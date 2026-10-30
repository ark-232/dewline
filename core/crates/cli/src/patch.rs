//! Codex's `apply_patch`, far enough to name the files a patch touches and the text it leaves in each. Ported from
//! openai/codex, codex-rs/apply-patch at 970111f6 (parser.rs, streaming_parser.rs, seek_sequence.rs,
//! file_update.rs, text_file.rs), Copyright 2025 OpenAI, under the Apache License 2.0; THIRD_PARTY_NOTICES.md
//! carries the notice. Nothing here touches a file.

const BEGIN_PATCH: &str = "*** Begin Patch";
const END_PATCH: &str = "*** End Patch";
const ADD_FILE: &str = "*** Add File: ";
const DELETE_FILE: &str = "*** Delete File: ";
const UPDATE_FILE: &str = "*** Update File: ";
const MOVE_TO: &str = "*** Move to: ";
const END_OF_FILE: &str = "*** End of File";
const CHANGE_CONTEXT: &str = "@@ ";
const EMPTY_CHANGE_CONTEXT: &str = "@@";
const ENVIRONMENT_ID: &str = "*** Environment ID:";

#[derive(Debug, PartialEq)]
pub enum Hunk {
    Add {
        path: String,
        contents: String,
    },
    Delete {
        path: String,
    },
    Update {
        path: String,
        move_path: Option<String>,
        chunks: Vec<Chunk>,
    },
}

impl Hunk {
    /// The paths the hunk names, as written in the patch.
    pub fn paths(&self) -> impl Iterator<Item = &str> {
        let (path, move_path) = match self {
            Hunk::Add { path, .. } | Hunk::Delete { path } => (path, None),
            Hunk::Update {
                path, move_path, ..
            } => (path, move_path.as_ref()),
        };
        [Some(path), move_path]
            .into_iter()
            .flatten()
            .map(String::as_str)
    }
}

#[derive(Debug, Default, PartialEq)]
pub struct Chunk {
    context: Option<String>,
    old_lines: Vec<String>,
    new_lines: Vec<String>,
    /// Indices into `old_lines` and `new_lines` of the lines parsed as context.
    context_lines: Vec<(usize, usize)>,
    end_of_file: bool,
}

impl Chunk {
    fn push_context(&mut self, line: String) {
        self.context_lines
            .push((self.old_lines.len(), self.new_lines.len()));
        self.old_lines.push(line.clone());
        self.new_lines.push(line);
    }
}

/// The hunks of `patch` as Codex reads it, leniently: markers may carry surrounding whitespace and the patch may
/// come wrapped in a heredoc. None for a patch Codex refuses, and for one that names an environment, whose paths
/// belong to another machine's folders.
pub fn parse(patch: &str) -> Option<Vec<Hunk>> {
    let lines: Vec<&str> = patch.trim().lines().collect();
    let lines = match bounded(&lines) {
        true => &lines[..],
        false => match lines[..] {
            [first, .., last]
                if ["<<EOF", "<<'EOF'", "<<\"EOF\""].contains(&first)
                    && last.ends_with("EOF")
                    && lines.len() >= 4
                    && bounded(&lines[1..lines.len() - 1]) =>
            {
                &lines[1..lines.len() - 1]
            }
            _ => return None,
        },
    };
    let text = lines.join("\n");
    let mut parser = Parser::default();
    let mut segments = text.split('\n').peekable();
    while let Some(segment) = segments.next() {
        if segments.peek().is_some() {
            parser.line(segment.strip_suffix('\r').unwrap_or(segment))?;
        } else if !segment.is_empty() {
            if segment.trim() == END_PATCH {
                parser.not_empty()?;
                parser.mode = Mode::Ended;
            } else {
                parser.line(segment)?;
            }
        }
    }
    (parser.mode == Mode::Ended && !parser.environment).then_some(parser.hunks)
}

