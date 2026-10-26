use std::ffi::{c_int, c_void};
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// A change seen this soon after git releases the index lock counts as seen
/// under it.
pub const RELEASE_GRACE: Duration = Duration::from_millis(150);
/// A lock held longer covers no more changes: git crashed or someone else
/// made it.
pub const LOCK_WAIT: Duration = Duration::from_secs(10);
/// Larger index files are not read.
const MAX_INDEX: u64 = 256 << 20;
/// HEAD, ORIG_HEAD and a worktree's `.git` file are one short line.
const MAX_LINE_FILE: u64 = 4096;
/// Lock spans kept for changes that wait for the lock.
const SPANS: usize = 16;

/// A git object id, SHA-1.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Oid(pub [u8; 20]);

impl fmt::Display for Oid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.iter().try_for_each(|byte| write!(f, "{byte:02x}"))
    }
}

/// CC_SHA1_CTX.
#[repr(C)]
#[derive(Default)]
struct Sha1Context {
    h: [u32; 5],
    nl: u32,
    nh: u32,
    data: [u32; 16],
    num: c_int,
}

// CommonCrypto, part of libSystem.
unsafe extern "C" {
    fn CC_SHA1_Init(context: *mut Sha1Context) -> c_int;
    fn CC_SHA1_Update(context: *mut Sha1Context, data: *const c_void, len: u32) -> c_int;
    fn CC_SHA1_Final(digest: *mut u8, context: *mut Sha1Context) -> c_int;
}

/// The id git gives `bytes` as a blob: the SHA-1 of `blob <length>\0` and
/// the bytes.
pub fn blob_id(bytes: &[u8]) -> Oid {
    let header = format!("blob {}\0", bytes.len());
    let mut context = Sha1Context::default();
    let mut id = [0u8; 20];
    // SAFETY: the context has CC_SHA1_CTX's layout and outlives the calls,
    // each chunk's length fits CC_LONG, and `id` holds the 20-byte digest.
    unsafe {
        CC_SHA1_Init(&mut context);
        let chunks = header.as_bytes().chunks(u32::MAX as usize);
        for chunk in chunks.chain(bytes.chunks(u32::MAX as usize)) {
            CC_SHA1_Update(&mut context, chunk.as_ptr().cast(), chunk.len() as u32);
        }
        CC_SHA1_Final(id.as_mut_ptr(), &mut context);
    }
    Oid(id)
}

/// What a repository is doing, read from its gitdir.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct State {
    /// HEAD's line: `ref: refs/heads/<branch>`, or a commit id when detached.
    pub head: Option<String>,
    /// The commit that reset, merge, pull and rebase leave in ORIG_HEAD.
    pub orig_head: Option<String>,
    /// Whether `index.lock` exists: git is changing the index.
    pub locked: bool,
    /// Whether a rebase is under way or stopped.
    pub rebasing: bool,
}

/// The index entry for one file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Entry {
    /// Stage 0: the blob the index holds for the file.
    Staged(Oid),
    /// Stages 1 to 3: a merge left the file unmerged.
    Unmerged,
    /// No entry, or one only `git add -N` made.
    Untracked,
    /// The index can't say: unreadable, damaged, split, sparse around the
    /// file, or in a format this reader doesn't know.
    Unknown,
}

/// When the engine saw git hold the index lock, and the index file it saw
/// when the span opened. An open span is still held.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Span {
    from: Instant,
    to: Option<Instant>,
    index: Option<Stamp>,
}

type Stamp = (u64, u64, i64, i64);

/// A working tree and its gitdir.
pub struct Repo {
    gitdir: PathBuf,
    top: PathBuf,
    /// When the engine last looked at the lock, and the index file it saw.
    sampled: Option<(Instant, Option<Stamp>)>,
    spans: Vec<Span>,
}

impl Repo {
    /// The repository whose working tree holds `path`, a realpath: the
    /// nearest folder above it with a `.git` folder, or a `.git` file that
    /// names the gitdir, as linked worktrees and submodules have. As for git,
    /// a gitdir without HEAD is no repository.
    pub fn find(path: &Path) -> Option<Repo> {
        for top in path.ancestors().skip(1) {
            let dot = top.join(".git");
            let Ok(metadata) = fs::metadata(&dot) else {
                continue;
            };
            let gitdir = if metadata.is_dir() {
                dot
            } else {
                linked_gitdir(&dot, top)?
            };
            if !gitdir.join("HEAD").is_file() {
                if metadata.is_dir() {
                    continue;
                }
                return None;
            }
            return Some(Repo {
                gitdir,
                top: top.to_path_buf(),
                sampled: None,
                spans: Vec::new(),
            });
        }
        None
    }

