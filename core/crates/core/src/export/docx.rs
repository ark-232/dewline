//! Word documents from markdown: headings, emphasis, lists, quotes, tables,
//! images, footnotes and code, written as a minimal OOXML package. Images
//! come only from files inside the document's folder; anything else keeps its
//! alt text.

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::fs::OpenOptions;
use std::io::{self, Cursor, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use pulldown_cmark::{Alignment, Event, Options, Parser, Tag, TagEnd};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

/// The largest image file a document takes.
const MAX_IMAGE: u64 = 20 << 20;
/// English Metric Units in a pixel at 96 dpi.
const EMU_PER_PX: u64 = 9525;
/// Six inches, the text width of a Letter page with 1-inch margins.
const MAX_WIDTH: u64 = 5_486_400;
/// The text width in twentieths of a point.
const TEXT_TWIPS: usize = 9360;

const W: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const R: &str = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

/// `markdown` as a DOCX file, with relative image paths read from `folder`.
pub fn docx(markdown: &str, folder: &Path) -> io::Result<Vec<u8>> {
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS;
    let mut writer = Writer {
        root: folder.canonicalize().ok(),
        ..Writer::default()
    };
    for event in Parser::new_ext(markdown, options) {
        writer.event(event);
    }
    writer.package()
}

#[derive(Default)]
struct Part {
    xml: String,
    /// Relationship type, target, and whether the target is outside the package.
    rels: Vec<(&'static str, String, bool)>,
}

impl Part {
    fn rel(&mut self, kind: &'static str, target: String, external: bool) -> String {
        self.rels.push((kind, target, external));
        format!("rId{}", self.rels.len() + 10)
    }

    fn rels_xml(&self, fixed: &str) -> String {
        let mut xml = format!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{fixed}"#
        );
        for (index, (kind, target, external)) in self.rels.iter().enumerate() {
            let mode = if *external { r#" TargetMode="External""# } else { "" };
            let _ = write!(
                xml,
                r#"<Relationship Id="rId{}" Type="{R}/{kind}" Target="{}"{mode}/>"#,
                index + 11,
                escaped(target)
            );
        }
        xml + "</Relationships>"
    }
}

struct Table {
    columns: Vec<Alignment>,
    cell: usize,
    head: bool,
}

#[derive(Default)]
struct Writer {
    root: Option<PathBuf>,
    doc: Part,
    notes: Part,
    /// Where a repeated footnote definition goes, unwritten.
    discard: Part,
    /// The footnote being written: `Some(None)` for a repeated definition.
    note: Option<Option<u32>>,
    note_ids: HashMap<String, u32>,
    defined: HashSet<u32>,
    /// The next paragraph opens with its footnote's mark.
    note_mark: bool,
    media: Vec<(String, Vec<u8>)>,
    drawings: u32,
    paragraph: bool,
    bold: u32,
    italic: u32,
    strike: u32,
    heading: Option<u32>,
    quote: u32,
    /// The numbering of each open list, innermost last.
    lists: Vec<u32>,
    /// Ordered lists: numbering, level and first number.
    ordered: Vec<(u32, usize, u64)>,
    /// The next paragraph is its list item's first and takes the number.
    item_first: bool,
    /// Inside a link, and whether it opened a hyperlink element.
    link: Option<bool>,
    code: Option<String>,
    /// Inside an image: its destination and the alt text so far.
    image: Option<(String, String)>,
    table: Option<Table>,
}

impl Writer {
    fn part(&mut self) -> &mut Part {
        match self.note {
            None => &mut self.doc,
            Some(Some(_)) => &mut self.notes,
            Some(None) => &mut self.discard,
        }
    }

    fn push(&mut self, xml: &str) {
        self.part().xml.push_str(xml);
    }

    fn note_id(&mut self, label: &str) -> u32 {
        let next = self.note_ids.len() as u32 + 1;
        *self.note_ids.entry(label.to_owned()).or_insert(next)
    }

    /// Opens a paragraph styled for where it sits, unless one is open.
    fn open(&mut self) {
        if self.paragraph {
            return;
        }
        let mut props = String::new();
        if let Some(level) = self.heading {
            let _ = write!(props, r#"<w:pStyle w:val="Heading{level}"/>"#);
        } else if self.note.is_some() {
            props.push_str(r#"<w:pStyle w:val="FootnoteText"/>"#);
        } else if self.quote > 0 {
            props.push_str(r#"<w:pStyle w:val="Quote"/>"#);
        }
        if let Some(&numbering) = self.lists.last() {
            if self.item_first {
                let _ = write!(
                    props,
                    r#"<w:numPr><w:ilvl w:val="{}"/><w:numId w:val="{numbering}"/></w:numPr>"#,
                    self.lists.len() - 1
                );
            } else {
                let _ = write!(props, r#"<w:ind w:left="{}"/>"#, 720 * self.lists.len());
            }
        } else if self.quote > 1 {
            let _ = write!(props, r#"<w:ind w:left="{}"/>"#, 720 * self.quote);
        }
        if let Some(table) = &self.table {
            let align = match table.columns.get(table.cell) {
                Some(Alignment::Center) => "center",
                Some(Alignment::Right) => "right",
                _ => "left",
            };
            let _ = write!(props, r#"<w:jc w:val="{align}"/>"#);
        }
        self.item_first = false;
        self.paragraph = true;
        if props.is_empty() {
            self.push("<w:p>");
        } else {
            self.push(&format!("<w:p><w:pPr>{props}</w:pPr>"));
        }
        if self.note_mark {
            self.note_mark = false;
            self.push(r#"<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r>"#);
        }
    }

    fn close(&mut self) {
        if self.paragraph {
            self.paragraph = false;
            self.push("</w:p>");
        }
    }

    fn text(&mut self, text: &str, style: Option<&str>) {
        if let Some((_, alt)) = &mut self.image {
            alt.push_str(text);
            return;
        }
        if let Some(code) = &mut self.code {
            code.push_str(text);
            return;
        }
        self.open();
        let mut props = String::new();
        if let Some(style) = style.or(self.link.map(|_| "Hyperlink")) {
            let _ = write!(props, r#"<w:rStyle w:val="{style}"/>"#);
        }
        if self.bold > 0 || self.table.as_ref().is_some_and(|table| table.head) {
            props.push_str("<w:b/>");
        }
        if self.italic > 0 {
            props.push_str("<w:i/>");
        }
        if self.strike > 0 {
            props.push_str("<w:strike/>");
        }
        let props = if props.is_empty() { props } else { format!("<w:rPr>{props}</w:rPr>") };
        self.push(&format!(r#"<w:r>{props}<w:t xml:space="preserve">{}</w:t></w:r>"#, escaped(text)));
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(text) => self.text(&text, None),
            Event::Code(text) => self.text(&text, Some("VerbatimChar")),
            Event::InlineMath(text) | Event::DisplayMath(text) => self.text(&text, Some("VerbatimChar")),
            Event::SoftBreak => self.text(" ", None),
            Event::HardBreak => {
                if self.image.is_none() && self.code.is_none() {
                    self.open();
                    self.push("<w:r><w:br/></w:r>");
                }
            }
            Event::Rule => {
                self.close();
                self.push(r#"<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="auto"/></w:pBdr></w:pPr></w:p>"#);
            }
            Event::TaskListMarker(done) => self.text(if done { "\u{2612} " } else { "\u{2610} " }, None),
            Event::FootnoteReference(label) => {
                if self.note.is_some() {
                    self.text(&label, Some("FootnoteReference"));
                } else {
                    let id = self.note_id(&label);
                    self.open();
                    self.push(&format!(
                        r#"<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="{id}"/></w:r>"#
                    ));
                }
            }
            // Raw HTML is inert: its tags are dropped and the text between them stays.
            Event::Html(_) | Event::InlineHtml(_) => {}
        }
    }

    fn start(&mut self, tag: Tag) {
        match tag {
            Tag::Paragraph | Tag::HtmlBlock => self.close(),
            Tag::Heading { level, .. } => {
                self.close();
                self.heading = Some(level as u32);
            }
            Tag::BlockQuote(_) => {
                self.close();
                self.quote += 1;
            }
            Tag::CodeBlock(_) => {
                self.close();
                self.code = Some(String::new());
            }
            Tag::List(start) => {
                self.close();
                let numbering = match start {
                    None => 1,
                    Some(first) => {
                        let numbering = self.ordered.len() as u32 + 2;
                        self.ordered.push((numbering, self.lists.len(), first));
                        numbering
                    }
                };
                self.lists.push(numbering);
            }
            Tag::Item => {
                self.close();
                self.item_first = true;
            }
            Tag::FootnoteDefinition(label) => {
                self.close();
                let id = self.note_id(&label);
                if self.defined.insert(id) {
                    self.note = Some(Some(id));
                    self.push(&format!(r#"<w:footnote w:id="{id}">"#));
                    self.note_mark = true;
                } else {
                    self.note = Some(None);
                }
            }
            Tag::Table(columns) => {
                self.close();
                let width = TEXT_TWIPS / columns.len().max(1);
                let mut xml = String::from(r#"<w:tbl><w:tblPr><w:tblStyle w:val="Table"/><w:tblW w:w="0" w:type="auto"/></w:tblPr><w:tblGrid>"#);
                for _ in &columns {
                    let _ = write!(xml, r#"<w:gridCol w:w="{width}"/>"#);
                }
                xml.push_str("</w:tblGrid>");
                self.push(&xml);
                self.table = Some(Table { columns, cell: 0, head: false });
            }
            Tag::TableHead => {
                self.push("<w:tr><w:trPr><w:tblHeader/></w:trPr>");
                if let Some(table) = &mut self.table {
                    table.head = true;
                    table.cell = 0;
                }
            }
            Tag::TableRow => {
                self.push("<w:tr>");
                if let Some(table) = &mut self.table {
                    table.cell = 0;
                }
            }
            Tag::TableCell => {
                let width = self.table.as_ref().map_or(TEXT_TWIPS, |table| TEXT_TWIPS / table.columns.len().max(1));
                self.push(&format!(r#"<w:tc><w:tcPr><w:tcW w:w="{width}" w:type="dxa"/></w:tcPr>"#));
            }
            Tag::Emphasis => self.italic += 1,
            Tag::Strong => self.bold += 1,
            Tag::Strikethrough => self.strike += 1,
            Tag::Link { dest_url, .. } => {
                if self.image.is_some() || self.code.is_some() {
                    return;
                }
                self.open();
                if dest_url.is_empty() || dest_url.starts_with('#') {
                    self.link = Some(false);
                } else {
                    let id = self.part().rel("hyperlink", dest_url.to_string(), true);
                    self.push(&format!(r#"<w:hyperlink r:id="{id}">"#));
                    self.link = Some(true);
                }
            }
            Tag::Image { dest_url, .. } => self.image = Some((dest_url.to_string(), String::new())),
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph | TagEnd::HtmlBlock => self.close(),
            TagEnd::Heading(_) => {
                self.close();
                self.heading = None;
            }
            TagEnd::BlockQuote(_) => {
                self.close();
                self.quote = self.quote.saturating_sub(1);
            }
            TagEnd::CodeBlock => {
                let code = self.code.take().unwrap_or_default();
                for line in code.strip_suffix('\n').unwrap_or(&code).split('\n') {
                    self.push(&format!(
                        r#"<w:p><w:pPr><w:pStyle w:val="SourceCode"/></w:pPr><w:r><w:t xml:space="preserve">{}</w:t></w:r></w:p>"#,
                        escaped(line)
                    ));
                }
            }
            TagEnd::List(_) => {
                self.close();
                self.lists.pop();
            }
            TagEnd::Item => {
                self.close();
                self.item_first = false;
            }
            TagEnd::FootnoteDefinition => {
                if self.note == Some(None) {
                    self.close();
                } else {
                    // An empty definition still needs a paragraph to carry its mark.
                    if self.note_mark {
                        self.open();
                    }
                    self.close();
                    self.push("</w:footnote>");
                }
                self.note = None;
            }
            TagEnd::Table => {
                self.push("</w:tbl><w:p/>");
                self.table = None;
            }
            TagEnd::TableHead | TagEnd::TableRow => {
                let missing = self.table.as_ref().map_or(0, |table| table.columns.len().saturating_sub(table.cell));
                for _ in 0..missing {
                    self.start(Tag::TableCell);
                    self.end(TagEnd::TableCell);
                }
                self.push("</w:tr>");
                if let Some(table) = &mut self.table {
                    table.head = false;
                }
            }
            TagEnd::TableCell => {
                self.open();
                self.close();
                self.push("</w:tc>");
                if let Some(table) = &mut self.table {
                    table.cell += 1;
                }
            }
            TagEnd::Emphasis => self.italic = self.italic.saturating_sub(1),
            TagEnd::Strong => self.bold = self.bold.saturating_sub(1),
            TagEnd::Strikethrough => self.strike = self.strike.saturating_sub(1),
            TagEnd::Link => {
                if self.link.take() == Some(true) {
                    self.push("</w:hyperlink>");
                }
            }
            TagEnd::Image => {
                let Some((dest, alt)) = self.image.take() else { return };
                match self.picture(&dest) {
                    Some((id, cx, cy)) => {
                        self.open();
                        self.drawings += 1;
                        let n = self.drawings;
                        self.push(&format!(
                            r#"<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="{cx}" cy="{cy}"/><wp:docPr id="{n}" name="Picture {n}" descr="{alt}"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="{n}" name="Picture {n}"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="{id}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"#,
                            alt = escaped(&alt)
                        ));
                    }
                    None => {
                        let text = if alt.is_empty() { dest } else { alt };
                        self.text(&text, None);
                    }
                }
            }
            _ => {}
        }
    }

    /// Adds the image at `dest` to the package and returns its relationship and size in EMUs.
    fn picture(&mut self, dest: &str) -> Option<(String, u64, u64)> {
        let bytes = read_image(self.root.as_deref()?, dest)?;
        let (extension, width, height) = image_size(&bytes)?;
        let name = format!("image{}.{extension}", self.media.len() + 1);
        self.media.push((name.clone(), bytes));
        let id = self.part().rel("image", format!("media/{name}"), false);
        let (mut cx, mut cy) = (width * EMU_PER_PX, height * EMU_PER_PX);
        if cx > MAX_WIDTH {
            cy = cy * MAX_WIDTH / cx;
            cx = MAX_WIDTH;
        }
        Some((id, cx, cy))
    }

    fn package(mut self) -> io::Result<Vec<u8>> {
        // A reference whose definition never came still needs a footnote to point at.
        let mut missing: Vec<u32> = self.note_ids.values().copied().filter(|id| !self.defined.contains(id)).collect();
        missing.sort_unstable();
        for id in missing {
            let _ = write!(
                self.notes.xml,
                r#"<w:footnote w:id="{id}"><w:p><w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr><w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r></w:p></w:footnote>"#
            );
        }
        let namespaces = format!(
            r#"xmlns:w="{W}" xmlns:r="{R}" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture""#
        );
        let head = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#;
        let document = format!(
            r#"{head}<w:document {namespaces}><w:body>{}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>"#,
            self.doc.xml
        );
        let footnotes = format!(
            r#"{head}<w:footnotes {namespaces}><w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>{}</w:footnotes>"#,
            self.notes.xml
        );
        let fixed = format!(
            r#"<Relationship Id="rId1" Type="{R}/styles" Target="styles.xml"/><Relationship Id="rId2" Type="{R}/numbering" Target="numbering.xml"/><Relationship Id="rId3" Type="{R}/footnotes" Target="footnotes.xml"/><Relationship Id="rId4" Type="{R}/settings" Target="settings.xml"/>"#
        );
        let mut files: Vec<(String, Vec<u8>)> = vec![
            ("[Content_Types].xml".into(), CONTENT_TYPES.into()),
            ("_rels/.rels".into(), ROOT_RELS.into()),
            ("word/document.xml".into(), document.into_bytes()),
            ("word/_rels/document.xml.rels".into(), self.doc.rels_xml(&fixed).into_bytes()),
            ("word/styles.xml".into(), STYLES.into()),
            ("word/numbering.xml".into(), numbering(&self.ordered).into_bytes()),
            ("word/footnotes.xml".into(), footnotes.into_bytes()),
            ("word/settings.xml".into(), SETTINGS.into()),
        ];
        if !self.notes.rels.is_empty() {
            files.push(("word/_rels/footnotes.xml.rels".into(), self.notes.rels_xml("").into_bytes()));
        }
        files.extend(self.media.into_iter().map(|(name, bytes)| (format!("word/media/{name}"), bytes)));
        let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        for (name, bytes) in files {
            zip.start_file(name, options).map_err(io::Error::other)?;
            zip.write_all(&bytes)?;
        }
        Ok(zip.finish().map_err(io::Error::other)?.into_inner())
    }
}

/// The bytes of the image `dest` names, when it is a file inside `root`: a
/// relative or absolute path, percent-encoded or not, but never a URL. The
/// path is resolved, checked against `root`, opened without following a link
/// and checked again by the descriptor's own path.
fn read_image(root: &Path, dest: &str) -> Option<Vec<u8>> {
    let scheme = dest.split_once(':').is_some_and(|(scheme, _)| {
        scheme.len() > 1 && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
    });
    if dest.is_empty() || scheme || dest.starts_with("//") {
        return None;
    }
    let path = root.join(percent_decoded(dest.split(['?', '#']).next()?)?);
    let real = path.canonicalize().ok()?;
    if !real.starts_with(root) {
        return None;
    }
    let file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(&real).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > MAX_IMAGE || !opened_inside(&file, root) {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_IMAGE).read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

#[cfg(target_os = "macos")]
fn opened_inside(file: &std::fs::File, root: &Path) -> bool {
    use std::ffi::{CStr, OsStr};
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    let mut buffer = [0u8; libc::PATH_MAX as usize];
    // SAFETY: F_GETPATH writes at most PATH_MAX bytes, NUL included, into the buffer.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, buffer.as_mut_ptr()) } == -1 {
        return false;
    }
    CStr::from_bytes_until_nul(&buffer).is_ok_and(|path| Path::new(OsStr::from_bytes(path.to_bytes())).starts_with(root))
}

#[cfg(not(target_os = "macos"))]
fn opened_inside(_: &std::fs::File, _: &Path) -> bool {
    true
}

fn percent_decoded(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The package extension and pixel size of a PNG, JPEG or GIF.
fn image_size(bytes: &[u8]) -> Option<(&'static str, u64, u64)> {
    let be = |at: usize, len: usize| bytes.get(at..at + len).map(|b| b.iter().fold(0u64, |n, &x| n << 8 | x as u64));
    let (extension, width, height) = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        ("png", be(16, 4)?, be(20, 4)?)
    } else if bytes.starts_with(b"GIF8") {
        let le = |at: usize| bytes.get(at..at + 2).map(|b| u64::from(b[0]) | u64::from(b[1]) << 8);
        ("gif", le(6)?, le(8)?)
    } else if bytes.starts_with(&[0xff, 0xd8]) {
        let mut at = 2;
        loop {
            if *bytes.get(at)? != 0xff {
                return None;
            }
            let marker = *bytes.get(at + 1)?;
            match marker {
                0xff => at += 1,
                0x01 | 0xd0..=0xd8 => at += 2,
                0xc0..=0xcf if !matches!(marker, 0xc4 | 0xc8 | 0xcc) => break ("jpeg", be(at + 7, 2)?, be(at + 5, 2)?),
                _ => at += 2 + be(at + 2, 2)? as usize,
            }
        }
    } else {
        return None;
    };
    (width > 0 && height > 0).then_some((extension, width, height))
}

/// `text` safe inside XML text and attribute values, without the characters XML 1.0 forbids.
fn escaped(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\t' => out.push_str("    "),
            '\n' | '\r' => out.push(' '),
            '\u{0}'..='\u{1f}' | '\u{fffe}' | '\u{ffff}' => {}
            c => out.push(c),
        }
    }
    out
}

/// Bullets on every level, and decimal numbers that each ordered list restarts at its own first number.
fn numbering(ordered: &[(u32, usize, u64)]) -> String {
    let mut xml = format!(r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:numbering xmlns:w="{W}">"#);
    for (id, format) in [(0, "bullet"), (1, "decimal")] {
        let _ = write!(xml, r#"<w:abstractNum w:abstractNumId="{id}"><w:multiLevelType w:val="hybridMultilevel"/>"#);
        for level in 0..9 {
            let text = if format == "bullet" {
                ["\u{2022}", "\u{25e6}", "\u{25aa}"][level % 3].to_owned()
            } else {
                format!("%{}.", level + 1)
            };
            let _ = write!(
                xml,
                r#"<w:lvl w:ilvl="{level}"><w:start w:val="1"/><w:numFmt w:val="{format}"/><w:lvlText w:val="{text}"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="{}" w:hanging="360"/></w:pPr></w:lvl>"#,
                720 * (level + 1)
            );
        }
        xml.push_str("</w:abstractNum>");
    }
    xml.push_str(r#"<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>"#);
    for (id, level, start) in ordered {
        let _ = write!(
            xml,
            r#"<w:num w:numId="{id}"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="{level}"><w:startOverride w:val="{start}"/></w:lvlOverride></w:num>"#
        );
    }
    xml + "</w:numbering>"
}

const CONTENT_TYPES: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="jpeg" ContentType="image/jpeg"/><Default Extension="gif" ContentType="image/gif"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/><Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/></Types>"#;

const ROOT_RELS: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#;

const SETTINGS: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:footnotePr><w:footnote w:id="-1"/><w:footnote w:id="0"/></w:footnotePr></w:settings>"#;

const STYLES: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia" w:eastAsia="Georgia" w:cs="Georgia"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="300" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/><w:i/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="4"/></w:pPr><w:rPr><w:b/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="5"/></w:pPr><w:rPr><w:i/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="A0A0A0"/></w:pBdr><w:ind w:left="720"/></w:pPr><w:rPr><w:i/><w:color w:val="505050"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="SourceCode"><w:name w:val="Source Code"/><w:basedOn w:val="Normal"/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F4F4F4"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:eastAsia="Menlo" w:cs="Menlo"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="40" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style><w:style w:type="character" w:styleId="VerbatimChar"><w:name w:val="Verbatim Char"/><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:eastAsia="Menlo" w:cs="Menlo"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr></w:style><w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="1F5FBF"/><w:u w:val="single"/></w:rPr></w:style><w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/><w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style><w:style w:type="table" w:styleId="Table"><w:name w:val="Table"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:left w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:right w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/></w:tblBorders><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style></w:styles>"#;
