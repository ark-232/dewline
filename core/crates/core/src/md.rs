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

struct Open {
    index: usize,
    range: Range<usize>,
    content: Option<Range<usize>>,
}

/// Spans ordered by `start`, outer before inner.
pub fn spans(text: &str) -> Vec<Span> {
    let mut found: Vec<(SpanKind, [usize; 4])> = Vec::new();
    let mut open: Vec<Open> = Vec::new();
    for (event, range) in Parser::new_ext(text, Options::ENABLE_STRIKETHROUGH).into_offset_iter() {
        if matches!(event, Event::End(_))
            && let Some(top) = open.pop_if(|top| top.range == range)
        {
            let (kind, offsets) = &mut found[top.index];
            let mut end = range.end;
            if matches!(kind, SpanKind::Heading { .. } | SpanKind::FencedCode) {
                let block = &text[range.clone()];
                end -= if block.ends_with("\r\n") {
                    2
                } else {
                    usize::from(block.ends_with(['\n', '\r']))
                };
            }
            let content = top.content.unwrap_or_else(|| {
                let at = match kind {
                    SpanKind::Link => range.start + 1,
                    SpanKind::Image => range.start + 2,
                    SpanKind::FencedCode => text[range.start..end]
                        .find('\n')
                        .map_or(end, |i| range.start + i + 1),
                    _ => end,
                };
                at..at
            });
            let content_end = content.end.min(end);
            *offsets = [
                range.start,
                end,
                content.start.min(content_end),
                content_end,
            ];
            continue;
        }
        if let Some(top) = open.last_mut() {
            let start = top.content.as_ref().map_or(range.start, |c| c.start);
            top.content = Some(start..range.end);
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
                let ticks = text[range.clone()]
                    .bytes()
                    .take_while(|&b| b == b'`')
                    .count();
                let offsets = [
                    range.start,
                    range.end,
                    range.start + ticks,
                    range.end - ticks,
                ];
                found.push((SpanKind::InlineCode, offsets));
                continue;
            }
            _ => continue,
        };
        open.push(Open {
            index: found.len(),
            range,
            content: None,
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
        .map(|(kind, [start, end, content_start, content_end])| Span {
            kind,
            start: utf16(start),
            end: utf16(end),
            content_start: utf16(content_start),
            content_end: utf16(content_end),
        })
        .collect()
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

    #[test]
    fn heading() {
        let text = format!("{BEFORE}\n\n## {INSIDE} ##\n");
        assert_eq!(
            spans(&text),
            [span(SpanKind::Heading { level: 2 }, 9, 12, 18, 21)]
        );
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
