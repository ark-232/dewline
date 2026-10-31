use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path};
use std::sync::OnceLock;

/// The files agents load as instructions, rules, skills, plans or memory, as
/// of `date`. A pattern is `/`-separated and matches the end of a path: `*`
/// stands for part of one name, `**` for any number of folders. Names match
/// regardless of ASCII case, as on macOS's default volumes.
pub struct AgentFiles {
    /// The day the list was last checked against the agents' documentation.
    pub date: String,
    patterns: Vec<Vec<String>>,
    limits: Vec<(Vec<String>, Limit)>,
}

/// What an agent's documentation says it loads of a file, as of the list's
/// date: the first `lines` lines, or the first `bytes` bytes, and a warning
/// past `warn_chars` characters.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Limit {
    pub agent: String,
    pub lines: Option<u64>,
    pub bytes: Option<u64>,
    pub warn_chars: Option<u64>,
}

impl AgentFiles {
    /// The list in agents.json.
    pub fn builtin() -> &'static AgentFiles {
        static BUILTIN: OnceLock<AgentFiles> = OnceLock::new();
        BUILTIN.get_or_init(|| {
            AgentFiles::parse(include_str!("agents.json")).expect("agents.json is a valid list")
        })
    }

    fn parse(json: &str) -> Option<AgentFiles> {
        let list: serde_json::Value = serde_json::from_str(json).ok()?;
        let date = list.get("date")?.as_str()?.to_owned();
        let patterns = list
            .get("patterns")?
            .as_array()?
            .iter()
            .map(|pattern| split(pattern.as_str()?))
            .collect::<Option<_>>()?;
        let limits = match list.get("limits") {
            None => Vec::new(),
            Some(limits) => limits
                .as_array()?
                .iter()
                .map(|limit| {
                    let number = |key| match limit.get(key) {
                        None => Some(None),
                        Some(value) => value.as_u64().filter(|&n| n > 0).map(Some),
                    };
                    let limit_for = Limit {
                        agent: limit.get("agent")?.as_str()?.to_owned(),
                        lines: number("lines")?,
                        bytes: number("bytes")?,
                        warn_chars: number("warn_chars")?,
                    };
                    let counted = limit_for.lines.is_some()
                        || limit_for.bytes.is_some()
                        || limit_for.warn_chars.is_some();
                    counted.then_some((split(limit.get("pattern")?.as_str()?)?, limit_for))
                })
                .collect::<Option<_>>()?,
        };
        Some(AgentFiles {
            date,
            patterns,
            limits,
        })
    }

    /// Whether an agent loads the file at `path`, judged by its name and the
    /// folders above it.
    pub fn matches(&self, path: &Path) -> bool {
        let names = names(path);
        self.patterns
            .iter()
            .any(|pattern| ends_with(pattern, &names))
    }

    /// The first limit in the list whose pattern matches `path`.
    pub fn limit(&self, path: &Path) -> Option<&Limit> {
        let names = names(path);
        self.limits
            .iter()
            .find(|(pattern, _)| ends_with(pattern, &names))
            .map(|(_, limit)| limit)
    }
}

fn split(pattern: &str) -> Option<Vec<String>> {
    let parts: Vec<String> = pattern.split('/').map(str::to_owned).collect();
    let valid =
        |part: &String| part == "**" || (!part.is_empty() && part.matches('*').count() <= 1);
    parts.iter().all(valid).then_some(parts)
}

fn names(path: &Path) -> Vec<&[u8]> {
    path.components()
        .filter_map(|component| match component {
            Component::Normal(name) => Some(name.as_bytes()),
            _ => None,
        })
        .collect()
}

fn ends_with(pattern: &[String], names: &[&[u8]]) -> bool {
    (0..names.len()).any(|start| glob(pattern, &names[start..]))
}

fn glob(pattern: &[String], names: &[&[u8]]) -> bool {
    match pattern.split_first() {
        None => names.is_empty(),
        Some((part, rest)) if part == "**" => {
            (0..=names.len()).any(|skip| glob(rest, &names[skip..]))
        }
        Some((part, rest)) => names
            .split_first()
            .is_some_and(|(name, names)| name_matches(part, name) && glob(rest, names)),
    }
}

