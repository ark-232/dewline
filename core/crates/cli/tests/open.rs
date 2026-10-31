//! `dewline open` against a socket server in this process that stands in for
//! the app. `DEWLINE_SOCKET` points the command at it, which also keeps the
//! command from starting or focusing the real app.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::symlink;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

const DEWLINE: &str = env!("CARGO_BIN_EXE_dewline");

/// A folder holding "my plan.md", with a socket path beside it.
struct Fixture {
    dir: tempfile::TempDir,
    socket: PathBuf,
}

impl Fixture {
    fn new() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("my plan.md"), "# Plan\n\nShip it.\n").unwrap();
        let socket = dir.path().join("control.sock");
        Fixture { dir, socket }
    }

    fn plan(&self) -> PathBuf {
        fs::canonicalize(self.dir.path().join("my plan.md")).unwrap()
    }

    fn dewline(&self, program: &Path, args: &[&str]) -> Command {
        let mut command = Command::new(program);
        command
            .args(args)
            .current_dir(self.dir.path())
            .env("DEWLINE_SOCKET", &self.socket)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.dewline(Path::new(DEWLINE), args).output().unwrap()
    }
}

/// Accepts one connection and returns its request, parsed, with the stream.
fn accept(listener: &UnixListener) -> (Value, UnixStream) {
    let (stream, _) = listener.accept().unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut line = String::new();
    BufReader::new(&stream).read_line(&mut line).unwrap();
    assert!(line.ends_with('\n'), "{line:?}");
    (serde_json::from_str(&line).unwrap(), stream)
}

fn answer(mut stream: &UnixStream, reply: &str) {
    writeln!(stream, r#"{{"v":1,"reply":"{reply}"}}"#).unwrap();
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

#[test]
fn open_wait_returns_once_the_file_closes() {
    let fixture = Fixture::new();
    let listener = UnixListener::bind(&fixture.socket).unwrap();
    let mut child = fixture
        .dewline(Path::new(DEWLINE), &["open", "--wait", "my plan.md:3:2"])
        .spawn()
        .unwrap();
    let (request, stream) = accept(&listener);
    assert_eq!(
        request,
        json!({"v": 1, "op": "open", "path": fixture.plan(), "line": 3, "col": 2, "wait": true})
    );
    answer(&stream, "opened");
    thread::sleep(Duration::from_millis(300));
    assert!(
        child.try_wait().unwrap().is_none(),
        "returned before the file closed"
    );
    answer(&stream, "closed");
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{}", stderr(&output));
}

#[test]
fn open_wait_fails_when_the_app_crashes() {
    let fixture = Fixture::new();
    let listener = UnixListener::bind(&fixture.socket).unwrap();
    let child = fixture
        .dewline(Path::new(DEWLINE), &["open", "--wait", "my plan.md"])
        .spawn()
        .unwrap();
    let (_, stream) = accept(&listener);
    answer(&stream, "opened");
    drop(stream);
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr(&output).contains("Dewline quit before the file closed"),
        "{}",
        stderr(&output)
    );
}

#[test]
fn open_wait_waits_for_every_file() {
    let fixture = Fixture::new();
    fs::write(fixture.dir.path().join("notes.md"), "notes\n").unwrap();
    let listener = UnixListener::bind(&fixture.socket).unwrap();
    let mut child = fixture
        .dewline(
            Path::new(DEWLINE),
            &["open", "my plan.md", "notes.md:2", "--wait"],
        )
        .spawn()
        .unwrap();
    let (first, plan) = accept(&listener);
    answer(&plan, "opened");
    let (second, notes) = accept(&listener);
    answer(&notes, "opened");
    assert_eq!(first["path"], json!(fixture.plan()));
    assert_eq!(
        (&second["line"], &second["wait"]),
        (&json!(2), &json!(true))
    );
    answer(&notes, "closed");
    thread::sleep(Duration::from_millis(200));
    assert!(
        child.try_wait().unwrap().is_none(),
        "returned with a file open"
    );
    answer(&plan, "closed");
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{}", stderr(&output));
}

#[test]
fn open_returns_once_opened_and_runs_through_a_symlink() {
    let fixture = Fixture::new();
    // The Homebrew cask links the command from Dewline.app/Contents/Helpers.
    let link = fixture.dir.path().join("bin/dewline");
    fs::create_dir(link.parent().unwrap()).unwrap();
    symlink(DEWLINE, &link).unwrap();
    let listener = UnixListener::bind(&fixture.socket).unwrap();
    let child = fixture
        .dewline(&link, &["open", "my plan.md"])
        .spawn()
        .unwrap();
    let (request, stream) = accept(&listener);
    assert_eq!(
        request,
        json!({"v": 1, "op": "open", "path": fixture.plan(), "wait": false})
    );
    answer(&stream, "opened");
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{}", stderr(&output));
    drop(stream);
}

#[test]
fn a_refusal_from_the_app_is_reported() {
    let fixture = Fixture::new();
    let listener = UnixListener::bind(&fixture.socket).unwrap();
    let child = fixture
        .dewline(Path::new(DEWLINE), &["open", "my plan.md"])
        .spawn()
        .unwrap();
    let (_, mut stream) = accept(&listener);
    writeln!(
        stream,
        r#"{{"v":1,"reply":"error","error":"cannot_open","message":"The file isn’t UTF-8 text.\u001b[2J"}}"#
    )
    .unwrap();
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr(&output)
            .ends_with("Dewline didn't open it: The file isn’t UTF-8 text.\u{FFFD}[2J\n"),
        "{}",
        stderr(&output)
    );
}

