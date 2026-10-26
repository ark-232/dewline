use std::collections::HashSet;
use std::ffi::OsString;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use blake3::Hash;

const KEEP_FOR: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const KEEP_NEWEST: usize = 50;
const HEADER: &[u8] = b"dewline snapshots 1";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    /// Unique among its file's snapshots until the file moves.
    pub id: u64,
    /// BLAKE3 of the bytes, the key `get` takes.
    pub hash: Hash,
    /// To the millisecond.
    pub time: SystemTime,
    pub origin: String,
    /// Set only by `pin`. A draft is never pinned.
    pub pinned: bool,
}

/// One file's history, oldest first, and its draft.
struct Index {
    path: PathBuf,
    history: Vec<Snapshot>,
    draft: Option<Snapshot>,
}

/// Snapshots of files, kept under a root folder. `blobs/` holds each version
/// once, zstd-compressed and named by the BLAKE3 hash of its bytes; `files/`
/// holds one index per file path, named by the hash of the path; `tmp/`
/// holds writes in progress, and every writer, in any process, holds the
/// `lock` file. Folders are 0700 and files 0600.
///
/// Each write is synced in `tmp/`, renamed into place and its folder synced,
/// so a kill leaves the old file or the new one whole. A blob is in place
/// before any index names it and is deleted only after no index does.
pub struct Store {
    root: PathBuf,
}

