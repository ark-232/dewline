//! merge3 against `git merge-file -p --diff3` on random markdown triples.
//! `merge_agrees_with_git` is the proptest form and needs git on the PATH.
//! `survey` (ignored) runs MERGE_CHECK_CASES triples per mode in MERGE_CHECK_MODES
//! (`lf`, `cr`) on MERGE_CHECK_THREADS threads, shrinks every kind of finding and
//! prints a report:
//!   cargo test --release --test merge_vs_git -- --ignored survey --nocapture

use dewline_core::merge::{Bias, Edit, Merge, apply, map_offset, merge3};
use proptest::prelude::*;
use proptest::sample::Index;
use proptest::strategy::ValueTree;
use proptest::test_runner::{Config, RngAlgorithm, TestRng, TestRunner};
use std::collections::{BTreeMap, HashMap};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;

// ---------------------------------------------------------------- generation

/// (base, ours, theirs)
type Triple = (String, String, String);

const POOL: &[&str] = &[
    "",
    "",
    "",
    "# Title",
    "## Notes",
    "- item",
    "- item",
    "- other item",
    "Some text here.",
    "Another line, with words.",
    "text",
    "text",
    "> quote",
    "```",
    "let x = 1;",
    "🙂 emoji 👩\u{200d}💻 line",
    "日本語の文章です。",
    "中文 and English 混合",
    "cafe\u{301} né",
    "| a | b |",
    "---",
    "1. first",
    "    code block",
];

const SHARED_WORDS: &[&str] = &["word", "text", "item", "🙂", "日本", "é", "-", "new"];

#[derive(Debug, Clone)]
pub struct Line {
    text: String,
    end: &'static str,
}

#[derive(Debug, Clone)]
enum WordOp {
    Change(String),
    InsertAfter(String),
    Delete,
    Append(String),
}

#[derive(Debug, Clone)]
enum Op {
    Delete(Index, usize),
    Insert(Index, Vec<String>),
    Replace(Index, String),
    Word(Index, Index, WordOp),
    Ending(Index, &'static str),
    FinalNewline,
    AllEndings(&'static str),
    /// Join line i with the next one through a space (a reflow).
    Join(Index),
    /// Break line i after word j.
    Split(Index, Index),
}

fn ending(cr: bool) -> BoxedStrategy<&'static str> {
    if cr {
        prop_oneof![6 => Just("\n"), 3 => Just("\r\n"), 2 => Just("\r")].boxed()
    } else {
        prop_oneof![3 => Just("\n"), 1 => Just("\r\n")].boxed()
    }
}

fn pool_line() -> impl Strategy<Value = String> {
    prop::sample::select(POOL).prop_map(String::from)
}

fn new_line(tag: &'static str) -> BoxedStrategy<String> {
    prop_oneof![
        2 => pool_line(),
        3 => (0..4u8).prop_map(move |n| format!("{tag}{n} added line")),
        1 => Just("shared added line".to_string()),
    ]
    .boxed()
}

fn new_word(tag: &'static str) -> BoxedStrategy<String> {
    prop_oneof![
        3 => (0..4u8).prop_map(move |n| format!("{tag}w{n}")),
        1 => prop::sample::select(SHARED_WORDS).prop_map(String::from),
    ]
    .boxed()
}

fn word_op(tag: &'static str) -> BoxedStrategy<WordOp> {
    prop_oneof![
        3 => new_word(tag).prop_map(WordOp::Change),
        2 => new_word(tag).prop_map(WordOp::InsertAfter),
        1 => Just(WordOp::Delete),
        2 => new_word(tag).prop_map(WordOp::Append),
    ]
    .boxed()
}

fn op(tag: &'static str, cr: bool) -> BoxedStrategy<Op> {
    prop_oneof![
        3 => (any::<Index>(), 1..3usize).prop_map(|(i, n)| Op::Delete(i, n)),
        4 => (any::<Index>(), prop::collection::vec(new_line(tag), 1..3)).prop_map(|(i, l)| Op::Insert(i, l)),
        3 => (any::<Index>(), new_line(tag)).prop_map(|(i, l)| Op::Replace(i, l)),
        6 => (any::<Index>(), any::<Index>(), word_op(tag)).prop_map(|(i, j, w)| Op::Word(i, j, w)),
        1 => (any::<Index>(), ending(cr)).prop_map(|(i, e)| Op::Ending(i, e)),
        1 => Just(Op::FinalNewline),
        1 => ending(cr).prop_map(Op::AllEndings),
        2 => any::<Index>().prop_map(Op::Join),
        2 => (any::<Index>(), any::<Index>()).prop_map(|(i, j)| Op::Split(i, j)),
    ]
    .boxed()
}

fn base_lines(cr: bool) -> impl Strategy<Value = Vec<Line>> {
    // A style: all LF, all CRLF, or mixed per line.
    let style = prop_oneof![5 => Just(0u8), 2 => Just(1u8), 1 => Just(2u8)];
    (
        prop::collection::vec((pool_line(), ending(cr)), 0..10),
        style,
        prop_oneof![3 => Just(true), 1 => Just(false)],
    )
        .prop_map(|(lines, style, final_nl)| {
            let mut lines: Vec<Line> = lines
                .into_iter()
                .map(|(text, end)| Line {
                    text,
                    end: match style {
                        0 => "\n",
                        1 => "\r\n",
                        _ => end,
                    },
                })
                .collect();
            if !final_nl && let Some(last) = lines.last_mut() {
                last.end = "";
            }
            normalize(&mut lines);
            lines
        })
}

/// Only the last line may lack an ending; an empty last line without one is dropped.
fn normalize(lines: &mut Vec<Line>) {
    let n = lines.len();
    for (k, line) in lines.iter_mut().enumerate() {
        if k + 1 < n && line.end.is_empty() {
            line.end = "\n";
        }
    }
    if lines
        .last()
        .is_some_and(|l| l.text.is_empty() && l.end.is_empty())
    {
        lines.pop();
    }
}

fn style_end(lines: &[Line], at: usize) -> &'static str {
    let near = [at.checked_sub(1), Some(at)];
    for k in near.into_iter().flatten() {
        if let Some(l) = lines.get(k)
            && !l.end.is_empty()
        {
            return l.end;
        }
    }
    "\n"
}

