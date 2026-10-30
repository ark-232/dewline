//! `dewline doctor`: whether the app matches this command, whether the agent hooks of docs/hooks.md are installed,
//! and which companion tools are on PATH. `--install-hooks` merges the hooks in, asking first.

use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use dewline_core::file;
use serde_json::{Map, Value, json};

use crate::control::enclosing_app;

/// An agent whose hooks call `dewline notify --hook <name>`.
struct Agent {
    name: &'static str,
    title: &'static str,
    /// The settings file, relative to the home folder.
    settings: &'static str,
    /// Each hook event, with the tool matcher it takes.
    events: &'static [(&'static str, Option<&'static str>)],
}

const TOOLS: &str = "Read|Edit|MultiEdit|Write";

const AGENTS: [Agent; 2] = [
    Agent {
        name: "claude",
        title: "Claude Code",
        settings: ".claude/settings.json",
        events: &[
            ("PreToolUse", Some(TOOLS)),
            ("PostToolUse", Some(TOOLS)),
            ("Stop", None),
            ("StopFailure", None),
            ("UserPromptSubmit", None),
            ("SessionEnd", None),
            ("InstructionsLoaded", None),
        ],
    },
    Agent {
        name: "codex",
        title: "Codex",
        settings: ".codex/hooks.json",
        events: &[
            ("PreToolUse", Some("^apply_patch$")),
            ("PostToolUse", Some("^apply_patch$")),
        ],
    },
];

/// Each companion's command and its Homebrew formula.
const COMPANIONS: [(&str, &str); 4] = [
    ("pandoc", "pandoc"),
    ("typst", "typst"),
    ("vale", "vale"),
    ("harper-ls", "harper"),
];

pub fn run(install: bool) -> Result<(), String> {
    let home = env::home_dir().ok_or("there is no home folder")?;
    // SAFETY: isatty only inspects the descriptor.
    if install && unsafe { libc::isatty(0) } != 1 {
        return Err("--install-hooks asks before it changes a file, so it needs a terminal".into());
    }
    let exe = env::current_exe()
        .and_then(fs::canonicalize)
        .map_err(|error| format!("this command's path: {error}"))?;

    let app = enclosing_app(&exe).map_or_else(
        || PathBuf::from("/Applications/Dewline.app"),
        Path::to_path_buf,
    );
    let cli = env!("CARGO_PKG_VERSION");
    match app_version(&app) {
        Some(version) if version == cli => println!("Version: app and command are both {cli}"),
        Some(version) => println!(
            "Version: the app at {} is {version} but this command is {cli}; use the command inside the app",
            app.display()
        ),
        None => println!(
            "Version: this command is {cli}; no app at {}",
            app.display()
        ),
    }

    let command = format!("{} notify --hook", quoted(&exe));
    println!("\nAgent hooks:");
    for agent in &AGENTS {
        let path = home.join(agent.settings);
        let settings = match read(&path) {
            Ok(settings) => settings,
            Err(error) => {
                println!("  {}: {error}", agent.title);
                continue;
            }
        };
        let missing = missing(settings.as_ref().map(|(value, _)| value), agent);
        if missing.is_empty() {
            println!("  {}: installed in {}", agent.title, path.display());
        } else {
            println!(
                "  {}: {} missing from {}",
                agent.title,
                missing.join(", "),
                path.display()
            );
            if install {
                install_hooks(agent, &path, settings, &format!("{command} {}", agent.name))?;
            }
        }
    }
    if !install {
        println!("  `dewline doctor --install-hooks` merges the missing ones in, asking first.");
    }

    println!("\nCompanions:");
    for (program, formula) in COMPANIONS {
        match on_path(program) {
            Some(path) => println!("  {program}: {}", path.display()),
            None => println!("  {program}: not installed; brew install {formula}"),
        }
    }
    Ok(())
}

fn app_version(app: &Path) -> Option<String> {
    let output = Command::new("/usr/bin/plutil")
        .args(["-extract", "CFBundleShortVersionString", "raw", "-o", "-"])
        .arg(app.join("Contents/Info.plist"))
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// A settings file's JSON and bytes, or `None` when there is no file.
fn read(path: &Path) -> Result<Option<(Value, Vec<u8>)>, String> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(|value| Some((value, bytes)))
            .map_err(|error| format!("{} isn't JSON this can read: {error}", path.display())),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("{}: {error}", path.display())),
    }
}

