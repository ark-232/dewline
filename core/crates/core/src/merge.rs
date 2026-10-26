//! Three-way merge: a file's new version (theirs) lands on the open buffer
//! (ours) against the text the buffer last absorbed (base).
//!
//! Lines are diffed first, then the words inside each changed region, both
//! with imara-diff's Myers algorithm. Offsets are UTF-16 code units, as the
//! Swift buffer counts them. They fall between characters and never inside
//! a `\r\n`, and every byte outside an edit stays as it was.

use std::collections::HashMap;
use std::ops::Range;

use imara_diff::{Algorithm, Diff, Hunk, Interner, NoSliderHeuristic, Token};

/// Theirs lands as one covering replace when it has more line hunks than
/// this or changes more than `COVERING_PERCENT` of the lines.
const COVERING_HUNKS: usize = 50;
const COVERING_PERCENT: usize = 30;

/// Replaces the UTF-16 range `start..end` with `text`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Edit {
    pub start: u32,
    pub end: u32,
    pub text: String,
}

/// Lines where ours and theirs changed the same words, or where one side's
/// insertion repeats the other's change or loses its line break to it. Ours
/// keeps its text at `start..end`; `theirs` is the other version of those
/// lines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conflict {
    pub start: u32,
    pub end: u32,
    pub theirs: String,
}

/// Theirs's changes as edits of ours, with offsets into ours. Edits are in
/// order, never touch each other or a conflict, and never cover text ours
/// changed since base.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Merge {
    pub edits: Vec<Edit>,
    pub conflicts: Vec<Conflict>,
    /// When theirs changed over 50 hunks or 30% of lines: one edit from the
    /// start of the first edit to the end of the last, carrying the merged
    /// text between, so it makes the same text as `edits`. Offsets still map
    /// through `edits`.
    pub covering: Option<Edit>,
}

/// Where an offset goes when an edit inserts text at it, or replaces text
/// on both sides of it: before or after the new text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bias {
    Before,
    After,
}

/// Lands theirs's changes since base on ours. Where both changed the same
/// words, the lines around them stay ours and become a conflict.
pub fn merge3(base: &str, ours: &str, theirs: &str) -> Merge {
    let (b, o, t) = (lines(base), lines(ours), lines(theirs));
    let (to_ours, to_theirs) = diff3(&b, &o, &t);
    let groups = groups(&to_ours, &to_theirs, true);
    let anchor = anchors(&b, &o, &t);
    let mut edits: Vec<(Range<usize>, String)> = Vec::new();
    let mut conflicts = Vec::new();
    let mut rest = &groups[..];
    while !rest.is_empty() {
        // Groups with no anchor line between them merge as one run, by word:
        // a line diff can pair a blank or repeated line with the wrong one.
        let between = |pair: &[Group]| pair[0].base.end..pair[1].base.start;
        let len = 1 + rest
            .windows(2)
            .take_while(|pair| !between(pair).any(|line| anchor[line as usize]))
            .count();
        let (run, next) = rest.split_at(len);
        rest = next;
        if !run.iter().any(|group| group.theirs_changed) {
            continue;
        }
        let (first, last) = (&run[0], &run[len - 1]);
        let at = o.at[first.ours.start as usize];
        let run_ours = o.slice(&(first.ours.start..last.ours.end));
        let run_theirs = t.slice(&(first.theirs.start..last.theirs.end));
        let run_base = b.slice(&(first.base.start..last.base.end));
        let Some(words) = merge_words(run_base, run_ours, run_theirs) else {
            conflicts.push((at..at + run_ours.len(), run_theirs.to_owned()));
            continue;
        };
        for (range, text) in words {
            let range = at + range.start..at + range.end;
            match edits.last_mut() {
                Some((last, last_text)) if last.end == range.start => {
                    last_text.push_str(text);
                    last.end = range.end;
                }
                _ => edits.push((range, text.to_owned())),
            }
        }
    }

    let changed: usize = to_theirs
        .iter()
        .map(|h| h.before.len().max(h.after.len()))
        .sum();
    let big =
        to_theirs.len() > COVERING_HUNKS || changed * 100 > b.len().max(t.len()) * COVERING_PERCENT;
    let covering = (big && !edits.is_empty()).then(|| {
        let mut text = String::new();
        for (k, (range, new)) in edits.iter().enumerate() {
            if k > 0 {
                text.push_str(&ours[edits[k - 1].0.end..range.start]);
            }
            text.push_str(new);
        }
        text
    });

    let mut cursor = Cursor::new(ours);
    let edits: Vec<Edit> = edits
        .into_iter()
        .map(|(range, text)| Edit {
            start: cursor.unit(range.start),
            end: cursor.unit(range.end),
            text,
        })
        .collect();
    let mut cursor = Cursor::new(ours);
    let conflicts = conflicts
        .into_iter()
        .map(|(range, theirs)| Conflict {
            start: cursor.unit(range.start),
            end: cursor.unit(range.end),
            theirs,
        })
        .collect();
    let covering = covering.map(|text| Edit {
        start: edits[0].start,
        end: edits[edits.len() - 1].end,
        text,
    });
    Merge {
        edits,
        conflicts,
        covering,
    }
}

