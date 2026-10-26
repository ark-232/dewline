use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, LazyLock};
use std::thread;
use std::time::Duration;

use dewline_core::md;
use mermaid_rs_renderer::{LayoutConfig, RenderOptions, Theme};
use ratex_layout::LayoutOptions;
use ratex_types::color::Color;
use resvg::{tiny_skia, usvg};

mod markdown;
mod save;

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

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RenderError {
    #[error("the source is over 50 KB")]
    TooLarge,
    #[error("rendering took over 250 ms")]
    TooSlow,
    #[error("{message}")]
    Invalid { message: String },
}

/// The editor theme's colors for a diagram, each sRGB 0xRRGGBBAA.
#[derive(uniffi::Record)]
pub struct DiagramColors {
    pub paper: u32,
    pub ink: u32,
    pub ink2: u32,
    pub accent: u32,
    pub rule: u32,
    pub fill: u32,
}

impl DiagramColors {
    /// The renderer's theme in these colors for a diagram of `kind`. On a dark page, where the ink is lighter than
    /// the paper, pie slices and git branches take the renderer's dark palettes and `LIGHT_ONLY` kinds keep its light
    /// theme.
    fn theme(&self, kind: &str) -> Theme {
        let lightness = |color: u32| (color >> 24) + ((color >> 16) & 0xff) + ((color >> 8) & 0xff);
        let modern = Theme::modern();
        let base = if lightness(self.ink) <= lightness(self.paper) {
            modern
        } else if LIGHT_ONLY.contains(&kind) {
            return modern;
        } else {
            Theme {
                font_family: modern.font_family,
                font_size: modern.font_size,
                ..Theme::dark()
            }
        };
        let [paper, ink, ink2, accent, rule, fill] = [
            self.paper,
            self.ink,
            self.ink2,
            self.accent,
            self.rule,
            self.fill,
        ]
        .map(|color| format!("#{color:08x}"));
        Theme {
            background: paper.clone(),
            edge_label_background: paper.clone(),
            cluster_background: paper.clone(),
            tertiary_color: paper,
            primary_text_color: ink.clone(),
            text_color: ink.clone(),
            git_commit_label_color: ink.clone(),
            git_tag_label_color: ink.clone(),
            pie_title_text_color: ink.clone(),
            pie_legend_text_color: ink,
            line_color: ink2,
            sequence_note_border: accent,
            primary_border_color: rule.clone(),
            cluster_border: rule.clone(),
            sequence_actor_border: rule.clone(),
            sequence_actor_line: rule.clone(),
            sequence_activation_border: rule.clone(),
            git_tag_label_border: rule.clone(),
            pie_outer_stroke_color: rule,
            primary_color: fill.clone(),
            secondary_color: fill.clone(),
            sequence_actor_fill: fill.clone(),
            sequence_note_fill: fill.clone(),
            sequence_activation_fill: fill.clone(),
            git_commit_label_background: fill.clone(),
            git_tag_label_background: fill,
            ..base
        }
    }
}

/// Premultiplied RGBA, row by row.
#[derive(uniffi::Record)]
pub struct Raster {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

// The diagram types mermaid-rs-renderer parses. A source without one of these
// headers would still render: the renderer reads anything shaped like an edge
// as a flowchart, so newer types come out as nonsense instead of an error.
const HEADERS: [&str; 29] = [
    "flowchart",
    "graph",
    "sequencediagram",
    "classdiagram",
    "statediagram",
    "erdiagram",
    "pie",
    "mindmap",
    "journey",
    "timeline",
    "gantt",
    "requirementdiagram",
    "gitgraph",
    "c4",
    "c4context",
    "c4container",
    "c4component",
    "c4dynamic",
    "c4deployment",
    "sankey",
    "quadrantchart",
    "zenuml",
    "block",
    "packet",
    "kanban",
    "architecture",
    "radar",
    "treemap",
    "xychart",
];
// Diagram types the renderer draws for a white page: on a dark one, some of their labels, lines or flows vanish.
const LIGHT_ONLY: [&str; 11] = [
    "c4",
    "c4context",
    "c4container",
    "c4component",
    "c4dynamic",
    "c4deployment",
    "quadrantchart",
    "radar",
    "requirementdiagram",
    "sankey",
    "timeline",
];
const MAX_SOURCE: usize = 50 * 1024;
const MAX_PIXELS: u32 = 16 << 20;
const BUDGET: Duration = Duration::from_millis(250);

static FONTS: LazyLock<Arc<usvg::fontdb::Database>> = LazyLock::new(|| {
    let mut fonts = usvg::fontdb::Database::new();
    fonts.load_system_fonts();
    Arc::new(fonts)
});

// mermaid-rs-renderer scans the system fonts on its first text measurement,
// which takes about the whole budget; the budget is for the diagram.
static MERMAID_FONTS: LazyLock<()> = LazyLock::new(|| {
    let _ = mermaid_rs_renderer::render("flowchart LR\n  a");
});

/// Runs `work` on its own thread and stops waiting after the budget. Neither
/// renderer can be cancelled, so a render that overruns finishes unobserved.
fn within_budget<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, RenderError> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || sender.send(work()));
    match receiver.recv_timeout(BUDGET) {
        Ok(result) => result.map_err(|message| RenderError::Invalid { message }),
        Err(RecvTimeoutError::Timeout) => Err(RenderError::TooSlow),
        Err(RecvTimeoutError::Disconnected) => Err(RenderError::Invalid {
            message: "the renderer crashed".into(),
        }),
    }
}

