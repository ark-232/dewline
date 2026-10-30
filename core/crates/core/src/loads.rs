//! Which instruction files each agent loads in a folder, with a local token estimate against its documented limit,
//! and the agent-written memory and plans waiting for review.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::links;

/// The day the limits below were last checked against each agent's documentation.
pub const LIMITS_DATE: &str = "2026-10-26";
/// Claude Code warns when one memory file passes 40,000 characters.
const CLAUDE_TOKENS: u64 = 40_000 / 4;
/// Codex reads at most `project_doc_max_bytes`, 32 KiB, of AGENTS.md files.
const CODEX_TOKENS: u64 = 32_768 / 4;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Vendor {
    Claude,
    Codex,
    Cursor,
}

impl Vendor {
    pub fn title(self) -> &'static str {
        match self {
            Vendor::Claude => "Claude Code",
            Vendor::Codex => "Codex",
            Vendor::Cursor => "Cursor",
        }
    }
}

/// One file an agent loads in the folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Loaded {
    pub vendor: Vendor,
    pub path: PathBuf,
    /// How it gets loaded: the walk, `@import from <file>`, or a Cursor rule's `alwaysApply` and globs.
    pub how: String,
    /// Bytes / 4.
    pub tokens: u64,
    /// The vendor's documented limit, in the same estimate; None when it documents none.
    pub limit: Option<u64>,
}

/// What Claude Code, Codex and Cursor load for a session started in `folder`.
pub fn what_loads(folder: &Path, home: Option<&Path>) -> Vec<Loaded> {
    let mut found = Vec::new();
    let mut add = |vendor, path: PathBuf, how: String, limit| {
        if let Ok(info) = fs::metadata(&path)
            && info.is_file()
            && !found
                .iter()
                .any(|seen: &Loaded| seen.vendor == vendor && seen.path == path)
        {
            found.push(Loaded {
                vendor,
                path,
                how,
                tokens: info.len().div_ceil(4),
                limit,
            });
        }
    };

    // Claude Code: the user's file, then each folder from the root down to this one, then each one's imports.
    let ancestors: Vec<&Path> = folder.ancestors().collect();
    let mut claude: Vec<PathBuf> = home
        .map(|home| home.join(".claude/CLAUDE.md"))
        .into_iter()
        .collect();
    for dir in ancestors.iter().rev() {
        for name in ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"] {
            claude.push(dir.join(name));
        }
    }
    for path in claude.into_iter().filter(|path| path.is_file()) {
        add(
            Vendor::Claude,
            path.clone(),
            "walk".into(),
            Some(CLAUDE_TOKENS),
        );
        for (import, from) in links::imported(&path, home) {
            let name = from
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            add(
                Vendor::Claude,
                import,
                format!("@import from {name}"),
                Some(CLAUDE_TOKENS),
            );
        }
    }

    // Codex: the user's file, then each folder from the repository's root down, an override winning in its folder.
    let root = ancestors
        .iter()
        .find(|dir| dir.join(".git").exists())
        .copied()
        .unwrap_or(folder);
    let mut codex: Vec<PathBuf> = home.map(|home| home.join(".codex")).into_iter().collect();
    codex.extend(
        ancestors
            .iter()
            .filter(|dir| dir.starts_with(root))
            .rev()
            .map(|dir| dir.to_path_buf()),
    );
    for dir in codex {
        let file = ["AGENTS.override.md", "AGENTS.md"]
            .iter()
            .map(|name| dir.join(name))
            .find(|path| path.is_file());
        if let Some(file) = file {
            add(Vendor::Codex, file, "walk".into(), Some(CODEX_TOKENS));
        }
    }

    // Cursor: the rules in each `.cursor/rules` from the repository's root down.
    for dir in ancestors.iter().filter(|dir| dir.starts_with(root)).rev() {
        let Ok(entries) = fs::read_dir(dir.join(".cursor/rules")) else {
            continue;
        };
        let mut rules: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "mdc"))
            .collect();
        rules.sort();
        for rule in rules {
            let how = fs::read_to_string(&rule)
                .map(|text| rule_trigger(&text))
                .unwrap_or_default();
            add(Vendor::Cursor, rule, how, None);
        }
    }
    found
}

/// A Cursor rule's trigger from its frontmatter: always, its globs, the agent's choice by description, or manual.
fn rule_trigger(text: &str) -> String {
    let Some(front) = text
        .strip_prefix("---\n")
        .and_then(|rest| rest.split("\n---").next())
    else {
        return "manual".into();
    };
    let field = |name: &str| {
        front
            .lines()
            .find_map(|line| line.strip_prefix(name)?.strip_prefix(':'))
            .map(str::trim)
            .filter(|value| !value.is_empty())
    };
    if field("alwaysApply") == Some("true") {
        return "always".into();
    }
    if let Some(globs) = field("globs") {
        let globs: Vec<&str> = globs
            .trim_matches(['[', ']'])
            .split(',')
            .map(|glob| glob.trim().trim_matches(['"', '\'']))
            .filter(|glob| !glob.is_empty())
            .collect();
        return format!("globs {}", globs.join(", "));
    }
    if field("description").is_some() {
        return "when the agent picks it".into();
    }
    "manual".into()
}

/// Agent-written memory and plans: `~/.claude/projects/*/memory/*.md`, `~/.claude/plans/*.md`, and the folder's
/// `.claude/**/*.md` and `docs/plans/*.md`, each with when it last changed, newest first.
pub fn review_files(home: Option<&Path>, folder: Option<&Path>) -> Vec<(PathBuf, SystemTime)> {
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(home) = home {
        if let Ok(projects) = fs::read_dir(home.join(".claude/projects")) {
            dirs.extend(
                projects
                    .flatten()
                    .map(|project| project.path().join("memory")),
            );
        }
        dirs.push(home.join(".claude/plans"));
    }
    if let Some(folder) = folder {
        dirs.push(folder.join("docs/plans"));
        let mut under = vec![(folder.join(".claude"), 0)];
        while let Some((dir, depth)) = under.pop() {
            dirs.push(dir.clone());
            if depth < 3 {
                under.extend(
                    fs::read_dir(&dir)
                        .into_iter()
                        .flatten()
                        .flatten()
                        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
                        .map(|entry| (entry.path(), depth + 1)),
                );
            }
        }
    }
    let mut found: Vec<(PathBuf, SystemTime)> = dirs
        .iter()
        .flat_map(|dir| fs::read_dir(dir).into_iter().flatten().flatten())
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "md"))
        .filter_map(|entry| {
            let info = entry.metadata().ok()?;
            Some((entry.path(), info.is_file().then(|| info.modified().ok())??))
        })
        .collect();
    found.sort();
    found.dedup_by(|a, b| a.0 == b.0);
    found.sort_by_key(|&(_, modified)| std::cmp::Reverse(modified));
    found
}
