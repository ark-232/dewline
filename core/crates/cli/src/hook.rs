//! A hook's JSON from stdin, read in one pass. The strings `dewline notify` uses are kept, Write's `content` is
//! hashed as it streams, and everything else is checked and dropped, so a large payload costs time, not memory.

use std::io::{self, BufRead};

use dewline_core::claims::MAX_ID;

use crate::notify::Vendor;

/// The most stdin a hook may send; a longer payload names nothing.
pub const MAX_INPUT: u64 = 64 << 20;
/// Deeper nesting than any hook sends is refused before it can exhaust the stack.
const MAX_DEPTH: usize = 64;
/// No key this reads is longer.
const MAX_KEY: usize = 32;
/// No file name a tool is given is longer.
const MAX_NAME: usize = 4096;
/// Decoded string bytes handed on at a time.
const CHUNK: usize = 64 * 1024;

/// The fields of one hook event that `dewline notify` reads.
#[derive(Debug, Default)]
pub struct Event {
    pub name: Option<String>,
    pub session: Option<String>,
    pub tool: Option<String>,
    pub tool_use_id: Option<String>,
    pub cwd: Option<String>,
    /// InstructionsLoaded's file.
    pub file_path: Option<String>,
    pub input: Input,
}

/// `tool_input`: Claude Code's file tools' fields, or Codex's patch.
#[derive(Debug, Default)]
pub struct Input {
    pub file_path: Option<String>,
    /// The BLAKE3 hash of Write's `content`.
    pub content: Option<blake3::Hash>,
    pub old_string: Option<String>,
    pub new_string: Option<String>,
    pub replace_all: Option<bool>,
    pub edits: Option<Vec<Edit>>,
    /// apply_patch's patch.
    pub command: Option<String>,
}

/// One of MultiEdit's `edits`.
#[derive(Debug, Default)]
pub struct Edit {
    pub old_string: Option<String>,
    pub new_string: Option<String>,
    pub replace_all: Option<bool>,
}

/// Reads one JSON object from `input`. Malformed or over-long input, a duplicated field, or a field of the wrong
/// type is an error: the event then names nothing.
pub fn read(input: impl BufRead, vendor: Vendor) -> io::Result<Event> {
    let mut reader = Reader {
        input: input.take(MAX_INPUT),
        depth: 0,
    };
    let mut event = Event::default();
    reader.object(&mut |reader, key| match key {
        "hook_event_name" => reader.text(&mut event.name, MAX_KEY),
        "session_id" => reader.text(&mut event.session, MAX_ID),
        "tool_name" => reader.text(&mut event.tool, MAX_KEY),
        "tool_use_id" => reader.text(&mut event.tool_use_id, MAX_ID),
        "cwd" => reader.text(&mut event.cwd, MAX_NAME),
        "file_path" => reader.text(&mut event.file_path, MAX_NAME),
        "tool_input" => reader.object(&mut |reader, key| {
            let input = &mut event.input;
            match (vendor, key) {
                (Vendor::Claude, "file_path") => reader.text(&mut input.file_path, MAX_NAME),
                (Vendor::Claude, "content") => reader.hash(&mut input.content),
                (Vendor::Claude, "old_string") => reader.text(&mut input.old_string, usize::MAX),
                (Vendor::Claude, "new_string") => reader.text(&mut input.new_string, usize::MAX),
                (Vendor::Claude, "replace_all") => reader.boolean(&mut input.replace_all),
                (Vendor::Claude, "edits") => reader.edits(&mut input.edits),
                (Vendor::Codex, "command") => reader.text(&mut input.command, usize::MAX),
                _ => reader.skip(),
            }
        }),
        _ => reader.skip(),
    })?;
    reader.whitespace()?;
    match reader.peek()? {
        None => Ok(event),
        Some(_) => Err(invalid("text after the object")),
    }
}

fn invalid(what: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, what)
}

type Field<'a, R> = dyn FnMut(&mut Reader<R>, &str) -> io::Result<()> + 'a;

struct Reader<R> {
    input: R,
    depth: usize,
}

