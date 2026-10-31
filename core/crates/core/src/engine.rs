//! The change engine: lands outside writes into an open document without
//! losing a byte. Rust keeps each document's base (the disk bytes the buffer
//! last absorbed), the disk as last seen, the landing awaiting its commit,
//! pending changes and conflicts. Swift keeps the buffer, its version and
//! the live ranges, and passes the buffer into the calls that need it.
//!
//! Calls that read or write files or the snapshot store take a document's
//! own lock, so they run one at a time per document; `commit`, `decide` and
//! `claim` never wait behind one that does, and touch no file but the
//! decisions log, which `decide` appends one line to.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime};

use blake3::Hash;

use crate::agents::AgentFiles;
use crate::claims::{Chain, Claim, Claims, Refused, Vendor};
use crate::decisions;
use crate::file::{self, SaveError};
use crate::git::{self, Entry, Repo};
use crate::merge::{self, Conflict, Edit};
use crate::store::{Snapshot, Store};
use crate::text;

const YOU: &str = "You";
const UNKNOWN: &str = "Unknown app";
/// Larger files don't open, and a file that grows past it reads as unreadable.
const MAX_FILE: u64 = 64 << 20;
/// How often `collaborate` snapshots a buffer that collaborators edit.
const COLLABORATION_SNAPSHOT: Duration = Duration::from_secs(30);

/// The time now, for claims and git's lock window and for the snapshot store.
pub type Clock = Box<dyn Fn() -> (Instant, SystemTime) + Send + Sync>;

pub fn system_clock() -> Clock {
    Box::new(|| (Instant::now(), SystemTime::now()))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DocId(pub u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ChangeId(pub u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LandingId(pub u64);

/// Who wrote a change. A writer is named only on content proof (record
/// 0007): a hook chain for an agent, the index's blob for git.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Origin {
    User,
    Agent {
        vendor: Vendor,
        session: String,
    },
    /// Git, and what it was doing when known: "Switched branch", "Rebase".
    Git {
        action: Option<String>,
    },
    /// "Unknown app".
    External,
    /// Someone editing the shared file live (D13), by node id and the name
    /// the host approved.
    Collaborator {
        peer: String,
        name: String,
    },
}

impl Origin {
    /// The origin as the snapshot store keeps it.
    pub fn label(&self) -> String {
        match self {
            Origin::User => YOU.into(),
            Origin::Agent { vendor, session } => {
                let vendor = match vendor {
                    Vendor::Claude => "claude",
                    Vendor::Codex => "codex",
                    Vendor::Cursor => "cursor",
                };
                format!("{vendor}:{session}")
            }
            Origin::Git { action: None } => "git".into(),
            Origin::Git {
                action: Some(action),
            } => format!("git:{action}"),
            Origin::External => UNKNOWN.into(),
            Origin::Collaborator { peer, name } => format!("collab:{peer}:{name}"),
        }
    }

    /// Reads a store label; anything it doesn't know is External.
    pub fn from_label(label: &str) -> Origin {
        let agent = |vendor, session: &str| Origin::Agent {
            vendor,
            session: session.into(),
        };
        match label.split_once(':') {
            _ if label == YOU => Origin::User,
            _ if label == "git" => Origin::Git { action: None },
            Some(("git", action)) => Origin::Git {
                action: Some(action.into()),
            },
            Some(("claude", session)) => agent(Vendor::Claude, session),
            Some(("codex", session)) => agent(Vendor::Codex, session),
            Some(("cursor", session)) => agent(Vendor::Cursor, session),
            Some(("collab", rest)) => match rest.split_once(':') {
                Some((peer, name)) => Origin::Collaborator {
                    peer: peer.into(),
                    name: name.into(),
                },
                None => Origin::External,
            },
            _ => Origin::External,
        }
    }
}

pub struct Opened {
    pub doc: DocId,
    /// The file as read. `Other` is not UTF-8 and opens read-only.
    pub contents: text::Opened,
    /// The realpath the engine keys the file by.
    pub path: PathBuf,
    /// Whether an agent loads the file (agents.json), by the path as opened
    /// or the realpath.
    pub agent_file: bool,
    /// The gitdir of the repository the file is in, to watch for
    /// `git_changed`.
    pub gitdir: Option<PathBuf>,
}

/// A file's new version merged into the buffer at `version`. Offsets are
/// UTF-16 into that buffer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Landing {
    pub id: LandingId,
    pub version: u64,
    pub origin: Origin,
    /// False for a quiet base: no marks, the quiet line instead.
    pub marked: bool,
    pub time: SystemTime,
    /// Each edit is one pending change.
    pub edits: Vec<(ChangeId, Edit)>,
    /// One replace that makes the same text as `edits`, for big changes.
    pub covering: Option<Edit>,
    pub conflicts: Vec<(ChangeId, Conflict)>,
}

#[derive(Debug)]
pub enum EngineError {
    /// No open document has the id.
    Closed,
    /// A hooked call or git's index lock holds the file: land again after
    /// the claim or git event that ends it, or shortly.
    Waiting,
    /// The document or the file's new version is not UTF-8 text.
    NotText,
    /// A collaborator's edits are out of order or past the buffer's end.
    Misplaced,
    Io(io::Error),
}

impl From<io::Error> for EngineError {
    fn from(error: io::Error) -> Self {
        EngineError::Io(error)
    }
}

/// The landing is not the document's current one, or the base moved since.
#[derive(Debug, PartialEq, Eq)]
pub struct Stale;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SaveKind {
    /// With the editor's state: an IME composition, a Writing Tools session.
    Auto {
        composing: bool,
        writing_tools: bool,
    },
    /// Cmd-S.
    Explicit,
}

/// Why a save wrote nothing. Every refusal but `Closed`, `ReadOnly` and
/// `Stale` puts the buffer in the file's draft snapshot.
#[derive(Debug)]
pub enum SaveRefused {
    Closed,
    /// The document is not UTF-8 text and is never written.
    ReadOnly,
    /// Stamped with a buffer version from before a committed landing.
    Stale,
    /// A conflict is open.
    Conflict,
    /// The file changed since the base: land first.
    Changed,
    /// A hook holds the file's autosave.
    Held,
    Composing,
    WritingTools,
    /// Autosave only: the file is gone. Cmd-S makes it again.
    Deleted,
    Unreadable,
    Io(io::Error),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Yours stays: the buffer is unchanged.
    Keep,
    /// The other version replaces yours: a change's text before it landed,
    /// a conflict's other version.
    Other,
    /// A conflict's two versions, yours first. A change is kept.
    Both,
}

/// What a claim changed, for Swift to act on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Update {
    /// A late claim named a change already seen; a quiet one becomes marked.
    Relabeled {
        doc: DocId,
        change: ChangeId,
        origin: Origin,
    },
    /// A hold on the file ended: run the refused autosave again.
    Released(DocId),
    /// A hooked call on the file ended: land again.
    Retry(DocId),
}

enum Disk {
    Seen {
        hash: Hash,
        bytes: Arc<[u8]>,
        seen: Instant,
    },
    Gone,
    Unreadable,
}

impl Disk {
    fn hash(&self) -> Option<Hash> {
        match self {
            Disk::Seen { hash, .. } => Some(*hash),
            _ => None,
        }
    }
}

enum Kind {
    /// The text the edit replaced and the text it put there.
    Edit {
        original: String,
        landed: String,
    },
    Conflict {
        theirs: String,
    },
}

struct Change {
    id: ChangeId,
    origin: Origin,
    marked: bool,
    /// The landing's ancestor and disk hashes, and when the disk was seen.
    from: Hash,
    to: Hash,
    seen: Instant,
    kind: Kind,
}

/// A landing awaiting its commit.
struct Pending {
    id: LandingId,
    version: u64,
    from: Hash,
    to: Hash,
    seen: Instant,
    bom: bool,
    origin: Origin,
    chain: Option<Chain>,
    head: Option<String>,
    changes: Vec<Change>,
    /// The landing edits the buffer, so its apply bumps the version.
    edits: bool,
}

struct Doc {
    opened: PathBuf,
    path: PathBuf,
    /// Transcripts, `file-history/` and agent settings: never snapshotted.
    private: bool,
    agent_file: bool,
    gitdir: Option<PathBuf>,
    /// HEAD when the document opened or last took a git landing.
    head: Option<String>,
    read_only: bool,
    bom: bool,
    base: Arc<[u8]>,
    base_hash: Hash,
    base_origin: Origin,
    /// The base is in the store.
    base_kept: bool,
    disk: Disk,
    landing: Option<Pending>,
    changes: Vec<Change>,
    /// The buffer version of the newest committed landing: saves stamped
    /// with it or older would undo it.
    floor: Option<u64>,
    /// When a landing first waited on git's index lock.
    wait_from: Option<Instant>,
    drafted: bool,
    /// When `collaborate` last snapshotted the buffer.
    collaborated: Option<Instant>,
    /// Bumped whenever the base or the disk changes.
    generation: u64,
}

impl Doc {
    fn conflicted(&self) -> bool {
        self.changes
            .iter()
            .any(|change| matches!(change.kind, Kind::Conflict { .. }))
    }
}

#[derive(Default)]
struct State {
    docs: HashMap<DocId, Doc>,
    serial: HashMap<DocId, Arc<Mutex<()>>>,
    claims: Claims,
    next: u64,
}

impl State {
    fn next(&mut self) -> u64 {
        self.next += 1;
        self.next
    }
}

pub struct Engine {
    store: Store,
    /// The store folder, which holds the decisions log.
    root: PathBuf,
    clock: Clock,
    agents: &'static AgentFiles,
    state: Mutex<State>,
    repos: Mutex<HashMap<PathBuf, Repo>>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    // Every update finishes before its lock is released, so a panic in
    // another call leaves nothing half done.
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Engine {
    /// An engine whose snapshots live in the store at `root`.
    pub fn new(root: &Path, clock: Clock) -> io::Result<Engine> {
        Ok(Engine {
            store: Store::open(root)?,
            root: root.to_owned(),
            clock,
            agents: AgentFiles::builtin(),
            state: Mutex::default(),
            repos: Mutex::default(),
        })
    }

    fn state(&self) -> MutexGuard<'_, State> {
        lock(&self.state)
    }

    /// The document's own lock, held across its file and store work.
    fn serial(&self, doc: DocId) -> Option<Arc<Mutex<()>>> {
        self.state().serial.get(&doc).cloned()
    }

    pub fn open(&self, path: &Path) -> io::Result<Opened> {
        let real = fs::canonicalize(path)?;
        let bytes = read(&real)?;
        let (now, _) = (self.clock)();
        let base_hash = blake3::hash(&bytes);
        let contents = text::Opened::new(bytes.clone());
        let (read_only, bom) = match &contents {
            text::Opened::Utf8 { bom, .. } => (false, *bom),
            text::Opened::Other(_) => (true, false),
        };
        let (gitdir, head) = self.find_repo(&real, now);
        let agent_file = self.agents.matches(path) || self.agents.matches(&real);
        let base: Arc<[u8]> = bytes.into();
        let doc = Doc {
            opened: path.to_owned(),
            private: private(path) || private(&real),
            path: real.clone(),
            agent_file,
            gitdir: gitdir.clone(),
            head,
            read_only,
            bom,
            base: base.clone(),
            base_hash,
            base_origin: Origin::External,
            base_kept: false,
            disk: Disk::Seen {
                hash: base_hash,
                bytes: base,
                seen: now,
            },
            landing: None,
            changes: Vec::new(),
            floor: None,
            wait_from: None,
            drafted: false,
            collaborated: None,
            generation: 0,
        };
        let mut state = self.state();
        let id = DocId(state.next());
        state.docs.insert(id, doc);
        state.serial.insert(id, Arc::default());
        Ok(Opened {
            doc: id,
            contents,
            path: real,
            agent_file,
            gitdir,
        })
    }

