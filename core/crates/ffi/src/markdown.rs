use std::panic::{self, AssertUnwindSafe};
use std::sync::{Arc, Mutex};

use dewline_core::md::{self, BlockKind, TokenKind};

/// A parse fails only by panicking. Returned as this error, a panic throws in Swift; UniFFI traps on a panic from a
/// function that cannot return an error.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ParseError {
    #[error("{message}")]
    Panic { message: String },
}

/// One document's parser. It keeps the link and footnote labels of the document's last whole parse, which its
/// windows resolve references against.
#[derive(Default, uniffi::Object)]
pub struct Markdown {
    labels: Mutex<Arc<md::Labels>>,
}

#[uniffi::export]
impl Markdown {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }

    /// The whole document as records. Its labels replace the ones windows use.
    pub fn parse(&self, text: String) -> Result<Vec<u8>, ParseError> {
        let (records, labels) = unwound(|| {
            let parse = md::parse(&text);
            (records(&parse), parse.labels)
        })?;
        *self.labels.lock().unwrap() = Arc::new(labels);
        Ok(records)
    }

    /// A window as records, or `None` when its text and `next` are over `md::WINDOW_LIMIT` bytes.
    pub fn parse_window(
        &self,
        text: String,
        next: String,
        at_start: bool,
        row: bool,
    ) -> Result<Option<Vec<u8>>, ParseError> {
        let labels = self.labels.lock().unwrap().clone();
        let window = md::Window {
            text: &text,
            next: &next,
            at_start,
            row,
        };
        unwound(|| md::parse_window(&window, &labels).map(|parse| records(&parse)))
    }

    /// Panics where a parse would. Only the test that a panic reaches Swift as an error calls it.
    pub fn panic_for_test(&self) -> Result<Vec<u8>, ParseError> {
        unwound(|| panic!("a test asked for a panic"))
    }
}

/// `parse`'s result, or its panic with the panic's message.
fn unwound<T>(parse: impl FnOnce() -> T) -> Result<T, ParseError> {
    panic::catch_unwind(AssertUnwindSafe(parse)).map_err(|panic| ParseError::Panic {
        message: panic
            .downcast_ref::<&str>()
            .map(|message| message.to_string())
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_default(),
    })
}

/// Little-endian u32 words: whether the parse holds (1 or 0), the number of blocks, the number of tokens, then each
/// block as its kind, start and end, then each token as its kind, start, content start, content end and end.
fn records(parse: &md::Parse) -> Vec<u8> {
    let words = 3 + 3 * parse.blocks.len() + 5 * parse.tokens.len();
    let mut records = Vec::with_capacity(4 * words);
    let mut put = |word: u32| records.extend_from_slice(&word.to_le_bytes());
    put(u32::from(parse.holds));
    put(parse.blocks.len() as u32);
    put(parse.tokens.len() as u32);
    for block in &parse.blocks {
        put(block_kind(block.kind));
        put(block.start);
        put(block.end);
    }
    for token in &parse.tokens {
        put(token_kind(token.kind));
        put(token.start);
        put(token.content_start);
        put(token.content_end);
        put(token.end);
    }
    records
}

/// A kind's code in the low byte, and a heading's level in the byte above it.
fn block_kind(kind: BlockKind) -> u32 {
    match kind {
        BlockKind::Paragraph => 0,
        BlockKind::Heading { level } => 1 | u32::from(level) << 8,
        BlockKind::ThematicBreak => 2,
        BlockKind::Quote => 3,
        BlockKind::Callout => 4,
        BlockKind::Code => 5,
        BlockKind::Html => 6,
        BlockKind::Item => 7,
        BlockKind::TableHead => 8,
        BlockKind::TableRow => 9,
        BlockKind::FootnoteDefinition => 10,
        BlockKind::Definition => 11,
        BlockKind::FrontMatter => 12,
    }
}

/// A kind's code in the low byte, and a heading's level or a task box's check (1 or 0) in the byte above it.
fn token_kind(kind: TokenKind) -> u32 {
    match kind {
        TokenKind::Heading { level } => u32::from(level) << 8,
        TokenKind::Emphasis => 1,
        TokenKind::Strong => 2,
        TokenKind::Strikethrough => 3,
        TokenKind::InlineCode => 4,
        TokenKind::Link => 5,
        TokenKind::Image => 6,
        TokenKind::FencedCode => 7,
        TokenKind::Quote => 8,
        TokenKind::Callout => 9,
        TokenKind::Item => 10,
        TokenKind::TaskBox { checked } => 11 | u32::from(checked) << 8,
        TokenKind::TableHead => 12,
        TokenKind::TableRow => 13,
        TokenKind::TableCell => 14,
        TokenKind::FootnoteReference => 15,
        TokenKind::FootnoteDefinition => 16,
        TokenKind::Definition => 17,
        TokenKind::InlineMath => 18,
        TokenKind::DisplayMath => 19,
        TokenKind::WikiLink => 20,
        TokenKind::Embed => 21,
        TokenKind::Highlight => 22,
        TokenKind::Comment => 23,
        TokenKind::Tag => 24,
        TokenKind::FrontMatter => 25,
        TokenKind::Html => 26,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(records: &[u8]) -> Vec<u32> {
        records
            .as_chunks::<4>()
            .0
            .iter()
            .map(|word| u32::from_le_bytes(*word))
            .collect()
    }

    // MdCore's decoder reads this layout; MarkdownParseTests decodes the same document.
    #[test]
    fn records_golden() {
        let text = "# Café 🙂\n\n- [x] **done** [a]\n\n[a]: /u\n";
        let records = Markdown::new().parse(text.into()).unwrap();
        #[rustfmt::skip]
        assert_eq!(words(&records), [
            1, 3, 6,
            1 | 1 << 8, 0, 10,
            7, 11, 30,
            11, 31, 39,
            1 << 8, 0, 2, 9, 9,
            10, 11, 13, 29, 29,
            11 | 1 << 8, 13, 14, 15, 16,
            2, 17, 19, 23, 25,
            5, 26, 27, 28, 29,
            17, 31, 32, 33, 38,
        ]);
    }

    #[test]
    fn a_panic_is_an_error() {
        let markdown = Markdown::new();
        let Err(ParseError::Panic { message }) = markdown.panic_for_test() else {
            panic!("the panic was not an error");
        };
        assert_eq!(message, "a test asked for a panic");
        assert!(markdown.parse("# a\n".into()).is_ok());
    }

    #[test]
    fn windows_resolve_the_last_whole_parse_labels() {
        let markdown = Markdown::new();
        let window = || {
            let records = markdown
                .parse_window("See [a].\n".into(), String::new(), false, false)
                .unwrap()
                .unwrap();
            words(&records)
        };
        assert_eq!(window(), [1, 1, 0, 0, 0, 9]);
        markdown.parse("[a]: /u\n\nSee [a].\n".into()).unwrap();
        assert_eq!(window(), [1, 1, 1, 0, 0, 9, 5, 4, 5, 6, 7]);
        markdown.parse("See [a].\n".into()).unwrap();
        assert_eq!(window(), [1, 1, 0, 0, 0, 9]);
        let over = "a".repeat(md::WINDOW_LIMIT);
        assert_eq!(
            markdown
                .parse_window(over, "\n".into(), false, false)
                .unwrap(),
            None
        );
    }
}
