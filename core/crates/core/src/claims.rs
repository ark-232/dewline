use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use blake3::Hash;

/// Session and tool use ids are 1 to this many printable ASCII characters.
pub const MAX_ID: usize = 128;
/// A pair of claims explains only a change seen from this long before its
/// PreToolUse arrived to this long after its PostToolUse did.
pub const LINK_GRACE: Duration = Duration::from_secs(5);
/// Landings on a file wait at most this long for an open call's
/// PostToolUse.
pub const OPEN_CALL_WAIT: Duration = Duration::from_secs(10);
/// A session's holds lapse this long after its last hook event.
pub const HOLD_LAPSE: Duration = Duration::from_secs(30 * 60);
/// PATH_MAX: no realpath is longer.
const MAX_PATH: usize = 1024;
/// The ledger forgets its oldest tool uses, and its oldest holds, past this
/// many of each.
const CAPACITY: usize = 4096;

/// A session id or a `tool_use_id`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Id(Box<str>);

impl Id {
    pub fn new(id: &str) -> Option<Id> {
        let printable = id.bytes().all(|byte| (b' '..=b'~').contains(&byte));
        ((1..=MAX_ID).contains(&id.len()) && printable).then(|| Id(id.into()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// The agent whose hooks sent a claim.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Vendor {
    Claude,
    Codex,
}

/// A vendor's session.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
struct Writer {
    vendor: Vendor,
    session: Id,
}

/// The tools a claim may name: Claude Code's file tools, and Codex's
/// `apply_patch` with one claim per file the patch names. Bash and every
/// other tool are refused: a hook around a command can't say which bytes it
/// wrote.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tool {
    Read,
    Edit,
    MultiEdit,
    Write,
    ApplyPatch,
}

impl Tool {
    fn parse(vendor: Vendor, name: &str) -> Option<Tool> {
        match (vendor, name) {
            (Vendor::Claude, "Read") => Some(Tool::Read),
            (Vendor::Claude, "Edit") => Some(Tool::Edit),
            (Vendor::Claude, "MultiEdit") => Some(Tool::MultiEdit),
            (Vendor::Claude, "Write") => Some(Tool::Write),
            (Vendor::Codex, "apply_patch") => Some(Tool::ApplyPatch),
            _ => None,
        }
    }
}

/// The fields of one `notify` line as `dewline notify` sent them, all
/// untrusted.
#[derive(Clone, Copy, Debug, Default)]
pub struct Fields<'a> {
    pub event: &'a str,
    /// `claude` or `codex`.
    pub vendor: &'a str,
    pub session: &'a str,
    pub tool_use_id: Option<&'a str>,
    pub tool: Option<&'a str>,
    /// The file's realpath.
    pub path: Option<&'a str>,
    /// BLAKE3 hex of the file's bytes, before the tool at PreToolUse and
    /// after it at PostToolUse; absent when there was no file.
    pub hash: Option<&'a str>,
    /// PreToolUse only: BLAKE3 hex of the bytes the tool's declared change
    /// makes of the bytes read then (Write's content, Edit's strings, Codex's
    /// patch).
    pub declared: Option<&'a str>,
}

/// One hook's report. It carries hashes, never content, and only labels:
/// nothing in this module writes a file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Claim {
    writer: Writer,
    event: Event,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Event {
    PreToolUse(ToolUse),
    PostToolUse(ToolUse),
    /// The session loaded the file as instructions.
    InstructionsLoaded(PathBuf),
    /// Stop, StopFailure, or UserPromptSubmit, the first hook after an
    /// interrupt.
    TurnEnd,
    SessionEnd,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ToolUse {
    id: Id,
    half: Half,
}

/// A tool use's file as one hook saw it: before the tool for PreToolUse,
/// after it for PostToolUse. No hash: no file.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Half {
    session: Id,
    tool: Tool,
    path: PathBuf,
    hash: Option<Hash>,
    declared: Option<Hash>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Refused {
    /// The named field is missing, too long, unprintable, or names a vendor,
    /// event or tool the ledger doesn't take.
    Invalid(&'static str),
    /// The `tool_use_id` already has this half or both, or was spent or
    /// closed. A replay that differs from the first closes the id.
    Replayed,
    /// The two halves of a `tool_use_id` name different sessions, tools or
    /// files. The id is closed.
    Mismatched,
}

impl Claim {
    pub fn parse(fields: Fields) -> Result<Claim, Refused> {
        let vendor = match fields.vendor {
            "claude" => Vendor::Claude,
            "codex" => Vendor::Codex,
            _ => return Err(Refused::Invalid("vendor")),
        };
        let session = Id::new(fields.session).ok_or(Refused::Invalid("session id"))?;
        let hash = |hex: Option<&str>, field| {
            hex.map(|hex| Hash::from_hex(hex).map_err(|_| Refused::Invalid(field)))
                .transpose()
        };
        let path = || match fields.path {
            Some(path) if path.starts_with('/') && path.len() <= MAX_PATH => {
                Ok(PathBuf::from(path))
            }
            _ => Err(Refused::Invalid("path")),
        };
        let tool_use = || {
            let tool = fields.tool.and_then(|name| Tool::parse(vendor, name));
            Ok(ToolUse {
                id: fields
                    .tool_use_id
                    .and_then(Id::new)
                    .ok_or(Refused::Invalid("tool_use_id"))?,
                half: Half {
                    session: session.clone(),
                    tool: tool.ok_or(Refused::Invalid("tool"))?,
                    path: path()?,
                    hash: hash(fields.hash, "hash")?,
                    declared: hash(fields.declared, "declared")?,
                },
            })
        };
        let event = match fields.event {
            "PreToolUse" => Event::PreToolUse(tool_use()?),
            "PostToolUse" => Event::PostToolUse(tool_use()?),
            "InstructionsLoaded" => Event::InstructionsLoaded(path()?),
            "Stop" | "StopFailure" | "UserPromptSubmit" => Event::TurnEnd,
            "SessionEnd" => Event::SessionEnd,
            _ => return Err(Refused::Invalid("event")),
        };
        Ok(Claim {
            writer: Writer { vendor, session },
            event,
        })
    }
}

/// One session's paired writes that take a file from a change's ancestor to
/// its disk bytes: every pair on any run between the two.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chain {
    pub vendor: Vendor,
    pub session: Id,
    uses: Vec<Id>,
}

enum Use {
    /// One half has arrived; `pre` says which.
    Half { pre: bool, half: Half, at: Instant },
    /// Both halves arrived and agree.
    Pair { link: Link, at: Instant },
    /// Spent on a change, or its claims disagreed.
    Closed { at: Instant },
}

impl Use {
    fn at(&self) -> Instant {
        match self {
            Use::Half { at, .. } | Use::Pair { at, .. } | Use::Closed { at } => *at,
        }
    }
}

struct Link {
    session: Id,
    path: PathBuf,
    from: Option<Hash>,
    to: Option<Hash>,
    declared: Option<Hash>,
    pre_at: Instant,
    post_at: Instant,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Until {
    TurnEnd,
    SessionEnd,
}

struct Hold {
    path: PathBuf,
    writer: Writer,
    until: Until,
}

/// What the hooks have claimed: tool uses by vendor and `tool_use_id`,
/// paired in any arrival order, and the autosave holds they put on files.
/// The engine consults it; it changes no bytes.
#[derive(Default)]
pub struct Claims {
    uses: HashMap<(Vendor, Id), Use>,
    holds: Vec<Hold>,
    /// When each session that holds a file last sent a hook event.
    heard: HashMap<Writer, Instant>,
}

impl Claims {
    /// Records `claim`, which arrived at `now`. Claude's PreToolUse holds the
    /// file's autosave until the session's turn ends, InstructionsLoaded
    /// until the session ends, and either lapses `HOLD_LAPSE` after the
    /// session's last hook event.
    pub fn record(&mut self, claim: Claim, now: Instant) -> Result<(), Refused> {
        let Claim { writer, event } = claim;
        let result = match event {
            Event::PreToolUse(tool_use) => {
                if tool_use.half.tool != Tool::ApplyPatch {
                    self.hold(&tool_use.half.path, &writer, Until::TurnEnd);
                }
                self.half(writer.vendor, tool_use, true, now)
            }
            Event::PostToolUse(tool_use) => self.half(writer.vendor, tool_use, false, now),
            Event::InstructionsLoaded(path) => {
                self.hold(&path, &writer, Until::SessionEnd);
                Ok(())
            }
            Event::TurnEnd => {
                self.holds
                    .retain(|hold| hold.writer != writer || hold.until != Until::TurnEnd);
                Ok(())
            }
            Event::SessionEnd => {
                self.holds.retain(|hold| hold.writer != writer);
                Ok(())
            }
        };
        if self.holds.iter().any(|hold| hold.writer == writer) {
            self.heard.insert(writer, now);
        }
        let heard = &self.heard;
        self.holds.retain(|hold| {
            heard
                .get(&hold.writer)
                .is_some_and(|at| now.saturating_duration_since(*at) <= HOLD_LAPSE)
        });
        let holding: HashSet<&Writer> = self.holds.iter().map(|hold| &hold.writer).collect();
        self.heard.retain(|writer, _| holding.contains(writer));
        result
    }

    fn half(
        &mut self,
        vendor: Vendor,
        tool_use: ToolUse,
        pre: bool,
        now: Instant,
    ) -> Result<(), Refused> {
        let ToolUse { id, half } = tool_use;
        // A Read only holds: it never links, so it needs no pair.
        if half.tool == Tool::Read {
            return Ok(());
        }
        let key = (vendor, id);
        let (entry, result) = match self.uses.remove(&key) {
            None => (Use::Half { pre, half, at: now }, Ok(())),
            Some(Use::Half {
                pre: first_pre,
                half: first,
                at,
            }) if first_pre == pre => {
                if first == half {
                    let first = Use::Half {
                        pre,
                        half: first,
                        at,
                    };
                    (first, Err(Refused::Replayed))
                } else {
                    (Use::Closed { at: now }, Err(Refused::Replayed))
                }
            }
            Some(Use::Half {
                half: first,
                at: first_at,
                ..
            }) => {
                let ((before, pre_at), (after, post_at)) = if pre {
                    ((half, now), (first, first_at))
                } else {
                    ((first, first_at), (half, now))
                };
                if (&before.session, before.tool, &before.path)
                    == (&after.session, after.tool, &after.path)
                {
                    let link = Link {
                        session: before.session,
                        path: before.path,
                        from: before.hash,
                        to: after.hash,
                        declared: before.declared,
                        pre_at,
                        post_at,
                    };
                    (Use::Pair { link, at: now }, Ok(()))
                } else {
                    (Use::Closed { at: now }, Err(Refused::Mismatched))
                }
            }
            Some(entry) => (entry, Err(Refused::Replayed)),
        };
        self.uses.insert(key, entry);
        if self.uses.len() > CAPACITY
            && let Some(oldest) = self
                .uses
                .iter()
                .min_by_key(|(_, entry)| entry.at())
                .map(|(key, _)| key.clone())
        {
            self.uses.remove(&oldest);
        }
        result
    }

    fn hold(&mut self, path: &Path, writer: &Writer, until: Until) {
        let held = self
            .holds
            .iter()
            .any(|hold| hold.path == path && hold.writer == *writer && hold.until == until);
        if !held {
            self.holds.push(Hold {
                path: path.to_path_buf(),
                writer: writer.clone(),
                until,
            });
            if self.holds.len() > CAPACITY {
                self.holds.remove(0);
            }
        }
    }

    /// Whether a hook's claim holds the autosave of the file at `path` at
    /// `now`.
    pub fn held(&self, path: &Path, now: Instant) -> bool {
        self.holds.iter().any(|hold| {
            hold.path == path
                && self
                    .heard
                    .get(&hold.writer)
                    .is_some_and(|at| now.saturating_duration_since(*at) <= HOLD_LAPSE)
        })
    }

    /// Whether a hooked call on `path` is open at `now`: its PreToolUse
    /// arrived at most `OPEN_CALL_WAIT` before and its PostToolUse hasn't.
    /// Landings on the file wait while it is, since Codex truncates the file
    /// and then writes it.
    pub fn open_call(&self, path: &Path, now: Instant) -> bool {
        self.uses.values().any(|entry| {
            matches!(entry, Use::Half { pre: true, half, at }
                if half.path == path && now.saturating_duration_since(*at) <= OPEN_CALL_WAIT)
        })
    }

    /// The chain of one session's pairs on `path` that takes it from `from`
    /// to `to`, for a change seen at `seen`. A pair counts only when its
    /// PreToolUse declared the bytes its PostToolUse found, so a second
    /// writer inside the call breaks it; only when no change has spent it;
    /// and only within `LINK_GRACE` of the change. None when no session's
    /// pairs link the two, or more than one's do.
    pub fn chain(&self, path: &Path, from: &Hash, to: &Hash, seen: Instant) -> Option<Chain> {
        if from == to {
            return None;
        }
        let mut writers: BTreeMap<(Vendor, &Id), Vec<(&Id, &Link)>> = BTreeMap::new();
        for ((vendor, id), entry) in &self.uses {
            if let Use::Pair { link, .. } = entry
                && link.declared.is_some()
                && link.declared == link.to
                && link.path == path
                && link.pre_at <= seen + LINK_GRACE
                && seen <= link.post_at + LINK_GRACE
            {
                writers
                    .entry((*vendor, &link.session))
                    .or_default()
                    .push((id, link));
            }
        }
        let mut found = None;
        for ((vendor, session), links) in writers {
            if let Some(uses) = between(&links, Some(*from), Some(*to)) {
                if found.is_some() {
                    return None;
                }
                found = Some(Chain {
                    vendor,
                    session: session.clone(),
                    uses,
                });
            }
        }
        found
    }

    /// Closes the chain's tool uses once the engine commits the change they
    /// explain, so no later change can use them.
    pub fn spend(&mut self, chain: &Chain, now: Instant) {
        for id in &chain.uses {
            if let Some(entry) = self.uses.get_mut(&(chain.vendor, id.clone())) {
                *entry = Use::Closed { at: now };
            }
        }
    }
}

/// Every use on some run of `links` from `from` to `to`, so that spending
/// them leaves no loop of the session's for a later writer's change to use.
/// None when no run reaches `to`.
fn between(links: &[(&Id, &Link)], from: Option<Hash>, to: Option<Hash>) -> Option<Vec<Id>> {
    let reach = |start: Option<Hash>, forward: bool| {
        let mut next: HashMap<Option<Hash>, Vec<Option<Hash>>> = HashMap::new();
        for (_, link) in links {
            let (a, b) = if forward {
                (link.from, link.to)
            } else {
                (link.to, link.from)
            };
            next.entry(a).or_default().push(b);
        }
        let mut reached = HashSet::from([start]);
        let mut queue = vec![start];
        while let Some(state) = queue.pop() {
            for &after in next.get(&state).into_iter().flatten() {
                if reached.insert(after) {
                    queue.push(after);
                }
            }
        }
        reached
    };
    let ahead = reach(from, true);
    if !ahead.contains(&to) {
        return None;
    }
    let behind = reach(to, false);
    let mut uses: Vec<Id> = links
        .iter()
        .filter(|(_, link)| ahead.contains(&link.from) && behind.contains(&link.to))
        .map(|(id, _)| (*id).clone())
        .collect();
    uses.sort();
    Some(uses)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    const P: &str = "/Users/someone/repo/CLAUDE.md";
    const Q: &str = "/Users/someone/repo/AGENTS.md";

    fn h(state: &str) -> Hash {
        blake3::hash(state.as_bytes())
    }

    fn hex(state: &str) -> String {
        h(state).to_hex().to_string()
    }

    /// A PreToolUse from `vendor`'s `session` on `path`, read at `before`,
    /// declaring a change that makes `declared`.
    fn pre_by(
        vendor: &str,
        session: &str,
        id: &str,
        tool: &str,
        path: &str,
        before: &str,
        declared: &str,
    ) -> Claim {
        let (before, declared) = (hex(before), hex(declared));
        Claim::parse(Fields {
            event: "PreToolUse",
            vendor,
            session,
            tool_use_id: Some(id),
            tool: Some(tool),
            path: Some(path),
            hash: Some(&before),
            declared: Some(&declared),
        })
        .unwrap()
    }

    fn post_by(
        vendor: &str,
        session: &str,
        id: &str,
        tool: &str,
        path: &str,
        after: &str,
    ) -> Claim {
        let after = hex(after);
        Claim::parse(Fields {
            event: "PostToolUse",
            vendor,
            session,
            tool_use_id: Some(id),
            tool: Some(tool),
            path: Some(path),
            hash: Some(&after),
            declared: None,
        })
        .unwrap()
    }

    fn pre(session: &str, id: &str, tool: &str, path: &str, before: &str, declared: &str) -> Claim {
        pre_by("claude", session, id, tool, path, before, declared)
    }

    fn post(session: &str, id: &str, tool: &str, path: &str, after: &str) -> Claim {
        post_by("claude", session, id, tool, path, after)
    }

    fn bare(event: &str, session: &str) -> Claim {
        let vendor = "claude";
        Claim::parse(Fields {
            event,
            vendor,
            session,
            ..Fields::default()
        })
        .unwrap()
    }

    fn loaded(session: &str, path: &str) -> Claim {
        let (event, vendor, path) = ("InstructionsLoaded", "claude", Some(path));
        Claim::parse(Fields {
            event,
            vendor,
            session,
            path,
            ..Fields::default()
        })
        .unwrap()
    }

    fn ids(ids: &[&str]) -> Vec<Id> {
        ids.iter().map(|id| Id::new(id).unwrap()).collect()
    }

    #[test]
    fn ids_are_1_to_128_printable_ascii_characters() {
        let long = "a".repeat(MAX_ID);
        let longer = "a".repeat(MAX_ID + 1);
        #[rustfmt::skip]
        let table: &[(&str, bool)] = &[
            ("", false), ("s", true), (&long, true), (&longer, false),
            ("0b6c5a7e-6a1b-4f0e-9c1d-2f8e1a3b4c5d", true), ("with space ~!", true),
            ("tab\t", false), ("new\nline", false), ("nul\0", false), ("del\x7f", false),
            ("caf\u{e9}", false), ("\u{202e}rtl", false),
        ];
        for &(id, valid) in table {
            assert_eq!(Id::new(id).is_some(), valid, "{id:?}");
            let stop = Fields {
                event: "Stop",
                vendor: "claude",
                session: id,
                ..Fields::default()
            };
            assert_eq!(Claim::parse(stop).is_ok(), valid, "session {id:?}");
            let edit = Fields {
                event: "PreToolUse",
                vendor: "claude",
                session: "s",
                tool_use_id: Some(id),
                tool: Some("Edit"),
                path: Some(P),
                ..Fields::default()
            };
            assert_eq!(Claim::parse(edit).is_ok(), valid, "tool_use_id {id:?}");
        }
    }

    #[test]
    fn parse_refuses_what_the_ledger_does_not_take() {
        let a = hex("a");
        let long_path = format!("/{}", "p".repeat(MAX_PATH));
        let edit = Fields {
            event: "PreToolUse",
            vendor: "claude",
            session: "s",
            tool_use_id: Some("t"),
            tool: Some("Edit"),
            path: Some(P),
            hash: Some(&a),
            declared: Some(&a),
        };
        let invalid = Refused::Invalid;
        #[rustfmt::skip]
        let table: Vec<(Fields, Refused)> = vec![
            (Fields { event: "Notification", ..edit }, invalid("event")),
            (Fields { event: "pretooluse", ..edit }, invalid("event")),
            (Fields { vendor: "cursor", ..edit }, invalid("vendor")),
            (Fields { vendor: "Claude", ..edit }, invalid("vendor")),
            (Fields { vendor: "", ..edit }, invalid("vendor")),
            (Fields { tool: Some("Bash"), ..edit }, invalid("tool")),
            (Fields { vendor: "codex", tool: Some("Bash"), ..edit }, invalid("tool")),
            (Fields { vendor: "codex", tool: Some("Edit"), ..edit }, invalid("tool")),
            (Fields { tool: Some("apply_patch"), ..edit }, invalid("tool")),
            (Fields { event: "PostToolUse", tool: Some("NotebookEdit"), ..edit }, invalid("tool")),
            (Fields { tool: None, ..edit }, invalid("tool")),
            (Fields { tool_use_id: None, ..edit }, invalid("tool_use_id")),
            (Fields { path: None, ..edit }, invalid("path")),
            (Fields { path: Some("CLAUDE.md"), ..edit }, invalid("path")),
            (Fields { path: Some(&long_path), ..edit }, invalid("path")),
            (Fields { hash: Some(&a[1..]), ..edit }, invalid("hash")),
            (Fields { hash: Some("not hex"), ..edit }, invalid("hash")),
            (Fields { declared: Some("not hex"), ..edit }, invalid("declared")),
            (Fields { event: "InstructionsLoaded", path: None, ..edit }, invalid("path")),
        ];
        for (fields, refused) in table {
            assert_eq!(Claim::parse(fields).err(), Some(refused), "{fields:?}");
        }
        let patch = Fields {
            vendor: "codex",
            tool: Some("apply_patch"),
            ..edit
        };
        assert!(Claim::parse(patch).is_ok());
        for event in ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd"] {
            let fields = Fields {
                event,
                vendor: "codex",
                session: "s",
                ..Fields::default()
            };
            assert!(Claim::parse(fields).is_ok(), "{event}");
        }
    }

    /// Claims with what recording each returns; a file, ancestor and disk
    /// state; the vendor, session and tool uses that should link them.
    type Case = (
        &'static str,
        Vec<(Claim, Result<(), Refused>)>,
        (&'static str, &'static str, &'static str),
        Option<(Vendor, &'static str, &'static [&'static str])>,
    );

    #[test]
    fn the_chain_table() {
        let t0 = Instant::now();
        let undeclared = |id, before: &str| {
            let before = hex(before);
            Claim::parse(Fields {
                event: "PreToolUse",
                vendor: "claude",
                session: "s1",
                tool_use_id: Some(id),
                tool: Some("Edit"),
                path: Some(P),
                hash: Some(&before),
                declared: None,
            })
            .unwrap()
        };
        #[rustfmt::skip]
        let table: Vec<Case> = vec![
            ("the agent's own exact write links its ancestor to its disk bytes",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(()))],
                (P, "A", "B"), Some((Vendor::Claude, "s1", &["t1"]))),
            ("the Post may arrive first",
                vec![(post("s1", "t1", "Write", P, "B"), Ok(())), (pre("s1", "t1", "Write", P, "A", "B"), Ok(()))],
                (P, "A", "B"), Some((Vendor::Claude, "s1", &["t1"]))),
            ("a second writer inside the call is Unknown",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", P, "C"), Ok(()))],
                (P, "A", "C"), None),
            ("and the declared bytes alone name nothing",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", P, "C"), Ok(()))],
                (P, "A", "B"), None),
            ("a call that declares no change is Unknown",
                vec![(undeclared("t1", "A"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("edits chain",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s1", "t2", "MultiEdit", P, "B", "C"), Ok(())), (post("s1", "t2", "MultiEdit", P, "C"), Ok(()))],
                (P, "A", "C"), Some((Vendor::Claude, "s1", &["t1", "t2"]))),
            ("a second writer inside one call breaks the chain",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s1", "t2", "Edit", P, "B", "C"), Ok(())), (post("s1", "t2", "Edit", P, "D"), Ok(())),
                     (pre("s1", "t3", "Edit", P, "D", "E"), Ok(())), (post("s1", "t3", "Edit", P, "E"), Ok(()))],
                (P, "A", "E"), None),
            ("Codex's patch links, named Codex",
                vec![(pre_by("codex", "c1", "call_1", "apply_patch", P, "A", "B"), Ok(())),
                     (post_by("codex", "c1", "call_1", "apply_patch", P, "B"), Ok(()))],
                (P, "A", "B"), Some((Vendor::Codex, "c1", &["call_1"]))),
            ("a Codex half can't finish a Claude call",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post_by("codex", "s1", "t1", "apply_patch", P, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("one session id from two vendors is two sessions",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre_by("codex", "s1", "t2", "apply_patch", P, "B", "C"), Ok(())),
                     (post_by("codex", "s1", "t2", "apply_patch", P, "C"), Ok(()))],
                (P, "A", "C"), None),
            ("a broken chain is Unknown",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s1", "t2", "Edit", P, "C", "D"), Ok(())), (post("s1", "t2", "Edit", P, "D"), Ok(()))],
                (P, "A", "D"), None),
            ("a forged ancestor is Unknown",
                vec![(pre("s1", "t1", "Edit", P, "X", "B"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("a claim for another file is Unknown",
                vec![(pre("s1", "t1", "Edit", Q, "A", "B"), Ok(())), (post("s1", "t1", "Edit", Q, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("halves on two files link neither",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", Q, "B"), Err(Refused::Mismatched))],
                (P, "A", "B"), None),
            ("halves from two sessions link nothing",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s2", "t1", "Edit", P, "B"), Err(Refused::Mismatched))],
                (P, "A", "B"), None),
            ("halves naming two tools link nothing",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Write", P, "B"), Err(Refused::Mismatched))],
                (P, "A", "B"), None),
            ("a Read's id can't finish a write",
                vec![(pre("s1", "t1", "Read", P, "A", "B"), Ok(())), (post("s1", "t1", "Write", P, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("a Read never links, even when the file changed under it",
                vec![(pre("s1", "t1", "Read", P, "A", "B"), Ok(())), (post("s1", "t1", "Read", P, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("a session can't finish another's chain",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s2", "t2", "Edit", P, "B", "C"), Ok(())), (post("s2", "t2", "Edit", P, "C"), Ok(()))],
                (P, "A", "C"), None),
            ("two sessions claiming one change name neither",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s2", "t2", "Edit", P, "A", "B"), Ok(())), (post("s2", "t2", "Edit", P, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("no change is no claim",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s1", "t2", "Edit", P, "B", "A"), Ok(())), (post("s1", "t2", "Edit", P, "A"), Ok(()))],
                (P, "A", "A"), None),
            ("a half alone links nothing",
                vec![(pre("s1", "t1", "Edit", P, "A", "B"), Ok(()))],
                (P, "A", "B"), None),
        ];
        for (name, claims, (path, from, to), expected) in table {
            let mut ledger = Claims::default();
            for (claim, result) in claims {
                assert_eq!(ledger.record(claim, t0), result, "{name}");
            }
            let chain = ledger.chain(Path::new(path), &h(from), &h(to), t0);
            let expected = expected.map(|(vendor, session, uses)| Chain {
                vendor,
                session: Id::new(session).unwrap(),
                uses: ids(uses),
            });
            assert_eq!(chain, expected, "{name}");
        }
    }

    #[test]
    fn replays_are_refused_and_link_nothing_new() {
        let t0 = Instant::now();
        let mut ledger = Claims::default();
        ledger
            .record(pre("s1", "t1", "Edit", P, "A", "B"), t0)
            .unwrap();
        let again = ledger.record(pre("s1", "t1", "Edit", P, "A", "B"), t0);
        assert_eq!(again, Err(Refused::Replayed));
        ledger.record(post("s1", "t1", "Edit", P, "B"), t0).unwrap();
        for replay in [
            pre("s1", "t1", "Edit", P, "A", "B"),
            post("s1", "t1", "Edit", P, "B"),
        ] {
            assert_eq!(ledger.record(replay, t0), Err(Refused::Replayed));
        }
        let other = ledger.record(post("s1", "t1", "Edit", P, "X"), t0);
        assert_eq!(other, Err(Refused::Replayed));
        let chain = ledger.chain(Path::new(P), &h("A"), &h("B"), t0).unwrap();
        assert!(ledger.chain(Path::new(P), &h("A"), &h("X"), t0).is_none());

        // Once a committed change spends the chain, the same change again,
        // the file back at A and then B from another writer, is Unknown.
        ledger.spend(&chain, t0);
        assert!(ledger.chain(Path::new(P), &h("A"), &h("B"), t0).is_none());
        for replay in [
            pre("s1", "t1", "Edit", P, "A", "B"),
            post("s1", "t1", "Edit", P, "B"),
        ] {
            assert_eq!(ledger.record(replay, t0), Err(Refused::Replayed));
        }
        assert!(ledger.chain(Path::new(P), &h("A"), &h("B"), t0).is_none());

        // A half replayed with other contents before its pair closes the id:
        // neither version is trusted.
        ledger
            .record(pre("s1", "t2", "Edit", P, "B", "C"), t0)
            .unwrap();
        let other = ledger.record(pre("s1", "t2", "Edit", P, "Y", "C"), t0);
        assert_eq!(other, Err(Refused::Replayed));
        let post = ledger.record(post("s1", "t2", "Edit", P, "C"), t0);
        assert_eq!(post, Err(Refused::Replayed));
        assert!(ledger.chain(Path::new(P), &h("B"), &h("C"), t0).is_none());
        assert!(ledger.chain(Path::new(P), &h("Y"), &h("C"), t0).is_none());
    }

    #[test]
    fn pairs_link_only_changes_seen_near_them() {
        let t0 = Instant::now();
        let mut ledger = Claims::default();
        let pre_at = t0 + Duration::from_secs(10);
        let post_at = t0 + Duration::from_secs(300);
        ledger
            .record(pre("s1", "t1", "Edit", P, "A", "B"), pre_at)
            .unwrap();
        ledger
            .record(post("s1", "t1", "Edit", P, "B"), post_at)
            .unwrap();
        let ask = |seen| ledger.chain(Path::new(P), &h("A"), &h("B"), seen);
        let ms = Duration::from_millis(1);
        assert!(ask(pre_at - LINK_GRACE).is_some());
        assert!(ask(pre_at - LINK_GRACE - ms).is_none());
        assert!(ask(post_at).is_some());
        assert!(ask(post_at + LINK_GRACE).is_some());
        assert!(ask(post_at + LINK_GRACE + ms).is_none());
    }

    #[test]
    fn spending_closes_every_loop_the_change_absorbed() {
        // The session wrote A, B, A, B and X, B between two looks: the engine
        // saw only A to B. No later writer's B to A or B to X is the
        // session's.
        let t0 = Instant::now();
        let mut ledger = Claims::default();
        #[rustfmt::skip]
        let edits = [("t1", "A", "B"), ("t2", "B", "A"), ("t3", "A", "B"), ("t4", "B", "X"), ("t5", "X", "B")];
        for (id, before, after) in edits {
            ledger
                .record(pre("s1", id, "Edit", P, before, after), t0)
                .unwrap();
            ledger.record(post("s1", id, "Edit", P, after), t0).unwrap();
        }
        let chain = ledger.chain(Path::new(P), &h("A"), &h("B"), t0).unwrap();
        assert_eq!(chain.uses, ids(&["t1", "t2", "t3", "t4", "t5"]));
        ledger.spend(&chain, t0);
        for (from, to) in [("A", "B"), ("B", "A"), ("B", "X"), ("X", "B")] {
            let chain = ledger.chain(Path::new(P), &h(from), &h(to), t0);
            assert!(chain.is_none(), "{from} {to}");
        }
        // A later edit past B is not part of the change, and stays.
        ledger
            .record(pre("s1", "t6", "Edit", P, "B", "C"), t0)
            .unwrap();
        ledger.record(post("s1", "t6", "Edit", P, "C"), t0).unwrap();
        let chain = ledger.chain(Path::new(P), &h("A"), &h("C"), t0);
        assert!(chain.is_none(), "t1 to t5 are spent");
        let next = ledger.chain(Path::new(P), &h("B"), &h("C"), t0).unwrap();
        assert_eq!(next.uses, ids(&["t6"]));
    }

    #[test]
    fn the_open_call_table() {
        let t0 = Instant::now();
        let secs = |n: u64| t0 + Duration::from_secs(n);
        let ms = Duration::from_millis(1);
        #[rustfmt::skip]
        let table: Vec<(&str, Vec<Claim>, &str, Instant, bool)> = vec![
            ("a Pre opens a call", vec![pre("s1", "t1", "Edit", P, "A", "B")], P, t0, true),
            ("for 10 s", vec![pre("s1", "t1", "Write", P, "A", "B")], P, secs(10), true),
            ("and no more", vec![pre("s1", "t1", "Edit", P, "A", "B")], P, secs(10) + ms, false),
            ("a Codex patch opens one", vec![pre_by("codex", "c1", "call_1", "apply_patch", P, "A", "B")], P, t0, true),
            ("on its file only", vec![pre("s1", "t1", "Edit", P, "A", "B")], Q, t0, false),
            ("its Post closes it",
                vec![pre("s1", "t1", "Edit", P, "A", "B"), post("s1", "t1", "Edit", P, "B")], P, t0, false),
            ("a Post alone opens nothing", vec![post("s1", "t1", "Edit", P, "B")], P, t0, false),
            ("a Read writes nothing", vec![pre("s1", "t1", "Read", P, "A", "A")], P, t0, false),
            ("a closed id is no open call",
                vec![pre("s1", "t1", "Edit", P, "A", "B"), pre("s1", "t1", "Edit", P, "X", "B")], P, t0, false),
        ];
        for (name, claims, path, now, open) in table {
            let mut ledger = Claims::default();
            for claim in claims {
                let _ = ledger.record(claim, t0);
            }
            assert_eq!(ledger.open_call(Path::new(path), now), open, "{name}");
        }
    }

    #[test]
    fn the_hold_table() {
        let t0 = Instant::now();
        #[rustfmt::skip]
        let table: Vec<(&str, Vec<Claim>, &str, bool)> = vec![
            ("a Read holds its file", vec![pre("s1", "t1", "Read", P, "A", "A")], P, true),
            ("and only its file", vec![pre("s1", "t1", "Read", P, "A", "A")], Q, false),
            ("a Post alone holds nothing", vec![post("s1", "t1", "Edit", P, "B")], P, false),
            ("a Codex patch holds nothing",
                vec![pre_by("codex", "c1", "call_1", "apply_patch", P, "A", "B")], P, false),
            ("Stop releases it", vec![pre("s1", "t1", "Edit", P, "A", "B"), bare("Stop", "s1")], P, false),
            ("StopFailure releases it",
                vec![pre("s1", "t1", "Write", P, "A", "B"), bare("StopFailure", "s1")], P, false),
            ("UserPromptSubmit, after an interrupt, releases it",
                vec![pre("s1", "t1", "MultiEdit", P, "A", "B"), bare("UserPromptSubmit", "s1")], P, false),
            ("SessionEnd releases it", vec![pre("s1", "t1", "Edit", P, "A", "B"), bare("SessionEnd", "s1")], P, false),
            ("another session's Stop doesn't", vec![pre("s1", "t1", "Edit", P, "A", "B"), bare("Stop", "s2")], P, true),
            ("nor another vendor's with the same session id",
                vec![pre("s1", "t1", "Edit", P, "A", "B"),
                     Claim::parse(Fields { event: "Stop", vendor: "codex", session: "s1", ..Fields::default() }).unwrap()],
                P, true),
            ("a hold from each session needs each Stop",
                vec![pre("s1", "t1", "Edit", P, "A", "B"), pre("s2", "t2", "Edit", P, "A", "B"), bare("Stop", "s1")],
                P, true),
            ("a refused Post doesn't release it",
                vec![pre("s1", "t1", "Edit", P, "A", "B"), post("s1", "t1", "Edit", Q, "B")], P, true),
            ("InstructionsLoaded holds past Stop", vec![loaded("s1", P), bare("Stop", "s1")], P, true),
            ("until SessionEnd", vec![loaded("s1", P), bare("SessionEnd", "s1")], P, false),
        ];
        for (name, claims, path, held) in table {
            let mut ledger = Claims::default();
            for claim in claims {
                let _ = ledger.record(claim, t0);
            }
            assert_eq!(ledger.held(Path::new(path), t0), held, "{name}");
        }
    }

    #[test]
    fn holds_lapse_30_minutes_after_the_sessions_last_hook_event() {
        let t0 = Instant::now();
        let at = |minutes: u64| t0 + Duration::from_secs(minutes * 60);
        let ms = Duration::from_millis(1);
        let mut ledger = Claims::default();
        ledger
            .record(pre("s1", "t1", "Read", P, "A", "A"), t0)
            .unwrap();
        ledger.record(loaded("s1", Q), t0).unwrap();
        assert!(ledger.held(Path::new(P), at(30)));
        assert!(!ledger.held(Path::new(P), at(30) + ms));
        assert!(
            !ledger.held(Path::new(Q), at(30) + ms),
            "InstructionsLoaded lapses too"
        );

        // Any hook event from the session keeps every hold of its alive;
        // another session's events don't.
        ledger.record(bare("Stop", "s2"), at(20)).unwrap();
        assert!(!ledger.held(Path::new(P), at(30) + ms));
        ledger
            .record(post("s1", "t9", "Edit", Q, "B"), at(20))
            .unwrap();
        assert!(ledger.held(Path::new(P), at(50)));
        assert!(ledger.held(Path::new(Q), at(50)));
        assert!(!ledger.held(Path::new(P), at(50) + ms));

        // A lapsed hold is gone for good: a later event revives nothing.
        ledger
            .record(bare("UserPromptSubmit", "s3"), at(51))
            .unwrap();
        ledger
            .record(post("s1", "t10", "Edit", Q, "C"), at(52))
            .unwrap();
        assert!(!ledger.held(Path::new(P), at(52)));
        assert!(ledger.holds.is_empty() && ledger.heard.is_empty());
    }

    #[test]
    fn the_ledger_stays_bounded() {
        let t0 = Instant::now();
        let mut ledger = Claims::default();
        for i in 0..CAPACITY + 50 {
            let at = t0 + Duration::from_millis(i as u64);
            let (session, id) = (format!("s{i}"), format!("t{i}"));
            ledger
                .record(pre(&session, &id, "Edit", P, "A", "B"), at)
                .unwrap();
        }
        assert_eq!(ledger.uses.len(), CAPACITY);
        assert_eq!(ledger.holds.len(), CAPACITY);
        assert_eq!(ledger.heard.len(), CAPACITY);
        let key = |id: &str| (Vendor::Claude, Id::new(id).unwrap());
        assert!(!ledger.uses.contains_key(&key("t0")));
        assert!(
            ledger
                .uses
                .contains_key(&key(&format!("t{}", CAPACITY + 49)))
        );
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(256))]

        /// One session's edits, shuffled among other sessions', another
        /// file's, Reads, a second writer's calls, forged halves and
        /// replays, chain the same in any arrival order.
        #[test]
        fn claims_chain_in_any_order(
            edits in 1..6usize,
            order in Just((0..80usize).collect::<Vec<_>>()).prop_shuffle(),
            forged in "[a-f]{1,4}",
        ) {
            let state = |i: usize| format!("state {i}");
            let mut claims = Vec::new();
            for i in 0..edits {
                let id = format!("toolu_{i}");
                let name = ["Edit", "Write", "MultiEdit"][i % 3];
                let (other, read, inside) = (format!("other_{i}"), format!("read_{i}"), format!("inside_{i}"));
                claims.push(pre("s1", &id, name, P, &state(i), &state(i + 1)));
                claims.push(post("s1", &id, name, P, &state(i + 1)));
                claims.push(pre("s2", &other, "Edit", Q, &state(i), &state(i + 1)));
                claims.push(post("s2", &other, "Edit", Q, &state(i + 1)));
                claims.push(pre("s1", &read, "Read", P, &state(i), &state(i)));
                claims.push(post("s1", &read, "Read", P, &forged));
                // A call whose declared change isn't what landed.
                claims.push(pre_by("codex", "c1", &inside, "apply_patch", P, &state(i), &forged));
                claims.push(post_by("codex", "c1", &inside, "apply_patch", P, &state(i + 1)));
                claims.push(post("s3", &format!("forged_{i}"), "Edit", P, &forged));
                claims.push(pre("s1", &id, name, P, &state(i), &state(i + 1)));
            }
            let t0 = Instant::now();
            let mut ledger = Claims::default();
            for (step, &at) in order.iter().filter(|&&at| at < claims.len()).enumerate() {
                let _ = ledger.record(claims[at].clone(), t0 + Duration::from_millis(step as u64));
            }
            let seen = t0 + Duration::from_secs(1);
            for i in 0..edits {
                for j in i + 1..=edits {
                    let chain = ledger.chain(Path::new(P), &h(&state(i)), &h(&state(j)), seen);
                    let uses: Vec<String> = (i..j).map(|k| format!("toolu_{k}")).collect();
                    let uses: Vec<&str> = uses.iter().map(String::as_str).collect();
                    let expected = Chain { vendor: Vendor::Claude, session: Id::new("s1").unwrap(), uses: ids(&uses) };
                    prop_assert_eq!(chain, Some(expected));
                    prop_assert_eq!(ledger.chain(Path::new(P), &h(&state(j)), &h(&state(i)), seen), None);
                }
                prop_assert_eq!(ledger.chain(Path::new(P), &h(&state(i)), &h(&forged), seen), None);
            }
        }
    }
}