    /// The gitdir of the repository that holds `real`, sampled, and its HEAD.
    fn find_repo(&self, real: &Path, now: Instant) -> (Option<PathBuf>, Option<String>) {
        let Some(found) = Repo::find(real) else {
            return (None, None);
        };
        let mut repos = lock(&self.repos);
        let gitdir = found.gitdir().to_owned();
        let repo = repos.entry(gitdir.clone()).or_insert(found);
        repo.sample(now);
        (Some(gitdir), repo.state().head)
    }

    /// Reads the file and notes it as the disk. True when it differs from
    /// the base. A new version is snapshotted, with the base it replaces,
    /// before this returns; if either fails, nothing is noted and nothing
    /// can land. A newer version supersedes a landing awaiting its commit.
    pub fn observe(&self, doc: DocId) -> Result<bool, EngineError> {
        let serial = self.serial(doc).ok_or(EngineError::Closed)?;
        let _serial = lock(&serial);
        let (path, private, base_hash, last, kept) = {
            let state = self.state();
            let d = state.docs.get(&doc).ok_or(EngineError::Closed)?;
            let kept =
                (!d.base_kept && !d.private).then(|| (d.base.clone(), d.base_origin.label()));
            (d.path.clone(), d.private, d.base_hash, d.disk.hash(), kept)
        };
        let read = read(&path);
        let (now, wall) = (self.clock)();
        let bytes = match read {
            Ok(bytes) => bytes,
            Err(error) => {
                if let Some((base, origin)) = &kept {
                    self.store.put(&path, base, origin, wall)?;
                }
                let mut state = self.state();
                let d = state.docs.get_mut(&doc).ok_or(EngineError::Closed)?;
                if d.base_hash == base_hash && kept.is_some() {
                    d.base_kept = true;
                }
                d.disk = match error.kind() {
                    io::ErrorKind::NotFound => Disk::Gone,
                    _ => Disk::Unreadable,
                };
                d.landing = None;
                d.generation += 1;
                return Ok(true);
            }
        };
        let hash = blake3::hash(&bytes);
        if last == Some(hash) {
            return Ok(hash != base_hash);
        }
        if hash != base_hash && !private {
            if let Some((base, origin)) = &kept {
                self.store.put(&path, base, origin, wall)?;
            }
            self.store.put(&path, &bytes, UNKNOWN, wall)?;
        }
        let mut state = self.state();
        let d = state.docs.get_mut(&doc).ok_or(EngineError::Closed)?;
        if d.base_hash == base_hash && kept.is_some() && hash != base_hash {
            d.base_kept = true;
        }
        d.disk = Disk::Seen {
            hash,
            bytes: if hash == d.base_hash {
                d.base.clone()
            } else {
                bytes.into()
            },
            seen: now,
        };
        d.landing = None;
        d.generation += 1;
        Ok(hash != d.base_hash)
    }

    /// Merges the disk's new version into `buffer`, the text at `version`,
    /// after snapshotting the buffer if it differs from the base. None when
    /// there is nothing to land. The landing replaces any earlier one; only
    /// it can commit.
    pub fn land(
        &self,
        doc: DocId,
        buffer: &str,
        version: u64,
    ) -> Result<Option<Landing>, EngineError> {
        let serial = self.serial(doc).ok_or(EngineError::Closed)?;
        let _serial = lock(&serial);
        let (now, wall) = (self.clock)();
        let (
            path,
            private,
            agent_file,
            gitdir,
            head,
            bom,
            base,
            base_hash,
            disk,
            to,
            seen,
            generation,
        ) = {
            let mut state = self.state();
            let State { docs, claims, .. } = &mut *state;
            let d = docs.get_mut(&doc).ok_or(EngineError::Closed)?;
            let Disk::Seen { hash, bytes, seen } = &d.disk else {
                return Ok(None);
            };
            if *hash == d.base_hash {
                return Ok(None);
            }
            if d.read_only {
                return Err(EngineError::NotText);
            }
            let locked = d
                .gitdir
                .as_ref()
                .is_some_and(|gitdir| gitdir.join("index.lock").exists());
            let lock_waits = locked
                && now.saturating_duration_since(*d.wait_from.get_or_insert(now)) < git::LOCK_WAIT;
            if claims.open_call(&d.path, now) || lock_waits {
                return Err(EngineError::Waiting);
            }
            d.wait_from = None;
            (
                d.path.clone(),
                d.private,
                d.agent_file,
                d.gitdir.clone(),
                d.head.clone(),
                d.bom,
                d.base.clone(),
                d.base_hash,
                bytes.clone(),
                *hash,
                *seen,
                d.generation,
            )
        };
        let text::Opened::Utf8 {
            bom: theirs_bom,
            text: theirs,
        } = text::Opened::new(disk.to_vec())
        else {
            return Err(EngineError::NotText);
        };
        let ours_base = strip(&base, bom).ok_or(EngineError::NotText)?;
        let dirty = buffer != ours_base;
        if dirty && !private {
            self.store
                .put(&path, &text::encode(buffer, bom), YOU, wall)?;
        }
        let merge = merge::merge3(ours_base, buffer, &theirs);

        let chain = {
            let state = self.state();
            let d = state.docs.get(&doc).ok_or(EngineError::Closed)?;
            if d.generation != generation {
                return Ok(None);
            }
            state.claims.chain(&path, &base_hash, &to, seen)
        };
        let (git, unmerged, now_head) = match &gitdir {
            Some(gitdir) => {
                let mut repos = lock(&self.repos);
                match repos.get_mut(gitdir) {
                    Some(repo) => {
                        repo.sample(now);
                        let state = repo.state();
                        let wrote = chain.is_none() && repo.wrote(&path, &disk, seen);
                        let action = if state.rebasing {
                            Some("Rebase".to_owned())
                        } else if state.head != head {
                            Some("Switched branch".to_owned())
                        } else {
                            None
                        };
                        let unmerged = repo.entry(&path) == Entry::Unmerged;
                        (wrote.then_some(action), unmerged, state.head)
                    }
                    None => (None, false, head),
                }
            }
            None => (None, false, head),
        };
        let origin = match (&chain, git) {
            (Some(chain), _) => Origin::Agent {
                vendor: chain.vendor,
                session: chain.session.as_str().to_owned(),
            },
            (None, Some(action)) => Origin::Git { action },
            (None, None) => Origin::External,
        };
        if origin != Origin::External && !private {
            self.store.relabel(&path, &to, UNKNOWN, &origin.label())?;
        }
        let quiet = !dirty
            && !unmerged
            && match &origin {
                Origin::External => !agent_file,
                Origin::Git { .. } => true,
                Origin::Agent { .. } | Origin::User | Origin::Collaborator { .. } => false,
            };

        let (edits, covering, conflicts) = if unmerged && buffer != theirs {
            let (start, end, theirs) = differing(buffer, &theirs);
            let card = Conflict { start, end, theirs };
            (Vec::new(), None, vec![card])
        } else {
            (merge.edits, merge.covering, merge.conflicts)
        };
        let originals = slices(buffer, edits.iter().map(|edit| (edit.start, edit.end)));

        let mut state = self.state();
        let ids: Vec<u64> = (0..1 + edits.len() + conflicts.len())
            .map(|_| state.next())
            .collect();
        let d = state.docs.get_mut(&doc).ok_or(EngineError::Closed)?;
        if d.generation != generation {
            return Ok(None);
        }
        let change = |id: u64, kind| Change {
            id: ChangeId(id),
            origin: origin.clone(),
            marked: !quiet,
            from: base_hash,
            to,
            seen,
            kind,
        };
        let mut changes = Vec::new();
        let landed_edits: Vec<(ChangeId, Edit)> = edits
            .into_iter()
            .zip(originals)
            .zip(&ids[1..])
            .map(|((edit, original), &id)| {
                changes.push(change(
                    id,
                    Kind::Edit {
                        original,
                        landed: edit.text.clone(),
                    },
                ));
                (ChangeId(id), edit)
            })
            .collect();
        let landed_conflicts: Vec<(ChangeId, Conflict)> = conflicts
            .into_iter()
            .zip(&ids[1 + landed_edits.len()..])
            .map(|(conflict, &id)| {
                changes.push(change(
                    id,
                    Kind::Conflict {
                        theirs: conflict.theirs.clone(),
                    },
                ));
                (ChangeId(id), conflict)
            })
            .collect();
        let landing = Landing {
            id: LandingId(ids[0]),
            version,
            origin: origin.clone(),
            marked: !quiet,
            time: wall,
            edits: landed_edits,
            covering,
            conflicts: landed_conflicts,
        };
        d.landing = Some(Pending {
            id: landing.id,
            version,
            from: base_hash,
            to,
            seen,
            bom: theirs_bom,
            origin,
            chain,
            head: now_head,
            changes,
            edits: !landing.edits.is_empty(),
        });
        Ok(Some(landing))
    }

    /// Takes a collaborator's edits to `buffer` (UTF-16, in order, apart) and
    /// returns them for the editor to apply in one step once no IME
    /// composition is open. Like a landing it snapshots a buffer that differs
    /// from the base first, at most every `COLLABORATION_SNAPSHOT`, since
    /// collaborators type a keystroke at a time. The edits reach only this
    /// document's buffer; its next save writes them through the
    /// compare-and-swap.
    pub fn collaborate(
        &self,
        doc: DocId,
        buffer: &str,
        edits: Vec<Edit>,
    ) -> Result<Vec<Edit>, EngineError> {
        let length = buffer.encode_utf16().count() as u32;
        let mut from = 0;
        for edit in &edits {
            if edit.start < from || edit.end < edit.start || edit.end > length {
                return Err(EngineError::Misplaced);
            }
            from = edit.end;
        }
        let serial = self.serial(doc).ok_or(EngineError::Closed)?;
        let _serial = lock(&serial);
        let (now, wall) = (self.clock)();
        let (path, private, bom, base) = {
            let mut state = self.state();
            let d = state.docs.get_mut(&doc).ok_or(EngineError::Closed)?;
            if d.read_only {
                return Err(EngineError::NotText);
            }
            if d.collaborated
                .is_some_and(|last| now.saturating_duration_since(last) < COLLABORATION_SNAPSHOT)
            {
                return Ok(edits);
            }
            d.collaborated = Some(now);
            (d.path.clone(), d.private, d.bom, d.base.clone())
        };
        if !private && strip(&base, bom) != Some(buffer) {
            self.store
                .put(&path, &text::encode(buffer, bom), YOU, wall)?;
        }
        Ok(edits)
    }

    /// Moves the base to the landing's disk version and keeps its changes.
    /// Call it on the main thread with the buffer still at the landing's
    /// version, and apply the landing in the same step only if it succeeds.
    pub fn commit(&self, doc: DocId, landing: LandingId) -> Result<(), Stale> {
        let (now, _) = (self.clock)();
        let mut state = self.state();
        let State { docs, claims, .. } = &mut *state;
        let d = docs.get_mut(&doc).ok_or(Stale)?;
        let pending = d
            .landing
            .take_if(|pending| pending.id == landing)
            .ok_or(Stale)?;
        let Disk::Seen { hash, bytes, .. } = &d.disk else {
            return Err(Stale);
        };
        if d.base_hash != pending.from || *hash != pending.to {
            return Err(Stale);
        }
        d.base = bytes.clone();
        d.base_hash = pending.to;
        d.bom = pending.bom;
        d.base_origin = pending.origin;
        d.base_kept = true;
        if pending.edits {
            d.floor = Some(pending.version);
        }
        d.head = pending.head;
        d.changes.retain(|change| change.marked);
        d.changes.extend(pending.changes);
        d.generation += 1;
        if let Some(chain) = &pending.chain {
            claims.spend(chain, now);
        }
        Ok(())
    }

