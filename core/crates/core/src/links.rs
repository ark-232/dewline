//! CLAUDE.md `@path` imports and relative markdown links: what each names, and which name nothing.

use std::collections::HashSet;
use std::fs;
use std::ops::Range;
use std::path::{Component, Path, PathBuf};

use pulldown_cmark::{Event, Options, Parser, Tag};

/// Claude Code follows imports at most this many hops from the file it loads.
pub const MAX_DEPTH: usize = 5;
/// `check_dir` reads at most this many files.
const MAX_FILES: usize = 20_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Import,
    Link,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Problem {
    Missing,
    /// The import leads back to a file already on its path.
    Cycle,
    /// More than `MAX_DEPTH` hops in, so Claude Code doesn't load it.
    TooDeep,
}

impl Problem {
    pub fn describe(self) -> &'static str {
        match self {
            Problem::Missing => "no such file",
            Problem::Cycle => "imports a file that imports it",
            Problem::TooDeep => "more than 5 imports deep",
        }
    }
}

/// One import or link in a file's text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub kind: Kind,
    /// Byte range of the `@path` or the whole link.
    pub range: Range<usize>,
    /// As written.
    pub text: String,
    pub path: PathBuf,
}

/// Whether Claude Code reads `@path` imports in the file at `path`: its memory files, by name.
pub fn takes_imports(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| {
            name.len() >= 6 && name[..6].eq_ignore_ascii_case("claude") && name.ends_with(".md")
        })
}

/// The imports (when `imports` is set) and relative links of `text`, a file in `folder`, outside code.
pub fn targets(text: &str, folder: &Path, home: Option<&Path>, imports: bool) -> Vec<Target> {
    let mut found = Vec::new();
    let mut code: Vec<Range<usize>> = Vec::new();
    for (event, range) in Parser::new_ext(text, Options::empty()).into_offset_iter() {
        match event {
            Event::Start(Tag::Link { dest_url, .. })
            | Event::Start(Tag::Image { dest_url, .. }) => {
                if let Some(path) = local(&dest_url, folder) {
                    found.push(Target {
                        kind: Kind::Link,
                        range,
                        text: dest_url.to_string(),
                        path,
                    });
                }
            }
            Event::Code(_)
            | Event::Html(_)
            | Event::InlineHtml(_)
            | Event::Start(Tag::CodeBlock(_)) => code.push(range),
            _ => {}
        }
    }
    if imports {
        found.extend(
            at_paths(text, folder, home)
                .into_iter()
                .filter(|target| !code.iter().any(|block| block.contains(&target.range.start))),
        );
    }
    found
}

/// A link's file, or None for a URL, an anchor in this file, or a site-root path.
fn local(dest: &str, folder: &Path) -> Option<PathBuf> {
    let dest = dest.split(['#', '?']).next().unwrap_or("");
    let scheme = dest.find(':').is_some_and(|colon| {
        dest[..colon]
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"+.-".contains(&b))
    });
    if dest.is_empty() || dest.starts_with('/') || scheme {
        return None;
    }
    Some(folder.join(decode(dest)))
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16).map(|d| d as u8);
        if bytes[i] == b'%'
            && let (Some(hi), Some(lo)) = (
                bytes.get(i + 1).copied().and_then(hex),
                bytes.get(i + 2).copied().and_then(hex),
            )
        {
            out.push(hi << 4 | lo);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_owned())
}

/// Each `@path` in `text` that starts a word and looks like a path: it holds a `/` or a `.`.
fn at_paths(span: &str, folder: &Path, home: Option<&Path>) -> Vec<Target> {
    let mut found = Vec::new();
    for (at, _) in span.match_indices('@') {
        if span[..at]
            .chars()
            .next_back()
            .is_some_and(|c| !c.is_whitespace())
        {
            continue;
        }
        let rest = &span[at + 1..];
        let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
        let word = rest[..end].trim_end_matches([',', ';', ':', ')', ']', '!', '?']);
        let word = word.strip_suffix('.').unwrap_or(word);
        if word.is_empty() || !word.contains(['/', '.']) {
            continue;
        }
        let path = match word.strip_prefix("~/") {
            Some(rest) => match home {
                Some(home) => home.join(rest),
                None => continue,
            },
            None if word.starts_with('/') => PathBuf::from(word),
            None => folder.join(word),
        };
        let start = at;
        found.push(Target {
            kind: Kind::Import,
            range: start..start + 1 + word.len(),
            text: format!("@{word}"),
            path,
        });
    }
    found
}

/// `path` with `.` and `..` folded, without touching the disk.
fn normal(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

/// A problem with one target of the file at `file`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Broken {
    pub file: PathBuf,
    pub target: Target,
    pub problem: Problem,
}