    /// The folder that holds HEAD, the index and its lock; the engine
    /// watches it.
    pub fn gitdir(&self) -> &Path {
        &self.gitdir
    }

    pub fn state(&self) -> State {
        let line = |name: &str| {
            let bytes = read_file(&self.gitdir.join(name), MAX_LINE_FILE).ok()?;
            Some(String::from_utf8(bytes).ok()?.lines().next()?.to_owned())
        };
        State {
            head: line("HEAD"),
            orig_head: line("ORIG_HEAD"),
            locked: self.gitdir.join("index.lock").exists(),
            rebasing: ["rebase-merge", "rebase-apply"]
                .iter()
                .any(|folder| self.gitdir.join(folder).is_dir()),
        }
    }

    /// The index entry for `path`, a realpath.
    pub fn entry(&self, path: &Path) -> Entry {
        let Ok(name) = path.strip_prefix(&self.top) else {
            return Entry::Untracked;
        };
        match read_file(&self.gitdir.join("index"), MAX_INDEX) {
            Ok(index) => lookup(&index, name.as_os_str().as_bytes()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Entry::Untracked,
            Err(_) => Entry::Unknown,
        }
    }

    /// Notes whether git holds the index lock at `now`. The engine calls this
    /// on every event in the gitdir, and when it sees a change in the working
    /// tree, before it asks `wrote` about that change. A lock taken and
    /// released between two calls leaves a new index file, and counts as held
    /// from the earlier call to this one. A lock released without a new index
    /// file wrote nothing, and counts for nothing.
    pub fn sample(&mut self, now: Instant) {
        let locked = self.gitdir.join("index.lock").exists();
        let index = fs::metadata(self.gitdir.join("index"))
            .ok()
            .map(|index| (index.dev(), index.ino(), index.mtime(), index.mtime_nsec()));
        self.saw(locked, index, now);
    }

    fn saw(&mut self, locked: bool, index: Option<Stamp>, now: Instant) {
        let previous = self.sampled.replace((now, index));
        let replaced = previous.is_some_and(|(_, before)| before != index);
        let since = previous.map_or(now, |(at, _)| at);
        if let Some(span) = self.spans.last_mut()
            && span.to.is_none()
        {
            if !locked {
                if span.index == index {
                    self.spans.pop();
                } else {
                    span.to = Some(now);
                }
            }
            return;
        }
        if replaced {
            // Git takes the lock for no longer than `LOCK_WAIT` without the
            // engine seeing it in between.
            let from = now
                .checked_sub(LOCK_WAIT)
                .map_or(since, |floor| since.max(floor));
            self.spans.push(Span {
                from,
                to: Some(now),
                index: None,
            });
        }
        if locked {
            self.spans.push(Span {
                from: now,
                to: None,
                index,
            });
        }
        if self.spans.len() > SPANS {
            self.spans.remove(0);
        }
    }

    fn covers(&self, seen: Instant) -> bool {
        self.spans.iter().any(|span| {
            let end = span
                .to
                .map_or(span.from + LOCK_WAIT, |to| to + RELEASE_GRACE);
            span.from <= seen && seen <= end
        })
    }

    /// Whether git wrote `bytes`, the change to `path` seen at `seen`: it was
    /// seen while git held the index lock, for at most `LOCK_WAIT`, or within
    /// 150 ms of its release, and `bytes` are the blob the index stages for
    /// `path`. False while the lock is held, since the index is the old one
    /// until it is released.
    pub fn wrote(&self, path: &Path, bytes: &[u8], seen: Instant) -> bool {
        !self.gitdir.join("index.lock").exists()
            && self.covers(seen)
            && self.entry(path) == Entry::Staged(blob_id(bytes))
    }
}

/// The gitdir a `.git` file names: `gitdir: <path>`, relative to the file's
/// folder unless absolute.
fn linked_gitdir(dot: &Path, top: &Path) -> Option<PathBuf> {
    let text = String::from_utf8(read_file(dot, MAX_LINE_FILE).ok()?).ok()?;
    let target = text
        .strip_prefix("gitdir: ")?
        .trim_end_matches(['\n', '\r']);
    (!target.is_empty()).then(|| top.join(target))
}

/// Reads a regular file of at most `max` bytes. The open doesn't block, so a
/// FIFO in a hostile repository can't stall the reader.
fn read_file(path: &Path, max: u64) -> io::Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "not a file"));
    }
    let mut bytes = Vec::with_capacity(metadata.len().min(max) as usize);
    file.take(max + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max {
        return Err(io::ErrorKind::FileTooLarge.into());
    }
    Ok(bytes)
}

const EXTENDED: u16 = 0x4000;
const SKIP_WORKTREE: u16 = 0x4000;
const INTENT_TO_ADD: u16 = 0x2000;
const NAME_MASK: u16 = 0x0fff;
const DIRECTORY: u32 = 0o040000;