    /// Writes `buffer`, stamped with its `version`, through the file's
    /// compare-and-swap against the base, and returns the bytes' hash. A
    /// refusal puts the buffer in the file's draft snapshot instead, except
    /// for a read-only document or a stale stamp. Cmd-S is refused only by a
    /// conflict or a file that changed since the base, and makes a deleted
    /// file again.
    pub fn save(
        &self,
        doc: DocId,
        buffer: &str,
        version: u64,
        kind: SaveKind,
    ) -> Result<Hash, SaveRefused> {
        let serial = self.serial(doc).ok_or(SaveRefused::Closed)?;
        let _serial = lock(&serial);
        let (now, wall) = (self.clock)();
        let (path, private, bom, base, base_hash, kept, refused, gone) = {
            let state = self.state();
            let d = state.docs.get(&doc).ok_or(SaveRefused::Closed)?;
            if d.read_only {
                return Err(SaveRefused::ReadOnly);
            }
            if d.floor.is_some_and(|floor| version <= floor) {
                return Err(SaveRefused::Stale);
            }
            let auto = |refused| matches!(kind, SaveKind::Auto { .. }).then_some(refused);
            let refused = if d.conflicted() {
                Some(SaveRefused::Conflict)
            } else if let SaveKind::Auto {
                composing,
                writing_tools,
            } = kind
                && (composing || writing_tools || state.claims.held(&d.path, now))
            {
                Some(if composing {
                    SaveRefused::Composing
                } else if writing_tools {
                    SaveRefused::WritingTools
                } else {
                    SaveRefused::Held
                })
            } else {
                match &d.disk {
                    Disk::Gone => auto(SaveRefused::Deleted),
                    Disk::Unreadable => Some(SaveRefused::Unreadable),
                    Disk::Seen { hash, .. } if *hash != d.base_hash => Some(SaveRefused::Changed),
                    Disk::Seen { .. } => None,
                }
            };
            // The document's own saves are history its undo holds.
            let kept = (!d.base_kept && !d.private && d.base_origin != Origin::User)
                .then(|| (d.base.clone(), d.base_origin.label()));
            (
                d.path.clone(),
                d.private,
                d.bom,
                d.base.clone(),
                d.base_hash,
                kept,
                refused,
                matches!(d.disk, Disk::Gone),
            )
        };
        let bytes = text::encode(buffer, bom);
        if let Some(refused) = refused {
            return Err(self.draft(doc, &path, private, &bytes, wall, refused));
        }
        if let Some((base, origin)) = &kept {
            self.store
                .put(&path, base, origin, wall)
                .map_err(SaveRefused::Io)?;
        }
        let written = if gone {
            create(&path, &bytes).map_err(|error| match error.kind() {
                io::ErrorKind::AlreadyExists => SaveRefused::Changed,
                _ => SaveRefused::Io(error),
            })
        } else {
            self.write(&path, &base_hash, &bytes)
                .map(drop)
                .map_err(|error| match error {
                    SaveError::Conflict => SaveRefused::Changed,
                    SaveError::Io(error) => SaveRefused::Io(error),
                })
        };
        if let Err(refused) = written {
            return Err(self.draft(doc, &path, private, &bytes, wall, refused));
        }
        let hash = blake3::hash(&bytes);
        let drafted = {
            let mut state = self.state();
            let d = state.docs.get_mut(&doc).ok_or(SaveRefused::Closed)?;
            let bytes: Arc<[u8]> = if hash == base_hash {
                base
            } else {
                bytes.into()
            };
            d.base = bytes.clone();
            d.base_hash = hash;
            d.base_origin = Origin::User;
            d.base_kept = false;
            d.disk = Disk::Seen {
                hash,
                bytes,
                seen: now,
            };
            d.generation += 1;
            std::mem::take(&mut d.drafted)
        };
        if drafted && !private {
            // The file holds what the draft held; a draft left behind costs
            // only space until it is pruned.
            let _ = self.store.clear_draft(&path);
        }
        Ok(hash)
    }

    /// The one call to `file::save`.
    fn write(&self, path: &Path, base: &Hash, bytes: &[u8]) -> Result<Hash, SaveError> {
        file::save(path, base, bytes)
    }

    /// Puts a refused save's bytes in the draft slot, and returns the
    /// refusal, or the store's error when the draft can't be written.
    fn draft(
        &self,
        doc: DocId,
        path: &Path,
        private: bool,
        bytes: &[u8],
        wall: SystemTime,
        refused: SaveRefused,
    ) -> SaveRefused {
        if private {
            return refused;
        }
        if let Err(error) = self.store.set_draft(path, bytes, YOU, wall) {
            return SaveRefused::Io(error);
        }
        if let Some(d) = self.state().docs.get_mut(&doc) {
            d.drafted = true;
        }
        refused
    }

    /// Decides a pending change or conflict, given the text of its live
    /// range, and returns the text that replaces that range, or None when
    /// the buffer stays as it is. An agent's change goes in the decisions
    /// log, kept or reverted.
    pub fn decide(
        &self,
        doc: DocId,
        change: ChangeId,
        decision: Decision,
        current: &str,
    ) -> Option<String> {
        let (replacement, logged) = {
            let mut state = self.state();
            let d = state.docs.get_mut(&doc)?;
            let at = d.changes.iter().position(|pending| pending.id == change)?;
            let reverted = match (&d.changes[at].kind, decision) {
                // A revert that would drop text typed inside the change leaves it pending.
                (Kind::Edit { original, landed }, Decision::Other) => {
                    Some(revert(original, landed, current)?)
                }
                _ => None,
            };
            let decided = d.changes.remove(at);
            let kept = !matches!(
                (&decided.kind, decision),
                (Kind::Edit { .. }, Decision::Other) | (Kind::Conflict { .. }, Decision::Keep)
            );
            let excerpt = match &decided.kind {
                Kind::Edit { landed, .. } => landed.clone(),
                Kind::Conflict { theirs } => theirs.clone(),
            };
            let logged = match &decided.origin {
                Origin::Agent { .. } if !d.private => {
                    Some((decided.origin.label(), d.path.clone(), kept, excerpt))
                }
                _ => None,
            };
            let replacement = match (decided.kind, decision) {
                (Kind::Edit { .. }, Decision::Other) => reverted,
                (_, Decision::Keep) | (Kind::Edit { .. }, _) => None,
                (Kind::Conflict { theirs }, Decision::Other) => Some(theirs),
                (Kind::Conflict { theirs }, Decision::Both) => Some(both(current, &theirs)),
            };
            (replacement, logged)
        };
        if let Some((label, path, kept, excerpt)) = logged
            && let Some((vendor, session)) = label.split_once(':')
        {
            // The decision stands without its line; only the agent's next read misses it.
            let _ = decisions::append(
                &self.root,
                &decisions::Decision {
                    vendor,
                    session,
                    file: &path,
                    time: (self.clock)().1,
                    kept,
                    excerpt: &excerpt,
                },
            );
        }
        replacement
    }

    /// The text of `snapshot`, to replace the buffer as one undoable edit.
    /// The buffer it replaces is snapshotted first.
    pub fn restore(&self, doc: DocId, snapshot: &Snapshot, buffer: &str) -> io::Result<String> {
        let serial = self.serial(doc).ok_or_else(closed)?;
        let _serial = lock(&serial);
        let (path, private, bom) = {
            let state = self.state();
            let d = state.docs.get(&doc).ok_or_else(closed)?;
            (d.path.clone(), d.private, d.bom)
        };
        let text::Opened::Utf8 { text, .. } = text::Opened::new(self.store.get(&snapshot.hash)?)
        else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the snapshot is not UTF-8 text",
            ));
        };
        if !private {
            self.store
                .put(&path, &text::encode(buffer, bom), YOU, (self.clock)().1)?;
        }
        Ok(text)
    }

    /// Records a hook's claim. Then every change not yet named, the landing
    /// awaiting its commit included, asks the claims again, so a late claim
    /// names a change already seen; and holds and open calls that ended are
    /// reported.
    pub fn claim(&self, claim: Claim) -> Result<Vec<Update>, Refused> {
        let (now, _) = (self.clock)();
        let mut updates = Vec::new();
        let mut relabels = Vec::new();
        {
            let mut state = self.state();
            let State { docs, claims, .. } = &mut *state;
            let before: HashMap<DocId, (bool, bool)> = docs
                .iter()
                .map(|(&id, d)| {
                    (
                        id,
                        (claims.held(&d.path, now), claims.open_call(&d.path, now)),
                    )
                })
                .collect();
            claims.record(claim, now)?;
            let mut ids: Vec<DocId> = docs.keys().copied().collect();
            ids.sort();
            for id in ids {
                let d = docs.get_mut(&id).expect("listed");
                let unnamed =
                    |origin: &Origin| matches!(origin, Origin::External | Origin::Git { .. });
                let mut links: Vec<(Hash, Hash, Instant)> = d
                    .changes
                    .iter()
                    .filter(|change| unnamed(&change.origin))
                    .map(|change| (change.from, change.to, change.seen))
                    .collect();
                links.dedup();
                for (from, to, seen) in links {
                    let Some(chain) = claims.chain(&d.path, &from, &to, seen) else {
                        continue;
                    };
                    let origin = Origin::Agent {
                        vendor: chain.vendor,
                        session: chain.session.as_str().to_owned(),
                    };
                    claims.spend(&chain, now);
                    for change in d.changes.iter_mut().filter(|change| {
                        (change.from, change.to, change.seen) == (from, to, seen)
                            && unnamed(&change.origin)
                    }) {
                        relabels.push((
                            d.path.clone(),
                            to,
                            change.origin.label(),
                            origin.label(),
                            d.private,
                        ));
                        change.origin = origin.clone();
                        change.marked = true;
                        updates.push(Update::Relabeled {
                            doc: id,
                            change: change.id,
                            origin: origin.clone(),
                        });
                    }
                }
                if let Some(pending) = d.landing.as_mut()
                    && unnamed(&pending.origin)
                    && let Some(chain) =
                        claims.chain(&d.path, &pending.from, &pending.to, pending.seen)
                {
                    let origin = Origin::Agent {
                        vendor: chain.vendor,
                        session: chain.session.as_str().to_owned(),
                    };
                    relabels.push((
                        d.path.clone(),
                        pending.to,
                        pending.origin.label(),
                        origin.label(),
                        d.private,
                    ));
                    pending.origin = origin.clone();
                    pending.chain = Some(chain);
                    for change in &mut pending.changes {
                        change.origin = origin.clone();
                        change.marked = true;
                        updates.push(Update::Relabeled {
                            doc: id,
                            change: change.id,
                            origin: origin.clone(),
                        });
                    }
                }
                let (held, open) = before[&id];
                if held && !claims.held(&d.path, now) {
                    updates.push(Update::Released(id));
                }
                if open && !claims.open_call(&d.path, now) {
                    updates.push(Update::Retry(id));
                }
            }
        }
        for (path, hash, from, to, private) in relabels {
            if !private {
                // The menu's label is all a failed relabel leaves wrong.
                let _ = self.store.relabel(&path, &hash, &from, &to);
            }
        }
        Ok(updates)
    }

    /// Notes an event in a gitdir, and returns the documents in its
    /// repository, whose landings may be waiting on the index lock.
    pub fn git_changed(&self, gitdir: &Path) -> Vec<DocId> {
        let (now, _) = (self.clock)();
        match lock(&self.repos).get_mut(gitdir) {
            Some(repo) => repo.sample(now),
            None => return Vec::new(),
        }
        let state = self.state();
        let mut docs: Vec<DocId> = state
            .docs
            .iter()
            .filter(|(_, d)| d.gitdir.as_deref() == Some(gitdir))
            .map(|(&id, _)| id)
            .collect();
        docs.sort();
        docs
    }

    /// Follows the document's file to `to`, where it now is, and returns
    /// the gitdir of the repository it is in now. Its snapshots move with it
    /// and take new ids.
    pub fn moved(&self, doc: DocId, to: &Path) -> io::Result<Option<PathBuf>> {
        let serial = self.serial(doc).ok_or_else(closed)?;
        let _serial = lock(&serial);
        let real = fs::canonicalize(to)?;
        let from = self.state().docs.get(&doc).ok_or_else(closed)?.path.clone();
        self.store.moved(&from, &real)?;
        let (now, _) = (self.clock)();
        let (gitdir, head) = self.find_repo(&real, now);
        let mut state = self.state();
        let d = state.docs.get_mut(&doc).ok_or_else(closed)?;
        d.private = private(to) || private(&real);
        d.agent_file = self.agents.matches(to) || self.agents.matches(&real);
        d.opened = to.to_owned();
        d.path = real;
        if gitdir != d.gitdir {
            d.head = head;
        }
        d.gitdir = gitdir.clone();
        drop(state);
        self.forget_repos();
        Ok(gitdir)
    }

    pub fn close(&self, doc: DocId) {
        let serial = self.serial(doc);
        let _serial = serial.as_deref().map(lock);
        let mut state = self.state();
        state.docs.remove(&doc);
        state.serial.remove(&doc);
        drop(state);
        self.forget_repos();
    }

    /// Drops repositories no open document is in.
    fn forget_repos(&self) {
        let used: Vec<PathBuf> = self
            .state()
            .docs
            .values()
            .filter_map(|d| d.gitdir.clone())
            .collect();
        lock(&self.repos).retain(|gitdir, _| used.contains(gitdir));
    }

    /// The document's file's snapshots, newest first.
    pub fn snapshots(&self, doc: DocId) -> io::Result<Vec<Snapshot>> {
        let path = self.state().docs.get(&doc).ok_or_else(closed)?.path.clone();
        self.store.list(&path)
    }

    pub fn pin(&self, doc: DocId, snapshot: &Snapshot, pinned: bool) -> io::Result<()> {
        let path = self.state().docs.get(&doc).ok_or_else(closed)?.path.clone();
        self.store.pin(&path, snapshot, pinned)
    }

    /// Prunes the store, keeping the drafts of every open document. Only the
    /// app prunes, once its documents are open again after launch.
    pub fn prune(&self) -> io::Result<()> {
        let open: Vec<PathBuf> = self.state().docs.values().map(|d| d.path.clone()).collect();
        let open: Vec<&Path> = open.iter().map(PathBuf::as_path).collect();
        self.store.prune((self.clock)().1, &open)
    }
}

