//! Live collaboration on one shared file (D13, record 0009). Loro mirrors the
//! file's text; the `.md` on each Mac stays the source of truth, and the app
//! hands every remote change to the change engine as a collaborator. iroh
//! carries a direct control stream to the host (join, approval, keys,
//! removal) and a gossip topic for ops and cursors, each message sealed with
//! the document key and signed by its sender's node key.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use iroh::endpoint::{Connection, presets};
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointAddr, PublicKey, RelayMode, RelayUrl, SecretKey};
use iroh_gossip::api::Event;
use iroh_gossip::{Gossip, TopicId};
use loro::cursor::{Cursor, PosType, Side};
use loro::{ExportMode, Frontiers, LoroDoc};
use n0_future::StreamExt;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};

mod link;
mod wire;

use link::Invite;
use wire::{Reader, Writer};

/// The relay every Mac uses when no direct path opens: n0's hosted relay
/// while Dewline is in development. The release relay (n0's or our own
/// `iroh-relay`) is this one constant; record 0009.
pub const RELAY: &str = "https://use1-1.relay.n0.iroh.link./";

const ALPN: &[u8] = b"dewline/collab/0";
/// The Loro text container that mirrors the file.
const TEXT: &str = "md";
/// The largest gossip message: one op or cursor. A larger op does not
/// broadcast (record 0009).
const GOSSIP_MAX: usize = 1 << 20;
const NAME_MAX: usize = 64;

/// Told on any thread when the status, the people or the text changed; read
/// the session's state from the main thread.
pub trait Listener: Send + Sync {
    fn changed(&self);
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    Connecting,
    /// Joined: the host has the name and has not decided.
    Waiting,
    Live,
    Denied,
    Removed,
    Failed(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteCursor {
    pub peer: String,
    pub name: String,
    /// UTF-16 into the text as of the last `pull`.
    pub offset: u32,
}

/// One replace that brings the text the app shows up to the shared text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteEdit {
    pub start: u32,
    pub end: u32,
    pub text: String,
    /// The collaborator whose op arrived last.
    pub peer: String,
    pub name: String,
}

pub struct Session {
    shared: Arc<Shared>,
    router: Router,
    runtime: Mutex<Option<Runtime>>,
}

struct Shared {
    secret: SecretKey,
    name: String,
    listener: Box<dyn Listener>,
    state: Mutex<State>,
    /// Sealed messages for the gossip topic.
    outbox: mpsc::UnboundedSender<Vec<u8>>,
}

struct State {
    status: Status,
    topic: [u8; 32],
    file_name: String,
    /// The current document key last, the one before it first: ops sealed
    /// just before a rotation still open, from members only.
    keys: Vec<(u32, [u8; 32])>,
    members: BTreeMap<PublicKey, String>,
    doc: LoroDoc,
    /// The version and text the app shows: its edits are made there.
    shown: Frontiers,
    shown_text: String,
    author: Option<PublicKey>,
    cursors: HashMap<PublicKey, Vec<u8>>,
    host: Option<Host>,
    /// A guest's frames to the host.
    to_host: Option<mpsc::UnboundedSender<Vec<u8>>>,
}

struct Host {
    endpoint: Endpoint,
    /// One-time join capabilities not yet presented.
    capabilities: HashSet<[u8; 32]>,
    pending: Vec<Pending>,
    /// Each approved guest's control frames.
    guests: HashMap<PublicKey, mpsc::UnboundedSender<Vec<u8>>>,
}

struct Pending {
    id: PublicKey,
    name: String,
    decide: oneshot::Sender<Option<Admission>>,
}

struct Admission {
    welcome: Vec<u8>,
    frames: mpsc::UnboundedReceiver<Vec<u8>>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn random() -> [u8; 32] {
    let mut bytes = [0; 32];
    getrandom::fill(&mut bytes).expect("the system's random source");
    bytes
}

/// A new node key for this Mac, kept in the Keychain.
pub fn new_node_key() -> [u8; 32] {
    random()
}

fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// A name as the host shows it: no control characters, at most 64 of them.
fn clean_name(name: &str) -> String {
    let name: String = name
        .chars()
        .filter(|c| !c.is_control())
        .take(NAME_MAX)
        .collect();
    match name.trim() {
        "" => "Guest".into(),
        name => name.into(),
    }
}

/// The host's file name as a bare name: no folders, no leading dots, `.md`.
fn jail_file_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let base: String = base
        .chars()
        .filter(|c| !c.is_control() && *c != ':')
        .take(100)
        .collect();
    let base = base.trim().trim_start_matches('.');
    match base {
        "" => "Shared.md".into(),
        base if base.ends_with(".md") || base.ends_with(".markdown") => base.into(),
        base => format!("{base}.md"),
    }
}

/// The one replace from `old` to `new`, in UTF-16.
fn differing(old: &str, new: &str) -> (u32, u32, String) {
    let prefix: usize = old
        .chars()
        .zip(new.chars())
        .take_while(|(a, b)| a == b)
        .map(|(a, _)| a.len_utf8())
        .sum();
    let (old_rest, new_rest) = (&old[prefix..], &new[prefix..]);
    let suffix: usize = old_rest
        .chars()
        .rev()
        .zip(new_rest.chars().rev())
        .take_while(|(a, b)| a == b)
        .map(|(a, _)| a.len_utf8())
        .sum();
    let start = utf16_len(&old[..prefix]) as u32;
    let end = start + utf16_len(&old_rest[..old_rest.len() - suffix]) as u32;
    (start, end, new_rest[..new_rest.len() - suffix].to_owned())
}

fn runtime() -> Result<Runtime, String> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("dewline-sync")
        .enable_all()
        .build()
        .map_err(|error| error.to_string())
}