fn bounded(lines: &[&str]) -> bool {
    matches!(lines, [first, .., last] if first.trim() == BEGIN_PATCH && last.trim() == END_PATCH)
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
enum Mode {
    #[default]
    NotStarted,
    Started,
    Add,
    Delete,
    Update,
    Ended,
}

#[derive(Default)]
struct Parser {
    mode: Mode,
    hunks: Vec<Hunk>,
    environment: bool,
}

impl Parser {
    /// None when the last hunk is an Update with nothing in it.
    fn not_empty(&self) -> Option<()> {
        if let Some(Hunk::Update { chunks, .. }) = self.hunks.last() {
            if chunks.is_empty() && self.mode == Mode::Update {
                return None;
            }
            if chunks
                .last()
                .is_some_and(|chunk| chunk.old_lines.is_empty() && chunk.new_lines.is_empty())
            {
                return None;
            }
        }
        Some(())
    }

    /// A hunk header or the end marker: Some(true) when `trimmed` is one.
    fn header(&mut self, trimmed: &str) -> Option<bool> {
        if self.mode == Mode::Started
            && let Some(id) = trimmed.strip_prefix(ENVIRONMENT_ID)
        {
            if self.environment || id.trim().is_empty() {
                return None;
            }
            self.environment = true;
            return Some(true);
        }
        let (hunk, mode) = if trimmed == END_PATCH {
            self.not_empty()?;
            self.mode = Mode::Ended;
            return Some(true);
        } else if let Some(path) = trimmed.strip_prefix(ADD_FILE) {
            let contents = String::new();
            let path = path.to_owned();
            (Hunk::Add { path, contents }, Mode::Add)
        } else if let Some(path) = trimmed.strip_prefix(DELETE_FILE) {
            let path = path.to_owned();
            (Hunk::Delete { path }, Mode::Delete)
        } else if let Some(path) = trimmed.strip_prefix(UPDATE_FILE) {
            let (path, move_path, chunks) = (path.to_owned(), None, Vec::new());
            let hunk = Hunk::Update {
                path,
                move_path,
                chunks,
            };
            (hunk, Mode::Update)
        } else {
            return Some(false);
        };
        self.not_empty()?;
        self.hunks.push(hunk);
        self.mode = mode;
        Some(true)
    }

    fn line(&mut self, line: &str) -> Option<()> {
        let trimmed = line.trim();
        match self.mode {
            Mode::NotStarted => {
                (trimmed == BEGIN_PATCH).then_some(())?;
                self.mode = Mode::Started;
                Some(())
            }
            Mode::Started | Mode::Delete => self.header(trimmed)?.then_some(()),
            Mode::Add => {
                if self.header(trimmed)? {
                    return Some(());
                }
                let added = line.strip_prefix('+')?;
                let Some(Hunk::Add { contents, .. }) = self.hunks.last_mut() else {
                    return None;
                };
                contents.push_str(added);
                contents.push('\n');
                Some(())
            }
            Mode::Update => self.update(line),
            Mode::Ended => trimmed.is_empty().then_some(()),
        }
    }

    fn update(&mut self, line: &str) -> Option<()> {
        let update = line.trim_end();
        if self.header(update)? {
            return Some(());
        }
        let Some(Hunk::Update {
            move_path, chunks, ..
        }) = self.hunks.last_mut()
        else {
            return None;
        };
        let context_marker = update == EMPTY_CHANGE_CONTEXT || update.starts_with(CHANGE_CONTEXT);
        if chunks.last().is_some_and(|chunk| chunk.end_of_file) {
            if update.is_empty() {
                return Some(());
            }
            if !context_marker {
                return None;
            }
        }
        if chunks.is_empty()
            && move_path.is_none()
            && let Some(to) = update.strip_prefix(MOVE_TO)
        {
            *move_path = Some(to.to_owned());
            return Some(());
        }
        let last_empty = chunks
            .last()
            .is_some_and(|chunk| chunk.old_lines.is_empty() && chunk.new_lines.is_empty());
        if context_marker && last_empty {
            return None;
        }
        if update == EMPTY_CHANGE_CONTEXT {
            chunks.push(Chunk::default());
            return Some(());
        }
        if let Some(context) = update.strip_prefix(CHANGE_CONTEXT) {
            chunks.push(Chunk {
                context: Some(context.to_owned()),
                ..Chunk::default()
            });
            return Some(());
        }
        if update == END_OF_FILE {
            if last_empty {
                return None;
            }
            if let Some(chunk) = chunks.last_mut() {
                chunk.end_of_file = true;
            }
            return Some(());
        }
        let (kind, rest) = match line.chars().next() {
            None => (' ', ""),
            Some(kind @ (' ' | '+' | '-')) => (kind, &line[1..]),
            Some(_) => return None,
        };
        if chunks.is_empty() {
            chunks.push(Chunk::default());
        }
        let chunk = chunks.last_mut()?;
        match kind {
            ' ' => chunk.push_context(rest.to_owned()),
            '+' => chunk.new_lines.push(rest.to_owned()),
            _ => chunk.old_lines.push(rest.to_owned()),
        }
        Some(())
    }
}

/// The text an Update hunk's `chunks` leave of `original`, or None where Codex can't place a chunk.
pub fn update(original: &str, chunks: &[Chunk]) -> Option<String> {
    let mut source = SourceFile::parse(original);
    let lines: Vec<&str> = source.lines.iter().map(|line| line.text.as_str()).collect();
    let replacements = replacements(&lines, chunks)?;
    source.apply(replacements);
    Some(source.contents())
}

type Replacement = (usize, usize, Vec<String>);

fn replacements(lines: &[&str], chunks: &[Chunk]) -> Option<Vec<Replacement>> {
    let mut replacements = Vec::new();
    let mut index = 0;
    for chunk in chunks {
        if let Some(context) = &chunk.context {
            index = seek(lines, &[context.as_str()], index, false)? + 1;
        }
        if chunk.old_lines.is_empty() {
            replacements.push((lines.len(), 0, chunk.new_lines.clone()));
            continue;
        }
        let mut pattern: Vec<&str> = chunk.old_lines.iter().map(String::as_str).collect();
        let mut new_lines = &chunk.new_lines[..];
        let mut found = seek(lines, &pattern, index, chunk.end_of_file);
        if found.is_none() && pattern.last().is_some_and(|line| line.is_empty()) {
            pattern.pop();
            if new_lines.last().is_some_and(String::is_empty) {
                new_lines = &new_lines[..new_lines.len() - 1];
            }
            found = seek(lines, &pattern, index, chunk.end_of_file);
        }
        let start = found?;
        let (mut old_start, mut new_start) = (0, 0);
        for &(old_context, new_context) in &chunk.context_lines {
            if old_context >= pattern.len() || new_context >= new_lines.len() {
                break;
            }
            if old_start != old_context || new_start != new_context {
                replacements.push((
                    start + old_start,
                    old_context - old_start,
                    new_lines[new_start..new_context].to_vec(),
                ));
            }
            old_start = old_context + 1;
            new_start = new_context + 1;
        }
        if old_start != pattern.len() || new_start != new_lines.len() {
            replacements.push((
                start + old_start,
                pattern.len() - old_start,
                new_lines[new_start..].to_vec(),
            ));
        }
        index = start + pattern.len();
    }
    replacements.sort_by_key(|(index, _, _)| *index);
    Some(replacements)
}

/// Where `pattern` starts in `lines` at or after `start`, matched exactly, then ignoring trailing whitespace, then
/// ignoring both ends' whitespace, then with typographic punctuation read as ASCII. With `eof`, only a match that
/// ends at the end of `lines` counts.
fn seek(lines: &[&str], pattern: &[&str], start: usize, eof: bool) -> Option<usize> {
    if pattern.is_empty() {
        return Some(start);
    }
    if pattern.len() > lines.len() {
        return None;
    }
    let last = lines.len() - pattern.len();
    let from = if eof { last.max(start) } else { start };
    let passes: [fn(&str, &str) -> bool; 4] = [
        |a, b| a == b,
        |a, b| a.trim_end() == b.trim_end(),
        |a, b| a.trim() == b.trim(),
        |a, b| normalise(a).eq(normalise(b)),
    ];
    passes.into_iter().find_map(|same| {
        (from..=last).find(|&i| {
            pattern
                .iter()
                .enumerate()
                .all(|(j, p)| same(lines[i + j], p))
        })
    })
}

fn normalise(line: &str) -> impl Iterator<Item = char> + '_ {
    line.trim().chars().map(|c| match c {
        '\u{2010}' | '\u{2011}' | '\u{2012}' | '\u{2013}' | '\u{2014}' | '\u{2015}'
        | '\u{2212}' => '-',
        '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}' => '\'',
        '\u{201C}' | '\u{201D}' | '\u{201E}' | '\u{201F}' => '"',
        '\u{00A0}' | '\u{2002}' | '\u{2003}' | '\u{2004}' | '\u{2005}' | '\u{2006}'
        | '\u{2007}' | '\u{2008}' | '\u{2009}' | '\u{200A}' | '\u{202F}' | '\u{205F}'
        | '\u{3000}' => ' ',
        other => other,
    })
}

