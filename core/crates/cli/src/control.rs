//! The app's control socket, as this command sees it. The app's side is
//! app/Dewline/ControlSocket.swift. A connection carries one request, a JSON
//! line; the app answers in JSON lines: `opened` or `error`, then `closed`
//! once the document closes when the request waits.

use std::env;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::target::Target;

pub const VERSION: u32 = 1;
/// The longest line either side reads, newline included.
pub const MAX_LINE: usize = 16 * 1024;
const BUNDLE_ID: &str = "dev.arkwerx.dewline";
const CONNECT_TIMEOUT: Duration = Duration::from_millis(50);
/// How long a launched app has to start listening.
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(10);
/// How long the app has to show a file it was asked for.
const OPEN_TIMEOUT: Duration = Duration::from_secs(10);

pub struct Socket {
    path: PathBuf,
    /// False when `DEWLINE_SOCKET` names the socket, as tests do: then this
    /// command never starts the app or brings it forward.
    launches: bool,
}

impl Socket {
    pub fn find() -> Result<Socket, String> {
        if let Some(path) = env::var_os("DEWLINE_SOCKET") {
            return Ok(Socket {
                path: path.into(),
                launches: false,
            });
        }
        let home = env::home_dir().ok_or("no home folder")?;
        Ok(Socket {
            path: home.join("Library/Application Support/dev.arkwerx.dewline/run/control.sock"),
            launches: true,
        })
    }

    /// Asks the app to open `target`, starting the app when nothing listens.
    pub fn open(&self, target: &Target, wait: bool) -> Result<Connection, String> {
        let stream = self.connect()?;
        let failed = |error: io::Error| format!("{}: talking to Dewline: {error}", target.path);
        stream
            .set_read_timeout(Some(OPEN_TIMEOUT))
            .map_err(failed)?;
        stream
            .set_write_timeout(Some(OPEN_TIMEOUT))
            .map_err(failed)?;
        let mut reader = BufReader::new(stream);
        reader
            .get_mut()
            .write_all(&encode_open(target, wait))
            .map_err(failed)?;
        match next_reply(&mut reader).map_err(|error| format!("{}: {error}", target.path))? {
            Some(Reply::Opened) => Ok(Connection {
                reader,
                path: target.path.clone(),
            }),
            Some(Reply::Error { error, message }) => Err(format!(
                "{}: Dewline didn't open it: {}",
                target.path,
                printable(message.as_deref().unwrap_or(&error))
            )),
            Some(Reply::Closed) | None => Err(format!("{}: Dewline didn't open it", target.path)),
        }
    }

    fn connect(&self) -> Result<UnixStream, String> {
        let uid = euid();
        let unreachable =
            |error| format!("no answer from Dewline at {}: {error}", self.path.display());
        match connect(&self.path, uid) {
            Ok(stream) => return Ok(stream),
            Err(error) if !self.launches || !nobody_listens(&error) => {
                return Err(unreachable(error));
            }
            Err(_) => launch()?,
        }
        let deadline = Instant::now() + LAUNCH_TIMEOUT;
        loop {
            thread::sleep(CONNECT_TIMEOUT);
            match connect(&self.path, uid) {
                Ok(stream) => return Ok(stream),
                Err(error) if nobody_listens(&error) && Instant::now() < deadline => {}
                Err(error) => return Err(unreachable(error)),
            }
        }
    }

    /// Brings the app forward, which macOS lets Launch Services do for a
    /// command the user ran. Focus only: the files are open either way, and
    /// open(1) reports its own failure.
    pub fn activate(&self) {
        if self.launches {
            let _ = Command::new("/usr/bin/open")
                .args(["-b", BUNDLE_ID])
                .status();
        }
    }
}

/// A file the app opened, still connected so its closing can be heard.
pub struct Connection {
    reader: BufReader<UnixStream>,
    path: String,
}

impl Connection {
    /// Returns once the app says the file's document closed.
    pub fn wait(mut self) -> Result<(), String> {
        // macOS refuses socket options (EINVAL) once the app has closed its
        // end; the read below then reports that end.
        let _ = self.reader.get_ref().set_read_timeout(None);
        match next_reply(&mut self.reader).map_err(|error| format!("{}: {error}", self.path))? {
            Some(Reply::Closed) => Ok(()),
            None => Err(format!(
                "{}: Dewline quit before the file closed",
                self.path
            )),
            Some(_) => Err(format!("{}: Dewline answered out of turn", self.path)),
        }
    }
}

