//! `dewline notify`, the command Claude Code's and Codex's hooks run with each event's JSON on stdin. It tells the
//! app, one `notify` line per claim on the control socket, which file a tool is about to change or changed and the
//! BLAKE3 hashes involved: ids, paths and hashes, never content (claims.rs reads them). It never writes a file,
//! never starts the app, never runs another program, and always exits 0, so a hook can't hold up or refuse a tool
//! call.

use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use clap::ValueEnum;
use dewline_core::claims::{Claim, Fields};
use serde::Serialize;

use crate::control::{self, Socket};
use crate::hook::{self, Event, Input};
use crate::patch::{self, Hunk};

/// The longest a run takes, whatever stdin and the files hold.
const DEADLINE: Duration = Duration::from_secs(2);
/// Larger files are hashed but get no declared hash.
const MAX_FILE: u64 = 64 << 20;
const UTF8_BOM: &[u8] = b"\xEF\xBB\xBF";

/// Whose hook runs the command.
#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub enum Vendor {
    Claude,
    Codex,
}

impl Vendor {
    fn name(self) -> &'static str {
        match self {
            Vendor::Claude => "claude",
            Vendor::Codex => "codex",
        }
    }
}

pub fn run(vendor: Vendor) {
    thread::spawn(|| {
        thread::sleep(DEADLINE);
        std::process::exit(0);
    });
    let Ok(socket) = Socket::find() else { return };
    // With no app listening, the run ends here, before stdin or any file is read.
    if socket.reach().is_err() {
        return;
    }
    let Ok(event) = hook::read(io::stdin().lock(), vendor) else {
        return;
    };
    for line in lines(vendor, &event) {
        if notify(&socket, &line).is_err() {
            return;
        }
    }
}

/// Sends one line on its own connection, then waits for the app to close it, so a patch naming many files can't
/// crowd the app's connection limit.
fn notify(socket: &Socket, line: &[u8]) -> io::Result<()> {
    let mut stream = socket.reach()?;
    control::set_timeout(&stream, Some(control::CONNECT_TIMEOUT))?;
    stream.write_all(line)?;
    io::copy(
        &mut (&stream).take(control::MAX_LINE as u64),
        &mut io::sink(),
    )?;
    Ok(())
}

#[derive(Serialize)]
struct Line<'a> {
    v: u32,
    op: &'static str,
    event: &'a str,
    vendor: &'a str,
    session: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_use_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hash: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    declared: Option<&'a str>,
}

/// The line for `fields`, or None when claims.rs would refuse it.
fn encode(fields: Fields) -> Option<Vec<u8>> {
    Claim::parse(fields).ok()?;
    let line = Line {
        v: control::VERSION,
        op: "notify",
        event: fields.event,
        vendor: fields.vendor,
        session: fields.session,
        tool_use_id: fields.tool_use_id,
        tool: fields.tool,
        path: fields.path,
        hash: fields.hash,
        declared: fields.declared,
    };
    let mut line = serde_json::to_vec(&line).expect("strings always serialize");
    line.push(b'\n');
    Some(line)
}

/// Every line `event` calls for: one per file a tool use names, one for the file InstructionsLoaded loads, one for
/// the end of a turn or session, and none for anything claims.rs doesn't take.
fn lines(vendor: Vendor, event: &Event) -> Vec<Vec<u8>> {
    let (Some(name), Some(session)) = (event.name.as_deref(), event.session.as_deref()) else {
        return Vec::new();
    };
    let fields = Fields {
        event: name,
        vendor: vendor.name(),
        session,
        ..Fields::default()
    };
    let pre = match name {
        "PreToolUse" => true,
        "PostToolUse" => false,
        "InstructionsLoaded" => {
            let real = event
                .file_path
                .as_deref()
                .and_then(|path| named(event.cwd.as_deref(), path))
                .and_then(|path| fs::canonicalize(path).ok());
            let path = real.as_deref().and_then(Path::to_str);
            return encode(Fields { path, ..fields }).into_iter().collect();
        }
        _ => return encode(fields).into_iter().collect(),
    };
    let (Some(tool), Some(id)) = (event.tool.as_deref(), event.tool_use_id.as_deref()) else {
        return Vec::new();
    };
    let fields = Fields {
        tool_use_id: Some(id),
        tool: Some(tool),
        ..fields
    };
    let files = match (vendor, tool) {
        (Vendor::Claude, "Read" | "Edit" | "MultiEdit" | "Write") => claude(event, tool, pre),
        (Vendor::Codex, "apply_patch") => codex(event, pre),
        _ => Vec::new(),
    };
    files
        .iter()
        .filter_map(|(path, hash, declared)| {
            let hash = hash.map(|hash| hash.to_hex());
            let declared = declared.map(|hash| hash.to_hex());
            encode(Fields {
                path: path.to_str(),
                hash: hash.as_ref().map(|hex| hex.as_str()),
                declared: declared.as_ref().map(|hex| hex.as_str()),
                ..fields
            })
        })
        .collect()
}