impl Store {
    /// Opens the store at `root`, creating its folders, and sets them to 0700.
    pub fn open(root: &Path) -> io::Result<Store> {
        for folder in ["", "blobs", "files", "tmp"] {
            let folder = root.join(folder);
            DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&folder)?;
            fs::set_permissions(&folder, fs::Permissions::from_mode(0o700))?;
        }
        Ok(Store {
            root: root.to_owned(),
        })
    }

    /// Adds `bytes` to the history of the file at `path`. When the newest
    /// entry already holds them from the same origin, it is returned instead.
    pub fn put(
        &self,
        path: &Path,
        bytes: &[u8],
        origin: &str,
        now: SystemTime,
    ) -> io::Result<Snapshot> {
        self.add(path, bytes, origin, now, false)
    }

    /// Puts `bytes` in the draft slot of the file at `path`, replacing the
    /// draft it held. The draft is not in the history; `prune` keeps it while
    /// the file has a document and for 30 days after it was written.
    pub fn set_draft(
        &self,
        path: &Path,
        bytes: &[u8],
        origin: &str,
        now: SystemTime,
    ) -> io::Result<Snapshot> {
        self.add(path, bytes, origin, now, true)
    }

    /// The bytes whose BLAKE3 hash is `hash`.
    pub fn get(&self, hash: &Hash) -> io::Result<Vec<u8>> {
        let blob = self.root.join("blobs").join(hash.to_hex().as_str());
        let bytes = zstd::decode_all(fs::read(&blob)?.as_slice())?;
        if blake3::hash(&bytes) != *hash {
            return Err(damaged(&blob));
        }
        Ok(bytes)
    }

    /// The history of the file at `path`, newest first.
    pub fn list(&self, path: &Path) -> io::Result<Vec<Snapshot>> {
        let mut history = self.index(path)?.history;
        history.reverse();
        Ok(history)
    }

    pub fn draft(&self, path: &Path) -> io::Result<Option<Snapshot>> {
        Ok(self.index(path)?.draft)
    }

    /// Pins or unpins an entry in the history of the file at `path`. An entry
    /// that is gone, or a draft, is NotFound.
    pub fn pin(&self, path: &Path, snapshot: &Snapshot, pinned: bool) -> io::Result<()> {
        let _lock = self.lock()?;
        let mut index = self.index(path)?;
        let entry = index
            .history
            .iter_mut()
            .find(|entry| (entry.id, entry.hash) == (snapshot.id, snapshot.hash))
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "the snapshot is gone"))?;
        if entry.pinned == pinned {
            return Ok(());
        }
        entry.pinned = pinned;
        self.write(&index)
    }

    /// Moves the snapshots of the file at `from` to `to`, its history merged
    /// by time with any history `to` already has, and gives them new ids. Its
    /// draft takes `to`'s slot, and a draft `to` held joins the history. A
    /// kill between the two index writes leaves the snapshots under both
    /// paths, and running the move again finishes it.
    pub fn moved(&self, from: &Path, to: &Path) -> io::Result<()> {
        if from.as_os_str() == to.as_os_str() {
            return Ok(());
        }
        let _lock = self.lock()?;
        let moving = self.index(from)?;
        if moving.history.is_empty() && moving.draft.is_none() {
            return Ok(());
        }
        let mut index = self.index(to)?;
        let mut there = std::mem::take(&mut index.history);
        // A move that a kill cut short left these in `to` already.
        let same =
            |a: &Snapshot, b: &Snapshot| (a.hash, a.time, &a.origin) == (b.hash, b.time, &b.origin);
        if let Some(draft) = moving.draft
            && let Some(displaced) = index.draft.replace(draft)
            && !index
                .draft
                .as_ref()
                .is_some_and(|draft| same(draft, &displaced))
        {
            there.insert(
                there.partition_point(|entry| entry.time <= displaced.time),
                displaced,
            );
        }
        let mut moving = moving.history;
        moving.retain(|entry| !there.iter().any(|kept| same(kept, entry)));
        let (mut there, mut moving) = (there.into_iter().peekable(), moving.into_iter().peekable());
        while let (Some(a), Some(b)) = (there.peek(), moving.peek()) {
            let next = if a.time <= b.time {
                there.next()
            } else {
                moving.next()
            };
            index.history.extend(next);
        }
        index.history.extend(there.chain(moving));
        for (id, snapshot) in (1..).zip(index.history.iter_mut().chain(&mut index.draft)) {
            snapshot.id = id;
        }
        self.write(&index)?;
        step("moved");
        fs::remove_file(self.root.join("files").join(key(from)))?;
        File::open(self.root.join("files"))?.sync_all()
    }

    /// Drops each history entry that is older than 30 days, unpinned and not
    /// among its file's newest 50, and each draft older than 30 days whose
    /// file is not in `open`, the files with a document. Then deletes the
    /// blobs no snapshot names and whatever killed writes left in `tmp/`. A
    /// file in `files/` that is not a sound index, hidden files aside, stops
    /// it before any blob is deleted.
    pub fn prune(&self, now: SystemTime, open: &[&Path]) -> io::Result<()> {
        let _lock = self.lock()?;
        for temp in fs::read_dir(self.root.join("tmp"))? {
            fs::remove_file(temp?.path())?;
        }
        let cutoff = now.checked_sub(KEEP_FOR).unwrap_or(UNIX_EPOCH);
        let mut named = HashSet::new();
        for file in fs::read_dir(self.root.join("files"))? {
            let file = file?.path();
            if file
                .file_name()
                .unwrap_or_default()
                .as_bytes()
                .starts_with(b".")
            {
                continue;
            }
            let mut index = parse(&fs::read(&file)?).ok_or_else(|| damaged(&file))?;
            let before = (index.history.len(), index.draft.is_some());
            let newest = index.history.len().saturating_sub(KEEP_NEWEST);
            let mut position = 0;
            index.history.retain(|entry| {
                position += 1;
                position > newest || entry.pinned || entry.time >= cutoff
            });
            if !open.contains(&index.path.as_path()) {
                index.draft.take_if(|draft| draft.time < cutoff);
            }
            if index.history.is_empty() && index.draft.is_none() {
                fs::remove_file(&file)?;
                File::open(self.root.join("files"))?.sync_all()?;
            } else if (index.history.len(), index.draft.is_some()) != before {
                self.write(&index)?;
            }
            named.extend(index.history.iter().chain(&index.draft).map(|s| s.hash));
        }
        step("prune");
        for blob in fs::read_dir(self.root.join("blobs"))? {
            let blob = blob?;
            if Hash::from_hex(blob.file_name().as_bytes()).is_ok_and(|hash| !named.contains(&hash))
            {
                fs::remove_file(blob.path())?;
            }
        }
        Ok(())
    }

    fn add(
        &self,
        path: &Path,
        bytes: &[u8],
        origin: &str,
        now: SystemTime,
        draft: bool,
    ) -> io::Result<Snapshot> {
        let hash = blake3::hash(bytes);
        let _lock = self.lock()?;
        let mut index = self.index(path)?;
        let current = if draft {
            index.draft.as_ref()
        } else {
            index.history.last()
        };
        if let Some(current) = current
            && (current.hash, current.origin.as_str()) == (hash, origin)
        {
            return Ok(current.clone());
        }
        let snapshot = Snapshot {
            id: index
                .history
                .iter()
                .chain(&index.draft)
                .map(|s| s.id)
                .max()
                .unwrap_or(0)
                + 1,
            hash,
            time: UNIX_EPOCH + Duration::from_millis(millis(now)),
            origin: origin.to_owned(),
            pinned: false,
        };
        if self.get(&hash).is_err() {
            let hex = hash.to_hex();
            self.replace("blobs", hex.as_str(), &zstd::encode_all(bytes, 0)?)?;
        }
        step("put");
        if draft {
            index.draft = Some(snapshot.clone());
        } else {
            index.history.push(snapshot.clone());
        }
        self.write(&index)?;
        Ok(snapshot)
    }

    fn lock(&self) -> io::Result<File> {
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(self.root.join("lock"))?;
        loop {
            match file.lock() {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                locked => return locked.map(|()| file),
            }
        }
    }

    fn index(&self, path: &Path) -> io::Result<Index> {
        let file = self.root.join("files").join(key(path));
        match fs::read(&file) {
            Ok(bytes) => parse(&bytes)
                .filter(|index| index.path == path)
                .ok_or_else(|| damaged(&file)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Index {
                path: path.to_owned(),
                history: Vec::new(),
                draft: None,
            }),
            Err(error) => Err(error),
        }
    }

    fn write(&self, index: &Index) -> io::Result<()> {
        let mut bytes = HEADER.to_vec();
        bytes.push(b'\n');
        bytes.extend(escape(index.path.as_os_str().as_bytes()));
        bytes.push(b'\n');
        let lines = index
            .history
            .iter()
            .map(|entry| (entry, if entry.pinned { "pinned" } else { "-" }))
            .chain(index.draft.iter().map(|draft| (draft, "draft")));
        for (snapshot, mark) in lines {
            write!(
                bytes,
                "{} {} {} {mark} ",
                snapshot.id,
                snapshot.hash.to_hex(),
                millis(snapshot.time),
            )?;
            bytes.extend(escape(snapshot.origin.as_bytes()));
            bytes.push(b'\n');
        }
        self.replace("files", &key(&index.path), &bytes)
    }

    /// Puts `bytes` at `folder/name` through a synced file in `tmp/`.
    fn replace(&self, folder: &str, name: &str, bytes: &[u8]) -> io::Result<()> {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let temp = self
            .root
            .join("tmp")
            .join(format!("{}.{stamp:x}", std::process::id()));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)?;
        let target = self.root.join(folder).join(name);
        let written = file
            .write_all(bytes)
            .and_then(|()| file.sync_all())
            .and_then(|()| {
                step(folder);
                fs::rename(&temp, &target)
            });
        if written.is_err() {
            // What this leaves, prune clears.
            let _ = fs::remove_file(&temp);
        }
        written?;
        File::open(self.root.join(folder))?.sync_all()
    }
}