/// Reads a regular file. The open doesn't block, so a FIFO put at the path
/// can't stall the document.
fn read(path: &Path) -> io::Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "not a file"));
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_FILE {
        return Err(io::ErrorKind::FileTooLarge.into());
    }
    Ok(bytes)
}

fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, "the document is closed")
}

/// Makes `path`, which must not exist, holding `bytes`.
fn create(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Transcripts, `file-history/` and agent settings, which may hold secrets:
/// the engine never snapshots them (audience.md, section 3 row 4).
fn private(path: &Path) -> bool {
    let names: Vec<&OsStr> = path
        .components()
        .filter_map(|component| match component {
            Component::Normal(name) => Some(name),
            _ => None,
        })
        .collect();
    let Some((name, folders)) = names.split_last() else {
        return false;
    };
    let extension = Path::new(name).extension().and_then(OsStr::to_str);
    extension == Some("jsonl")
        || *name == ".claude.json"
        || names.iter().any(|name| *name == "file-history")
        || (matches!(extension, Some("json" | "toml"))
            && folders
                .iter()
                .any(|folder| *folder == ".claude" || *folder == ".codex"))
}

/// The text of a file's bytes, past its byte-order mark when it has one.
fn strip(bytes: &[u8], bom: bool) -> Option<&str> {
    let bytes = if bom { bytes.get(3..)? } else { bytes };
    std::str::from_utf8(bytes).ok()
}

/// The UTF-16 ranges of `text` as strings. Ranges are in order and fall
/// between characters, as `merge3` makes them.
fn slices(text: &str, ranges: impl Iterator<Item = (u32, u32)>) -> Vec<String> {
    let mut chars = text.char_indices();
    let (mut unit, mut byte) = (0u32, 0usize);
    let mut to_byte = |at: u32| {
        while unit < at {
            let (i, c) = chars.next().expect("a range inside the text");
            unit += c.len_utf16() as u32;
            byte = i + c.len_utf8();
        }
        byte
    };
    ranges
        .map(|(start, end)| {
            let start = to_byte(start);
            let end = to_byte(end);
            text[start..end].to_owned()
        })
        .collect()
}

/// Where `ours` and `theirs` differ: the UTF-16 range in ours between their
/// common start and end, and theirs's text there.
fn differing(ours: &str, theirs: &str) -> (u32, u32, String) {
    let prefix: usize = ours
        .chars()
        .zip(theirs.chars())
        .take_while(|(a, b)| a == b)
        .map(|(c, _)| c.len_utf8())
        .sum();
    let suffix: usize = ours[prefix..]
        .chars()
        .rev()
        .zip(theirs[prefix..].chars().rev())
        .take_while(|(a, b)| a == b)
        .map(|(c, _)| c.len_utf8())
        .sum();
    let units = |text: &str| text.encode_utf16().count() as u32;
    let start = units(&ours[..prefix]);
    let end = units(&ours[..ours.len() - suffix]);
    (start, end, theirs[prefix..theirs.len() - suffix].to_owned())
}

/// A change's text with the change undone: `original` back where it put
/// `landed`, keeping what was typed inside it since. None when that typing
/// and the revert overlap.
fn revert(original: &str, landed: &str, current: &str) -> Option<String> {
    if current == landed {
        return Some(original.to_owned());
    }
    let merge = merge::merge3(landed, current, original);
    merge
        .conflicts
        .is_empty()
        .then(|| merge::apply(current, &merge.edits))
}

/// A conflict's two versions, yours first, on lines of their own.
fn both(yours: &str, theirs: &str) -> String {
    let ending = [yours, theirs]
        .iter()
        .find_map(|text| {
            ["\r\n", "\n", "\r"]
                .into_iter()
                .find(|ending| text.contains(ending))
        })
        .unwrap_or("\n");
    let open = !yours.is_empty() && !yours.ends_with(['\n', '\r']);
    [yours, if open { ending } else { "" }, theirs].concat()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::claims::Fields;
    use proptest::prelude::*;
    use std::process::Command;
    use std::time::{Duration, UNIX_EPOCH};

    struct Fixture {
        _dir: tempfile::TempDir,
        root: PathBuf,
        engine: Engine,
        time: Arc<Mutex<(Instant, SystemTime)>>,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let start = (
            Instant::now(),
            UNIX_EPOCH + Duration::from_secs(1_790_000_000),
        );
        let time = Arc::new(Mutex::new(start));
        let clock = time.clone();
        let engine = Engine::new(
            &root.join("snapshots"),
            Box::new(move || *clock.lock().unwrap()),
        )
        .unwrap();
        Fixture {
            _dir: dir,
            root,
            engine,
            time,
        }
    }

    impl Fixture {
        fn tick(&self, ms: u64) {
            let mut time = self.time.lock().unwrap();
            time.0 += Duration::from_millis(ms);
            time.1 += Duration::from_millis(ms);
        }

        fn file(&self, name: &str, bytes: &str) -> PathBuf {
            let path = self.root.join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, bytes).unwrap();
            path
        }

        /// A writer's tmp-and-rename save.
        fn replace(&self, path: &Path, bytes: &str) {
            let temp = path.with_extension("tmp.123.abc");
            fs::write(&temp, bytes).unwrap();
            fs::rename(&temp, path).unwrap();
        }

        fn origins(&self, path: &Path) -> Vec<(String, String)> {
            let store = &self.engine.store;
            let history = store.list(path).unwrap();
            history
                .iter()
                .rev()
                .map(|s| {
                    (
                        String::from_utf8(store.get(&s.hash).unwrap()).unwrap(),
                        s.origin.clone(),
                    )
                })
                .collect()
        }

        fn draft(&self, path: &Path) -> Option<String> {
            let store = &self.engine.store;
            let draft = store.draft(path).unwrap()?;
            Some(String::from_utf8(store.get(&draft.hash).unwrap()).unwrap())
        }

        /// Observes, lands and commits, and returns the landing and the
        /// buffer with it applied.
        fn land(&self, doc: DocId, buffer: &str, version: u64) -> (Landing, String) {
            assert!(self.engine.observe(doc).unwrap());
            let landing = self.engine.land(doc, buffer, version).unwrap().unwrap();
            self.engine.commit(doc, landing.id).unwrap();
            let edits: Vec<Edit> = landing.edits.iter().map(|(_, edit)| edit.clone()).collect();
            let applied = merge::apply(buffer, &edits);
            (landing, applied)
        }
    }

    fn auto() -> SaveKind {
        SaveKind::Auto {
            composing: false,
            writing_tools: false,
        }
    }

    fn opened(engine: &Engine, path: &Path) -> (DocId, String) {
        let opened = engine.open(path).unwrap();
        let text::Opened::Utf8 { text, .. } = opened.contents else {
            panic!("not text");
        };
        (opened.doc, text)
    }

    fn claim(
        event: &str,
        session: &str,
        id: &str,
        path: &Path,
        hash: &str,
        declared: Option<&str>,
    ) -> Claim {
        let path = path.to_str().unwrap();
        let hash = blake3::hash(hash.as_bytes()).to_hex().to_string();
        let declared = declared.map(|text| blake3::hash(text.as_bytes()).to_hex().to_string());
        Claim::parse(Fields {
            event,
            vendor: "claude",
            session,
            tool_use_id: Some(id),
            tool: Some("Edit"),
            path: Some(path),
            hash: Some(&hash),
            declared: declared.as_deref(),
        })
        .unwrap()
    }

    fn stop(session: &str) -> Claim {
        Claim::parse(Fields {
            event: "Stop",
            vendor: "claude",
            session,
            ..Fields::default()
        })
        .unwrap()
    }

    #[test]
    fn an_outside_write_to_a_clean_buffer_takes_a_quiet_base() {
        let fx = fixture();
        let path = fx.file("notes.md", "# Notes\n\nOne.\n");
        let (doc, text) = opened(&fx.engine, &path);
        assert!(
            !fx.engine.observe(doc).unwrap(),
            "our own file is no change"
        );
        fx.replace(&path, "# Notes\n\nOne. Two.\n");
        let (landing, buffer) = fx.land(doc, &text, 1);
        assert_eq!(
            (landing.origin.clone(), landing.marked),
            (Origin::External, false)
        );
        assert_eq!(buffer, "# Notes\n\nOne. Two.\n");
        // The outgoing base and the new version are kept, in that order.
        assert_eq!(
            fx.origins(&path),
            [
                ("# Notes\n\nOne.\n".to_owned(), UNKNOWN.to_owned()),
                ("# Notes\n\nOne. Two.\n".to_owned(), UNKNOWN.to_owned())
            ]
        );
        assert!(!fx.engine.observe(doc).unwrap());
        // An autosave stamped before the landing would undo it.
        assert!(matches!(
            fx.engine.save(doc, &text, 1, auto()),
            Err(SaveRefused::Stale)
        ));
        let saved = format!("{buffer}Three.\n");
        fx.engine.save(doc, &saved, 3, auto()).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), saved);
        assert!(
            !fx.engine.observe(doc).unwrap(),
            "our own write is no change"
        );
    }

    #[test]
    fn typing_and_an_outside_write_merge_and_mark() {
        let fx = fixture();
        let path = fx.file("notes.md", "one\n\ntwo\n");
        let (doc, _) = opened(&fx.engine, &path);
        let typed = "one typed\n\ntwo\n";
        fx.replace(&path, "one\n\ntwo agent\n");
        let (landing, buffer) = fx.land(doc, typed, 4);
        assert!(landing.marked, "a landing into unsaved text is marked");
        assert_eq!(buffer, "one typed\n\ntwo agent\n");
        let kept: Vec<String> = fx
            .origins(&path)
            .into_iter()
            .map(|(text, _)| text)
            .collect();
        assert!(
            kept.contains(&typed.to_owned()),
            "the dirty buffer is snapshotted first"
        );
        assert_eq!(
            fx.engine.save(doc, &buffer, 5, auto()).unwrap(),
            blake3::hash(buffer.as_bytes())
        );
    }

    #[test]
    fn a_conflict_holds_every_save_until_it_is_decided() {
        let fx = fixture();
        let path = fx.file("notes.md", "x\n\nThe cat sat\n");
        let (doc, _) = opened(&fx.engine, &path);
        let ours = "x\n\nThe dog sat\n";
        fx.replace(&path, "x\n\nThe cow sat\n");
        let (landing, buffer) = fx.land(doc, ours, 1);
        let [(id, conflict)] = &landing.conflicts[..] else {
            panic!("{landing:?}");
        };
        assert_eq!(buffer, ours, "a conflict keeps yours");
        for kind in [auto(), SaveKind::Explicit] {
            assert!(matches!(
                fx.engine.save(doc, &buffer, 2, kind),
                Err(SaveRefused::Conflict)
            ));
        }
        assert_eq!(fx.draft(&path).as_deref(), Some(ours));
        assert_eq!(fs::read_to_string(&path).unwrap(), "x\n\nThe cow sat\n");
        let yours = &buffer[conflict.start as usize..conflict.end as usize];
        let both = fx.engine.decide(doc, *id, Decision::Both, yours).unwrap();
        assert_eq!(both, "The dog sat\nThe cow sat\n");
        assert_eq!(
            fx.engine.decide(doc, *id, Decision::Both, yours),
            None,
            "decided once"
        );
        let buffer = buffer.replace(yours, &both);
        fx.engine.save(doc, &buffer, 3, auto()).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), buffer);
        assert_eq!(fx.draft(&path), None, "a save clears the draft");
    }

    #[test]
    fn a_landing_that_edits_nothing_leaves_the_version_saveable() {
        let fx = fixture();
        let path = fx.file("notes.md", "x\n\nThe cat sat\n");
        let (doc, _) = opened(&fx.engine, &path);
        let ours = "x\n\nThe dog sat\n";
        fx.replace(&path, "x\n\nThe cow sat\n");
        let (landing, _) = fx.land(doc, ours, 1);
        assert!(landing.edits.is_empty() && landing.conflicts.len() == 1);
        let (id, conflict) = &landing.conflicts[0];
        let yours = &ours[conflict.start as usize..conflict.end as usize];
        assert_eq!(fx.engine.decide(doc, *id, Decision::Keep, yours), None);
        fx.engine.save(doc, ours, 1, auto()).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), ours);
    }

    #[test]
    fn a_file_over_64_mb_does_not_open_or_land() {
        let fx = fixture();
        let path = fx.file("big.md", "a\n");
        let (doc, _) = opened(&fx.engine, &path);
        let file = OpenOptions::new().write(true).open(&path).unwrap();
        file.set_len(MAX_FILE + 1).unwrap();
        assert_eq!(
            fx.engine.open(&path).err().map(|error| error.kind()),
            Some(io::ErrorKind::FileTooLarge)
        );
        assert!(fx.engine.observe(doc).unwrap());
        assert!(fx.engine.land(doc, "a\n", 1).unwrap().is_none());
        let refused = fx.engine.save(doc, "b\n", 1, auto());
        assert!(
            matches!(refused, Err(SaveRefused::Unreadable)),
            "{refused:?}"
        );
    }

    #[test]
    fn a_newer_version_supersedes_a_landing() {
        let fx = fixture();
        let path = fx.file("notes.md", "a\n");
        let (doc, text) = opened(&fx.engine, &path);
        fx.replace(&path, "a\nb\n");
        assert!(fx.engine.observe(doc).unwrap());
        let first = fx.engine.land(doc, &text, 1).unwrap().unwrap();
        fx.replace(&path, "a\nb\nc\n");
        assert!(fx.engine.observe(doc).unwrap());
        assert_eq!(fx.engine.commit(doc, first.id), Err(Stale));
        let second = fx.engine.land(doc, &text, 1).unwrap().unwrap();
        let third = fx.engine.land(doc, &text, 1).unwrap().unwrap();
        assert_eq!(
            fx.engine.commit(doc, second.id),
            Err(Stale),
            "a later land supersedes"
        );
        fx.engine.commit(doc, third.id).unwrap();
        assert_eq!(fx.engine.commit(doc, third.id), Err(Stale));
        assert!(fx.engine.land(doc, "a\nb\nc\n", 2).unwrap().is_none());
        // A file that goes back to the base drops the landing.
        fx.replace(&path, "a\nb\nc\nd\n");
        assert!(fx.engine.observe(doc).unwrap());
        let fourth = fx.engine.land(doc, "a\nb\nc\n", 2).unwrap().unwrap();
        fx.replace(&path, "a\nb\nc\n");
        assert!(!fx.engine.observe(doc).unwrap());
        assert_eq!(fx.engine.commit(doc, fourth.id), Err(Stale));
    }

    #[test]
    fn a_refused_autosave_writes_the_draft() {
        let fx = fixture();
        let path = fx.file("notes.md", "a\n");
        let (doc, _) = opened(&fx.engine, &path);
        let busy = [
            (
                SaveKind::Auto {
                    composing: true,
                    writing_tools: false,
                },
                "composing",
            ),
            (
                SaveKind::Auto {
                    composing: false,
                    writing_tools: true,
                },
                "writing tools",
            ),
        ];
        for (kind, name) in busy {
            let refused = fx.engine.save(doc, name, 1, kind);
            assert!(
                matches!(
                    refused,
                    Err(SaveRefused::Composing | SaveRefused::WritingTools)
                ),
                "{name}"
            );
            assert_eq!(fx.draft(&path).as_deref(), Some(name));
        }
        fx.engine
            .claim(claim(
                "PreToolUse",
                "s1",
                "t1",
                &path,
                "a\n",
                Some("a\nb\n"),
            ))
            .unwrap();
        assert!(matches!(
            fx.engine.save(doc, "held", 2, auto()),
            Err(SaveRefused::Held)
        ));
        assert_eq!(fx.draft(&path).as_deref(), Some("held"));
        assert_eq!(fs::read_to_string(&path).unwrap(), "a\n");
        // Cmd-S overrides a hold, and Stop releases it.
        fx.engine
            .save(doc, "mine\n", 3, SaveKind::Explicit)
            .unwrap();
        assert_eq!(
            fx.engine.claim(stop("s1")).unwrap(),
            [Update::Released(doc)]
        );
        fx.engine.save(doc, "mine again\n", 4, auto()).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "mine again\n");

        // A write the engine has not seen yet is caught by the compare-and-swap.
        fx.replace(&path, "theirs\n");
        assert!(matches!(
            fx.engine.save(doc, "late\n", 5, auto()),
            Err(SaveRefused::Changed)
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "theirs\n");
        assert_eq!(fx.draft(&path).as_deref(), Some("late\n"));
        let kept: Vec<String> = fx
            .origins(&path)
            .into_iter()
            .map(|(text, _)| text)
            .collect();
        assert!(
            kept.contains(&"a\n".to_owned()),
            "the opened version is kept before the first save"
        );
    }

    #[test]
    fn a_deleted_file_refuses_autosave_and_cmd_s_makes_it_again() {
        let fx = fixture();
        let path = fx.file("notes.md", "a\n");
        let (doc, _) = opened(&fx.engine, &path);
        fs::remove_file(&path).unwrap();
        assert!(fx.engine.observe(doc).unwrap());
        assert!(fx.engine.land(doc, "a typed\n", 1).unwrap().is_none());
        assert!(matches!(
            fx.engine.save(doc, "a typed\n", 1, auto()),
            Err(SaveRefused::Deleted)
        ));
        assert!(!path.exists());
        let kept: Vec<String> = fx
            .origins(&path)
            .into_iter()
            .map(|(text, _)| text)
            .collect();
        assert_eq!(kept, ["a\n"], "the deleted version is kept");
        fx.engine
            .save(doc, "a typed\n", 2, SaveKind::Explicit)
            .unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "a typed\n");
        assert!(!fx.engine.observe(doc).unwrap());
        // A file made again by someone else between the look and the save stays theirs.
        fs::remove_file(&path).unwrap();
        assert!(fx.engine.observe(doc).unwrap());
        fs::write(&path, "theirs\n").unwrap();
        let refused = fx.engine.save(doc, "mine\n", 3, SaveKind::Explicit);
        assert!(matches!(refused, Err(SaveRefused::Changed)), "{refused:?}");
        assert_eq!(fs::read_to_string(&path).unwrap(), "theirs\n");
    }

    #[test]
    fn decisions_revert_keep_and_take_the_other_version() {
        assert_eq!(revert("old", "new", "new").as_deref(), Some("old"));
        assert_eq!(
            revert("The cat sat", "The cow sat", "The cow sat down").as_deref(),
            Some("The cat sat down")
        );
        assert_eq!(revert("a", "b", "c"), None);
        assert_eq!(both("mine", "theirs\r\n"), "mine\r\ntheirs\r\n");
        assert_eq!(both("mine\n", "theirs\n"), "mine\ntheirs\n");
        assert_eq!(both("", "theirs"), "theirs");
        assert_eq!(differing("abXcd", "abYYcd"), (2, 3, "YY".to_owned()));
        assert_eq!(differing("🙂a", "🙂b"), (2, 3, "b".to_owned()));
        assert_eq!(
            slices("🙂ab\r\nc", [(0, 2), (3, 5)].into_iter()),
            ["🙂", "b\r"]
        );

        let fx = fixture();
        let path = fx.file("notes.md", "The cat sat.\n");
        let (doc, text) = opened(&fx.engine, &path);
        fx.replace(&path, "The cow sat.\n");
        let (landing, _) = fx.land(doc, &text, 1);
        let [(id, edit)] = &landing.edits[..] else {
            panic!("{landing:?}");
        };
        assert_eq!(edit.text, "cow");
        // Typing inside the change that the revert would drop leaves it pending.
        assert_eq!(fx.engine.decide(doc, *id, Decision::Other, "cXw"), None);
        assert_eq!(
            fx.engine
                .decide(doc, *id, Decision::Other, "cow")
                .as_deref(),
            Some("cat")
        );
        assert_eq!(fx.engine.decide(doc, *id, Decision::Other, "cow"), None);
        assert_eq!(fx.engine.decide(DocId(999), *id, Decision::Keep, ""), None);
    }

    #[test]
    fn restore_keeps_the_buffer_it_replaces() {
        let fx = fixture();
        let path = fx.file("notes.md", "one\n");
        let (doc, text) = opened(&fx.engine, &path);
        fx.replace(&path, "two\n");
        let (_, buffer) = fx.land(doc, &text, 1);
        let snapshots = fx.engine.snapshots(doc).unwrap();
        let oldest = snapshots.last().unwrap();
        let typed = format!("{buffer}typed\n");
        assert_eq!(fx.engine.restore(doc, oldest, &typed).unwrap(), "one\n");
        let kept: Vec<String> = fx
            .origins(&path)
            .into_iter()
            .map(|(text, _)| text)
            .collect();
        assert_eq!(kept, ["one\n", "two\n", "two\ntyped\n"]);
        let newest = fx.engine.snapshots(doc).unwrap().remove(0);
        fx.engine.pin(doc, &newest, true).unwrap();
        assert!(fx.engine.snapshots(doc).unwrap()[0].pinned);
    }

    #[test]
    fn a_hook_chain_names_the_agent_and_a_late_one_relabels() {
        let fx = fixture();
        let path = fx.file("notes.md", "a\n");
        let (doc, text) = opened(&fx.engine, &path);
        fx.engine
            .claim(claim(
                "PreToolUse",
                "s1",
                "t1",
                &path,
                "a\n",
                Some("a\nb\n"),
            ))
            .unwrap();
        fx.replace(&path, "a\nb\n");
        fx.engine
            .claim(claim("PostToolUse", "s1", "t1", &path, "a\nb\n", None))
            .unwrap();
        let (landing, buffer) = fx.land(doc, &text, 1);
        let claude = Origin::Agent {
            vendor: Vendor::Claude,
            session: "s1".into(),
        };
        assert_eq!(
            (landing.origin.clone(), landing.marked),
            (claude.clone(), true)
        );
        assert_eq!(
            fx.origins(&path)[1],
            ("a\nb\n".to_owned(), "claude:s1".to_owned())
        );

        // The hooks report after the landing: the quiet change is relabeled.
        fx.replace(&path, "a\nb\nc\n");
        let (late, buffer) = fx.land(doc, &buffer, 3);
        assert_eq!(
            (late.origin.clone(), late.marked),
            (Origin::External, false)
        );
        fx.tick(4_000);
        let post = claim("PostToolUse", "s1", "t2", &path, "a\nb\nc\n", None);
        assert_eq!(fx.engine.claim(post).unwrap(), []);
        let pre = claim("PreToolUse", "s1", "t2", &path, "a\nb\n", Some("a\nb\nc\n"));
        let updates = fx.engine.claim(pre).unwrap();
        let change = late.edits[0].0;
        assert_eq!(
            updates,
            [Update::Relabeled {
                doc,
                change,
                origin: claude.clone()
            }]
        );
        assert_eq!(fx.origins(&path).last().unwrap().1, "claude:s1");

        // A second writer inside the call leaves the change Unknown.
        fx.engine
            .claim(claim(
                "PreToolUse",
                "s1",
                "t3",
                &path,
                "a\nb\nc\n",
                Some("a\nb\nc\nd\n"),
            ))
            .unwrap();
        fx.replace(&path, "a\nb\nc\nd\n");
        fx.replace(&path, "a\nb\nc\nd\nsomeone\n");
        fx.engine
            .claim(claim(
                "PostToolUse",
                "s1",
                "t3",
                &path,
                "a\nb\nc\nd\nsomeone\n",
                None,
            ))
            .unwrap();
        let (inside, _) = fx.land(doc, &buffer, 5);
        assert_eq!(inside.origin, Origin::External);
    }

    #[test]
    fn landings_wait_for_an_open_call_and_the_index_lock() {
        let fx = fixture();
        let path = fx.file("repo/notes.md", "a\n");
        git(&fx.root.join("repo"), &["init", "-q"]);
        let (doc, text) = opened(&fx.engine, &path);
        fx.engine
            .claim(claim(
                "PreToolUse",
                "s1",
                "t1",
                &path,
                "a\n",
                Some("a\nb\n"),
            ))
            .unwrap();
        fs::write(&path, "").unwrap();
        assert!(fx.engine.observe(doc).unwrap());
        assert!(matches!(
            fx.engine.land(doc, &text, 1),
            Err(EngineError::Waiting)
        ));
        fs::write(&path, "a\nb\n").unwrap();
        assert!(fx.engine.observe(doc).unwrap());
        let updates = fx
            .engine
            .claim(claim("PostToolUse", "s1", "t1", &path, "a\nb\n", None))
            .unwrap();
        assert_eq!(updates, [Update::Retry(doc)]);
        let landing = fx.engine.land(doc, &text, 1).unwrap().unwrap();
        assert!(matches!(landing.origin, Origin::Agent { .. }));
        fx.engine.commit(doc, landing.id).unwrap();

        let lock = fx.root.join("repo/.git/index.lock");
        fs::write(&lock, "").unwrap();
        fx.replace(&path, "a\nb\nc\n");
        assert!(fx.engine.observe(doc).unwrap());
        assert!(matches!(
            fx.engine.land(doc, "a\nb\n", 2),
            Err(EngineError::Waiting)
        ));
        fx.tick(9_999);
        assert!(matches!(
            fx.engine.land(doc, "a\nb\n", 2),
            Err(EngineError::Waiting)
        ));
        fx.tick(1);
        let landing = fx.engine.land(doc, "a\nb\n", 2).unwrap().unwrap();
        assert_eq!(
            landing.origin,
            Origin::External,
            "a stale lock names nothing"
        );
    }

    /// Runs git with no user or system config.
    fn git(dir: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
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
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    #[test]
    fn git_writes_land_quiet_and_named_and_an_unmerged_path_opens_a_card() {
        let fx = fixture();
        let repo = fx.root.join("repo");
        let path = fx.file("repo/CLAUDE.md", "base\n");
        git(&repo, &["init", "-q"]);
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-q", "-m", "base"]);
        git(&repo, &["checkout", "-q", "-b", "theirs"]);
        fs::write(&path, "theirs\n").unwrap();
        git(&repo, &["commit", "-q", "-am", "theirs"]);
        git(&repo, &["checkout", "-q", "main"]);
        let (doc, text) = opened(&fx.engine, &path);
        let again = fx.engine.open(&path).unwrap();
        fx.engine.close(again.doc);
        assert!(again.agent_file);
        assert_eq!(again.gitdir, Some(repo.join(".git")));

        git(&repo, &["checkout", "-q", "theirs"]);
        assert_eq!(fx.engine.git_changed(&repo.join(".git")), [doc]);
        let (landing, buffer) = fx.land(doc, &text, 1);
        let switched = Origin::Git {
            action: Some("Switched branch".into()),
        };
        assert_eq!(
            (landing.origin, landing.marked),
            (switched, false),
            "git is quiet, even on an agent file"
        );
        assert_eq!(fx.origins(&path)[1].1, "git:Switched branch");

        // An unknown write to an agent file is marked (D23).
        fx.tick(1_000);
        fx.replace(&path, "theirs\nunknown\n");
        let (landing, buffer) = fx.land(doc, &buffer, 2);
        assert_eq!((landing.origin, landing.marked), (Origin::External, true));
        fx.engine.save(doc, &buffer, 3, SaveKind::Explicit).unwrap();
        git(&repo, &["commit", "-q", "-am", "saved"]);
        git(&repo, &["checkout", "-q", "main"]);
        fs::write(&path, "ours\n").unwrap();
        git(&repo, &["commit", "-q", "-am", "ours"]);
        let output = Command::new("git")
            .current_dir(&repo)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args([
                "-c",
                "user.email=t@example.invalid",
                "-c",
                "user.name=t",
                "merge",
                "-q",
                "theirs",
            ])
            .output()
            .unwrap();
        assert!(!output.status.success(), "the merge conflicts");
        fx.engine.git_changed(&repo.join(".git"));
        assert!(fx.engine.observe(doc).unwrap());
        let landing = fx.engine.land(doc, &buffer, 4).unwrap().unwrap();
        assert!(landing.edits.is_empty() && landing.marked);
        assert_eq!(landing.conflicts.len(), 1, "{landing:?}");
        assert!(landing.conflicts[0].1.theirs.contains("<<<<<<<"));
    }

    #[test]
    fn transcripts_history_and_settings_are_never_snapshotted() {
        for (path, kept) in [
            ("/Users/me/.claude/projects/-x/0b6c.jsonl", true),
            ("/Users/me/.claude/file-history/abc/CLAUDE.md@v2", true),
            ("/Users/me/.claude/settings.json", true),
            ("/Users/me/repo/.claude/settings.local.json", true),
            ("/Users/me/.codex/config.toml", true),
            ("/Users/me/.claude.json", true),
            ("/Users/me/.claude/CLAUDE.md", false),
            ("/Users/me/repo/package.json", false),
            ("/Users/me/repo/notes.md", false),
        ] {
            assert_eq!(private(Path::new(path)), kept, "{path}");
        }
        let fx = fixture();
        let path = fx.file(".claude/settings.json", "{}\n");
        let (doc, text) = opened(&fx.engine, &path);
        fx.replace(&path, "{\"a\": 1}\n");
        fx.land(doc, &text, 1);
        assert!(matches!(
            fx.engine.save(
                doc,
                "{}",
                2,
                SaveKind::Auto {
                    composing: true,
                    writing_tools: false
                }
            ),
            Err(SaveRefused::Composing)
        ));
        assert!(fx.engine.snapshots(doc).unwrap().is_empty());
        assert_eq!(fx.draft(&path), None);
    }

    #[test]
    fn a_moved_file_keeps_its_snapshots_and_read_only_files_never_land() {
        let fx = fixture();
        let path = fx.file("notes.md", "one\n");
        let (doc, text) = opened(&fx.engine, &path);
        fx.replace(&path, "two\n");
        fx.land(doc, &text, 1);
        let to = fx.root.join("CLAUDE.md");
        fs::rename(&path, &to).unwrap();
        fx.engine.moved(doc, &to).unwrap();
        assert_eq!(fx.engine.snapshots(doc).unwrap().len(), 2);
        fx.replace(&to, "three\n");
        let (landing, _) = fx.land(doc, "two\n", 2);
        assert!(landing.marked, "an agent file now");

        fs::remove_file(&to).unwrap();
        let fifo = std::ffi::CString::new(to.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: the path outlives the call.
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        assert!(fx.engine.observe(doc).unwrap(), "a FIFO doesn't stall");
        let refused = fx.engine.save(doc, "three\n", 4, auto());
        assert!(
            matches!(refused, Err(SaveRefused::Unreadable)),
            "{refused:?}"
        );

        let binary = fx.root.join("latin1.md");
        fs::write(&binary, b"caf\xe9\n").unwrap();
        let opened = fx.engine.open(&binary).unwrap();
        assert!(matches!(opened.contents, text::Opened::Other(_)));
        fs::write(&binary, b"caf\xe9 au lait\n").unwrap();
        assert!(fx.engine.observe(opened.doc).unwrap());
        assert!(matches!(
            fx.engine.land(opened.doc, "", 1),
            Err(EngineError::NotText)
        ));
        assert!(matches!(
            fx.engine.save(opened.doc, "", 1, SaveKind::Explicit),
            Err(SaveRefused::ReadOnly)
        ));
        fx.engine.close(opened.doc);
        assert!(matches!(
            fx.engine.observe(opened.doc),
            Err(EngineError::Closed)
        ));
    }

    #[derive(Clone, Debug)]
    enum Op {
        /// Another app writes the file: a line replaced, inserted, deleted
        /// or extended, by tmp-and-rename, truncate-and-write or append.
        Write {
            how: u8,
            line: prop::sample::Index,
            kind: u8,
        },
        Delete,
        RenameAway,
        Type {
            at: prop::sample::Index,
            delete: u8,
            insert: bool,
        },
        Observe,
        Land,
        /// Commits one landing made at the buffer's version, the newest by default.
        Commit {
            which: Option<prop::sample::Index>,
        },
        /// Observe, land and commit with no edit between, as Swift mostly does.
        Sync,
        /// An autosave stamped `back` versions ago.
        Autosave {
            back: u8,
            composing: bool,
            writing_tools: bool,
        },
        CmdS,
        Decide {
            which: prop::sample::Index,
            decision: u8,
        },
        Restore {
            which: prop::sample::Index,
        },
        /// Claude edits the file; a second writer may get in inside the call.
        AgentWrite {
            session: u8,
            line: prop::sample::Index,
            intrude: bool,
            pre_late: bool,
            post_late: bool,
            how: u8,
        },
        /// A hook's queued claim arrives.
        Deliver {
            which: prop::sample::Index,
        },
        Stop {
            session: u8,
        },
        GitCommit,
        GitCheckout {
            which: prop::sample::Index,
        },
        Moved,
        Tick {
            ms: u16,
        },
    }

    fn op() -> impl Strategy<Value = Op> {
        use prop::sample::Index;
        prop_oneof![
            6 => (0..3u8, any::<Index>(), 0..4u8).prop_map(|(how, line, kind)| Op::Write { how, line, kind }),
            1 => Just(Op::Delete),
            1 => Just(Op::RenameAway),
            8 => (any::<Index>(), 0..3u8, any::<bool>()).prop_map(|(at, delete, insert)| Op::Type { at, delete, insert }),
            8 => Just(Op::Observe),
            6 => Just(Op::Land),
            6 => any::<Index>().prop_map(|which| Op::Commit { which: Some(which) }),
            6 => Just(Op::Sync),
            5 => (prop_oneof![4 => Just(0u8), 1 => 1..4u8], prop::bool::weighted(0.1), prop::bool::weighted(0.1))
                .prop_map(|(back, composing, writing_tools)| Op::Autosave { back, composing, writing_tools }),
            2 => Just(Op::CmdS),
            3 => (any::<Index>(), 0..3u8).prop_map(|(which, decision)| Op::Decide { which, decision }),
            1 => any::<Index>().prop_map(|which| Op::Restore { which }),
            5 => (0..2u8, any::<Index>(), prop::bool::weighted(0.25), prop::bool::weighted(0.25), prop::bool::weighted(0.4), 0..2u8)
                .prop_map(|(session, line, intrude, pre_late, post_late, how)| {
                    Op::AgentWrite { session, line, intrude, pre_late, post_late, how }
                }),
            4 => any::<Index>().prop_map(|which| Op::Deliver { which }),
            3 => (0..2u8).prop_map(|session| Op::Stop { session }),
            1 => Just(Op::GitCommit),
            1 => any::<Index>().prop_map(|which| Op::GitCheckout { which }),
            1 => Just(Op::Moved),
            3 => (0..2_000u16).prop_map(|ms| Op::Tick { ms }),
        ]
    }

    /// A pending change or conflict as Swift tracks it: its live UTF-16 range.
    struct Live {
        id: ChangeId,
        start: u32,
        end: u32,
        marked: bool,
        conflict: bool,
    }

    /// The test's side of the engine: the buffer and what Swift tracks, and
    /// what the writers did, to check the engine against.
    struct Run {
        fx: Fixture,
        repo: PathBuf,
        path: PathBuf,
        doc: DocId,
        buffer: String,
        version: u64,
        /// Buffers by version, oldest first, for autosaves still in flight.
        history: Vec<(u64, String)>,
        landings: Vec<Landing>,
        /// Each landed change's ancestor and disk hashes.
        links: HashMap<ChangeId, (Hash, Hash)>,
        live: Vec<Live>,
        floor: Option<u64>,
        /// Versions that must never be lost: each another writer left in the
        /// file when the engine looked, and each buffer a landing or restore
        /// replaced. The document's own saves are history its undo holds.
        ever: HashMap<Hash, Vec<u8>>,
        /// The file holds the document's own save.
        ours: bool,
        holds: Vec<(u8, PathBuf)>,
        queued: Vec<(u8, bool, PathBuf, Claim)>,
        /// Each session's own writes, from hash to hash, that its claims declared.
        honest: Vec<(u8, Hash, Hash)>,
        blobs: Vec<Hash>,
        commits: Vec<String>,
        serial: u32,
    }

    fn hook(
        event: &str,
        session: u8,
        id: &str,
        path: &Path,
        hash: Option<Hash>,
        declared: Option<Hash>,
    ) -> Claim {
        let session = format!("s{session}");
        let hash = hash.map(|hash| hash.to_hex().to_string());
        let declared = declared.map(|hash| hash.to_hex().to_string());
        Claim::parse(Fields {
            event,
            vendor: "claude",
            session: &session,
            tool_use_id: Some(id),
            tool: Some("Edit"),
            path: Some(path.to_str().unwrap()),
            hash: hash.as_deref(),
            declared: declared.as_deref(),
        })
        .unwrap()
    }

    fn units(text: &str) -> u32 {
        text.encode_utf16().count() as u32
    }

    /// `text` with one line changed by `kind`, the new line named `token`.
    fn rewrite(text: &str, line: prop::sample::Index, kind: u8, token: &str) -> String {
        let mut lines: Vec<String> = text.split_inclusive(['\n']).map(str::to_owned).collect();
        let at = line.index(lines.len() + 1);
        let ending = if token.len().is_multiple_of(3) {
            "\r\n"
        } else {
            "\n"
        };
        match kind {
            0 if at < lines.len() => lines[at] = format!("{token}{ending}"),
            2 if at < lines.len() => {
                lines.remove(at);
            }
            3 if at < lines.len() => {
                let body = lines[at].trim_end_matches(['\n', '\r']).to_owned();
                let end = lines[at][body.len()..].to_owned();
                lines[at] = format!("{body} {token}{end}");
            }
            _ => lines.insert(at, format!("{token}{ending}")),
        }
        lines.concat()
    }

    impl Run {
        fn new() -> Run {
            let mut fx = fixture();
            // The rules, not durability, which the store's own tests check.
            fx.engine.store.sync = false;
            let repo = fx.root.join("repo");
            let text = "# Notes\n\nalpha one\n\nbeta two\n\ngamma three\n";
            let path = fx.file("repo/notes.md", text);
            git(&repo, &["init", "-q"]);
            let (doc, buffer) = opened(&fx.engine, &path);
            Run {
                repo,
                path,
                doc,
                history: vec![(0, buffer.clone())],
                ever: HashMap::from([(
                    blake3::hash(buffer.as_bytes()),
                    buffer.clone().into_bytes(),
                )]),
                buffer,
                version: 0,
                landings: Vec::new(),
                links: HashMap::new(),
                live: Vec::new(),
                floor: None,
                holds: Vec::new(),
                queued: Vec::new(),
                honest: Vec::new(),
                blobs: Vec::new(),
                commits: Vec::new(),
                serial: 0,
                ours: false,
                fx,
            }
        }

        fn token(&mut self, prefix: &str) -> String {
            self.serial += 1;
            format!("{prefix}{}", self.serial)
        }

        fn disk(&self) -> Option<Vec<u8>> {
            fs::read(&self.path).ok()
        }

        fn put(&self, bytes: &str, how: u8) {
            match how {
                0 => self.fx.replace(&self.path, bytes),
                _ => fs::write(&self.path, bytes).unwrap(),
            }
        }

        fn doc<T>(&self, read: impl FnOnce(&Doc) -> T) -> T {
            read(&self.fx.engine.state().docs[&self.doc])
        }

        fn held(&self) -> bool {
            self.holds.iter().any(|(_, path)| *path == self.path)
        }

        /// Replaces the buffer's UTF-16 range, as the user or Swift does,
        /// carrying live ranges and the version along.
        fn edit(&mut self, edits: &[Edit]) {
            self.buffer = merge::apply(&self.buffer, edits);
            for live in &mut self.live {
                live.start = merge::map_offset(edits, live.start, merge::Bias::Before);
                live.end = merge::map_offset(edits, live.end, merge::Bias::After);
            }
            self.version += 1;
            self.history.push((self.version, self.buffer.clone()));
        }

        /// The session's declared writes chain `from` to `to`: the content
        /// proof record 0007 asks for a name.
        fn proven(&self, session: &str, from: Hash, to: Hash) -> bool {
            let mut reached = vec![from];
            let mut grew = true;
            while grew {
                grew = false;
                for (s, a, b) in &self.honest {
                    if format!("s{s}") == session && reached.contains(a) && !reached.contains(b) {
                        reached.push(*b);
                        grew = true;
                    }
                }
            }
            reached.contains(&to)
        }

        fn check_origin(
            &self,
            origin: &Origin,
            (from, to): (Hash, Hash),
        ) -> Result<(), TestCaseError> {
            match origin {
                Origin::Agent { session, .. } => {
                    prop_assert!(
                        self.proven(session, from, to),
                        "{origin:?} named without proof"
                    )
                }
                Origin::Git { .. } => prop_assert!(
                    self.blobs.contains(&to),
                    "git named for bytes it never staged"
                ),
                Origin::External => {}
                Origin::User => prop_assert!(false, "a landing named the user"),
                Origin::Collaborator { .. } => {
                    prop_assert!(false, "a landing named a collaborator")
                }
            }
            Ok(())
        }

        fn step(&mut self, op: &Op) -> Result<(), TestCaseError> {
            let base_before = self.doc(|d| d.base_hash);
            let disk_before = self.disk();
            let conflicted = self.live.iter().any(|live| live.conflict);
            let (mut committed, mut saved) = (false, false);
            let outside = matches!(
                op,
                Op::Write { .. }
                    | Op::Delete
                    | Op::RenameAway
                    | Op::AgentWrite { .. }
                    | Op::GitCheckout { .. }
                    | Op::Moved
            );
            match op.clone() {
                Op::Write { how, line, kind } => {
                    let token = self.token("w");
                    let old = self
                        .disk()
                        .map(|bytes| String::from_utf8(bytes).unwrap())
                        .unwrap_or_default();
                    if how == 2 {
                        let mut file = OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&self.path)
                            .unwrap();
                        writeln!(file, "{token}").unwrap();
                    } else {
                        self.put(&rewrite(&old, line, kind, &token), how);
                    }
                }
                Op::Delete => {
                    let _ = fs::remove_file(&self.path);
                }
                Op::RenameAway => {
                    let away = format!("{}.md", self.token("away"));
                    let away = self.repo.join(away);
                    let _ = fs::rename(&self.path, away);
                }
                Op::Type { at, delete, insert } => {
                    let boundaries: Vec<u32> = std::iter::once(0)
                        .chain(self.buffer.chars().scan(0, |at, c| {
                            *at += c.len_utf16() as u32;
                            Some(*at)
                        }))
                        .collect();
                    let k = at.index(boundaries.len());
                    let end = boundaries[(k + delete as usize).min(boundaries.len() - 1)];
                    let text = if insert {
                        format!("{} 🙂", self.token("u"))
                    } else {
                        String::new()
                    };
                    self.edit(&[Edit {
                        start: boundaries[k],
                        end,
                        text,
                    }]);
                }
                Op::Observe => {
                    let differs = self.fx.engine.observe(self.doc).unwrap();
                    if let Some(bytes) = &disk_before
                        && !self.ours
                    {
                        self.ever.insert(blake3::hash(bytes), bytes.clone());
                        if differs {
                            let (kept, base) = (self.stored(), self.doc(|d| d.base_hash));
                            prop_assert!(
                                kept.contains(&blake3::hash(bytes)),
                                "a new version not kept"
                            );
                            prop_assert!(kept.contains(&base), "an outgoing base not kept");
                        }
                    }
                }
                Op::Land => match self.fx.engine.land(self.doc, &self.buffer, self.version) {
                    Ok(Some(landing)) => {
                        self.ever.insert(
                            blake3::hash(self.buffer.as_bytes()),
                            self.buffer.clone().into_bytes(),
                        );
                        let link = self.doc(|d| (d.base_hash, d.disk.hash().unwrap()));
                        self.check_origin(&landing.origin, link)?;
                        let ids = landing.edits.iter().map(|(id, _)| *id);
                        for id in ids.chain(landing.conflicts.iter().map(|(id, _)| *id)) {
                            self.links.insert(id, link);
                        }
                        self.landings.push(landing);
                    }
                    Ok(None) | Err(EngineError::Waiting | EngineError::NotText) => {}
                    Err(error) => prop_assert!(false, "land: {error:?}"),
                },
                Op::Commit { which } => {
                    let current: Vec<Landing> = self
                        .landings
                        .iter()
                        .filter(|l| l.version == self.version)
                        .cloned()
                        .collect();
                    if !current.is_empty() {
                        let landing = current
                            [which.map_or(current.len() - 1, |which| which.index(current.len()))]
                        .clone();
                        match self.fx.engine.commit(self.doc, landing.id) {
                            Ok(()) => {
                                committed = true;
                                let edits: Vec<Edit> =
                                    landing.edits.iter().map(|(_, e)| e.clone()).collect();
                                let ours: Vec<u16> = self.buffer.encode_utf16().collect();
                                if let Some(covering) = &landing.covering {
                                    let one =
                                        merge::apply(&self.buffer, std::slice::from_ref(covering));
                                    prop_assert_eq!(one, merge::apply(&self.buffer, &edits));
                                }
                                self.live.retain(|live| live.marked);
                                // Swift bumps the version only when a landing edits the buffer.
                                if !edits.is_empty() {
                                    self.edit(&edits);
                                    self.floor = Some(landing.version);
                                }
                                let after: Vec<u16> = self.buffer.encode_utf16().collect();
                                for (id, edit) in &landing.edits {
                                    let start =
                                        merge::map_offset(&edits, edit.start, merge::Bias::Before);
                                    let end = start + units(&edit.text);
                                    self.live.push(Live {
                                        id: *id,
                                        start,
                                        end,
                                        marked: landing.marked,
                                        conflict: false,
                                    });
                                }
                                for (id, conflict) in &landing.conflicts {
                                    let start = merge::map_offset(
                                        &edits,
                                        conflict.start,
                                        merge::Bias::Before,
                                    );
                                    let kept =
                                        &ours[conflict.start as usize..conflict.end as usize];
                                    let end = start + kept.len() as u32;
                                    prop_assert_eq!(
                                        &after[start as usize..end as usize],
                                        kept,
                                        "a conflict lost yours"
                                    );
                                    self.live.push(Live {
                                        id: *id,
                                        start,
                                        end,
                                        marked: true,
                                        conflict: true,
                                    });
                                }
                                self.landings.clear();
                            }
                            Err(Stale) => self.landings.retain(|l| l.id != landing.id),
                        }
                    }
                }
                Op::Autosave {
                    back,
                    composing,
                    writing_tools,
                } => {
                    let k = self.history.len() - 1 - (back as usize).min(self.history.len() - 1);
                    let (version, buffer) = self.history[k].clone();
                    let held = self.held();
                    let kind = SaveKind::Auto {
                        composing,
                        writing_tools,
                    };
                    let result = self.fx.engine.save(self.doc, &buffer, version, kind);
                    let stale = self.floor.is_some_and(|floor| version <= floor);
                    prop_assert_eq!(
                        stale,
                        matches!(result, Err(SaveRefused::Stale)),
                        "{:?}",
                        result
                    );
                    match result {
                        Ok(hash) => {
                            saved = true;
                            prop_assert!(
                                !conflicted && !held && !composing && !writing_tools,
                                "an autosave while refusing"
                            );
                            prop_assert_eq!(
                                disk_before.as_deref().map(blake3::hash),
                                Some(base_before),
                                "a write over a change"
                            );
                            prop_assert_eq!(self.disk(), Some(buffer.clone().into_bytes()));
                            prop_assert_eq!(hash, blake3::hash(buffer.as_bytes()));
                        }
                        Err(SaveRefused::Stale) => {}
                        Err(SaveRefused::Io(error)) => prop_assert!(false, "{error}"),
                        Err(_) => {
                            prop_assert_eq!(self.draft(), Some(blake3::hash(buffer.as_bytes())))
                        }
                    }
                }
                Op::CmdS => {
                    let result = self.fx.engine.save(
                        self.doc,
                        &self.buffer,
                        self.version,
                        SaveKind::Explicit,
                    );
                    match result {
                        Ok(_) => {
                            saved = true;
                            prop_assert!(!conflicted, "Cmd-S during a conflict");
                            let over = disk_before.as_deref().map(blake3::hash);
                            prop_assert!(
                                over.is_none() || over == Some(base_before),
                                "a write over a change"
                            );
                            prop_assert_eq!(self.disk(), Some(self.buffer.clone().into_bytes()));
                        }
                        Err(SaveRefused::Io(error)) => prop_assert!(false, "{error}"),
                        Err(SaveRefused::Stale) => {
                            prop_assert!(false, "the current buffer is never stale")
                        }
                        Err(_) => prop_assert_eq!(
                            self.draft(),
                            Some(blake3::hash(self.buffer.as_bytes()))
                        ),
                    }
                }
                Op::Decide { which, decision } => {
                    if !self.live.is_empty() {
                        let live = self.live.remove(which.index(self.live.len()));
                        let units16: Vec<u16> = self.buffer.encode_utf16().collect();
                        let current =
                            String::from_utf16(&units16[live.start as usize..live.end as usize])
                                .unwrap();
                        let decision =
                            [Decision::Keep, Decision::Other, Decision::Both][decision as usize];
                        if let Some(text) =
                            self.fx.engine.decide(self.doc, live.id, decision, &current)
                        {
                            self.edit(&[Edit {
                                start: live.start,
                                end: live.end,
                                text,
                            }]);
                        }
                    }
                }
                Op::Restore { which } => {
                    let snapshots = self.fx.engine.snapshots(self.doc).unwrap();
                    if !snapshots.is_empty() {
                        let snapshot = &snapshots[which.index(snapshots.len())];
                        let text = self
                            .fx
                            .engine
                            .restore(self.doc, snapshot, &self.buffer)
                            .unwrap();
                        self.ever.insert(
                            blake3::hash(self.buffer.as_bytes()),
                            self.buffer.clone().into_bytes(),
                        );
                        let end = units(&self.buffer);
                        self.edit(&[Edit {
                            start: 0,
                            end,
                            text,
                        }]);
                    }
                }
                Op::AgentWrite {
                    session,
                    line,
                    intrude,
                    pre_late,
                    post_late,
                    how,
                } => {
                    if let Some(old) = self.disk() {
                        let old = String::from_utf8(old).unwrap();
                        let token = self.token("a");
                        let new = rewrite(&old, line, 1, &token);
                        let id = self.token("toolu_");
                        let path = self.path.clone();
                        let (from, declared) =
                            (blake3::hash(old.as_bytes()), blake3::hash(new.as_bytes()));
                        let pre = hook(
                            "PreToolUse",
                            session,
                            &id,
                            &path,
                            Some(from),
                            Some(declared),
                        );
                        if pre_late {
                            self.queued.push((session, true, path.clone(), pre));
                        } else {
                            self.deliver(session, true, path.clone(), pre)?;
                        }
                        self.put(&new, how);
                        let after = if intrude {
                            let other = self.token("i");
                            let intruded = rewrite(&new, line, 3, &other);
                            self.put(&intruded, 1);
                            intruded
                        } else {
                            self.honest.push((session, from, declared));
                            new
                        };
                        let post = hook(
                            "PostToolUse",
                            session,
                            &id,
                            &path,
                            Some(blake3::hash(after.as_bytes())),
                            None,
                        );
                        if post_late {
                            self.queued.push((session, false, path, post));
                        } else {
                            self.deliver(session, false, path, post)?;
                        }
                    }
                }
                Op::Deliver { which } => {
                    if !self.queued.is_empty() {
                        let (session, pre, path, claim) =
                            self.queued.remove(which.index(self.queued.len()));
                        self.deliver(session, pre, path, claim)?;
                    }
                }
                Op::Stop { session } => {
                    let held = self.held();
                    let updates = self.fx.engine.claim(stop(&format!("s{session}"))).unwrap();
                    self.holds.retain(|(s, _)| *s != session);
                    self.updates(held, &updates)?;
                }
                Op::GitCommit => {
                    git(&self.repo, &["add", "-A"]);
                    git(&self.repo, &["commit", "-q", "--allow-empty", "-m", "c"]);
                    self.commits
                        .push(git(&self.repo, &["rev-parse", "HEAD"]).trim().to_owned());
                    if let Some(bytes) = self.disk() {
                        self.blobs.push(blake3::hash(&bytes));
                    }
                    self.fx.engine.git_changed(&self.repo.join(".git"));
                }
                Op::GitCheckout { which } => {
                    if !self.commits.is_empty() {
                        let commit = self.commits[which.index(self.commits.len())].clone();
                        let name = self.path.file_name().unwrap().to_str().unwrap().to_owned();
                        let _ = Command::new("git")
                            .current_dir(&self.repo)
                            .env("GIT_CONFIG_GLOBAL", "/dev/null")
                            .env("GIT_CONFIG_NOSYSTEM", "1")
                            .args(["checkout", "-q", &commit, "--", &name])
                            .output()
                            .unwrap();
                        self.fx.engine.git_changed(&self.repo.join(".git"));
                    }
                }
                Op::Moved => {
                    if self.path.exists() {
                        let to = format!("{}.md", self.token("moved"));
                        let to = self.repo.join(to);
                        fs::rename(&self.path, &to).unwrap();
                        self.fx.engine.moved(self.doc, &to).unwrap();
                        self.path = to;
                    }
                }
                Op::Tick { ms } => self.fx.tick(u64::from(ms)),
                Op::Sync => {
                    for op in [Op::Observe, Op::Land] {
                        self.step(&op)?;
                    }
                    return self.step(&Op::Commit { which: None });
                }
            }

            if saved {
                self.ours = true;
            } else if outside && self.disk() != disk_before {
                self.ours = false;
            }
            let base = self.doc(|d| d.base.clone());
            if blake3::hash(&base) != base_before {
                prop_assert!(committed || saved, "{op:?} moved the base");
            }
            if !outside && self.disk() != disk_before {
                prop_assert!(saved, "{op:?} wrote the file");
            }
            let (stored, file) = (self.stored(), self.disk());
            for (hash, bytes) in &self.ever {
                let kept = file.as_ref() == Some(bytes)
                    || self.buffer.as_bytes() == &bytes[..]
                    || *base == bytes[..]
                    || stored.contains(hash);
                prop_assert!(kept, "{op:?} lost {:?}", String::from_utf8_lossy(bytes));
            }
            Ok(())
        }

        fn deliver(
            &mut self,
            session: u8,
            pre: bool,
            path: PathBuf,
            claim: Claim,
        ) -> Result<(), TestCaseError> {
            let held = self.held();
            let result = self.fx.engine.claim(claim);
            if pre && !self.holds.contains(&(session, path.clone())) {
                self.holds.push((session, path));
            }
            match result {
                Ok(updates) => self.updates(held, &updates),
                Err(refused) => {
                    prop_assert!(false, "{refused:?}");
                    Ok(())
                }
            }
        }

        fn updates(&mut self, held: bool, updates: &[Update]) -> Result<(), TestCaseError> {
            for update in updates {
                if let Update::Relabeled {
                    doc,
                    change,
                    origin,
                } = update
                {
                    prop_assert_eq!(*doc, self.doc);
                    self.check_origin(origin, self.links[change])?;
                    if let Some(live) = self.live.iter_mut().find(|live| live.id == *change) {
                        live.marked = true;
                    }
                }
            }
            let released = updates
                .iter()
                .any(|update| matches!(update, Update::Released(_)));
            prop_assert_eq!(released, held && !self.held(), "{:?}", updates);
            Ok(())
        }

        fn draft(&self) -> Option<Hash> {
            let path = self.doc(|d| d.path.clone());
            self.fx
                .engine
                .store
                .draft(&path)
                .unwrap()
                .map(|draft| draft.hash)
        }

        /// Hashes the store holds for the document's file: history and draft.
        fn stored(&self) -> Vec<Hash> {
            let store = &self.fx.engine.store;
            let path = self.doc(|d| d.path.clone());
            let mut hashes: Vec<Hash> = store.list(&path).unwrap().iter().map(|s| s.hash).collect();
            hashes.extend(store.draft(&path).unwrap().map(|s| s.hash));
            hashes
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(
            std::env::var("PROPTEST_CASES").map_or(CASES, |cases| cases.parse().unwrap())
        ))]

        #[test]
        fn writers_typing_claims_git_and_saves_keep_the_rules(ops in prop::collection::vec(op(), 1..64)) {
            let mut run = Run::new();
            for op in &ops {
                run.step(op)?;
            }
        }
    }

    /// Nightly sets PROPTEST_CASES.
    const CASES: u32 = 256;
}
