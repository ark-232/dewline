use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use blake3::Hash;

/// Session and tool use ids are 1 to this many printable ASCII characters.
pub const MAX_ID: usize = 128;
/// A pair of claims explains only a change seen from this long before its
/// PreToolUse arrived to this long after its PostToolUse did.
pub const LINK_GRACE: Duration = Duration::from_secs(5);
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

/// The Claude Code tools a claim may name. Bash and every other tool are
/// refused: a hook around a command can't say which bytes it wrote.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tool {
    Read,
    Edit,
    MultiEdit,
    Write,
}

impl Tool {
    fn parse(name: &str) -> Option<Tool> {
        match name {
            "Read" => Some(Tool::Read),
            "Edit" => Some(Tool::Edit),
            "MultiEdit" => Some(Tool::MultiEdit),
            "Write" => Some(Tool::Write),
            _ => None,
        }
    }
}

/// One hook's report, from one `notify` line. It carries hashes, never
/// content, and only labels: nothing in this module writes a file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Claim {
    session: Id,
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
}

#[derive(Debug, PartialEq, Eq)]
pub enum Refused {
    /// The named field is missing, too long, unprintable, or names an event
    /// or tool the ledger doesn't take.
    Invalid(&'static str),
    /// The `tool_use_id` already has this half or both, or was spent or
    /// closed. A replay that differs from the first closes the id.
    Replayed,
    /// The two halves of a `tool_use_id` name different sessions, tools or
    /// files. The id is closed.
    Mismatched,
}

impl Claim {
    /// Reads the fields of one `notify` line, all untrusted. `path` is the
    /// file's realpath; `hash` is the BLAKE3 hex of its bytes (for Write's
    /// PostToolUse, of the content it wrote), absent when there was no file.
    pub fn parse(
        event: &str,
        session: &str,
        tool_use_id: Option<&str>,
        tool: Option<&str>,
        path: Option<&str>,
        hash: Option<&str>,
    ) -> Result<Claim, Refused> {
        let session = Id::new(session).ok_or(Refused::Invalid("session id"))?;
        let path = || match path {
            Some(path) if path.starts_with('/') && path.len() <= MAX_PATH => {
                Ok(PathBuf::from(path))
            }
            _ => Err(Refused::Invalid("path")),
        };
        let tool_use = || {
            Ok(ToolUse {
                id: tool_use_id
                    .and_then(Id::new)
                    .ok_or(Refused::Invalid("tool_use_id"))?,
                half: Half {
                    session: session.clone(),
                    tool: tool.and_then(Tool::parse).ok_or(Refused::Invalid("tool"))?,
                    path: path()?,
                    hash: hash
                        .map(|hex| Hash::from_hex(hex).map_err(|_| Refused::Invalid("hash")))
                        .transpose()?,
                },
            })
        };
        let event = match event {
            "PreToolUse" => Event::PreToolUse(tool_use()?),
            "PostToolUse" => Event::PostToolUse(tool_use()?),
            "InstructionsLoaded" => Event::InstructionsLoaded(path()?),
            "Stop" | "StopFailure" | "UserPromptSubmit" => Event::TurnEnd,
            "SessionEnd" => Event::SessionEnd,
            _ => return Err(Refused::Invalid("event")),
        };
        Ok(Claim { session, event })
    }
}

/// One session's paired writes that take a file from a change's ancestor to
/// its disk bytes: every pair on any run between the two.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chain {
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
    session: Id,
    until: Until,
}

/// What the hooks have claimed: tool uses by `tool_use_id`, paired in any
/// arrival order, and the autosave holds they put on files. The engine
/// consults it; it changes no bytes.
#[derive(Default)]
pub struct Claims {
    uses: HashMap<Id, Use>,
    holds: Vec<Hold>,
}