/// A claimed file: its realpath, its hash (None: no file) and, at PreToolUse, the declared hash.
type Claimed = (PathBuf, Option<blake3::Hash>, Option<blake3::Hash>);

fn claude(event: &Event, tool: &str, pre: bool) -> Vec<Claimed> {
    let input = &event.input;
    let Some((path, disk)) = input
        .file_path
        .as_deref()
        .and_then(|path| named(event.cwd.as_deref(), path))
        .and_then(|path| look(&path, pre && tool != "Read"))
    else {
        return Vec::new();
    };
    let declared = if pre {
        declared(tool, input, &disk)
    } else {
        None
    };
    vec![(path, disk.hash(), declared)]
}

fn codex(event: &Event, pre: bool) -> Vec<Claimed> {
    let (Some(cwd), Some(hunks)) = (
        event.cwd.as_deref().filter(|cwd| cwd.starts_with('/')),
        event.input.command.as_deref().and_then(patch::parse),
    ) else {
        return Vec::new();
    };
    // Each file the patch names, in order, by realpath; one Codex can't reach as a regular file is None.
    let mut files: Vec<(String, Option<(PathBuf, Disk)>)> = Vec::new();
    for name in hunks.iter().flat_map(Hunk::paths) {
        if !files.iter().any(|(seen, _)| seen == name) {
            files.push((name.to_owned(), look(&Path::new(cwd).join(name), pre)));
        }
    }
    let after = pre.then(|| simulate(&hunks, &files)).flatten();
    let mut claimed: Vec<Claimed> = Vec::new();
    for (path, disk) in files.into_iter().filter_map(|(_, file)| file) {
        if !claimed.iter().any(|(seen, _, _)| *seen == path) {
            let declared = after
                .as_ref()
                .and_then(|after| after.get(&path).cloned().flatten())
                .map(|text| blake3::hash(text.as_bytes()));
            claimed.push((path, disk.hash(), declared));
        }
    }
    claimed
}

/// Each file's text after Codex applies `hunks` in order to what `files` read, by realpath (None: no file), or
/// None for the whole patch where Codex would stop partway or the result depends on what wasn't read.
fn simulate(
    hunks: &[Hunk],
    files: &[(String, Option<(PathBuf, Disk)>)],
) -> Option<BTreeMap<PathBuf, Option<String>>> {
    let real = |name: &str| {
        files
            .iter()
            .find(|(seen, _)| seen == name)
            .and_then(|(_, file)| file.as_ref())
    };
    let mut state: BTreeMap<PathBuf, Option<String>> = BTreeMap::new();
    let text = |state: &BTreeMap<PathBuf, Option<String>>, name: &str| -> Option<Option<String>> {
        let (path, disk) = real(name)?;
        match state.get(path) {
            Some(text) => Some(text.clone()),
            None => match disk {
                Disk::Missing => Some(None),
                Disk::File { bytes, .. } => Some(Some(patch_text(bytes.as_deref()?)?.to_owned())),
            },
        }
    };
    for hunk in hunks {
        match hunk {
            Hunk::Add { path, contents } => {
                state.insert(real(path)?.0.clone(), Some(contents.clone()));
            }
            Hunk::Delete { path } => {
                let (real_path, disk) = real(path)?;
                let exists = match state.get(real_path) {
                    Some(text) => text.is_some(),
                    None => matches!(disk, Disk::File { .. }),
                };
                exists.then_some(())?;
                state.insert(real_path.clone(), None);
            }
            Hunk::Update {
                path,
                move_path,
                chunks,
            } => {
                let new = patch::update(&text(&state, path)??, chunks)?;
                let source = real(path)?.0.clone();
                match move_path {
                    Some(to) => {
                        state.insert(real(to)?.0.clone(), Some(new));
                        state.insert(source, None);
                    }
                    None => {
                        state.insert(source, Some(new));
                    }
                }
            }
        }
    }
    Some(state)
}