/// The index file name for `path`.
fn key(path: &Path) -> String {
    blake3::hash(path.as_os_str().as_bytes())
        .to_hex()
        .to_string()
}

fn millis(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn damaged(file: &Path) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("{} is damaged", file.display()),
    )
}

/// Escapes `%` and newlines, which end an index line.
fn escape(bytes: &[u8]) -> Vec<u8> {
    let mut escaped = Vec::with_capacity(bytes.len());
    for &byte in bytes {
        match byte {
            b'%' => escaped.extend_from_slice(b"%25"),
            b'\n' => escaped.extend_from_slice(b"%0A"),
            _ => escaped.push(byte),
        }
    }
    escaped
}

fn unescape(mut bytes: &[u8]) -> Option<Vec<u8>> {
    let mut plain = Vec::with_capacity(bytes.len());
    while let Some((&byte, rest)) = bytes.split_first() {
        if byte == b'%' {
            let hex = std::str::from_utf8(rest.get(..2)?).ok()?;
            plain.push(u8::from_str_radix(hex, 16).ok()?);
            bytes = &rest[2..];
        } else {
            plain.push(byte);
            bytes = rest;
        }
    }
    Some(plain)
}

/// Reads an index: a header line, the escaped path, then a line per
/// snapshot with its id, hash, milliseconds, mark (`-`, `pinned` or
/// `draft`) and escaped origin.
fn parse(bytes: &[u8]) -> Option<Index> {
    let mut lines = bytes.strip_suffix(b"\n")?.split(|&byte| byte == b'\n');
    if lines.next()? != HEADER {
        return None;
    }
    let mut index = Index {
        path: PathBuf::from(OsString::from_vec(unescape(lines.next()?)?)),
        history: Vec::new(),
        draft: None,
    };
    let number = |field: &[u8]| std::str::from_utf8(field).ok()?.parse().ok();
    for line in lines {
        let mut fields = line.splitn(5, |&byte| byte == b' ');
        let id = number(fields.next()?)?;
        let hash = Hash::from_hex(fields.next()?).ok()?;
        let time = UNIX_EPOCH + Duration::from_millis(number(fields.next()?)?);
        let mark = fields.next()?;
        let origin = String::from_utf8(unescape(fields.next()?)?).ok()?;
        let snapshot = Snapshot {
            id,
            hash,
            time,
            origin,
            pinned: mark == b"pinned",
        };
        match mark {
            b"-" | b"pinned" => index.history.push(snapshot),
            b"draft" if index.draft.is_none() => index.draft = Some(snapshot),
            _ => return None,
        }
    }
    Some(index)
}

/// Test builds die at the step DEWLINE_STORE_KILL names, as a kill would.
#[cfg(test)]
fn step(name: &str) {
    if std::env::var_os("DEWLINE_STORE_KILL").is_some_and(|kill| kill == name) {
        // SAFETY: kill and getpid have no preconditions.
        unsafe {
            libc::kill(libc::getpid(), libc::SIGKILL);
        }
        // The signal can land after kill returns; this thread must not run on.
        loop {
            std::thread::park();
        }
    }
}