/// The events of `agent` with no hook calling `dewline notify --hook <name>`.
fn missing(settings: Option<&Value>, agent: &Agent) -> Vec<&'static str> {
    let suffix = format!(" notify --hook {}", agent.name);
    let installed = |event: &str| {
        settings
            .and_then(|settings| settings.pointer(&format!("/hooks/{event}")))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|group| group.get("hooks")?.as_array())
            .flatten()
            .filter_map(|hook| hook.get("command")?.as_str())
            .any(|command| command.contains("dewline") && command.trim_end().ends_with(&suffix))
    };
    agent
        .events
        .iter()
        .map(|&(event, _)| event)
        .filter(|event| !installed(event))
        .collect()
}

/// `settings` with a hook running `command` added to each of `agent`'s events that lacks one; every other key and
/// hook kept as it was.
fn merge(settings: Option<&Value>, agent: &Agent, command: &str) -> Result<Value, String> {
    let missing = missing(settings, agent);
    let mut settings = settings.cloned().unwrap_or_else(|| json!({}));
    let root = settings
        .as_object_mut()
        .ok_or("the settings aren't a JSON object")?;
    let hooks = root
        .entry("hooks")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("its \"hooks\" isn't a JSON object")?;
    for &(event, matcher) in agent.events {
        if !missing.contains(&event) {
            continue;
        }
        let mut group = Map::new();
        if let Some(matcher) = matcher {
            group.insert("matcher".into(), json!(matcher));
        }
        group.insert(
            "hooks".into(),
            json!([{"type": "command", "command": command}]),
        );
        hooks
            .entry(event)
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .ok_or_else(|| format!("its hooks for {event} aren't a JSON array"))?
            .push(Value::Object(group));
    }
    Ok(settings)
}

fn install_hooks(
    agent: &Agent,
    path: &Path,
    settings: Option<(Value, Vec<u8>)>,
    command: &str,
) -> Result<(), String> {
    let (current, bytes) = settings.unzip();
    let merged = merge(current.as_ref(), agent, command)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    let added: Vec<_> = missing(current.as_ref(), agent)
        .into_iter()
        .map(|event| json!({ (event): merged["hooks"][event].as_array().and_then(|groups| groups.last()) }))
        .collect();
    println!("\n  This adds to {}:", path.display());
    for entry in &added {
        println!("    {entry}");
    }
    eprint!("  Merge them in? [y/N] ");
    let mut answer = String::new();
    io::stdin()
        .read_line(&mut answer)
        .map_err(|error| format!("stdin: {error}"))?;
    if !matches!(answer.trim(), "y" | "Y" | "yes") {
        println!("  Left {} as it was.", path.display());
        return Ok(());
    }
    let text = serde_json::to_string_pretty(&merged).expect("a JSON value serializes") + "\n";
    write(path, bytes.as_deref(), text.as_bytes())
        .map_err(|error| format!("{}: {error}", path.display()))?;
    println!("  Merged into {}.", path.display());
    if agent.name == "codex" {
        println!(
            "  Codex runs a new hook once you trust it: start Codex, open /hooks, select each Dewline hook and press t."
        );
    }
    Ok(())
}

/// Writes `new` over a file that held `old`, after copying it to a dated backup beside it, or makes the file when
/// `old` is `None`. A file that changed since it was read is left alone.
fn write(path: &Path, old: Option<&[u8]>, new: &[u8]) -> io::Result<()> {
    let Some(old) = old else {
        if let Some(folder) = path.parent() {
            fs::create_dir_all(folder)?;
        }
        return OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)?
            .write_all(new);
    };
    if fs::read(path)? != old {
        return Err(io::Error::other(
            "it changed after it was read; run this again",
        ));
    }
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs());
    let mut backup = path.as_os_str().to_owned();
    backup.push(format!(".dewline-backup-{seconds}"));
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&backup)?
        .write_all(old)?;
    println!("  Backed up to {}.", Path::new(&backup).display());
    file::save(path, &file::hash(old), new)
        .map(drop)
        .map_err(|error| io::Error::other(error.to_string()))
}

/// `path` as one shell word.
fn quoted(path: &Path) -> String {
    let text = path.to_string_lossy();
    if text
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"/-._+".contains(&byte))
    {
        text.into_owned()
    } else {
        format!("'{}'", text.replace('\'', r"'\''"))
    }
}