/// What Codex can read and patch: UTF-8 text with no byte-order mark.
fn patch_text(bytes: &[u8]) -> Option<&str> {
    (!bytes.starts_with(UTF8_BOM))
        .then(|| std::str::from_utf8(bytes).ok())
        .flatten()
}

/// The hash of the bytes Claude Code's tool writes, or None where it would refuse the call or this can't be sure
/// of its bytes: a file that isn't UTF-8 text, holds a NUL or starts with a byte-order mark, an Edit of a file with
/// CRs (Edit rewrites line endings), or an Edit Claude Code would refuse.
fn declared(tool: &str, input: &Input, disk: &Disk) -> Option<blake3::Hash> {
    let text = match disk {
        Disk::Missing => None,
        Disk::File { bytes, .. } => {
            let bytes = bytes.as_deref()?;
            let plain = !bytes.starts_with(UTF8_BOM) && !bytes.contains(&0);
            Some(plain.then(|| std::str::from_utf8(bytes).ok()).flatten()?)
        }
    };
    let edits: Vec<(&str, &str, bool)> = match tool {
        "Write" => return input.content,
        "Edit" => vec![(
            input.old_string.as_deref()?,
            input.new_string.as_deref()?,
            input.replace_all.unwrap_or(false),
        )],
        "MultiEdit" => input
            .edits
            .as_ref()?
            .iter()
            .map(|edit| {
                Some((
                    edit.old_string.as_deref()?,
                    edit.new_string.as_deref()?,
                    edit.replace_all.unwrap_or(false),
                ))
            })
            .collect::<Option<_>>()?,
        _ => return None,
    };
    if text.is_some_and(|text| text.contains('\r')) {
        return None;
    }
    edited(text, &edits).map(|text| blake3::hash(text.as_bytes()))
}

/// What Claude Code's Edit and MultiEdit make of `text` (None: no file), applying each edit to the result of the
/// last: an empty `old_string` only as the first edit of a file that is missing or empty, where it writes
/// `new_string`; otherwise the first match, or every match with `replace_all`, refusing a missing match, more than
/// one match without `replace_all`, an `old_string` found in an earlier edit's `new_string`, and an edit that changes
/// nothing. Deleting text that doesn't end in a newline also deletes the newline after it, when one follows.
fn edited(text: Option<&str>, edits: &[(&str, &str, bool)]) -> Option<String> {
    let original = text.unwrap_or("");
    let mut out = original.to_owned();
    let mut written: Vec<&str> = Vec::new();
    for (index, &(old, new, all)) in edits.iter().enumerate() {
        let next = if old.is_empty() {
            (index == 0 && original.is_empty()).then(|| new.to_owned())?
        } else {
            if index == 0 {
                text?;
            }
            let trimmed = old.trim_end_matches('\n');
            if !trimmed.is_empty() && written.iter().any(|earlier| earlier.contains(trimmed)) {
                return None;
            }
            let matches = out.matches(old).count();
            if matches == 0 || (matches > 1 && !all) {
                return None;
            }
            let with_newline = format!("{old}\n");
            let old = if new.is_empty() && !old.ends_with('\n') && out.contains(&with_newline) {
                with_newline.as_str()
            } else {
                old
            };
            if all {
                out.replace(old, new)
            } else {
                out.replacen(old, new, 1)
            }
        };
        if next == out {
            return None;
        }
        out = next;
        written.push(new);
    }
    (out != original).then_some(out)
}