async fn bind(secret: SecretKey) -> Result<Endpoint, String> {
    let relay: RelayUrl = RELAY.parse().map_err(|_| "bad relay URL".to_owned())?;
    Endpoint::builder(presets::Minimal)
        .secret_key(secret)
        .relay_mode(RelayMode::custom([relay]))
        .bind()
        .await
        .map_err(|error| error.to_string())
}

impl Session {
    /// Shares `text`, the file's current text and nothing older, as
    /// `file_name`. `node_key` is this Mac's node key from the Keychain.
    pub fn host(
        node_key: [u8; 32],
        name: &str,
        file_name: &str,
        text: &str,
        listener: Box<dyn Listener>,
    ) -> Result<Session, String> {
        let runtime = runtime()?;
        let secret = SecretKey::from_bytes(&node_key);
        let doc = LoroDoc::new();
        doc.get_text(TEXT)
            .insert(0, text)
            .map_err(|error| error.to_string())?;
        doc.commit();
        let endpoint = runtime.block_on(bind(secret.clone()))?;
        let (outbox, outbox_rx) = mpsc::unbounded_channel();
        let topic = random();
        let shared = Arc::new(Shared {
            secret: secret.clone(),
            name: clean_name(name),
            listener,
            state: Mutex::new(State {
                status: Status::Live,
                topic,
                file_name: jail_file_name(file_name),
                keys: vec![(0, random())],
                members: BTreeMap::from([(secret.public(), clean_name(name))]),
                shown: doc.oplog_frontiers(),
                shown_text: text.into(),
                doc,
                author: None,
                cursors: HashMap::new(),
                host: Some(Host {
                    endpoint: endpoint.clone(),
                    capabilities: HashSet::new(),
                    pending: Vec::new(),
                    guests: HashMap::new(),
                }),
                to_host: None,
            }),
            outbox,
        });
        let _context = runtime.enter();
        let gossip = Gossip::builder()
            .max_message_size(GOSSIP_MAX)
            .spawn(endpoint.clone());
        let router = Router::builder(endpoint)
            .accept(ALPN, Joins(shared.clone()))
            .accept(iroh_gossip::ALPN, gossip.clone())
            .spawn();
        runtime.spawn(shared.clone().gossip(gossip, Vec::new(), outbox_rx));
        drop(_context);
        Ok(Session {
            shared,
            router,
            runtime: Mutex::new(Some(runtime)),
        })
    }