/// Theirs's word changes as edits of `ours`, or `None` when both sides
/// changed the same words differently.
fn merge_words<'a>(
    base: &str,
    ours: &str,
    theirs: &'a str,
) -> Option<Vec<(Range<usize>, &'a str)>> {
    let (b, o, t) = (words(base), words(ours), words(theirs));
    let (to_ours, to_theirs) = diff3(&b, &o, &t);
    let groups = groups(&to_ours, &to_theirs, false);
    let side = |group: &Group| match group.ours_changed {
        true => o.slice(&group.ours),
        false => t.slice(&group.theirs),
    };
    let ends_line = |text: &str| text.ends_with(['\n', '\r']);
    for pair in groups.windows(2) {
        let (left, right) = (&pair[0], &pair[1]);
        let one_each = left.ours_changed != left.theirs_changed
            && right.ours_changed != right.theirs_changed
            && left.ours_changed != right.ours_changed;
        if !one_each || left.base.end != right.base.start {
            continue;
        }
        // One side inserts at the edge of the other's change. That is a
        // conflict when the insertion repeats the change's text there, or
        // starts a line whose break the change took away.
        let (left_text, right_text) = (side(left), side(right));
        let clash = if right.base.is_empty() {
            let broke = ends_line(b.slice(&(left.base.end - 1..left.base.end)));
            left_text.ends_with(right_text) || (broke && !ends_line(left_text))
        } else {
            left.base.is_empty() && right_text.starts_with(left_text)
        };
        if clash {
            return None;
        }
    }
    let mut edits = Vec::new();
    for group in groups {
        let theirs = t.slice(&group.theirs);
        if !group.ours_changed {
            edits.push((o.bytes(&group.ours), theirs));
        } else if group.theirs_changed && o.slice(&group.ours) != theirs {
            return None;
        }
    }
    Some(edits)
}

/// `text` with `edits` made. Offsets must fall between characters.
pub fn apply(text: &str, edits: &[Edit]) -> String {
    let mut out = String::with_capacity(text.len());
    let mut cursor = Cursor::new(text);
    let mut done = 0;
    for edit in edits {
        let start = cursor.byte(edit.start);
        out.push_str(&text[done..start]);
        out.push_str(&edit.text);
        done = cursor.byte(edit.end);
    }
    out.push_str(&text[done..]);
    out
}

/// Maps an offset in a text to the same place after `edits`, which are in
/// order and do not overlap. An offset at the edge of replaced text keeps
/// its neighbor outside it; one inside replaced text, or where text is
/// inserted, goes to the side of the new text that `bias` names.
pub fn map_offset(edits: &[Edit], offset: u32, bias: Bias) -> u32 {
    let mut shift = 0i64;
    for edit in edits {
        if offset < edit.start
            || (offset == edit.start && (edit.start < edit.end || bias == Bias::Before))
        {
            break;
        }
        let inserted = units(&edit.text);
        if offset < edit.end {
            let start = edit.start as i64 + shift;
            return match bias {
                Bias::Before => start,
                Bias::After => start + inserted,
            } as u32;
        }
        shift += inserted - i64::from(edit.end - edit.start);
    }
    (offset as i64 + shift) as u32
}

/// Moves the undo history past `edits` that the engine made to the buffer.
///
/// `undo` holds one entry per undoable action, oldest first; an entry is the
/// edits that undo it, as offsets into the buffer when that entry is next.
/// Entries move with the text around them. The first entry, from the
/// newest, that would undo text the engine replaced or undo around text it
/// inserted is dropped with everything older. Redo is cleared.
pub fn map_undo(undo: &mut Vec<Vec<Edit>>, redo: &mut Vec<Vec<Edit>>, edits: &[Edit]) {
    redo.clear();
    let mut engine = edits.to_vec();
    for k in (0..undo.len()).rev() {
        if overlap(&undo[k], &engine) {
            undo.drain(..=k);
            return;
        }
        // At one place, the entry's text goes before the engine's.
        let entry = map_edits(&undo[k], &engine, Bias::Before);
        engine = map_edits(&engine, &undo[k], Bias::After);
        undo[k] = entry;
    }
}

/// Whether two ordered edit lists share any text, or one inserts strictly
/// inside the other's range.
fn overlap(a: &[Edit], b: &[Edit]) -> bool {
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i].start < b[j].end && b[j].start < a[i].end {
            return true;
        }
        if a[i].end <= b[j].end {
            i += 1;
        } else {
            j += 1;
        }
    }
    false
}

/// `edits` moved past `through`: a range keeps out text inserted at its
/// edges, and an insertion goes to the `empty` side of text inserted at it.
fn map_edits(edits: &[Edit], through: &[Edit], empty: Bias) -> Vec<Edit> {
    edits
        .iter()
        .map(|edit| {
            let (start, end) = if edit.start == edit.end {
                let at = map_offset(through, edit.start, empty);
                (at, at)
            } else {
                (
                    map_offset(through, edit.start, Bias::After),
                    map_offset(through, edit.end, Bias::Before),
                )
            };
            Edit {
                start,
                end,
                text: edit.text.clone(),
            }
        })
        .collect()
}

fn units(text: &str) -> i64 {
    text.encode_utf16().count() as i64
}

/// Walks a text forward, converting between byte and UTF-16 offsets.
struct Cursor<'a> {
    text: &'a str,
    byte: usize,
    unit: u32,
}

impl<'a> Cursor<'a> {
    fn new(text: &'a str) -> Self {
        Cursor {
            text,
            byte: 0,
            unit: 0,
        }
    }

    fn unit(&mut self, byte: usize) -> u32 {
        self.unit += self.text[self.byte..byte]
            .chars()
            .map(|c| c.len_utf16() as u32)
            .sum::<u32>();
        self.byte = byte;
        self.unit
    }

    fn byte(&mut self, unit: u32) -> usize {
        let mut chars = self.text[self.byte..].chars();
        while self.unit < unit {
            let c = chars.next().expect("offset past the end of the text");
            self.unit += c.len_utf16() as u32;
            self.byte += c.len_utf8();
        }
        assert_eq!(self.unit, unit, "offset inside a surrogate pair");
        self.byte
    }
}