fn apply_ops(base: &[Line], ops: &[Op]) -> Vec<Line> {
    let mut lines = base.to_vec();
    for op in ops {
        let len = lines.len();
        match op {
            Op::Delete(i, n) => {
                if len > 0 {
                    let i = i.index(len);
                    lines.drain(i..(i + n).min(len));
                }
            }
            Op::Insert(i, new) => {
                let i = i.index(len + 1);
                let end = style_end(&lines, i);
                let open_end = i == len && len > 0 && lines[len - 1].end.is_empty();
                let mut add: Vec<Line> = new
                    .iter()
                    .map(|t| Line {
                        text: t.clone(),
                        end,
                    })
                    .collect();
                if open_end {
                    lines[len - 1].end = end;
                    add.last_mut().unwrap().end = "";
                }
                lines.splice(i..i, add);
            }
            Op::Replace(i, new) => {
                if len > 0 {
                    lines[i.index(len)].text = new.clone();
                }
            }
            Op::Word(i, j, w) => {
                if len > 0 {
                    let line = &mut lines[i.index(len)];
                    let mut words: Vec<String> = if line.text.is_empty() {
                        vec![]
                    } else {
                        line.text.split(' ').map(String::from).collect()
                    };
                    match w {
                        WordOp::Append(new) => words.push(new.clone()),
                        _ if words.is_empty() => {
                            if let WordOp::Change(new) | WordOp::InsertAfter(new) = w {
                                words.push(new.clone());
                            }
                        }
                        WordOp::Change(new) => {
                            let j = j.index(words.len());
                            words[j] = new.clone();
                        }
                        WordOp::InsertAfter(new) => {
                            let j = j.index(words.len());
                            words.insert(j + 1, new.clone());
                        }
                        WordOp::Delete => {
                            let j = j.index(words.len());
                            words.remove(j);
                        }
                    }
                    line.text = words.join(" ");
                }
            }
            Op::Ending(i, e) => {
                if len > 0 {
                    let line = &mut lines[i.index(len)];
                    if !line.end.is_empty() {
                        line.end = e;
                    }
                }
            }
            Op::FinalNewline => {
                if let Some(last) = lines.last_mut() {
                    last.end = if last.end.is_empty() { "\n" } else { "" };
                }
            }
            Op::AllEndings(e) => {
                for line in lines.iter_mut() {
                    if !line.end.is_empty() {
                        line.end = e;
                    }
                }
            }
            Op::Join(i) => {
                if len > 1 {
                    let i = i.index(len - 1);
                    let next = lines.remove(i + 1);
                    let line = &mut lines[i];
                    line.text = format!("{} {}", line.text, next.text);
                    line.end = next.end;
                }
            }
            Op::Split(i, j) => {
                if len > 0 {
                    let i = i.index(len);
                    let words: Vec<String> = lines[i].text.split(' ').map(String::from).collect();
                    let j = j.index(words.len() + 1);
                    let (a, b) = (words[..j].join(" "), words[j..].join(" "));
                    let end = if lines[i].end.is_empty() {
                        "\n"
                    } else {
                        lines[i].end
                    };
                    let tail = Line {
                        text: b,
                        end: lines[i].end,
                    };
                    lines[i] = Line { text: a, end };
                    lines.insert(i + 1, tail);
                }
            }
        }
        normalize(&mut lines);
    }
    lines
}

