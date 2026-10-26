use std::ops::Range;

use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag};

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
            span.1 = offsets(text, span.0, &range, top.child_end);
            continue;
        }
        if let Some(top) = open.last_mut() {
            top.child_end = range.end;
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
                let offsets = offsets(text, SpanKind::InlineCode, &range, range.start);
                found.push((SpanKind::InlineCode, offsets));
                continue;
            }
            _ => continue,
        };
        open.push(Open {
            index: found.len(),
            child_end: range.start,
            range,
        });
        found.push((kind, [0; 4]));
    }

    let mut bytes: Vec<usize> = found.iter().flat_map(|(_, offsets)| *offsets).collect();
    bytes.sort_unstable();
    bytes.dedup();
    let mut units = Vec::with_capacity(bytes.len());
    let (mut byte, mut unit) = (0, 0);
    for &next in &bytes {
        unit += text[byte..next].chars().map(char::len_utf16).sum::<usize>();
        byte = next;
        units.push(unit as u32);
    }
    let utf16 = |at: usize| units[bytes.binary_search(&at).unwrap()];
    found
        .into_iter()
        .map(|(kind, [start, content_start, content_end, end])| Span {
            kind,
            start: utf16(start),
            end: utf16(end),
            content_start: utf16(content_start),
            content_end: utf16(content_end),
        })
        .collect()
}

/// Byte offsets `[start, content_start, content_end, end]` of a span over
/// `range` whose child events end at `child_end`.
fn offsets(text: &str, kind: SpanKind, range: &Range<usize>, child_end: usize) -> [usize; 4] {
    let source = &text[range.clone()];
    let source = match kind {
        SpanKind::Heading { .. } | SpanKind::FencedCode => source
            .strip_suffix("\r\n")
            .or_else(|| source.strip_suffix(['\n', '\r']))
            .unwrap_or(source),
        _ => source,
    };
    let (start, end) = (range.start, range.start + source.len());
    let marker = match kind {
        SpanKind::Emphasis | SpanKind::Link => 1,
        SpanKind::Strong | SpanKind::Image => 2,
        SpanKind::Strikethrough => source.len() - source.trim_start_matches('~').len(),
        SpanKind::InlineCode => source.len() - source.trim_start_matches('`').len(),
        // A setext heading hides only its underline.
        SpanKind::Heading { .. } if source.contains(['\n', '\r']) => 0,
        SpanKind::Heading { .. } => {
            let rest = source.trim_start_matches('#').trim_start_matches(BLANK);
            source.len() - rest.len()
        }
        SpanKind::FencedCode => source.find('\n').map_or(source.len(), |at| at + 1),
    };
    let content_start = start + marker;
    let child_end = child_end.clamp(content_start, end);
    let content_end = match kind {
        SpanKind::Emphasis | SpanKind::Strong | SpanKind::Strikethrough | SpanKind::InlineCode => {
            end - marker
        }
        // Text that ends at a line break leaves the next line's `>` or indent
        // before the `]`, outside every child event.
        SpanKind::Link | SpanKind::Image => child_end + text[child_end..end].find(']').unwrap_or(0),
        SpanKind::Heading { .. } | SpanKind::FencedCode => child_end,
    };
    [start, content_start, content_end, end]
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

    proptest! {
        #[test]
        fn offsets_nest_and_never_split_a_surrogate_pair(
            text in prop_oneof!["\\PC*", "[-*_~`#!\\[\\]()<> \\né🙂a]*"]
        ) {
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
        }
    }
}