/// A text cut into tokens: token `k` is `text[at[k]..at[k + 1]]`.
struct Tokens<'a> {
    text: &'a str,
    at: Vec<usize>,
}

impl<'a> Tokens<'a> {
    fn len(&self) -> usize {
        self.at.len() - 1
    }

    fn iter(&self) -> impl Iterator<Item = &'a str> + '_ {
        self.at.windows(2).map(|w| &self.text[w[0]..w[1]])
    }

    fn bytes(&self, tokens: &Range<u32>) -> Range<usize> {
        self.at[tokens.start as usize]..self.at[tokens.end as usize]
    }

    fn slice(&self, tokens: &Range<u32>) -> &'a str {
        &self.text[self.bytes(tokens)]
    }
}

/// Lines with their endings: `\n`, `\r\n` or a lone `\r`.
fn lines(text: &str) -> Tokens<'_> {
    let bytes = text.as_bytes();
    let mut at = vec![0];
    at.extend(
        (0..bytes.len())
            .filter(|&i| {
                bytes[i] == b'\n' || (bytes[i] == b'\r' && bytes.get(i + 1) != Some(&b'\n'))
            })
            .map(|i| i + 1),
    );
    if at.last() != Some(&text.len()) {
        at.push(text.len());
    }
    Tokens { text, at }
}

/// Runs of letters and digits, runs of other blanks, line endings, and runs
/// of everything else.
fn words(text: &str) -> Tokens<'_> {
    let class = |c: char| (c.is_alphanumeric(), c.is_whitespace());
    let mut at = vec![0];
    let mut last = None;
    for (i, c) in text.char_indices() {
        if let Some(last) = last {
            let split = match (last, c) {
                ('\r', '\n') => false,
                ('\r' | '\n', _) | (_, '\r' | '\n') => true,
                _ => class(last) != class(c),
            };
            if split {
                at.push(i);
            }
        }
        last = Some(c);
    }
    if !text.is_empty() {
        at.push(text.len());
    }
    Tokens { text, at }
}

/// Which base lines occur once in each text, so that no line diff can pair
/// them with another line.
fn anchors(base: &Tokens, ours: &Tokens, theirs: &Tokens) -> Vec<bool> {
    let mut counts: HashMap<&str, [u32; 3]> = HashMap::new();
    for (k, tokens) in [base, ours, theirs].into_iter().enumerate() {
        for line in tokens.iter() {
            counts.entry(line).or_default()[k] += 1;
        }
    }
    base.iter().map(|line| counts[line] == [1, 1, 1]).collect()
}

/// Hunks from base to ours and from base to theirs.
fn diff3(base: &Tokens, ours: &Tokens, theirs: &Tokens) -> (Vec<Hunk>, Vec<Hunk>) {
    let mut interner = Interner::new(base.len() + ours.len() + theirs.len());
    let [b, o, t] = [base, ours, theirs].map(|tokens| {
        tokens
            .iter()
            .map(|token| interner.intern(token))
            .collect::<Vec<_>>()
    });
    (diff(&interner, &b, &o), diff(&interner, &b, &t))
}

fn diff(interner: &Interner<&str>, before: &[Token], after: &[Token]) -> Vec<Hunk> {
    // Histogram takes quadratic time on scattered changes: 17 s to diff
    // 200,000 lines with every third changed, against 1.4 ms for Myers.
    let mut diff = Diff::default();
    diff.compute_with(Algorithm::Myers, before, after, interner.num_tokens());
    diff.postprocess_with(before, after, NoSliderHeuristic);
    diff.hunks().collect()
}

/// A region one side or both changed, in tokens of each text. Between two
/// groups, all three texts agree.
struct Group {
    base: Range<u32>,
    ours: Range<u32>,
    theirs: Range<u32>,
    ours_changed: bool,
    theirs_changed: bool,
}

