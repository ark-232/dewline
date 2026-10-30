//! Markdown to one standalone HTML page. Raw HTML in the source is shown as text, never passed through.

pub mod docx;

use std::collections::HashMap;
use std::fmt::Write;
use std::fs::{self, File};
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path};

use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

/// What the page needs beyond the markdown.
pub struct ExportOptions<'a> {
    pub title: &'a str,
    /// The theme's stylesheet, inlined in the head.
    pub css: &'a str,
    /// A Mermaid source as inline SVG, or `None` to show the source.
    pub diagram: &'a dyn Fn(&str) -> Option<String>,
    /// TeX as inline HTML, display math when the flag is set, or `None` to show the source.
    pub math: &'a dyn Fn(&str, bool) -> Option<String>,
    /// The document's folder: images inside it are inlined as data URLs, all others keep their paths.
    pub folder: Option<&'a Path>,
}

/// The largest image file inlined.
const MAX_IMAGE: u64 = 20 << 20;

/// Scripts never run; styles and images come only from the page itself and data URLs.
pub const CSP: &str = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:";

const OPTIONS: Options = crate::md::OPTIONS.union(Options::ENABLE_YAML_STYLE_METADATA_BLOCKS);

pub fn html(text: &str, options: &ExportOptions<'_>) -> String {
    let mut out = String::with_capacity(text.len() * 2);
    let _ = write!(
        out,
        "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n\
         <meta http-equiv=\"Content-Security-Policy\" content=\"{CSP}\">\n\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
         <title>{}</title>\n<style>\n{}\n</style>\n</head>\n<body>\n",
        escape(options.title),
        options.css.replace("</", "<\\/"),
    );
    Writer {
        out: &mut out,
        options,
        footnotes: HashMap::new(),
        columns: Vec::new(),
        column: 0,
        head: false,
    }
    .run(Parser::new_ext(text, OPTIONS));
    out.push_str("</body>\n</html>\n");
    out
}

/// `text` with the five HTML-significant characters as entities.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// A link target, unless its scheme can run code: relative paths, fragments and web, mail and data-image URLs.
fn url(target: &str) -> Option<String> {
    let scheme_end = target.find([':', '/', '?', '#']);
    let safe = match scheme_end {
        Some(at) if target[at..].starts_with(':') => {
            let scheme = target[..at].to_ascii_lowercase();
            matches!(scheme.as_str(), "http" | "https" | "mailto")
                || target[at + 1..].starts_with("image/") && scheme == "data"
        }
        _ => true,
    };
    safe.then(|| escape(target))
}

/// A data URL of the image at `path` relative to `folder`: a relative path without `..` that resolves, symlinks
/// followed, to a regular file inside the folder, at most `MAX_IMAGE` bytes, whose bytes are PNG, JPEG, GIF, WebP or
/// SVG.
fn inline_image(folder: &Path, path: &str) -> Option<String> {
    let relative = Path::new(path);
    if path.contains(':')
        || !relative
            .components()
            .all(|part| matches!(part, Component::Normal(_) | Component::CurDir))
    {
        return None;
    }
    let root = fs::canonicalize(folder).ok()?;
    let target = fs::canonicalize(root.join(relative)).ok()?;
    if !target.starts_with(&root) {
        return None;
    }
    let file = File::options()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&target)
        .ok()?;
    let info = file.metadata().ok()?;
    if !info.is_file() || info.len() > MAX_IMAGE {
        return None;
    }
    let mut bytes = Vec::with_capacity(info.len() as usize);
    file.take(MAX_IMAGE + 1).read_to_end(&mut bytes).ok()?;
    let head = &bytes[..bytes.len().min(1024)];
    let mime = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        "image/jpeg"
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        "image/gif"
    } else if bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        "image/webp"
    } else if target
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("svg"))
        && head.windows(4).any(|window| window == b"<svg")
    {
        "image/svg+xml"
    } else {
        return None;
    };
    (bytes.len() as u64 <= MAX_IMAGE).then(|| format!("data:{mime};base64,{}", base64(&bytes)))
}

pub fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, &b)| n | u32::from(b) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= chunk.len() {
                ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char
            } else {
                '='
            });
        }
    }
    out
}

struct Writer<'o, 'a> {
    out: &'o mut String,
    options: &'o ExportOptions<'a>,
    /// Footnote labels by the number they show, in order of first mention.
    footnotes: HashMap<String, usize>,
    columns: Vec<Alignment>,
    column: usize,
    head: bool,
}

impl Writer<'_, '_> {
    fn footnote(&mut self, label: &str) -> usize {
        let next = self.footnotes.len() + 1;
        *self.footnotes.entry(label.to_owned()).or_insert(next)
    }

