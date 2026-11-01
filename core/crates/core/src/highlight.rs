//! Code highlighting for fenced blocks (record 0008). One worker thread owns syntect's syntaxes and each block's
//! per-line parse states, so an edit reparses a block from its first changed line. Diff and markdown blocks are
//! highlighted here without syntect. Spans come back as token classes in UTF-16 offsets; the app picks the colors.

use std::collections::HashMap;
use std::panic::{self, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use syntect::parsing::{ParseState, Scope, ScopeStack, SyntaxSet};

use crate::md::{self, TokenKind};

/// What a span of code is. The app maps each class to a theme color.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Class {
    Comment = 1,
    String,
    Escape,
    Number,
    Constant,
    Keyword,
    Operator,
    Type,
    Function,
    Tag,
    Attribute,
    Inserted,
    Deleted,
    Heading,
}

/// UTF-16 offsets in the block's text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: u32,
    pub end: u32,
    pub class: Class,
}

/// A line with more scope changes than this stays plain: the guard against patterns that split a line into a token
/// per character (the mdmost PR #21 budget).
pub const LINE_TOKENS: usize = 2_000;
/// A line longer than this in UTF-8 bytes is not parsed.
pub const LINE_BYTES: usize = 16_384;
/// A line whose parse takes longer than this stays plain, and so does the rest of its block.
pub const LINE_TIME: Duration = Duration::from_millis(30);
/// The blocks whose line states the worker keeps.
const CACHED_BLOCKS: usize = 256;

enum Job {
    Highlight {
        block: u64,
        generation: u64,
        language: String,
        text: String,
        reply: Sender<Option<Vec<Span>>>,
    },
    Forget(u64),
}

/// The worker's handle. Each call to `highlight` waits for the worker, so the app calls it off the main thread.
pub struct Highlighter {
    jobs: Mutex<Sender<Job>>,
    /// The newest request's generation for each block; an older request still queued or running comes back `None`.
    latest: Arc<Mutex<HashMap<u64, u64>>>,
}

impl Highlighter {
    /// Starts the worker, which loads the syntaxes at `dump` (an uncompressed newline dump) before its first block.
    /// Without them every language but diff and markdown stays plain.
    pub fn new(dump: PathBuf) -> Self {
        let (jobs, inbox) = mpsc::channel();
        let latest = Arc::new(Mutex::new(HashMap::new()));
        let shared = latest.clone();
        std::thread::Builder::new()
            .name("dewline-highlight".into())
            .spawn(move || Worker::new(dump, shared).run(inbox))
            .expect("spawn the highlight worker");
        Self {
            jobs: Mutex::new(jobs),
            latest,
        }
    }

    /// The spans of `text`, a fenced block's content in `language` (its info string's first word), or `None` when a
    /// newer request for `block` or a `forget` overtook this one. `block` is any id the caller keeps for the block:
    /// the worker reuses its line states for the lines that did not change since the last request with that id.
    pub fn highlight(&self, block: u64, language: &str, text: &str) -> Option<Vec<Span>> {
        let generation = {
            let mut latest = self.latest.lock().unwrap();
            let next = latest.get(&block).map_or(1, |generation| generation + 1);
            latest.insert(block, next);
            next
        };
        let (reply, answer) = mpsc::channel();
        self.jobs
            .lock()
            .unwrap()
            .send(Job::Highlight {
                block,
                generation,
                language: language.to_string(),
                text: text.to_string(),
                reply,
            })
            .ok()?;
        answer.recv().ok().flatten()
    }

    /// Cancels `block`'s requests and drops its line states.
    pub fn forget(&self, block: u64) {
        self.latest.lock().unwrap().remove(&block);
        let _ = self.jobs.lock().unwrap().send(Job::Forget(block));
    }
}

struct Line {
    text: String,
    /// In UTF-16 offsets from the line's start.
    spans: Vec<Span>,
    /// The parser and scopes after the line.
    state: ParseState,
    scopes: ScopeStack,
}

struct Cache {
    syntax: String,
    lines: Vec<Line>,
    used: u64,
}

struct Worker {
    dump: PathBuf,
    set: Option<Option<SyntaxSet>>,
    rules: Rules,
    latest: Arc<Mutex<HashMap<u64, u64>>>,
    blocks: HashMap<u64, Cache>,
    clock: u64,
}