impl<R: BufRead> Reader<R> {
    fn peek(&mut self) -> io::Result<Option<u8>> {
        Ok(self.input.fill_buf()?.first().copied())
    }

    fn next(&mut self) -> io::Result<u8> {
        let byte = self
            .peek()?
            .ok_or_else(|| invalid("the input ends early"))?;
        self.input.consume(1);
        Ok(byte)
    }

    fn whitespace(&mut self) -> io::Result<()> {
        while let Some(b' ' | b'\t' | b'\n' | b'\r') = self.peek()? {
            self.input.consume(1);
        }
        Ok(())
    }

    fn expect(&mut self, byte: u8) -> io::Result<()> {
        self.whitespace()?;
        match self.next()? == byte {
            true => Ok(()),
            false => Err(invalid("unexpected character")),
        }
    }

    fn nest(&mut self) -> io::Result<()> {
        self.depth += 1;
        match self.depth <= MAX_DEPTH {
            true => Ok(()),
            false => Err(invalid("nested too deep")),
        }
    }

    /// Calls `field` with each key, which must read that key's value.
    fn object(&mut self, field: &mut Field<'_, R>) -> io::Result<()> {
        self.nest()?;
        self.expect(b'{')?;
        self.whitespace()?;
        if self.peek()? == Some(b'}') {
            self.input.consume(1);
        } else {
            loop {
                self.expect(b'"')?;
                let mut key = Vec::new();
                self.string(&mut |bytes| {
                    // A longer key is none this reads; its value is skipped.
                    if key.len() + bytes.len() <= MAX_KEY {
                        key.extend_from_slice(bytes);
                    } else {
                        key.clear();
                        key.push(0);
                    }
                    Ok(())
                })?;
                self.expect(b':')?;
                field(self, std::str::from_utf8(&key).unwrap_or(""))?;
                self.whitespace()?;
                match self.next()? {
                    b',' => continue,
                    b'}' => break,
                    _ => return Err(invalid("unexpected character")),
                }
            }
        }
        self.depth -= 1;
        Ok(())
    }

    fn array(&mut self, item: &mut dyn FnMut(&mut Self) -> io::Result<()>) -> io::Result<()> {
        self.nest()?;
        self.expect(b'[')?;
        self.whitespace()?;
        if self.peek()? == Some(b']') {
            self.input.consume(1);
        } else {
            loop {
                item(self)?;
                self.whitespace()?;
                match self.next()? {
                    b',' => continue,
                    b']' => break,
                    _ => return Err(invalid("unexpected character")),
                }
            }
        }
        self.depth -= 1;
        Ok(())
    }

    /// A string of at most `limit` bytes.
    fn text(&mut self, slot: &mut Option<String>, limit: usize) -> io::Result<()> {
        if slot.is_some() {
            return Err(invalid("a field appears twice"));
        }
        self.expect(b'"')?;
        let mut text = Vec::new();
        self.string(&mut |bytes| {
            if text.len() + bytes.len() > limit {
                return Err(invalid("a string is too long"));
            }
            text.extend_from_slice(bytes);
            Ok(())
        })?;
        *slot = Some(String::from_utf8(text).map_err(|_| invalid("not UTF-8"))?);
        Ok(())
    }

    fn hash(&mut self, slot: &mut Option<blake3::Hash>) -> io::Result<()> {
        if slot.is_some() {
            return Err(invalid("a field appears twice"));
        }
        self.expect(b'"')?;
        let mut hasher = blake3::Hasher::new();
        self.string(&mut |bytes| {
            hasher.update(bytes);
            Ok(())
        })?;
        *slot = Some(hasher.finalize());
        Ok(())
    }

    fn boolean(&mut self, slot: &mut Option<bool>) -> io::Result<()> {
        if slot.is_some() {
            return Err(invalid("a field appears twice"));
        }
        self.whitespace()?;
        *slot = Some(match self.peek()? {
            Some(b't') => self.literal(b"true").map(|()| true)?,
            Some(b'f') => self.literal(b"false").map(|()| false)?,
            _ => return Err(invalid("not a boolean")),
        });
        Ok(())
    }

