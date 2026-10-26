use std::collections::HashSet;
use std::ops::Range;

use pulldown_cmark::{
    BrokenLink, BrokenLinkCallback, CodeBlockKind, CowStr, Event, LinkType, Options, Parser, Tag,
};
use unicase::UniCase;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpanKind {
    Heading { level: u8 },
    Emphasis,
    Strong,
    Strikethrough,
    InlineCode,
    Link,
    Image,
    FencedCode,
}

/// Offsets are UTF-16 code units. `[start, content_start)` and
/// `[content_end, end)` are the markers the editor hides.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub kind: SpanKind,
    pub start: u32,
    pub end: u32,
    pub content_start: u32,
    pub content_end: u32,
}

const BLANK: [char; 4] = [' ', '\t', '\x0b', '\x0c'];

struct Open {
    index: usize,
    range: Range<usize>,
    end: usize,
    child_end: usize,
}

/// Spans ordered by `start`, outer before inner.
pub fn spans(text: &str) -> Vec<Span> {
    let mut found: Vec<(SpanKind, [usize; 4])> = Vec::new();
    let mut open: Vec<Open> = Vec::new();
    for (event, range) in Parser::new_ext(text, Options::ENABLE_STRIKETHROUGH).into_offset_iter() {
        if matches!(event, Event::End(_))
            && let Some(top) = open.pop_if(|top| top.range == range)
        {
            let span = &mut found[top.index];
            span.1 = marks(
                text,
                span.0.into(),
                range.start..top.end,
                None,
                top.child_end,
                0,
            );
            continue;
        }
        // pulldown-cmark ends a collapsed reference, `[text][]`, before its `[]`.
        let end = match &event {
            Event::Start(Tag::Link { link_type, .. } | Tag::Image { link_type, .. })
                if *link_type == LinkType::Collapsed && text[range.end..].starts_with("[]") =>
            {
                range.end + 2
            }
            _ => range.end,
        };
        if let Some(top) = open.last_mut() {
            top.child_end = end;
        }
        let kind = match event {
            Event::Start(Tag::Heading { level, .. }) => SpanKind::Heading { level: level as u8 },
            Event::Start(Tag::Emphasis) => SpanKind::Emphasis,
            Event::Start(Tag::Strong) => SpanKind::Strong,
            Event::Start(Tag::Strikethrough) => SpanKind::Strikethrough,
            Event::Start(Tag::Link { .. }) => SpanKind::Link,
            Event::Start(Tag::Image { .. }) => SpanKind::Image,
            Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(_))) => SpanKind::FencedCode,
            Event::Code(_) => {
                let offsets = marks(
                    text,
                    TokenKind::InlineCode,
                    range.clone(),
                    None,
                    range.start,
                    0,
                );
                found.push((SpanKind::InlineCode, offsets));
                continue;
            }
            _ => continue,
        };
        open.push(Open {
            index: found.len(),
            end,
            child_end: range.start,
            range,
        });
        found.push((kind, [0; 4]));
    }

    let utf16 = Utf16::new(text);
    found
        .into_iter()
        .map(|(kind, [start, content_start, content_end, end])| Span {
            kind,
            start: utf16.at(start),
            end: utf16.at(end),
            content_start: utf16.at(content_start),
            content_end: utf16.at(content_end),
        })
        .collect()
}

/// The most text, window and lookahead together, that `parse_window` takes: the bound on Rust in the keystroke path.
pub const WINDOW_LIMIT: usize = 4096;

/// What a block is. A block is a unit the editor reparses: a top-level block, a top-level list item, or a top-level
/// table's head (its header and delimiter rows) or one of its rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BlockKind {
    Paragraph,
    Heading {
        level: u8,
    },
    ThematicBreak,
    Quote,
    /// A quote that opens with `[!type]`.
    Callout,
    Code,
    Html,
    Item,
    TableHead,
    TableRow,
    FootnoteDefinition,
    /// A link reference definition, which pulldown-cmark reports only through its label table.
    Definition,
    FrontMatter,
}

/// Whole lines in UTF-16 offsets: the last line's terminator is in, blank lines after it are out. Blocks are in order
/// and apart, and each token lies inside one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Block {
    pub kind: BlockKind,
    pub start: u32,
    pub end: u32,
}

/// What a token is, and which characters are its markers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TokenKind {
    /// `#` to `######` and the blanks after them, and the closing hashes; a setext heading's line break and underline.
    Heading {
        level: u8,
    },
    Emphasis,
    Strong,
    Strikethrough,
    InlineCode,
    /// `[` and `](url)`, `][label]`, `][]` or `]`; an autolink's `<` and `>`.
    Link,
    /// `![` and the same closings as a link.
    Image,
    /// The opening fence's line and the closing fence.
    FencedCode,
    /// `>` and one blank on the quote's first line.
    Quote,
    /// A callout's `[!` and `]`, with `+` or `-` when it folds, around its type.
    Callout,
    /// A list item's marker and the blanks after it.
    Item,
    /// `[` and `]` around a task box's ` ` or `x`.
    TaskBox {
        checked: bool,
    },
    /// A header row; the line break and delimiter row after it are its closing marker.
    TableHead,
    TableRow,
    /// The blanks around a cell's content.
    TableCell,
    /// `[^` and `]` around the label.
    FootnoteReference,
    /// `[^label]:` and the blanks after it.
    FootnoteDefinition,
    /// A link reference definition: `[`, then `]:` with the destination and title, around the label.
    Definition,
    /// `$` and `$`.
    InlineMath,
    /// `$$` and `$$`.
    DisplayMath,
    /// `[[`, with the target and `|` when an alias follows, and `]]`.
    WikiLink,
    /// `![[` and `]]`.
    Embed,
    /// `==` and `==`.
    Highlight,
    /// `%%` and `%%`.
    Comment,
    /// `#` before the tag.
    Tag,
    /// The opening `---` line and the closing `---` or `...`.
    FrontMatter,
    /// An inline HTML tag or comment, all content.
    Html,
}

impl From<SpanKind> for TokenKind {
    fn from(kind: SpanKind) -> Self {
        match kind {
            SpanKind::Heading { level } => TokenKind::Heading { level },
            SpanKind::Emphasis => TokenKind::Emphasis,
            SpanKind::Strong => TokenKind::Strong,
            SpanKind::Strikethrough => TokenKind::Strikethrough,
            SpanKind::InlineCode => TokenKind::InlineCode,
            SpanKind::Link => TokenKind::Link,
            SpanKind::Image => TokenKind::Image,
            SpanKind::FencedCode => TokenKind::FencedCode,
        }
    }
}

/// UTF-16 offsets. `[start, content_start)` and `[content_end, end)` are the markers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token {
    pub kind: TokenKind,
    pub start: u32,
    pub content_start: u32,
    pub content_end: u32,
    pub end: u32,
}

/// What a window needs from the rest of its document: the link and footnote labels, compared as pulldown-cmark
/// compares them, and whether the document opens front matter that no line closes.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Labels {
    links: HashSet<UniCase<String>>,
    footnotes: HashSet<UniCase<String>>,
    open_front_matter: bool,
}

impl Labels {
    fn covers(&self, other: &Labels) -> bool {
        other.links.is_subset(&self.links) && other.footnotes.is_subset(&self.footnotes)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parse {
    pub blocks: Vec<Block>,
    /// Ordered by `start`, outer before inner.
    pub tokens: Vec<Token>,
    /// The labels the text defines.
    pub labels: Labels,
    /// Whether the rest of the document still parses as it did: the next block starts where it did and is no new table
    /// row, a row window is still a table's head and rows, front matter the window opens closes in it, and the window
    /// defines no label the document lacked. True for a document.
    pub holds: bool,
}

/// The text the editor reparses after an edit, cut from its document.
#[derive(Debug, Clone, Copy)]
pub struct Window<'a> {
    /// Whole blocks: those holding the edit, and the block above when no blank line separates them or the window
    /// starts with a blank or a line break, with a quote, item or footnote right above that block. For an edit in a
    /// table's body, the table's head and then the edited rows; for an edit in its head, the whole table.
    pub text: &'a str,
    /// The lines after `text` through the first one that is not blank and the line after that, which can make it a
    /// table's header; nothing at the end of the document.
    pub next: &'a str,
    /// Whether `text` starts the document, the only place front matter is.
    pub at_start: bool,
    /// Whether `text` is a table's head and body rows.
    pub row: bool,
}

/// Tables, footnotes, task lists, strikethrough, math and wikilinks; front matter and the Obsidian syntax are ours.
const OPTIONS: Options = Options::ENABLE_TABLES
    .union(Options::ENABLE_FOOTNOTES)
    .union(Options::ENABLE_STRIKETHROUGH)
    .union(Options::ENABLE_TASKLISTS)
    .union(Options::ENABLE_MATH)
    .union(Options::ENABLE_WIKILINKS);

/// A whole document.
pub fn parse(text: &str) -> Parse {
    let window = Window {
        text,
        next: "",
        at_start: true,
        row: false,
    };
    let mut parse = run(&window, &Labels::default());
    parse.labels.open_front_matter = matches!(front_matter(text), Some(Err(())));
    parse
}

/// A window, with the document's labels from its last whole parse; `None` over `WINDOW_LIMIT`.
pub fn parse_window(window: &Window<'_>, labels: &Labels) -> Option<Parse> {
    if window.text.len() + window.next.len() > WINDOW_LIMIT {
        return None;
    }
    let mut parse = run(window, labels);
    // A closing line anywhere closes front matter the document's first line opened.
    let closes = |text: &str| {
        let bytes = text.as_bytes();
        (0..bytes.len()).any(|at| {
            (at == 0 || matches!(bytes[at - 1], b'\n' | b'\r'))
                && closing_fence(&bytes[at..]).is_some()
        })
    };
    parse.holds &= labels.covers(&parse.labels)
        && !(labels.open_front_matter && !window.at_start && closes(window.text));
    Some(parse)
}

fn run(window: &Window<'_>, table: &Labels) -> Parse {
    let text = window.text;
    let front = window.at_start.then(|| front_matter(text)).flatten();
    // Front matter left open can close past the window.
    let open = matches!(front, Some(Err(())));
    let front = front.and_then(Result::ok);
    let skip = front.as_ref().map_or(0, |front| front.end);
    let body = &text[skip..];
    // Footnote references resolve only against definitions in the parsed text, so a window gets a copy of each
    // definition it refers to, ahead of it and closed off by an HTML block and a blank line.
    let prefix = footnote_prefix(body, table);
    let source = [prefix.as_str(), body, window.next].concat();
    let (lo, hi) = (prefix.len(), prefix.len() + body.len());
    let walk = walk(&source, table);
    let inside = |at: usize| (lo..hi).contains(&at);
    let local = |at: usize| at.clamp(lo, hi) - lo + skip;

    let mut blocks: Vec<(BlockKind, Range<usize>)> = Vec::new();
    let mut tokens: Vec<(TokenKind, [usize; 4])> = Vec::new();
    if let Some(front) = &front {
        blocks.push((BlockKind::FrontMatter, 0..front.end));
        tokens.push((
            TokenKind::FrontMatter,
            [0, front.open, front.close, front.close_end],
        ));
    }
    for (kind, range) in &walk.blocks {
        if inside(range.start) {
            blocks.push((*kind, local(range.start)..local(range.end)));
        }
    }
    tokens.extend(
        walk.tokens
            .iter()
            .filter(|(_, [start, ..])| inside(*start))
            .map(|(kind, offsets)| (*kind, offsets.map(local))),
    );
    let mut labels = Labels::default();
    for (label, span) in &walk.links {
        if inside(span.start) {
            labels.links.insert(UniCase::new(label.clone()));
        }
    }
    for (label, at) in &walk.footnotes {
        if inside(*at) {
            labels.footnotes.insert(UniCase::new(label.clone()));
        }
    }

    let next = hi + blank_lines(window.next);
    // The window's blocks end in it, the next block starts where it did, and only a row window's table runs on into
    // it.
    let after = walk.blocks.iter().find(|(_, range)| range.start == next);
    let mut holds = walk
        .blocks
        .iter()
        .all(|(_, range)| !inside(range.start) || range.end <= hi)
        && (next == source.len()
            || (!open
                && after.is_some_and(|(kind, _)| window.row || *kind != BlockKind::TableRow)));
    if window.row {
        holds &= matches!(blocks.split_first(), Some(((BlockKind::TableHead, _), rows))
            if !rows.is_empty() && rows.iter().all(|(kind, _)| *kind == BlockKind::TableRow));
    }

    let utf16 = Utf16::new(text);
    Parse {
        blocks: blocks
            .into_iter()
            .map(|(kind, range)| Block {
                kind,
                start: utf16.at(range.start),
                end: utf16.at(range.end),
            })
            .collect(),
        tokens: tokens
            .into_iter()
            .map(|(kind, [start, content_start, content_end, end])| Token {
                kind,
                start: utf16.at(start),
                content_start: utf16.at(content_start),
                content_end: utf16.at(content_end),
                end: utf16.at(end),
            })
            .collect(),
        labels,
        holds,
    }
}

/// UTF-16 offsets of byte offsets on a text's character boundaries: the byte offset, less the continuation bytes
/// before it, plus one for each four-byte character, which UTF-16 writes as a surrogate pair.
struct Utf16<'a> {
    bytes: &'a [u8],
    /// That adjustment at the start of each 64-byte block, and whether the block is ASCII.
    blocks: Vec<(i64, bool)>,
}