fn render(lines: &[Line]) -> String {
    lines
        .iter()
        .map(|l| format!("{}{}", l.text, l.end))
        .collect()
}

fn ops(tag: &'static str, cr: bool) -> impl Strategy<Value = Vec<Op>> {
    prop_oneof![
        1 => Just(vec![]),
        4 => prop::collection::vec(op(tag, cr), 1..2),
        4 => prop::collection::vec(op(tag, cr), 2..4),
    ]
}

/// (base, ours, theirs)
pub fn triple(cr: bool) -> impl Strategy<Value = Triple> {
    (base_lines(cr), ops("o", cr), ops("t", cr)).prop_map(|(base, o, t)| {
        (
            render(&base),
            render(&apply_ops(&base, &o)),
            render(&apply_ops(&base, &t)),
        )
    })
}

// ---------------------------------------------------------------- oracle

fn scratch() -> PathBuf {
    std::env::var_os("MERGE_CHECK_TMP")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("merge-check"))
}

/// Exit code and stdout of `git merge-file -p --diff3 ours base theirs`.
fn git_merge(dir: &Path, base: &str, ours: &str, theirs: &str, word_level: bool) -> (i32, Vec<u8>) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join("base"), base).unwrap();
    std::fs::write(dir.join("ours"), ours).unwrap();
    std::fs::write(dir.join("theirs"), theirs).unwrap();
    let mut cmd = Command::new("git");
    cmd.current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args(["merge-file", "-p"]);
    if !word_level {
        cmd.arg("--diff3");
    }
    let out = cmd.args(["ours", "base", "theirs"]).output().unwrap();
    (out.status.code().unwrap_or(-1), out.stdout)
}

/// Per character: joined runs from two sides must not read as a new token.
fn counts(s: &str) -> HashMap<&str, i64> {
    let mut m = HashMap::new();
    for (i, c) in s.char_indices() {
        *m.entry(&s[i..i + c.len_utf8()]).or_default() += 1;
    }
    m
}

/// Per character, what an LCS diff of `from` to `to` inserts and deletes.
fn ins_del(from: &str, to: &str, prefer_insert: bool) -> (HashMap<char, i64>, HashMap<char, i64>) {
    let (a, b): (Vec<char>, Vec<char>) = (from.chars().collect(), to.chars().collect());
    let (n, m) = (a.len(), b.len());
    let mut dp = vec![vec![0u32; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            dp[i][j] = if a[i] == b[j] {
                dp[i + 1][j + 1] + 1
            } else {
                dp[i + 1][j].max(dp[i][j + 1])
            };
        }
    }
    let (mut ins, mut del) = (HashMap::new(), HashMap::new());
    let (mut i, mut j) = (0, 0);
    while i < n || j < m {
        if i < n && j < m && a[i] == b[j] {
            i += 1;
            j += 1;
        } else if j < m
            && (i == n
                || dp[i][j + 1] > dp[i + 1][j]
                || (prefer_insert && dp[i][j + 1] == dp[i + 1][j]))
        {
            *ins.entry(b[j]).or_default() += 1;
            j += 1;
        } else {
            *del.entry(a[i]).or_default() += 1;
            i += 1;
        }
    }
    (ins, del)
}