#[uniffi::export]
pub fn render_mermaid(source: String, colors: DiagramColors) -> Result<String, RenderError> {
    if source.len() > MAX_SOURCE {
        return Err(RenderError::TooLarge);
    }
    let mut frontmatter = false;
    let header = source.lines().map(str::trim).find(|line| {
        frontmatter ^= *line == "---";
        !frontmatter && !line.is_empty() && *line != "---" && !line.starts_with("%%")
    });
    let kind = header.map_or("", |line| {
        line.split(|c: char| !c.is_ascii_alphanumeric())
            .next()
            .unwrap_or("")
    });
    let known = kind.to_ascii_lowercase();
    if !HEADERS.contains(&known.as_str()) {
        return Err(RenderError::Invalid {
            message: format!("unsupported diagram type '{kind}'"),
        });
    }
    LazyLock::force(&MERMAID_FONTS);
    let theme = colors.theme(&known);
    within_budget(move || {
        let options = RenderOptions {
            theme,
            layout: LayoutConfig::default(),
        };
        mermaid_rs_renderer::render_with_options(&source, options)
            .map_err(|error| error.to_string())
    })
}

/// Draws an SVG at `scale` pixels per SVG unit, or smaller to fit `max_width`
/// pixels.
#[uniffi::export]
pub fn rasterize_svg(svg: String, scale: f32, max_width: u32) -> Result<Raster, RenderError> {
    let invalid = |message: String| RenderError::Invalid { message };
    let options = usvg::Options {
        fontdb: FONTS.clone(),
        ..Default::default()
    };
    let tree = usvg::Tree::from_str(&svg, &options).map_err(|error| invalid(error.to_string()))?;
    let scale = scale.min(max_width as f32 / tree.size().width());
    let (width, height) = (
        (tree.size().width() * scale).ceil() as u32,
        (tree.size().height() * scale).ceil() as u32,
    );
    if width.saturating_mul(height) > MAX_PIXELS {
        return Err(invalid("the picture is over 16 megapixels".into()));
    }
    let mut pixmap = tiny_skia::Pixmap::new(width, height)
        .ok_or_else(|| invalid("the picture is empty".into()))?;
    resvg::render(
        &tree,
        tiny_skia::Transform::from_scale(scale, scale),
        &mut pixmap.as_mut(),
    );
    Ok(Raster {
        width,
        height,
        pixels: pixmap.take(),
    })
}