impl<'a> Utf16<'a> {
    fn new(text: &'a str) -> Self {
        let bytes = text.as_bytes();
        let mut blocks = Vec::with_capacity(bytes.len() / 64 + 1);
        let mut total = 0;
        for block in bytes.chunks(64) {
            let ascii = block.is_ascii();
            blocks.push((total, ascii));
            if !ascii {
                total += adjustment(block);
            }
        }
        blocks.push((total, true));
        Utf16 { bytes, blocks }
    }

    fn at(&self, byte: usize) -> u32 {
        let (before, ascii) = self.blocks[byte / 64];
        let inside = if ascii {
            0
        } else {
            adjustment(&self.bytes[byte / 64 * 64..byte])
        };
        (byte as i64 - before - inside) as u32
    }
}

fn adjustment(bytes: &[u8]) -> i64 {
    bytes
        .iter()
        .map(|&byte| i64::from(byte & 0xC0 == 0x80) - i64::from(byte >= 0xF0))
        .sum()
}

/// Front matter's byte offsets: after the opening line, at the closing `---` or `...`, after it and its blanks, and
/// after its line.
struct Front {
    open: usize,
    close: usize,
    close_end: usize,
    end: usize,
}

/// pulldown-cmark's YAML metadata block, at the start only: `---` alone on the first line, a second line that is
/// neither blank nor the close, and a closing line of `---` or `...`. `Err` when no line in `text` closes it.
fn front_matter(text: &str) -> Option<Result<Front, ()>> {
    let bytes = text.as_bytes();
    let next_line = |at: usize| {
        bytes[at..]
            .iter()
            .position(|&byte| byte == b'\n')
            .map_or(bytes.len(), |n| at + n + 1)
    };
    if !text.starts_with("---") || bytes.get(3) == Some(&b'-') {
        return None;
    }
    let open = next_line(0);
    if !bytes[3..open].iter().all(u8::is_ascii_whitespace) {
        return None;
    }
    let mut at = open;
    while at < bytes.len() {
        let close = closing_fence(&bytes[at..]);
        if at == open && (close.is_some() || is_blank_line(&bytes[at..])) {
            return None;
        }
        if let Some(length) = close {
            let close_end = at + length;
            let end = close_end + line_break(&bytes[close_end..]);
            return Some(Ok(Front {
                open,
                close: at,
                close_end,
                end,
            }));
        }
        at = next_line(at);
    }
    Some(Err(()))
}

/// The length of `---` or `...` and the spaces after it, when they fill the line.
fn closing_fence(bytes: &[u8]) -> Option<usize> {
    let fence = *bytes
        .first()
        .filter(|&&byte| byte == b'-' || byte == b'.')?;
    if bytes.get(1..3) != Some(&[fence, fence]) || bytes.get(3) == Some(&fence) {
        return None;
    }
    let length = 3 + bytes[3..].iter().take_while(|&&byte| byte == b' ').count();
    matches!(bytes.get(length), None | Some(b'\n' | b'\r')).then_some(length)
}

fn is_blank_line(bytes: &[u8]) -> bool {
    let blanks = bytes
        .iter()
        .take_while(|&&byte| matches!(byte, b' ' | b'\t' | b'\x0b' | b'\x0c'))
        .count();
    matches!(bytes.get(blanks), None | Some(b'\n' | b'\r'))
}

fn line_break(bytes: &[u8]) -> usize {
    match bytes {
        [b'\r', b'\n', ..] => 2,
        [b'\n' | b'\r', ..] => 1,
        _ => 0,
    }
}

/// The start of the line after the one holding `at`.
fn line_after(text: &str, at: usize) -> usize {
    text[at..].find(['\n', '\r']).map_or(text.len(), |n| {
        at + n + line_break(&text.as_bytes()[at + n..])
    })
}

/// `range` grown to whole lines, without blank lines at its end.
fn lines(text: &str, range: Range<usize>) -> Range<usize> {
    let source = &text[range.clone()];
    let first = range.end
        - source
            .trim_start_matches(|c: char| c.is_ascii_whitespace())
            .len();
    let start = text[..first].rfind(['\n', '\r']).map_or(0, |at| at + 1);
    let last = range.start
        + source
            .trim_end_matches(|c: char| c.is_ascii_whitespace())
            .len();
    start..line_after(text, last.max(start))
}

/// The length of the blank lines that start `text`.
fn blank_lines(text: &str) -> usize {
    let mut at = 0;
    while at < text.len() && is_blank_line(&text.as_bytes()[at..]) {
        at = line_after(text, at);
    }
    at
}

/// Definitions for the footnotes `body` refers to that the document defines elsewhere.
fn footnote_prefix(body: &str, table: &Labels) -> String {
    let mut prefix = String::new();
    if table.footnotes.is_empty() {
        return prefix;
    }
    let mut seen = HashSet::new();
    for (at, _) in body.match_indices("[^") {
        let rest = &body[at + 2..];
        let Some(close) = rest
            .bytes()
            .take(1000)
            .position(|byte| byte == b']' || byte == b'[')
            .filter(|&close| rest.as_bytes()[close] == b']')
        else {
            continue;
        };
        let label = rest[..close]
            .split_ascii_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if !label.is_empty()
            && table.footnotes.contains(&UniCase::new(label.clone()))
            && seen.insert(label.clone())
        {
            prefix.push_str("[^");
            prefix.push_str(&label);
            prefix.push_str("]: x\n");
        }
    }
    if !prefix.is_empty() {
        prefix.push_str("\n<!-- -->\n\n");
    }
    prefix
}

/// Resolves a reference to a label the document defines outside the parsed text. Styling needs no destination.
struct Resolve<'a>(&'a Labels);

impl<'input> BrokenLinkCallback<'input> for Resolve<'_> {
    fn handle_broken_link(
        &mut self,
        link: BrokenLink<'input>,
    ) -> Option<(CowStr<'input>, CowStr<'input>)> {
        let label = UniCase::new(link.reference.into_string());
        self.0
            .links
            .contains(&label)
            .then_some((CowStr::Borrowed(""), CowStr::Borrowed("")))
    }
}