/// A named file as one look found it.
enum Disk {
    Missing,
    File {
        hash: blake3::Hash,
        /// The bytes, unless the file is larger than MAX_FILE or the look didn't keep them.
        bytes: Option<Vec<u8>>,
    },
}

impl Disk {
    fn hash(&self) -> Option<blake3::Hash> {
        match self {
            Disk::Missing => None,
            Disk::File { hash, .. } => Some(*hash),
        }
    }
}

/// `path` as a tool resolves it: absolute, or relative to the session's folder.
fn named(cwd: Option<&str>, path: &str) -> Option<PathBuf> {
    match (path.starts_with('/'), cwd) {
        (true, _) => Some(PathBuf::from(path)),
        (false, Some(cwd)) if cwd.starts_with('/') && !path.starts_with('~') => {
            Some(Path::new(cwd).join(path))
        }
        _ => None,
    }
}

/// The realpath of `path` and what is there, keeping the bytes when `keep`. A file not there yet takes its folder's
/// realpath and its name. Anything but a regular file, or nothing at a resolvable place, is None; a FIFO is opened
/// without blocking and refused.
fn look(path: &Path, keep: bool) -> Option<(PathBuf, Disk)> {
    let real = match fs::canonicalize(path) {
        Ok(real) => real,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            // A dangling symlink is something: the tool would write through it.
            fs::symlink_metadata(path).is_err().then_some(())?;
            let folder = fs::canonicalize(path.parent()?).ok()?;
            return Some((folder.join(path.file_name()?), Disk::Missing));
        }
        Err(_) => return None,
    };
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&real)
        .ok()?;
    file.metadata().ok()?.is_file().then_some(())?;
    let disk = read(&file, keep).ok()?;
    Some((real, disk))
}