    /// Joins through a `dewline://join` link as `name`. The status moves to
    /// Waiting, then Live with `text` and `file_name` once the host approves.
    pub fn join(
        node_key: [u8; 32],
        name: &str,
        link: &str,
        listener: Box<dyn Listener>,
    ) -> Result<Session, String> {
        let invite = Invite::parse(link).ok_or("not a Dewline join link")?;
        let runtime = runtime()?;
        let secret = SecretKey::from_bytes(&node_key);
        let endpoint = runtime.block_on(bind(secret.clone()))?;
        let (outbox, outbox_rx) = mpsc::unbounded_channel();
        let doc = LoroDoc::new();
        let shared = Arc::new(Shared {
            secret,
            name: clean_name(name),
            listener,
            state: Mutex::new(State {
                status: Status::Connecting,
                topic: [0; 32],
                file_name: String::new(),
                keys: Vec::new(),
                members: BTreeMap::new(),
                shown: doc.oplog_frontiers(),
                shown_text: String::new(),
                doc,
                author: None,
                cursors: HashMap::new(),
                host: None,
                to_host: None,
            }),
            outbox,
        });
        let _context = runtime.enter();
        let gossip = Gossip::builder()
            .max_message_size(GOSSIP_MAX)
            .spawn(endpoint.clone());
        let router = Router::builder(endpoint.clone())
            .accept(iroh_gossip::ALPN, gossip.clone())
            .spawn();
        runtime.spawn(shared.clone().connect(endpoint, gossip, invite, outbox_rx));
        drop(_context);
        Ok(Session {
            shared,
            router,
            runtime: Mutex::new(Some(runtime)),
        })
    }

    /// A new one-time join link. Host only.
    pub fn invite(&self) -> Option<String> {
        let mut state = lock(&self.shared.state);
        let host = state.host.as_mut()?;
        let capability = random();
        host.capabilities.insert(capability);
        let relay: RelayUrl = RELAY.parse().ok()?;
        let addr: EndpointAddr = host.endpoint.addr().with_relay_url(relay);
        Some(
            Invite {
                host: addr,
                capability,
            }
            .format(),
        )
    }

    pub fn status(&self) -> Status {
        lock(&self.shared.state).status.clone()
    }

    pub fn is_host(&self) -> bool {
        lock(&self.shared.state).host.is_some()
    }

    /// The shared file's name, jailed to a bare `.md` name.
    pub fn file_name(&self) -> String {
        lock(&self.shared.state).file_name.clone()
    }

    /// The text the app shows: for a guest, what to open once Live.
    pub fn text(&self) -> String {
        lock(&self.shared.state).shown_text.clone()
    }

    /// The topic, which names the share in the Keychain.
    pub fn share_id(&self) -> String {
        data_encoding::HEXLOWER.encode(&lock(&self.shared.state).topic)
    }

    /// The current document key, for the Keychain.
    pub fn document_key(&self) -> Option<[u8; 32]> {
        lock(&self.shared.state).keys.last().map(|(_, key)| *key)
    }

    /// Joins awaiting the host's decision.
    pub fn pending(&self) -> Vec<Peer> {
        let state = lock(&self.shared.state);
        let Some(host) = &state.host else {
            return Vec::new();
        };
        host.pending
            .iter()
            .map(|pending| Peer {
                id: pending.id.to_string(),
                name: pending.name.clone(),
            })
            .collect()
    }

    /// Everyone in the share but this Mac.
    pub fn peers(&self) -> Vec<Peer> {
        let me = self.shared.secret.public();
        lock(&self.shared.state)
            .members
            .iter()
            .filter(|(id, _)| **id != me)
            .map(|(id, name)| Peer {
                id: id.to_string(),
                name: name.clone(),
            })
            .collect()
    }

    /// Admits a pending join: the guest gets the share's snapshot and a new
    /// document key, which everyone else gets too.
    pub fn approve(&self, peer: &str) {
        let mut state = lock(&self.shared.state);
        let Some(pending) = take_pending(&mut state, peer) else {
            return;
        };
        state.members.insert(pending.id, pending.name);
        let (epoch, key) = rotate(&mut state);
        let (sender, frames) = mpsc::unbounded_channel();
        let members: Vec<_> = state.members.clone().into_iter().collect();
        let Ok(snapshot) = state.doc.export(ExportMode::Snapshot) else {
            return;
        };
        let welcome = wire::write_members(
            Writer::new(wire::WELCOME)
                .bytes(&state.topic)
                .u32(epoch)
                .bytes(&key)
                .field(state.file_name.as_bytes()),
            &members,
        )
        .bytes(&snapshot)
        .0;
        if let Some(host) = state.host.as_mut() {
            host.guests.insert(pending.id, sender);
        }
        drop(state);
        let _ = pending.decide.send(Some(Admission { welcome, frames }));
        self.shared.listener.changed();
    }