/// Byte offsets into the parsed source.
#[derive(Default)]
struct Walk {
    blocks: Vec<(BlockKind, Range<usize>)>,
    /// In document order, outer before inner.
    tokens: Vec<(TokenKind, [usize; 4])>,
    /// Tokens found after the ones around them: the Obsidian syntax and definitions.
    extra: Vec<(TokenKind, [usize; 4])>,
    links: Vec<(String, Range<usize>)>,
    footnotes: Vec<(String, usize)>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Container {
    List,
    Table,
    Code,
    Other,
}

struct Node {
    container: Container,
    token: Option<usize>,
    unit: Option<usize>,
    range: Range<usize>,
    end: usize,
    first_child: Option<usize>,
    child_end: usize,
    /// The end of the tokens inside.
    inner_end: usize,
    /// Where its runs of text start in the walk's list.
    texts: usize,
}

const REMOVED: [usize; 4] = [usize::MAX; 4];

fn walk(source: &str, table: &Labels) -> Walk {
    let mut events = Parser::new_with_broken_link_callback(source, OPTIONS, Some(Resolve(table)))
        .into_offset_iter();
    let mut walk = Walk::default();
    let mut stack: Vec<Node> = Vec::new();
    // Each open node's runs of text, after those of the nodes around it.
    let mut texts: Vec<Range<usize>> = Vec::new();
    // A quote's first paragraph, whose first text may be a callout's `[!type]`.
    let mut callout = None;
    let mut after_quote = false;
    for (event, range) in &mut events {
        if matches!(event, Event::End(_)) {
            if let Some(node) = stack.pop() {
                extend(source, &texts[node.texts..], &mut walk.extra);
                texts.truncate(node.texts);
                walk.close(source, node, stack.last_mut());
            }
            after_quote = false;
            continue;
        }
        if let Some(at) = callout.take()
            && matches!(event, Event::Text(_))
            && range.start == at
            && let Some((type_end, end)) = callout_marker(source, at)
        {
            walk.tokens
                .push((TokenKind::Callout, [at, at + 2, type_end, end]));
            if let Some(unit) = stack
                .len()
                .checked_sub(2)
                .and_then(|quote| stack[quote].unit)
            {
                walk.blocks[unit].0 = BlockKind::Callout;
            }
        }
        // pulldown-cmark ends a collapsed reference, `[text][]`, before its `[]`.
        let end = match &event {
            Event::Start(Tag::Link { link_type, .. } | Tag::Image { link_type, .. })
                if matches!(link_type, LinkType::Collapsed | LinkType::CollapsedUnknown)
                    && source[range.end..].starts_with("[]") =>
            {
                range.end + 2
            }
            _ => range.end,
        };
        if let Some(top) = stack.last_mut() {
            top.first_child.get_or_insert(range.start);
            top.child_end = end;
        }
        let unit = match (&event, stack.as_slice()) {
            (Event::Start(Tag::List(_) | Tag::Table(_)), []) => None,
            (Event::Start(Tag::Item), [list]) if list.container == Container::List => {
                Some(BlockKind::Item)
            }
            (Event::Start(Tag::TableHead), [table]) if table.container == Container::Table => {
                Some(BlockKind::TableHead)
            }
            (Event::Start(Tag::TableRow), [table]) if table.container == Container::Table => {
                Some(BlockKind::TableRow)
            }
            (Event::Start(tag), []) => Some(block_kind(tag)),
            (Event::Rule, []) => Some(BlockKind::ThematicBreak),
            _ => None,
        }
        .map(|kind| {
            walk.blocks.push((kind, range.clone()));
            walk.blocks.len() - 1
        });
        let (start, stop) = (range.start, range.end);
        let leaf = match &event {
            Event::Code(_) => Some((
                TokenKind::InlineCode,
                marks(source, TokenKind::InlineCode, range.clone(), None, start, 0),
            )),
            Event::InlineMath(_) => Some((TokenKind::InlineMath, between(start, stop, 1, 1))),
            Event::DisplayMath(_) => Some((TokenKind::DisplayMath, between(start, stop, 2, 2))),
            Event::FootnoteReference(_) => {
                Some((TokenKind::FootnoteReference, between(start, stop, 2, 1)))
            }
            Event::TaskListMarker(checked) => Some((
                TokenKind::TaskBox { checked: *checked },
                between(start, stop, 1, 1),
            )),
            Event::InlineHtml(_) => Some((TokenKind::Html, [start, start, stop, stop])),
            _ => None,
        };
        if let Some((kind, offsets)) = leaf
            && well_formed(source, kind, &offsets)
        {
            // pulldown-cmark reports an item's task box inside the paragraph or heading after it.
            match kind {
                TokenKind::TaskBox { .. } => walk.extra.push((kind, offsets)),
                _ => walk.tokens.push((kind, offsets)),
            }
            if let Some(top) = stack.last_mut() {
                top.inner_end = top.inner_end.max(offsets[3]);
            }
        }
        if let Event::Text(_) = event
            && let Some(top) = stack.last()
            && top.container != Container::Code
        {
            let own = texts.len() > top.texts;
            match texts.last_mut() {
                Some(run) if own && run.end == range.start => run.end = range.end,
                _ => texts.push(range.clone()),
            }
        }
        let Event::Start(tag) = event else {
            after_quote = false;
            continue;
        };
        if let Tag::FootnoteDefinition(label) = &tag {
            walk.footnotes.push((label.to_string(), start));
        }
        if matches!(tag, Tag::Paragraph) && after_quote {
            callout = Some(start);
        }
        after_quote = matches!(tag, Tag::BlockQuote(_));
        let token = token_kind(&tag).map(|kind| {
            walk.tokens.push((kind, [start; 4]));
            walk.tokens.len() - 1
        });
        let container = match tag {
            Tag::List(_) => Container::List,
            Tag::Table(_) => Container::Table,
            Tag::CodeBlock(_) | Tag::HtmlBlock | Tag::MetadataBlock(_) => Container::Code,
            _ => Container::Other,
        };
        stack.push(Node {
            texts: texts.len(),
            container,
            token,
            unit,
            range,
            end,
            first_child: None,
            child_end: start,
            inner_end: 0,
        });
    }

    let mut definitions = Vec::new();
    for (label, definition) in events.reference_definitions().iter() {
        let span = definition.span.clone();
        walk.links.push((label.to_owned(), span.clone()));
        definitions.push(span);
    }
    walk.units(source, definitions);
    walk.tokens.retain(|(_, offsets)| *offsets != REMOVED);
    let order = |(_, [start, .., end]): &(TokenKind, [usize; 4])| (*start, std::cmp::Reverse(*end));
    debug_assert!(walk.tokens.is_sorted_by_key(order));
    walk.extra.sort_by_key(order);
    let mut tokens = Vec::with_capacity(walk.tokens.len() + walk.extra.len());
    let mut extra = walk.extra.drain(..).peekable();
    for token in walk.tokens.drain(..) {
        while let Some(next) = extra.next_if(|next| order(next) < order(&token)) {
            tokens.push(next);
        }
        tokens.push(token);
    }
    tokens.extend(extra);
    // pulldown-cmark can report a child of a wikilink outside the wikilink's text; a token that does not nest in its
    // parent's content goes.
    let mut parents: Vec<[usize; 4]> = Vec::new();
    tokens.retain(|(_, offsets)| {
        let [start, .., end] = *offsets;
        while parents.last().is_some_and(|parent| parent[3] <= start) {
            parents.pop();
        }
        let nests = parents
            .last()
            .is_none_or(|parent| parent[1] <= start && end <= parent[2]);
        if nests {
            parents.push(*offsets);
        }
        nests
    });
    walk.tokens = tokens;
    walk
}

impl Walk {
    /// Blocks as whole lines, with the definitions no other block holds. pulldown-cmark reports only a label's first
    /// definition, so text outside every block is the rest: each run of it is a block, its first definitions tokens.
    fn units(&mut self, source: &str, definitions: Vec<Range<usize>>) {
        // pulldown-cmark can start two blocks on one line, as with `[^1]:[^1]: a`; they are one.
        let mut lined: Vec<(BlockKind, Range<usize>)> = Vec::with_capacity(self.blocks.len());
        for (kind, range) in self.blocks.drain(..) {
            let range = lines(source, range);
            match lined.last_mut() {
                Some((_, before)) if range.start < before.end => {
                    before.end = before.end.max(range.end)
                }
                _ => lined.push((kind, range)),
            }
        }
        let mut outside: Vec<(BlockKind, Range<usize>)> = definitions
            .into_iter()
            .filter(|span| {
                let before = lined.partition_point(|(_, range)| range.start <= span.start);
                before == 0 || lined[before - 1].1.end <= span.start
            })
            .map(|span| (BlockKind::Definition, lines(source, span)))
            .collect();
        lined.append(&mut outside);
        lined.sort_by_key(|(_, range)| range.start);
        self.blocks = lined;
        // Whitespace lines can be a block's content, as in a fence left open at the end.
        for (_, offsets) in &self.tokens {
            let [start, .., end] = *offsets;
            let index = self
                .blocks
                .partition_point(|(_, range)| range.start <= start);
            if *offsets != REMOVED
                && let Some((_, range)) = index.checked_sub(1).map(|index| &mut self.blocks[index])
                && range.contains(&start)
                && end > range.end
            {
                range.end = line_after(source, end);
            }
        }
        let mut gaps = Vec::new();
        let mut at = 0;
        for index in 0..=self.blocks.len() {
            let (start, end) = self
                .blocks
                .get(index)
                .map_or((source.len(), source.len()), |(_, range)| {
                    (range.start, range.end)
                });
            let gap = &source[at..start.max(at)];
            let first = blank_lines(gap);
            if first < gap.len() {
                gaps.push(lines(source, at + first..start));
            }
            at = at.max(end);
        }
        self.blocks
            .extend(gaps.into_iter().map(|gap| (BlockKind::Definition, gap)));
        self.blocks.sort_by_key(|(_, range)| range.start);
        // A block that parses only after the one above joins it: definitions start a paragraph, so a paragraph or
        // setext heading right after them is the same block, and a line indented four columns starts code unless the
        // block above continues into it.
        let mut merged: Vec<(BlockKind, Range<usize>)> = Vec::with_capacity(self.blocks.len());
        for (kind, range) in self.blocks.drain(..) {
            let indent = source[range.clone()]
                .bytes()
                .take_while(|byte| matches!(byte, b' ' | b'\t'))
                .fold(0, |columns, byte| {
                    if byte == b'\t' {
                        columns + 4 - columns % 4
                    } else {
                        columns + 1
                    }
                });
            match merged.last_mut() {
                Some((last, before))
                    if *last == BlockKind::Definition
                        && before.end == range.start
                        && matches!(
                            kind,
                            BlockKind::Definition
                                | BlockKind::Paragraph
                                | BlockKind::Heading { .. }
                        ) =>
                {
                    *last = kind;
                    before.end = range.end;
                }
                Some((last, before)) if indent >= 4 && kind != BlockKind::Code => {
                    before.end = range.end;
                    // A table's head brings its rows into its window, wherever it starts.
                    if kind == BlockKind::TableHead {
                        *last = kind;
                    }
                }
                _ => merged.push((kind, range)),
            }
        }
        self.blocks = merged;
        // pulldown-cmark reports a label's first definition only, so each block's definitions come from parsing the
        // block alone, which a whole document and a window do alike. A table holds none, and a footnote's own `]:`
        // is not one.
        for (kind, range) in &self.blocks {
            let text = &source[range.clone()];
            let colons = text.matches("]:").take(2).count();
            if matches!(kind, BlockKind::TableHead | BlockKind::TableRow)
                || colons == 0
                || (*kind == BlockKind::FootnoteDefinition && colons == 1)
            {
                continue;
            }
            let mut events = Parser::new_ext(text, OPTIONS).into_offset_iter();
            events.by_ref().for_each(drop);
            for (_, definition) in events.reference_definitions().iter() {
                let span = range.start + definition.span.start..range.start + definition.span.end;
                self.extra
                    .push((TokenKind::Definition, definition_marks(source, span)));
            }
        }
    }

    fn close(&mut self, source: &str, node: Node, parent: Option<&mut Node>) {
        let reach = self.finish(source, &node, parent.as_deref());
        if let Some(parent) = parent {
            parent.inner_end = parent.inner_end.max(reach);
        }
    }

