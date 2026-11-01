//! The change engine as Swift sees it. Ids are the engine's numbers;
//! offsets are UTF-16, as NSString counts them.

use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

use dewline_core::claims::{self, Fields};
use dewline_core::engine::{self as core, ChangeId, DocId, LandingId};
use dewline_core::{file, merge, store, text};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum EngineError {
    #[error("the document is closed")]
    Closed,
    #[error("a hook call or git's index lock holds the file")]
    Waiting,
    #[error("the file is not UTF-8 text")]
    NotText,
    #[error("the landing is not the current one")]
    Stale,
    #[error("{message}")]
    Invalid { message: String },
    #[error("{message}")]
    Io { message: String },
}

impl From<core::EngineError> for EngineError {
    fn from(error: core::EngineError) -> Self {
        match error {
            core::EngineError::Closed => EngineError::Closed,
            core::EngineError::Waiting => EngineError::Waiting,
            core::EngineError::NotText => EngineError::NotText,
            core::EngineError::Misplaced => EngineError::Invalid {
                message: "the edits are out of order or past the end of the buffer".into(),
            },
            core::EngineError::Io(error) => error.into(),
        }
    }
}

impl From<std::io::Error> for EngineError {
    fn from(error: std::io::Error) -> Self {
        EngineError::Io {
            message: error.to_string(),
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SaveRefused {
    #[error("the document is closed")]
    Closed,
    #[error("the document is read-only")]
    ReadOnly,
    #[error("the buffer is older than a landing")]
    Stale,
    #[error("a conflict is open")]
    Conflict,
    #[error("the file changed")]
    Changed,
    #[error("a hook holds the file")]
    Held,
    #[error("text is being composed")]
    Composing,
    #[error("Writing Tools is working")]
    WritingTools,
    #[error("the file is gone")]
    Deleted,
    #[error("the file can't be read")]
    Unreadable,
    #[error("{message}")]
    Io { message: String },
}

impl From<core::SaveRefused> for SaveRefused {
    fn from(refused: core::SaveRefused) -> Self {
        match refused {
            core::SaveRefused::Closed => SaveRefused::Closed,
            core::SaveRefused::ReadOnly => SaveRefused::ReadOnly,
            core::SaveRefused::Stale => SaveRefused::Stale,
            core::SaveRefused::Conflict => SaveRefused::Conflict,
            core::SaveRefused::Changed => SaveRefused::Changed,
            core::SaveRefused::Held => SaveRefused::Held,
            core::SaveRefused::Composing => SaveRefused::Composing,
            core::SaveRefused::WritingTools => SaveRefused::WritingTools,
            core::SaveRefused::Deleted => SaveRefused::Deleted,
            core::SaveRefused::Unreadable => SaveRefused::Unreadable,
            core::SaveRefused::Io(error) => SaveRefused::Io {
                message: error.to_string(),
            },
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ClaimRefused {
    #[error("the {field} field is invalid")]
    Invalid { field: String },
    #[error("the tool use was already claimed")]
    Replayed,
    #[error("the two halves of the tool use disagree")]
    Mismatched,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Vendor {
    Claude,
    Codex,
    Cursor,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Origin {
    User,
    Agent {
        vendor: Vendor,
        session: String,
    },
    Git {
        action: Option<String>,
    },
    /// "Unknown app".
    External,
    Collaborator {
        peer: String,
        name: String,
    },
}

impl From<core::Origin> for Origin {
    fn from(origin: core::Origin) -> Self {
        match origin {
            core::Origin::User => Origin::User,
            core::Origin::Agent { vendor, session } => Origin::Agent {
                vendor: match vendor {
                    claims::Vendor::Claude => Vendor::Claude,
                    claims::Vendor::Codex => Vendor::Codex,
                    claims::Vendor::Cursor => Vendor::Cursor,
                },
                session,
            },
            core::Origin::Git { action } => Origin::Git { action },
            core::Origin::External => Origin::External,
            core::Origin::Collaborator { peer, name } => Origin::Collaborator { peer, name },
        }
    }
}

/// Replaces the UTF-16 range `start..end` with `text`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Edit {
    pub start: u32,
    pub end: u32,
    pub text: String,
}

impl From<merge::Edit> for Edit {
    fn from(edit: merge::Edit) -> Self {
        Edit {
            start: edit.start,
            end: edit.end,
            text: edit.text,
        }
    }
}

#[derive(Debug, uniffi::Enum)]
pub enum Contents {
    Text {
        text: String,
        bom: bool,
    },
    /// Not UTF-8: shown read-only, never written.
    Bytes {
        bytes: Vec<u8>,
    },
}

#[derive(Debug, uniffi::Record)]
pub struct Opened {
    pub doc: u64,
    pub contents: Contents,
    /// The realpath the engine keys the file by.
    pub path: String,
    pub agent_file: bool,
    /// The repository's gitdir, to watch and pass to `git_changed`.
    pub gitdir: Option<String>,
}

/// One landed edit, a pending change.
#[derive(Debug, uniffi::Record)]
pub struct Landed {
    pub change: u64,
    pub edit: Edit,
}

/// Lines both sides changed: yours stay at `start..end`, `theirs` is the
/// other version, shown until decided.
#[derive(Debug, uniffi::Record)]
pub struct ConflictCard {
    pub change: u64,
    pub start: u32,
    pub end: u32,
    pub theirs: String,
}

/// A file's new version merged into the buffer at `version`. Commit it on
/// the main thread with the buffer still at `version`, and apply it in the
/// same step only when the commit succeeds: `covering` when present, else
/// `edits`.
#[derive(Debug, uniffi::Record)]
pub struct Landing {
    pub id: u64,
    pub version: u64,
    pub origin: Origin,
    pub marked: bool,
    pub time: SystemTime,
    pub edits: Vec<Landed>,
    pub covering: Option<Edit>,
    pub conflicts: Vec<ConflictCard>,
}

impl From<core::Landing> for Landing {
    fn from(landing: core::Landing) -> Self {
        Landing {
            id: landing.id.0,
            version: landing.version,
            origin: landing.origin.into(),
            marked: landing.marked,
            time: landing.time,
            edits: landing
                .edits
                .into_iter()
                .map(|(change, edit)| Landed {
                    change: change.0,
                    edit: edit.into(),
                })
                .collect(),
            covering: landing.covering.map(Edit::from),
            conflicts: landing
                .conflicts
                .into_iter()
                .map(|(change, conflict)| ConflictCard {
                    change: change.0,
                    start: conflict.start,
                    end: conflict.end,
                    theirs: conflict.theirs,
                })
                .collect(),
        }
    }
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum SaveKind {
    Auto {
        composing: bool,
        writing_tools: bool,
    },
    Explicit,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum Decision {
    Keep,
    Other,
    Both,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Snapshot {
    pub id: u64,
    pub hash: Vec<u8>,
    pub time: SystemTime,
    pub origin: Origin,
    pub label: String,
    pub pinned: bool,
}

impl From<store::Snapshot> for Snapshot {
    fn from(snapshot: store::Snapshot) -> Self {
        Snapshot {
            id: snapshot.id,
            hash: snapshot.hash.as_bytes().to_vec(),
            time: snapshot.time,
            origin: core::Origin::from_label(&snapshot.origin).into(),
            label: snapshot.origin,
            pinned: snapshot.pinned,
        }
    }
}

impl TryFrom<Snapshot> for store::Snapshot {
    type Error = EngineError;

    fn try_from(snapshot: Snapshot) -> Result<Self, EngineError> {
        Ok(store::Snapshot {
            id: snapshot.id,
            hash: file::Hash::from_slice(&snapshot.hash).map_err(|_| EngineError::Invalid {
                message: "a snapshot hash is 32 bytes".into(),
            })?,
            time: snapshot.time,
            origin: snapshot.label,
            pinned: snapshot.pinned,
        })
    }
}

/// One `notify` line's fields, as the control socket received them.
#[derive(Debug, uniffi::Record)]
pub struct ClaimFields {
    pub event: String,
    pub vendor: String,
    pub session: String,
    pub tool_use_id: Option<String>,
    pub tool: Option<String>,
    pub path: Option<String>,
    pub hash: Option<String>,
    pub declared: Option<String>,
}

#[derive(Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Update {
    /// A late claim named a change already seen; a quiet one is now marked.
    Relabeled {
        doc: u64,
        change: u64,
        origin: Origin,
    },
    /// A hold ended: run the refused autosave again.
    Released { doc: u64 },
    /// A hook call ended: land again.
    Retry { doc: u64 },
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum Bias {
    Before,
    After,
}

#[derive(uniffi::Object)]
pub struct Engine(core::Engine);

#[uniffi::export]
impl Engine {
    /// An engine whose snapshots live under `store`.
    #[uniffi::constructor]
    pub fn new(store: String) -> Result<Arc<Engine>, EngineError> {
        let engine = core::Engine::new(Path::new(&store), core::system_clock())?;
        Ok(Arc::new(Engine(engine)))
    }

    pub fn open(&self, path: String) -> Result<Opened, EngineError> {
        let opened = self.0.open(Path::new(&path))?;
        Ok(Opened {
            doc: opened.doc.0,
            contents: match opened.contents {
                text::Opened::Utf8 { bom, text } => Contents::Text { text, bom },
                text::Opened::Other(bytes) => Contents::Bytes { bytes },
            },
            path: opened.path.to_string_lossy().into_owned(),
            agent_file: opened.agent_file,
            gitdir: opened
                .gitdir
                .map(|gitdir| gitdir.to_string_lossy().into_owned()),
        })
    }

    /// Whether the file differs from the base. Off the main thread.
    pub fn observe(&self, doc: u64) -> Result<bool, EngineError> {
        Ok(self.0.observe(DocId(doc))?)
    }

    /// Off the main thread: it snapshots and merges.
    pub fn land(
        &self,
        doc: u64,
        buffer: String,
        version: u64,
    ) -> Result<Option<Landing>, EngineError> {
        Ok(self
            .0
            .land(DocId(doc), &buffer, version)?
            .map(Landing::from))
    }

    /// A collaborator's edits to `buffer`, snapshotted first, to apply once no
    /// IME composition is open.
    pub fn collaborate(
        &self,
        doc: u64,
        buffer: String,
        edits: Vec<Edit>,
    ) -> Result<Vec<Edit>, EngineError> {
        let edits = edits
            .into_iter()
            .map(|edit| merge::Edit {
                start: edit.start,
                end: edit.end,
                text: edit.text,
            })
            .collect();
        Ok(self
            .0
            .collaborate(DocId(doc), &buffer, edits)?
            .into_iter()
            .map(Edit::from)
            .collect())
    }

    /// On the main thread, in the step that applies the landing.
    pub fn commit(&self, doc: u64, landing: u64) -> Result<(), EngineError> {
        self.0
            .commit(DocId(doc), LandingId(landing))
            .map_err(|core::Stale| EngineError::Stale)
    }

    /// The hash of the bytes written. Off the main thread.
    pub fn save(
        &self,
        doc: u64,
        buffer: String,
        version: u64,
        kind: SaveKind,
    ) -> Result<Vec<u8>, SaveRefused> {
        let kind = match kind {
            SaveKind::Auto {
                composing,
                writing_tools,
            } => core::SaveKind::Auto {
                composing,
                writing_tools,
            },
            SaveKind::Explicit => core::SaveKind::Explicit,
        };
        let hash = self.0.save(DocId(doc), &buffer, version, kind)?;
        Ok(hash.as_bytes().to_vec())
    }

    /// The text that replaces the change's live range, whose text is
    /// `current`; none when the buffer stays as it is.
    pub fn decide(
        &self,
        doc: u64,
        change: u64,
        decision: Decision,
        current: String,
    ) -> Option<String> {
        let decision = match decision {
            Decision::Keep => core::Decision::Keep,
            Decision::Other => core::Decision::Other,
            Decision::Both => core::Decision::Both,
        };
        self.0
            .decide(DocId(doc), ChangeId(change), decision, &current)
    }

    /// The snapshot's text, to replace the buffer as one undoable edit.
    pub fn restore(
        &self,
        doc: u64,
        snapshot: Snapshot,
        buffer: String,
    ) -> Result<String, EngineError> {
        let snapshot = store::Snapshot::try_from(snapshot)?;
        Ok(self.0.restore(DocId(doc), &snapshot, &buffer)?)
    }

    pub fn claim(&self, fields: ClaimFields) -> Result<Vec<Update>, ClaimRefused> {
        let claim = claims::Claim::parse(Fields {
            event: &fields.event,
            vendor: &fields.vendor,
            session: &fields.session,
            tool_use_id: fields.tool_use_id.as_deref(),
            tool: fields.tool.as_deref(),
            path: fields.path.as_deref(),
            hash: fields.hash.as_deref(),
            declared: fields.declared.as_deref(),
        })
        .and_then(|claim| self.0.claim(claim))
        .map_err(|refused| match refused {
            claims::Refused::Invalid(field) => ClaimRefused::Invalid {
                field: field.into(),
            },
            claims::Refused::Replayed => ClaimRefused::Replayed,
            claims::Refused::Mismatched => ClaimRefused::Mismatched,
        })?;
        Ok(claim
            .into_iter()
            .map(|update| match update {
                core::Update::Relabeled {
                    doc,
                    change,
                    origin,
                } => Update::Relabeled {
                    doc: doc.0,
                    change: change.0,
                    origin: origin.into(),
                },
                core::Update::Released(doc) => Update::Released { doc: doc.0 },
                core::Update::Retry(doc) => Update::Retry { doc: doc.0 },
            })
            .collect())
    }

    /// The documents in the gitdir's repository, to land again.
    pub fn git_changed(&self, gitdir: String) -> Vec<u64> {
        self.0
            .git_changed(Path::new(&gitdir))
            .into_iter()
            .map(|doc| doc.0)
            .collect()
    }

    /// The document's file is now at `to`; returns its repository's
    /// gitdir. Snapshot ids change.
    pub fn moved(&self, doc: u64, to: String) -> Result<Option<String>, EngineError> {
        let gitdir = self.0.moved(DocId(doc), Path::new(&to))?;
        Ok(gitdir.map(|gitdir| gitdir.to_string_lossy().into_owned()))
    }

    pub fn close(&self, doc: u64) {
        self.0.close(DocId(doc));
    }

    /// Newest first.
    pub fn snapshots(&self, doc: u64) -> Result<Vec<Snapshot>, EngineError> {
        let snapshots = self.0.snapshots(DocId(doc))?;
        Ok(snapshots.into_iter().map(Snapshot::from).collect())
    }

    pub fn pin(&self, doc: u64, snapshot: Snapshot, pinned: bool) -> Result<(), EngineError> {
        let snapshot = store::Snapshot::try_from(snapshot)?;
        Ok(self.0.pin(DocId(doc), &snapshot, pinned)?)
    }

    /// Once, after the documents of the last session are open again.
    pub fn prune(&self) -> Result<(), EngineError> {
        Ok(self.0.prune()?)
    }
}

/// Edits from Swift, checked to be in order without overlap before the
/// engine maps through them.
fn checked(edits: Vec<Edit>) -> Result<Vec<merge::Edit>, EngineError> {
    let mut end = 0;
    edits
        .into_iter()
        .map(|edit| {
            if edit.start > edit.end || edit.start < end {
                return Err(EngineError::Invalid {
                    message: format!("edit {}..{} is out of order", edit.start, edit.end),
                });
            }
            end = edit.end;
            Ok(merge::Edit {
                start: edit.start,
                end: edit.end,
                text: edit.text,
            })
        })
        .collect()
}

/// Maps a UTF-16 offset through `edits`, ordered and not overlapping: the
/// caret with Before, a selection's start with After and its end with
/// Before.
#[uniffi::export]
pub fn map_offset(edits: Vec<Edit>, offset: u32, bias: Bias) -> Result<u32, EngineError> {
    let bias = match bias {
        Bias::Before => merge::Bias::Before,
        Bias::After => merge::Bias::After,
    };
    Ok(merge::map_offset(&checked(edits)?, offset, bias))
}

/// Moves the undo history past edits the engine made: `undo` and `redo` are
/// entries oldest first, each the edits that undo one action. Entries the
/// engine's edits touched are dropped with everything older; redo empties.
#[uniffi::export]
pub fn map_undo(undo: Vec<Vec<Edit>>, edits: Vec<Edit>) -> Result<Vec<Vec<Edit>>, EngineError> {
    let mut undo = undo
        .into_iter()
        .map(checked)
        .collect::<Result<Vec<_>, _>>()?;
    merge::map_undo(&mut undo, &mut Vec::new(), &checked(edits)?);
    Ok(undo
        .into_iter()
        .map(|entry| entry.into_iter().map(Edit::from).collect())
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edit(start: u32, end: u32, text: &str) -> Edit {
        Edit {
            start,
            end,
            text: text.into(),
        }
    }

    #[test]
    fn an_outside_write_lands_through_the_object() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let path = root.join("notes.md");
        std::fs::write(&path, "\u{feff}one 🙂\n").unwrap();
        let engine = Engine::new(root.join("snapshots").to_string_lossy().into()).unwrap();
        let opened = engine.open(path.to_string_lossy().into()).unwrap();
        let Contents::Text { text, bom: true } = opened.contents else {
            panic!("{:?}", opened.contents);
        };
        assert_eq!(text, "one 🙂\n");
        std::fs::write(&path, "\u{feff}one 🙂 two\n").unwrap();
        assert!(engine.observe(opened.doc).unwrap());
        let landing = engine.land(opened.doc, text.clone(), 1).unwrap().unwrap();
        assert_eq!(landing.edits[0].edit, edit(6, 6, " two"), "UTF-16 offsets");
        assert_eq!(landing.origin, Origin::External);
        engine.commit(opened.doc, landing.id).unwrap();
        assert!(matches!(
            engine.commit(opened.doc, landing.id),
            Err(EngineError::Stale)
        ));
        assert!(matches!(
            engine.save(opened.doc, text, 1, SaveKind::Explicit),
            Err(SaveRefused::Stale)
        ));
        let hash = engine
            .save(opened.doc, "one 🙂 two!\n".into(), 2, SaveKind::Explicit)
            .unwrap();
        assert_eq!(
            std::fs::read(&path).unwrap(),
            "\u{feff}one 🙂 two!\n".as_bytes()
        );
        assert_eq!(
            hash,
            file::hash("\u{feff}one 🙂 two!\n".as_bytes()).as_bytes()
        );

        let snapshots = engine.snapshots(opened.doc).unwrap();
        assert_eq!(snapshots.len(), 2);
        let restored = engine
            .restore(opened.doc, snapshots[1].clone(), "x".into())
            .unwrap();
        assert_eq!(restored, "one 🙂\n");
        engine.pin(opened.doc, snapshots[0].clone(), true).unwrap();
        let bad = Snapshot {
            hash: vec![1, 2],
            ..snapshots[0].clone()
        };
        assert!(matches!(
            engine.restore(opened.doc, bad, String::new()),
            Err(EngineError::Invalid { .. })
        ));
        let refused = engine.claim(ClaimFields {
            event: "PreToolUse".into(),
            vendor: "claude".into(),
            session: "s1".into(),
            tool_use_id: Some("t1".into()),
            tool: Some("Bash".into()),
            path: Some(path.to_string_lossy().into()),
            hash: None,
            declared: None,
        });
        assert!(matches!(refused, Err(ClaimRefused::Invalid { field }) if field == "tool"));
        engine.close(opened.doc);
        assert!(matches!(
            engine.observe(opened.doc),
            Err(EngineError::Closed)
        ));
    }

    #[test]
    fn edits_from_swift_are_checked_before_mapping() {
        let edits = vec![edit(1, 1, "XY"), edit(2, 4, "Z")];
        assert_eq!(map_offset(edits.clone(), 3, Bias::After).unwrap(), 5);
        for bad in [
            vec![edit(4, 2, "")],
            vec![edit(2, 4, ""), edit(3, 5, "")],
            vec![edit(5, 6, ""), edit(1, 2, "")],
        ] {
            assert!(matches!(
                map_offset(bad.clone(), 0, Bias::Before),
                Err(EngineError::Invalid { .. })
            ));
            assert!(matches!(
                map_undo(vec![bad], vec![]),
                Err(EngineError::Invalid { .. })
            ));
        }
        let undo = map_undo(vec![vec![edit(5, 11, "")]], vec![edit(0, 0, "Oh, ")]).unwrap();
        assert_eq!(undo, [vec![edit(9, 15, "")]]);
    }
}