#[test]
fn an_app_that_hangs_up_is_an_error() {
    let fixture = Fixture::new();
    let listener = UnixListener::bind(&fixture.socket).unwrap();
    for _ in 0..20 {
        let child = fixture
            .dewline(Path::new(DEWLINE), &["open", "my plan.md"])
            .spawn()
            .unwrap();
        drop(listener.accept().unwrap());
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        // Not the EINVAL macOS gives socket options on a closed connection.
        assert!(
            stderr(&output).starts_with("dewline: ") && !stderr(&output).contains("os error 22"),
            "{}",
            stderr(&output)
        );
    }
}

#[test]
fn bad_names_open_nothing() {
    let fixture = Fixture::new();
    fs::create_dir(fixture.dir.path().join("drafts")).unwrap();
    // Nothing listens, so reaching the socket would fail differently.
    let output = fixture.run(&["open", "my plan.md", "drafts", "missing.md:4"]);
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        stderr(&output),
        "dewline: drafts: is a folder; dewline open takes files\ndewline: missing.md:4: no such file\n"
    );
}

#[test]
fn a_hostile_name_cannot_drive_the_terminal() {
    let fixture = Fixture::new();
    let output = fixture.run(&["open", "\u{1b}]0;owned\u{7}/plan.md:3"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(
        !output.stderr.contains(&0x1b) && !output.stderr.contains(&0x07),
        "{:?}",
        stderr(&output)
    );
    assert!(stderr(&output).contains("]0;owned"), "{}", stderr(&output));
}

#[test]
fn nothing_listening_fails_without_starting_the_app() {
    let fixture = Fixture::new();
    let start = Instant::now();
    let output = fixture.run(&["open", "my plan.md"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr(&output).starts_with("dewline: no answer from Dewline at "),
        "{}",
        stderr(&output)
    );
    assert!(start.elapsed() < Duration::from_secs(2));
}

#[test]
fn help_and_version() {
    let fixture = Fixture::new();
    let version = fixture.run(&["--version"]);
    assert_eq!(
        String::from_utf8_lossy(&version.stdout),
        format!("dewline {}\n", env!("CARGO_PKG_VERSION"))
    );
    let help = String::from_utf8_lossy(&fixture.run(&["--help"]).stdout).into_owned();
    for command in ["open", "notify", "changes", "capture", "export", "mcp", "doctor"] {
        assert!(help.contains(&format!("\n  {command} ")), "{help}");
    }
    let export = String::from_utf8_lossy(&fixture.run(&["export", "--help"]).stdout).into_owned();
    assert!(export.contains("PDF needs the Dewline app"), "{export}");
    let open = String::from_utf8_lossy(&fixture.run(&["open", "--help"]).stdout).into_owned();
    assert!(
        open.contains("FILE[:LINE[:COLUMN]]") && open.contains("--wait"),
        "{open}"
    );
    let bare = fixture.run(&[]);
    assert_eq!(bare.status.code(), Some(2));
    assert!(
        stderr(&bare).contains("Usage: dewline"),
        "{}",
        stderr(&bare)
    );
    assert_eq!(fixture.run(&["open"]).status.code(), Some(2));
    assert_eq!(fixture.run(&["export", "plan.md"]).status.code(), Some(2));
}