    /// Sets the node's token, and returns the end of the tokens it holds.
    fn finish(&mut self, source: &str, node: &Node, parent: Option<&Node>) -> usize {
        let Some(index) = node.token else {
            return node.inner_end;
        };
        let kind = self.tokens[index].0;
        // pulldown-cmark pads a short row with empty cells after its last one.
        if kind == TokenKind::TableCell
            && node.range.is_empty()
            && parent.is_some_and(|row| {
                let text = &source[row.range.clone()];
                node.range.start >= row.range.start + text.trim_end_matches(['\n', '\r']).len()
            })
        {
            self.tokens[index].1 = REMOVED;
            return node.inner_end;
        }
        let offsets = marks(
            source,
            kind,
            node.range.start..node.end,
            node.first_child,
            node.child_end,
            node.inner_end,
        );
        if !well_formed(source, kind, &offsets) {
            self.tokens[index].1 = REMOVED;
            return node.inner_end;
        }
        self.tokens[index].1 = offsets;
        if kind == TokenKind::TableHead
            && let Some(unit) = node.unit
        {
            self.blocks[unit].1.end = offsets[3];
        }
        offsets[3].max(node.inner_end)
    }
}

fn block_kind(tag: &Tag<'_>) -> BlockKind {
    match tag {
        Tag::Heading { level, .. } => BlockKind::Heading {
            level: *level as u8,
        },
        Tag::BlockQuote(_) => BlockKind::Quote,
        Tag::CodeBlock(_) => BlockKind::Code,
        Tag::HtmlBlock => BlockKind::Html,
        Tag::FootnoteDefinition(_) => BlockKind::FootnoteDefinition,
        Tag::MetadataBlock(_) => BlockKind::FrontMatter,
        _ => BlockKind::Paragraph,
    }
}

fn token_kind(tag: &Tag<'_>) -> Option<TokenKind> {
    Some(match tag {
        Tag::Heading { level, .. } => TokenKind::Heading {
            level: *level as u8,
        },
        Tag::Emphasis => TokenKind::Emphasis,
        Tag::Strong => TokenKind::Strong,
        Tag::Strikethrough => TokenKind::Strikethrough,
        Tag::Link {
            link_type: LinkType::WikiLink { .. },
            ..
        } => TokenKind::WikiLink,
        Tag::Link { .. } => TokenKind::Link,
        Tag::Image {
            link_type: LinkType::WikiLink { .. },
            ..
        } => TokenKind::Embed,
        Tag::Image { .. } => TokenKind::Image,
        Tag::CodeBlock(CodeBlockKind::Fenced(_)) => TokenKind::FencedCode,
        Tag::BlockQuote(_) => TokenKind::Quote,
        Tag::Item => TokenKind::Item,
        Tag::TableHead => TokenKind::TableHead,
        Tag::TableRow => TokenKind::TableRow,
        Tag::TableCell => TokenKind::TableCell,
        Tag::FootnoteDefinition(_) => TokenKind::FootnoteDefinition,
        _ => return None,
    })
}

/// Whether a token's offsets are in order, on character boundaries, and around its syntax. pulldown-cmark can split a
/// code span, math, emphasis or a link at a wikilink's `|`, leaving a lone delimiter.
fn well_formed(text: &str, kind: TokenKind, offsets: &[usize; 4]) -> bool {
    let [start, content_start, content_end, end] = *offsets;
    if !offsets.is_sorted() || !offsets.iter().all(|&at| text.is_char_boundary(at)) {
        return false;
    }
    let (open, close) = (&text[start..content_start], &text[content_end..end]);
    let delimiter = match kind {
        TokenKind::Emphasis | TokenKind::Strong => ['*', '_'].as_slice(),
        TokenKind::Strikethrough => &['~'],
        TokenKind::InlineCode => &['`'],
        TokenKind::InlineMath => return (open, close) == ("$", "$"),
        TokenKind::DisplayMath => return (open, close) == ("$$", "$$"),
        TokenKind::FootnoteReference => return (open, close) == ("[^", "]"),
        TokenKind::TaskBox { .. } => return (open, close) == ("[", "]"),
        TokenKind::Link => {
            return (open == "[" && close.starts_with(']')) || (open == "<" && close == ">");
        }
        TokenKind::Image => return open == "![" && close.starts_with(']'),
        TokenKind::WikiLink => return open.starts_with("[[") && close == "]]",
        TokenKind::Embed => return open.starts_with("![[") && close == "]]",
        _ => return true,
    };
    !open.is_empty() && open == close && open.trim_start_matches(delimiter).is_empty()
}

/// Offsets with `open` bytes of opening marker and `close` of closing, as far as the range allows.
fn between(start: usize, end: usize, open: usize, close: usize) -> [usize; 4] {
    let content_start = (start + open).min(end);
    [
        start,
        content_start,
        end.saturating_sub(close).max(content_start),
        end,
    ]
}

/// `[` and `]:`, the destination and the title, around a definition's label.
fn definition_marks(source: &str, span: Range<usize>) -> [usize; 4] {
    let end = span.start
        + source[span.clone()]
            .trim_end_matches(|c: char| c.is_ascii_whitespace())
            .len();
    let bytes = source.as_bytes();
    let Some(open) = source[span.start..end]
        .find('[')
        .map(|at| span.start + at + 1)
    else {
        return [span.start, span.start, end, end];
    };
    let mut close = open;
    while close < end && bytes[close] != b']' {
        close += if bytes[close] == b'\\' { 2 } else { 1 };
    }
    [span.start, open, close.min(end), end]
}

/// `[!type]`, with `+` or `-` when it folds, before a blank or the end: where the type and the marker end.
fn callout_marker(source: &str, at: usize) -> Option<(usize, usize)> {
    let rest = source[at..].strip_prefix("[!")?;
    let name = rest.len()
        - rest
            .trim_start_matches(|c: char| c.is_ascii_alphanumeric() || c == '-' || c == '_')
            .len();
    let after = rest[name..].strip_prefix(']')?;
    let end = at + 2 + name + 1 + usize::from(after.starts_with(['+', '-']));
    (name > 0 && source[end..].chars().next().is_none_or(char::is_whitespace))
        .then_some((at + 2 + name, end))
}

/// Byte offsets `[start, content_start, content_end, end]` of a token over `range` whose children start at
/// `first_child` and end at `child_end`.
fn marks(
    text: &str,
    kind: TokenKind,
    range: Range<usize>,
    first_child: Option<usize>,
    child_end: usize,
    inner_end: usize,
) -> [usize; 4] {
    let start = range.start;
    let source = &text[range.clone()];
    // A block's last line, without its terminator or the blank lines after it.
    let last = start
        + source
            .trim_end_matches(|c: char| c.is_ascii_whitespace())
            .len();
    let block_end = (last
        + text[last..range.end]
            .find(['\n', '\r'])
            .unwrap_or(range.end - last))
    .max(inner_end.min(range.end));
    let skip = |at: usize, blanks: &[char]| {
        at + text[at..block_end.max(at)].len()
            - text[at..block_end.max(at)].trim_start_matches(blanks).len()
    };
    match kind {
        TokenKind::Quote
        | TokenKind::Item
        | TokenKind::FootnoteDefinition
        | TokenKind::TableRow => {
            // pulldown-cmark starts an item at the line break or `>` before it when it splits a tab.
            let start = match kind {
                TokenKind::TableRow => start,
                TokenKind::Item => skip(start, &[' ', '\t', '\n', '\r', '>']),
                _ => skip(start, &[' ', '\t', '\n', '\r']),
            };
            let marker = match kind {
                TokenKind::Quote => text[start..block_end].find('>').map(|at| {
                    let after = start + at + 1;
                    after + usize::from(text[after..block_end].starts_with([' ', '\t']))
                }),
                TokenKind::Item => {
                    let at = skip(start, &[' ']);
                    let after = match text.as_bytes().get(at) {
                        Some(b'-' | b'+' | b'*') => at + 1,
                        Some(b'0'..=b'9') => {
                            let digits = at + text[at..].len()
                                - text[at..]
                                    .trim_start_matches(|c: char| c.is_ascii_digit())
                                    .len();
                            digits + usize::from(text[digits..].starts_with(['.', ')']))
                        }
                        _ => at,
                    };
                    Some(skip(after.min(block_end), &[' ', '\t']))
                }
                TokenKind::FootnoteDefinition => text[start..block_end]
                    .find("]:")
                    .map(|at| skip(start + at + 2, &[' ', '\t'])),
                _ => None,
            };
            let content_start = marker
                .unwrap_or(start)
                .min(
                    first_child
                        .filter(|&child| child > start)
                        .unwrap_or(block_end),
                )
                .clamp(start, block_end);
            [start, content_start, block_end, block_end]
        }
        TokenKind::WikiLink | TokenKind::Embed => {
            let open = if kind == TokenKind::Embed { 3 } else { 2 };
            let close = range.end.saturating_sub(2).max(start);
            // An alias follows the target's `|`; anything else from `[[` on is content.
            let content_start = first_child
                .filter(|&child| child > start + open && text[..child].ends_with('|'))
                .unwrap_or(start + open)
                .clamp((start + open).min(close), close);
            [
                start,
                content_start,
                child_end.clamp(content_start, close),
                range.end,
            ]
        }
        TokenKind::TableHead => {
            let header = start + source.trim_end_matches(['\n', '\r']).len();
            let delimiter = &text[range.end..];
            let end = range.end + delimiter.find(['\n', '\r']).unwrap_or(delimiter.len());
            [start, start, header, end]
        }
        TokenKind::TableCell => {
            let content = source.trim_matches([' ', '\t']);
            let content_start = if content.is_empty() {
                start
            } else {
                start + source.len() - source.trim_start_matches([' ', '\t']).len()
            };
            [
                start,
                content_start,
                content_start + content.len(),
                range.end,
            ]
        }
        TokenKind::Heading { .. }
        | TokenKind::Emphasis
        | TokenKind::Strong
        | TokenKind::Strikethrough
        | TokenKind::InlineCode
        | TokenKind::Link
        | TokenKind::Image
        | TokenKind::FencedCode => inline_marks(text, kind, &range, child_end),
        _ => [start, start, range.end, range.end],
    }
}

/// Byte offsets `[start, content_start, content_end, end]` of a span over
/// `range` whose child events end at `child_end`.
fn inline_marks(text: &str, kind: TokenKind, range: &Range<usize>, child_end: usize) -> [usize; 4] {
    let source = &text[range.clone()];
    let source = match kind {
        TokenKind::Heading { .. } | TokenKind::FencedCode => source
            .strip_suffix("\r\n")
            .or_else(|| source.strip_suffix(['\n', '\r']))
            .unwrap_or(source),
        // pulldown-cmark stretches emphasis, strong, strikethrough or code that
        // ends an ATX heading over the heading's trailing blanks.
        _ => source.trim_end_matches(BLANK),
    };
    let (start, end) = (range.start, range.start + source.len());
    let marker = match kind {
        TokenKind::Emphasis | TokenKind::Link => 1,
        TokenKind::Strong | TokenKind::Image => 2,
        TokenKind::Strikethrough => source.len() - source.trim_start_matches('~').len(),
        TokenKind::InlineCode => source.len() - source.trim_start_matches('`').len(),
        // A setext heading hides only its underline.
        TokenKind::Heading { .. } if source.contains(['\n', '\r']) => 0,
        TokenKind::Heading { .. } => {
            let rest = source.trim_start_matches('#').trim_start_matches(BLANK);
            source.len() - rest.len()
        }
        TokenKind::FencedCode => source.find('\n').map_or(source.len(), |at| at + 1),
        _ => 0,
    };
    let content_start = start + marker;
    let child_end = child_end.clamp(content_start, end);
    let content_end = match kind {
        TokenKind::Emphasis
        | TokenKind::Strong
        | TokenKind::Strikethrough
        | TokenKind::InlineCode => end - marker,
        // Text that ends at a line break leaves the next line's `>` or indent
        // before the `]`, outside every child event.
        TokenKind::Link | TokenKind::Image => {
            child_end + text[child_end..end].find(']').unwrap_or(0)
        }
        // Inline HTML can run over a setext heading's last line break, which the underline keeps.
        TokenKind::Heading { .. } => {
            let child_end = match source.rfind('\n').or_else(|| source.rfind('\r')) {
                Some(at) if marker == 0 => {
                    let line_break = start + at - usize::from(source[..at].ends_with('\r'));
                    child_end.min(line_break).max(content_start)
                }
                _ => child_end,
            };
            content_start + text[content_start..child_end].trim_end_matches(BLANK).len()
        }
        _ => child_end,
    };
    [start, content_start, content_end, end]
}

/// The Obsidian syntax pulldown-cmark lacks, in one node's runs of text: `%%comments%%`, `==highlights==` and `#tags`.
/// A pair's two markers have one parent, so whatever lies between them nests inside it.
fn extend(source: &str, runs: &[Range<usize>], tokens: &mut Vec<(TokenKind, [usize; 4])>) {
    let bytes = source.as_bytes();
    // Where two of `byte` start, left to right and without overlap.
    let doubles = |byte: u8| {
        let mut found = Vec::new();
        for run in runs {
            let mut at = run.start;
            while at + 1 < run.end {
                if bytes[at] == byte && bytes[at + 1] == byte {
                    found.push(at);
                    at += 2;
                } else {
                    at += 1;
                }
            }
        }
        found
    };
    let comments: Vec<Range<usize>> = doubles(b'%')
        .as_chunks::<2>()
        .0
        .iter()
        .map(|[open, close]| *open..close + 2)
        .collect();
    for comment in &comments {
        tokens.push((
            TokenKind::Comment,
            between(comment.start, comment.end, 2, 2),
        ));
    }
    // Whether `at`, which only grows from one call to the next, is outside every comment.
    let outside = || {
        let mut comments = comments.iter().peekable();
        move |at: usize| {
            while comments.next_if(|comment| comment.end <= at).is_some() {}
            comments.peek().is_none_or(|comment| at < comment.start)
        }
    };

    let mut open: Option<usize> = None;
    let mut uncommented = outside();
    for at in doubles(b'=') {
        if !uncommented(at) || (at > 0 && bytes[at - 1] == b'=') || bytes.get(at + 2) == Some(&b'=')
        {
            continue;
        }
        let closes = source[..at]
            .chars()
            .next_back()
            .is_some_and(|c| !c.is_whitespace());
        let opens = source[at + 2..]
            .chars()
            .next()
            .is_some_and(|c| !c.is_whitespace());
        match open {
            Some(start) if closes && at > start + 2 => {
                tokens.push((TokenKind::Highlight, [start, start + 2, at, at + 2]));
                open = None;
            }
            _ if opens => open = Some(at),
            _ => {}
        }
    }

    let mut uncommented = outside();
    for run in runs {
        for at in (run.start..run.end).filter(|&at| bytes[at] == b'#') {
            let follows_blank = source[..at]
                .chars()
                .next_back()
                .is_none_or(char::is_whitespace);
            let name = &source[at + 1..run.end];
            let length = name.len()
                - name
                    .trim_start_matches(|c: char| {
                        c.is_alphanumeric() || matches!(c, '_' | '-' | '/')
                    })
                    .len();
            if follows_blank
                && uncommented(at)
                && !name[..length].bytes().all(|byte| byte.is_ascii_digit())
            {
                tokens.push((
                    TokenKind::Tag,
                    [at, at + 1, at + 1 + length, at + 1 + length],
                ));
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    // 7 UTF-16 units before each span, 6 inside it.
    const BEFORE: &str = "é日本語🙂 ";
    const INSIDE: &str = "é日本語🙂";

    fn span(kind: SpanKind, start: u32, content_start: u32, content_end: u32, end: u32) -> Span {
        Span {
            kind,
            start,
            end,
            content_start,
            content_end,
        }
    }

    /// Each span as its opening marker, content and closing marker.
    fn split(text: &str) -> Vec<(SpanKind, [&str; 3])> {
        let byte: Vec<usize> = text
            .char_indices()
            .flat_map(|(at, c)| [at; 2].into_iter().take(c.len_utf16()))
            .chain([text.len()])
            .collect();
        spans(text)
            .into_iter()
            .map(|s| {
                let [a, b, c, d] =
                    [s.start, s.content_start, s.content_end, s.end].map(|at| byte[at as usize]);
                (s.kind, [&text[a..b], &text[b..c], &text[c..d]])
            })
            .collect()
    }

    #[test]
    fn heading() {
        let text = format!("{BEFORE}\n\n## {INSIDE} ##\n");
        assert_eq!(
            spans(&text),
            [span(SpanKind::Heading { level: 2 }, 9, 12, 18, 21)]
        );
    }

    #[test]
    fn setext_heading() {
        let text = format!("{BEFORE}\n\n{INSIDE}\n===\n");
        assert_eq!(
            spans(&text),
            [span(SpanKind::Heading { level: 1 }, 9, 9, 15, 19)]
        );
        assert_eq!(split(&text)[0].1[2], "\n===");
    }

    #[test]
    fn emphasis() {
        let text = format!("{BEFORE}*{INSIDE}*");
        assert_eq!(spans(&text), [span(SpanKind::Emphasis, 7, 8, 14, 15)]);
    }

    #[test]
    fn strong() {
        let text = format!("{BEFORE}**{INSIDE}**");
        assert_eq!(spans(&text), [span(SpanKind::Strong, 7, 9, 15, 17)]);
    }

    #[test]
    fn strikethrough() {
        let text = format!("{BEFORE}~~{INSIDE}~~");
        assert_eq!(spans(&text), [span(SpanKind::Strikethrough, 7, 9, 15, 17)]);
    }

    #[test]
    fn inline_code() {
        let text = format!("{BEFORE}`` a`{INSIDE} ``");
        assert_eq!(spans(&text), [span(SpanKind::InlineCode, 7, 9, 19, 21)]);
    }

    #[test]
    fn link() {
        let text = format!("{BEFORE}[{INSIDE}](🙂)");
        assert_eq!(spans(&text), [span(SpanKind::Link, 7, 8, 14, 19)]);
    }

    #[test]
    fn image() {
        let text = format!("{BEFORE}![{INSIDE}](🙂)");
        assert_eq!(spans(&text), [span(SpanKind::Image, 7, 9, 15, 20)]);
    }

    #[test]
    fn fenced_code() {
        let text = format!("{BEFORE}\n\n```\n{INSIDE}\n```\n");
        assert_eq!(spans(&text), [span(SpanKind::FencedCode, 9, 13, 20, 23)]);
    }

    #[test]
    fn outer_spans_come_before_inner_ones() {
        assert_eq!(
            spans("***z*** [`c`](u)"),
            [
                span(SpanKind::Emphasis, 0, 1, 6, 7),
                span(SpanKind::Strong, 1, 3, 4, 6),
                span(SpanKind::Link, 8, 9, 12, 16),
                span(SpanKind::InlineCode, 9, 10, 11, 12),
            ]
        );
    }

    #[test]
    fn an_escape_at_content_start_is_content() {
        assert_eq!(
            split(r"[\[1\]](#ref)"),
            [(SpanKind::Link, ["[", r"\[1\]", "](#ref)"])]
        );
        assert_eq!(
            split(r"**\*nix**"),
            [(SpanKind::Strong, ["**", r"\*nix", "**"])]
        );
        assert_eq!(
            split(r"# \#1 priority"),
            [(SpanKind::Heading { level: 1 }, ["# ", r"\#1 priority", ""])]
        );
        assert_eq!(
            split("\\*a\n==="),
            [(SpanKind::Heading { level: 1 }, ["", r"\*a", "\n==="])]
        );
    }

    #[test]
    fn a_fence_in_a_list_or_quote_opens_with_its_own_line() {
        assert_eq!(
            split("- step:\n  ```sh\n  make\n  make install\n  ```"),
            [(
                SpanKind::FencedCode,
                ["```sh\n", "  make\n  make install\n", "  ```"]
            )]
        );
        assert_eq!(
            split("> ```\n> a\n> b\n> ```"),
            [(SpanKind::FencedCode, ["```\n", "> a\n> b\n", "> ```"])]
        );
    }

    #[test]
    fn blanks_after_a_heading_stay_out_of_its_inline_spans() {
        assert_eq!(
            split("# t `c`\t"),
            [
                (SpanKind::Heading { level: 1 }, ["# ", "t `c`", "\t"]),
                (SpanKind::InlineCode, ["`", "c", "`"]),
            ]
        );
        assert_eq!(
            split("# *a*\t"),
            [
                (SpanKind::Heading { level: 1 }, ["# ", "*a*", "\t"]),
                (SpanKind::Emphasis, ["*", "a", "*"]),
            ]
        );
        assert_eq!(
            split("## **a**\x0b"),
            [
                (SpanKind::Heading { level: 2 }, ["## ", "**a**", "\x0b"]),
                (SpanKind::Strong, ["**", "a", "**"]),
            ]
        );
        assert_eq!(
            split("### ~b~\x0c"),
            [
                (SpanKind::Heading { level: 3 }, ["### ", "~b~", "\x0c"]),
                (SpanKind::Strikethrough, ["~", "b", "~"]),
            ]
        );
    }

    #[test]
    fn link_text_ending_at_a_line_break_keeps_the_next_line_prefix() {
        assert_eq!(
            split(">~1. [\r\n>](u)"),
            [(SpanKind::Link, ["[", "\r\n>", "](u)"])]
        );
        assert_eq!(
            split("- [a\n  ](u)"),
            [(SpanKind::Link, ["[", "a\n  ", "](u)"])]
        );
    }

    #[test]
    fn a_collapsed_reference_ends_after_its_brackets() {
        assert_eq!(
            split("[x]: /u\n\n[![x][]](v) [x][]"),
            [
                (SpanKind::Link, ["[", "![x][]", "](v)"]),
                (SpanKind::Image, ["![", "x", "][]"]),
                (SpanKind::Link, ["[", "x", "][]"]),
            ]
        );
        assert_eq!(
            split("[x]: /u\n\n# a [x][]"),
            [
                (SpanKind::Heading { level: 1 }, ["# ", "a [x][]", ""]),
                (SpanKind::Link, ["[", "x", "][]"]),
            ]
        );
    }

    #[test]
    fn a_trailing_crlf_stays_out_of_block_spans() {
        assert_eq!(
            split("# a\r\n"),
            [(SpanKind::Heading { level: 1 }, ["# ", "a", ""])]
        );
        assert_eq!(
            split("b\r\n---\r\n"),
            [(SpanKind::Heading { level: 2 }, ["", "b", "\r\n---"])]
        );
        assert_eq!(
            split("```\r\nc\r\n```\r\n"),
            [(SpanKind::FencedCode, ["```\r\n", "c\r\n", "```"])]
        );
    }

    #[test]
    fn a_lone_cr_ends_a_block_line() {
        assert_eq!(
            split("# a\r"),
            [(SpanKind::Heading { level: 1 }, ["# ", "a", ""])]
        );
        assert_eq!(
            split("#b\r==="),
            [(SpanKind::Heading { level: 1 }, ["", "#b", "\r==="])]
        );
    }

    #[test]
    fn an_atx_opener_takes_every_blank_after_its_hashes() {
        assert_eq!(
            split("#\ta"),
            [(SpanKind::Heading { level: 1 }, ["#\t", "a", ""])]
        );
        assert_eq!(
            split("##\x0b\x0cb"),
            [(SpanKind::Heading { level: 2 }, ["##\x0b\x0c", "b", ""])]
        );
    }

    #[test]
    fn an_unclosed_fence_runs_to_the_end_of_the_text() {
        assert_eq!(
            split("```\na\n"),
            [(SpanKind::FencedCode, ["```\n", "a", ""])]
        );
        assert_eq!(
            split("~~~\nb"),
            [(SpanKind::FencedCode, ["~~~\n", "b", ""])]
        );
    }

    #[test]
    fn empty_content() {
        assert_eq!(
            split("#"),
            [(SpanKind::Heading { level: 1 }, ["#", "", ""])]
        );
        assert_eq!(
            split("## ##"),
            [(SpanKind::Heading { level: 2 }, ["## ", "", "##"])]
        );
        assert_eq!(
            split("[](u) ![](v)"),
            [
                (SpanKind::Link, ["[", "", "](u)"]),
                (SpanKind::Image, ["![", "", "](v)"]),
            ]
        );
        assert_eq!(
            split("```\n```"),
            [(SpanKind::FencedCode, ["```\n", "", "```"])]
        );
    }

    // Mostly single syntax characters: at the default case count, a uniform
    // mix with longer tokens rarely builds a span.
    fn markdown() -> impl Strategy<Value = String> {
        let piece = prop_oneof![
            12 => prop::sample::select(vec![
                "-", "*", "_", "~", "`", "#", "!", "[", "]", "(", ")", "<", ">", "=", ":", " ",
                "\\", "\t", "\x0b", "\n", "é", "🙂", "a",
            ]),
            2 => Just("```"),
            2 => Just("**"),
            1 => Just("\r\n"),
            1 => Just("\n> "),
            1 => Just("\n- "),
            1 => Just("  "),
            1 => Just("](u)"),
            1 => Just("][]"),
            1 => Just("[a]: u\n"),
        ];
        let text = prop::collection::vec(piece, 0..48).prop_map(|pieces| pieces.concat());
        prop_oneof!["\\PC*", text]
    }

    proptest! {
        #[test]
        fn offsets_nest_and_never_split_a_surrogate_pair(text in markdown()) {
            let units: Vec<u16> = text.encode_utf16().collect();
            let found = spans(&text);
            for s in &found {
                prop_assert!(s.start <= s.content_start);
                prop_assert!(s.content_start <= s.content_end);
                prop_assert!(s.content_end <= s.end);
                prop_assert!(s.end as usize <= units.len());
                for at in [s.start, s.content_start, s.content_end, s.end] {
                    prop_assert!(units.get(at as usize).is_none_or(|u| !(0xDC00..0xE000).contains(u)));
                }
            }
            for pair in found.windows(2) {
                prop_assert!((pair[0].start, pair[1].end) <= (pair[1].start, pair[0].end));
            }
            let mut parents: Vec<&Span> = Vec::new();
            for s in &found {
                while parents.last().is_some_and(|p| p.end <= s.start) {
                    parents.pop();
                }
                if let Some(p) = parents.last() {
                    prop_assert!(p.content_start <= s.start && s.end <= p.content_end, "{s:?} in {p:?}");
                }
                parents.push(s);
            }
        }

        #[test]
        fn markers_hold_only_syntax(text in markdown()) {
            for (kind, [open, content, close]) in split(&text) {
                let syntax = match kind {
                    SpanKind::Emphasis => matches!(open, "*" | "_") && close == open,
                    SpanKind::Strong => matches!(open, "**" | "__") && close == open,
                    SpanKind::Strikethrough => matches!(open, "~" | "~~") && close == open,
                    SpanKind::InlineCode => {
                        open.starts_with('`') && open.trim_start_matches('`').is_empty() && close == open
                    }
                    SpanKind::Link => {
                        (open == "[" && close.starts_with(']')) || (open == "<" && close == ">")
                    }
                    SpanKind::Image => open == "![" && close.starts_with(']'),
                    SpanKind::Heading { level } => {
                        let atx = open.trim_end_matches(BLANK) == "#".repeat(level.into());
                        let setext = open.is_empty() && close.contains(['\n', '\r']);
                        ((atx && !content.starts_with(BLANK)) || setext) && !content.ends_with(BLANK)
                    }
                    SpanKind::FencedCode => {
                        (open.starts_with("```") || open.starts_with("~~~"))
                            && open.find('\n').is_none_or(|at| at + 1 == open.len())
                    }
                };
                prop_assert!(syntax, "{kind:?} {open:?} {content:?} {close:?} in {text:?}");
            }
        }
    }

    // The parser the editor uses.

    /// The byte offset of each UTF-16 offset in `text`, and of its end.
    fn bytes_of(text: &str) -> Vec<usize> {
        text.char_indices()
            .flat_map(|(at, c)| [at; 2].into_iter().take(c.len_utf16()))
            .chain([text.len()])
            .collect()
    }

    /// Each token as its opening marker, content and closing marker.
    fn show(text: &str) -> Vec<(TokenKind, [&str; 3])> {
        let byte = bytes_of(text);
        parse(text)
            .tokens
            .into_iter()
            .map(|t| {
                let [a, b, c, d] =
                    [t.start, t.content_start, t.content_end, t.end].map(|at| byte[at as usize]);
                (t.kind, [&text[a..b], &text[b..c], &text[c..d]])
            })
            .collect()
    }

    fn kinds(text: &str) -> Vec<BlockKind> {
        parse(text).blocks.iter().map(|b| b.kind).collect()
    }

    fn block_text(text: &str) -> Vec<(BlockKind, &str)> {
        let byte = bytes_of(text);
        parse(text)
            .blocks
            .iter()
            .map(|b| (b.kind, &text[byte[b.start as usize]..byte[b.end as usize]]))
            .collect()
    }

    fn syntax(kind: TokenKind, open: &str, content: &str, close: &str) -> bool {
        let blanks = |s: &str| s.chars().all(|c| matches!(c, ' ' | '\t'));
        match kind {
            TokenKind::Emphasis => matches!(open, "*" | "_") && close == open,
            TokenKind::Strong => matches!(open, "**" | "__") && close == open,
            TokenKind::Strikethrough => matches!(open, "~" | "~~") && close == open,
            TokenKind::InlineCode => {
                open.starts_with('`') && open.trim_start_matches('`').is_empty() && close == open
            }
            TokenKind::Link => {
                (open == "[" && close.starts_with(']')) || (open == "<" && close == ">")
            }
            TokenKind::Image => open == "![" && close.starts_with(']'),
            TokenKind::Heading { level } => {
                let atx = open.trim_end_matches(BLANK) == "#".repeat(level.into());
                let setext = open.is_empty() && close.contains(['\n', '\r']);
                ((atx && !content.starts_with(BLANK)) || setext) && !content.ends_with(BLANK)
            }
            TokenKind::FencedCode => {
                let fence = open.trim_start_matches(' ');
                (fence.starts_with("```") || fence.starts_with("~~~"))
                    && open.find('\n').is_none_or(|at| at + 1 == open.len())
            }
            TokenKind::Quote => {
                let rest = open.trim_start_matches(' ');
                rest.starts_with('>') && blanks(&rest[1..]) && rest.len() <= 2 && close.is_empty()
            }
            TokenKind::Callout => {
                open == "[!"
                    && matches!(close, "]" | "]+" | "]-")
                    && !content.is_empty()
                    && content
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
            }
            TokenKind::Item => {
                let marker = open.trim_start_matches(' ').trim_end_matches([' ', '\t']);
                let ordered = marker.len() > 1
                    && marker.ends_with(['.', ')'])
                    && marker[..marker.len() - 1]
                        .bytes()
                        .all(|b| b.is_ascii_digit());
                (matches!(marker, "-" | "+" | "*") || ordered) && close.is_empty()
            }
            TokenKind::TaskBox { .. } => {
                open == "[" && close == "]" && content.chars().count() == 1
            }
            TokenKind::TableHead => {
                open.is_empty()
                    && close.starts_with(['\n', '\r'])
                    && close
                        .chars()
                        .all(|c| matches!(c, '|' | '-' | ':' | ' ' | '\t' | '\n' | '\r' | '>'))
            }
            TokenKind::TableRow | TokenKind::Html => open.is_empty() && close.is_empty(),
            TokenKind::TableCell => blanks(open) && blanks(close),
            TokenKind::FootnoteReference => open == "[^" && close == "]",
            TokenKind::FootnoteDefinition => {
                let label = open.trim_end_matches([' ', '\t']);
                label.starts_with("[^") && label.ends_with("]:") && close.is_empty()
            }
            TokenKind::Definition => open.trim_start_matches(' ') == "[" && close.starts_with("]:"),
            TokenKind::InlineMath => open == "$" && close == "$",
            TokenKind::DisplayMath => open == "$$" && close == "$$",
            TokenKind::WikiLink => {
                open.starts_with("[[") && (open.len() == 2 || open.ends_with('|')) && close == "]]"
            }
            TokenKind::Embed => {
                open.starts_with("![[") && (open.len() == 3 || open.ends_with('|')) && close == "]]"
            }
            TokenKind::Highlight => open == "==" && close == "==",
            TokenKind::Comment => open == "%%" && close == "%%",
            TokenKind::Tag => open == "#" && !content.is_empty() && close.is_empty(),
            TokenKind::FrontMatter => {
                open.trim_end() == "---" && matches!(close.trim_end_matches(' '), "---" | "...")
            }
        }
    }

    /// The marker property: offsets are ordered, in bounds and whole characters; tokens nest inside their parents'
    /// content and their blocks; markers hold only syntax; and hidden markers plus visible text are the source.
    fn check_markers(text: &str, parse: &Parse) -> Result<(), String> {
        let units: Vec<u16> = text.encode_utf16().collect();
        let whole = |at: u32| {
            (at as usize) <= units.len()
                && units
                    .get(at as usize)
                    .is_none_or(|u| !(0xDC00..0xE000).contains(u))
        };
        let mut previous = 0;
        for b in &parse.blocks {
            let line_start = b.start == 0 || matches!(units[b.start as usize - 1], 0x0A | 0x0D);
            let line_end =
                b.end as usize == units.len() || matches!(units[b.end as usize - 1], 0x0A | 0x0D);
            if !(previous <= b.start
                && b.start < b.end
                && whole(b.start)
                && whole(b.end)
                && line_start
                && line_end)
            {
                return Err(format!("block {b:?} after {previous}"));
            }
            previous = b.end;
        }
        let mut hidden = vec![false; units.len()];
        let mut parents: Vec<&Token> = Vec::new();
        for t in &parse.tokens {
            let offsets = [t.start, t.content_start, t.content_end, t.end];
            if !(offsets.is_sorted() && offsets.into_iter().all(whole)) {
                return Err(format!("offsets of {t:?}"));
            }
            if !parse
                .blocks
                .iter()
                .any(|b| b.start <= t.start && t.end <= b.end)
            {
                return Err(format!("{t:?} is in no block"));
            }
            while parents.last().is_some_and(|p| p.end <= t.start) {
                parents.pop();
            }
            if let Some(p) = parents.last()
                && !(p.content_start <= t.start && t.end <= p.content_end)
            {
                return Err(format!("{t:?} in {p:?}"));
            }
            parents.push(t);
            let piece =
                |a: u32, b: u32| String::from_utf16(&units[a as usize..b as usize]).unwrap();
            let [open, content, close] = [
                piece(t.start, t.content_start),
                piece(t.content_start, t.content_end),
                piece(t.content_end, t.end),
            ];
            if !syntax(t.kind, &open, &content, &close) {
                return Err(format!("{:?} {open:?} {content:?} {close:?}", t.kind));
            }
            for at in (t.start..t.content_start).chain(t.content_end..t.end) {
                hidden[at as usize] = true;
            }
        }
        let (mut markers, mut visible, mut rebuilt) = (String::new(), String::new(), String::new());
        for run in hidden.chunk_by(|a, b| a == b) {
            let at = markers.encode_utf16().count() + visible.encode_utf16().count();
            let piece =
                String::from_utf16(&units[at..at + run.len()]).map_err(|e| e.to_string())?;
            if run[0] {
                markers.push_str(&piece)
            } else {
                visible.push_str(&piece)
            }
            rebuilt.push_str(&piece);
        }
        if rebuilt != text {
            return Err("hidden markers and visible text are not the source".into());
        }
        Ok(())
    }

    /// The window an edit in `blocks[index]` reparses, as UTF-16 pieces, and whether it is a table row's.
    /// Whether `text` starts with a blank or a line break, either of which can continue a list item, a footnote or
    /// a fence above it across blank lines.
    fn starts_indented(text: &str) -> bool {
        matches!(text.as_bytes().first(), Some(b' ' | b'\t' | b'\n' | b'\r'))
    }

    /// The block above joins the window when no blank line separates them, or when the window starts with a blank
    /// or a line break; so does a quote, item or footnote right above that one.
    fn window_of(
        blocks: &[Block],
        index: usize,
        indented: &dyn Fn(u32) -> bool,
    ) -> (Vec<Range<u32>>, bool) {
        let head = |i: usize| {
            (0..=i)
                .rev()
                .find(|&j| blocks[j].kind == BlockKind::TableHead)
        };
        let block = blocks[index];
        let mut pieces = Vec::new();
        if block.kind == BlockKind::TableRow
            && let Some(head) = head(index)
        {
            pieces.push(blocks[head].start..blocks[head].end);
            pieces.push(block.start..block.end);
            return (pieces, true);
        }
        // A table's head brings its rows along.
        let rows = match block.kind {
            BlockKind::TableHead => blocks[index + 1..]
                .iter()
                .take_while(|b| b.kind == BlockKind::TableRow)
                .count(),
            _ => 0,
        };
        let start = match index.checked_sub(1).map(|i| (i, blocks[i])) {
            Some((i, above)) if above.end == block.start || indented(block.start) => {
                if above.kind == BlockKind::TableRow
                    && let Some(head) = head(i)
                {
                    pieces.push(blocks[head].start..blocks[head].end);
                }
                // A quote, item or footnote right above that block can take its first line as a lazy continuation.
                match i.checked_sub(1).map(|j| blocks[j]) {
                    Some(container)
                        if container.end == above.start
                            && matches!(
                                container.kind,
                                BlockKind::Quote
                                    | BlockKind::Callout
                                    | BlockKind::Item
                                    | BlockKind::FootnoteDefinition
                            ) =>
                    {
                        container.start
                    }
                    _ => above.start,
                }
            }
            _ => block.start,
        };
        pieces.push(start..blocks[index + rows].end);
        (pieces, false)
    }

    /// Restartability: every block's window parses alone as it does within the whole document, and holds.
    fn check_restart(text: &str) -> Result<(), String> {
        let whole = parse(text);
        let byte = bytes_of(text);
        for index in 0..whole.blocks.len() {
            let indented = |at: u32| starts_indented(&text[byte[at as usize]..]);
            let (pieces, row) = window_of(&whole.blocks, index, &indented);
            let window: String = pieces
                .iter()
                .map(|p| &text[byte[p.start as usize]..byte[p.end as usize]])
                .collect();
            let after = byte[pieces.last().unwrap().end as usize];
            let next_end = {
                let rest = &text[after..];
                let blank = blank_lines(rest);
                if blank == rest.len() {
                    after + blank
                } else {
                    after + line_after(rest, line_after(rest, blank))
                }
            };
            let at_start = pieces[0].start == 0;
            let next = &text[after..next_end];
            let got = parse_window(
                &Window {
                    text: &window,
                    next,
                    at_start,
                    row,
                },
                &whole.labels,
            )
            .ok_or("over the limit")?;
            // Front matter the window opens and does not close may close past it, so that window never holds.
            let open = at_start && matches!(front_matter(&window), Some(Err(())));
            if !got.holds && !open {
                return Err(format!(
                    "window {index} {window:?} next {next:?} does not hold"
                ));
            }
            // Window offsets back to the document, a start at a piece's start and an end at a piece's end.
            let mut starts = Vec::new();
            let mut length = 0;
            for p in &pieces {
                starts.push(length);
                length += p.end - p.start;
            }
            let map = |at: u32, end: bool| {
                let k = if end {
                    starts.iter().rposition(|&s| s < at).unwrap_or(0)
                } else {
                    starts.iter().rposition(|&s| s <= at).unwrap()
                };
                pieces[k].start + at - starts[k]
            };
            let units: Vec<Block> = whole
                .blocks
                .iter()
                .filter(|b| pieces.iter().any(|p| p.start <= b.start && b.end <= p.end))
                .copied()
                .collect();
            let mapped: Vec<Block> = got
                .blocks
                .iter()
                .map(|b| Block {
                    kind: b.kind,
                    start: map(b.start, false),
                    end: map(b.end, true),
                })
                .collect();
            if mapped != units {
                return Err(format!(
                    "window {index} {window:?}: blocks {mapped:?} != {units:?}"
                ));
            }
            let expected: Vec<Token> = whole
                .tokens
                .iter()
                .filter(|t| units.iter().any(|b| b.start <= t.start && t.end <= b.end))
                .copied()
                .collect();
            let mapped: Vec<Token> = got
                .tokens
                .iter()
                .map(|t| Token {
                    kind: t.kind,
                    start: map(t.start, false),
                    content_start: map(t.content_start, false),
                    content_end: map(t.content_end, t.content_end > t.content_start),
                    end: map(t.end, true),
                })
                .collect();
            if mapped != expected {
                return Err(format!(
                    "window {index} {window:?}: tokens {mapped:?} != {expected:?}"
                ));
            }
        }
        Ok(())
    }

    /// The lines after a window that `Window::next` holds.
    fn lookahead(rest: &str) -> &str {
        let blank = blank_lines(rest);
        if blank == rest.len() {
            rest
        } else {
            &rest[..line_after(rest, line_after(rest, blank))]
        }
    }

    /// After an edit inside a block's window, a window that holds leaves every block and token outside it as it was,
    /// and those inside as the window parsed them. A window that held a definition before the edit is the editor's to
    /// reparse, since the label table cannot tell what the edit removed.
    fn check_edit(
        text: &str,
        pick: usize,
        offset: usize,
        delete: usize,
        insert: &str,
    ) -> Result<(), String> {
        let old = parse(text);
        if old.blocks.is_empty() {
            return Ok(());
        }
        let byte = bytes_of(text);
        let index = pick % old.blocks.len();
        let block = old.blocks[index];
        let (ws16, we16) = (block.start, block.end);
        let (ws, we) = (byte[ws16 as usize], byte[we16 as usize]);
        if block.kind == BlockKind::TableRow
            || block.kind == BlockKind::TableHead
            || old.tokens.iter().any(|t| {
                matches!(
                    t.kind,
                    TokenKind::Definition | TokenKind::FootnoteDefinition
                ) && ws16 <= t.start
                    && t.end <= we16
            })
        {
            return Ok(());
        }
        // The edit stays inside the block and off its last line break.
        let last = if text[..we].ends_with("\r\n") {
            we - 2
        } else if text[..we].ends_with(['\n', '\r']) {
            we - 1
        } else {
            we
        };
        let mut from = ws + offset % (last - ws + 1);
        while !text.is_char_boundary(from) {
            from -= 1;
        }
        let mut to = (from + delete).min(last);
        while !text.is_char_boundary(to) {
            to -= 1;
        }
        let edited = format!("{}{insert}{}", &text[..from], &text[to..]);
        let new_we = we + insert.len() - (to - from);
        // The window is cut from the edited text, by the old blocks.
        let new_byte = bytes_of(&edited);
        let indented = |at: u32| starts_indented(&edited[new_byte[at as usize]..]);
        let mut blocks = old.blocks.clone();
        let delta16 = edited[ws..new_we].encode_utf16().count() as i64 - (we16 - ws16) as i64;
        blocks[index].end = (we16 as i64 + delta16) as u32;
        for b in &mut blocks[index + 1..] {
            b.start = (b.start as i64 + delta16) as u32;
            b.end = (b.end as i64 + delta16) as u32;
        }
        let (pieces, _) = window_of(&blocks, index, &indented);
        let [piece] = pieces.as_slice() else {
            return Ok(());
        };
        let (start, end) = (new_byte[piece.start as usize], new_byte[piece.end as usize]);
        let window = Window {
            text: &edited[start..end],
            next: lookahead(&edited[end..]),
            at_start: start == 0,
            row: false,
        };
        let Some(got) = parse_window(&window, &old.labels) else {
            return Ok(());
        };
        if !got.holds {
            return Ok(());
        }
        let new = parse(&edited);
        let (w0, w1) = (piece.start, piece.end);
        let old_end = (w1 as i64 - delta16) as u32;
        let shift = |at: u32| (at as i64 + delta16) as u32;
        let before = |s: u32, e: u32| e <= w0 && s < w0 || (s == e && e < w0);
        let outside_old: Vec<(BlockKind, u32, u32)> = old
            .blocks
            .iter()
            .filter(|b| b.end <= w0 || b.start >= old_end)
            .map(|b| {
                if b.start >= old_end {
                    (b.kind, shift(b.start), shift(b.end))
                } else {
                    (b.kind, b.start, b.end)
                }
            })
            .collect();
        let outside_new: Vec<(BlockKind, u32, u32)> = new
            .blocks
            .iter()
            .filter(|b| b.end <= w0 || b.start >= w1)
            .map(|b| (b.kind, b.start, b.end))
            .collect();
        if outside_old != outside_new {
            return Err(format!(
                "blocks outside the window {:?} changed: {outside_old:?} != {outside_new:?} in {edited:?}",
                window.text
            ));
        }
        let moved = |t: &Token| Token {
            kind: t.kind,
            start: shift(t.start),
            content_start: shift(t.content_start),
            content_end: shift(t.content_end),
            end: shift(t.end),
        };
        let tokens_old: Vec<Token> = old
            .tokens
            .iter()
            .filter(|t| before(t.start, t.end) || t.start >= old_end)
            .map(|t| if t.start >= old_end { moved(t) } else { *t })
            .collect();
        let tokens_new: Vec<Token> = new
            .tokens
            .iter()
            .filter(|t| before(t.start, t.end) || t.start >= w1)
            .copied()
            .collect();
        if tokens_old != tokens_new {
            return Err(format!(
                "tokens outside the window {:?} changed in {edited:?}",
                window.text
            ));
        }
        let inside: Vec<Token> = new
            .tokens
            .iter()
            .filter(|t| w0 <= t.start && t.end <= w1 && !before(t.start, t.end))
            .copied()
            .collect();
        let windowed: Vec<Token> = got
            .tokens
            .iter()
            .map(|t| Token {
                kind: t.kind,
                start: t.start + w0,
                content_start: t.content_start + w0,
                content_end: t.content_end + w0,
                end: t.end + w0,
            })
            .collect();
        if inside != windowed {
            return Err(format!(
                "window {:?} parsed apart from the document {edited:?}: {windowed:?} != {inside:?}",
                window.text
            ));
        }
        Ok(())
    }

    fn check(text: &str) {
        let parsed = parse(text);
        if let Err(error) = check_markers(text, &parsed) {
            panic!("markers in {text:?}: {error}");
        }
        if let Err(error) = check_restart(text) {
            panic!("restart in {text:?}: {error}");
        }
    }

    #[test]
    fn tables() {
        let text = "| a | *b* |\n|:--|--:|\n| 1 |\n|x||\nlazy\n\nafter";
        assert_eq!(
            show(text),
            [
                (TokenKind::TableHead, ["", "| a | *b* |", "\n|:--|--:|"]),
                (TokenKind::TableCell, [" ", "a", " "]),
                (TokenKind::TableCell, [" ", "*b*", " "]),
                (TokenKind::Emphasis, ["*", "b", "*"]),
                (TokenKind::TableRow, ["", "| 1 |", ""]),
                (TokenKind::TableCell, [" ", "1", " "]),
                (TokenKind::TableRow, ["", "|x||", ""]),
                (TokenKind::TableCell, ["", "x", ""]),
                (TokenKind::TableCell, ["", "", ""]),
                (TokenKind::TableRow, ["", "lazy", ""]),
                (TokenKind::TableCell, ["", "lazy", ""]),
            ]
        );
        assert_eq!(
            block_text(text),
            [
                (BlockKind::TableHead, "| a | *b* |\n|:--|--:|\n"),
                (BlockKind::TableRow, "| 1 |\n"),
                (BlockKind::TableRow, "|x||\n"),
                (BlockKind::TableRow, "lazy\n"),
                (BlockKind::Paragraph, "after"),
            ]
        );
        // A table interrupts a paragraph; in a quote, the delimiter row keeps its `>`.
        assert_eq!(
            kinds("para\n| a |\n| - |"),
            [BlockKind::Paragraph, BlockKind::TableHead]
        );
        assert_eq!(
            show("> | a |\n> |---|")[1],
            (TokenKind::TableHead, ["", "| a |", "\n> |---|"])
        );
        check(text);
    }

    #[test]
    fn task_lists() {
        assert_eq!(
            show("- [ ] to do\n- [x] done"),
            [
                (TokenKind::Item, ["- ", "[ ] to do", ""]),
                (TokenKind::TaskBox { checked: false }, ["[", " ", "]"]),
                (TokenKind::Item, ["- ", "[x] done", ""]),
                (TokenKind::TaskBox { checked: true }, ["[", "x", "]"]),
            ]
        );
        assert_eq!(kinds("1. a\n2. b\n\n   more\n- c"), [BlockKind::Item; 3]);
        check("- [ ] a\n\n- [x] b\n\n  more\n\n10) [X] c");
    }

    #[test]
    fn footnotes() {
        let text = "See[^1] and [^none].\n\n[^1]: The *note*\n    continued";
        assert_eq!(
            show(text),
            [
                (TokenKind::FootnoteReference, ["[^", "1", "]"]),
                (
                    TokenKind::FootnoteDefinition,
                    ["[^1]: ", "The *note*\n    continued", ""]
                ),
                (TokenKind::Emphasis, ["*", "note", "*"]),
            ]
        );
        assert_eq!(
            kinds(text),
            [BlockKind::Paragraph, BlockKind::FootnoteDefinition]
        );
        check(text);
    }

    #[test]
    fn math() {
        assert_eq!(
            show("$a^2$ and $$\\sum$$"),
            [
                (TokenKind::InlineMath, ["$", "a^2", "$"]),
                (TokenKind::DisplayMath, ["$$", "\\sum", "$$"]),
            ]
        );
        assert_eq!(
            show("$$\nx\n$$"),
            [(TokenKind::DisplayMath, ["$$", "\nx\n", "$$"])]
        );
        check("$a$\n\n$$\nb\n$$\n\n`$c$`");
    }

    #[test]
    fn wikilinks_and_embeds() {
        assert_eq!(
            show("[[note|alias]] [[note#heading]] ![[image.png]] [[a]]"),
            [
                (TokenKind::WikiLink, ["[[note|", "alias", "]]"]),
                (TokenKind::WikiLink, ["[[", "note#heading", "]]"]),
                (TokenKind::Embed, ["![[", "image.png", "]]"]),
                (TokenKind::WikiLink, ["[[", "a", "]]"]),
            ]
        );
        check("[[a|*b*]]\n![[c#d|e]]");
    }

    #[test]
    fn obsidian_inlines() {
        assert_eq!(
            show("==mark *it*== %%hidden == text%% #tag #12 x#y #a/b-c_d"),
            [
                (TokenKind::Highlight, ["==", "mark *it*", "=="]),
                (TokenKind::Emphasis, ["*", "it", "*"]),
                (TokenKind::Comment, ["%%", "hidden == text", "%%"]),
                (TokenKind::Tag, ["#", "tag", ""]),
                (TokenKind::Tag, ["#", "a/b-c_d", ""]),
            ]
        );
        // Code, a spaced opener and `===` are not highlights; a heading's text holds tags.
        assert_eq!(
            show("`==a==` == b== ===c==="),
            [(TokenKind::InlineCode, ["`", "==a==", "`"])]
        );
        assert_eq!(
            show("# Title #tag"),
            [
                (TokenKind::Heading { level: 1 }, ["# ", "Title #tag", ""]),
                (TokenKind::Tag, ["#", "tag", ""]),
            ]
        );
        assert!(
            show("```\n#tag ==a== %%b%%\n```")
                .iter()
                .all(|(kind, _)| *kind == TokenKind::FencedCode)
        );
        check("==a==\n%%b\nc%%\n#d");
    }

    #[test]
    fn callouts() {
        let text = "> [!warning]- Careful\n> body\n\n> [!NOTE]\n\n> plain [!note]";
        assert_eq!(
            show(text),
            [
                (TokenKind::Quote, ["> ", "[!warning]- Careful\n> body", ""]),
                (TokenKind::Callout, ["[!", "warning", "]-"]),
                (TokenKind::Quote, ["> ", "[!NOTE]", ""]),
                (TokenKind::Callout, ["[!", "NOTE", "]"]),
                (TokenKind::Quote, ["> ", "plain [!note]", ""]),
            ]
        );
        assert_eq!(
            kinds(text),
            [BlockKind::Callout, BlockKind::Callout, BlockKind::Quote]
        );
        check(text);
    }

    #[test]
    fn front_matter_only_at_the_start() {
        let text = "---\ntitle: x\n---\n# H\n\n---\nnot: front\n---\n";
        assert_eq!(
            show(text),
            [
                (TokenKind::FrontMatter, ["---\n", "title: x\n", "---"]),
                (TokenKind::Heading { level: 1 }, ["# ", "H", ""]),
                (TokenKind::Heading { level: 2 }, ["", "not: front", "\n---"]),
            ]
        );
        assert_eq!(
            kinds(text),
            [
                BlockKind::FrontMatter,
                BlockKind::Heading { level: 1 },
                BlockKind::ThematicBreak,
                BlockKind::Heading { level: 2 }
            ]
        );
        // The same lines in a window that does not start the document are a rule and a heading.
        let window = Window {
            text: "---\ntitle: x\n---\n",
            next: "",
            at_start: false,
            row: false,
        };
        let parsed = parse_window(&window, &Labels::default()).unwrap();
        assert_eq!(
            parsed.blocks.iter().map(|b| b.kind).collect::<Vec<_>>(),
            [BlockKind::ThematicBreak, BlockKind::Heading { level: 2 }]
        );
        // pulldown-cmark's rules: a blank second line or no close is no front matter.
        assert_eq!(kinds("---\n\na\n---\n")[0], BlockKind::ThematicBreak);
        assert_eq!(kinds("---\na\n")[0], BlockKind::ThematicBreak);
        assert_eq!(
            show("---\r\na\r\n...  \r\nb")[0],
            (TokenKind::FrontMatter, ["---\r\n", "a\r\n", "...  "])
        );
        check(text);
    }

    #[test]
    fn labels_defined_elsewhere_resolve_in_a_window() {
        let text = "[a]: /u\n[^n]: note\n\nSee [a], [A][], [b] and [^N].\n";
        let whole = parse(text);
        let window = Window {
            text: "See [a], [A][], [b] and [^N].\n",
            next: "",
            at_start: false,
            row: false,
        };
        let alone = parse(window.text);
        let windowed = parse_window(&window, &whole.labels).unwrap();
        assert!(windowed.holds);
        assert_eq!(alone.tokens, []);
        let kinds: Vec<TokenKind> = windowed.tokens.iter().map(|t| t.kind).collect();
        assert_eq!(
            kinds,
            [
                TokenKind::Link,
                TokenKind::Link,
                TokenKind::FootnoteReference
            ]
        );
        assert_eq!(
            show(text)[..2],
            [
                (TokenKind::Definition, ["[", "a", "]: /u"]),
                (TokenKind::FootnoteDefinition, ["[^n]: ", "note", ""]),
            ]
        );
        assert_eq!(block_text(text)[0], (BlockKind::Definition, "[a]: /u\n"));
        check(text);
    }

    #[test]
    fn a_window_holds_while_the_next_block_starts_where_it_did() {
        let holds = |text: &str, next: &str| {
            let window = Window {
                text,
                next,
                at_start: false,
                row: false,
            };
            parse_window(&window, &Labels::default()).unwrap().holds
        };
        assert!(holds("a\n", "\n# b\n"));
        assert!(holds("- a\n", "- b\n"));
        assert!(holds("a\n", ""));
        assert!(holds("a\n", "\n\n"));
        // An unclosed fence, a setext underline, a lazy line, an item's continuation, an open HTML block.
        assert!(!holds("```\na\n", "\nb\n"));
        assert!(!holds("a\n", "===\n"));
        assert!(!holds("> a\n", "b\n"));
        assert!(!holds("- a\n", "\n  b\n"));
        assert!(!holds("<!--\n", "\nb\n"));
        // A row window holds while it is still the head and a row.
        let row = |text: &str| {
            let window = Window {
                text,
                next: "| 2 |\n",
                at_start: false,
                row: true,
            };
            parse_window(&window, &Labels::default()).unwrap().holds
        };
        assert!(row("| a |\n|---|\n| 1 |\n"));
        assert!(!row("| a |\n|---|\n# 1\n"));
        // Front matter the window opens can close past it.
        let open = Window {
            text: "---\ntitle\n",
            next: "\n---\n",
            at_start: true,
            row: false,
        };
        assert!(!parse_window(&open, &Labels::default()).unwrap().holds);
        assert_eq!(kinds("---\ntitle\n\n---\n"), [BlockKind::FrontMatter]);
        // A new label can restyle other blocks.
        let window = Window {
            text: "[new]: /u\n",
            next: "",
            at_start: false,
            row: false,
        };
        assert!(!parse_window(&window, &Labels::default()).unwrap().holds);
        let big = "a".repeat(WINDOW_LIMIT);
        assert!(
            parse_window(
                &Window {
                    text: &big,
                    next: "\n",
                    at_start: false,
                    row: false
                },
                &Labels::default()
            )
            .is_none()
        );
    }

    #[test]
    fn spans_and_tokens_agree_on_the_inline_kinds() {
        let text = "# A *b* **c** ~~d~~ `e` [f](u) ![g](v)\n\n```\nh\n```\n";
        let tokens: Vec<_> = parse(text)
            .tokens
            .into_iter()
            .map(|t| (t.kind, [t.start, t.content_start, t.content_end, t.end]))
            .collect();
        let spans: Vec<_> = spans(text)
            .into_iter()
            .map(|s| {
                (
                    TokenKind::from(s.kind),
                    [s.start, s.content_start, s.content_end, s.end],
                )
            })
            .collect();
        assert_eq!(tokens, spans);
    }

    /// `→` stands for a tab, as in the spec.
    fn examples(spec: &str) -> Vec<String> {
        let fence = "````````````````````````````````";
        let mut found = Vec::new();
        let mut lines = spec.lines();
        while let Some(line) = lines.next() {
            if line
                .strip_prefix(fence)
                .is_some_and(|rest| rest.trim_start().starts_with("example"))
            {
                let mut markdown = String::new();
                for line in lines.by_ref().take_while(|line| *line != ".") {
                    markdown.push_str(line);
                    markdown.push('\n');
                }
                lines.by_ref().find(|line| line.starts_with(fence));
                found.push(markdown.replace('→', "\t"));
            }
        }
        found
    }

    fn run_suite(name: &str, spec: &str, count: usize) {
        let examples = examples(spec);
        assert_eq!(examples.len(), count, "{name}");
        let failures: Vec<String> = examples
            .iter()
            .enumerate()
            .filter_map(|(index, text)| {
                check_markers(text, &parse(text))
                    .and_then(|()| check_restart(text))
                    .err()
                    .map(|error| format!("{name} example {}: {error} in {text:?}", index + 1))
            })
            .collect();
        eprintln!(
            "{name}: {} of {count} examples pass",
            count - failures.len()
        );
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }

    #[test]
    fn commonmark_spec() {
        run_suite(
            "CommonMark 0.31.2",
            include_str!("../../../../corpus/commonmark/spec.txt"),
            652,
        );
    }

    #[test]
    fn gfm_spec() {
        run_suite(
            "GFM tables",
            include_str!("../../../../corpus/gfm/gfm_table.txt"),
            9,
        );
        run_suite(
            "GFM strikethrough",
            include_str!("../../../../corpus/gfm/gfm_strikethrough.txt"),
            3,
        );
        run_suite(
            "GFM task lists",
            include_str!("../../../../corpus/gfm/gfm_tasklist.txt"),
            2,
        );
    }

    // Short syntax pieces, so that a few dozen build blocks of every kind.
    fn document() -> impl Strategy<Value = String> {
        let piece = prop_oneof![
            8 => prop::sample::select(vec![
                "-", "*", "_", "~", "`", "#", "!", "[", "]", "(", ")", "<", ">", "=", ":", " ", "|", "$",
                "%", "^", "\\", "\t", "\n", "é", "🙂", "a", "1", ".",
            ]),
            1 => prop::sample::select(vec![
                "\n\n", "\r\n", "\n> ", "\n- ", "\n1. ", "  ", "    ", "```", "~~~", "**", "==", "%%", "$$",
                "[[", "]]", "![[", "[^1]", "[^1]: n\n", "[a]: /u\n", "[a]", "](u)", "| a | b |\n", "|---|---|\n",
                "| 1 |\n", "- [ ] ", "- [x] ", "> [!note] ", "#tag ", "---\n", "...\n", "<div>\n", "<!--", "-->",
                "\n===\n", "\n---\n",
            ]),
        ];
        prop::collection::vec(piece, 0..64).prop_map(|pieces| pieces.concat())
    }

    proptest! {
        #[test]
        fn every_window_parses_alone_as_in_the_document(text in document()) {
            prop_assert!(check_restart(&text).is_ok(), "{}", check_restart(&text).unwrap_err());
        }

        #[test]
        fn an_edit_whose_window_holds_changes_nothing_outside_it(
            text in document(),
            pick in any::<usize>(),
            offset in any::<usize>(),
            delete in 0..6usize,
            insert in prop::sample::select(vec![
                "", "a", " ", "  ", "    ", "\t", "\n", "\n\n", "- ", "1. ", "> ", "# ", "```", "~~~", "$$", "%%", "==",
                "<div>", "<!--", "-->", "---", "===", "|", "| a |\n|---|", "[a]: /u", "[^1]: n", "[^1]", "[a]", "[[",
                "]]", "*", "`", "\r\n", "é", "🙂",
            ]),
        ) {
            let result = check_edit(&text, pick, offset, delete, insert);
            prop_assert!(result.is_ok(), "{}", result.unwrap_err());
        }

        #[test]
        fn markers_hold_only_syntax_in_every_token(text in prop_oneof![document(), "\\PC*"]) {
            let parsed = parse(&text);
            prop_assert!(check_markers(&text, &parsed).is_ok(), "{}", check_markers(&text, &parsed).unwrap_err());
        }
    }
}