fn launch() -> Result<(), String> {
    let status = Command::new("/usr/bin/open")
        .args(["-b", BUNDLE_ID])
        .status()
        .map_err(|error| format!("couldn't run /usr/bin/open: {error}"))?;
    if !status.success() {
        return Err("couldn't start Dewline; is it installed?".into());
    }
    Ok(())
}

/// Connects within CONNECT_TIMEOUT to a socket whose server runs as `uid`.
fn connect(path: &Path, uid: u32) -> io::Result<UnixStream> {
    let (sender, receiver) = mpsc::channel();
    let path = path.to_owned();
    // std has no connect timeout for Unix sockets. A connect that outlasts the
    // wait ends with its thread, dropping the stream.
    thread::spawn(move || sender.send(UnixStream::connect(path)));
    let stream = receiver
        .recv_timeout(CONNECT_TIMEOUT)
        .map_err(|_| io::Error::from(io::ErrorKind::TimedOut))??;
    let peer = peer_uid(&stream)?;
    if peer != uid {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("the socket's owner runs as uid {peer}, not {uid}"),
        ));
    }
    Ok(stream)
}

fn nobody_listens(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused | io::ErrorKind::TimedOut
    )
}

fn peer_uid(stream: &UnixStream) -> io::Result<u32> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: the descriptor stays open while `stream` lives, and both
    // pointers are valid for the call.
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

fn euid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

#[derive(Serialize)]
struct OpenRequest<'a> {
    v: u32,
    op: &'static str,
    path: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    line: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    col: Option<u32>,
    wait: bool,
}

fn encode_open(target: &Target, wait: bool) -> Vec<u8> {
    let request = OpenRequest {
        v: VERSION,
        op: "open",
        path: &target.path,
        line: target.line,
        col: target.column,
        wait,
    };
    let mut line = serde_json::to_vec(&request).expect("strings and numbers always serialize");
    line.push(b'\n');
    line
}

#[derive(Debug, PartialEq)]
enum Reply {
    Opened,
    Closed,
    Error {
        error: String,
        message: Option<String>,
    },
}

#[derive(Deserialize)]
struct ReplyLine {
    v: u32,
    reply: String,
    error: Option<String>,
    message: Option<String>,
}

fn decode_reply(line: &[u8]) -> Result<Reply, String> {
    let line: ReplyLine = serde_json::from_slice(line)
        .map_err(|error| format!("Dewline sent a line this command can't read: {error}"))?;
    if line.v != VERSION {
        return Err(format!(
            "Dewline speaks control protocol {}, this command {VERSION}",
            line.v
        ));
    }
    match (line.reply.as_str(), line.error) {
        ("opened", _) => Ok(Reply::Opened),
        ("closed", _) => Ok(Reply::Closed),
        ("error", Some(error)) => Ok(Reply::Error {
            error,
            message: line.message,
        }),
        (reply, _) => Err(format!(
            "Dewline sent an unknown reply: {}",
            printable(reply)
        )),
    }
}

/// The next reply, or None where the app closed the connection.
fn next_reply(reader: &mut impl BufRead) -> Result<Option<Reply>, String> {
    match read_line(reader) {
        Ok(Some(line)) => decode_reply(&line).map(Some),
        Ok(None) => Ok(None),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
            Err("Dewline didn't answer in time".into())
        }
        Err(error) => Err(format!("reading Dewline's answer: {error}")),
    }
}

/// One line without its newline, or None where the stream ends cleanly.
fn read_line(reader: &mut impl BufRead) -> io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    reader
        .by_ref()
        .take(MAX_LINE as u64)
        .read_until(b'\n', &mut line)?;
    match line.last() {
        None => Ok(None),
        Some(b'\n') => {
            line.pop();
            Ok(Some(line))
        }
        Some(_) if line.len() == MAX_LINE => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "a line longer than 16 KiB",
        )),
        Some(_) => Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "the connection ended inside a line",
        )),
    }
}

