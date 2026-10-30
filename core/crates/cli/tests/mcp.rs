//! `dewline mcp` and `dewline doctor` run as an agent would run them, with HOME in a temporary folder.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{Value, json};

const DEWLINE: &str = env!("CARGO_BIN_EXE_dewline");

/// A home holding the notes folder served, and a secret outside that folder.
struct Fixture {
    dir: tempfile::TempDir,
}

impl Fixture {
    fn new() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let notes = home.join("notes");
        fs::create_dir_all(notes.join("projects")).unwrap();
        fs::create_dir_all(notes.join(".git")).unwrap();
        fs::write(
            notes.join("projects/launch.md"),
            "# Launch\n\nShip the beta.\n",
        )
        .unwrap();
        fs::write(
            notes.join("today.md"),
            "Work on [[launch]] and [the plan](projects/launch.md).\n",
        )
        .unwrap();
        fs::write(notes.join(".git/HEAD.md"), "beta in git\n").unwrap();
        fs::write(notes.join(".hidden.md"), "beta hidden\n").unwrap();
        fs::write(notes.join("page.html"), "beta html\n").unwrap();
        fs::write(home.join("secret.md"), "beta secret [[launch]]\n").unwrap();
        symlink(home.join("secret.md"), notes.join("leak.md")).unwrap();
        symlink(&home, notes.join("home")).unwrap();
        Fixture { dir }
    }

    fn home(&self) -> PathBuf {
        self.dir.path().join("home")
    }

    fn inbox(&self) -> PathBuf {
        self.home().join("Documents/Dewline/Inbox.md")
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(DEWLINE);
        command
            .args(args)
            .env("HOME", self.home())
            .current_dir(self.dir.path());
        command
    }
}

struct Server {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next: u64,
}

impl Server {
    fn start(fixture: &Fixture, root: &Path) -> Server {
        let mut child = fixture
            .command(&["mcp", root.to_str().unwrap()])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Server {
            child,
            stdin,
            stdout,
            next: 0,
        }
    }