/// Finds `name` in an index file's bytes, which are untrusted: anything
/// malformed is Unknown.
fn lookup(index: &[u8], name: &[u8]) -> Entry {
    read_index(
        &mut Reader {
            bytes: index,
            at: 0,
        },
        name,
    )
    .unwrap_or(Entry::Unknown)
}

/// Reads index versions 2, 3 and 4, as gitformat-index(5) lays them out,
/// with SHA-1 ids.
fn read_index(index: &mut Reader, name: &[u8]) -> Option<Entry> {
    if index.take(4)? != b"DIRC" {
        return None;
    }
    let version = index.u32()?;
    if !(2..=4).contains(&version) {
        return None;
    }
    let count = index.u32()?;
    let mut found = None;
    let mut sparse = false;
    let mut entry_name = Vec::new();
    for _ in 0..count {
        let start = index.at;
        let stat = index.take(40)?;
        let mode = u32::from_be_bytes(stat.get(24..28)?.try_into().ok()?);
        let id = Oid(index.take(20)?.try_into().ok()?);
        let flags = index.u16()?;
        let extended = if flags & EXTENDED == 0 {
            0
        } else if version >= 3 {
            index.u16()?
        } else {
            return None;
        };
        if extended & !(SKIP_WORKTREE | INTENT_TO_ADD) != 0 {
            return None;
        }
        // Names of 0xfff bytes or more say 0xfff and end at a NUL.
        let length = usize::from(flags & NAME_MASK);
        let exact = length < usize::from(NAME_MASK);
        if version == 4 {
            // The name is the previous one, cut by a varint, plus a suffix.
            let strip = index.varint()?;
            entry_name.truncate(entry_name.len().checked_sub(strip)?);
            entry_name.extend_from_slice(index.until_nul()?);
            if (exact && entry_name.len() != length) || entry_name.len() < length {
                return None;
            }
        } else {
            let named = if exact {
                index.take(length)?
            } else {
                let named = index.peek_until_nul()?;
                if named.len() < length {
                    return None;
                }
                index.take(named.len())?
            };
            // NUL padding to a multiple of eight bytes, at least one.
            let fixed = if flags & EXTENDED == 0 { 62 } else { 64 };
            let end = start.checked_add((fixed + named.len() + 8) & !7)?;
            if index
                .take(end.checked_sub(index.at)?)?
                .iter()
                .any(|&byte| byte != 0)
            {
                return None;
            }
            entry_name.clear();
            entry_name.extend_from_slice(named);
        }
        if mode & 0o170000 == DIRECTORY {
            sparse = true;
        }
        if entry_name != name {
            continue;
        }
        let entry = if flags & 0x3000 != 0 {
            Entry::Unmerged
        } else if extended & SKIP_WORKTREE != 0 {
            Entry::Unknown
        } else if extended & INTENT_TO_ADD != 0 {
            Entry::Untracked
        } else {
            Entry::Staged(id)
        };
        found = match (found, entry) {
            (None, entry) => Some(entry),
            (Some(Entry::Unmerged), Entry::Unmerged) => Some(Entry::Unmerged),
            // Staged twice, or both staged and unmerged.
            _ => return None,
        };
    }
    let mut split = false;
    while index.left() > 20 {
        let signature = index.take(4)?;
        let size = usize::try_from(index.u32()?).ok()?;
        index.take(size)?;
        match signature {
            b"link" => split = true,
            b"sdir" => sparse = true,
            // Optional extensions start with a capital letter.
            [b'A'..=b'Z', ..] => {}
            _ => return None,
        }
    }
    // The trailing checksum. A SHA-256 index has 32 bytes and ends up here.
    if index.left() != 20 {
        return None;
    }
    Some(match found {
        _ if split => Entry::Unknown,
        Some(entry) => entry,
        None if sparse => Entry::Unknown,
        None => Entry::Untracked,
    })
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn left(&self) -> usize {
        self.bytes.len() - self.at
    }

    fn take(&mut self, length: usize) -> Option<&'a [u8]> {
        let bytes = self.bytes.get(self.at..self.at.checked_add(length)?)?;
        self.at += length;
        Some(bytes)
    }

    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_be_bytes(self.take(2)?.try_into().ok()?))
    }

    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_be_bytes(self.take(4)?.try_into().ok()?))
    }

    /// The bytes up to the next NUL, left unread.
    fn peek_until_nul(&self) -> Option<&'a [u8]> {
        let rest = self.bytes.get(self.at..)?;
        rest.get(..rest.iter().position(|&byte| byte == 0)?)
    }

    /// The bytes up to the next NUL, which is read too.
    fn until_nul(&mut self) -> Option<&'a [u8]> {
        let bytes = self.peek_until_nul()?;
        self.take(bytes.len() + 1)?;
        Some(bytes)
    }

    /// Git's offset varint (varint.c), which version 4 cuts names by.
    fn varint(&mut self) -> Option<usize> {
        let mut byte = self.take(1)?[0];
        let mut value = u64::from(byte & 0x7f);
        while byte & 0x80 != 0 {
            value = value.checked_add(1)?;
            if value >> 57 != 0 {
                return None;
            }
            byte = self.take(1)?[0];
            value = (value << 7) | u64::from(byte & 0x7f);
        }
        usize::try_from(value).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::ffi::CString;
    use std::process::{Command, Output};
    use std::sync::OnceLock;
    use tempfile::TempDir;

    /// Runs git with no user or system config, so no identity or setting of
    /// the machine's reaches a fixture.
    fn run(dir: &Path, args: &[&str]) -> Output {
        Command::new("git")
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .args([
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "user.name=test",
            ])
            .args([
                "-c",
                "init.defaultBranch=main",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(args)
            .output()
            .unwrap()
    }

    fn git(dir: &Path, args: &[&str]) -> String {
        let output = run(dir, args);
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    /// A repository with `files` added, at its realpath.
    fn repo(files: &[(&str, &[u8])]) -> (TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        git(&root, &["init", "-q"]);
        for (name, bytes) in files {
            write(&root, name, bytes);
        }
        git(&root, &["add", "-A"]);
        (dir, root)
    }

    fn write(root: &Path, name: &str, bytes: &[u8]) {
        let path = root.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }

    fn staged(root: &Path, name: &str) -> String {
        git(root, &["rev-parse", &format!(":{name}")])
            .trim()
            .to_owned()
    }

    fn mkfifo(path: &Path) {
        let path = CString::new(path.as_os_str().as_bytes()).unwrap();
        // SAFETY: the path outlives the call.
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    }

    const FILES: [(&str, &[u8]); 7] = [
        ("AGENTS.md", b"# Agents\n"),
        ("CLAUDE.md", b"# Claude\r\n\r\nCRLF stays.\r\n"),
        ("docs/plan.md", b"# Plan\n"),
        ("docs/plan-b.md", b"# Plan B\n"),
        ("docs/plans/one.md", b"one\n"),
        ("docs/plans/two.md", b""),
        ("z\u{e9}/caf\u{e9}.md", "caf\u{e9}\n".as_bytes()),
    ];

    #[test]
    fn blob_ids_are_git_hash_object() {
        let dir = tempfile::tempdir().unwrap();
        let big: Vec<u8> = (0..3_000_000u64).map(|i| (i * 7919 % 251) as u8).collect();
        let cases: [&[u8]; 5] = [
            b"",
            b"hello\n",
            b"a\r\nb\r\n",
            &[0, 159, 146, 150, 255],
            &big,
        ];
        for (i, bytes) in cases.into_iter().enumerate() {
            let path = dir.path().join(format!("{i}.bin"));
            fs::write(&path, bytes).unwrap();
            let git = git(dir.path(), &["hash-object", path.to_str().unwrap()]);
            assert_eq!(blob_id(bytes).to_string(), git.trim(), "case {i}");
        }
        assert_eq!(
            blob_id(b"").to_string(),
            "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
        );
    }

    #[test]
    fn index_versions_2_3_and_4_give_the_staged_blob() {
        for version in [2u32, 3, 4] {
            let (_dir, root) = repo(&FILES);
            if version >= 3 {
                // Extended flags: v3 keeps them, and git writes v2 without them.
                write(&root, "docs/later.md", b"later\n");
                git(&root, &["add", "-N", "docs/later.md"]);
                git(
                    &root,
                    &["update-index", "--skip-worktree", "docs/plan-b.md"],
                );
            }
            git(
                &root,
                &["update-index", "--index-version", &version.to_string()],
            );
            let index = fs::read(root.join(".git/index")).unwrap();
            assert_eq!(index[4..8], version.to_be_bytes());
            let repo = Repo::find(&root.join("AGENTS.md")).unwrap();
            for (name, bytes) in FILES {
                let entry = repo.entry(&root.join(name));
                if version >= 3 && name == "docs/plan-b.md" {
                    assert_eq!(entry, Entry::Unknown, "v{version} {name}");
                    continue;
                }
                assert_eq!(entry, Entry::Staged(blob_id(bytes)), "v{version} {name}");
                assert_eq!(blob_id(bytes).to_string(), staged(&root, name));
            }
            let later = repo.entry(&root.join("docs/later.md"));
            assert_eq!(later, Entry::Untracked, "v{version}: intent to add");
            assert_eq!(repo.entry(&root.join("docs/plans")), Entry::Untracked);
            assert_eq!(repo.entry(&root.join("docs/missing.md")), Entry::Untracked);
            assert_eq!(
                repo.entry(Path::new("/elsewhere/AGENTS.md")),
                Entry::Untracked
            );
        }
    }

    #[test]
    fn only_unmerged_entries_are_conflicts() {
        for version in ["2", "4"] {
            let (_dir, root) = repo(&[("CLAUDE.md", b"base\n"), ("notes.md", b"notes\n")]);
            git(&root, &["commit", "-q", "-m", "base"]);
            git(&root, &["checkout", "-q", "-b", "theirs"]);
            write(&root, "CLAUDE.md", b"theirs\n");
            git(&root, &["commit", "-q", "-am", "theirs"]);
            git(&root, &["checkout", "-q", "main"]);
            write(&root, "CLAUDE.md", b"ours\n");
            git(&root, &["commit", "-q", "-am", "ours"]);
            assert!(!run(&root, &["merge", "-q", "theirs"]).status.success());
            git(&root, &["update-index", "--index-version", version]);
            let repo = Repo::find(&root.join("CLAUDE.md")).unwrap();
            assert_eq!(repo.entry(&root.join("CLAUDE.md")), Entry::Unmerged);
            // Markers in a staged file are text, not a conflict.
            let markers = b"<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\n";
            write(&root, "notes.md", markers);
            git(&root, &["add", "notes.md"]);
            let notes = repo.entry(&root.join("notes.md"));
            assert_eq!(notes, Entry::Staged(blob_id(markers)));
            git(&root, &["add", "CLAUDE.md"]);
            let resolved = fs::read(root.join("CLAUDE.md")).unwrap();
            let entry = repo.entry(&root.join("CLAUDE.md"));
            assert_eq!(entry, Entry::Staged(blob_id(&resolved)));
        }
    }

    #[test]
    fn a_dot_git_file_names_the_gitdir() {
        let (_dir, root) = repo(&[("CLAUDE.md", b"main\n")]);
        git(&root, &["commit", "-q", "-m", "one"]);
        let worktree = root.join("wt");
        git(&root, &["worktree", "add", "-q", "-b", "side", "wt"]);
        write(&worktree, "CLAUDE.md", b"side\n");
        git(&worktree, &["add", "CLAUDE.md"]);
        let repo = Repo::find(&worktree.join("CLAUDE.md")).unwrap();
        assert_eq!(repo.gitdir(), root.join(".git/worktrees/wt"));
        let entry = repo.entry(&worktree.join("CLAUDE.md"));
        assert_eq!(entry, Entry::Staged(blob_id(b"side\n")));
        assert_eq!(repo.state().head.as_deref(), Some("ref: refs/heads/side"));
        let main = Repo::find(&root.join("CLAUDE.md")).unwrap();
        assert_eq!(
            main.entry(&root.join("CLAUDE.md")),
            Entry::Staged(blob_id(b"main\n"))
        );

        // A relative gitdir, as submodules have, is relative to the file.
        let sub = root.join("sub");
        fs::create_dir(&sub).unwrap();
        fs::write(sub.join(".git"), "gitdir: ../.git\r\n").unwrap();
        let repo = Repo::find(&sub.join("CLAUDE.md")).unwrap();
        assert_eq!(repo.gitdir(), sub.join("../.git"));

        for broken in ["", "gitdir: ", "gitdir ../.git", "\u{0}"] {
            fs::write(sub.join(".git"), broken).unwrap();
            assert!(Repo::find(&sub.join("CLAUDE.md")).is_none(), "{broken:?}");
        }
        fs::remove_file(sub.join(".git")).unwrap();
        mkfifo(&sub.join(".git"));
        assert!(Repo::find(&sub.join("CLAUDE.md")).is_none());

        // A gitdir needs a HEAD: git looks past a .git folder without one,
        // and refuses a .git file that names one.
        fs::remove_file(sub.join(".git")).unwrap();
        fs::create_dir(sub.join(".git")).unwrap();
        let repo = Repo::find(&sub.join("CLAUDE.md")).unwrap();
        assert_eq!(repo.gitdir(), root.join(".git"));
        fs::write(
            root.join("wt/.git"),
            format!("gitdir: {}\n", sub.join(".git").display()),
        )
        .unwrap();
        assert!(Repo::find(&worktree.join("CLAUDE.md")).is_none());
    }

    #[test]
    fn split_and_sparse_indexes_are_unknown() {
        let (_dir, root) = repo(&[("CLAUDE.md", b"one\n"), ("other/notes.md", b"two\n")]);
        git(&root, &["commit", "-q", "-m", "one"]);
        let repo = Repo::find(&root.join("CLAUDE.md")).unwrap();
        git(&root, &["update-index", "--split-index"]);
        assert_eq!(repo.entry(&root.join("CLAUDE.md")), Entry::Unknown);
        git(&root, &["update-index", "--no-split-index"]);
        assert_eq!(
            repo.entry(&root.join("CLAUDE.md")),
            Entry::Staged(blob_id(b"one\n"))
        );

        git(
            &root,
            &["sparse-checkout", "set", "--cone", "--sparse-index", "docs"],
        );
        assert_eq!(
            repo.entry(&root.join("CLAUDE.md")),
            Entry::Staged(blob_id(b"one\n"))
        );
        assert_eq!(repo.entry(&root.join("other/notes.md")), Entry::Unknown);
        assert_eq!(repo.entry(&root.join("missing.md")), Entry::Unknown);
    }

    #[test]
    fn state_reads_head_orig_head_the_lock_and_rebase_folders() {
        let (_dir, root) = repo(&[("CLAUDE.md", b"one\n")]);
        git(&root, &["commit", "-q", "-m", "one"]);
        write(&root, "CLAUDE.md", b"two\n");
        git(&root, &["commit", "-q", "-am", "two"]);
        let two = git(&root, &["rev-parse", "HEAD"]).trim().to_owned();
        let repo = Repo::find(&root.join("CLAUDE.md")).unwrap();
        let state = repo.state();
        assert_eq!(state.head.as_deref(), Some("ref: refs/heads/main"));
        assert_eq!(state.orig_head, None);
        assert!(!state.locked && !state.rebasing);

        git(&root, &["checkout", "-q", "-b", "other"]);
        assert_eq!(repo.state().head.as_deref(), Some("ref: refs/heads/other"));
        git(&root, &["reset", "-q", "--hard", "HEAD~"]);
        assert_eq!(repo.state().orig_head, Some(two.clone()));
        git(&root, &["checkout", "-q", "--detach", &two]);
        assert_eq!(repo.state().head, Some(two));

        let gitdir = root.join(".git");
        fs::write(gitdir.join("index.lock"), b"").unwrap();
        assert!(repo.state().locked);
        fs::remove_file(gitdir.join("index.lock")).unwrap();
        for folder in ["rebase-merge", "rebase-apply"] {
            fs::create_dir(gitdir.join(folder)).unwrap();
            assert!(repo.state().rebasing, "{folder}");
            fs::remove_dir(gitdir.join(folder)).unwrap();
        }

        // FIFOs where git keeps files must not stall the reader.
        fs::remove_file(gitdir.join("HEAD")).unwrap();
        mkfifo(&gitdir.join("HEAD"));
        assert_eq!(repo.state().head, None);
        fs::remove_file(gitdir.join("index")).unwrap();
        mkfifo(&gitdir.join("index"));
        assert_eq!(repo.entry(&root.join("CLAUDE.md")), Entry::Unknown);
    }

    /// Samples as (ms, lock exists, index file generation), then the time a
    /// change was seen and whether the lock covers it.
    type Samples = (&'static str, &'static [(u64, bool, u64)], u64, bool);

    #[test]
    fn the_lock_window() {
        let t0 = Instant::now();
        let ms = |n: u64| t0 + Duration::from_millis(n);
        #[rustfmt::skip]
        let table: &[Samples] = &[
            ("no lock, no new index", &[(0, false, 1), (500, false, 1)], 100, false),
            ("held when seen", &[(0, false, 1), (100, true, 1)], 150, true),
            ("seen before it was held", &[(0, false, 1), (100, true, 1)], 50, false),
            ("held since the first sample", &[(0, true, 1)], 0, true),
            ("released 150 ms before", &[(0, false, 1), (100, true, 1), (200, false, 2)], 350, true),
            ("released 151 ms before", &[(0, false, 1), (100, true, 1), (200, false, 2)], 351, false),
            ("taken and released between samples", &[(0, false, 1), (200, false, 2)], 100, true),
            ("then 150 ms of grace", &[(0, false, 1), (200, false, 2)], 350, true),
            ("and no more", &[(0, false, 1), (200, false, 2)], 351, false),
            ("before the earlier sample", &[(50, false, 1), (200, false, 2)], 10, false),
            ("released and taken again", &[(0, false, 1), (200, false, 2), (300, true, 2)], 320, true),
            ("between two locks", &[(0, false, 1), (100, true, 1), (110, false, 2), (900, true, 2)], 500, false),
            ("an index that disappears", &[(0, false, 1), (200, false, 0)], 100, true),
            ("a lock released with no new index", &[(0, false, 1), (100, true, 1), (200, false, 1)], 150, false),
            ("a stale lock covers 10 s", &[(0, false, 1), (100, true, 1)], 10_100, true),
            ("and no more", &[(0, false, 1), (100, true, 1)], 10_101, false),
            ("a new index after a long quiet", &[(0, false, 1), (60_000, false, 2)], 50_000, true),
            ("covers only the last 10 s", &[(0, false, 1), (60_000, false, 2)], 49_999, false),
        ];
        for (name, samples, seen, covered) in table {
            let mut repo = Repo {
                gitdir: PathBuf::new(),
                top: PathBuf::new(),
                sampled: None,
                spans: Vec::new(),
            };
            for &(at, locked, generation) in *samples {
                let index = (generation > 0).then_some((1, generation, 0, 0));
                repo.saw(locked, index, ms(at));
            }
            assert_eq!(repo.covers(ms(*seen)), *covered, "{name}");
        }
    }

    #[test]
    fn git_wrote_only_the_staged_blob_under_the_lock() {
        let (_dir, root) = repo(&[("CLAUDE.md", b"# One\n")]);
        git(&root, &["commit", "-q", "-m", "one"]);
        write(&root, "CLAUDE.md", b"# Two\n");
        git(&root, &["commit", "-q", "-am", "two"]);
        let path = root.join("CLAUDE.md");
        let mut repo = Repo::find(&path).unwrap();
        let t0 = Instant::now();
        repo.sample(t0);
        assert!(!repo.wrote(&path, b"# Two\n", t0), "no lock yet");

        git(&root, &["checkout", "-q", "HEAD~", "--", "CLAUDE.md"]);
        let seen = t0 + Duration::from_millis(20);
        repo.sample(seen);
        let bytes = fs::read(&path).unwrap();
        assert_eq!(bytes, b"# One\n");
        assert!(repo.wrote(&path, &bytes, seen));
        assert!(!repo.wrote(&path, b"# One, edited\n", seen));
        assert!(!repo.wrote(&path, &bytes, seen + Duration::from_millis(151)));

        // Nothing is git's while the lock is held: the index is the old one.
        let lock = root.join(".git/index.lock");
        fs::write(&lock, b"").unwrap();
        repo.sample(seen);
        assert!(!repo.wrote(&path, &bytes, seen));
        fs::remove_file(&lock).unwrap();
        repo.sample(seen);
        assert!(repo.wrote(&path, &bytes, seen));

        // The same bytes from another writer, with no lock: not git's.
        let later = seen + Duration::from_secs(5);
        repo.sample(later);
        assert!(!repo.wrote(&path, &bytes, later));
    }

    /// One entry as git lays it out: stage and extended flags as given, a
    /// name of 0xfff bytes or more marked 0xfff.
    fn entry(
        version: u32,
        previous: &[u8],
        name: &[u8],
        flags: u16,
        extended: Option<u16>,
    ) -> Vec<u8> {
        let mut bytes = vec![0u8; 24];
        bytes.extend(0o100644u32.to_be_bytes());
        bytes.extend([0u8; 12]);
        bytes.extend(blob_id(name).0);
        let length = name.len().min(0xfff) as u16;
        let flags = flags | length | if extended.is_some() { EXTENDED } else { 0 };
        bytes.extend(flags.to_be_bytes());
        bytes.extend(extended.map(u16::to_be_bytes).into_iter().flatten());
        if version == 4 {
            let common = previous
                .iter()
                .zip(name)
                .take_while(|(a, b)| a == b)
                .count();
            let mut strip = previous.len() - common;
            let mut varint = vec![(strip & 0x7f) as u8];
            while strip >> 7 != 0 {
                strip = (strip >> 7) - 1;
                varint.insert(0, 0x80 | (strip & 0x7f) as u8);
            }
            bytes.extend(varint);
            bytes.extend(&name[common..]);
            bytes.push(0);
        } else {
            bytes.extend(name);
            bytes.resize((bytes.len() + 8) & !7, 0);
        }
        bytes
    }

    fn index(version: u32, names: &[&[u8]], extensions: &[u8]) -> Vec<u8> {
        let mut bytes = b"DIRC".to_vec();
        bytes.extend(version.to_be_bytes());
        bytes.extend((names.len() as u32).to_be_bytes());
        let mut previous: &[u8] = b"";
        for name in names {
            bytes.extend(entry(version, previous, name, 0, None));
            previous = name;
        }
        bytes.extend(extensions);
        bytes.extend([0u8; 20]);
        bytes
    }

    #[test]
    fn long_names_and_extensions() {
        let long = "d/".repeat(2500) + "CLAUDE.md";
        for version in [2, 3, 4] {
            let names: [&[u8]; 3] = [b"a.md", long.as_bytes(), b"z.md"];
            let index = index(version, &names, b"TREE\0\0\0\x01xZZZZ\0\0\0\0");
            for name in names {
                assert_eq!(
                    lookup(&index, name),
                    Entry::Staged(blob_id(name)),
                    "v{version}"
                );
            }
        }
    }

    #[test]
    fn malformed_indexes_are_unknown() {
        let good = index(4, &[b"a.md", b"ab.md"], b"");
        assert_eq!(lookup(&good, b"ab.md"), Entry::Staged(blob_id(b"ab.md")));
        let mut cases: Vec<(&str, Vec<u8>)> = vec![
            ("empty", Vec::new()),
            ("bad signature", [b"DIRX", &good[4..]].concat()),
            (
                "version 5",
                [&good[..4], &5u32.to_be_bytes(), &good[8..]].concat(),
            ),
            ("no trailer", good[..good.len() - 20].to_vec()),
            ("a 32-byte trailer", [&good[..], &[0u8; 12]].concat()),
            (
                "a required extension",
                index(2, &[b"a.md"], b"abcd\0\0\0\0"),
            ),
            (
                "an extension past the end",
                index(2, &[b"a.md"], b"TREE\xff\xff\xff\xff"),
            ),
            (
                "more entries than bytes",
                [&good[..8], &u32::MAX.to_be_bytes(), &good[12..]].concat(),
            ),
        ];
        let mut extended = b"DIRC\0\0\0\x02\0\0\0\x01".to_vec();
        extended.extend(entry(3, b"", b"a.md", 0, Some(0)));
        extended.extend([0u8; 20]);
        cases.push(("extended flags in version 2", extended));
        let mut unknown_flag = b"DIRC\0\0\0\x03\0\0\0\x01".to_vec();
        unknown_flag.extend(entry(3, b"", b"a.md", 0, Some(0x8000)));
        unknown_flag.extend([0u8; 20]);
        cases.push(("an unknown extended flag", unknown_flag));
        let mut strip = b"DIRC\0\0\0\x04\0\0\0\x01".to_vec();
        strip.extend(entry(4, b"zz", b"a.md", 0, None));
        strip.extend([0u8; 20]);
        cases.push(("a cut longer than the previous name", strip));
        let mut varint = good.clone();
        varint.splice(12 + 62..12 + 63, [0xff; 12]);
        cases.push(("a varint that overflows", varint));
        let mut short = index(2, &[b"a.md"], b"");
        short[12 + 61] = 0xff;
        short[12 + 60] |= 0x0f;
        cases.push(("0xfff for a short name", short));
        let mut padding = index(2, &[b"a.md"], b"");
        padding[12 + 62 + 4] = b'x';
        cases.push(("padding that isn't NUL", padding));
        let mut twice = index(2, &[b"a.md", b"a.md"], b"");
        twice[12 + 72 + 40] ^= 1;
        cases.push(("one name staged twice", twice));
        for (name, bytes) in cases {
            assert_eq!(lookup(&bytes, b"a.md"), Entry::Unknown, "{name}");
        }
        for cut in 0..good.len() {
            assert_eq!(
                lookup(&good[..cut], b"a.md"),
                Entry::Unknown,
                "cut at {cut}"
            );
        }
    }

    /// Real indexes of each version, written by git.
    fn real_indexes() -> &'static [Vec<u8>] {
        static INDEXES: OnceLock<Vec<Vec<u8>>> = OnceLock::new();
        INDEXES.get_or_init(|| {
            ["2", "3", "4"]
                .iter()
                .map(|version| {
                    let (_dir, root) = repo(&FILES);
                    write(&root, "docs/later.md", b"later\n");
                    git(&root, &["add", "-N", "docs/later.md"]);
                    git(&root, &["update-index", "--index-version", version]);
                    fs::read(root.join(".git/index")).unwrap()
                })
                .collect()
        })
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(512))]

        #[test]
        fn damaged_indexes_never_panic(
            which in 0..3usize,
            cut in any::<prop::sample::Index>(),
            flips in prop::collection::vec((any::<prop::sample::Index>(), any::<u8>()), 0..6),
        ) {
            let mut index = real_indexes()[which].clone();
            for (at, byte) in flips {
                let at = at.index(index.len());
                index[at] = byte;
            }
            index.truncate(cut.index(index.len() + 1));
            for (name, _) in FILES {
                lookup(&index, name.as_bytes());
            }
        }

        #[test]
        fn built_indexes_read_back(
            version in 2..=4u32,
            names in prop::collection::btree_set("[ab/.]{1,12}", 1..24),
        ) {
            let names: Vec<&[u8]> = names.iter().map(|name| name.as_bytes()).collect();
            let index = index(version, &names, b"");
            for name in &names {
                prop_assert_eq!(lookup(&index, name), Entry::Staged(blob_id(name)));
            }
            prop_assert_eq!(lookup(&index, b"c"), Entry::Untracked);
        }
    }
}
