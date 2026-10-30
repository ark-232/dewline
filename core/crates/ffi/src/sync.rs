//! Live collaboration as Swift sees it: one `Collab` per shared document.
//! Offsets are UTF-16, as NSString counts them.

use std::sync::Arc;

use dewline_sync::{Listener, Session, Status};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CollabError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<String> for CollabError {
    fn from(message: String) -> Self {
        CollabError::Failed { message }
    }
}

/// Told on a background thread when anything changed; read on the main one.
#[uniffi::export(with_foreign)]
pub trait CollabListener: Send + Sync {
    fn changed(&self);
}

struct Forward(Arc<dyn CollabListener>);

impl Listener for Forward {
    fn changed(&self) {
        self.0.changed();
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CollabStatus {
    Connecting,
    Waiting,
    Live,
    Denied,
    Removed,
    Failed { message: String },
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CollabPeer {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct RemoteCursor {
    pub peer: String,
    pub name: String,
    pub offset: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct RemoteEdit {
    pub start: u32,
    pub end: u32,
    pub text: String,
    pub peer: String,
    pub name: String,
}

fn key(bytes: Vec<u8>) -> Result<[u8; 32], CollabError> {
    bytes.try_into().map_err(|_| CollabError::Failed {
        message: "a node key is 32 bytes".into(),
    })
}

fn peers(peers: Vec<dewline_sync::Peer>) -> Vec<CollabPeer> {
    peers
        .into_iter()
        .map(|peer| CollabPeer {
            id: peer.id,
            name: peer.name,
        })
        .collect()
}

#[derive(uniffi::Object)]
pub struct Collab(Session);

#[uniffi::export]
impl Collab {
    /// Shares `text` as `file_name`, with `node_key` from the Keychain.
    #[uniffi::constructor]
    pub fn host(
        node_key: Vec<u8>,
        name: String,
        file_name: String,
        text: String,
        listener: Arc<dyn CollabListener>,
    ) -> Result<Arc<Collab>, CollabError> {
        let session = Session::host(
            key(node_key)?,
            &name,
            &file_name,
            &text,
            Box::new(Forward(listener)),
        )?;
        Ok(Arc::new(Collab(session)))
    }

    /// Joins through a `dewline://join` link.
    #[uniffi::constructor]
    pub fn join(
        node_key: Vec<u8>,
        name: String,
        link: String,
        listener: Arc<dyn CollabListener>,
    ) -> Result<Arc<Collab>, CollabError> {
        let session = Session::join(key(node_key)?, &name, &link, Box::new(Forward(listener)))?;
        Ok(Arc::new(Collab(session)))
    }

    /// A new one-time join link; None for a guest.
    pub fn invite(&self) -> Option<String> {
        self.0.invite()
    }

    pub fn status(&self) -> CollabStatus {
        match self.0.status() {
            Status::Connecting => CollabStatus::Connecting,
            Status::Waiting => CollabStatus::Waiting,
            Status::Live => CollabStatus::Live,
            Status::Denied => CollabStatus::Denied,
            Status::Removed => CollabStatus::Removed,
            Status::Failed(message) => CollabStatus::Failed { message },
        }
    }

    pub fn is_host(&self) -> bool {
        self.0.is_host()
    }

    pub fn file_name(&self) -> String {
        self.0.file_name()
    }

    pub fn text(&self) -> String {
        self.0.text()
    }

    pub fn share_id(&self) -> String {
        self.0.share_id()
    }

    pub fn document_key(&self) -> Option<Vec<u8>> {
        self.0.document_key().map(Vec::from)
    }

    pub fn pending(&self) -> Vec<CollabPeer> {
        peers(self.0.pending())
    }

    pub fn peers(&self) -> Vec<CollabPeer> {
        peers(self.0.peers())
    }

    pub fn approve(&self, peer: String) {
        self.0.approve(&peer);
    }

    pub fn deny(&self, peer: String) {
        self.0.deny(&peer);
    }

    pub fn remove(&self, peer: String) {
        self.0.remove(&peer);
    }

    /// The app's own edit to the text it shows.
    pub fn edit(&self, start: u32, end: u32, text: String) -> Result<(), CollabError> {
        Ok(self.0.edit(start, end, &text)?)
    }

    /// Collaborators' changes since the last pull, as one replace.
    pub fn pull(&self) -> Option<RemoteEdit> {
        self.0.pull().map(|edit| RemoteEdit {
            start: edit.start,
            end: edit.end,
            text: edit.text,
            peer: edit.peer,
            name: edit.name,
        })
    }

    pub fn set_cursor(&self, offset: u32) {
        self.0.set_cursor(offset);
    }

    pub fn cursors(&self) -> Vec<RemoteCursor> {
        self.0
            .cursors()
            .into_iter()
            .map(|cursor| RemoteCursor {
                peer: cursor.peer,
                name: cursor.name,
                offset: cursor.offset,
            })
            .collect()
    }

    pub fn close(&self) {
        self.0.close();
    }
}

/// A new node key for the Keychain.
#[uniffi::export]
pub fn new_node_key() -> Vec<u8> {
    dewline_sync::new_node_key().into()
}