fn read(file: &File, keep: bool) -> io::Result<Disk> {
    let mut hasher = blake3::Hasher::new();
    if !keep {
        hasher.update_reader(file)?;
        let hash = hasher.finalize();
        return Ok(Disk::File { hash, bytes: None });
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE + 1).read_to_end(&mut bytes)?;
    hasher.update(&bytes);
    let bytes = if bytes.len() as u64 > MAX_FILE {
        hasher.update_reader(file)?;
        None
    } else {
        Some(bytes)
    };
    let hash = hasher.finalize();
    Ok(Disk::File { hash, bytes })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edit(text: Option<&str>, old: &str, new: &str, all: bool) -> Option<String> {
        edited(text, &[(old, new, all)])
    }

    #[test]
    fn edit_replaces_one_unique_match() {
        assert_eq!(
            edit(Some("a b c"), "b", "B", false).as_deref(),
            Some("a B c")
        );
        // Claude Code refuses a string found twice unless replace_all is set, and one found nowhere.
        assert_eq!(edit(Some("x y x"), "x", "z", false), None);
        assert_eq!(
            edit(Some("x y x"), "x", "z", true).as_deref(),
            Some("z y z")
        );
        assert_eq!(edit(Some("aaa"), "aa", "b", true).as_deref(), Some("ba"));
        assert_eq!(edit(Some("abc"), "q", "z", false), None);
        assert_eq!(edit(Some("abc"), "b", "b", false), None);
        // A replacement is literal: $& and $1 mean nothing.
        assert_eq!(
            edit(Some("ab"), "a", "$&$1$$", false).as_deref(),
            Some("$&$1$$b")
        );
    }

    #[test]
    fn deleting_a_line_takes_its_newline() {
        assert_eq!(
            edit(Some("one\ntwo\nthree\n"), "two", "", false).as_deref(),
            Some("one\nthree\n")
        );
        assert_eq!(
            edit(Some("one\ntwo"), "two", "", false).as_deref(),
            Some("one\n")
        );
        assert_eq!(
            edit(Some("one\ntwo\n"), "two\n", "", false).as_deref(),
            Some("one\n")
        );
        // With replace_all, only matches a newline follows are deleted, each with its newline.
        assert_eq!(
            edit(Some("x\nx y\nx"), "x", "", true).as_deref(),
            Some("x y\nx")
        );
    }

    #[test]
    fn an_empty_old_string_writes_a_missing_or_empty_file() {
        assert_eq!(edit(None, "", "# New\n", false).as_deref(), Some("# New\n"));
        assert_eq!(
            edit(Some(""), "", "# New\n", false).as_deref(),
            Some("# New\n")
        );
        assert_eq!(edit(Some("# Old\n"), "", "# New\n", false), None);
        assert_eq!(edit(None, "", "", false), None);
        assert_eq!(edit(None, "a", "b", false), None);
    }

    #[test]
    fn multi_edit_applies_edits_in_order() {
        let text = Some("alpha beta gamma\n");
        let edits = [("alpha", "one", false), ("one beta", "two", false)];
        assert_eq!(edited(text, &edits).as_deref(), Some("two gamma\n"));
        // An old_string found in an earlier edit's new_string is refused, as is any edit that fails.
        assert_eq!(
            edited(text, &[("alpha", "beta x", false), ("beta", "B", false)]),
            None
        );
        assert_eq!(
            edited(text, &[("alpha", "one", false), ("alpha", "two", false)]),
            None
        );
        // Edits that cancel out change nothing, which Claude Code refuses.
        assert_eq!(
            edited(Some("ab"), &[("a", "x", false), ("xb", "ab", false)]),
            None
        );
        // After a first edit that writes a new file, every later old_string is part of that edit's new_string.
        let new_file = [("", "a\n\nb\n", false), ("b", "c", false)];
        assert_eq!(edited(None, &new_file), None);
        let new_file = [("", "a\n\nb\n", false), ("\n\n", "\n", false)];
        assert_eq!(edited(None, &new_file).as_deref(), Some("a\nb\n"));
        assert_eq!(
            edited(Some("a"), &[("a", "b", false), ("", "c", false)]),
            None
        );
    }

    fn input(old: &str, new: &str) -> Input {
        Input {
            old_string: Some(old.into()),
            new_string: Some(new.into()),
            ..Input::default()
        }
    }

    fn file(bytes: &[u8]) -> Disk {
        Disk::File {
            hash: blake3::hash(bytes),
            bytes: Some(bytes.to_vec()),
        }
    }

    #[test]
    fn files_claude_code_rewrites_get_no_declared_hash() {
        let h = |text: &str| Some(blake3::hash(text.as_bytes()));
        assert_eq!(declared("Edit", &input("a", "b"), &file(b"a\n")), h("b\n"));
        for bytes in [&b"a\r\n"[..], b"\xEF\xBB\xBFa\n", b"a\0\n", b"a\xff\n"] {
            assert_eq!(
                declared("Edit", &input("a", "b"), &file(bytes)),
                None,
                "{bytes:?}"
            );
        }
        let too_big = Disk::File {
            hash: blake3::hash(b""),
            bytes: None,
        };
        assert_eq!(declared("Edit", &input("a", "b"), &too_big), None);
        let write = Input {
            content: h("new"),
            ..Input::default()
        };
        assert_eq!(declared("Write", &write, &Disk::Missing), h("new"));
        // Write writes its content as it is over a file with CRLFs, but adds a byte-order mark to one that has one.
        assert_eq!(declared("Write", &write, &file(b"old\r\n")), h("new"));
        assert_eq!(declared("Write", &write, &file(b"\xEF\xBB\xBFold")), None);
        assert_eq!(declared("Read", &write, &file(b"old")), None);
    }

    #[test]
    fn named_paths_are_absolute_or_relative_to_the_session() {
        assert_eq!(named(None, "/a/b.md"), Some(PathBuf::from("/a/b.md")));
        assert_eq!(
            named(Some("/repo"), "docs/b.md"),
            Some(PathBuf::from("/repo/docs/b.md"))
        );
        assert_eq!(named(Some("repo"), "b.md"), None);
        assert_eq!(named(Some("/repo"), "~/b.md"), None);
        assert_eq!(named(None, "b.md"), None);
    }
}
