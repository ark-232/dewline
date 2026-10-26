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
            .map(|pattern| {
                let parts: Vec<String> = pattern.as_str()?.split('/').map(str::to_owned).collect();
                let valid = |part: &String| {
                    part == "**" || (!part.is_empty() && part.matches('*').count() <= 1)
                };
                parts.iter().all(valid).then_some(parts)
            })
            .collect::<Option<_>>()?;
        Some(AgentFiles { date, patterns })
    }

    /// Whether an agent loads the file at `path`, judged by its name and the
    /// folders above it.
    pub fn matches(&self, path: &Path) -> bool {
        let names: Option<Vec<&str>> = path
            .components()
            .filter_map(|component| match component {
                Component::Normal(name) => Some(name.to_str()),
                _ => None,
            })
            .collect();
        names.is_some_and(|names| {
            self.patterns
                .iter()
                .any(|pattern| (0..names.len()).any(|start| glob(pattern, &names[start..])))
        })
    }
}

fn glob(pattern: &[String], names: &[&str]) -> bool {
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

fn name_matches(part: &str, name: &str) -> bool {
    let (part, name) = (part.as_bytes(), name.as_bytes());
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
    }
}
