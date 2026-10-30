use std::path::Path;

use dewline_core::agents::AgentFiles;

/// What an agent's documentation says it loads of a file: the first `lines`
/// lines, or the first `bytes` bytes.
#[derive(uniffi::Record)]
pub struct AgentLimit {
    pub agent: String,
    pub lines: Option<u64>,
    pub bytes: Option<u64>,
}

/// Whether an agent loads the file at `path` as instructions, rules, skills,
/// plans or memory.
#[uniffi::export]
pub fn is_agent_file(path: String) -> bool {
    AgentFiles::builtin().matches(Path::new(&path))
}

/// The load limit the agent that reads `path` documents, if any.
#[uniffi::export]
pub fn agent_file_limit(path: String) -> Option<AgentLimit> {
    AgentFiles::builtin()
        .limit(Path::new(&path))
        .map(|limit| AgentLimit {
            agent: limit.agent.clone(),
            lines: limit.lines,
            bytes: limit.bytes,
        })
}

/// The day the agent-file list and its limits were last checked, YYYY-MM-DD.
#[uniffi::export]
pub fn agent_files_date() -> String {
    AgentFiles::builtin().date.clone()
}