    fn edits(&mut self, slot: &mut Option<Vec<Edit>>) -> io::Result<()> {
        if slot.is_some() {
            return Err(invalid("a field appears twice"));
        }
        let mut edits = Vec::new();
        self.array(&mut |reader| {
            let mut edit = Edit::default();
            reader.object(&mut |reader, key| match key {
                "old_string" => reader.text(&mut edit.old_string, usize::MAX),
                "new_string" => reader.text(&mut edit.new_string, usize::MAX),
                "replace_all" => reader.boolean(&mut edit.replace_all),
                _ => reader.skip(),
            })?;
            edits.push(edit);
            Ok(())
        })?;
        *slot = Some(edits);
        Ok(())
    }

    /// Reads and drops one value of any kind.
    fn skip(&mut self) -> io::Result<()> {
        self.whitespace()?;
        match self
            .peek()?
            .ok_or_else(|| invalid("the input ends early"))?
        {
            b'{' => self.object(&mut |reader, _| reader.skip()),
            b'[' => self.array(&mut |reader| reader.skip()),
            b'"' => {
                self.input.consume(1);
                self.string(&mut |_| Ok(()))
            }
            b't' => self.literal(b"true"),
            b'f' => self.literal(b"false"),
            b'n' => self.literal(b"null"),
            b'-' | b'0'..=b'9' => {
                while let Some(b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E') = self.peek()? {
                    self.input.consume(1);
                }
                Ok(())
            }
            _ => Err(invalid("unexpected character")),
        }
    }

    fn literal(&mut self, word: &[u8]) -> io::Result<()> {
        for &byte in word {
            if self.next()? != byte {
                return Err(invalid("unexpected character"));
            }
        }
        Ok(())
    }

    /// Decodes a string whose opening quote has been read, handing its UTF-8 bytes to `out` in chunks that each end
    /// on a character boundary.
    fn string(&mut self, out: &mut dyn FnMut(&[u8]) -> io::Result<()>) -> io::Result<()> {
        let mut chunk = Vec::new();
        loop {
            let buffer = self.input.fill_buf()?;
            if buffer.is_empty() {
                return Err(invalid("the input ends inside a string"));
            }
            let run = buffer
                .iter()
                .position(|&byte| byte == b'"' || byte == b'\\' || byte < 0x20)
                .unwrap_or(buffer.len());
            chunk.extend_from_slice(&buffer[..run]);
            let stop = buffer.get(run).copied();
            self.input.consume(run);
            match stop {
                None => {}
                Some(b'"') => {
                    self.input.consume(1);
                    return flush(&mut chunk, out, true);
                }
                Some(b'\\') => {
                    self.input.consume(1);
                    let c = self.escape()?;
                    chunk.extend_from_slice(c.encode_utf8(&mut [0; 4]).as_bytes());
                }
                Some(_) => return Err(invalid("a control character inside a string")),
            }
            if chunk.len() >= CHUNK {
                flush(&mut chunk, out, false)?;
            }
        }
    }

    fn escape(&mut self) -> io::Result<char> {
        Ok(match self.next()? {
            b'"' => '"',
            b'\\' => '\\',
            b'/' => '/',
            b'b' => '\u{8}',
            b'f' => '\u{c}',
            b'n' => '\n',
            b'r' => '\r',
            b't' => '\t',
            b'u' => {
                let unit = self.hex4()?;
                let code = match unit {
                    0xD800..=0xDBFF => {
                        self.literal(b"\\u")?;
                        let low = self.hex4()?;
                        if !(0xDC00..=0xDFFF).contains(&low) {
                            return Err(invalid("a lone surrogate"));
                        }
                        0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    }
                    0xDC00..=0xDFFF => return Err(invalid("a lone surrogate")),
                    _ => unit,
                };
                char::from_u32(code).ok_or_else(|| invalid("a bad escape"))?
            }
            _ => return Err(invalid("a bad escape")),
        })
    }

    fn hex4(&mut self) -> io::Result<u32> {
        let mut value = 0;
        for _ in 0..4 {
            let digit = char::from(self.next()?)
                .to_digit(16)
                .ok_or_else(|| invalid("a bad escape"))?;
            value = value * 16 + digit;
        }
        Ok(value)
    }
}