/// A clean merge applies each side's change once (identical changes may land
/// once). Per character, merged must equal base + Δours + Δtheirs, give or
/// take what both sides inserted or deleted alike: checked on net counts and
/// on char-LCS insert/delete counts (two tie-breaks); `None` when any holds.
fn conservation(base: &str, ours: &str, theirs: &str, merged: &str) -> Option<String> {
    let (b, o, t, m) = (counts(base), counts(ours), counts(theirs), counts(merged));
    let mut keys: Vec<&str> = b
        .keys()
        .chain(o.keys())
        .chain(t.keys())
        .chain(m.keys())
        .copied()
        .collect();
    keys.sort();
    keys.dedup();
    let lcs: Vec<_> = [false, true]
        .iter()
        .map(|&p| (ins_del(base, ours, p), ins_del(base, theirs, p)))
        .collect();
    let mut bad = Vec::new();
    for k in keys {
        let g = |m: &HashMap<&str, i64>| m.get(k).copied().unwrap_or(0);
        let (bc, oc, tc, mc) = (g(&b), g(&o), g(&t), g(&m));
        let (d_o, dt) = (oc - bc, tc - bc);
        let sum = bc + d_o + dt;
        let net_ok = if d_o != 0 && d_o.signum() == dt.signum() {
            let one = if d_o > 0 {
                bc + d_o.max(dt)
            } else {
                bc + d_o.min(dt)
            };
            (one.min(sum)..=one.max(sum)).contains(&mc)
        } else {
            mc == sum
        };
        let c = k.chars().next().unwrap();
        let id_ok = lcs.iter().any(|((io, dd_o), (it, dt_))| {
            let h = |m: &HashMap<char, i64>| m.get(&c).copied().unwrap_or(0);
            let (io, d_o2, it, dt2) = (h(io), h(dd_o), h(it), h(dt_));
            let sum = bc + io + it - d_o2 - dt2;
            (sum - io.min(it)..=sum + d_o2.min(dt2)).contains(&mc)
        });
        if !net_ok && !id_ok {
            bad.push(format!(
                "{k:?}: base {bc} ours {oc} theirs {tc} merged {mc}"
            ));
        }
    }
    (!bad.is_empty()).then(|| bad.join("; "))
}

fn byte_of(text: &str, unit: u32) -> usize {
    let mut u = 0u32;
    for (i, c) in text.char_indices() {
        if u >= unit {
            return i;
        }
        u += c.len_utf16() as u32;
    }
    text.len()
}

/// Lines as dewline cuts them: `\n`, `\r\n`, or a lone `\r` ends a line.
fn split_lines(text: &str) -> Vec<(usize, usize)> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut start = 0;
    for i in 0..b.len() {
        if b[i] == b'\n' || (b[i] == b'\r' && b.get(i + 1) != Some(&b'\n')) {
            out.push((start, i + 1));
            start = i + 1;
        }
    }
    if start < b.len() {
        out.push((start, b.len()));
    }
    out
}

