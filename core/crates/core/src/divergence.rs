//! Sibling instruction files in one folder, compared heading by heading. Informational only: nothing here writes.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

/// Files past this size aren't compared.
const MAX_BYTES: u64 = 512 * 1024;

/// The instruction files of `folder` that agents read side by side: CLAUDE.md, AGENTS.md, GEMINI.md,
/// `.cursor/rules/*.mdc` and `.github/copilot-instructions.md`, in that order.
pub fn siblings(folder: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = ["CLAUDE.md", "AGENTS.md", "GEMINI.md"]
        .iter()
        .map(|name| folder.join(name))
        .filter(|path| path.is_file())
        .collect();
    if let Ok(entries) = fs::read_dir(folder.join(".cursor/rules")) {
        let mut rules: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "mdc") && path.is_file())
            .collect();
        rules.sort();
        found.extend(rules);
    }
    let copilot = folder.join(".github/copilot-instructions.md");
    if copilot.is_file() {
        found.push(copilot);
    }
    found
}

/// Each heading's section body, keyed by its title in lower case, with whitespace runs folded so reflowing doesn't
/// count. Text before the first heading, and a `.mdc` file's frontmatter, are left out.
pub fn sections(text: &str) -> BTreeMap<String, String> {
    let mut text = text;
    if let Some(rest) = text.strip_prefix("---\n")
        && let Some(end) = rest.find("\n---")
    {
        text = &rest[end + 4..];
    }
    let mut found = BTreeMap::new();
    let mut current: Option<(String, Vec<&str>)> = None;
    let mut fence: Option<&str> = None;
    for line in text.lines() {
        let trimmed = line.trim_start();
        if let Some(open) = fence {
            if trimmed.starts_with(open) {
                fence = None;
            }
        } else if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            fence = Some(&trimmed[..3]);
        } else if let Some(title) = heading(trimmed) {
            if let Some((key, body)) = current.take() {
                found.insert(key, fold(&body));
            }
            current = Some((title.to_lowercase(), Vec::new()));
            continue;
        }
        if let Some((_, body)) = current.as_mut() {
            body.push(line);
        }
    }
    if let Some((key, body)) = current {
        found.insert(key, fold(&body));
    }
    found
}

fn heading(line: &str) -> Option<&str> {
    let level = line.bytes().take_while(|&b| b == b'#').count();
    if !(1..=6).contains(&level) {
        return None;
    }
    let rest = &line[level..];
    (rest.is_empty() || rest.starts_with([' ', '\t']))
        .then(|| rest.trim().trim_end_matches('#').trim())
}

fn fold(lines: &[&str]) -> String {
    lines
        .join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// A sibling whose sections differ from another's.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Divergence {
    pub path: PathBuf,
    /// The sibling it's compared with: AGENTS.md when that shares a heading with it.
    pub other: PathBuf,
    /// The headings changed here, or present in `other` and missing here.
    pub sections: Vec<String>,
}

/// For each sibling in `folder` that shares a heading with another, the headings where the two disagree. Siblings
/// that share no heading are separate files, not copies, and aren't compared.
pub fn divergence(folder: &Path) -> Vec<Divergence> {
    let files: Vec<(PathBuf, BTreeMap<String, String>)> = siblings(folder)
        .into_iter()
        .filter(|path| fs::metadata(path).is_ok_and(|info| info.len() <= MAX_BYTES))
        .filter_map(|path| Some((sections(&fs::read_to_string(&path).ok()?), path)))
        .map(|(sections, path)| (path, sections))
        .collect();
    let agents = |path: &Path| path.file_name().is_some_and(|name| name == "AGENTS.md");
    let mut found = Vec::new();
    for (path, mine) in &files {
        let mut others: Vec<&(PathBuf, BTreeMap<String, String>)> = files
            .iter()
            .filter(|(other, theirs)| {
                other != path && theirs.keys().any(|key| mine.contains_key(key))
            })
            .collect();
        others.sort_by_key(|(other, _)| !agents(other));
        for (other, theirs) in others {
            let differ: Vec<String> = theirs
                .iter()
                .filter(|(key, body)| mine.get(*key) != Some(body))
                .map(|(key, _)| key.clone())
                .collect();
            if !differ.is_empty() {
                found.push(Divergence {
                    path: path.clone(),
                    other: other.clone(),
                    sections: differ,
                });
                break;
            }
        }
    }
    found
}