/// Text from the app with control characters replaced, so it can't drive the terminal.
fn printable(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_control() { '\u{FFFD}' } else { c })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    fn target(path: &str, line: Option<u32>, column: Option<u32>) -> Target {
        Target {
            path: path.into(),
            line,
            column,
        }
    }

    #[test]
    fn an_open_request_is_one_json_line() {
        assert_eq!(
            encode_open(&target("/Users/me/launch notes/plan.md", Some(12), Some(4)), true),
            b"{\"v\":1,\"op\":\"open\",\"path\":\"/Users/me/launch notes/plan.md\",\"line\":12,\"col\":4,\"wait\":true}\n"
        );
        assert_eq!(
            encode_open(&target("/tmp/plan.md", None, None), false),
            b"{\"v\":1,\"op\":\"open\",\"path\":\"/tmp/plan.md\",\"wait\":false}\n"
        );
        // A newline, quote or backslash in a name stays inside the string.
        let line = encode_open(&target("/tmp/a\nb\"c\\d.md", Some(1), None), false);
        assert_eq!(line.iter().filter(|&&byte| byte == b'\n').count(), 1);
        let value: serde_json::Value = serde_json::from_slice(&line).unwrap();
        assert_eq!(value["path"], "/tmp/a\nb\"c\\d.md");
    }

    #[test]
    fn replies_decode() {
        assert_eq!(
            decode_reply(br#"{"v":1,"reply":"opened"}"#),
            Ok(Reply::Opened)
        );
        assert_eq!(
            decode_reply(br#"{"reply":"closed","v":1,"later":true}"#),
            Ok(Reply::Closed)
        );
        assert_eq!(
            decode_reply(br#"{"v":1,"reply":"error","error":"not_a_file"}"#),
            Ok(Reply::Error {
                error: "not_a_file".into(),
                message: None
            })
        );
        assert_eq!(
            decode_reply(br#"{"v":1,"reply":"error","error":"cannot_open","message":"not UTF-8"}"#),
            Ok(Reply::Error {
                error: "cannot_open".into(),
                message: Some("not UTF-8".into())
            })
        );
        for refused in [
            &br#"{"v":2,"reply":"opened"}"#[..],
            br#"{"v":1,"reply":"error"}"#,
            br#"{"v":1,"reply":"renamed"}"#,
            br#"{"reply":"opened"}"#,
            br#"{"v":"1","reply":"opened"}"#,
            b"opened",
            b"",
        ] {
            assert!(
                decode_reply(refused).is_err(),
                "{}",
                String::from_utf8_lossy(refused)
            );
        }
    }

    #[test]
    fn lines_are_bounded() {
        let mut two = &b"{\"a\":1}\n{\"b\":2}\n"[..];
        assert_eq!(read_line(&mut two).unwrap(), Some(b"{\"a\":1}".to_vec()));
        assert_eq!(read_line(&mut two).unwrap(), Some(b"{\"b\":2}".to_vec()));
        assert_eq!(read_line(&mut two).unwrap(), None);
        let long = vec![b'x'; MAX_LINE + 10];
        assert_eq!(
            read_line(&mut &long[..]).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        let mut fits = vec![b'x'; MAX_LINE - 1];
        fits.push(b'\n');
        assert_eq!(
            read_line(&mut &fits[..]).unwrap().map(|line| line.len()),
            Some(MAX_LINE - 1)
        );
        assert_eq!(
            read_line(&mut &b"{\"v\":1"[..]).unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
    }

    #[test]
    fn a_socket_run_by_another_user_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("control.sock");
        let listener = UnixListener::bind(&path).unwrap();
        // Another uid can't be had without root, so this asks for one.
        let error = connect(&path, euid() + 1).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert!(connect(&path, euid()).is_ok());
        drop(listener);
    }

    #[test]
    fn nothing_listening_fails_fast() {
        let dir = tempfile::tempdir().unwrap();
        let start = Instant::now();
        let error = connect(&dir.path().join("control.sock"), euid()).unwrap_err();
        assert!(nobody_listens(&error), "{error}");
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn printable_keeps_text_and_drops_escapes() {
        assert_eq!(
            printable("café \u{1b}[2Jgone\n"),
            "café \u{FFFD}[2Jgone\u{FFFD}"
        );
    }
}