fn on_path(program: &str) -> Option<PathBuf> {
    env::split_paths(&env::var_os("PATH")?)
        .map(|folder| folder.join(program))
        .find(|path| fs::metadata(path).is_ok_and(|info| info.is_file()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMMAND: &str = "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude";

    #[test]
    fn merging_adds_every_event_once_and_keeps_the_rest() {
        let claude = &AGENTS[0];
        let settings = json!({
            "model": "opus",
            "permissions": {"allow": ["Bash(ls)"]},
            "hooks": {
                "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh"}]}],
                "Notification": [{"hooks": [{"type": "command", "command": "say hi"}]}],
            },
        });
        let once = merge(Some(&settings), claude, COMMAND).unwrap();
        assert!(missing(Some(&once), claude).is_empty());
        assert_eq!(merge(Some(&once), claude, COMMAND).unwrap(), once);
        assert_eq!(once["model"], "opus");
        assert_eq!(once["permissions"], settings["permissions"]);
        assert_eq!(
            once["hooks"]["Notification"],
            settings["hooks"]["Notification"]
        );
        assert_eq!(
            once["hooks"]["PreToolUse"][0],
            settings["hooks"]["PreToolUse"][0]
        );
        assert_eq!(
            once["hooks"]["PreToolUse"][1],
            json!({"matcher": TOOLS, "hooks": [{"type": "command", "command": COMMAND}]})
        );
        assert_eq!(
            once["hooks"]["Stop"],
            json!([{"hooks": [{"type": "command", "command": COMMAND}]}])
        );
        let keys: Vec<_> = once.as_object().unwrap().keys().collect();
        assert_eq!(keys, ["model", "permissions", "hooks"]);
        let events: Vec<_> = once["hooks"].as_object().unwrap().keys().collect();
        assert_eq!(events[..2], ["PreToolUse", "Notification"]);
    }

    #[test]
    fn hooks_installed_by_hand_count() {
        let codex = &AGENTS[1];
        let by_hand = json!({"hooks": {
            "PreToolUse": [{"matcher": "^apply_patch$", "hooks": [{"type": "command", "command": "/opt/dewline notify --hook codex"}]}],
        }});
        assert_eq!(missing(Some(&by_hand), codex), ["PostToolUse"]);
        assert_eq!(missing(None, codex), ["PreToolUse", "PostToolUse"]);
        let merged = merge(Some(&by_hand), codex, "dewline notify --hook codex").unwrap();
        assert_eq!(merged["hooks"]["PreToolUse"].as_array().unwrap().len(), 1);
        assert!(missing(Some(&merged), codex).is_empty());
    }

    #[test]
    fn settings_of_another_shape_are_refused() {
        let claude = &AGENTS[0];
        assert!(merge(Some(&json!([])), claude, COMMAND).is_err());
        assert!(merge(Some(&json!({"hooks": []})), claude, COMMAND).is_err());
        assert!(merge(Some(&json!({"hooks": {"Stop": {}}})), claude, COMMAND).is_err());
    }

    #[test]
    fn a_write_backs_up_first_and_never_clobbers_a_newer_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        fs::write(&path, "{\"a\": 1}").unwrap();
        write(&path, Some(b"{\"a\": 1}"), b"{\"a\": 2}").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"{\"a\": 2}");
        let backups: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .filter(|name| name.starts_with("settings.json.dewline-backup-"))
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(
            fs::read(dir.path().join(&backups[0])).unwrap(),
            b"{\"a\": 1}"
        );
        let stale = dir.path().join("stale.json");
        fs::write(&stale, "{\"a\": 2}").unwrap();
        assert!(write(&stale, Some(b"{\"a\": 1}"), b"{\"a\": 3}").is_err());
        assert_eq!(fs::read(&stale).unwrap(), b"{\"a\": 2}");
        let fresh = dir.path().join("new/hooks.json");
        write(&fresh, None, b"{}").unwrap();
        assert_eq!(fs::read(&fresh).unwrap(), b"{}");
    }

    #[test]
    fn a_path_is_one_shell_word() {
        assert_eq!(
            quoted(Path::new("/Applications/Dewline.app/x")),
            "/Applications/Dewline.app/x"
        );
        assert_eq!(
            quoted(Path::new("/Users/me/it's here")),
            r"'/Users/me/it'\''s here'"
        );
    }
}