fn name_matches(part: &str, name: &[u8]) -> bool {
    let part = part.as_bytes();
    match part.iter().position(|&byte| byte == b'*') {
        None => part.eq_ignore_ascii_case(name),
        Some(star) => {
            let (head, tail) = (&part[..star], &part[star + 1..]);
            name.len() >= head.len() + tail.len()
                && name[..head.len()].eq_ignore_ascii_case(head)
                && name[name.len() - tail.len()..].eq_ignore_ascii_case(tail)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_list_is_dated() {
        let date = &AgentFiles::builtin().date;
        let parts: Vec<&str> = date.split('-').collect();
        let lengths: Vec<usize> = parts.iter().map(|part| part.len()).collect();
        assert_eq!(lengths, [4, 2, 2], "{date}");
        assert!(
            parts
                .iter()
                .all(|part| part.bytes().all(|byte| byte.is_ascii_digit()))
        );
    }

    #[test]
    fn a_list_with_a_bad_pattern_or_no_date_is_refused() {
        let parse = |json: &str| AgentFiles::parse(json).is_some();
        assert!(parse(
            r#"{"date": "2026-10-26", "patterns": ["a/**/*.md"]}"#
        ));
        assert!(!parse(r#"{"patterns": ["CLAUDE.md"]}"#));
        assert!(!parse(
            r#"{"date": "2026-10-26", "patterns": ["a/*x*.md"]}"#
        ));
        assert!(!parse(r#"{"date": "2026-10-26", "patterns": ["a//b.md"]}"#));
        assert!(!parse(r#"{"date": "2026-10-26", "patterns": [7]}"#));
        assert!(parse(
            r#"{"date": "2026-10-26", "patterns": [], "limits": [{"pattern": "A.md", "agent": "A", "lines": 9}]}"#
        ));
        assert!(!parse(
            r#"{"date": "2026-10-26", "patterns": [], "limits": [{"pattern": "A.md", "agent": "A"}]}"#
        ));
        assert!(!parse(
            r#"{"date": "2026-10-26", "patterns": [], "limits": [{"pattern": "A.md", "agent": "A", "bytes": 0}]}"#
        ));
        assert!(!parse(
            r#"{"date": "2026-10-26", "patterns": [], "limits": [{"pattern": "A.md", "lines": 9}]}"#
        ));
    }

    #[test]
    fn limits_follow_the_vendor_that_loads_the_file() {
        let files = AgentFiles::builtin();
        let limit = |path: &str| {
            files
                .limit(Path::new(path))
                .map(|limit| (limit.agent.as_str(), limit.lines, limit.bytes))
        };
        assert_eq!(
            limit("/Users/someone/.claude/projects/-Users-someone-repo/memory/MEMORY.md"),
            Some(("Claude Code", Some(200), Some(25000)))
        );
        assert_eq!(
            limit("/Users/someone/repo/.claude/agent-memory/reviewer/MEMORY.md"),
            Some(("Claude Code", Some(200), Some(25000)))
        );
        assert_eq!(
            limit("/Users/someone/repo/claude.md"),
            Some(("Claude Code", Some(200), None))
        );
        assert_eq!(
            files
                .limit(Path::new("/Users/someone/repo/CLAUDE.md"))
                .and_then(|limit| limit.warn_chars),
            Some(40_000)
        );
        assert_eq!(
            limit("/Users/someone/repo/AGENTS.md"),
            Some(("Codex", None, Some(32768)))
        );
        assert_eq!(
            limit("/Users/someone/repo/.cursor/rules/style.mdc"),
            Some(("Cursor", Some(500), None))
        );
        assert_eq!(limit("/Users/someone/.claude/skills/pdf/SKILL.md"), None);
        assert_eq!(limit("/Users/someone/repo/README.md"), None);
        for (pattern, _) in &files.limits {
            let path = pattern.join("/").replace("**/", "").replace('*', "x");
            assert!(
                files.matches(Path::new(&path)),
                "{path} has a limit but is no agent file"
            );
        }
    }

    #[test]
    fn recognizes_agent_files() {
        #[rustfmt::skip]
        let table: &[(&str, bool)] = &[
            ("/Users/someone/repo/CLAUDE.md", true),
            ("/Users/someone/repo/claude.md", true),
            ("/Users/someone/repo/.claude/CLAUDE.md", true),
            ("/Users/someone/repo/CLAUDE.local.md", true),
            ("/Users/someone/.claude/CLAUDE.md", true),
            ("/Library/Application Support/ClaudeCode/CLAUDE.md", true),
            ("/Users/someone/repo/packages/web/AGENTS.md", true),
            ("/Users/someone/repo/AGENTS.override.md", true),
            ("/Users/someone/repo/AGENT.md", true),
            ("/Users/someone/repo/GEMINI.md", true),
            ("/Users/someone/repo/WARP.md", true),
            ("/Users/someone/repo/CRUSH.md", true),
            ("/Users/someone/repo/CONVENTIONS.md", true),
            ("/Users/someone/repo/.goosehints", true),
            ("/Users/someone/repo/.cursorrules", true),
            ("/Users/someone/repo/.windsurfrules", true),
            ("/Users/someone/repo/.rules", true),
            ("/Users/someone/repo/.claude/rules/testing.md", true),
            ("/Users/someone/repo/.claude/rules/frontend/react.md", true),
            ("/Users/someone/.claude/skills/pdf/SKILL.md", true),
            ("/Users/someone/.claude/skills/pdf/reference/forms.md", true),
            ("/Users/someone/repo/.claude/commands/deploy.md", true),
            ("/Users/someone/repo/.claude/agents/reviewer.md", true),
            ("/Users/someone/repo/.claude/agent-memory/reviewer/MEMORY.md", true),
            ("/Users/someone/repo/.claude/output-styles/terse.md", true),
            ("/Users/someone/.claude/projects/-Users-someone-repo/memory/MEMORY.md", true),
            ("/Users/someone/.claude/projects/-Users-someone-repo/memory/feedback_style.md", true),
            ("/Users/someone/.claude/plans/fuzzy-melody.md", true),
            ("/Users/someone/.codex/AGENTS.md", true),
            ("/Users/someone/.codex/prompts/review.md", true),
            ("/Users/someone/.agents/skills/lint/SKILL.md", true),
            ("/Users/someone/repo/tools/SKILL.md", true),
            ("/Users/someone/repo/.cursor/rules/style.mdc", true),
            ("/Users/someone/repo/.cursor/rules/nested/style.md", true),
            ("/Users/someone/repo/.github/copilot-instructions.md", true),
            ("/Users/someone/repo/.github/instructions/rust.instructions.md", true),
            ("/Users/someone/repo/.specify/memory/constitution.md", true),
            ("/Users/someone/repo/.ruler/instructions.md", true),
            ("/Users/someone/repo/.kiro/steering/product.md", true),
            ("/Users/someone/repo/README.md", false),
            ("/Users/someone/repo/docs/CLAUDE.md.bak", false),
            ("/Users/someone/repo/MY-CLAUDE.md", false),
            ("/Users/someone/repo/.claude/settings.local.json", false),
            ("/Users/someone/repo/.claude/notes.md", false),
            ("/Users/someone/.claude/skills/pdf/scripts/fill.py", false),
            ("/Users/someone/.claude/projects/-Users-someone-repo/0b6c5a7e.jsonl", false),
            ("/Users/someone/.claude/projects/-Users-someone-repo/notes.md", false),
            ("/Users/someone/.claude/file-history/abc/CLAUDE.md@v2", false),
            ("/Users/someone/.codex/config.toml", false),
            ("/Users/someone/.codex/sessions/2026/rollout.jsonl", false),
            ("/Users/someone/repo/.cursor/rules.mdc", false),
            ("/Users/someone/repo/.github/instructions/readme.md", false),
            ("/Users/someone/repo/.github/workflows/ci.yml", false),
            ("/Users/someone/repo/rules", false),
            ("/", false),
        ];
        let files = AgentFiles::builtin();
        for &(path, expected) in table {
            assert_eq!(files.matches(Path::new(path)), expected, "{path}");
        }
        let unnamed = std::ffi::OsStr::from_bytes(b"/Volumes/share/\xff\xfe/CLAUDE.md");
        assert!(
            files.matches(Path::new(unnamed)),
            "a name that isn't UTF-8 above it"
        );
    }
}