/// Gathers the hunks of both sides into groups, in base order. Hunks group
/// when they share a token or insert at one place; with `adjacent`, whenever
/// they touch.
fn groups(ours: &[Hunk], theirs: &[Hunk], adjacent: bool) -> Vec<Group> {
    let overlaps = |a: &Range<u32>, b: &Range<u32>| {
        let touch = a.start <= b.end && b.start <= a.end;
        (a.start < b.end && b.start < a.end)
            || (touch && (adjacent || (a.is_empty() && b.is_empty())))
    };
    let key = |hunk: &Hunk| (hunk.before.start, hunk.before.end);
    let mut groups = Vec::new();
    let (mut i, mut j) = (0, 0);
    let (mut ours_shift, mut theirs_shift) = (0i64, 0i64);
    while i < ours.len() || j < theirs.len() {
        let ours_first = j == theirs.len() || (i < ours.len() && key(&ours[i]) <= key(&theirs[j]));
        let (mut i_end, mut j_end, mut base) = if ours_first {
            (i + 1, j, ours[i].before.clone())
        } else {
            (i, j + 1, theirs[j].before.clone())
        };
        loop {
            let next = if i_end < ours.len() && overlaps(&ours[i_end].before, &base) {
                i_end += 1;
                &ours[i_end - 1]
            } else if j_end < theirs.len() && overlaps(&theirs[j_end].before, &base) {
                j_end += 1;
                &theirs[j_end - 1]
            } else {
                break;
            };
            base.end = base.end.max(next.before.end);
        }
        let side = |hunks: &[Hunk], shift: &mut i64| {
            let start = (i64::from(base.start) + *shift) as u32;
            *shift += hunks
                .iter()
                .map(|h| h.after.len() as i64 - h.before.len() as i64)
                .sum::<i64>();
            start..(i64::from(base.end) + *shift) as u32
        };
        groups.push(Group {
            ours: side(&ours[i..i_end], &mut ours_shift),
            theirs: side(&theirs[j..j_end], &mut theirs_shift),
            base,
            ours_changed: i_end > i,
            theirs_changed: j_end > j,
        });
        (i, j) = (i_end, j_end);
    }
    groups
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use proptest::sample::Index;
    use std::cell::Cell;

    fn edit(start: u32, end: u32, text: &str) -> Edit {
        Edit {
            start,
            end,
            text: text.into(),
        }
    }

    fn merged(base: &str, ours: &str, theirs: &str) -> String {
        apply(ours, &merge3(base, ours, theirs).edits)
    }

    /// Ten lines, with `changed` in capitals.
    fn ten(changed: &[usize]) -> String {
        (0..10)
            .map(|i| match changed.contains(&i) {
                true => format!("LINE {i}\n"),
                false => format!("line {i}\n"),
            })
            .collect()
    }

    #[test]
    fn edits_to_different_lines_both_land() {
        let base = "one\ntwo\nthree\n";
        assert_eq!(
            merged(base, "ONE\ntwo\nthree\n", "one\ntwo\nTHREE\n"),
            "ONE\ntwo\nTHREE\n"
        );
    }

    #[test]
    fn edits_to_different_words_of_a_line_both_land() {
        let base = "The quick brown fox\n";
        let ours = "The quick brown fox jumps\n";
        let merge = merge3(base, ours, "The slow brown fox\n");
        assert_eq!(merge.edits, [edit(4, 9, "slow")]);
        assert_eq!(merge.conflicts, []);
        assert_eq!(apply(ours, &merge.edits), "The slow brown fox jumps\n");
    }

    #[test]
    fn a_word_both_changed_conflicts_and_keeps_ours() {
        let base = "x\n\nThe cat sat\n";
        let ours = "x\n\nThe dog sat\n";
        let merge = merge3(base, ours, "X\n\nThe cow sat\n");
        assert_eq!(merge.edits, [edit(0, 1, "X")]);
        assert_eq!(
            merge.conflicts,
            [Conflict {
                start: 3,
                end: 15,
                theirs: "The cow sat\n".into()
            }]
        );
        assert_eq!(apply(ours, &merge.edits), "X\n\nThe dog sat\n");
    }

    #[test]
    fn different_insertions_at_one_place_conflict() {
        let merge = merge3("a\n", "a\nmine\n", "a\ntheirs\n");
        assert_eq!(merge.edits, []);
        assert_eq!(
            merge.conflicts,
            [Conflict {
                start: 2,
                end: 7,
                theirs: "theirs\n".into()
            }]
        );
    }

    #[test]
    fn the_same_change_on_both_sides_lands_once() {
        let merge = merge3("a b\n", "a c\n", "a c\n");
        assert_eq!((merge.edits, merge.conflicts), (vec![], vec![]));
    }

    #[test]
    fn an_append_does_not_join_a_line_ours_left_open() {
        for (base, ours, theirs) in [
            (
                "Notes\n- one\n",
                "Notes\n- one more",
                "Notes\n- one\n- two\n",
            ),
            ("a\r\nb\r\n", "a\r\nb typed", "a\r\nb\r\nc\r\n"),
        ] {
            let merge = merge3(base, ours, theirs);
            assert_eq!(
                (merge.edits.len(), merge.conflicts.len()),
                (0, 1),
                "{ours:?}"
            );
        }
    }

    #[test]
    fn an_insertion_that_repeats_the_other_side_conflicts() {
        for (base, ours, theirs) in [
            ("foo bar\n", "foo new baz\n", "foo new bar\n"),
            ("foo bar\n", "foo baz new\n", "foo bar new\n"),
            ("A\nB\n", "A\nX\nB2\n", "A\nX\nB\n"),
        ] {
            let merge = merge3(base, ours, theirs);
            assert_eq!(
                (merge.edits.len(), merge.conflicts.len()),
                (0, 1),
                "{ours:?}"
            );
        }
    }

    #[test]
    fn typing_at_a_line_end_merges_with_new_line_endings() {
        let base = "one two\r\nthree\r\n";
        let ours = "one two typed\r\nthree\r\n";
        assert_eq!(
            merged(base, ours, "one two\nthree\n"),
            "one two typed\nthree\n"
        );
    }

    #[test]
    fn lines_across_blank_lines_merge_by_word() {
        let base = "w0. w1\r\n\r\nw2. w3. w4\r\n\r\nw5 ";
        let ours = "w0. w1\r\n\r\nw2. o3. w4\r\n\r\nw5 ";
        let merge = merge3(base, ours, "w0. w2. w3. w4\r\n\r\nt5 ");
        assert_eq!(merge.conflicts, []);
        assert_eq!(apply(ours, &merge.edits), "w0. w2. o3. w4\r\n\r\nt5 ");
        let base = "w0 w3. w4\n\nw5. w6 w7\n\nw8. w9\n\nw10";
        let ours = "w0 w3. w5. w6 w7\n\nw8. w9 on9\n\nw10";
        let theirs = "w0 w3. w4\n\nw5. w6 tn6 w7\n\nw8. w9\n\nw10";
        assert_eq!(
            merged(base, ours, theirs),
            "w0 w3. w5. w6 tn6 w7\n\nw8. w9 on9\n\nw10"
        );
    }

    #[test]
    fn a_conflict_across_blank_lines_offers_all_of_theirs() {
        let base = "Intro text here.\n\nSecond para with a typo teh.\n\n";
        let ours = "Intro text, edited.\n\nSecond para with a typo";
        for theirs in [
            "Intro text here.\n\nSecond para with a typo the.\n\n",
            "Intro text here.\n\nSecond para with a typo teh.\n\nAgent para.\n",
        ] {
            let merge = merge3(base, ours, theirs);
            assert_eq!(merge.edits, []);
            let end = ours.encode_utf16().count() as u32;
            let whole = Conflict {
                start: 0,
                end,
                theirs: theirs.into(),
            };
            assert_eq!(merge.conflicts, [whole]);
        }
    }

    #[test]
    fn scattered_changes_to_a_large_file_merge_in_linear_time() {
        // Theirs capitalizes every third line's first word; ours types at the
        // end of every seventh line.
        let file = |theirs: usize, ours: usize| -> String {
            let every = |n: usize, i: usize| n > 0 && i.is_multiple_of(n);
            (0..40_000)
                .map(|i| {
                    let first = if every(theirs, i) { "LINE" } else { "line" };
                    let last = if every(ours, i) { " typed" } else { "" };
                    format!("{first} {i} some words{last}\n")
                })
                .collect()
        };
        let base = file(0, 0);
        let crlf = base.replace('\n', "\r\n");
        let started = std::time::Instant::now();
        let merge = merge3(&base, &file(0, 7), &file(3, 0));
        assert_eq!(apply(&file(0, 7), &merge.edits), file(3, 7));
        assert_eq!((merge.edits.len(), merge.conflicts.len()), (13_334, 0));
        let typed = crlf.replace("line 20000 some words", "line 20000 some words typed");
        let merge = merge3(&crlf, &typed, &base);
        assert_eq!(apply(&typed, &merge.edits), typed.replace("\r\n", "\n"));
        // Each merge takes about 0.4 s in a debug build; a quadratic diff
        // takes minutes.
        assert!(started.elapsed().as_secs() < 10, "{:?}", started.elapsed());
    }

    #[test]
    fn line_endings_stay_byte_for_byte() {
        let base = "a\r\nb\rc\nd";
        assert_eq!(
            merged(base, "a\r\nb\rc\nd!", "A\r\nb\rc\nd"),
            "A\r\nb\rc\nd!"
        );
        let crlf = "one\r\ntwo\r\n";
        assert_eq!(merged(crlf, crlf, "one\ntwo\r\n"), "one\ntwo\r\n");
        assert_eq!(
            merged(crlf, "one\r\ntwo!\r\n", "One\r\ntwo\r\nthree\r\n"),
            "One\r\ntwo!\r\nthree\r\n"
        );
    }

    #[test]
    fn surrogate_pairs_stay_whole() {
        let ours = "🙂 a 🙂👍\n";
        let merge = merge3("🙂 a 🙂\n", ours, "🙂 b 🙂\n");
        assert_eq!(merge.edits, [edit(3, 4, "b")]);
        assert_eq!(apply(ours, &merge.edits), "🙂 b 🙂👍\n");
    }

    /// The covering replace, after checking it makes the same text as the edits.
    fn covering(ours: &str, merge: &Merge) -> Option<Edit> {
        let covering = merge.covering.clone()?;
        assert_eq!(covering.start, merge.edits[0].start);
        assert_eq!(covering.end, merge.edits.last().unwrap().end);
        assert_eq!(
            apply(ours, std::slice::from_ref(&covering)),
            apply(ours, &merge.edits)
        );
        Some(covering)
    }

    #[test]
    fn over_50_hunks_land_as_one_covering_replace() {
        let base: String = (0..400).map(|i| format!("line {i}\n")).collect();
        let changed = |hunks: usize| -> String {
            (0..400)
                .map(|i| match i % 4 == 0 && i / 4 < hunks {
                    true => format!("LINE {i}\n"),
                    false => format!("line {i}\n"),
                })
                .collect()
        };
        let fifty = merge3(&base, &base, &changed(50));
        assert_eq!((fifty.edits.len(), fifty.covering), (50, None));
        let theirs = changed(51);
        let merge = merge3(&base, &base, &theirs);
        assert_eq!(merge.edits.len(), 51);
        assert_eq!(apply(&base, &[covering(&base, &merge).unwrap()]), theirs);
    }

    #[test]
    fn over_30_percent_of_lines_land_as_one_covering_replace() {
        let base = ten(&[]);
        let thirty = merge3(&base, &base, &ten(&[0, 2, 4]));
        assert_eq!((thirty.edits.len(), thirty.covering), (3, None));
        let merge = merge3(&base, &base, &ten(&[0, 2, 4, 6]));
        assert_eq!(merge.edits.len(), 4);
        assert_eq!(
            apply(&base, &[covering(&base, &merge).unwrap()]),
            ten(&[0, 2, 4, 6])
        );
    }

    #[test]
    fn a_covering_replace_carries_unsaved_text_and_the_caret_keeps_it() {
        let typed = |text: String| text.replace("line 4\n", "line 4 typed\n");
        let (base, theirs) = (ten(&[]), ten(&[0, 2, 6, 8]));
        let ours = typed(base.clone());
        let merge = merge3(&base, &ours, &theirs);
        let covering = covering(&ours, &merge).unwrap();
        assert!(covering.text.contains("line 4 typed\n"));
        let merged = apply(&ours, &[covering]);
        assert_eq!(merged, typed(theirs));
        let caret = ours.find(" typed").unwrap() as u32 + 6;
        let caret = map_offset(&merge.edits, caret, Bias::Before) as usize;
        assert_eq!(&merged[caret - 12..caret], "line 4 typed");
    }

    #[test]
    fn map_offset_keeps_neighbors_and_follows_bias() {
        // "abcdef" becomes "aXYbZef".
        let edits = [edit(1, 1, "XY"), edit(2, 4, "Z")];
        let map = |at, bias| map_offset(&edits, at, bias);
        assert_eq!(map(0, Bias::After), 0);
        assert_eq!((map(1, Bias::Before), map(1, Bias::After)), (1, 3));
        assert_eq!((map(2, Bias::Before), map(2, Bias::After)), (4, 4));
        assert_eq!((map(3, Bias::Before), map(3, Bias::After)), (4, 5));
        assert_eq!((map(4, Bias::Before), map(4, Bias::After)), (5, 5));
        assert_eq!(map(6, Bias::Before), 7);
    }

    #[test]
    fn undo_moves_past_engine_edits() {
        // "hello" + " world" typed, then the engine prepends "Oh, ".
        let mut undo = vec![vec![edit(5, 11, "")]];
        let mut redo = vec![vec![edit(0, 0, "x")]];
        map_undo(&mut undo, &mut redo, &[edit(0, 0, "Oh, ")]);
        assert_eq!(undo, [vec![edit(9, 15, "")]]);
        assert_eq!(redo, Vec::<Vec<Edit>>::new());
        assert_eq!(apply("Oh, hello world", &undo[0]), "Oh, hello");
    }

    #[test]
    fn undo_stops_at_the_first_entry_the_engine_touched() {
        // "a" typed at 0, then "b" typed at 1: "ab". The engine replaces "a".
        let mut undo = vec![vec![edit(0, 1, "")], vec![edit(1, 2, "")]];
        map_undo(&mut undo, &mut vec![], &[edit(0, 1, "A")]);
        assert_eq!(undo, [vec![edit(1, 2, "")]]);
        // Typing at 1 and 2, then an engine insertion between them.
        let mut undo = vec![vec![edit(1, 3, "")]];
        map_undo(&mut undo, &mut vec![], &[edit(2, 2, "!")]);
        assert_eq!(undo, Vec::<Vec<Edit>>::new());
    }

    const PIECES: &[&str] = &[
        "a",
        "b",
        "word",
        "é",
        "e\u{301}",
        "日本",
        "🙂",
        "👩\u{200d}💻",
        " ",
        "  ",
        "\t",
        ".",
        "*",
        "#",
        "\n",
        "\n",
        "\r\n",
        "\r",
    ];

    fn text(max: usize) -> impl Strategy<Value = String> {
        prop::collection::vec(prop::sample::select(PIECES), 0..max).prop_map(|p| p.concat())
    }

    /// `of` with a few characters replaced, inserted or deleted.
    fn edited(of: String) -> impl Strategy<Value = String> {
        prop::collection::vec((any::<Index>(), 0..4usize, text(4)), 0..4).prop_map(move |edits| {
            let mut chars: Vec<char> = of.chars().collect();
            for (at, len, new) in edits {
                let start = at.index(chars.len() + 1);
                let end = (start + len).min(chars.len());
                chars.splice(start..end, new.chars());
            }
            chars.into_iter().collect()
        })
    }

    /// A base and two edited copies of it.
    fn versions() -> impl Strategy<Value = (String, String, String)> {
        text(48).prop_flat_map(|base| (Just(base.clone()), edited(base.clone()), edited(base)))
    }

    /// One line of a region: its tag, then characters no other region uses.
    fn region(tag: &'static str) -> impl Strategy<Value = String> {
        let pieces = &["a", "é", "e\u{301}", "🙂", "👩\u{200d}💻", " ", "\t", "*"][..];
        prop::collection::vec(prop::sample::select(pieces), 0..6)
            .prop_map(move |p| format!("{tag}{}", p.concat()))
    }

    fn boundaries(text: &str) -> Vec<u32> {
        let mut at = vec![0];
        for c in text.chars() {
            at.push(at.last().unwrap() + c.len_utf16() as u32);
        }
        at
    }

    /// Characters not used before in the test case, every other one outside
    /// the Basic Multilingual Plane.
    fn fresh(next: &Cell<u32>, len: usize) -> String {
        let code = |i: u32| {
            if i.is_multiple_of(2) {
                0x4E00 + i
            } else {
                0x20000 + i
            }
        };
        (0..len)
            .map(|_| char::from_u32(code(next.replace(next.get() + 1))).unwrap())
            .collect()
    }

    /// Ordered, non-overlapping edits of `text` at character boundaries that
    /// insert fresh characters, never two insertions at one place.
    fn edits_of(text: &str, picks: &[(Index, Index, usize)], next: &Cell<u32>) -> Vec<Edit> {
        let at = boundaries(text);
        let mut ranges: Vec<(u32, u32, usize)> = picks
            .iter()
            .map(|(a, b, len)| {
                let (a, b) = (at[a.index(at.len())], at[b.index(at.len())]);
                (a.min(b), a.max(b), *len)
            })
            .collect();
        ranges.sort();
        let mut edits: Vec<Edit> = Vec::new();
        for (start, end, len) in ranges {
            let fits = |last: &Edit| {
                last.end < start || (last.end == start && (last.start < last.end || start < end))
            };
            if edits.last().is_none_or(fits) && (start < end || len > 0) {
                edits.push(edit(start, end, &fresh(next, len)));
            }
        }
        edits
    }

    fn picks() -> impl Strategy<Value = Vec<(Index, Index, usize)>> {
        prop::collection::vec((any::<Index>(), any::<Index>(), 0..4usize), 0..5)
    }

    /// The edits that undo `edits` of `text`, as offsets into the result.
    fn inverse(text: &str, edits: &[Edit]) -> Vec<Edit> {
        let units: Vec<u16> = text.encode_utf16().collect();
        let mut shift = 0i64;
        edits
            .iter()
            .map(|e| {
                let start = (i64::from(e.start) + shift) as u32;
                let len = e.text.encode_utf16().count() as u32;
                shift += i64::from(len) - i64::from(e.end - e.start);
                let old = String::from_utf16(&units[e.start as usize..e.end as usize]).unwrap();
                edit(start, start + len, &old)
            })
            .collect()
    }

    #[derive(Debug, Clone, Copy, PartialEq)]
    enum Act {
        Keep,
        Change,
        Delete,
        Append,
    }

    /// Words `w0`, `w1`, ..., each followed by its separator: kept, changed
    /// to `{tag}{i}`, deleted with its separator, or followed by ` {tag}n{i}`.
    fn render(words: &[(&str, Act, &str)]) -> String {
        let mut text = String::new();
        for (i, (separator, act, tag)) in words.iter().enumerate() {
            match act {
                Act::Keep => text.push_str(&format!("w{i}")),
                Act::Change => text.push_str(&format!("{tag}{i}")),
                Act::Delete => continue,
                Act::Append => text.push_str(&format!("w{i} {tag}n{i}")),
            }
            text.push_str(separator);
        }
        text
    }

    proptest! {
        #[test]
        fn a_clean_buffer_takes_theirs((base, _, theirs) in versions()) {
            let merge = merge3(&base, &base, &theirs);
            prop_assert!(merge.conflicts.is_empty());
            prop_assert_eq!(apply(&base, &merge.edits), theirs);
        }

        #[test]
        fn a_covering_replace_makes_the_merged_text((base, ours, theirs) in versions()) {
            covering(&ours, &merge3(&base, &ours, &theirs));
        }

        #[test]
        fn an_unchanged_file_changes_nothing((base, ours, _) in versions()) {
            prop_assert_eq!(merge3(&base, &ours, &base), Merge::default());
        }

        #[test]
        fn one_change_made_on_both_sides_changes_nothing((base, ours, _) in versions()) {
            let merge = merge3(&base, &ours, &ours);
            prop_assert!(merge.edits.is_empty() && merge.conflicts.is_empty());
        }

        #[test]
        fn disjoint_edits_commute(
            (a, b, c, a2, b2, c2) in (
                region("α"), region("β"), region("γ"), region("α"), region("β"), region("γ"),
            ),
            end in prop::sample::select(&["\n", "\r\n", "\r"][..]),
        ) {
            let text = |a: &str, b: &str, c: &str| format!("{a}{end}§1{end}{b}{end}§2{end}{c}");
            let (base, ours, theirs) = (text(&a, &b, &c), text(&a2, &b, &c2), text(&a, &b2, &c));
            let both = text(&a2, &b2, &c2);
            let (one, two) = (merge3(&base, &ours, &theirs), merge3(&base, &theirs, &ours));
            prop_assert!(one.conflicts.is_empty() && two.conflicts.is_empty());
            prop_assert_eq!(apply(&ours, &one.edits), both.as_str());
            prop_assert_eq!(apply(&theirs, &two.edits), both.as_str());
        }

        #[test]
        fn clean_merges_commute((base, ours, theirs) in versions()) {
            let (one, two) = (merge3(&base, &ours, &theirs), merge3(&base, &theirs, &ours));
            prop_assert_eq!(one.conflicts.is_empty(), two.conflicts.is_empty());
            if one.conflicts.is_empty() {
                prop_assert_eq!(apply(&ours, &one.edits), apply(&theirs, &two.edits));
            }
        }

        #[test]
        fn conflicts_keep_ours((base, ours, theirs) in versions()) {
            let merge = merge3(&base, &ours, &theirs);
            prop_assert!(merge.conflicts.is_empty() || (base != ours && base != theirs));
            let merged: Vec<u16> = apply(&ours, &merge.edits).encode_utf16().collect();
            let units: Vec<u16> = ours.encode_utf16().collect();
            for conflict in &merge.conflicts {
                let kept = &units[conflict.start as usize..conflict.end as usize];
                let at = map_offset(&merge.edits, conflict.start, Bias::Before) as usize;
                prop_assert_eq!(&merged[at..at + kept.len()], kept);
            }
        }

        #[test]
        fn unsaved_text_is_never_covered((base, _, theirs) in versions(), at in any::<Index>()) {
            let mut chars: Vec<char> = base.chars().collect();
            chars.insert(at.index(chars.len() + 1), '\u{E000}');
            let ours: String = chars.into_iter().collect();
            let typed = ours.encode_utf16().position(|u| u == 0xE000).unwrap() as u32;
            let merge = merge3(&base, &ours, &theirs);
            for edit in &merge.edits {
                prop_assert!(edit.end <= typed || typed < edit.start, "{edit:?} covers {typed}");
            }
            prop_assert_eq!(apply(&ours, &merge.edits).matches('\u{E000}').count(), 1);
        }

        #[test]
        fn offsets_fall_between_characters_and_line_endings((base, ours, theirs) in versions()) {
            let merge = merge3(&base, &ours, &theirs);
            let units: Vec<u16> = ours.encode_utf16().collect();
            let between = |at: u32| match units.get(at as usize) {
                None => at as usize == units.len(),
                Some(&unit) => {
                    !(0xDC00..0xE000).contains(&unit)
                        && !(unit == u16::from(b'\n') && at > 0 && units[at as usize - 1] == u16::from(b'\r'))
                }
            };
            let mut ranges: Vec<(u32, u32)> = merge.edits.iter().map(|e| (e.start, e.end))
                .chain(merge.conflicts.iter().map(|c| (c.start, c.end)))
                .collect();
            ranges.sort();
            for &(start, end) in &ranges {
                prop_assert!(start <= end && between(start) && between(end), "{start}..{end}");
            }
            for pair in ranges.windows(2) {
                prop_assert!(pair[0].1 < pair[1].0, "{:?} touches {:?}", pair[0], pair[1]);
            }
        }

        #[test]
        fn mapped_offsets_keep_their_neighbors(len in 0..24usize, picks in picks()) {
            let next = Cell::new(0);
            let text = fresh(&next, len);
            let edits = edits_of(&text, &picks, &next);
            let before: Vec<u16> = text.encode_utf16().collect();
            let after: Vec<u16> = apply(&text, &edits).encode_utf16().collect();
            let at = boundaries(&text);
            for bias in [Bias::Before, Bias::After] {
                let to: Vec<u32> = at.iter().map(|&at| map_offset(&edits, at, bias)).collect();
                prop_assert!(to.windows(2).all(|w| w[0] <= w[1]));
                for (&at, &to) in at.iter().zip(&to) {
                    let (at, to) = (at as usize, to as usize);
                    prop_assert!(after.get(to).is_none_or(|u| !(0xDC00..0xE000).contains(u)));
                    prop_assert!(to <= after.len());
                    let range = |e: &Edit| e.start as usize..e.end as usize;
                    let inserted = edits.iter().any(|e| range(e) == (at..at) && !e.text.is_empty());
                    let left = at > 0 && !edits.iter().any(|e| range(e).contains(&(at - 1)));
                    let right = at < before.len() && !edits.iter().any(|e| range(e).contains(&at));
                    if left && (!inserted || bias == Bias::Before) {
                        prop_assert_eq!(after[to - 1], before[at - 1]);
                    }
                    if right && (!inserted || bias == Bias::After) {
                        prop_assert_eq!(after[to], before[at]);
                    }
                    let around = |e: &&Edit| range(e) == (at..at) || range(e).contains(&at) && e.start as usize != at;
                    for e in edits.iter().filter(around) {
                        let new: Vec<u16> = e.text.encode_utf16().collect();
                        let side = match bias {
                            Bias::Before => after.get(to..to + new.len()),
                            Bias::After => to.checked_sub(new.len()).map(|from| &after[from..to]),
                        };
                        prop_assert_eq!(side, Some(&new[..]));
                    }
                }
            }
        }

        #[test]
        fn undo_reverts_only_the_users_edits(
            len in 0..20usize,
            steps in prop::collection::vec(picks(), 0..6),
            engine in picks(),
        ) {
            let next = Cell::new(0);
            let mut states = vec![fresh(&next, len)];
            let mut undo = Vec::new();
            for picks in &steps {
                let text = states.last().unwrap();
                let edits = edits_of(text, picks, &next);
                undo.push(inverse(text, &edits));
                states.push(apply(text, &edits));
            }
            let now = states.last().unwrap();
            let engine = edits_of(now, &engine, &next);
            let mut redo = vec![vec![edit(0, 0, "x")]];
            map_undo(&mut undo, &mut redo, &engine);
            prop_assert!(redo.is_empty());
            let kept = undo.len();
            let mut text = apply(now, &engine);
            while let Some(entry) = undo.pop() {
                text = apply(&text, &entry);
            }
            // Every character is unique: the engine's text is still whole, and
            // the rest is the text before the undone edits, less what the
            // engine replaced.
            for e in &engine {
                prop_assert!(text.contains(&e.text), "{:?} in {:?}", e.text, text);
            }
            let units: Vec<u16> = now.encode_utf16().collect();
            let replaced: String = engine
                .iter()
                .map(|e| String::from_utf16(&units[e.start as usize..e.end as usize]).unwrap())
                .collect();
            let written: String = engine.iter().map(|e| e.text.as_str()).collect();
            let old = &states[states.len() - 1 - kept];
            let rest = |text: &str, out: &str| text.chars().filter(|c| !out.contains(*c)).collect::<String>();
            prop_assert_eq!(rest(&text, &written), rest(old, &replaced));
        }

        #[test]
        fn disjoint_word_edits_both_land(
            words in prop::collection::vec((
                prop::sample::select(&[" ", "\n", "\r\n", "\r", ". ", ", ", "\t", "  ", "\n\n", " 🙂 ", "\r\n\r\n"][..]),
                prop_oneof![4 => Just(Act::Keep), 2 => Just(Act::Change), 1 => Just(Act::Delete), 1 => Just(Act::Append)],
                any::<bool>(),
            ), 1..40),
        ) {
            // A kept word stands between any word ours acts on and any word
            // theirs acts on.
            let mut words = words;
            for i in 1..words.len() {
                let (act, mine) = (words[i].1, words[i].2);
                if act != Act::Keep && words[i - 1].1 != Act::Keep && mine != words[i - 1].2 {
                    words[i].1 = Act::Keep;
                }
            }
            let side = |ours: bool, tag| -> Vec<(&str, Act, &str)> {
                words.iter().map(|&(sep, act, mine)| (sep, if mine == ours { act } else { Act::Keep }, tag)).collect()
            };
            let base = render(&words.iter().map(|&(sep, _, _)| (sep, Act::Keep, "x")).collect::<Vec<_>>());
            let (ours, theirs) = (render(&side(true, "o")), render(&side(false, "t")));
            let both = render(&words.iter().map(|&(sep, act, mine)| (sep, act, if mine { "o" } else { "t" })).collect::<Vec<_>>());
            let (one, two) = (merge3(&base, &ours, &theirs), merge3(&base, &theirs, &ours));
            prop_assert!(one.conflicts.is_empty() && two.conflicts.is_empty(), "{base:?} {ours:?} {theirs:?}");
            prop_assert_eq!(apply(&ours, &one.edits), both.as_str());
            prop_assert_eq!(apply(&theirs, &two.edits), both.as_str());
        }
    }
}