/// Hands on the valid UTF-8 in `chunk`, keeping a character split at its end for the next chunk unless `last`.
fn flush(
    chunk: &mut Vec<u8>,
    out: &mut dyn FnMut(&[u8]) -> io::Result<()>,
    last: bool,
) -> io::Result<()> {
    let valid = match std::str::from_utf8(chunk) {
        Ok(_) => chunk.len(),
        Err(error) if error.error_len().is_none() && !last => error.valid_up_to(),
        Err(_) => return Err(invalid("not UTF-8")),
    };
    out(&chunk[..valid])?;
    chunk.drain(..valid);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claude(json: &str) -> io::Result<Event> {
        read(json.as_bytes(), Vendor::Claude)
    }

    #[test]
    fn keeps_the_fields_notify_reads() {
        let event = claude(
            r#"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/repo","hook_event_name":"PreToolUse",
            "tool_name":"Edit","tool_input":{"file_path":"/repo/plan.md","old_string":"a\nb","new_string":"é😀",
            "replace_all":true,"extra":[1,{"x":null}]},"tool_use_id":"toolu_1","tool_response":{"originalFile":"big"}}"#,
        )
        .unwrap();
        assert_eq!(event.name.as_deref(), Some("PreToolUse"));
        assert_eq!(event.session.as_deref(), Some("s1"));
        assert_eq!(event.tool.as_deref(), Some("Edit"));
        assert_eq!(event.tool_use_id.as_deref(), Some("toolu_1"));
        assert_eq!(event.cwd.as_deref(), Some("/repo"));
        assert_eq!(event.input.file_path.as_deref(), Some("/repo/plan.md"));
        assert_eq!(event.input.old_string.as_deref(), Some("a\nb"));
        assert_eq!(event.input.new_string.as_deref(), Some("é😀"));
        assert_eq!(event.input.replace_all, Some(true));
    }

    #[test]
    fn content_is_hashed_as_it_streams() {
        let text = "line \"one\"\n\tcafé ".repeat(20_000);
        let json =
            serde_json::json!({"hook_event_name": "PreToolUse", "tool_input": {"content": text}})
                .to_string();
        let event = claude(&json).unwrap();
        assert_eq!(event.input.content, Some(blake3::hash(text.as_bytes())));
        // Codex's events have no Write.
        assert_eq!(
            read(json.as_bytes(), Vendor::Codex).unwrap().input.content,
            None
        );
    }

    #[test]
    fn refuses_what_is_not_one_plain_object() {
        let deep = format!("{{\"a\":{}1{}}}", "[".repeat(100), "]".repeat(100));
        let long_id = format!(r#"{{"session_id":"{}"}}"#, "a".repeat(MAX_ID + 1));
        for json in [
            "",
            "[]",
            "{",
            r#"{"session_id":"s1"} {}"#,
            r#"{"session_id":"s1","session_id":"s2"}"#,
            r#"{"session_id":1}"#,
            r#"{"tool_input":{"replace_all":"yes"}}"#,
            r#"{"tool_input":{"content":"a","content":"b"}}"#,
            r#"{"session_id":"\ud800"}"#,
            r#"{"session_id":"\udc00x"}"#,
            r#"{"session_id":"\q"}"#,
            "{\"session_id\":\"new\nline\"}",
            r#"{"a":tru}"#,
            &deep,
            &long_id,
        ] {
            assert!(claude(json).is_err(), "{json:?}");
        }
        assert!(read(&b"{\"session_id\":\"\xff\"}"[..], Vendor::Claude).is_err());
        assert!(claude(r#" {"unknown":{"deep":[true,false,null,-1.5e3,"\u0000"]}} "#).is_ok());
    }

    #[test]
    fn input_past_the_cap_is_refused() {
        let mut huge = br#"{"prompt":""#.to_vec();
        huge.resize(MAX_INPUT as usize + 10, b'a');
        huge.extend_from_slice(br#""}"#);
        assert!(read(&huge[..], Vendor::Claude).is_err());
    }
}