    pub fn deny(&self, peer: &str) {
        let pending = take_pending(&mut lock(&self.shared.state), peer);
        if let Some(pending) = pending {
            let _ = pending.decide.send(None);
            self.shared.listener.changed();
        }
    }

    /// Revokes a guest: its node leaves the members, so its ops are dropped,
    /// and the document key rotates to everyone who stays.
    pub fn remove(&self, peer: &str) {
        let mut state = lock(&self.shared.state);
        let Some(id) = state
            .members
            .keys()
            .find(|id| id.to_string() == peer)
            .copied()
        else {
            return;
        };
        if Some(id) == Some(self.shared.secret.public()) {
            return;
        }
        let Some(host) = state.host.as_mut() else {
            return;
        };
        if let Some(frames) = host.guests.remove(&id) {
            let _ = frames.send(vec![wire::REMOVED]);
        }
        state.members.remove(&id);
        state.cursors.remove(&id);
        rotate(&mut state);
        drop(state);
        self.shared.listener.changed();
    }

    /// The app's edit to the text it shows, in UTF-16.
    pub fn edit(&self, start: u32, end: u32, text: &str) -> Result<(), String> {
        let mut state = lock(&self.shared.state);
        if state.status != Status::Live {
            return Err("the share is not live".into());
        }
        let (start, end) = (start as usize, end as usize);
        if start > end || end > utf16_len(&state.shown_text) {
            return Err("the edit is past the end of the text".into());
        }
        let error = |error: loro::LoroError| error.to_string();
        let before = state.doc.oplog_vv();
        if state.doc.oplog_frontiers() == state.shown {
            state
                .doc
                .get_text(TEXT)
                .splice_utf16(start, end - start, text)
                .map_err(error)?;
            state.doc.commit();
            state.shown = state.doc.oplog_frontiers();
        } else {
            // Remote ops the app has not pulled: the edit is made at the
            // version the app shows and merges as concurrent with them.
            let fork = state.doc.fork_at(&state.shown).map_err(error)?;
            fork.set_peer_id(state.doc.peer_id()).map_err(error)?;
            fork.get_text(TEXT)
                .splice_utf16(start, end - start, text)
                .map_err(error)?;
            fork.commit();
            let ours = fork
                .export(ExportMode::updates(&before))
                .map_err(|error| error.to_string())?;
            state.doc.import(&ours).map_err(error)?;
            state.shown = fork.oplog_frontiers();
        }
        let shown: Vec<u16> = state.shown_text.encode_utf16().collect();
        state.shown_text = String::from_utf16_lossy(&shown[..start])
            + text
            + &String::from_utf16_lossy(&shown[end..]);
        let update = state
            .doc
            .export(ExportMode::updates(&before))
            .map_err(|error| error.to_string())?;
        let sealed = seal(&self.shared.secret, &state, wire::OP, &update);
        drop(state);
        if let Some(sealed) = sealed {
            let _ = self.shared.outbox.send(sealed);
        }
        Ok(())
    }

    /// What collaborators changed since the last pull, as one replace of the
    /// text the app shows. The app applies it through the engine's
    /// `collaborate` and the IME rule.
    pub fn pull(&self) -> Option<RemoteEdit> {
        let mut state = lock(&self.shared.state);
        let now = state.doc.get_text(TEXT).to_string();
        state.shown = state.doc.oplog_frontiers();
        if now == state.shown_text {
            return None;
        }
        let (start, end, text) = differing(&state.shown_text, &now);
        state.shown_text = now;
        let author = state.author;
        let name = author
            .and_then(|id| state.members.get(&id).cloned())
            .unwrap_or_default();
        Some(RemoteEdit {
            start,
            end,
            text,
            peer: author.map(|id| id.to_string()).unwrap_or_default(),
            name,
        })
    }

