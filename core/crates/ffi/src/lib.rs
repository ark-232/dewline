use dewline_core::md;

uniffi::setup_scaffolding!();

#[derive(uniffi::Enum)]
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

#[derive(uniffi::Record)]
pub struct Span {
    pub kind: SpanKind,
    pub start: u32,
    pub end: u32,
    pub content_start: u32,
    pub content_end: u32,
}

impl From<md::Span> for Span {
    fn from(span: md::Span) -> Self {
        let kind = match span.kind {
            md::SpanKind::Heading { level } => SpanKind::Heading { level },
            md::SpanKind::Emphasis => SpanKind::Emphasis,
            md::SpanKind::Strong => SpanKind::Strong,
            md::SpanKind::Strikethrough => SpanKind::Strikethrough,
            md::SpanKind::InlineCode => SpanKind::InlineCode,
            md::SpanKind::Link => SpanKind::Link,
            md::SpanKind::Image => SpanKind::Image,
            md::SpanKind::FencedCode => SpanKind::FencedCode,
        };
        Span {
            kind,
            start: span.start,
            end: span.end,
            content_start: span.content_start,
            content_end: span.content_end,
        }
    }
}

#[uniffi::export]
pub fn parse_spans(text: String) -> Vec<Span> {
    md::spans(&text).into_iter().map(Span::from).collect()
}