impl Worker {
    fn new(dump: PathBuf, latest: Arc<Mutex<HashMap<u64, u64>>>) -> Self {
        Self {
            dump,
            set: None,
            rules: Rules::default(),
            latest,
            blocks: HashMap::new(),
            clock: 0,
        }
    }

    fn run(mut self, inbox: Receiver<Job>) {
        for job in inbox {
            match job {
                Job::Forget(block) => {
                    self.blocks.remove(&block);
                }
                Job::Highlight {
                    block,
                    generation,
                    language,
                    text,
                    reply,
                } => {
                    let spans = panic::catch_unwind(AssertUnwindSafe(|| {
                        self.highlight(block, generation, &language, &text)
                    }))
                    .unwrap_or_else(|_| {
                        self.blocks.remove(&block);
                        Some(Vec::new())
                    });
                    let _ = reply.send(spans);
                }
            }
        }
    }

    fn current(&self, block: u64, generation: u64) -> bool {
        self.latest.lock().unwrap().get(&block) == Some(&generation)
    }

    fn highlight(
        &mut self,
        block: u64,
        generation: u64,
        language: &str,
        text: &str,
    ) -> Option<Vec<Span>> {
        if !self.current(block, generation) {
            return None;
        }
        match language.to_ascii_lowercase().as_str() {
            "diff" | "patch" => return Some(diff(text)),
            "md" | "markdown" => return Some(markdown(text)),
            _ => {}
        }
        if self.set.is_none() {
            self.set = Some(syntect::dumps::from_uncompressed_dump_file(&self.dump).ok());
            self.rules = rules();
        }
        let Some(set) = self.set.as_ref().unwrap() else {
            return Some(Vec::new());
        };
        let Some(syntax) = find(set, language) else {
            return Some(Vec::new());
        };
        self.clock += 1;
        let mut cache = self
            .blocks
            .remove(&block)
            .filter(|cache| cache.syntax == syntax.name)
            .unwrap_or_else(|| Cache {
                syntax: syntax.name.clone(),
                lines: Vec::new(),
                used: 0,
            });
        cache.used = self.clock;
        let new: Vec<&str> = text.split_inclusive('\n').collect();
        let kept = cache
            .lines
            .iter()
            .zip(&new)
            .take_while(|(line, text)| line.text == **text)
            .count();
        cache.lines.truncate(kept);
        let mut stalled = false;
        for text in &new[kept..] {
            if !self.current(block, generation) {
                return None;
            }
            let (mut state, mut scopes) = cache.lines.last().map_or_else(
                || (ParseState::new(syntax), ScopeStack::new()),
                |line| (line.state.clone(), line.scopes.clone()),
            );
            let mut spans = Vec::new();
            if !stalled && text.len() <= LINE_BYTES {
                let started = Instant::now();
                // The syntaxes are built for lines that end in a line break.
                let owned;
                let parsed = if text.ends_with('\n') {
                    *text
                } else {
                    owned = format!("{text}\n");
                    &owned
                };
                if let Ok(ops) = state.parse_line(parsed, set) {
                    spans = classes(&self.rules, text, &ops, &mut scopes);
                }
                stalled = started.elapsed() > LINE_TIME;
                if stalled {
                    spans.clear();
                }
            }
            cache.lines.push(Line {
                text: text.to_string(),
                spans,
                state,
                scopes,
            });
        }
        let mut spans = Vec::new();
        let mut at = 0;
        for line in &cache.lines {
            spans.extend(line.spans.iter().map(|span| Span {
                start: span.start + at,
                end: span.end + at,
                class: span.class,
            }));
            at += line.text.encode_utf16().count() as u32;
        }
        if stalled {
            // A slow line leaves the rest plain; the next request starts over at it rather than reuse plain lines.
            cache.lines.truncate(kept);
        }
        if self.blocks.len() >= CACHED_BLOCKS {
            let oldest = self
                .blocks
                .iter()
                .min_by_key(|(_, cache)| cache.used)
                .map(|(block, _)| *block);
            oldest.map(|block| self.blocks.remove(&block));
        }
        self.blocks.insert(block, cache);
        Some(spans)
    }
}