    /// This Mac's caret, in UTF-16 into the text the app shows.
    pub fn set_cursor(&self, offset: u32) {
        let state = lock(&self.shared.state);
        if state.status != Status::Live || state.doc.oplog_frontiers() != state.shown {
            return;
        }
        let text = state.doc.get_text(TEXT);
        let Some(cursor) = text
            .convert_pos(offset as usize, PosType::Utf16, PosType::Unicode)
            .and_then(|position| text.get_cursor(position, Side::Middle))
        else {
            return;
        };
        let sealed = seal(&self.shared.secret, &state, wire::CURSOR, &cursor.encode());
        drop(state);
        if let Some(sealed) = sealed {
            let _ = self.shared.outbox.send(sealed);
        }
    }

    /// Collaborators' carets in the shared text.
    pub fn cursors(&self) -> Vec<RemoteCursor> {
        let state = lock(&self.shared.state);
        let text = state.doc.get_text(TEXT);
        state
            .cursors
            .iter()
            .filter_map(|(id, bytes)| {
                let cursor = Cursor::decode(bytes).ok()?;
                let position = state.doc.get_cursor_pos(&cursor).ok()?.current.pos;
                Some(RemoteCursor {
                    peer: id.to_string(),
                    name: state.members.get(id)?.clone(),
                    offset: text.convert_pos(position, PosType::Unicode, PosType::Utf16)? as u32,
                })
            })
            .collect()
    }

    /// Leaves the share and stops the network.
    pub fn close(&self) {
        let runtime = lock(&self.runtime).take();
        if let Some(runtime) = runtime {
            let router = self.router.clone();
            runtime.block_on(async move {
                let _ = tokio::time::timeout(Duration::from_secs(1), router.shutdown()).await;
            });
            runtime.shutdown_background();
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if let Some(runtime) = lock(&self.runtime).take() {
            runtime.shutdown_background();
        }
    }
}

fn take_pending(state: &mut State, peer: &str) -> Option<Pending> {
    let host = state.host.as_mut()?;
    let index = host
        .pending
        .iter()
        .position(|pending| pending.id.to_string() == peer)?;
    Some(host.pending.remove(index))
}

/// A new document key, sent with the members to every connected guest.
fn rotate(state: &mut State) -> (u32, [u8; 32]) {
    let epoch = state.keys.last().map_or(0, |(epoch, _)| epoch + 1);
    let key = random();
    state.keys.push((epoch, key));
    if state.keys.len() > 2 {
        state.keys.remove(0);
    }
    let members: Vec<_> = state.members.clone().into_iter().collect();
    let frame = wire::write_members(Writer::new(wire::REKEY).u32(epoch).bytes(&key), &members).0;
    if let Some(host) = &state.host {
        for frames in host.guests.values() {
            let _ = frames.send(frame.clone());
        }
    }
    (epoch, key)
}

fn seal(secret: &SecretKey, state: &State, kind: u8, body: &[u8]) -> Option<Vec<u8>> {
    let (epoch, key) = state.keys.last()?;
    let plain = [&[kind][..], body].concat();
    Some(wire::seal(&state.topic, secret, *epoch, key, &plain))
}

impl Shared {
    fn changed(&self) {
        self.listener.changed();
    }

    fn set_status(&self, status: Status) {
        lock(&self.state).status = status;
        self.changed();
    }

    /// A gossip message: dropped unless a member signed it under a key this
    /// Mac holds.
    fn receive(&self, content: &[u8]) {
        let mut state = lock(&self.state);
        let Some(envelope) = wire::open_envelope(&state.topic, content) else {
            return;
        };
        if envelope.sender == self.secret.public() || !state.members.contains_key(&envelope.sender)
        {
            return;
        }
        let Some((_, key)) = state
            .keys
            .iter()
            .find(|(epoch, _)| *epoch == envelope.epoch)
        else {
            return;
        };
        let Some(plain) = envelope.decrypt(key) else {
            return;
        };
        match plain.split_first() {
            Some((&wire::OP, update)) => {
                if state.doc.import(update).is_err() {
                    return;
                }
                state.author = Some(envelope.sender);
            }
            Some((&wire::CURSOR, cursor)) => {
                state.cursors.insert(envelope.sender, cursor.to_vec());
            }
            _ => return,
        }
        drop(state);
        self.changed();
    }