/// A PNG of display math at `size` points, `scale` pixels per point, in
/// `color` (0xRRGGBBAA).
#[uniffi::export]
pub fn render_math(tex: String, size: f32, scale: f32, color: u32) -> Result<Vec<u8>, RenderError> {
    if tex.len() > MAX_SOURCE {
        return Err(RenderError::TooLarge);
    }
    within_budget(move || {
        let [r, g, b, a] = color
            .to_be_bytes()
            .map(|channel| f32::from(channel) / 255.0);
        let nodes = ratex_parser::parser::parse(&tex).map_err(|error| error.to_string())?;
        let layout = ratex_layout::layout(
            &nodes,
            &LayoutOptions::default().with_color(Color { r, g, b, a }),
        );
        ratex_layout::validate_layout(&layout)?;
        let options = ratex_render::RenderOptions {
            font_size: size,
            padding: 0.0,
            background_color: Color {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 0.0,
            },
            font_dir: String::new(),
            device_pixel_ratio: scale,
        };
        ratex_render::render_to_png(&ratex_layout::to_display_list(&layout), &options)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Once;

    // mermaid-rs-renderer copies a font into XDG_CACHE_HOME, or ~/.cache without it.
    fn isolate() {
        static ONCE: Once = Once::new();
        // SAFETY: every test calls this first, so no test thread reads the environment meanwhile.
        ONCE.call_once(|| unsafe {
            std::env::set_var(
                "XDG_CACHE_HOME",
                std::env::temp_dir().join("dewline-ffi-tests"),
            );
        });
    }

    // Nightwatch, dark.
    fn night() -> DiagramColors {
        DiagramColors {
            paper: 0x08101aff,
            ink: 0xd1e1e9ff,
            ink2: 0xa3b8c5ff,
            accent: 0x62bbf5ff,
            rule: 0x4f6172ff,
            fill: 0x0f1926ff,
        }
    }

    #[test]
    fn mermaid_renders_svg() {
        isolate();
        let svg = render_mermaid("flowchart LR\n  a[Start] --> b[Stop]".into(), night()).unwrap();
        assert!(svg.starts_with("<svg") && svg.contains("Start"));
    }

    #[test]
    fn mermaid_takes_the_theme_colors() {
        isolate();
        let svg = render_mermaid(
            "sequenceDiagram\n  a->>b: hi\n  note over b: n".into(),
            night(),
        )
        .unwrap();
        for color in [
            "#08101aff",
            "#d1e1e9ff",
            "#a3b8c5ff",
            "#62bbf5ff",
            "#4f6172ff",
            "#0f1926ff",
        ] {
            assert!(svg.contains(color), "{color} is missing");
        }
    }

    #[test]
    fn light_only_kinds_keep_the_light_theme_on_a_dark_page() {
        isolate();
        let svg = render_mermaid("timeline\n  2002 : LinkedIn".into(), night()).unwrap();
        assert!(svg.contains("fill=\"#FFFFFF\"") && !svg.contains("#08101aff"));
    }

    #[test]
    fn mermaid_errors_name_the_problem() {
        isolate();
        let Err(RenderError::Invalid { message }) =
            render_mermaid("venn-beta\n  set A\n  set B".into(), night())
        else {
            panic!("rendered a diagram type the renderer does not parse");
        };
        assert_eq!(message, "unsupported diagram type 'venn'");
        let Err(RenderError::Invalid { message }) = render_mermaid(
            "---\ntitle: T\n---\nclassDiagram\n  class A {\n    <<interface>>\n  }".into(),
            night(),
        ) else {
            panic!("rendered a class body the renderer does not parse");
        };
        assert!(message.contains("<<interface>>"), "{message}");
        assert!(matches!(
            render_mermaid("%%\n".repeat(MAX_SOURCE), night()),
            Err(RenderError::TooLarge)
        ));
    }

    #[test]
    fn svg_rasterizes_at_scale() {
        isolate();
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="4"><rect width="10" height="4" fill="red"/></svg>"#;
        let raster = rasterize_svg(svg.into(), 2.0, 100).unwrap();
        assert_eq!((raster.width, raster.height), (20, 8));
        assert_eq!(raster.pixels.len(), 20 * 8 * 4);
        assert_eq!(raster.pixels[..4], [255, 0, 0, 255]);
        let fitted = rasterize_svg(svg.into(), 2.0, 5).unwrap();
        assert_eq!((fitted.width, fitted.height), (5, 2));
    }

    #[test]
    fn math_renders_png_or_names_the_error() {
        isolate();
        let png = render_math(r"\frac{a}{b}".into(), 17.0, 2.0, 0x000000ff).unwrap();
        assert_eq!(png[1..4], *b"PNG");
        assert!(matches!(
            render_math(r"\frac{a".into(), 17.0, 2.0, 0x000000ff),
            Err(RenderError::Invalid { .. })
        ));
    }

    #[test]
    fn math_over_the_size_cap_is_refused() {
        isolate();
        assert!(matches!(
            render_math("%\n".repeat(MAX_SOURCE), 17.0, 2.0, 0x000000ff),
            Err(RenderError::TooLarge)
        ));
    }
}
