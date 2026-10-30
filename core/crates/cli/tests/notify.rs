//! `dewline notify` run as the hooks run it, with each event's JSON on stdin, against a socket server in this
//! process that stands in for the app. `DEWLINE_SOCKET` points the command at it. hook-events.json holds one
//! payload of each shape Claude Code and Codex send, built from their hook docs.

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::symlink;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use dewline_core::claims::{Claim, Fields};
use serde_json::{Value, json};

const DEWLINE: &str = env!("CARGO_BIN_EXE_dewline");
const PLAN: &str = "# Plan\n\nShip it.\n";

/// A folder holding plan.md and CLAUDE.md, with a socket path beside them.
struct Fixture {
    dir: tempfile::TempDir,
    socket: PathBuf,
}

impl Fixture {
    fn new() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("plan.md"), PLAN).unwrap();
        fs::write(dir.path().join("CLAUDE.md"), "# Rules\n").unwrap();
        fs::create_dir(dir.path().join("notes")).unwrap();
        let socket = dir.path().join("control.sock");
        Fixture { dir, socket }
    }

    fn real(&self, name: &str) -> String {
        let real = fs::canonicalize(self.dir.path()).unwrap().join(name);
        real.into_os_string().into_string().unwrap()
    }

    /// The fixture called `name`, with its folder filled in.
    fn event(&self, name: &str) -> Value {
        let events: Value = serde_json::from_str(include_str!("hook-events.json")).unwrap();
        let text = events[name].to_string();
        assert_ne!(text, "null", "{name}");
        let dir = self.dir.path().to_str().unwrap();
        serde_json::from_str(&text.replace("@DIR@", dir)).unwrap()
    }

    /// Runs `dewline notify --hook vendor` with `stdin`, checks it exits 0 with nothing on stdout, and returns the
    /// lines a listening stand-in for the app heard.
    fn notify(&self, vendor: &str, stdin: &[u8]) -> Vec<Value> {
        let _ = fs::remove_file(&self.socket);
        let listener = UnixListener::bind(&self.socket).unwrap();
        let (sender, heard) = mpsc::channel();
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let mut line = String::new();
                let _ = BufReader::new(&stream).read_line(&mut line);
                if sender.send(line).is_err() {
                    return;
                }
            }
        });
        let output = run(vendor, stdin, &self.socket);
        assert!(output.status.success(), "{output:?}");
        assert!(output.stdout.is_empty(), "{output:?}");
        // The run probes the socket once before it reads stdin, sending nothing.
        let lines = drain(&self.socket, &heard);
        assert_eq!(lines.first().map(String::as_str), Some(""));
        lines[1..]
            .iter()
            .map(|line| {
                assert!(
                    line.ends_with('\n') && line.matches('\n').count() == 1,
                    "{line:?}"
                );
                serde_json::from_str(line).unwrap()
            })
            .collect()
    }

    fn one(&self, vendor: &str, event: &Value) -> Option<Value> {
        let mut lines = self.notify(vendor, event.to_string().as_bytes());
        assert!(lines.len() <= 1, "{lines:?}");
        lines.pop()
    }
}

/// Every line the stand-in heard: the command sends without waiting for the app, so this sends a last line of
/// its own and reads until the stand-in, which takes connections in order, has heard it.
fn drain(socket: &Path, heard: &mpsc::Receiver<String>) -> Vec<String> {
    let mut last = std::os::unix::net::UnixStream::connect(socket).unwrap();
    last.write_all(b"end\n").unwrap();
    heard.iter().take_while(|line| line != "end\n").collect()
}