    /// Runs the gossip topic: broadcasts the outbox, receives, and has a
    /// guest ask the host for anything missed whenever a neighbor comes up.
    async fn gossip(
        self: Arc<Self>,
        gossip: Gossip,
        bootstrap: Vec<PublicKey>,
        mut outbox: mpsc::UnboundedReceiver<Vec<u8>>,
    ) {
        let topic = lock(&self.state).topic;
        let Ok(subscription) = gossip
            .subscribe(TopicId::from_bytes(topic), bootstrap)
            .await
        else {
            self.set_status(Status::Failed("The share's network didn't start.".into()));
            return;
        };
        let (sender, mut receiver) = subscription.split();
        tokio::spawn(async move {
            while let Some(message) = outbox.recv().await {
                let _ = sender.broadcast(message.into()).await;
            }
        });
        while let Some(event) = receiver.next().await {
            match event {
                Ok(Event::Received(message)) => self.receive(&message.content),
                Ok(Event::NeighborUp(_)) => {
                    let state = lock(&self.state);
                    if let Some(to_host) = &state.to_host {
                        let want = Writer::new(wire::WANT)
                            .bytes(&state.doc.oplog_vv().encode())
                            .0;
                        let _ = to_host.send(want);
                    }
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
    }

    /// The guest's side: present the capability and name, wait for the
    /// host, then follow its control frames.
    async fn connect(
        self: Arc<Self>,
        endpoint: Endpoint,
        gossip: Gossip,
        invite: Invite,
        outbox: mpsc::UnboundedReceiver<Vec<u8>>,
    ) {
        let host = invite.host.id;
        let result = async {
            let connection = endpoint
                .connect(invite.host, ALPN)
                .await
                .map_err(|error| error.to_string())?;
            let (mut send, mut receive) = connection
                .open_bi()
                .await
                .map_err(|error| error.to_string())?;
            let hello = Writer::new(wire::HELLO)
                .bytes(&invite.capability)
                .field(self.name.as_bytes())
                .0;
            wire::send(&mut send, &hello).await?;
            self.set_status(Status::Waiting);
            let frame = wire::receive(&mut receive, usize::MAX).await?;
            if frame.first() != Some(&wire::WELCOME) {
                return Ok::<_, String>(Some(Status::Denied));
            }
            self.welcome(&frame[1..])?;
            let (to_host, mut frames) = mpsc::unbounded_channel::<Vec<u8>>();
            lock(&self.state).to_host = Some(to_host);
            tokio::spawn(async move {
                while let Some(frame) = frames.recv().await {
                    if wire::send(&mut send, &frame).await.is_err() {
                        break;
                    }
                }
            });
            tokio::spawn(self.clone().gossip(gossip, vec![host], outbox));
            self.changed();
            loop {
                let Ok(frame) = wire::receive(&mut receive, usize::MAX).await else {
                    return Ok(None);
                };
                let mut reader = Reader(&frame[1..]);
                match frame[0] {
                    wire::REKEY => {
                        let (Some(epoch), Some(key), Some(members)) = (
                            reader.u32(),
                            reader.array(),
                            wire::read_members(&mut reader),
                        ) else {
                            continue;
                        };
                        let mut state = lock(&self.state);
                        state.keys.push((epoch, key));
                        if state.keys.len() > 2 {
                            state.keys.remove(0);
                        }
                        state.members = members.into_iter().collect();
                        let members = state.members.clone();
                        state.cursors.retain(|id, _| members.contains_key(id));
                    }
                    wire::UPDATES => {
                        let mut state = lock(&self.state);
                        if state.doc.import(reader.rest()).is_ok() {
                            state.author = Some(host);
                        }
                    }
                    wire::REMOVED => return Ok(Some(Status::Removed)),
                    _ => continue,
                }
                self.changed();
            }
        }
        .await;
        let status = match result {
            Ok(Some(status)) => status,
            Ok(None) => Status::Failed("The host ended the share.".into()),
            Err(error) => Status::Failed(error),
        };
        self.set_status(status);
    }

    fn welcome(&self, body: &[u8]) -> Result<(), String> {
        let bad = || "the host's welcome is malformed".to_owned();
        let mut reader = Reader(body);
        let topic = reader.array().ok_or_else(bad)?;
        let epoch = reader.u32().ok_or_else(bad)?;
        let key = reader.array().ok_or_else(bad)?;
        let file_name = reader.string().ok_or_else(bad)?;
        let members = wire::read_members(&mut reader).ok_or_else(bad)?;
        let mut state = lock(&self.state);
        state
            .doc
            .import(reader.rest())
            .map_err(|error| error.to_string())?;
        state.topic = topic;
        state.keys = vec![(epoch, key)];
        state.file_name = jail_file_name(&file_name);
        state.members = members.into_iter().collect();
        state.shown = state.doc.oplog_frontiers();
        state.shown_text = state.doc.get_text(TEXT).to_string();
        state.status = Status::Live;
        Ok(())
    }

    /// The host's side of one guest: the capability check, the decision, then
    /// its frames both ways until it leaves or is removed.
    async fn serve(self: Arc<Self>, connection: Connection) {
        let id = connection.remote_id();
        let Ok((mut send, mut receive)) = connection.accept_bi().await else {
            return;
        };
        let Ok(hello) = wire::receive(&mut receive, 4096).await else {
            return;
        };
        let mut reader = Reader(&hello);
        let (Some([wire::HELLO]), Some(capability), Some(name)) =
            (reader.array::<1>(), reader.array::<32>(), reader.string())
        else {
            return;
        };
        let (decide, decision) = oneshot::channel();
        let admitted = {
            let mut state = lock(&self.state);
            let known = state.members.contains_key(&id);
            let Some(host) = state.host.as_mut() else {
                return;
            };
            // Spent on first presentation, whatever the host decides.
            let admitted = host.capabilities.remove(&capability) && !known;
            if admitted {
                host.pending.retain(|pending| pending.id != id);
                host.pending.push(Pending {
                    id,
                    name: clean_name(&name),
                    decide,
                });
            }
            admitted
        };
        let admission = if admitted {
            self.changed();
            decision.await.ok().flatten()
        } else {
            None
        };
        let Some(Admission {
            welcome,
            mut frames,
        }) = admission
        else {
            let _ = wire::send(&mut send, &[wire::DENIED]).await;
            let _ = send.finish();
            let _ = tokio::time::timeout(Duration::from_secs(2), connection.closed()).await;
            return;
        };
        if wire::send(&mut send, &welcome).await.is_err() {
            self.left(id);
            return;
        }
        let writer = connection.clone();
        tokio::spawn(async move {
            while let Some(frame) = frames.recv().await {
                let removed = frame.first() == Some(&wire::REMOVED);
                if wire::send(&mut send, &frame).await.is_err() || removed {
                    break;
                }
            }
            let _ = send.finish();
            let _ = tokio::time::timeout(Duration::from_secs(2), writer.closed()).await;
            writer.close(0u32.into(), b"removed");
        });
        while let Ok(frame) = wire::receive(&mut receive, 1 << 20).await {
            if frame.first() != Some(&wire::WANT) {
                continue;
            }
            let state = lock(&self.state);
            let Ok(theirs) = loro::VersionVector::decode(&frame[1..]) else {
                continue;
            };
            let Ok(update) = state.doc.export(ExportMode::updates(&theirs)) else {
                continue;
            };
            if let Some(frames) = state.host.as_ref().and_then(|host| host.guests.get(&id)) {
                let _ = frames.send(Writer::new(wire::UPDATES).bytes(&update).0);
            }
        }
        self.left(id);
    }

    /// A guest's connection closed. One the host did not remove leaves the
    /// members too, and the key rotates.
    fn left(&self, id: PublicKey) {
        let mut state = lock(&self.state);
        let Some(host) = state.host.as_mut() else {
            return;
        };
        if host.guests.remove(&id).is_none() {
            return;
        }
        state.members.remove(&id);
        state.cursors.remove(&id);
        rotate(&mut state);
        drop(state);
        self.changed();
    }
}

/// The host's handler for join connections.
struct Joins(Arc<Shared>);

impl fmt::Debug for Joins {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("Joins")
    }
}

impl ProtocolHandler for Joins {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        self.0.clone().serve(connection).await;
        Ok(())
    }
}