struct SourceLine {
    text: String,
    ending: Option<&'static str>,
}

/// A file's lines, each with its own ending.
struct SourceFile {
    lines: Vec<SourceLine>,
    /// The first ending in the file, LF in one without any; inserted lines take it.
    ending: &'static str,
}

impl SourceFile {
    fn parse(contents: &str) -> SourceFile {
        let bytes = contents.as_bytes();
        let (mut lines, mut ending, mut start, mut cursor) = (Vec::new(), None, 0, 0);
        while cursor < bytes.len() {
            let (end, length) = match bytes[cursor] {
                b'\r' if bytes.get(cursor + 1) == Some(&b'\n') => ("\r\n", 2),
                b'\r' => ("\r", 1),
                b'\n' => ("\n", 1),
                _ => {
                    cursor += 1;
                    continue;
                }
            };
            ending.get_or_insert(end);
            lines.push(SourceLine {
                text: contents[start..cursor].to_owned(),
                ending: Some(end),
            });
            cursor += length;
            start = cursor;
        }
        if start < contents.len() {
            lines.push(SourceLine {
                text: contents[start..].to_owned(),
                ending: None,
            });
        }
        SourceFile {
            lines,
            ending: ending.unwrap_or("\n"),
        }
    }

    /// Applies sorted, non-overlapping replacements. Every line then ends, as Codex's updates always have.
    fn apply(&mut self, replacements: Vec<Replacement>) {
        let mut source = std::mem::take(&mut self.lines).into_iter();
        let (mut lines, mut index) = (Vec::new(), 0);
        for (start, old, new) in replacements {
            lines.extend(source.by_ref().take(start.saturating_sub(index)));
            source.by_ref().take(old).for_each(drop);
            lines.extend(new.into_iter().map(|text| SourceLine {
                text,
                ending: Some(self.ending),
            }));
            index = start + old;
        }
        lines.extend(source);
        for line in &mut lines {
            line.ending.get_or_insert(self.ending);
        }
        self.lines = lines;
    }

