//! The inbox: one markdown file every capture appends to, the CLI's, MCP's and the app's alike. Each entry starts with
//! a dated source line, such as `2026-10-25 14:02 · cli`.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::file::{self, SaveError};

/// How many times an append reads the inbox again after another writer changed it first.
const RETRIES: usize = 20;

pub fn default_path(home: &Path) -> PathBuf {
    home.join("Documents/Dewline/Inbox.md")
}

/// Appends `text` as one entry from `source`, through the compare-and-swap save, so a running app takes it as an
/// outside write. The bytes already there stay as they are.
pub fn append(path: &Path, source: &str, text: &str) -> io::Result<()> {
    let text = text.trim_end();
    if text.trim_start().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "there is nothing to capture",
        ));
    }
    append_entry(
        path,
        &format!("{} · {source}\n{text}\n", stamp(SystemTime::now())),
    )
}

fn append_entry(path: &Path, entry: &str) -> io::Result<()> {
    for _ in 0..RETRIES {
        let old = match fs::read(path) {
            Ok(old) => old,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if let Some(folder) = path.parent() {
                    fs::create_dir_all(folder)?;
                }
                match OpenOptions::new().write(true).create_new(true).open(path) {
                    Ok(mut file) => return file.write_all(entry.as_bytes()),
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                    Err(error) => return Err(error),
                }
            }
            Err(error) => return Err(error),
        };
        let gap: &[u8] = if old.is_empty() || old.ends_with(b"\n\n") {
            b""
        } else if old.ends_with(b"\n") {
            b"\n"
        } else {
            b"\n\n"
        };
        let new = [&old[..], gap, entry.as_bytes()].concat();
        match file::save(path, &file::hash(&old), &new) {
            Ok(_) => return Ok(()),
            Err(SaveError::Conflict) => continue,
            Err(SaveError::Io(error)) => return Err(error),
        }
    }
    Err(io::Error::other(
        "the inbox kept changing, so nothing was added",
    ))
}

/// `time` in local time, to the minute.
pub fn stamp(time: SystemTime) -> String {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs()) as libc::time_t;
    // SAFETY: `tm` is plain data that localtime_r fills; both pointers are valid for the call.
    let tm = unsafe {
        let mut tm = std::mem::zeroed::<libc::tm>();
        libc::localtime_r(&seconds, &mut tm);
        tm
    };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_append_adds_one_entry_after_the_bytes_already_there() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("Inbox.md");
        for (old, gap) in [
            (
                &b"# Inbox\n\n- [ ] call \xff the bank\r\nno newline"[..],
                &b"\n\n"[..],
            ),
            (b"one line\n", b"\n"),
            (b"two lines\n\n", b""),
            (b"", b""),
        ] {
            fs::write(&path, old).unwrap();
            append(&path, "cli", "buy milk\n\nand eggs \n\n").unwrap();
            let new = fs::read(&path).unwrap();
            assert!(new.starts_with(old));
            let entry = std::str::from_utf8(&new[old.len()..]).unwrap();
            let entry = entry
                .strip_prefix(std::str::from_utf8(gap).unwrap())
                .unwrap();
            let (line, text) = entry.split_once('\n').unwrap();
            assert_eq!(text, "buy milk\n\nand eggs\n");
            let (time, source) = line.split_once(" · ").unwrap();
            assert_eq!(source, "cli");
            assert_eq!(time.len(), "2026-10-25 14:02".len());
            assert_eq!(&time[4..5], "-");
            assert_eq!(&time[10..11], " ");
        }
    }

    #[test]
    fn a_missing_inbox_and_its_folders_are_made() {
        let dir = tempfile::tempdir().unwrap();
        let path = default_path(dir.path());
        append(&path, "mcp", "first").unwrap();
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.ends_with(" · mcp\nfirst\n"), "{text:?}");
        assert_eq!(text.lines().count(), 2);
    }

    #[test]
    fn empty_text_writes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("Inbox.md");
        fs::write(&path, "kept").unwrap();
        assert!(append(&path, "cli", " \n\t\n").is_err());
        assert_eq!(fs::read(&path).unwrap(), b"kept");
    }
}
