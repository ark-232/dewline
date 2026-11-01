//! `dewline://join?node=…&relay=…&addr=…&cap=…`: the host's node address and
//! a one-time join capability. Binary values are lowercase base32 without
//! padding; the relay URL is percent-encoded.

use std::net::SocketAddr;

use data_encoding::BASE32_NOPAD;
use iroh::{EndpointAddr, PublicKey, RelayUrl, TransportAddr};

const PREFIX: &str = "dewline://join?";

pub struct Invite {
    pub host: EndpointAddr,
    pub capability: [u8; 32],
}

fn base32(bytes: &[u8]) -> String {
    BASE32_NOPAD.encode(bytes).to_ascii_lowercase()
}

fn unbase32<const N: usize>(text: &str) -> Option<[u8; N]> {
    BASE32_NOPAD
        .decode(text.to_ascii_uppercase().as_bytes())
        .ok()?
        .try_into()
        .ok()
}

fn escape(text: &str) -> String {
    text.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

fn unescape(text: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(text.len());
    let mut rest = text.as_bytes();
    while let [first, tail @ ..] = rest {
        if *first == b'%' {
            let hex = std::str::from_utf8(tail.get(..2)?).ok()?;
            bytes.push(u8::from_str_radix(hex, 16).ok()?);
            rest = &tail[2..];
        } else {
            bytes.push(*first);
            rest = tail;
        }
    }
    String::from_utf8(bytes).ok()
}

impl Invite {
    pub fn format(&self) -> String {
        let mut link = format!("{PREFIX}node={}", base32(self.host.id.as_bytes()));
        for addr in &self.host.addrs {
            match addr {
                TransportAddr::Relay(url) => {
                    link += &format!("&relay={}", escape(url.as_str()));
                }
                TransportAddr::Ip(ip) => link += &format!("&addr={}", escape(&ip.to_string())),
                _ => {}
            }
        }
        link + &format!("&cap={}", base32(&self.capability))
    }

    pub fn parse(link: &str) -> Option<Invite> {
        let query = link.trim().strip_prefix(PREFIX)?;
        let (mut node, mut capability, mut addrs) = (None, None, Vec::new());
        for pair in query.split('&') {
            let (key, value) = pair.split_once('=')?;
            match key {
                "node" => node = Some(PublicKey::from_bytes(&unbase32(value)?).ok()?),
                "cap" => capability = Some(unbase32(value)?),
                "relay" => addrs.push(TransportAddr::Relay(
                    unescape(value)?.parse::<RelayUrl>().ok()?,
                )),
                "addr" => addrs.push(TransportAddr::Ip(
                    unescape(value)?.parse::<SocketAddr>().ok()?,
                )),
                _ => {}
            }
        }
        Some(Invite {
            host: EndpointAddr::from_parts(node?, addrs),
            capability: capability?,
        })
    }
}
