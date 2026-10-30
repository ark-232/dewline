//! The decisions log: every Keep or Revert of an agent's change, one JSON
//! line each, appended to `decisions.jsonl` in the store folder. `dewline
//! changes` and the MCP `decisions` tool read it back, so an agent sees what
//! was kept and reverted before its next edit.

use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const FILE: &str = "decisions.jsonl";

/// The app's store folder.
pub fn standard_root() -> Option<PathBuf> {
    env::home_dir()
        .map(|home| home.join("Library/Application Support/dev.arkwerx.dewline/snapshots"))
}

/// One decision on an agent's change. `excerpt` is the change's text,
/// logged only as its hash.
pub struct Decision<'a> {
    pub vendor: &'a str,
    pub session: &'a str,
    pub file: &'a Path,
    pub time: SystemTime,
    pub kept: bool,
    pub excerpt: &'a str,
}

/// Appends the decision as one line, in a single write.
pub fn append(root: &Path, decision: &Decision) -> io::Result<()> {
    let mut line = json!({
        "vendor": decision.vendor,
        "session": decision.session,
        "file": decision.file.to_string_lossy(),
        "time": rfc3339(decision.time),
        "decision": if decision.kept { "kept" } else { "reverted" },
        "excerpt_hash": blake3::hash(decision.excerpt.as_bytes()).to_hex().as_str(),
    })
    .to_string();
    line.push('\n');
    OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(root.join(FILE))?
        .write_all(line.as_bytes())
}

/// The log's decisions, oldest first: those of `session` when given, and
/// those at or after `since`, a UTC time in RFC 3339 or a prefix of one
/// ("2026-10-30", "2026-10-30T10:00"). A line that doesn't parse is skipped.
pub fn read(root: &Path, session: Option<&str>, since: Option<&str>) -> io::Result<Vec<Value>> {
    let text = match fs::read_to_string(root.join(FILE)) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    Ok(text
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|record| session.is_none_or(|session| record["session"] == session))
        .filter(|record| {
            since.is_none_or(|since| record["time"].as_str().is_some_and(|time| time >= since))
        })
        .collect())
}

/// "2026-10-30T18:01:02Z".
fn rfc3339(time: SystemTime) -> String {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs()) as i64;
    let (days, rest) = (seconds.div_euclid(86_400), seconds.rem_euclid(86_400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}