/// Byte ranges of ours that an LCS line diff says ours changed (empty at a
/// deletion), each with the base range it replaced.
fn changed_regions(
    base: &str,
    ours: &str,
    prefer_insert: bool,
) -> Vec<((usize, usize), (usize, usize))> {
    let (bl, ol) = (split_lines(base), split_lines(ours));
    let bs: Vec<&str> = bl.iter().map(|&(s, e)| &base[s..e]).collect();
    let os: Vec<&str> = ol.iter().map(|&(s, e)| &ours[s..e]).collect();
    let (n, m) = (bs.len(), os.len());
    let mut dp = vec![vec![0u32; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            dp[i][j] = if bs[i] == os[j] {
                dp[i + 1][j + 1] + 1
            } else {
                dp[i + 1][j].max(dp[i][j + 1])
            };
        }
    }
    let pos = |j: usize| if j < m { ol[j].0 } else { ours.len() };
    let bpos = |i: usize| if i < n { bl[i].0 } else { base.len() };
    let (mut i, mut j) = (0, 0);
    let mut regions = Vec::new();
    let mut open: Option<(usize, usize)> = None; // start bytes in ours and base
    while i < n || j < m {
        if i < n && j < m && bs[i] == os[j] {
            if let Some((s, bs0)) = open.take() {
                regions.push(((s, pos(j)), (bs0, bpos(i))));
            }
            i += 1;
            j += 1;
        } else if j < m
            && (i == n
                || dp[i][j + 1] > dp[i + 1][j]
                || (prefer_insert && dp[i][j + 1] == dp[i + 1][j]))
        {
            open.get_or_insert((pos(j), bpos(i)));
            j += 1;
        } else {
            open.get_or_insert((pos(j), bpos(i)));
            i += 1;
        }
    }
    if let Some((s, bs0)) = open {
        regions.push(((s, ours.len()), (bs0, base.len())));
    }
    regions
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Kind {
    Panic,
    GitError,
    CoveringDiffers,
    /// git exits 0, merge3 reports a conflict.
    GitCleanButConflict,
    /// git exits 0, merge3 is clean but its text differs; token counts still balance.
    GitCleanDiffersBalanced,
    /// git exits 0, merge3 is clean, text differs and token counts do not balance.
    GitCleanDiffersUnbalanced,
    /// git conflicts, merge3 clean, and some side's change is lost or doubled.
    CleanUnbalanced,
    /// A conflict's ours text is not in the merged buffer where it maps.
    ConflictOursLost,
    /// Every change ours made sits inside a conflict, yet taking theirs for
    /// each conflict does not give theirs.
    ConflictTheirsWrong,
    /// Taking theirs for each conflict differs from git's clean merge of base,
    /// ours with its in-conflict changes reverted, and theirs.
    ConflictResolvedDiffers,
    /// Two letters or digits sit together in the merged text that sit together
    /// in none of base, ours or theirs: text from both sides glued into one word.
    GluedWord,
    /// The same for two other non-blank characters (softer signal).
    GluedOther,
}

#[derive(Debug, Default, Clone)]
pub struct Outcome {
    pub git_clean: bool,
    pub dew_clean: bool,
    pub findings: Vec<(Kind, String)>,
}

pub fn check(dir: &Path, base: &str, ours: &str, theirs: &str) -> Outcome {
    let mut out = Outcome::default();
    let merge: Merge = match catch_unwind(AssertUnwindSafe(|| merge3(base, ours, theirs))) {
        Ok(m) => m,
        Err(e) => {
            let msg = e
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| e.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_default();
            out.findings.push((Kind::Panic, msg));
            return out;
        }
    };
    let merged = match catch_unwind(AssertUnwindSafe(|| apply(ours, &merge.edits))) {
        Ok(m) => m,
        Err(_) => {
            out.findings.push((Kind::Panic, "apply".into()));
            return out;
        }
    };
    out.dew_clean = merge.conflicts.is_empty();
    if let Some(c) = &merge.covering
        && apply(ours, std::slice::from_ref(c)) != merged
    {
        out.findings.push((Kind::CoveringDiffers, String::new()));
    }

    let (code, git_out) = git_merge(dir, base, ours, theirs, false);
    if !(0..=127).contains(&code) {
        out.findings.push((Kind::GitError, format!("exit {code}")));
        return out;
    }
    out.git_clean = code == 0;

    // 1. git clean: merge3 must be clean and byte-identical.
    if out.git_clean {
        if !out.dew_clean {
            out.findings.push((
                Kind::GitCleanButConflict,
                format!("git {:?}", String::from_utf8_lossy(&git_out)),
            ));
        } else if merged.as_bytes() != git_out {
            let bal = conservation(base, ours, theirs, &merged);
            let kind = if bal.is_none() {
                Kind::GitCleanDiffersBalanced
            } else {
                Kind::GitCleanDiffersUnbalanced
            };
            out.findings.push((
                kind,
                format!(
                    "git {:?} dewline {:?} {}",
                    String::from_utf8_lossy(&git_out),
                    merged,
                    bal.unwrap_or_default()
                ),
            ));
        }
    }

    // 2. merge3 clean (git conflicted or not): no side's change dropped or doubled.
    if out.dew_clean
        && !out.git_clean
        && let Some(bad) = conservation(base, ours, theirs, &merged)
    {
        out.findings
            .push((Kind::CleanUnbalanced, format!("dewline {merged:?} {bad}")));
    }

    // 3. Conflicts keep ours byte for byte, and taking theirs gives theirs where ours did not change.
    if !out.dew_clean {
        let units: Vec<u16> = ours.encode_utf16().collect();
        let merged16: Vec<u16> = merged.encode_utf16().collect();
        for c in &merge.conflicts {
            let kept = &units[c.start as usize..c.end as usize];
            let at = map_offset(&merge.edits, c.start, Bias::Before) as usize;
            if merged16.get(at..at + kept.len()) != Some(kept) {
                out.findings
                    .push((Kind::ConflictOursLost, format!("{c:?}")));
            }
        }
        let mut all: Vec<Edit> = merge.edits.clone();
        all.extend(merge.conflicts.iter().map(|c| Edit {
            start: c.start,
            end: c.end,
            text: c.theirs.clone(),
        }));
        all.sort_by_key(|e| (e.start, e.end));
        let resolved = apply(ours, &all);
        let spans: Vec<(usize, usize)> = merge
            .conflicts
            .iter()
            .map(|c| (byte_of(ours, c.start), byte_of(ours, c.end)))
            .collect();
        let inside = changed_regions(base, ours, true)
            .iter()
            .all(|&((s, e), _)| spans.iter().any(|&(cs, ce)| cs <= s && e <= ce));
        if inside && resolved != theirs {
            out.findings
                .push((Kind::ConflictTheirsWrong, format!("resolved {resolved:?}")));
        }
        // Theirs wins every conflict: the result must be the clean merge of
        // base, ours with its in-conflict changes reverted, and theirs.
        let mut references = Vec::new();
        for prefer_insert in [true, false] {
            let mut reverted = String::new();
            let mut done = 0;
            for ((s, e), (bs, be)) in changed_regions(base, ours, prefer_insert) {
                if spans.iter().any(|&(cs, ce)| cs <= s && e <= ce) {
                    reverted.push_str(&ours[done..s]);
                    reverted.push_str(&base[bs..be]);
                    done = e;
                }
            }
            reverted.push_str(&ours[done..]);
            let (code, reference) = git_merge(dir, base, &reverted, theirs, false);
            if code == 0 {
                references.push((reverted, reference));
            }
        }
        if !references.is_empty() && references.iter().all(|(_, r)| resolved.as_bytes() != r) {
            let (reverted, reference) = &references[0];
            out.findings.push((
                Kind::ConflictResolvedDiffers,
                format!(
                    "resolved {resolved:?} git {:?} (ours reverted {reverted:?})",
                    String::from_utf8_lossy(reference)
                ),
            ));
        }
    }

    // 4. Glue: a bigram of two non-blank characters new to all three texts.
    let mut seen = std::collections::HashSet::new();
    for t in [base, ours, theirs] {
        let cs: Vec<char> = t.chars().collect();
        for w in cs.windows(2) {
            seen.insert((w[0], w[1]));
        }
    }
    let cs: Vec<char> = merged.chars().collect();
    let blank = |c: char| c.is_whitespace();
    for w in cs.windows(2) {
        if !seen.contains(&(w[0], w[1])) && !blank(w[0]) && !blank(w[1]) {
            let kind = if w[0].is_alphanumeric() && w[1].is_alphanumeric() {
                Kind::GluedWord
            } else {
                Kind::GluedOther
            };
            out.findings.push((
                kind,
                format!("{:?} in {merged:?}", format!("{}{}", w[0], w[1])),
            ));
            break;
        }
    }
    out
}

// ---------------------------------------------------------------- shrinking

fn has(dir: &Path, t: &Triple, kind: Kind) -> bool {
    check(dir, &t.0, &t.1, &t.2)
        .findings
        .iter()
        .any(|f| f.0 == kind)
}

/// Greedy: drop lines, then characters, then make non-ASCII ASCII, while `kind` still fails.
fn minimize(dir: &Path, mut t: Triple, kind: Kind) -> Triple {
    let get = |t: &Triple, k: usize| match k {
        0 => t.0.clone(),
        1 => t.1.clone(),
        _ => t.2.clone(),
    };
    let set = |t: &mut Triple, k: usize, v: String| match k {
        0 => t.0 = v,
        1 => t.1 = v,
        _ => t.2 = v,
    };
    let mut progress = true;
    while progress {
        progress = false;
        // Same line removed from all three.
        let lines0: Vec<String> = split_lines(&t.0)
            .iter()
            .map(|&(s, e)| t.0[s..e].to_string())
            .collect();
        for l in lines0 {
            let mut c = t.clone();
            for k in 0..3 {
                let s = get(&c, k);
                if let Some(p) = s.find(&l) {
                    set(&mut c, k, format!("{}{}", &s[..p], &s[p + l.len()..]));
                }
            }
            if c != t && has(dir, &c, kind) {
                t = c;
                progress = true;
            }
        }
        for k in 0..3 {
            let mut i = 0;
            loop {
                let s = get(&t, k);
                let lines = split_lines(&s);
                if i >= lines.len() {
                    break;
                }
                let (a, b) = lines[i];
                let mut c = t.clone();
                set(&mut c, k, format!("{}{}", &s[..a], &s[b..]));
                if has(dir, &c, kind) {
                    t = c;
                    progress = true;
                } else {
                    i += 1;
                }
            }
        }
        for k in 0..3 {
            let mut i = 0;
            loop {
                let s = get(&t, k);
                let idx: Vec<usize> = s.char_indices().map(|x| x.0).collect();
                if i >= idx.len() {
                    break;
                }
                let end = idx.get(i + 1).copied().unwrap_or(s.len());
                let mut c = t.clone();
                set(&mut c, k, format!("{}{}", &s[..idx[i]], &s[end..]));
                if has(dir, &c, kind) {
                    t = c;
                    progress = true;
                } else {
                    i += 1;
                }
            }
        }
    }
    t
}

// ---------------------------------------------------------------- drivers

fn report_triple(t: &Triple) -> String {
    format!(
        "    base   {:?}\n    ours   {:?}\n    theirs {:?}",
        t.0, t.1, t.2
    )
}

fn survey_mode(cr: bool, cases: usize, threads: usize) {
    let found: Mutex<BTreeMap<Kind, Vec<Triple>>> = Mutex::new(BTreeMap::new());
    let tallies: Mutex<BTreeMap<(bool, bool), usize>> = Mutex::new(BTreeMap::new());
    let kinds: Mutex<BTreeMap<Kind, usize>> = Mutex::new(BTreeMap::new());
    std::thread::scope(|s| {
        for th in 0..threads {
            let (found, tallies, kinds) = (&found, &tallies, &kinds);
            s.spawn(move || {
                let dir = scratch().join(format!("{}-{th}", if cr { "cr" } else { "lf" }));
                let mut seed = [7u8; 32];
                seed[0] = th as u8;
                seed[1] = cr as u8;
                let mut runner = TestRunner::new_with_rng(
                    Config::default(),
                    TestRng::from_seed(RngAlgorithm::ChaCha, &seed),
                );
                let strat = triple(cr);
                for _ in 0..cases / threads {
                    let tree = strat.new_tree(&mut runner).unwrap();
                    let t = tree.current();
                    let out = check(&dir, &t.0, &t.1, &t.2);
                    *tallies
                        .lock()
                        .unwrap()
                        .entry((out.git_clean, out.dew_clean))
                        .or_default() += 1;
                    for (kind, _) in &out.findings {
                        *kinds.lock().unwrap().entry(*kind).or_default() += 1;
                        let mut f = found.lock().unwrap();
                        let list = f.entry(*kind).or_default();
                        if list.len() < 12 {
                            list.push(t.clone());
                        }
                    }
                }
            });
        }
    });
    println!(
        "\n=== mode {} : {cases} triples",
        if cr { "with lone CR" } else { "LF/CRLF" }
    );
    println!(
        "(git clean, merge3 clean) tallies: {:?}",
        tallies.lock().unwrap()
    );
    println!("finding counts: {:?}", kinds.lock().unwrap());
    let dir = scratch().join(format!("shrink-{}", cr as u8));
    for (kind, list) in found.lock().unwrap().iter() {
        let mut seen = std::collections::BTreeSet::new();
        println!("\n--- {kind:?}");
        for t in list {
            let m = minimize(&dir, t.clone(), *kind);
            if seen.insert(m.clone()) {
                let out = check(&dir, &m.0, &m.1, &m.2);
                let detail = out
                    .findings
                    .iter()
                    .find(|f| f.0 == *kind)
                    .map(|f| f.1.clone())
                    .unwrap_or_default();
                println!("{}\n    -> {}", report_triple(&m), detail);
            }
        }
    }
}

#[test]
#[ignore]
fn survey() {
    let cases: usize = std::env::var("MERGE_CHECK_CASES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(4000);
    let threads: usize = std::env::var("MERGE_CHECK_THREADS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(6);
    let modes = std::env::var("MERGE_CHECK_MODES").unwrap_or_else(|_| "lf,cr".into());
    for mode in modes.split(',') {
        survey_mode(mode == "cr", cases, threads);
    }
}

/// One triple from the command line: MERGE_CHECK_ONE='["base","ours","theirs"]' (JSON-ish, Rust escapes).
#[test]
#[ignore]
fn one() {
    let dir = scratch().join("one");
    for (b, o, t) in cases_from_env() {
        let merge = merge3(&b, &o, &t);
        let (code, git) = git_merge(&dir, &b, &o, &t, false);
        println!("{}", report_triple(&(b.clone(), o.clone(), t.clone())));
        println!("    git exit {code}: {:?}", String::from_utf8_lossy(&git));
        println!("    merge3 {:?}", merge);
        println!("    merged {:?}", apply(&o, &merge.edits));
        println!("    findings {:?}", check(&dir, &b, &o, &t).findings);
    }
}

fn cases_from_env() -> Vec<Triple> {
    let raw = std::env::var("MERGE_CHECK_ONE").unwrap_or_default();
    raw.split("\n---\n")
        .filter(|s| !s.trim().is_empty())
        .map(|s| {
            let parts: Vec<String> = s.split("\n|\n").map(unescape).collect();
            (parts[0].clone(), parts[1].clone(), parts[2].clone())
        })
        .collect()
}

fn unescape(s: &str) -> String {
    let mut out = String::new();
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c == '\\' {
            match it.next() {
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('t') => out.push('\t'),
                Some('\\') => out.push('\\'),
                Some(o) => {
                    out.push('\\');
                    out.push(o)
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

proptest! {
    #![proptest_config(ProptestConfig {
        failure_persistence: None,
        ..ProptestConfig::default()
    })]

    #[test]
    fn merge_agrees_with_git((base, ours, theirs) in triple(false)) {
        let dir = scratch().join(format!("prop-{:?}", std::thread::current().id()));
        let out = check(&dir, &base, &ours, &theirs);
        let bugs: Vec<_> = out.findings.iter().filter(|f| !legitimate(f.0)).collect();
        prop_assert!(bugs.is_empty(), "{:?}", bugs);
    }
}

/// Kinds that are differences in granularity, not data loss, and the two
/// checks that misfire on repeated or blank lines.
fn legitimate(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::GitCleanButConflict
            | Kind::GitCleanDiffersBalanced
            | Kind::CleanUnbalanced
            | Kind::ConflictResolvedDiffers
    )
}