fn run(vendor: &str, stdin: &[u8], socket: &Path) -> std::process::Output {
    let mut child = Command::new(DEWLINE)
        .args(["notify", "--hook", vendor])
        .env_clear()
        .env("DEWLINE_SOCKET", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let stdin = stdin.to_vec();
    // The command may stop reading early, so a write that fails is fine.
    let writer = thread::spawn(move || {
        let _ = input.write_all(&stdin);
    });
    let output = child.wait_with_output().unwrap();
    writer.join().unwrap();
    output
}

fn hex(bytes: &str) -> String {
    blake3::hash(bytes.as_bytes()).to_hex().to_string()
}

/// Every line is one claims.rs takes.
fn parses(line: &Value) {
    let field = |name| line[name].as_str();
    let fields = Fields {
        event: field("event").unwrap(),
        vendor: field("vendor").unwrap(),
        session: field("session").unwrap(),
        tool_use_id: field("tool_use_id"),
        tool: field("tool"),
        path: field("path"),
        hash: field("hash"),
        declared: field("declared"),
    };
    assert!(Claim::parse(fields).is_ok(), "{line}");
    let keys = [
        "v",
        "op",
        "event",
        "vendor",
        "session",
        "tool_use_id",
        "tool",
        "path",
        "hash",
        "declared",
    ];
    assert!(
        line.as_object()
            .unwrap()
            .keys()
            .all(|key| keys.contains(&key.as_str())),
        "{line}"
    );
}

#[test]
fn each_event_shape_sends_what_claims_rs_parses() {
    let fixture = Fixture::new();
    let plan = fixture.real("plan.md");
    let claude_session = "0b6c5a7e-6a1b-4f0e-9c1d-2f8e1a3b4c5d";
    let codex_session = "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b";
    let tool = |event: &str, vendor: &str, session: &str, id: &str, tool: &str, path: &str| {
        json!({"v": 1, "op": "notify", "event": event, "vendor": vendor, "session": session,
               "tool_use_id": id, "tool": tool, "path": path})
    };
    let with = |mut line: Value, hash: Option<String>, declared: Option<String>| {
        if let Some(hash) = hash {
            line["hash"] = hash.into();
        }
        if let Some(declared) = declared {
            line["declared"] = declared.into();
        }
        line
    };
    let friday = "# Plan\n\nShip it on Friday.\n";
    let new = "# New\n\n“Quoted” 😀\n";
    let table: Vec<(&str, &str, Option<Value>)> = vec![
        (
            "claude",
            "claude PreToolUse Read",
            Some(with(
                tool(
                    "PreToolUse",
                    "claude",
                    claude_session,
                    "toolu_01Read",
                    "Read",
                    &plan,
                ),
                Some(hex(PLAN)),
                None,
            )),
        ),
        (
            "claude",
            "claude PostToolUse Read",
            Some(with(
                tool(
                    "PostToolUse",
                    "claude",
                    claude_session,
                    "toolu_01Read",
                    "Read",
                    &plan,
                ),
                Some(hex(PLAN)),
                None,
            )),
        ),
        (
            "claude",
            "claude PreToolUse Edit",
            Some(with(
                tool(
                    "PreToolUse",
                    "claude",
                    claude_session,
                    "toolu_01Edit",
                    "Edit",
                    &plan,
                ),
                Some(hex(PLAN)),
                Some(hex(friday)),
            )),
        ),
        (
            "claude",
            "claude PostToolUse Edit",
            Some(with(
                tool(
                    "PostToolUse",
                    "claude",
                    claude_session,
                    "toolu_01Edit",
                    "Edit",
                    &plan,
                ),
                Some(hex(PLAN)),
                None,
            )),
        ),
        (
            "claude",
            "claude PreToolUse MultiEdit",
            Some(with(
                tool(
                    "PreToolUse",
                    "claude",
                    claude_session,
                    "toolu_01Multi",
                    "MultiEdit",
                    &plan,
                ),
                Some(hex(PLAN)),
                Some(hex("# Launch plan\n\nShip it.\n\nThen rest.\n")),
            )),
        ),
        (
            "claude",
            "claude PostToolUse MultiEdit",
            Some(with(
                tool(
                    "PostToolUse",
                    "claude",
                    claude_session,
                    "toolu_01Multi",
                    "MultiEdit",
                    &plan,
                ),
                Some(hex(PLAN)),
                None,
            )),
        ),
        // The file isn't there yet: its folder's realpath and its name, no hash.
        (
            "claude",
            "claude PreToolUse Write",
            Some(with(
                tool(
                    "PreToolUse",
                    "claude",
                    claude_session,
                    "toolu_01Write",
                    "Write",
                    &fixture.real("notes/new.md"),
                ),
                None,
                Some(hex(new)),
            )),
        ),
        (
            "claude",
            "claude PostToolUse Write",
            Some(tool(
                "PostToolUse",
                "claude",
                claude_session,
                "toolu_01Write",
                "Write",
                &fixture.real("notes/new.md"),
            )),
        ),
        (
            "claude",
            "claude Stop",
            Some(
                json!({"v": 1, "op": "notify", "event": "Stop", "vendor": "claude", "session": claude_session}),
            ),
        ),
        (
            "claude",
            "claude StopFailure",
            Some(
                json!({"v": 1, "op": "notify", "event": "StopFailure", "vendor": "claude", "session": claude_session}),
            ),
        ),
        (
            "claude",
            "claude UserPromptSubmit",
            Some(
                json!({"v": 1, "op": "notify", "event": "UserPromptSubmit", "vendor": "claude", "session": claude_session}),
            ),
        ),
        (
            "claude",
            "claude SessionEnd",
            Some(
                json!({"v": 1, "op": "notify", "event": "SessionEnd", "vendor": "claude", "session": claude_session}),
            ),
        ),
        (
            "claude",
            "claude InstructionsLoaded",
            Some(
                json!({"v": 1, "op": "notify", "event": "InstructionsLoaded", "vendor": "claude",
            "session": claude_session, "path": fixture.real("CLAUDE.md")}),
            ),
        ),
        (
            "codex",
            "codex PreToolUse apply_patch",
            Some(with(
                tool(
                    "PreToolUse",
                    "codex",
                    codex_session,
                    "call_Patch1",
                    "apply_patch",
                    &plan,
                ),
                Some(hex(PLAN)),
                Some(hex(friday)),
            )),
        ),
        (
            "codex",
            "codex PostToolUse apply_patch",
            Some(with(
                tool(
                    "PostToolUse",
                    "codex",
                    codex_session,
                    "call_Patch1",
                    "apply_patch",
                    &plan,
                ),
                Some(hex(PLAN)),
                None,
            )),
        ),
        (
            "codex",
            "codex Stop",
            Some(
                json!({"v": 1, "op": "notify", "event": "Stop", "vendor": "codex", "session": codex_session}),
            ),
        ),
        (
            "codex",
            "codex UserPromptSubmit",
            Some(
                json!({"v": 1, "op": "notify", "event": "UserPromptSubmit", "vendor": "codex", "session": codex_session}),
            ),
        ),
        (
            "codex",
            "codex SessionEnd",
            Some(
                json!({"v": 1, "op": "notify", "event": "SessionEnd", "vendor": "codex", "session": codex_session}),
            ),
        ),
        // A hook run for the other vendor's events names nothing it can't parse.
        ("codex", "claude PreToolUse Edit", None),
        ("claude", "codex PreToolUse apply_patch", None),
    ];
    for (vendor, name, expected) in table {
        let line = fixture.one(vendor, &fixture.event(name));
        if let Some(line) = &line {
            parses(line);
        }
        assert_eq!(line, expected, "{name} as {vendor}");
    }
}

#[test]
fn bash_and_other_tools_name_nothing() {
    let fixture = Fixture::new();
    let mut event = fixture.event("claude PreToolUse Edit");
    for tool in ["Bash", "NotebookEdit", "Glob", "edit"] {
        event["tool_name"] = tool.into();
        assert_eq!(fixture.one("claude", &event), None, "{tool}");
    }
    let mut event = fixture.event("codex PreToolUse apply_patch");
    event["tool_name"] = "shell".into();
    event["tool_input"] = json!({"command": ["bash", "-lc", "echo hi > plan.md"]});
    assert_eq!(fixture.one("codex", &event), None);
    let notification =
        json!({"session_id": "s", "hook_event_name": "Notification", "message": "hi"});
    assert_eq!(fixture.one("claude", &notification), None);
}

/// The declared hash for an Edit, from `input`, of plan.md holding `text`.
fn edit_declares(fixture: &Fixture, text: &str, input: Value) -> Option<String> {
    fs::write(fixture.dir.path().join("plan.md"), text).unwrap();
    let mut event = fixture.event("claude PreToolUse Edit");
    let mut tool_input = json!({"file_path": fixture.real("plan.md")});
    tool_input
        .as_object_mut()
        .unwrap()
        .extend(input.as_object().unwrap().clone());
    event["tool_input"] = tool_input;
    let line = fixture.one("claude", &event).unwrap();
    assert_eq!(line["hash"], hex(text));
    line["declared"].as_str().map(str::to_owned)
}

#[test]
fn edit_declares_only_what_claude_code_would_write() {
    let fixture = Fixture::new();
    let edit = |text, input| edit_declares(&fixture, text, input);
    assert_eq!(
        edit("a b a\n", json!({"old_string": "b", "new_string": "c"})),
        Some(hex("a c a\n"))
    );
    // Found twice: refused without replace_all, every match with it.
    assert_eq!(
        edit("a b a\n", json!({"old_string": "a", "new_string": "c"})),
        None
    );
    assert_eq!(
        edit(
            "a b a\n",
            json!({"old_string": "a", "new_string": "c", "replace_all": true})
        ),
        Some(hex("c b c\n"))
    );
    assert_eq!(
        edit("a b a\n", json!({"old_string": "z", "new_string": "c"})),
        None
    );
    // Edit rewrites line endings, so a file with CRs declares nothing.
    assert_eq!(
        edit("a\r\nb\r\n", json!({"old_string": "b", "new_string": "c"})),
        None
    );
}

#[test]
fn multi_edit_declares_its_edits_applied_in_order() {
    let fixture = Fixture::new();
    let mut event = fixture.event("claude PreToolUse MultiEdit");
    event["tool_input"]["edits"] = json!([
        {"old_string": "Ship it.", "new_string": "Ship it soon."},
        {"old_string": "it soon", "new_string": "everything", "replace_all": true},
    ]);
    // The second edit's old_string comes from the first's new_string, which Claude Code refuses.
    assert!(
        fixture
            .one("claude", &event)
            .unwrap()
            .get("declared")
            .is_none()
    );
    event["tool_input"]["edits"] = json!([
        {"old_string": "Ship it.", "new_string": "Ship it soon."},
        {"old_string": "# Plan", "new_string": "# Soon"},
    ]);
    let line = fixture.one("claude", &event).unwrap();
    assert_eq!(line["declared"], hex("# Soon\n\nShip it soon.\n"));
}

#[test]
fn a_patch_claims_each_file_it_names() {
    let fixture = Fixture::new();
    let dir = fixture.dir.path();
    fs::write(dir.join("old.md"), "gone\n").unwrap();
    fs::write(
        dir.join("move.md"),
        "# Move\n\nkeep \u{201C}quotes\u{201D} \u{2014} here\n",
    )
    .unwrap();
    let patch = "*** Begin Patch\n\
        *** Add File: notes/added.md\n+# Added\n\
        *** Delete File: old.md\n\
        *** Update File: plan.md\n@@\n # Plan\n-\n-Ship it.\n+\n+Ship it today.\n\
        *** Update File: move.md\n*** Move to: notes/moved.md\n@@\n-keep \"quotes\" - here\n+kept\n\
        *** End Patch\n";
    let mut event = fixture.event("codex PreToolUse apply_patch");
    event["tool_input"]["command"] = patch.into();
    let lines = fixture.notify("codex", event.to_string().as_bytes());
    lines.iter().for_each(parses);
    let claims: Vec<(&str, Option<&str>, Option<&str>)> = lines
        .iter()
        .map(|line| {
            (
                line["path"].as_str().unwrap(),
                line["hash"].as_str(),
                line["declared"].as_str(),
            )
        })
        .collect();
    let (added, old, plan, moving, moved) = (
        fixture.real("notes/added.md"),
        fixture.real("old.md"),
        fixture.real("plan.md"),
        fixture.real("move.md"),
        fixture.real("notes/moved.md"),
    );
    let (gone, before) = (
        hex("gone\n"),
        hex("# Move\n\nkeep \u{201C}quotes\u{201D} \u{2014} here\n"),
    );
    let (added_after, plan_after, moved_after) = (
        hex("# Added\n"),
        hex("# Plan\n\nShip it today.\n"),
        hex("# Move\n\nkept\n"),
    );
    assert_eq!(
        claims,
        [
            (added.as_str(), None, Some(added_after.as_str())),
            (old.as_str(), Some(gone.as_str()), None),
            (
                plan.as_str(),
                Some(hex(PLAN).as_str()),
                Some(plan_after.as_str())
            ),
            (moving.as_str(), Some(before.as_str()), None),
            (moved.as_str(), None, Some(moved_after.as_str())),
        ]
    );
    // A chunk Codex can't place fails the whole patch, so no file declares anything.
    event["tool_input"]["command"] = patch.replace("-Ship it.", "-Ship nothing.").into();
    let lines = fixture.notify("codex", event.to_string().as_bytes());
    assert_eq!(lines.len(), 5);
    assert!(
        lines.iter().all(|line| line.get("declared").is_none()),
        "{lines:?}"
    );
}

/// Every file under `dir`, with its bytes, and every folder.
fn snapshot(dir: &Path) -> BTreeMap<PathBuf, Option<Vec<u8>>> {
    let mut found = BTreeMap::new();
    let mut folders = vec![dir.to_path_buf()];
    while let Some(folder) = folders.pop() {
        for entry in fs::read_dir(&folder).unwrap() {
            let path = entry.unwrap().path();
            let kind = fs::symlink_metadata(&path).unwrap().file_type();
            if kind.is_dir() {
                folders.push(path.clone());
                found.insert(path, None);
            } else if kind.is_file() {
                found.insert(path.clone(), Some(fs::read(&path).unwrap()));
            } else {
                found.insert(path, None);
            }
        }
    }
    found
}

#[test]
fn write_shaped_events_change_no_bytes() {
    let fixture = Fixture::new();
    let dir = fixture.dir.path();
    fs::write(dir.join("old.md"), "gone\n").unwrap();
    let patch = "*** Begin Patch\n*** Add File: added.md\n+new\n*** Delete File: old.md\n\
        *** Update File: plan.md\n*** Move to: moved.md\n@@\n-Ship it.\n+Shipped.\n*** End Patch";
    let mut events: Vec<(&str, Value)> = Vec::new();
    for name in ["PreToolUse", "PostToolUse"] {
        for tool in ["Edit", "MultiEdit", "Write"] {
            events.push(("claude", fixture.event(&format!("claude {name} {tool}"))));
        }
        let mut codex = fixture.event(&format!("codex {name} apply_patch"));
        codex["tool_input"]["command"] = patch.into();
        events.push(("codex", codex));
    }
    let before = snapshot(dir);
    for (vendor, event) in &events {
        assert!(
            !fixture
                .notify(vendor, event.to_string().as_bytes())
                .is_empty()
        );
    }
    let mut after = snapshot(dir);
    after.remove(&fixture.socket);
    let mut before = before;
    before.remove(&fixture.socket);
    assert_eq!(before, after);
}

#[test]
fn exits_at_once_when_the_app_isnt_running() {
    let fixture = Fixture::new();
    let mut event = fixture.event("claude PreToolUse Write");
    event["tool_input"]["content"] = "x".repeat(8 << 20).into();
    let stdin = event.to_string();
    // No socket, then a socket file nobody listens on, as a crashed app leaves.
    let stale = fixture.dir.path().join("stale.sock");
    drop(UnixListener::bind(&stale).unwrap());
    for socket in [fixture.socket.clone(), stale] {
        // The best of five runs, so a busy machine's scheduling doesn't decide it.
        let fastest = (0..5)
            .map(|_| {
                let start = Instant::now();
                let output = run("claude", stdin.as_bytes(), &socket);
                assert!(
                    output.status.success() && output.stdout.is_empty(),
                    "{output:?}"
                );
                start.elapsed()
            })
            .min()
            .unwrap();
        assert!(
            fastest < Duration::from_millis(60),
            "{fastest:?} with {socket:?}"
        );
    }
}

#[test]
fn a_fifo_is_refused_without_blocking() {
    let fixture = Fixture::new();
    let fifo = fixture.dir.path().join("pipe.md");
    assert!(
        Command::new("/usr/bin/mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success()
    );
    let mut event = fixture.event("claude PreToolUse Edit");
    event["tool_input"]["file_path"] = fifo.to_str().unwrap().into();
    let start = Instant::now();
    assert_eq!(fixture.one("claude", &event), None);
    assert!(start.elapsed() < Duration::from_secs(1));
}

#[test]
fn hostile_paths_and_ids_are_refused_or_resolved() {
    let fixture = Fixture::new();
    let dir = fixture.dir.path();
    let plan = fixture.real("plan.md");
    let edit = |path: &str| {
        let mut event = fixture.event("claude PreToolUse Edit");
        event["tool_input"]["file_path"] = path.into();
        fixture.one("claude", &event)
    };
    let path_of = |line: Option<Value>| line.map(|line| line["path"].as_str().unwrap().to_owned());
    // .. and symlinks resolve to the file's realpath.
    fs::create_dir(dir.join("sub")).unwrap();
    symlink(dir.join("plan.md"), dir.join("link.md")).unwrap();
    symlink(dir.join("missing.md"), dir.join("dangling.md")).unwrap();
    let dir = dir.to_str().unwrap();
    assert_eq!(
        path_of(edit(&format!("{dir}/sub/../plan.md"))),
        Some(plan.clone())
    );
    assert_eq!(path_of(edit(&format!("{dir}/link.md"))), Some(plan.clone()));
    assert_eq!(
        path_of(edit("plan.md")),
        Some(plan.clone()),
        "relative to cwd"
    );
    // A file in folders not made yet takes the nearest existing folder's realpath and the names below it.
    assert_eq!(
        path_of(edit(&format!("{dir}/nowhere/deeper/new.md"))),
        Some(fixture.real("nowhere/deeper/new.md"))
    );
    // A NUL, a dangling symlink, a folder, .. among folders not made yet, a path past 1024 bytes, or one past
    // the 4 KiB the reader keeps names nothing.
    let long = format!("{dir}/{}.md", "n".repeat(1100));
    for path in [
        format!("{dir}/plan.md\0.md"),
        format!("{dir}/dangling.md"),
        format!("{dir}/sub"),
        format!("{dir}/nowhere/../new.md"),
        format!("{dir}/sub/.."),
        long,
        format!("{dir}/{}plan.md", "./".repeat(2100)),
        "~/plan.md".to_owned(),
    ] {
        assert_eq!(edit(&path), None, "{path:?}");
    }
    // A newline in a name stays inside the JSON string: still one line.
    let odd = format!("{dir}/two\nlines.md");
    fs::write(&odd, PLAN).unwrap();
    let real = fs::canonicalize(&odd)
        .unwrap()
        .into_os_string()
        .into_string()
        .unwrap();
    assert_eq!(path_of(edit(&odd)), Some(real));
    // Ids claims.rs refuses name nothing.
    for (field, id) in [
        ("session_id", "new\nline".to_owned()),
        ("session_id", "nul\0".to_owned()),
        ("session_id", "s".repeat(129)),
        ("tool_use_id", "caf\u{e9}".to_owned()),
        ("tool_use_id", String::new()),
    ] {
        let mut event = fixture.event("claude PreToolUse Edit");
        event[field] = id.clone().into();
        assert_eq!(fixture.one("claude", &event), None, "{field} {id:?}");
    }
}

#[test]
fn nothing_reaches_a_shell() {
    let fixture = Fixture::new();
    let dir = fixture.dir.path().to_str().unwrap().to_owned();
    let marker = fixture.dir.path().join("pwned");
    let shell = format!(
        "$(touch {0}) `touch {0}`; touch {0} | touch {0}",
        marker.display()
    );
    let mut event = fixture.event("claude PreToolUse Write");
    event["session_id"] = shell.clone().into();
    event["tool_input"]["file_path"] = format!("{dir}/{shell}").into();
    event["tool_input"]["content"] = shell.clone().into();
    fixture.notify("claude", event.to_string().as_bytes());
    let mut event = fixture.event("codex PreToolUse apply_patch");
    event["tool_input"]["command"] =
        format!("*** Begin Patch\n*** Add File: {shell}\n+{shell}\n*** End Patch").into();
    fixture.notify("codex", event.to_string().as_bytes());
    assert!(!marker.exists());
}

#[test]
fn malformed_or_oversized_input_names_nothing() {
    let fixture = Fixture::new();
    let event = fixture.event("claude PreToolUse Edit").to_string();
    for stdin in [
        b"".to_vec(),
        b"not json".to_vec(),
        event.as_bytes()[..event.len() / 2].to_vec(),
        format!("{}{}", "[".repeat(100_000), "]".repeat(100_000)).into_bytes(),
    ] {
        assert!(fixture.notify("claude", &stdin).is_empty());
    }
    let mut big = fixture.event("claude PreToolUse Write");
    big["tool_input"]["content"] = "x".repeat(65 << 20).into();
    assert!(
        fixture
            .notify("claude", big.to_string().as_bytes())
            .is_empty()
    );
}

#[test]
fn a_bad_command_line_still_exits_0() {
    let fixture = Fixture::new();
    for args in [
        &["notify"][..],
        &["notify", "--hook", "cursor"],
        &["notify", "--hook", "claude", "--wait"],
    ] {
        let output = Command::new(DEWLINE)
            .args(args)
            .env_clear()
            .env("DEWLINE_SOCKET", &fixture.socket)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(
            output.status.success() && output.stdout.is_empty(),
            "{args:?} {output:?}"
        );
    }
}

#[test]
fn stdin_left_open_doesnt_hold_the_run() {
    let fixture = Fixture::new();
    let listener = UnixListener::bind(&fixture.socket).unwrap();
    let mut child = Command::new(DEWLINE)
        .args(["notify", "--hook", "claude"])
        .env_clear()
        .env("DEWLINE_SOCKET", &fixture.socket)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let start = Instant::now();
    stdin
        .write_all(fixture.event("claude Stop").to_string().as_bytes())
        .unwrap();
    // The probe, then the claim, with stdin still open.
    for expected in ["", "Stop"] {
        let (stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(&stream).read_line(&mut line).unwrap();
        assert!(line.contains(expected), "{line:?}");
    }
    assert!(child.wait().unwrap().success());
    assert!(
        start.elapsed() < Duration::from_secs(1),
        "{:?}",
        start.elapsed()
    );
    drop(stdin);
}

#[test]
fn every_file_of_a_patch_is_sent_though_the_app_answers_none() {
    let fixture = Fixture::new();
    let listener = UnixListener::bind(&fixture.socket).unwrap();
    // A stand-in that reads each line and keeps the connection open, as a busy app might.
    let (sender, heard) = mpsc::channel();
    thread::spawn(move || {
        let mut kept = Vec::new();
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let mut line = String::new();
            let _ = BufReader::new(&stream).read_line(&mut line);
            kept.push(stream);
            if sender.send(line).is_err() {
                return;
            }
        }
    });
    let mut event = fixture.event("codex PreToolUse apply_patch");
    event["tool_input"]["command"] =
        "*** Begin Patch\n*** Add File: a.md\n+a\n*** Add File: b.md\n+b\n*** Add File: c.md\n+c\n*** End Patch".into();
    let output = run("codex", event.to_string().as_bytes(), &fixture.socket);
    assert!(output.status.success());
    let lines: Vec<String> = drain(&fixture.socket, &heard)
        .into_iter()
        .filter(|line| !line.is_empty())
        .collect();
    assert_eq!(lines.len(), 3, "{lines:?}");
}

#[test]
fn a_write_over_a_file_with_a_byte_order_mark_still_declares_its_content() {
    let fixture = Fixture::new();
    fs::write(fixture.dir.path().join("plan.md"), b"\xEF\xBB\xBF# Plan\n").unwrap();
    let mut event = fixture.event("claude PreToolUse Write");
    event["tool_input"]["file_path"] = fixture.real("plan.md").into();
    let line = fixture.one("claude", &event).unwrap();
    assert_eq!(line["declared"], hex("# New\n\n“Quoted” 😀\n"));
}