/// The syntax for a fence's language: an extension or a name, as GitHub reads them, with a few common aliases.
fn find<'a>(set: &'a SyntaxSet, language: &str) -> Option<&'a syntect::parsing::SyntaxReference> {
    let language = match language.to_ascii_lowercase().as_str() {
        "shell" | "zsh" | "console" => "bash".to_string(),
        "c++" => "cpp".to_string(),
        "golang" => "go".to_string(),
        "javascript" | "jsx" | "mjs" | "cjs" => "js".to_string(),
        "typescript" | "tsx" => "ts".to_string(),
        "jsonc" | "json5" => "json".to_string(),
        "py3" | "python3" => "py".to_string(),
        other => other.to_string(),
    };
    if language.is_empty() {
        return None;
    }
    set.find_syntax_by_token(&language)
        .filter(|syntax| !syntax.hidden && syntax.name != "Unnamed")
}

/// Scope prefixes and their classes, most specific first; a token's class is the first match for its innermost scope
/// that has one. A string inside a mapping's key reads as an attribute.
#[derive(Default)]
struct Rules {
    classes: Vec<(Scope, Class)>,
    keys: Vec<Scope>,
}

fn rules() -> Rules {
    let classes = [
        ("comment", Class::Comment),
        ("constant.character.escape", Class::Escape),
        ("string", Class::String),
        ("constant.numeric", Class::Number),
        ("constant", Class::Constant),
        ("support.constant", Class::Constant),
        ("variable.language", Class::Keyword),
        ("keyword.operator", Class::Operator),
        ("keyword", Class::Keyword),
        ("storage", Class::Keyword),
        ("entity.name.function", Class::Function),
        ("support.function", Class::Function),
        ("variable.function", Class::Function),
        ("entity.name.tag", Class::Tag),
        ("entity.other.attribute-name", Class::Attribute),
        ("support.type.property-name", Class::Attribute),
        ("entity.name", Class::Type),
        ("entity.other.inherited-class", Class::Type),
        ("support.type", Class::Type),
        ("support.class", Class::Type),
        ("markup.inserted", Class::Inserted),
        ("markup.deleted", Class::Deleted),
        ("markup.heading", Class::Heading),
    ];
    let scope = |name: &str| Scope::new(name).unwrap();
    Rules {
        classes: classes
            .into_iter()
            .map(|(name, class)| (scope(name), class))
            .collect(),
        keys: vec![
            scope("meta.mapping.key"),
            scope("meta.structure.dictionary.key"),
        ],
    }
}

fn class(rules: &Rules, scopes: &ScopeStack) -> Option<Class> {
    let stack = scopes.as_slice();
    let found = stack.iter().rev().find_map(|scope| {
        rules
            .classes
            .iter()
            .find(|(rule, _)| rule.is_prefix_of(*scope))
            .map(|(_, class)| *class)
    });
    if found == Some(Class::String)
        && stack
            .iter()
            .any(|scope| rules.keys.iter().any(|key| key.is_prefix_of(*scope)))
    {
        return Some(Class::Attribute);
    }
    found
}

/// Applies a line's scope changes to `scopes` and returns the line's spans in UTF-16 offsets from its start, or none
/// when the line has more than `LINE_TOKENS` changes.
fn classes(
    rules: &Rules,
    line: &str,
    ops: &[(usize, syntect::parsing::ScopeStackOp)],
    scopes: &mut ScopeStack,
) -> Vec<Span> {
    if ops.len() > LINE_TOKENS {
        for (_, op) in ops {
            let _ = scopes.apply(op);
        }
        return Vec::new();
    }
    let bare = line.trim_end_matches(['\n', '\r']).len();
    let mut spans: Vec<Span> = Vec::new();
    // The byte the last span ended at and its UTF-16 offset, so the line's offsets convert once.
    let mut cursor = (0, 0);
    let mut push = |from: usize, to: usize, class: Option<Class>| {
        let to = to.min(bare);
        let (Some(class), true) = (class, from < to) else {
            return;
        };
        let mut units = |byte: usize| {
            cursor = (
                byte,
                cursor.1 + line[cursor.0..byte].encode_utf16().count() as u32,
            );
            cursor.1
        };
        let (start, end) = (units(from), units(to));
        match spans.last_mut() {
            Some(last) if last.class == class && last.end == start => last.end = end,
            _ => spans.push(Span { start, end, class }),
        }
    };
    let mut at = 0;
    for (offset, op) in ops {
        let offset = (*offset).min(line.len());
        push(at, offset, class(rules, scopes));
        at = offset;
        let _ = scopes.apply(op);
    }
    push(at, line.len(), class(rules, scopes));
    spans
}