    fn send(&mut self, message: &Value) {
        writeln!(self.stdin, "{message}").unwrap();
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        self.send(&json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params}));
        let mut line = String::new();
        self.stdout.read_line(&mut line).unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["jsonrpc"], "2.0");
        assert_eq!(reply["id"], self.next);
        reply
    }

    /// A tool's text, and whether it reported an error.
    fn call(&mut self, tool: &str, arguments: Value) -> (String, bool) {
        let reply = self.request("tools/call", json!({"name": tool, "arguments": arguments}));
        let result = &reply["result"];
        (
            result["content"][0]["text"].as_str().unwrap().to_owned(),
            result["isError"].as_bool().unwrap(),
        )
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn the_handshake_lists_four_tools() {
    let fixture = Fixture::new();
    let mut server = Server::start(&fixture, &fixture.home().join("notes"));
    let reply = server.request(
        "initialize",
        json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}),
    );
    assert_eq!(reply["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(reply["result"]["serverInfo"]["name"], "dewline");
    assert!(reply["result"]["capabilities"]["tools"].is_object());
    server.send(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
    assert_eq!(server.request("ping", json!({}))["result"], json!({}));
    let tools = server.request("tools/list", json!({}));
    let names: Vec<_> = tools["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["read", "search", "backlinks", "append_to_inbox"]);
    assert_eq!(
        server.request("resources/list", json!({}))["error"]["code"],
        -32601
    );
    assert_eq!(
        server.request("tools/call", json!({"name": "write", "arguments": {}}))["error"]["code"],
        -32602
    );
    let reply = server.request("initialize", json!({"protocolVersion": "1999-01-01"}));
    assert_eq!(reply["result"]["protocolVersion"], "2025-11-25");
}

#[test]
fn every_tool_stays_inside_the_folder() {
    let fixture = Fixture::new();
    let notes = fixture.home().join("notes");
    let mut server = Server::start(&fixture, &notes);

    assert_eq!(
        server.call("read", json!({"path": "projects/launch.md"})),
        ("# Launch\n\nShip the beta.\n".to_owned(), false)
    );
    let secret = fixture.home().join("secret.md");
    for path in [
        "../secret.md",
        "leak.md",
        "home/secret.md",
        secret.to_str().unwrap(),
        "/etc/hosts",
        ".git/HEAD.md",
        ".hidden.md",
        "page.html",
        "projects",
    ] {
        let (text, failed) = server.call("read", json!({"path": path}));
        assert!(failed, "{path}: {text}");
        assert!(!text.contains("beta"), "{path}: {text}");
        let (text, failed) = server.call("backlinks", json!({"note": path}));
        assert!(failed, "{path}: {text}");
    }

    let (text, failed) = server.call("search", json!({"query": "BETA"}));
    assert!(!failed);
    assert_eq!(text, "projects/launch.md:3: Ship the beta.\n");

    let (text, failed) = server.call("backlinks", json!({"note": "projects/launch.md"}));
    assert!(!failed);
    assert_eq!(
        text,
        "today.md:1: Work on [[launch]] and [the plan](projects/launch.md).\n"
    );

    let before = fs::read(&secret).unwrap();
    let (text, failed) = server.call("append_to_inbox", json!({"text": "../../secret.md"}));
    assert!(!failed, "{text}");
    assert!(
        fs::read_to_string(fixture.inbox())
            .unwrap()
            .ends_with(" · mcp\n../../secret.md\n")
    );
    assert_eq!(fs::read(&secret).unwrap(), before);
    assert!(server.call("append_to_inbox", json!({"path": "x.md"})).1);
}

#[test]
fn a_folder_an_agent_must_not_have_is_refused() {
    let fixture = Fixture::new();
    fs::create_dir_all(fixture.home().join("Library/Notes")).unwrap();
    for root in [
        fixture.home(),
        fixture.dir.path().to_path_buf(),
        fixture.home().join("Library/Notes"),
    ] {
        let output = fixture
            .command(&["mcp", root.to_str().unwrap()])
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(!output.status.success(), "{root:?}");
    }
}

#[test]
fn capture_appends_one_entry() {
    let fixture = Fixture::new();
    fs::create_dir_all(fixture.inbox().parent().unwrap()).unwrap();
    fs::write(fixture.inbox(), "# Inbox\n").unwrap();
    let output = fixture
        .command(&["capture", "buy", "milk"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let mut piped = fixture
        .command(&["capture"])
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    piped
        .stdin
        .take()
        .unwrap()
        .write_all(b"from stdin\n")
        .unwrap();
    assert!(piped.wait().unwrap().success());
    let text = fs::read_to_string(fixture.inbox()).unwrap();
    let entries: Vec<_> = text.split("\n\n").collect();
    assert_eq!(entries.len(), 3, "{text}");
    assert_eq!(entries[0], "# Inbox");
    assert!(entries[1].ends_with(" · cli\nbuy milk"), "{text}");
    assert!(entries[2].ends_with(" · cli\nfrom stdin\n"), "{text}");
}

#[test]
fn doctor_installs_hooks_only_from_a_terminal() {
    let fixture = Fixture::new();
    let settings = fixture.home().join(".claude/settings.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, "{\"model\": \"opus\"}").unwrap();
    let report = fixture.command(&["doctor"]).output().unwrap();
    assert!(report.status.success());
    let report = String::from_utf8(report.stdout).unwrap();
    assert!(
        report.contains("Claude Code: PreToolUse, PostToolUse"),
        "{report}"
    );
    assert!(
        report.contains("Codex: PreToolUse, PostToolUse missing"),
        "{report}"
    );
    let install = fixture
        .command(&["doctor", "--install-hooks"])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(!install.status.success());
    assert!(String::from_utf8_lossy(&install.stderr).contains("needs a terminal"));
    assert_eq!(fs::read(&settings).unwrap(), b"{\"model\": \"opus\"}");
    assert!(!fixture.home().join(".codex").exists());
}
