//! `dewline export`: HTML here, through core's exporter; PDF through the app, which owns the paged layout.

use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::{self, Path};
use std::process::Command;

use clap::ValueEnum;
use dewline_core::export::{self, ExportOptions};

#[derive(Clone, Copy, ValueEnum)]
pub enum Format {
    Html,
    Pdf,
}

/// The page's look without the app's theme: system faces, a readable measure, light and dark.
const CSS: &str = "\
:root { color-scheme: light dark; }
body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; max-width: 42em; margin: 2em auto; padding: 0 1em; }
pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
pre { padding: 0.75em 1em; overflow-x: auto; background: rgba(127, 127, 127, 0.1); border-radius: 6px; }
blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid rgba(127, 127, 127, 0.4); }
table { border-collapse: collapse; }
th, td { border: 1px solid rgba(127, 127, 127, 0.4); padding: 0.3em 0.6em; }
img { max-width: 100%; }
";

pub fn run(file: &Path, format: Format, out: Option<&Path>) -> Result<(), String> {
    let source = fs::canonicalize(file).map_err(|error| format!("{}: {error}", file.display()))?;
    let out = match out {
        Some(out) => path::absolute(out).map_err(|error| format!("{}: {error}", out.display()))?,
        None => source.with_extension(match format {
            Format::Html => "html",
            Format::Pdf => "pdf",
        }),
    };
    if fs::canonicalize(&out).is_ok_and(|out| out == source) {
        return Err(format!(
            "{}: the export would replace its own source",
            out.display()
        ));
    }
    match format {
        Format::Html => {
            let text = fs::read_to_string(&source)
                .map_err(|error| format!("{}: {error}", source.display()))?;
            let title = source.file_stem().unwrap_or_default().to_string_lossy();
            let page = export::html(
                &text,
                &ExportOptions {
                    title: &title,
                    css: CSS,
                    diagram: &|_| None,
                    math: &|_, _| None,
                    folder: source.parent(),
                },
            );
            fs::write(&out, page).map_err(|error| format!("{}: {error}", out.display()))
        }
        Format::Pdf => {
            let url = format!(
                "dewline://export?to=pdf&file={}&out={}",
                percent(&source),
                percent(&out)
            );
            let status = Command::new("/usr/bin/open")
                .arg(&url)
                .status()
                .map_err(|error| format!("couldn't run /usr/bin/open: {error}"))?;
            if status.success() {
                Ok(())
            } else {
                Err("Dewline didn't take the export; PDF export needs the app".into())
            }
        }
    }
}

/// `path` for a URL query: every byte but letters, digits, `/` and `-._~` percent-encoded.
fn percent(path: &Path) -> String {
    let mut out = String::new();
    for &byte in path.as_os_str().as_bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_lands_beside_the_file_with_its_images_inlined() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("launch plan.md");
        fs::write(&file, "# Plan\n\n![dot](dot.png) <script>x</script>\n").unwrap();
        fs::write(dir.path().join("dot.png"), b"\x89PNG\r\n\x1a\nrest").unwrap();
        run(&file, Format::Html, None).unwrap();
        let page = fs::read_to_string(dir.path().join("launch plan.html")).unwrap();
        assert!(page.contains("<title>launch plan</title>"));
        assert!(page.contains("<h1>Plan</h1>"));
        assert!(page.contains("data:image/png;base64,"));
        assert!(!page.contains("<script>"));
        let out = dir.path().join("out/page.html");
        fs::create_dir(dir.path().join("out")).unwrap();
        run(&file, Format::Html, Some(&out)).unwrap();
        assert!(out.exists());
        assert!(run(&file, Format::Html, Some(&file)).is_err());
    }

    #[test]
    fn a_url_carries_any_path() {
        assert_eq!(
            percent(Path::new("/Users/me/a b&c=d?.md")),
            "/Users/me/a%20b%26c%3Dd%3F.md"
        );
        assert_eq!(percent(Path::new("/tmp/café")), "/tmp/caf%C3%A9");
    }
}