    fn contents(self) -> String {
        let mut contents = String::new();
        for line in self.lines {
            contents.push_str(&line.text);
            contents.push_str(line.ending.unwrap_or(""));
        }
        contents
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn patch(body: &str) -> String {
        format!("*** Begin Patch\n{body}*** End Patch")
    }

    fn updated(original: &str, body: &str) -> Option<String> {
        let hunks = parse(&patch(&format!("*** Update File: f.md\n{body}")))?;
        let [Hunk::Update { chunks, .. }] = &hunks[..] else {
            panic!("{hunks:?}")
        };
        update(original, chunks)
    }

    #[test]
    fn parses_each_header_kind() {
        let hunks = parse(&patch(
            "*** Add File: notes/new.md\n+one\n+two\n*** Delete File: old.md\n*** Update File: plan.md\n\
             *** Move to: done/plan.md\n@@ ## Steps\n-ship\n+ship it\n",
        ))
        .unwrap();
        assert_eq!(
            hunks[0],
            Hunk::Add {
                path: "notes/new.md".into(),
                contents: "one\ntwo\n".into()
            }
        );
        assert_eq!(
            hunks[1],
            Hunk::Delete {
                path: "old.md".into()
            }
        );
        let paths: Vec<_> = hunks.iter().flat_map(Hunk::paths).collect();
        assert_eq!(paths, ["notes/new.md", "old.md", "plan.md", "done/plan.md"]);
    }

    #[test]
    fn reads_patches_as_leniently_as_codex() {
        let body = "*** Add File: a.md\n+a\n";
        for text in [
            patch(body),
            format!("  {}  \n\n", patch(body)),
            format!("<<'EOF'\n{}\nEOF\n", patch(body)),
            format!("<<EOF\n{}\nEOF", patch(body)),
            patch(body).replace('\n', "\r\n"),
            patch("*** Update File: f.md\n@@\n+quux\n*** End of File\n\n"),
        ] {
            assert_eq!(parse(&text).map(|hunks| hunks.len()), Some(1), "{text:?}");
        }
        for text in [
            "*** Add File: a.md\n+a\n*** End Patch".to_owned(),
            "*** Begin Patch\n*** Add File: a.md\n+a\n".to_owned(),
            patch("*** Frobnicate File: a.md\n"),
            patch("*** Update File: a.md\n"),
            patch("*** Update File: a.md\n@@\n"),
            patch("*** Update File: a.md\nno prefix\n"),
            patch("*** Add File: a.md\nno plus\n"),
            patch("*** Environment ID: remote\n*** Add File: a.md\n+a\n"),
            format!("<<\"EOF'\n{}\nEOF\n", patch(body)),
            "<<EOF\n*** Begin Patch\n*** Update File: f.md\nEOF\n".to_owned(),
        ] {
            assert_eq!(parse(&text), None, "{text:?}");
        }
        assert_eq!(parse(&patch("")), Some(vec![]));
    }

    #[test]
    fn updates_match_exactly_then_ever_more_loosely() {
        // Exact, trailing whitespace, both ends, then typographic punctuation.
        assert_eq!(
            updated("a\nb\nc\n", "@@\n a\n-b\n+B\n").as_deref(),
            Some("a\nB\nc\n")
        );
        assert_eq!(
            updated("a  \nb\t\n", "@@\n a\n-b\n+B\n").as_deref(),
            Some("a  \nB\n")
        );
        assert_eq!(
            updated("  a\n  b\n", "@@\n a\n-b\n+  B\n").as_deref(),
            Some("  a\n  B\n")
        );
        assert_eq!(
            updated(
                "Use \u{201C}dew\u{201D} \u{2014} it\u{2019}s fast\n",
                "@@\n-Use \"dew\" - it's fast\n+Use dew\n"
            )
            .as_deref(),
            Some("Use dew\n")
        );
        // A chunk Codex can't place fails the update.
        assert_eq!(updated("a\nb\n", "@@\n-x\n+y\n"), None);
    }

    #[test]
    fn chunks_apply_in_order_down_the_file() {
        // Codex's own test_unified_diff_interleaved_changes.
        let body = "@@\n a\n-b\n+B\n@@\n d\n-e\n+E\n@@\n f\n+g\n*** End of File\n";
        assert_eq!(
            updated("a\nb\nc\nd\ne\nf\n", body).as_deref(),
            Some("a\nB\nc\nd\nE\nf\ng\n")
        );
        // The search for a chunk's lines starts after its @@ context line.
        assert_eq!(
            updated("x\n## A\nx\n", "@@ ## A\n-x\n+y\n").as_deref(),
            Some("x\n## A\ny\n")
        );
    }

    #[test]
    fn updates_keep_line_endings_and_end_every_line() {
        assert_eq!(
            updated("a\r\nb\r\n", "@@\n a\n+x\n b\n").as_deref(),
            Some("a\r\nx\r\nb\r\n")
        );
        assert_eq!(updated("a\nb", "@@\n-b\n+c\n").as_deref(), Some("a\nc\n"));
        assert_eq!(updated("a\n", "@@\n+tail\n").as_deref(), Some("a\ntail\n"));
        assert_eq!(
            updated("x\ny\nx\n", "@@\n-x\n+z\n*** End of File\n").as_deref(),
            Some("x\ny\nz\n")
        );
        assert_eq!(
            updated("# T\n## A\nx\n## B\nx\n", "@@ ## B\n-x\n+y\n").as_deref(),
            Some("# T\n## A\nx\n## B\ny\n")
        );
    }
}