/// A unified diff's lines: file and hunk headers, insertions and deletions.
fn diff(text: &str) -> Vec<Span> {
    let mut spans = Vec::new();
    let mut at = 0;
    for line in text.split_inclusive('\n') {
        let length = line.encode_utf16().count() as u32;
        let bare = line.trim_end_matches(['\n', '\r']).encode_utf16().count() as u32;
        let class = if ["+++", "---", "@@", "diff ", "index "]
            .iter()
            .any(|head| line.starts_with(head))
        {
            Some(Class::Heading)
        } else if line.starts_with('+') {
            Some(Class::Inserted)
        } else if line.starts_with('-') {
            Some(Class::Deleted)
        } else {
            None
        };
        if let (Some(class), true) = (class, bare > 0) {
            spans.push(Span {
                start: at,
                end: at + bare,
                class,
            });
        }
        at += length;
    }
    spans
}

/// Markdown through `core::md`: each token's markers and content, inner tokens over outer ones.
fn markdown(text: &str) -> Vec<Span> {
    let parse = md::parse(text);
    let mut painted: Vec<Option<Class>> = vec![None; text.encode_utf16().count()];
    let mut paint = |from: u32, to: u32, class: Option<Class>| {
        if let Some(class) = class {
            painted[from as usize..to as usize].fill(Some(class));
        }
    };
    for token in &parse.tokens {
        let (markers, content) = match token.kind {
            TokenKind::Heading { .. } => (Some(Class::Heading), Some(Class::Heading)),
            TokenKind::InlineCode | TokenKind::FencedCode => {
                (Some(Class::Operator), Some(Class::String))
            }
            TokenKind::Link | TokenKind::Image | TokenKind::WikiLink | TokenKind::Embed => {
                (Some(Class::Operator), Some(Class::Function))
            }
            TokenKind::Callout => (Some(Class::Keyword), Some(Class::Keyword)),
            TokenKind::FootnoteReference
            | TokenKind::FootnoteDefinition
            | TokenKind::Definition => (Some(Class::Attribute), Some(Class::Attribute)),
            TokenKind::InlineMath | TokenKind::DisplayMath => {
                (Some(Class::Operator), Some(Class::Number))
            }
            TokenKind::Comment | TokenKind::FrontMatter => {
                (Some(Class::Comment), Some(Class::Comment))
            }
            TokenKind::Tag => (Some(Class::Constant), Some(Class::Constant)),
            TokenKind::Html => (Some(Class::Tag), Some(Class::Tag)),
            TokenKind::TableHead | TokenKind::TableRow | TokenKind::TableCell => (None, None),
            _ => (Some(Class::Operator), None),
        };
        paint(token.start, token.content_start, markers);
        paint(token.content_end, token.end, markers);
        paint(token.content_start, token.content_end, content);
    }
    let mut spans: Vec<Span> = Vec::new();
    for (index, class) in painted.into_iter().enumerate() {
        let Some(class) = class else { continue };
        let index = index as u32;
        match spans.last_mut() {
            Some(last) if last.class == class && last.end == index => last.end += 1,
            _ => spans.push(Span {
                start: index,
                end: index + 1,
                class,
            }),
        }
    }
    spans
}

#[cfg(test)]
mod tests {
    use super::*;