/// The broken links and imports of `text`, the file at `file`: missing targets, and for a memory file the imports
/// that cycle or run too deep anywhere under it.
pub fn broken(file: &Path, text: &str, home: Option<&Path>) -> Vec<Broken> {
    let folder = file.parent().unwrap_or(Path::new("/"));
    let imports = takes_imports(file);
    let mut found: Vec<Broken> = targets(text, folder, home, imports)
        .into_iter()
        .filter(|target| !target.path.exists())
        .map(|target| Broken {
            file: file.to_path_buf(),
            target,
            problem: Problem::Missing,
        })
        .collect();
    if imports {
        let mut path = vec![normal(file)];
        walk_imports(
            text,
            folder,
            home,
            1,
            &mut path,
            &mut |from, target, problem| {
                if problem != Problem::Missing {
                    found.push(Broken {
                        file: from.to_path_buf(),
                        target: target.clone(),
                        problem,
                    });
                }
            },
        );
    }
    found
}

/// Every import under `text`, depth first: `visit(file, target, problem)` for each broken one, `Missing` included.
/// `stack` holds the files on the current path.
fn walk_imports(
    text: &str,
    folder: &Path,
    home: Option<&Path>,
    depth: usize,
    stack: &mut Vec<PathBuf>,
    visit: &mut dyn FnMut(&Path, &Target, Problem),
) {
    let from = stack.last().cloned().unwrap_or_default();
    for target in targets(text, folder, home, true) {
        if target.kind != Kind::Import {
            continue;
        }
        let path = normal(&target.path);
        if stack.contains(&path) {
            visit(&from, &target, Problem::Cycle);
        } else if depth > MAX_DEPTH {
            visit(&from, &target, Problem::TooDeep);
        } else if let Ok(inner) = fs::read_to_string(&path) {
            stack.push(path.clone());
            let folder = path.parent().unwrap_or(Path::new("/")).to_path_buf();
            walk_imports(&inner, &folder, home, depth + 1, stack, visit);
            stack.pop();
        } else {
            visit(&from, &target, Problem::Missing);
        }
    }
}

/// The files the imports of the memory file `file` load, each once, with the file that imports it, depth first.
pub fn imported(file: &Path, home: Option<&Path>) -> Vec<(PathBuf, PathBuf)> {
    let mut found = Vec::new();
    let mut seen = HashSet::from([normal(file)]);
    collect(file, home, 1, &mut seen, &mut found);
    found
}

fn collect(
    file: &Path,
    home: Option<&Path>,
    depth: usize,
    seen: &mut HashSet<PathBuf>,
    found: &mut Vec<(PathBuf, PathBuf)>,
) {
    let Ok(text) = fs::read_to_string(file) else {
        return;
    };
    let folder = file.parent().unwrap_or(Path::new("/"));
    for target in targets(&text, folder, home, true) {
        let path = normal(&target.path);
        if target.kind != Kind::Import
            || depth > MAX_DEPTH
            || !path.is_file()
            || !seen.insert(path.clone())
        {
            continue;
        }
        found.push((path.clone(), file.to_path_buf()));
        collect(&path, home, depth + 1, seen, found);
    }
}

/// The broken links and imports of every markdown file under `dir`, skipping hidden folders other than `.claude`,
/// `.cursor` and `.github`, and `node_modules` and `target`. Symlinked folders aren't followed.
pub fn check_dir(dir: &Path, home: Option<&Path>) -> Vec<Broken> {
    let mut found = Vec::new();
    let mut folders = vec![dir.to_path_buf()];
    let mut files = 0;
    while let Some(folder) = folders.pop() {
        let Ok(entries) = fs::read_dir(&folder) else {
            continue;
        };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if kind.is_dir() {
                let hidden =
                    name.starts_with('.') && ![".claude", ".cursor", ".github"].contains(&&*name);
                if !hidden && name != "node_modules" && name != "target" {
                    folders.push(entry.path());
                }
            } else if kind.is_file()
                && [".md", ".mdc", ".markdown"]
                    .iter()
                    .any(|ext| name.ends_with(ext))
            {
                files += 1;
                if files > MAX_FILES {
                    return found;
                }
                if let Ok(text) = fs::read_to_string(entry.path()) {
                    found.extend(broken(&entry.path(), &text, home));
                }
            }
        }
    }
    found
}

/// The 1-based line of byte `offset` in `text`.
pub fn line_of(text: &str, offset: usize) -> usize {
    text.as_bytes()[..offset.min(text.len())]
        .iter()
        .filter(|&&b| b == b'\n')
        .count()
        + 1
}