    fn run<'t>(&mut self, events: impl Iterator<Item = Event<'t>>) {
        let mut events = events;
        while let Some(event) = events.next() {
            match event {
                Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(info)))
                    if info.split_whitespace().next() == Some("mermaid") =>
                {
                    let source = code(&mut events);
                    match (self.options.diagram)(&source) {
                        Some(svg) => {
                            let _ = writeln!(self.out, "<figure class=\"diagram\">{svg}</figure>");
                        }
                        None => {
                            let _ = writeln!(
                                self.out,
                                "<pre><code class=\"language-mermaid\">{}</code></pre>",
                                escape(&source)
                            );
                        }
                    }
                }
                Event::Start(Tag::MetadataBlock(_)) => {
                    code(&mut events);
                }
                Event::Start(Tag::Image {
                    dest_url, title, ..
                }) => {
                    let alt = code(&mut events);
                    self.out.push_str("<img");
                    let inlined = self
                        .options
                        .folder
                        .and_then(|folder| inline_image(folder, &dest_url));
                    if let Some(src) = inlined.or_else(|| url(&dest_url)) {
                        let _ = write!(self.out, " src=\"{src}\"");
                    }
                    let _ = write!(self.out, " alt=\"{}\"", escape(&alt));
                    if !title.is_empty() {
                        let _ = write!(self.out, " title=\"{}\"", escape(&title));
                    }
                    self.out.push('>');
                }
                Event::Start(tag) => self.start(tag),
                Event::End(tag) => self.end(tag),
                Event::Text(text) => self.out.push_str(&escape(&text)),
                Event::Code(text) => {
                    let _ = write!(self.out, "<code>{}</code>", escape(&text));
                }
                Event::InlineMath(tex) => match (self.options.math)(&tex, false) {
                    Some(math) => self.out.push_str(&math),
                    None => {
                        let _ = write!(self.out, "<code class=\"math\">{}</code>", escape(&tex));
                    }
                },
                Event::DisplayMath(tex) => match (self.options.math)(&tex, true) {
                    Some(math) => {
                        let _ = write!(self.out, "<span class=\"math-display\">{math}</span>");
                    }
                    None => {
                        let _ = write!(
                            self.out,
                            "<code class=\"math math-display\">{}</code>",
                            escape(&tex)
                        );
                    }
                },
                Event::Html(html) | Event::InlineHtml(html) => self.out.push_str(&escape(&html)),
                Event::FootnoteReference(label) => {
                    let number = self.footnote(&label);
                    let _ = write!(
                        self.out,
                        "<sup class=\"footnote-reference\"><a href=\"#fn-{}\">{number}</a></sup>",
                        escape(&label)
                    );
                }
                Event::SoftBreak => self.out.push('\n'),
                Event::HardBreak => self.out.push_str("<br>\n"),
                Event::Rule => self.out.push_str("<hr>\n"),
                Event::TaskListMarker(checked) => {
                    let _ = write!(
                        self.out,
                        "<input type=\"checkbox\" disabled{}> ",
                        if checked { " checked" } else { "" }
                    );
                }
            }
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => self.out.push_str("<p>"),
            Tag::Heading { level, .. } => {
                let _ = write!(self.out, "<{}>", heading(level));
            }
            Tag::BlockQuote(_) => self.out.push_str("<blockquote>\n"),
            Tag::CodeBlock(kind) => {
                let language = match &kind {
                    CodeBlockKind::Fenced(info) => info.split_whitespace().next().unwrap_or(""),
                    CodeBlockKind::Indented => "",
                };
                if language.is_empty() {
                    self.out.push_str("<pre><code>");
                } else {
                    let _ = write!(
                        self.out,
                        "<pre><code class=\"language-{}\">",
                        escape(language)
                    );
                }
            }
            Tag::HtmlBlock => self.out.push_str("<pre class=\"html\">"),
            Tag::List(Some(1)) => self.out.push_str("<ol>\n"),
            Tag::List(Some(start)) => {
                let _ = writeln!(self.out, "<ol start=\"{start}\">");
            }
            Tag::List(None) => self.out.push_str("<ul>\n"),
            Tag::Item => self.out.push_str("<li>"),
            Tag::FootnoteDefinition(label) => {
                let number = self.footnote(&label);
                let _ = write!(
                    self.out,
                    "<div class=\"footnote-definition\" id=\"fn-{}\"><sup class=\"footnote-definition-label\">{number}</sup>",
                    escape(&label)
                );
            }
            Tag::DefinitionList => self.out.push_str("<dl>\n"),
            Tag::DefinitionListTitle => self.out.push_str("<dt>"),
            Tag::DefinitionListDefinition => self.out.push_str("<dd>"),
            Tag::Table(columns) => {
                self.columns = columns;
                self.out.push_str("<table>\n");
            }
            Tag::TableHead => {
                self.head = true;
                self.column = 0;
                self.out.push_str("<thead><tr>");
            }
            Tag::TableRow => {
                self.column = 0;
                self.out.push_str("<tr>");
            }
            Tag::TableCell => {
                let cell = if self.head { "th" } else { "td" };
                let align = match self.columns.get(self.column) {
                    Some(Alignment::Left) => " style=\"text-align:left\"",
                    Some(Alignment::Center) => " style=\"text-align:center\"",
                    Some(Alignment::Right) => " style=\"text-align:right\"",
                    _ => "",
                };
                let _ = write!(self.out, "<{cell}{align}>");
            }
            Tag::Emphasis => self.out.push_str("<em>"),
            Tag::Strong => self.out.push_str("<strong>"),
            Tag::Strikethrough => self.out.push_str("<del>"),
            Tag::Superscript => self.out.push_str("<sup>"),
            Tag::Subscript => self.out.push_str("<sub>"),
            Tag::Link {
                dest_url, title, ..
            } => {
                self.out.push_str("<a");
                if let Some(href) = url(&dest_url) {
                    let _ = write!(self.out, " href=\"{href}\"");
                }
                if !title.is_empty() {
                    let _ = write!(self.out, " title=\"{}\"", escape(&title));
                }
                self.out.push('>');
            }
            Tag::Image { .. } | Tag::MetadataBlock(_) => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        let close = match tag {
            TagEnd::Paragraph => "</p>\n",
            TagEnd::Heading(level) => {
                let _ = writeln!(self.out, "</{}>", heading(level));
                return;
            }
            TagEnd::BlockQuote(_) => "</blockquote>\n",
            TagEnd::CodeBlock => "</code></pre>\n",
            TagEnd::HtmlBlock => "</pre>\n",
            TagEnd::List(true) => "</ol>\n",
            TagEnd::List(false) => "</ul>\n",
            TagEnd::Item => "</li>\n",
            TagEnd::FootnoteDefinition => "</div>\n",
            TagEnd::DefinitionList => "</dl>\n",
            TagEnd::DefinitionListTitle => "</dt>\n",
            TagEnd::DefinitionListDefinition => "</dd>\n",
            TagEnd::Table => "</tbody></table>\n",
            TagEnd::TableHead => {
                self.head = false;
                "</tr></thead>\n<tbody>\n"
            }
            TagEnd::TableRow => "</tr>\n",
            TagEnd::TableCell => {
                self.column += 1;
                if self.head { "</th>" } else { "</td>" }
            }
            TagEnd::Emphasis => "</em>",
            TagEnd::Strong => "</strong>",
            TagEnd::Strikethrough => "</del>",
            TagEnd::Superscript => "</sup>",
            TagEnd::Subscript => "</sub>",
            TagEnd::Link => "</a>",
            TagEnd::Image | TagEnd::MetadataBlock(_) => "",
        };
        self.out.push_str(close);
    }
}

