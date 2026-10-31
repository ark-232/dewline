use std::path::Path;
use std::time::UNIX_EPOCH;

use dewline_core::{divergence, links, loads};

/// One file an agent loads in a folder.
#[derive(uniffi::Record)]
pub struct LoadedFile {
    pub agent: String,
    pub path: String,
    /// "walk", "@import from CLAUDE.md", or a Cursor rule's trigger.
    pub how: String,
    /// The file's bytes / 4.
    pub tokens: u64,
}

/// What Claude Code, Codex and Cursor load for a session started in `folder`.
#[uniffi::export]
pub fn what_loads(folder: String, home: Option<String>) -> Vec<LoadedFile> {
    loads::what_loads(Path::new(&folder), home.as_deref().map(Path::new))
        .into_iter()
        .map(|loaded| LoadedFile {
            agent: loaded.vendor.title().into(),
            path: loaded.path.to_string_lossy().into_owned(),
            how: loaded.how,
            tokens: loaded.tokens,
        })
        .collect()
}

/// A sibling instruction file whose sections differ from another's.
#[derive(uniffi::Record)]
pub struct SiblingDivergence {
    pub path: String,
    pub other: String,
    pub sections: Vec<String>,
}

#[uniffi::export]
pub fn sibling_divergence(folder: String) -> Vec<SiblingDivergence> {
    divergence::divergence(Path::new(&folder))
        .into_iter()
        .map(|found| SiblingDivergence {
            path: found.path.to_string_lossy().into_owned(),
            other: found.other.to_string_lossy().into_owned(),
            sections: found.sections,
        })
        .collect()
}

/// A memory or plan file an agent writes, with when it last changed in seconds since 1970.
#[derive(uniffi::Record)]
pub struct ReviewFile {
    pub path: String,
    pub modified: f64,
}

#[uniffi::export]
pub fn review_files(home: Option<String>, folder: Option<String>) -> Vec<ReviewFile> {
    loads::review_files(
        home.as_deref().map(Path::new),
        folder.as_deref().map(Path::new),
    )
    .into_iter()
    .map(|(path, modified)| ReviewFile {
        path: path.to_string_lossy().into_owned(),
        modified: modified
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |since| since.as_secs_f64()),
    })
    .collect()
}

/// A broken link or import in a file's text, in UTF-16 offsets.
#[derive(uniffi::Record)]
pub struct BrokenLink {
    pub location: u64,
    pub length: u64,
    pub target: String,
    pub problem: String,
}

/// The broken links and imports of `text`, the file at `path`.
#[uniffi::export]
pub fn broken_links(path: String, text: String, home: Option<String>) -> Vec<BrokenLink> {
    let file = Path::new(&path);
    let utf16 = |byte: usize| text[..byte].encode_utf16().count() as u64;
    links::broken(file, &text, home.as_deref().map(Path::new))
        .into_iter()
        .filter(|broken| broken.file == file)
        .map(|broken| {
            let start = utf16(broken.target.range.start);
            BrokenLink {
                location: start,
                length: utf16(broken.target.range.end) - start,
                target: broken.target.text,
                problem: broken.problem.describe().into(),
            }
        })
        .collect()
}
