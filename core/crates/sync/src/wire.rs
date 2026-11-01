//! Byte layouts: control frames on the host's direct stream, and the sealed
//! envelope every gossip message travels in.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use iroh::endpoint::{RecvStream, SendStream};
use iroh::{PublicKey, SecretKey, Signature};

/// Control frames over this size are refused; a snapshot is the largest.
const MAX_FRAME: usize = 80 << 20;

// Control frame tags.
pub const HELLO: u8 = 1;
pub const DENIED: u8 = 2;
pub const WELCOME: u8 = 3;
pub const REKEY: u8 = 4;
pub const REMOVED: u8 = 5;
pub const WANT: u8 = 6;
pub const UPDATES: u8 = 7;

// Gossip message kinds, inside the envelope.
pub const OP: u8 = 1;
pub const CURSOR: u8 = 2;

pub async fn send(stream: &mut SendStream, frame: &[u8]) -> Result<(), String> {
    let length = u32::try_from(frame.len()).map_err(|_| "frame too large".to_owned())?;
    stream
        .write_all(&length.to_be_bytes())
        .await
        .map_err(|error| error.to_string())?;
    stream
        .write_all(frame)
        .await
        .map_err(|error| error.to_string())
}

pub async fn receive(stream: &mut RecvStream, limit: usize) -> Result<Vec<u8>, String> {
    let mut length = [0; 4];
    stream
        .read_exact(&mut length)
        .await
        .map_err(|error| error.to_string())?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > limit.min(MAX_FRAME) {
        return Err("bad frame length".into());
    }
    let mut frame = vec![0; length];
    stream
        .read_exact(&mut frame)
        .await
        .map_err(|error| error.to_string())?;
    Ok(frame)
}

#[derive(Default)]
pub struct Writer(pub Vec<u8>);

impl Writer {
    pub fn new(tag: u8) -> Writer {
        Writer(vec![tag])
    }

    pub fn bytes(mut self, bytes: &[u8]) -> Writer {
        self.0.extend_from_slice(bytes);
        self
    }

    pub fn u32(self, value: u32) -> Writer {
        self.bytes(&value.to_be_bytes())
    }

    /// A string or byte run with its length in front.
    pub fn field(self, bytes: &[u8]) -> Writer {
        self.u32(bytes.len() as u32).bytes(bytes)
    }
}

pub struct Reader<'a>(pub &'a [u8]);

impl<'a> Reader<'a> {
    pub fn bytes(&mut self, count: usize) -> Option<&'a [u8]> {
        if self.0.len() < count {
            return None;
        }
        let (head, rest) = self.0.split_at(count);
        self.0 = rest;
        Some(head)
    }

    pub fn array<const N: usize>(&mut self) -> Option<[u8; N]> {
        self.bytes(N)?.try_into().ok()
    }

    pub fn u32(&mut self) -> Option<u32> {
        self.array().map(u32::from_be_bytes)
    }

    pub fn field(&mut self) -> Option<&'a [u8]> {
        let count = self.u32()? as usize;
        self.bytes(count)
    }

    pub fn string(&mut self) -> Option<String> {
        String::from_utf8(self.field()?.to_vec()).ok()
    }

    pub fn rest(&mut self) -> &'a [u8] {
        std::mem::take(&mut self.0)
    }
}

/// The members list: node id and approved name, for WELCOME and REKEY.
pub fn write_members(mut writer: Writer, members: &[(PublicKey, String)]) -> Writer {
    writer = writer.u32(members.len() as u32);
    for (id, name) in members {
        writer = writer.bytes(id.as_bytes()).field(name.as_bytes());
    }
    writer
}

pub fn read_members(reader: &mut Reader) -> Option<Vec<(PublicKey, String)>> {
    let count = reader.u32()?;
    (0..count)
        .map(|_| {
            let id = PublicKey::from_bytes(&reader.array()?).ok()?;
            Some((id, reader.string()?))
        })
        .collect()
}

/// sender, epoch, nonce, ciphertext, then a signature over the topic and all
/// of that by the sender's node key. The sender id is the AEAD's associated
/// data, so a ciphertext can't be replayed under another member's name.
pub fn seal(
    topic: &[u8; 32],
    secret: &SecretKey,
    epoch: u32,
    key: &[u8; 32],
    plain: &[u8],
) -> Vec<u8> {
    let sender = secret.public();
    let mut nonce = [0; 24];
    getrandom::fill(&mut nonce).expect("the system's random source");
    let cipher = XChaCha20Poly1305::new(key.into());
    let sealed = cipher
        .encrypt(
            &XNonce::from(nonce),
            Payload {
                msg: plain,
                aad: sender.as_bytes(),
            },
        )
        .expect("encrypting in memory");
    let mut envelope = Writer::default()
        .bytes(sender.as_bytes())
        .u32(epoch)
        .bytes(&nonce)
        .bytes(&sealed)
        .0;
    let signature = secret.sign(&[topic.as_slice(), &envelope].concat());
    envelope.extend_from_slice(&signature.to_bytes());
    envelope
}

/// The sender, the epoch and the signed bytes of an envelope, before the
/// receiver looks up the sender and the key.
pub struct Envelope<'a> {
    pub sender: PublicKey,
    pub epoch: u32,
    nonce: [u8; 24],
    sealed: &'a [u8],
}

pub fn open_envelope<'a>(topic: &[u8; 32], envelope: &'a [u8]) -> Option<Envelope<'a>> {
    let signed_length = envelope.len().checked_sub(Signature::LENGTH)?;
    let (signed, signature) = envelope.split_at(signed_length);
    let mut reader = Reader(signed);
    let sender = PublicKey::from_bytes(&reader.array()?).ok()?;
    let epoch = reader.u32()?;
    let nonce = reader.array()?;
    let sealed = reader.rest();
    let signature = Signature::from_bytes(signature.try_into().ok()?);
    sender
        .verify(&[topic.as_slice(), signed].concat(), &signature)
        .ok()?;
    Some(Envelope {
        sender,
        epoch,
        nonce,
        sealed,
    })
}

impl Envelope<'_> {
    pub fn decrypt(&self, key: &[u8; 32]) -> Option<Vec<u8>> {
        XChaCha20Poly1305::new(key.into())
            .decrypt(
                &XNonce::from(self.nonce),
                Payload {
                    msg: self.sealed,
                    aad: self.sender.as_bytes(),
                },
            )
            .ok()
    }
}