#[cfg(not(test))]
fn step(_: &str) {}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::collections::HashMap;
    use std::os::unix::fs::MetadataExt;
    use std::os::unix::process::ExitStatusExt;
    use std::process::{Command, Stdio};

    const NOTES: &str = "/Users/me/notes/launch-plan.md";
    const OTHER: &str = "/Users/me/notes/archive/launch-plan.md";

    fn hours(hours: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(1_790_000_000 + hours * 60 * 60)
    }

    fn day(days: u64) -> SystemTime {
        hours(days * 24)
    }

    fn store() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(&dir.path().join("snapshots")).unwrap();
        (dir, store)
    }

    fn names(folder: &Path) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(folder)
            .unwrap()
            .map(|item| item.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    }

    fn blobs(store: &Store) -> HashSet<Hash> {
        names(&store.root.join("blobs"))
            .iter()
            .map(|name| Hash::from_hex(name).unwrap())
            .collect()
    }

    /// The hashes every index names, each checked to be in a blob that holds its bytes.
    fn intact(store: &Store) -> HashSet<Hash> {
        let mut named = HashSet::new();
        for name in names(&store.root.join("files")) {
            let index = parse(&fs::read(store.root.join("files").join(name)).unwrap()).unwrap();
            for snapshot in index.history.iter().chain(&index.draft) {
                store.get(&snapshot.hash).unwrap();
                named.insert(snapshot.hash);
            }
        }
        named
    }

    fn ids(store: &Store, path: &str) -> Vec<u64> {
        let history = store.list(Path::new(path)).unwrap();
        history.iter().rev().map(|s| s.id).collect()
    }

    fn child(test: &str, root: &Path, env: &[(&str, &str)]) -> Command {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args(["--exact", test])
            .env("DEWLINE_STORE_ROOT", root)
            .envs(env.iter().copied());
        command
    }

    #[test]
    fn a_snapshot_round_trips() {
        let (_dir, store) = store();
        let notes = Path::new(NOTES);
        let large = b"Ship the beta on Friday.\n".repeat(40_000);
        let binary: Vec<u8> = (0..=255).collect();
        let versions: [&[u8]; 4] = [b"", b"# Notes\r\n", &binary, &large];
        let mut taken = Vec::new();
        for (n, bytes) in (0..).zip(versions) {
            let now = hours(n) + Duration::from_nanos(1_234_567);
            let snapshot = store.put(notes, bytes, "You", now).unwrap();
            assert_eq!(snapshot.hash, blake3::hash(bytes));
            assert_eq!(snapshot.time, hours(n) + Duration::from_millis(1));
            assert_eq!(store.get(&snapshot.hash).unwrap(), bytes);
            taken.push(snapshot);
        }
        taken.reverse();
        let listed = Store::open(&store.root).unwrap().list(notes).unwrap();
        assert_eq!(listed, taken);
        assert_eq!(ids(&store, NOTES), [1, 2, 3, 4]);

        let blob = store
            .root
            .join("blobs")
            .join(blake3::hash(&large).to_hex().as_str());
        assert!(fs::metadata(blob).unwrap().len() < large.len() as u64 / 100);

        // The same bytes from the same writer add nothing; another file shares the blob.
        assert_eq!(
            store.put(notes, &large, "You", hours(9)).unwrap(),
            listed[0]
        );
        store
            .put(Path::new(OTHER), &large, "Claude", hours(9))
            .unwrap();
        assert_eq!(store.list(notes).unwrap(), listed);
        assert_eq!(names(&store.root.join("blobs")).len(), 4);

        let odd = Path::new("/Users/me/100% done\nnotes.md");
        let origin = "Claude 7%\nsession";
        let snapshot = store.put(odd, b"odd", origin, hours(9)).unwrap();
        assert_eq!(store.list(odd).unwrap(), [snapshot]);
        assert_eq!(store.list(odd).unwrap()[0].origin, origin);
    }

    #[test]
    fn only_the_user_pins() {
        let (_dir, store) = store();
        let notes = Path::new(NOTES);
        let first = store.put(notes, b"mine", "You", hours(0)).unwrap();
        let second = store.put(notes, b"claude", "Claude", hours(1)).unwrap();
        let pinned = || -> Vec<bool> {
            let history = store.list(notes).unwrap();
            history.iter().rev().map(|s| s.pinned).collect()
        };
        assert_eq!(pinned(), [false, false]);
        store.pin(notes, &second, true).unwrap();
        store
            .put(notes, b"claude again", "Claude", hours(2))
            .unwrap();
        assert_eq!(pinned(), [false, true, false]);
        store.pin(notes, &first, true).unwrap();
        store.pin(notes, &second, false).unwrap();
        assert_eq!(pinned(), [true, false, false]);

        let draft = store.set_draft(notes, b"unsaved", "You", hours(3)).unwrap();
        let gone = Snapshot {
            id: 99,
            ..first.clone()
        };
        let other = Snapshot {
            hash: blake3::hash(b"other"),
            ..first
        };
        for snapshot in [&gone, &other, &draft] {
            let error = store.pin(notes, snapshot, true).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::NotFound);
        }
    }

    #[test]
    fn a_draft_is_overwritten_in_place() {
        let (_dir, store) = store();
        let notes = Path::new(NOTES);
        store.put(notes, b"# Notes\n", "You", hours(0)).unwrap();
        assert_eq!(store.draft(notes).unwrap(), None);
        let first = store
            .set_draft(notes, b"# Notes\nTyping", "You", hours(1))
            .unwrap();
        assert_eq!(first.id, 2);
        let second = store
            .set_draft(notes, b"# Notes\nTyping on", "You", hours(2))
            .unwrap();
        assert_eq!(store.draft(notes).unwrap().as_ref(), Some(&second));
        assert_eq!(store.get(&second.hash).unwrap(), b"# Notes\nTyping on");
        assert_eq!(
            store
                .set_draft(notes, b"# Notes\nTyping on", "You", hours(3))
                .unwrap(),
            second
        );
        assert_eq!(ids(&store, NOTES), [1]);
        assert_eq!(
            store.put(notes, b"claude", "Claude", hours(4)).unwrap().id,
            4
        );

        // The replaced draft's bytes go with the next prune.
        store.prune(hours(5), &[notes]).unwrap();
        assert!(!blobs(&store).contains(&first.hash));
        assert_eq!(blobs(&store), intact(&store));
    }

    #[test]
    fn prune_keeps_pins_30_days_or_the_newest_50_and_their_blobs() {
        let (_dir, store) = store();
        let (notes, other) = (Path::new(NOTES), Path::new(OTHER));
        let recent = Path::new("/Users/me/notes/today.md");
        let closed = Path::new("/Users/me/notes/closed.md");
        for n in 0..60 {
            let bytes = format!("v{n}");
            store
                .put(notes, bytes.as_bytes(), "Claude", day(n))
                .unwrap();
        }
        let fifth = store.list(notes).unwrap().remove(54);
        assert_eq!(store.get(&fifth.hash).unwrap(), b"v5");
        store.pin(notes, &fifth, true).unwrap();
        store.put(other, b"v3", "Claude", day(3)).unwrap();
        for n in 0..70 {
            let bytes = format!("r{n}");
            let now = hours(80 * 24 + n * 6);
            store.put(recent, bytes.as_bytes(), "Claude", now).unwrap();
        }
        let open_draft = store.set_draft(notes, b"open", "You", day(1)).unwrap();
        store.set_draft(other, b"old", "You", day(2)).unwrap();
        store.set_draft(closed, b"closed", "You", day(2)).unwrap();
        let new_draft = store.set_draft(recent, b"new", "You", day(99)).unwrap();
        let edge = Path::new("/Users/me/notes/edge.md");
        let line = day(100) - Duration::from_secs(30 * 24 * 60 * 60);
        store
            .put(edge, b"before", "Claude", line - Duration::from_millis(1))
            .unwrap();
        store.put(edge, b"on", "Claude", line).unwrap();
        for n in 0..50 {
            let bytes = format!("e{n}");
            store
                .put(edge, bytes.as_bytes(), "Claude", day(80))
                .unwrap();
        }

        store.prune(day(100), &[notes]).unwrap();
        assert_eq!(
            ids(&store, "/Users/me/notes/edge.md"),
            (2..=52).collect::<Vec<_>>()
        );
        // v5 is pinned and v10 to v59 are the newest 50.
        assert_eq!(
            ids(&store, NOTES),
            [6].into_iter().chain(11..=60).collect::<Vec<_>>()
        );
        assert_eq!(ids(&store, OTHER), [1]);
        assert_eq!(
            ids(&store, "/Users/me/notes/today.md"),
            (1..=70).collect::<Vec<_>>()
        );
        assert_eq!(store.draft(notes).unwrap(), Some(open_draft));
        assert_eq!(store.draft(other).unwrap(), None);
        assert_eq!(store.draft(recent).unwrap(), Some(new_draft));
        assert!(!store.root.join("files").join(key(closed)).exists());

        let blobs = blobs(&store);
        for gone in ["v0", "v1", "v2", "v4", "v6", "v9", "old", "closed"] {
            assert!(!blobs.contains(&blake3::hash(gone.as_bytes())), "{gone}");
        }
        assert!(blobs.contains(&blake3::hash(b"v3")));
        assert_eq!(blobs, intact(&store));
    }

    #[test]
    fn a_kill_between_steps_leaves_no_dangling_entry() {
        let test = "store::tests::a_kill_between_steps_leaves_no_dangling_entry";
        let (notes, other) = (Path::new(NOTES), Path::new(OTHER));
        let run = |store: &Store, op: &str| match op {
            "put" => store.put(notes, b"new", "Unknown app", day(60)).map(drop),
            "draft" => store.set_draft(notes, b"new", "You", day(60)).map(drop),
            "prune" => store.prune(day(100), &[]),
            _ => store.moved(notes, other),
        };
        if let Some(root) = std::env::var_os("DEWLINE_STORE_ROOT") {
            let store = Store::open(Path::new(&root)).unwrap();
            run(&store, &std::env::var("DEWLINE_STORE_OP").unwrap()).unwrap();
            return;
        }
        let cases = [
            ("put", "blobs"),
            ("put", "put"),
            ("put", "files"),
            ("draft", "put"),
            ("draft", "files"),
            ("prune", "prune"),
            ("moved", "moved"),
        ];
        for (op, step) in cases {
            let (_dir, store) = store();
            for n in 0..55 {
                let bytes = format!("v{n}");
                store
                    .put(notes, bytes.as_bytes(), "Claude", day(n))
                    .unwrap();
            }
            store.set_draft(notes, b"typed", "You", day(55)).unwrap();
            store.put(other, b"archived", "You", day(1)).unwrap();
            let (history, draft, archived, stored) = (
                store.list(notes).unwrap(),
                store.draft(notes).unwrap(),
                store.list(other).unwrap(),
                blobs(&store),
            );

            let env = [("DEWLINE_STORE_OP", op), ("DEWLINE_STORE_KILL", step)];
            let killed = child(test, &store.root, &env).output().unwrap();
            assert_eq!(
                killed.status.signal(),
                Some(libc::SIGKILL),
                "{op} {step}: {}",
                String::from_utf8_lossy(&killed.stdout)
            );
            let named = intact(&store);
            let temps = names(&store.root.join("tmp")).len();
            let with_new: HashSet<_> = stored
                .iter()
                .copied()
                .chain([blake3::hash(b"new")])
                .collect();
            match step {
                "blobs" => assert_eq!((blobs(&store), temps), (stored.clone(), 1)),
                "put" => assert_eq!((blobs(&store), temps), (with_new, 0)),
                "files" => assert_eq!((blobs(&store), temps), (with_new, 1)),
                "prune" => {
                    // The entries and the draft went and their blobs stayed.
                    assert_eq!(blobs(&store), stored);
                    assert_eq!(ids(&store, NOTES), (6..=55).collect::<Vec<_>>());
                    assert_eq!(store.draft(notes).unwrap(), None);
                }
                _ => {
                    let merged = store.list(other).unwrap();
                    assert_eq!(merged.len(), history.len() + 1);
                    assert_eq!(
                        store.draft(other).unwrap().map(|d| d.hash),
                        draft.as_ref().map(|d| d.hash)
                    );
                }
            }
            if step != "prune" {
                assert_eq!(store.list(notes).unwrap(), history, "{op} {step}");
                assert_eq!(store.draft(notes).unwrap(), draft, "{op} {step}");
            }
            if op != "moved" {
                assert_eq!(store.list(other).unwrap(), archived, "{op} {step}");
            }

            // A prune clears what the kill left, and the operation runs again.
            store.prune(day(0), &[]).unwrap();
            assert_eq!(names(&store.root.join("tmp")).len(), 0);
            assert_eq!(blobs(&store), intact(&store));
            assert!(named.is_subset(&blobs(&store)));
            run(&store, op).unwrap();
            assert!(intact(&store).is_subset(&blobs(&store)));
            match op {
                "put" => assert_eq!(store.list(notes).unwrap().len(), history.len() + 1),
                "draft" => {
                    let draft = store.draft(notes).unwrap().unwrap();
                    assert_eq!(store.get(&draft.hash).unwrap(), b"new");
                }
                "moved" => {
                    assert!(store.list(notes).unwrap().is_empty());
                    assert_eq!(store.list(other).unwrap().len(), history.len() + 1);
                    let moved = store.draft(other).unwrap().map(|d| d.hash);
                    assert_eq!(moved, draft.as_ref().map(|d| d.hash));
                }
                _ => {}
            }
        }
    }

    #[test]
    fn folders_are_0700_and_files_0600() {
        let test = "store::tests::folders_are_0700_and_files_0600";
        let Some(root) = std::env::var_os("DEWLINE_STORE_ROOT") else {
            // The umask holds for the whole process, so this runs alone in a child without one.
            let dir = tempfile::tempdir().unwrap();
            let output = child(test, dir.path(), &[]).output().unwrap();
            let report = String::from_utf8_lossy(&output.stdout);
            assert!(
                output.status.success() && report.contains("1 passed"),
                "{report}"
            );
            return;
        };
        // SAFETY: this child process runs only this test.
        unsafe {
            libc::umask(0);
        }
        let root = PathBuf::from(root).join("snapshots");
        for folder in [&root, &root.join("blobs")] {
            DirBuilder::new().mode(0o755).create(folder).unwrap();
        }
        let store = Store::open(&root).unwrap();
        let notes = Path::new(NOTES);
        let mine = store.put(notes, b"# Notes\n", "You", day(0)).unwrap();
        store
            .put(notes, b"# Notes\nClaude\n", "Claude", day(1))
            .unwrap();
        store.set_draft(notes, b"# Draft\n", "You", day(1)).unwrap();
        store.pin(notes, &mine, true).unwrap();
        store.moved(notes, Path::new(OTHER)).unwrap();
        store.prune(day(2), &[]).unwrap();

        let mut files = Vec::new();
        let mut folders = vec![root.clone()];
        while let Some(folder) = folders.pop() {
            let mode = fs::metadata(&folder).unwrap().mode() & 0o7777;
            assert_eq!(mode, 0o700, "{}", folder.display());
            for item in fs::read_dir(&folder).unwrap() {
                let path = item.unwrap().path();
                let metadata = fs::symlink_metadata(&path).unwrap();
                if metadata.is_dir() {
                    folders.push(path);
                } else {
                    assert_eq!(metadata.mode() & 0o7777, 0o600, "{}", path.display());
                    files.push(path.strip_prefix(&root).unwrap().to_owned());
                }
            }
        }
        files.sort();
        let blob =
            |bytes: &[u8]| PathBuf::from("blobs").join(blake3::hash(bytes).to_hex().as_str());
        let mut expected = vec![
            blob(b"# Notes\n"),
            blob(b"# Notes\nClaude\n"),
            blob(b"# Draft\n"),
            PathBuf::from("files").join(key(Path::new(OTHER))),
            PathBuf::from("lock"),
        ];
        expected.sort();
        assert_eq!(files, expected);
    }

    #[test]
    fn writers_in_three_processes_take_turns() {
        let test = "store::tests::writers_in_three_processes_take_turns";
        let notes = Path::new(NOTES);
        let puts = 40;
        if let Some(root) = std::env::var_os("DEWLINE_STORE_ROOT") {
            let store = Store::open(&PathBuf::from(root).join("snapshots")).unwrap();
            let writer = std::env::var("DEWLINE_STORE_WRITER").unwrap();
            for n in 0..puts {
                if writer == "prune" {
                    store.prune(day(0), &[]).unwrap();
                    continue;
                }
                let bytes = format!("{writer} {n}");
                let snapshot = store.put(notes, bytes.as_bytes(), &writer, day(0)).unwrap();
                if n % 4 == 0 {
                    store.pin(notes, &snapshot, true).unwrap();
                }
                let draft = format!("{writer} draft {n}");
                store
                    .set_draft(notes, draft.as_bytes(), &writer, day(0))
                    .unwrap();
            }
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let writers = ["app", "cli", "prune"].map(|writer| {
            child(test, dir.path(), &[("DEWLINE_STORE_WRITER", writer)])
                .stdout(Stdio::piped())
                .spawn()
                .unwrap()
        });
        for writer in writers {
            let output = writer.wait_with_output().unwrap();
            let report = String::from_utf8_lossy(&output.stdout);
            assert!(
                output.status.success() && report.contains("1 passed"),
                "{report}"
            );
        }
        let store = Store::open(&dir.path().join("snapshots")).unwrap();
        let history = store.list(notes).unwrap();
        assert_eq!(history.len(), 2 * puts);
        for writer in ["app", "cli"] {
            let theirs: Vec<_> = history
                .iter()
                .rev()
                .filter(|s| s.origin == writer)
                .map(|s| (store.get(&s.hash).unwrap(), s.pinned))
                .collect();
            let expected: Vec<_> = (0..puts)
                .map(|n| (format!("{writer} {n}").into_bytes(), n % 4 == 0))
                .collect();
            assert_eq!(theirs, expected);
        }
        let draft = store.draft(notes).unwrap().unwrap();
        let last = String::from_utf8(store.get(&draft.hash).unwrap()).unwrap();
        assert_eq!(last, format!("{} draft {}", draft.origin, puts - 1));
        let ids: HashSet<_> = history.iter().chain([&draft]).map(|s| s.id).collect();
        assert_eq!(ids.len(), history.len() + 1);
        store.prune(day(0), &[]).unwrap();
        assert_eq!(blobs(&store), intact(&store));
    }

    #[test]
    fn a_failed_write_leaves_nothing_behind() {
        let test = "store::tests::a_failed_write_leaves_nothing_behind";
        let Some(root) = std::env::var_os("DEWLINE_STORE_ROOT") else {
            // The file size limit holds for the whole process, so this runs alone in a child.
            let dir = tempfile::tempdir().unwrap();
            let output = child(test, dir.path(), &[]).output().unwrap();
            let report = String::from_utf8_lossy(&output.stdout);
            assert!(
                output.status.success() && report.contains("1 passed"),
                "{report}"
            );
            return;
        };
        let store = Store::open(&PathBuf::from(root).join("snapshots")).unwrap();
        let notes = Path::new(NOTES);
        store.put(notes, b"# Notes\n", "You", day(0)).unwrap();
        // SAFETY: this child process runs only this test.
        unsafe {
            libc::signal(libc::SIGXFSZ, libc::SIG_IGN);
            let mut limit = std::mem::zeroed::<libc::rlimit>();
            assert_eq!(libc::getrlimit(libc::RLIMIT_FSIZE, &mut limit), 0);
            limit.rlim_cur = 4096;
            assert_eq!(libc::setrlimit(libc::RLIMIT_FSIZE, &limit), 0);
        }
        let mut x = 0x9E37_79B9u32;
        let noise: Vec<u8> = (0..65536)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                x as u8
            })
            .collect();
        assert!(store.put(notes, &noise, "You", day(1)).is_err());
        assert!(store.set_draft(notes, &noise, "You", day(1)).is_err());
        assert!(names(&store.root.join("tmp")).is_empty());
        assert_eq!(ids(&store, NOTES), [1]);
        assert_eq!(store.draft(notes).unwrap(), None);
    }

    #[test]
    fn a_moved_file_keeps_its_snapshots() {
        let (_dir, store) = store();
        let (notes, other) = (Path::new(NOTES), Path::new(OTHER));
        store.put(other, b"old 1", "git", day(1)).unwrap();
        store.put(notes, b"mine", "You", day(2)).unwrap();
        store.set_draft(other, b"old draft", "You", day(3)).unwrap();
        let mine = store.list(notes).unwrap().remove(0);
        store.pin(notes, &mine, true).unwrap();
        store.put(other, b"old 2", "git", day(4)).unwrap();
        store.put(notes, b"claude", "Claude", day(5)).unwrap();
        store.set_draft(notes, b"draft", "You", day(6)).unwrap();
        store.moved(notes, other).unwrap();

        assert!(store.list(notes).unwrap().is_empty());
        assert_eq!(store.draft(notes).unwrap(), None);
        let history = store.list(other).unwrap();
        let read: Vec<_> = history
            .iter()
            .rev()
            .map(|s| (s.id, store.get(&s.hash).unwrap(), s.pinned))
            .collect();
        let expected: Vec<(u64, Vec<u8>, bool)> = vec![
            (1, b"old 1".into(), false),
            (2, b"mine".into(), true),
            (3, b"old draft".into(), false),
            (4, b"old 2".into(), false),
            (5, b"claude".into(), false),
        ];
        assert_eq!(read, expected);
        let draft = store.draft(other).unwrap().unwrap();
        assert_eq!(
            (draft.id, store.get(&draft.hash).unwrap()),
            (6, b"draft".to_vec())
        );
        assert_eq!(names(&store.root.join("files")), [key(other)]);

        store.moved(other, other).unwrap();
        store.moved(notes, other).unwrap();
        assert_eq!(store.list(other).unwrap(), history);
    }

    #[test]
    fn damage_is_an_error_and_stops_prune_before_it_deletes() {
        let (_dir, store) = store();
        let (notes, other) = (Path::new(NOTES), Path::new(OTHER));
        let mine = store.put(notes, b"# Notes\n", "You", day(0)).unwrap();
        store.put(other, b"# Other\n", "You", day(0)).unwrap();
        let blob = store.root.join("blobs").join(mine.hash.to_hex().as_str());
        fs::write(&blob, zstd::encode_all(&b"# Not notes\n"[..], 0).unwrap()).unwrap();
        let error = store.get(&mine.hash).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        // The same bytes, put again, mend the blob.
        store.put(other, b"# Notes\n", "You", day(1)).unwrap();
        assert_eq!(store.get(&mine.hash).unwrap(), b"# Notes\n");

        // Hidden files are passed over; any other file that is not an index stops prune.
        let files = store.root.join("files");
        fs::write(files.join(".DS_Store"), b"Finder").unwrap();
        store.prune(day(400), &[]).unwrap();
        let before = blobs(&store);
        fs::write(files.join("from-a-newer-dewline"), b"dewline snapshots 2\n").unwrap();
        let error = store.prune(day(400), &[]).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        fs::remove_file(files.join("from-a-newer-dewline")).unwrap();

        fs::write(
            files.join(key(notes)),
            b"dewline snapshots 1\n/Users/me/notes/launch-plan.md\n1 not-a-hash\n",
        )
        .unwrap();
        for error in [
            store.list(notes).unwrap_err(),
            store.prune(day(400), &[]).unwrap_err(),
            store.put(notes, b"# Notes 2\n", "You", day(1)).unwrap_err(),
        ] {
            assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        }
        assert_eq!(blobs(&store), before);
    }

    #[derive(Clone, Debug)]
    enum Op {
        Put {
            file: usize,
            version: u8,
            claude: bool,
            hours: u64,
        },
        Burst {
            file: usize,
            count: u64,
        },
        Draft {
            file: usize,
            version: u8,
        },
        Pin {
            file: usize,
            entry: prop::sample::Index,
            pinned: bool,
        },
        Moved {
            from: usize,
            to: usize,
        },
        Prune {
            days: u64,
            open: [bool; 2],
        },
    }

    fn op() -> impl Strategy<Value = Op> {
        prop_oneof![
            8 => (0..2usize, 0..6u8, any::<bool>(), 0..72u64).prop_map(
                |(file, version, claude, hours)| Op::Put { file, version, claude, hours }
            ),
            1 => (0..2usize, 1..60u64).prop_map(|(file, count)| Op::Burst { file, count }),
            2 => (0..2usize, 0..6u8).prop_map(|(file, version)| Op::Draft { file, version }),
            3 => (0..2usize, any::<prop::sample::Index>(), any::<bool>())
                .prop_map(|(file, entry, pinned)| Op::Pin { file, entry, pinned }),
            1 => (0..2usize, 0..2usize).prop_map(|(from, to)| Op::Moved { from, to }),
            3 => (0..40u64, any::<[bool; 2]>()).prop_map(|(days, open)| Op::Prune { days, open }),
        ]
    }

    /// The rules the store keeps, on plain vectors.
    #[derive(Default)]
    struct Model {
        history: [Vec<Snapshot>; 2],
        draft: [Option<Snapshot>; 2],
        bytes: HashMap<Hash, Vec<u8>>,
        clock: u64,
    }

    impl Model {
        fn add(&mut self, file: usize, bytes: Vec<u8>, origin: &str, draft: bool) {
            let hash = blake3::hash(&bytes);
            self.bytes.insert(hash, bytes);
            let current = if draft {
                self.draft[file].as_ref()
            } else {
                self.history[file].last()
            };
            if current.is_some_and(|s| (s.hash, s.origin.as_str()) == (hash, origin)) {
                return;
            }
            let ids = self.history[file]
                .iter()
                .chain(&self.draft[file])
                .map(|s| s.id);
            let snapshot = Snapshot {
                id: ids.max().unwrap_or(0) + 1,
                hash,
                time: hours(self.clock),
                origin: origin.to_owned(),
                pinned: false,
            };
            if draft {
                self.draft[file] = Some(snapshot);
            } else {
                self.history[file].push(snapshot);
            }
        }

        fn moved(&mut self, from: usize, to: usize) {
            if from == to || (self.history[from].is_empty() && self.draft[from].is_none()) {
                return;
            }
            let mut there: Vec<_> = std::mem::take(&mut self.history[to]);
            if let Some(draft) = self.draft[from].take()
                && let Some(displaced) = self.draft[to].replace(draft)
            {
                there.push(displaced);
                there.sort_by_key(|s| s.time);
            }
            let mut merged: Vec<_> = there
                .into_iter()
                .map(|s| (0, s))
                .chain(
                    std::mem::take(&mut self.history[from])
                        .into_iter()
                        .map(|s| (1, s)),
                )
                .collect();
            merged.sort_by_key(|(side, s)| (s.time, *side));
            self.history[to] = merged.into_iter().map(|(_, s)| s).collect();
            let (history, draft) = (&mut self.history[to], &mut self.draft[to]);
            for (id, snapshot) in (1..).zip(history.iter_mut().chain(draft)) {
                snapshot.id = id;
            }
        }

        fn prune(&mut self, open: [bool; 2]) {
            let cutoff = hours(self.clock) - Duration::from_secs(30 * 24 * 60 * 60);
            let files = self.history.iter_mut().zip(&mut self.draft).zip(open);
            for ((history, draft), open) in files {
                let newest = history.len().saturating_sub(50);
                *history = history
                    .iter()
                    .enumerate()
                    .filter(|(at, s)| *at >= newest || s.pinned || s.time >= cutoff)
                    .map(|(_, s)| s.clone())
                    .collect();
                if !open && draft.as_ref().is_some_and(|d| d.time < cutoff) {
                    *draft = None;
                }
            }
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(16))]

        #[test]
        fn random_puts_drafts_pins_moves_and_prunes_keep_the_rules(
            ops in prop::collection::vec(op(), 1..40),
        ) {
            let (_dir, store) = store();
            let paths = [Path::new(NOTES), Path::new(OTHER)];
            let mut model = Model::default();
            for op in ops {
                let pruned = matches!(op, Op::Prune { .. });
                match op {
                    Op::Put { file, version, claude, hours: later } => {
                        model.clock += later;
                        let origin = if claude { "Claude" } else { "Unknown app" };
                        let bytes = format!("version {version}").into_bytes();
                        store.put(paths[file], &bytes, origin, hours(model.clock)).unwrap();
                        model.add(file, bytes, origin, false);
                    }
                    Op::Burst { file, count } => {
                        for n in 0..count {
                            model.clock += 1;
                            let bytes = format!("burst {} {n}", model.clock).into_bytes();
                            store.put(paths[file], &bytes, "Claude", hours(model.clock)).unwrap();
                            model.add(file, bytes, "Claude", false);
                        }
                    }
                    Op::Draft { file, version } => {
                        let bytes = format!("version {version}").into_bytes();
                        store.set_draft(paths[file], &bytes, "You", hours(model.clock)).unwrap();
                        model.add(file, bytes, "You", true);
                    }
                    Op::Pin { file, entry, pinned } => {
                        if !model.history[file].is_empty() {
                            let at = entry.index(model.history[file].len());
                            store.pin(paths[file], &model.history[file][at], pinned).unwrap();
                            model.history[file][at].pinned = pinned;
                        }
                    }
                    Op::Moved { from, to } => {
                        store.moved(paths[from], paths[to]).unwrap();
                        model.moved(from, to);
                    }
                    Op::Prune { days, open } => {
                        model.clock += days * 24;
                        let open: Vec<_> = (0..2).filter(|&f| open[f]).map(|f| paths[f]).collect();
                        store.prune(hours(model.clock), &open).unwrap();
                        model.prune([0, 1].map(|f| open.contains(&paths[f])));
                    }
                }
                let mut named = HashSet::new();
                for (file, path) in paths.iter().enumerate() {
                    let expected: Vec<_> = model.history[file].iter().rev().cloned().collect();
                    prop_assert_eq!(store.list(path).unwrap(), expected);
                    prop_assert_eq!(store.draft(path).unwrap(), model.draft[file].clone());
                    for snapshot in model.history[file].iter().chain(&model.draft[file]) {
                        prop_assert_eq!(&store.get(&snapshot.hash).unwrap(), &model.bytes[&snapshot.hash]);
                        named.insert(snapshot.hash);
                    }
                }
                if pruned {
                    prop_assert_eq!(blobs(&store), named);
                    prop_assert_eq!(names(&store.root.join("tmp")).len(), 0);
                }
            }
        }
    }
}