    fn highlighter() -> Highlighter {
        Highlighter::new(PathBuf::from(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../app/Dewline/Syntaxes.packdump"
        )))
    }

    /// The text of each span with its class.
    fn read(text: &str, spans: &[Span]) -> Vec<(String, Class)> {
        let units: Vec<u16> = text.encode_utf16().collect();
        spans
            .iter()
            .map(|span| {
                (
                    String::from_utf16(&units[span.start as usize..span.end as usize]).unwrap(),
                    span.class,
                )
            })
            .collect()
    }

    fn has(found: &[(String, Class)], text: &str, class: Class) -> bool {
        found
            .iter()
            .any(|(span, found)| span == text && *found == class)
    }

    #[test]
    fn rust() {
        let text = "// sum\nfn add(a: u32) -> u32 {\n    let s = \"é\\n\";\n    a + 42\n}\n";
        let found = read(text, &highlighter().highlight(1, "rust", text).unwrap());
        assert!(has(&found, "// sum", Class::Comment), "{found:?}");
        assert!(has(&found, "fn", Class::Keyword), "{found:?}");
        assert!(has(&found, "add", Class::Function), "{found:?}");
        assert!(has(&found, "\\n", Class::Escape), "{found:?}");
        assert!(has(&found, "42", Class::Number), "{found:?}");
        assert!(
            found
                .iter()
                .any(|(span, class)| span.contains('é') && *class == Class::String),
            "{found:?}"
        );
    }

    #[test]
    fn python() {
        let text = "def greet(name):\n    # hi\n    return f\"hi {name}\" if name else None\n";
        let found = read(text, &highlighter().highlight(1, "py", text).unwrap());
        assert!(has(&found, "def", Class::Keyword), "{found:?}");
        assert!(has(&found, "greet", Class::Function), "{found:?}");
        assert!(has(&found, "# hi", Class::Comment), "{found:?}");
        assert!(has(&found, "None", Class::Constant), "{found:?}");
    }

    #[test]
    fn json() {
        let text = "{\"name\": \"dewline\", \"size\": 1.5, \"open\": true}";
        let found = read(text, &highlighter().highlight(1, "json", text).unwrap());
        assert!(has(&found, "\"name\"", Class::Attribute), "{found:?}");
        assert!(has(&found, "\"dewline\"", Class::String), "{found:?}");
        assert!(has(&found, "1.5", Class::Number), "{found:?}");
        assert!(has(&found, "true", Class::Constant), "{found:?}");
    }

    #[test]
    fn an_edit_reparses_from_its_line() {
        let highlighter = highlighter();
        let before = "let a = 1;\nlet b = 2;\n";
        let after = "let a = 1;\nlet b = \"2\";\n";
        let first = highlighter.highlight(7, "rs", before).unwrap();
        let second = read(after, &highlighter.highlight(7, "rs", after).unwrap());
        assert_eq!(read(before, &first)[..2], second[..2]);
        assert!(has(&second, "\"2\"", Class::String), "{second:?}");
    }

    #[test]
    fn a_line_over_the_token_budget_stays_plain() {
        let numbers = vec!["1"; LINE_TOKENS].join(",");
        let text = format!("[1]\n[{numbers}]\n[2]\n");
        let started = Instant::now();
        let found = read(&text, &highlighter().highlight(1, "json", &text).unwrap());
        assert!(
            has(&found, "1", Class::Number) && has(&found, "2", Class::Number),
            "{found:?}"
        );
        assert_eq!(
            found
                .iter()
                .filter(|(_, class)| *class == Class::Number)
                .count(),
            2,
            "{:?}",
            started.elapsed()
        );
    }

    /// syntect 5.3.0 loops forever on two contexts that `set` each other without consuming (trishume/syntect#706),
    /// which older JavaScript syntaxes do on this line.
    #[test]
    fn the_syntect_706_line_returns() {
        for language in ["js", "ts"] {
            let (sent, received) = mpsc::channel();
            std::thread::spawn(move || {
                sent.send(highlighter().highlight(1, language, "x /*"))
                    .unwrap()
            });
            assert!(
                received.recv_timeout(Duration::from_secs(10)).is_ok(),
                "{language}"
            );
        }
    }

    #[test]
    fn an_unknown_language_has_no_spans() {
        let highlighter = highlighter();
        assert_eq!(
            highlighter.highlight(1, "klingon", "qapla'\n"),
            Some(Vec::new())
        );
        assert_eq!(highlighter.highlight(2, "", "plain\n"), Some(Vec::new()));
    }

    #[test]
    fn diff_and_markdown_are_native() {
        let text = "@@ -1 +1 @@\n-old\n+new\n same\n";
        let found = read(text, &highlighter().highlight(1, "diff", text).unwrap());
        assert_eq!(
            found,
            [
                ("@@ -1 +1 @@".into(), Class::Heading),
                ("-old".into(), Class::Deleted),
                ("+new".into(), Class::Inserted)
            ]
        );
        let text = "# Title\n\nSee `code`.\n";
        let found = read(text, &highlighter().highlight(1, "markdown", text).unwrap());
        assert!(
            has(&found, "# Title", Class::Heading) && has(&found, "code", Class::String),
            "{found:?}"
        );
    }

    #[test]
    fn a_newer_request_cancels_an_older_one() {
        let highlighter = Arc::new(highlighter());
        let text: String = (0..20_000).map(|n| format!("let x{n} = {n};\n")).collect();
        let older = {
            let (highlighter, text) = (highlighter.clone(), text.clone());
            std::thread::spawn(move || highlighter.highlight(3, "rust", &text))
        };
        std::thread::sleep(Duration::from_millis(20));
        assert!(highlighter.highlight(3, "rust", "let y = 1;\n").is_some());
        assert_eq!(older.join().unwrap(), None);
    }
}