fn heading(level: HeadingLevel) -> &'static str {
    match level {
        HeadingLevel::H1 => "h1",
        HeadingLevel::H2 => "h2",
        HeadingLevel::H3 => "h3",
        HeadingLevel::H4 => "h4",
        HeadingLevel::H5 => "h5",
        HeadingLevel::H6 => "h6",
    }
}

/// The text up to the end of the tag just started, with nested markup dropped: a code block's source, an image's alt.
fn code<'t>(events: &mut impl Iterator<Item = Event<'t>>) -> String {
    let mut text = String::new();
    let mut depth = 1;
    for event in events {
        match event {
            Event::Start(_) => depth += 1,
            Event::End(_) => {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
            Event::Text(t) | Event::Code(t) | Event::InlineMath(t) | Event::DisplayMath(t) => {
                text.push_str(&t)
            }
            Event::SoftBreak | Event::HardBreak => text.push(' '),
            _ => {}
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn export(text: &str) -> String {
        html(
            text,
            &ExportOptions {
                title: "t",
                css: "",
                diagram: &|_| Some("<svg>diagram</svg>".into()),
                math: &|tex, display| Some(format!("[{display}:{tex}]")),
                folder: None,
            },
        )
    }

    fn body(page: &str) -> &str {
        &page[page.find("<body>").unwrap()..]
    }

    #[test]
    fn tables_render_with_alignment() {
        let page = export("| a | b |\n|:-|-:|\n| 1 | 2 |\n");
        assert!(page.contains("<thead><tr><th style=\"text-align:left\">a</th><th style=\"text-align:right\">b</th></tr></thead>"), "{page}");
        assert!(
            page.contains(
                "<tr><td style=\"text-align:left\">1</td><td style=\"text-align:right\">2</td></tr>"
            ),
            "{page}"
        );
    }

    #[test]
    fn task_lists_render_as_disabled_boxes() {
        let page = export("- [x] done\n- [ ] todo\n");
        assert!(
            page.contains("<li><input type=\"checkbox\" disabled checked> done</li>"),
            "{page}"
        );
        assert!(
            page.contains("<li><input type=\"checkbox\" disabled> todo</li>"),
            "{page}"
        );
    }

    #[test]
    fn footnotes_number_in_order_of_mention() {
        let page = export("One[^b] two[^a].\n\n[^a]: First.\n[^b]: Second.\n");
        assert!(
            page.contains("<a href=\"#fn-b\">1</a>") && page.contains("<a href=\"#fn-a\">2</a>"),
            "{page}"
        );
        assert!(
            page.contains("id=\"fn-a\"><sup class=\"footnote-definition-label\">2</sup>"),
            "{page}"
        );
    }

    #[test]
    fn strikethrough_diagrams_and_math_render() {
        let page = export("~~gone~~ $x$\n\n$$y$$\n\n```mermaid\nflowchart LR\n```\n");
        assert!(page.contains("<del>gone</del>"), "{page}");
        assert!(
            page.contains("[false:x]") && page.contains("[true:y]"),
            "{page}"
        );
        assert!(
            page.contains("<figure class=\"diagram\"><svg>diagram</svg></figure>"),
            "{page}"
        );
    }

    #[test]
    fn raw_html_is_escaped() {
        let page = export("<script>alert(1)</script>\n\nText <img src=x onerror=alert(2)> here.\n");
        let body = body(&page);
        assert!(
            !body.contains("<script") && !body.contains("<img"),
            "{body}"
        );
        assert!(
            body.contains("&lt;script&gt;alert(1)&lt;/script&gt;"),
            "{body}"
        );
        assert!(
            body.contains("&lt;img src=x onerror=alert(2)&gt;"),
            "{body}"
        );
        assert!(page.contains(CSP));
    }

    #[test]
    fn script_urls_lose_their_target_and_images_keep_their_paths() {
        let page = export(
            "[a](javascript:alert(1)) [b](JavaScript:x) ![alt \"q\"](img/a.png) [c](https://x.dev)",
        );
        assert!(
            !page.contains("javascript:") && !page.contains("JavaScript:"),
            "{page}"
        );
        assert!(
            page.contains("<img src=\"img/a.png\" alt=\"alt &quot;q&quot;\">"),
            "{page}"
        );
        assert!(page.contains("<a href=\"https://x.dev\">c</a>"), "{page}");
    }

    #[test]
    fn front_matter_stays_out_and_the_stylesheet_cannot_close_its_tag() {
        let page = html(
            "---\nsecret: 1\n---\n# Hi\n",
            &ExportOptions {
                title: "<t>",
                css: "p{}</style><script>",
                diagram: &|_| None,
                math: &|_, _| None,
                folder: None,
            },
        );
        assert!(
            !page.contains("secret") && page.contains("<h1>Hi</h1>"),
            "{page}"
        );
        assert!(
            page.contains("<title>&lt;t&gt;</title>") && !page.contains("</style><script>"),
            "{page}"
        );
    }

    #[test]
    fn images_inside_the_folder_inline_and_all_others_keep_their_paths() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("doc");
        fs::create_dir_all(folder.join("img")).unwrap();
        let png = b"\x89PNG\r\n\x1a\nrest".to_vec();
        fs::write(folder.join("img/a.png"), &png).unwrap();
        fs::write(folder.join("notes.png"), b"not an image").unwrap();
        fs::write(root.path().join("secret.png"), &png).unwrap();
        std::os::unix::fs::symlink(root.path().join("secret.png"), folder.join("link.png"))
            .unwrap();
        let page = html(
            "![a](img/a.png) ![b](link.png) ![c](../secret.png) ![d](notes.png) ![e](missing.png)",
            &ExportOptions {
                title: "t",
                css: "",
                diagram: &|_| None,
                math: &|_, _| None,
                folder: Some(&folder),
            },
        );
        assert!(
            page.contains(&format!(
                "<img src=\"data:image/png;base64,{}\" alt=\"a\">",
                base64(&png)
            )),
            "{page}"
        );
        for kept in ["link.png", "../secret.png", "notes.png", "missing.png"] {
            assert!(
                page.contains(&format!("<img src=\"{kept}\"")),
                "{kept}: {page}"
            );
        }
        assert_eq!(base64(b"Ma"), "TWE=");
    }
}