impl Claims {
    /// Records `claim`, which arrived at `now`. PreToolUse holds the file's
    /// autosave until the session's turn ends, InstructionsLoaded until the
    /// session ends.
    pub fn record(&mut self, claim: Claim, now: Instant) -> Result<(), Refused> {
        let session = claim.session;
        match claim.event {
            Event::PreToolUse(tool_use) => {
                self.hold(&tool_use.half.path, &session, Until::TurnEnd);
                self.half(tool_use, true, now)
            }
            Event::PostToolUse(tool_use) => self.half(tool_use, false, now),
            Event::InstructionsLoaded(path) => {
                self.hold(&path, &session, Until::SessionEnd);
                Ok(())
            }
            Event::TurnEnd => {
                self.holds
                    .retain(|hold| hold.session != session || hold.until != Until::TurnEnd);
                Ok(())
            }
            Event::SessionEnd => {
                self.holds.retain(|hold| hold.session != session);
                Ok(())
            }
        }
    }

    fn half(&mut self, tool_use: ToolUse, pre: bool, now: Instant) -> Result<(), Refused> {
        let ToolUse { id, half } = tool_use;
        // A Read only holds: it never links, so it needs no pair.
        if half.tool == Tool::Read {
            return Ok(());
        }
        let (entry, result) = match self.uses.remove(&id) {
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
        self.uses.insert(id, entry);
        if self.uses.len() > CAPACITY
            && let Some(oldest) = self
                .uses
                .iter()
                .min_by_key(|(_, entry)| entry.at())
                .map(|(id, _)| id.clone())
        {
            self.uses.remove(&oldest);
        }
        result
    }

    fn hold(&mut self, path: &Path, session: &Id, until: Until) {
        let held = self
            .holds
            .iter()
            .any(|hold| hold.path == path && hold.session == *session && hold.until == until);
        if !held {
            self.holds.push(Hold {
                path: path.to_path_buf(),
                session: session.clone(),
                until,
            });
            if self.holds.len() > CAPACITY {
                self.holds.remove(0);
            }
        }
    }

    /// Whether a hook's claim holds the autosave of the file at `path`.
    pub fn held(&self, path: &Path) -> bool {
        self.holds.iter().any(|hold| hold.path == path)
    }

    /// The chain of one session's Edit, MultiEdit and Write pairs on `path`
    /// that takes it from `from` to `to`, for a change seen at `seen`. Only
    /// pairs no change has spent count, and only within `LINK_GRACE` of the
    /// change. None when no session's pairs link the two, or more than one's
    /// do.
    pub fn chain(&self, path: &Path, from: &Hash, to: &Hash, seen: Instant) -> Option<Chain> {
        if from == to {
            return None;
        }
        let mut sessions: BTreeMap<&Id, Vec<(&Id, &Link)>> = BTreeMap::new();
        for (id, entry) in &self.uses {
            if let Use::Pair { link, .. } = entry
                && link.path == path
                && link.pre_at <= seen + LINK_GRACE
                && seen <= link.post_at + LINK_GRACE
            {
                sessions.entry(&link.session).or_default().push((id, link));
            }
        }
        let mut found = None;
        for (session, links) in sessions {
            if let Some(uses) = between(&links, Some(*from), Some(*to)) {
                if found.is_some() {
                    return None;
                }
                found = Some(Chain {
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
            if let Some(entry) = self.uses.get_mut(id) {
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

    fn tool(
        event: &str,
        session: &str,
        id: &str,
        tool: &str,
        path: &str,
        hash: Option<Hash>,
    ) -> Claim {
        let hex = hash.map(|hash| hash.to_hex().to_string());
        Claim::parse(
            event,
            session,
            Some(id),
            Some(tool),
            Some(path),
            hex.as_deref(),
        )
        .unwrap()
    }

    fn pre(session: &str, id: &str, name: &str, path: &str, state: &str) -> Claim {
        tool("PreToolUse", session, id, name, path, Some(h(state)))
    }

    fn post(session: &str, id: &str, name: &str, path: &str, state: &str) -> Claim {
        tool("PostToolUse", session, id, name, path, Some(h(state)))
    }

    fn bare(event: &str, session: &str) -> Claim {
        Claim::parse(event, session, None, None, None, None).unwrap()
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
            let session = Claim::parse("Stop", id, None, None, None, None);
            assert_eq!(session.is_ok(), valid, "session {id:?}");
            let tool_use = Claim::parse("PreToolUse", "s", Some(id), Some("Edit"), Some(P), None);
            assert_eq!(tool_use.is_ok(), valid, "tool_use_id {id:?}");
        }
    }

    #[test]
    fn parse_refuses_what_the_ledger_does_not_take() {
        let hex = h("a").to_hex().to_string();
        let long_path = format!("/{}", "p".repeat(MAX_PATH));
        let invalid = Refused::Invalid;
        #[rustfmt::skip]
        let table: &[Fields] = &[
            ("Notification", None, None, None, None, invalid("event")),
            ("pretooluse", Some("t"), Some("Edit"), Some(P), Some(&hex), invalid("event")),
            ("PreToolUse", Some("t"), Some("Bash"), Some(P), Some(&hex), invalid("tool")),
            ("PostToolUse", Some("t"), Some("NotebookEdit"), Some(P), Some(&hex), invalid("tool")),
            ("PreToolUse", Some("t"), None, Some(P), Some(&hex), invalid("tool")),
            ("PreToolUse", None, Some("Edit"), Some(P), Some(&hex), invalid("tool_use_id")),
            ("PreToolUse", Some("t"), Some("Edit"), None, Some(&hex), invalid("path")),
            ("PreToolUse", Some("t"), Some("Edit"), Some("CLAUDE.md"), Some(&hex), invalid("path")),
            ("PreToolUse", Some("t"), Some("Edit"), Some(&long_path), Some(&hex), invalid("path")),
            ("PreToolUse", Some("t"), Some("Edit"), Some(P), Some(&hex[1..]), invalid("hash")),
            ("PreToolUse", Some("t"), Some("Edit"), Some(P), Some("not hex"), invalid("hash")),
            ("InstructionsLoaded", None, None, None, None, invalid("path")),
        ];
        for (event, id, tool, path, hash, refused) in table {
            let claim = Claim::parse(event, "s", *id, *tool, *path, *hash);
            assert_eq!(
                claim.as_ref().err(),
                Some(refused),
                "{event} {tool:?} {path:?}"
            );
        }
        for event in ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd"] {
            assert!(
                Claim::parse(event, "s", None, None, None, None).is_ok(),
                "{event}"
            );
        }
    }

    /// An event, `tool_use_id`, tool, path and hash, and why they're refused.
    type Fields<'a> = (
        &'a str,
        Option<&'a str>,
        Option<&'a str>,
        Option<&'a str>,
        Option<&'a str>,
        Refused,
    );
    /// Claims with what recording each returns; a file, ancestor and disk
    /// state; the session and tool uses that should link them.
    type Case = (
        &'static str,
        Vec<(Claim, Result<(), Refused>)>,
        (&'static str, &'static str, &'static str),
        Option<(&'static str, &'static [&'static str])>,
    );

    #[test]
    fn the_chain_table() {
        let t0 = Instant::now();
        #[rustfmt::skip]
        let table: Vec<Case> = vec![
            ("one Edit links its ancestor to its disk bytes",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(()))],
                (P, "A", "B"), Some(("s1", &["t1"]))),
            ("the Post may arrive first",
                vec![(post("s1", "t1", "Write", P, "B"), Ok(())), (pre("s1", "t1", "Write", P, "A"), Ok(()))],
                (P, "A", "B"), Some(("s1", &["t1"]))),
            ("edits chain",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s1", "t2", "MultiEdit", P, "B"), Ok(())), (post("s1", "t2", "MultiEdit", P, "C"), Ok(()))],
                (P, "A", "C"), Some(("s1", &["t1", "t2"]))),
            ("a broken chain is Unknown",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s1", "t2", "Edit", P, "C"), Ok(())), (post("s1", "t2", "Edit", P, "D"), Ok(()))],
                (P, "A", "D"), None),
            ("a forged disk hash is Unknown",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(())), (post("s1", "t1", "Edit", P, "X"), Ok(()))],
                (P, "A", "B"), None),
            ("a forged ancestor is Unknown",
                vec![(pre("s1", "t1", "Edit", P, "X"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("a claim for another file is Unknown",
                vec![(pre("s1", "t1", "Edit", Q, "A"), Ok(())), (post("s1", "t1", "Edit", Q, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("halves on two files link neither",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(())), (post("s1", "t1", "Edit", Q, "B"), Err(Refused::Mismatched))],
                (P, "A", "B"), None),
            ("halves from two sessions link nothing",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(())), (post("s2", "t1", "Edit", P, "B"), Err(Refused::Mismatched))],
                (P, "A", "B"), None),
            ("halves naming two tools link nothing",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(())), (post("s1", "t1", "Write", P, "B"), Err(Refused::Mismatched))],
                (P, "A", "B"), None),
            ("a Read's id can't finish a write",
                vec![(pre("s1", "t1", "Read", P, "A"), Ok(())), (post("s1", "t1", "Write", P, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("a Read never links, even when the file changed under it",
                vec![(pre("s1", "t1", "Read", P, "A"), Ok(())), (post("s1", "t1", "Read", P, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("a session can't finish another's chain",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s2", "t2", "Edit", P, "B"), Ok(())), (post("s2", "t2", "Edit", P, "C"), Ok(()))],
                (P, "A", "C"), None),
            ("two sessions claiming one change name neither",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s2", "t2", "Edit", P, "A"), Ok(())), (post("s2", "t2", "Edit", P, "B"), Ok(()))],
                (P, "A", "B"), None),
            ("no change is no claim",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(())), (post("s1", "t1", "Edit", P, "B"), Ok(())),
                     (pre("s1", "t2", "Edit", P, "B"), Ok(())), (post("s1", "t2", "Edit", P, "A"), Ok(()))],
                (P, "A", "A"), None),
            ("a half alone links nothing",
                vec![(pre("s1", "t1", "Edit", P, "A"), Ok(()))],
                (P, "A", "B"), None),
        ];
        for (name, claims, (path, from, to), expected) in table {
            let mut ledger = Claims::default();
            for (claim, result) in claims {
                assert_eq!(ledger.record(claim, t0), result, "{name}");
            }
            let chain = ledger.chain(Path::new(path), &h(from), &h(to), t0);
            let expected = expected.map(|(session, uses)| Chain {
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
        ledger.record(pre("s1", "t1", "Edit", P, "A"), t0).unwrap();
        assert_eq!(
            ledger.record(pre("s1", "t1", "Edit", P, "A"), t0),
            Err(Refused::Replayed)
        );
        ledger.record(post("s1", "t1", "Edit", P, "B"), t0).unwrap();
        for replay in [
            pre("s1", "t1", "Edit", P, "A"),
            post("s1", "t1", "Edit", P, "B"),
        ] {
            assert_eq!(ledger.record(replay, t0), Err(Refused::Replayed));
        }
        assert_eq!(
            ledger.record(post("s1", "t1", "Edit", P, "X"), t0),
            Err(Refused::Replayed)
        );
        let chain = ledger.chain(Path::new(P), &h("A"), &h("B"), t0).unwrap();
        assert!(ledger.chain(Path::new(P), &h("A"), &h("X"), t0).is_none());

        // Once a committed change spends the chain, the same change again,
        // the file back at A and then B from another writer, is Unknown.
        ledger.spend(&chain, t0);
        assert!(ledger.chain(Path::new(P), &h("A"), &h("B"), t0).is_none());
        for replay in [
            pre("s1", "t1", "Edit", P, "A"),
            post("s1", "t1", "Edit", P, "B"),
        ] {
            assert_eq!(ledger.record(replay, t0), Err(Refused::Replayed));
        }
        assert!(ledger.chain(Path::new(P), &h("A"), &h("B"), t0).is_none());

        // A half replayed with other contents before its pair closes the id:
        // neither version is trusted.
        ledger.record(pre("s1", "t2", "Edit", P, "B"), t0).unwrap();
        assert_eq!(
            ledger.record(pre("s1", "t2", "Edit", P, "Y"), t0),
            Err(Refused::Replayed)
        );
        assert_eq!(
            ledger.record(post("s1", "t2", "Edit", P, "C"), t0),
            Err(Refused::Replayed)
        );
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
            .record(pre("s1", "t1", "Edit", P, "A"), pre_at)
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
        let edits = [
            ("t1", "A", "B"),
            ("t2", "B", "A"),
            ("t3", "A", "B"),
            ("t4", "B", "X"),
            ("t5", "X", "B"),
        ];
        for (id, before, after) in edits {
            ledger.record(pre("s1", id, "Edit", P, before), t0).unwrap();
            ledger.record(post("s1", id, "Edit", P, after), t0).unwrap();
        }
        let chain = ledger.chain(Path::new(P), &h("A"), &h("B"), t0).unwrap();
        assert_eq!(chain.uses, ids(&["t1", "t2", "t3", "t4", "t5"]));
        ledger.spend(&chain, t0);
        for (from, to) in [("A", "B"), ("B", "A"), ("B", "X"), ("X", "B")] {
            assert!(
                ledger.chain(Path::new(P), &h(from), &h(to), t0).is_none(),
                "{from} {to}"
            );
        }
        // A later edit past B is not part of the change, and stays.
        ledger.record(pre("s1", "t6", "Edit", P, "B"), t0).unwrap();
        ledger.record(post("s1", "t6", "Edit", P, "C"), t0).unwrap();
        let chain = ledger.chain(Path::new(P), &h("A"), &h("C"), t0);
        assert!(chain.is_none(), "t1 to t5 are spent");
        let next = ledger.chain(Path::new(P), &h("B"), &h("C"), t0).unwrap();
        assert_eq!(next.uses, ids(&["t6"]));
    }

    #[test]
    fn the_hold_table() {
        let t0 = Instant::now();
        #[rustfmt::skip]
        let table: Vec<(&str, Vec<Claim>, &str, bool)> = vec![
            ("a Read holds its file", vec![pre("s1", "t1", "Read", P, "A")], P, true),
            ("and only its file", vec![pre("s1", "t1", "Read", P, "A")], Q, false),
            ("a Post alone holds nothing", vec![post("s1", "t1", "Edit", P, "B")], P, false),
            ("Stop releases it", vec![pre("s1", "t1", "Edit", P, "A"), bare("Stop", "s1")], P, false),
            ("StopFailure releases it", vec![pre("s1", "t1", "Write", P, "A"), bare("StopFailure", "s1")], P, false),
            ("UserPromptSubmit, after an interrupt, releases it",
                vec![pre("s1", "t1", "MultiEdit", P, "A"), bare("UserPromptSubmit", "s1")], P, false),
            ("SessionEnd releases it", vec![pre("s1", "t1", "Edit", P, "A"), bare("SessionEnd", "s1")], P, false),
            ("another session's Stop doesn't", vec![pre("s1", "t1", "Edit", P, "A"), bare("Stop", "s2")], P, true),
            ("a hold from each session needs each Stop",
                vec![pre("s1", "t1", "Edit", P, "A"), pre("s2", "t2", "Edit", P, "A"), bare("Stop", "s1")], P, true),
            ("a refused Post doesn't release it",
                vec![pre("s1", "t1", "Edit", P, "A"), post("s1", "t1", "Edit", Q, "B")], P, true),
            ("InstructionsLoaded holds past Stop",
                vec![Claim::parse("InstructionsLoaded", "s1", None, None, Some(P), None).unwrap(), bare("Stop", "s1")],
                P, true),
            ("until SessionEnd",
                vec![Claim::parse("InstructionsLoaded", "s1", None, None, Some(P), None).unwrap(), bare("SessionEnd", "s1")],
                P, false),
        ];
        for (name, claims, path, held) in table {
            let mut ledger = Claims::default();
            for claim in claims {
                let _ = ledger.record(claim, t0);
            }
            assert_eq!(ledger.held(Path::new(path)), held, "{name}");
        }
    }

    #[test]
    fn the_ledger_stays_bounded() {
        let t0 = Instant::now();
        let mut ledger = Claims::default();
        for i in 0..CAPACITY + 50 {
            let at = t0 + Duration::from_millis(i as u64);
            ledger
                .record(pre(&format!("s{i}"), &format!("t{i}"), "Edit", P, "A"), at)
                .unwrap();
        }
        assert_eq!(ledger.uses.len(), CAPACITY);
        assert_eq!(ledger.holds.len(), CAPACITY);
        assert!(!ledger.uses.contains_key(&Id::new("t0").unwrap()));
        assert!(
            ledger
                .uses
                .contains_key(&Id::new(&format!("t{}", CAPACITY + 49)).unwrap())
        );
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(256))]

        /// One session's edits, shuffled among other sessions', another
        /// file's, Reads, forged halves and replays, chain the same in any
        /// arrival order.
        #[test]
        fn claims_chain_in_any_order(
            edits in 1..6usize,
            order in Just((0..64usize).collect::<Vec<_>>()).prop_shuffle(),
            forged in "[a-f]{1,4}",
        ) {
            let state = |i: usize| format!("state {i}");
            let mut claims = Vec::new();
            for i in 0..edits {
                let id = format!("toolu_{i}");
                let name = ["Edit", "Write", "MultiEdit"][i % 3];
                claims.push(pre("s1", &id, name, P, &state(i)));
                claims.push(post("s1", &id, name, P, &state(i + 1)));
                claims.push(pre("s2", &format!("other_{i}"), "Edit", Q, &state(i)));
                claims.push(post("s2", &format!("other_{i}"), "Edit", Q, &state(i + 1)));
                claims.push(pre("s1", &format!("read_{i}"), "Read", P, &state(i)));
                claims.push(post("s1", &format!("read_{i}"), "Read", P, &forged));
                claims.push(post("s3", &format!("forged_{i}"), "Edit", P, &forged));
                claims.push(pre("s1", &id, name, P, &state(i)));
            }
            let t0 = Instant::now();
            let mut ledger = Claims::default();
            for (step, &at) in order.iter().filter(|&&at| at < claims.len()).enumerate() {
                let _ = ledger.record(claims[at].clone(), t0 + Duration::from_millis(step as u64));
            }
            let now = t0 + Duration::from_secs(1);
            for i in 0..edits {
                for j in i + 1..=edits {
                    let chain = ledger.chain(Path::new(P), &h(&state(i)), &h(&state(j)), now);
                    let uses: Vec<String> = (i..j).map(|k| format!("toolu_{k}")).collect();
                    let uses: Vec<&str> = uses.iter().map(String::as_str).collect();
                    prop_assert_eq!(chain, Some(Chain { session: Id::new("s1").unwrap(), uses: ids(&uses) }));
                    prop_assert_eq!(ledger.chain(Path::new(P), &h(&state(j)), &h(&state(i)), now), None);
                }
                prop_assert_eq!(ledger.chain(Path::new(P), &h(&state(i)), &h(&forged), now), None);
            }
        }
    }
}
