//! `dewline mcp`: a folder's notes for an agent, as an MCP server on stdio (JSON-RPC 2.0, one message per line).
//! Every path goes through core's jail. Only `.md`, `.markdown` and `.txt` files are served, never a dotfile or
//! anything under a dot folder such as `.git`, and the one file written is the inbox.

use std::env;
use std::fs;
use std::io::{self, BufRead, Read, Write};
use std::path::{Component, Path, PathBuf};

use dewline_core::jail::Jail;
use dewline_core::{decisions, inbox};
use serde_json::{Value, json};

/// Protocol versions this server speaks, newest first.
const VERSIONS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
/// The most a tool reads of one file.
const MAX_FILE: u64 = 8 << 20;
/// The most lines a search or backlinks call returns.
const MAX_HITS: usize = 200;
/// The most files a search or backlinks call reads.
const MAX_FILES: usize = 20_000;

pub fn run(root: &Path) -> Result<(), String> {
    let home = env::home_dir().ok_or("there is no home folder")?;
    let jail =
        Jail::for_agents(root, &home).map_err(|error| format!("{}: {error}", root.display()))?;
    let server = Server {
        jail,
        inbox: crate::inbox_path()?,
    };
    let stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();
    for line in stdin.lines() {
        let line = line.map_err(|error| format!("stdin: {error}"))?;
        if line.trim().is_empty() {
            continue;
        }
        if let Some(reply) = server.handle(&line) {
            writeln!(stdout, "{reply}")
                .and_then(|()| stdout.flush())
                .map_err(|error| format!("stdout: {error}"))?;
        }
    }
    Ok(())
}

struct Server {
    jail: Jail,
    inbox: PathBuf,
}

impl Server {
    /// The reply to one message, or none for a notification.
    fn handle(&self, line: &str) -> Option<Value> {
        let Ok(message) = serde_json::from_str::<Value>(line) else {
            return Some(error(Value::Null, -32700, "Parse error"));
        };
        let id = message.get("id").cloned();
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            return Some(error(id.unwrap_or(Value::Null), -32600, "Invalid Request"));
        };
        let id = id?;
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        let result = match method {
            "initialize" => {
                let asked = params.get("protocolVersion").and_then(Value::as_str);
                let version = VERSIONS.into_iter().find(|&version| Some(version) == asked);
                json!({
                    "protocolVersion": version.unwrap_or(VERSIONS[0]),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "dewline", "version": env!("CARGO_PKG_VERSION")},
                })
            }
            "ping" => json!({}),
            "tools/list" => json!({"tools": tools()}),
            "tools/call" => {
                let name = params
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let arguments = params.get("arguments").cloned().unwrap_or(json!({}));
                match self.call(name, &arguments) {
                    Some(Ok(text)) => {
                        json!({"content": [{"type": "text", "text": text}], "isError": false})
                    }
                    Some(Err(message)) => {
                        json!({"content": [{"type": "text", "text": message}], "isError": true})
                    }
                    None => return Some(error(id, -32602, &format!("Unknown tool: {name}"))),
                }
            }
            _ => return Some(error(id, -32601, "Method not found")),
        };
        Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
    }

    fn call(&self, name: &str, arguments: &Value) -> Option<Result<String, String>> {
        let argument = |key: &str| {
            arguments
                .get(key)
                .and_then(Value::as_str)
                .ok_or_else(|| format!("{name} needs a string `{key}`"))
        };
        Some(match name {
            "read" => {
                argument("path").and_then(|path| self.read(Path::new(path)).map(|(text, _)| text))
            }
            "search" => argument("query").and_then(|query| self.search(query)),
            "backlinks" => argument("note").and_then(|note| self.backlinks(Path::new(note))),
            "append_to_inbox" => argument("text").and_then(|text| {
                inbox::append(&self.inbox, "mcp", text)
                    .map(|()| "Added to the inbox.".to_owned())
                    .map_err(|error| format!("The inbox: {error}"))
            }),
            "decisions" => {
                let optional = |key: &str| match arguments.get(key) {
                    None | Some(Value::Null) => Ok(None),
                    Some(Value::String(value)) => Ok(Some(value.as_str())),
                    Some(_) => Err(format!("{name} takes `{key}` as a string")),
                };
                optional("session").and_then(|session| {
                    let since = optional("since")?;
                    let root = decisions::standard_root().ok_or("there is no home folder")?;
                    let records = decisions::read(&root, session, since)
                        .map_err(|error| format!("The decisions log: {error}"))?;
                    Ok(Value::Array(self.inside(records)).to_string())
                })
            }
            _ => return None,
        })
    }

    /// The decisions on files under the root, each `file` made root-relative; the rest would leak paths outside it.
    fn inside(&self, records: Vec<Value>) -> Vec<Value> {
        records
            .into_iter()
            .filter_map(|mut record| {
                let file = PathBuf::from(record["file"].as_str()?);
                let real = fs::canonicalize(&file).unwrap_or(file);
                let relative = real.strip_prefix(self.jail.root()).ok()?;
                record["file"] = relative.to_string_lossy().into();
                Some(record)
            })
            .collect()
    }

    /// A served file's text and its root-relative path.
    fn read(&self, path: &Path) -> Result<(String, PathBuf), String> {
        let refused = |why: String| format!("{}: {why}", path.display());
        let (file, relative) = self
            .jail
            .open(path)
            .map_err(|error| refused(error.to_string()))?;
        if !served(&relative) {
            return Err(refused(
                "only .md, .markdown and .txt files outside dot folders are served".into(),
            ));
        }
        let info = file
            .metadata()
            .map_err(|error| refused(error.to_string()))?;
        if !info.is_file() || info.len() > MAX_FILE {
            return Err(refused("it is not a file of at most 8 MB".into()));
        }
        let mut bytes = Vec::new();
        file.take(MAX_FILE)
            .read_to_end(&mut bytes)
            .map_err(|error| refused(error.to_string()))?;
        let text = String::from_utf8(bytes).map_err(|_| refused("it is not UTF-8 text".into()))?;
        Ok((text, relative))
    }

    fn search(&self, query: &str) -> Result<String, String> {
        let needle = query.to_lowercase();
        if needle.trim().is_empty() {
            return Err("search needs a non-empty query".into());
        }
        Ok(self.lines(|_, line| line.to_lowercase().contains(&needle)))
    }

    fn backlinks(&self, note: &Path) -> Result<String, String> {
        let (_, target) = self.read(note)?;
        Ok(self.lines(|source, line| links_to(source, line, &target)))
    }

    /// `path:line: text` for each line of each served file that `matches`.
    fn lines(&self, matches: impl Fn(&Path, &str) -> bool) -> String {
        let mut files = Vec::new();
        walk(self.jail.root(), Path::new(""), &mut files);
        let mut out = String::new();
        let mut hits = 0;
        for relative in files {
            let Ok((text, relative)) = self.read(&relative) else {
                continue;
            };
            for (number, line) in text.lines().enumerate() {
                if matches(&relative, line) {
                    let line: String = line.trim().chars().take(240).collect();
                    out.push_str(&format!("{}:{}: {line}\n", relative.display(), number + 1));
                    hits += 1;
                    if hits == MAX_HITS {
                        return out;
                    }
                }
            }
        }
        if out.is_empty() {
            out.push_str("No matches.");
        }
        out
    }
}

/// Collects the served files under `folder`, root-relative, in name order. Links are skipped, not followed.
fn walk(root: &Path, folder: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root.join(folder)) else {
        return;
    };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        if files.len() == MAX_FILES {
            return;
        }
        let relative = folder.join(entry.file_name());
        match entry.file_type() {
            Ok(kind) if kind.is_dir() && !hidden(&relative) => walk(root, &relative, files),
            Ok(kind) if kind.is_file() && served(&relative) => files.push(relative),
            _ => {}
        }
    }
}

fn hidden(relative: &Path) -> bool {
    relative
        .components()
        .any(|part| part.as_os_str().as_encoded_bytes().starts_with(b"."))
}

fn served(relative: &Path) -> bool {
    !hidden(relative)
        && relative.extension().is_some_and(|extension| {
            ["md", "markdown", "txt"]
                .iter()
                .any(|served| extension.eq_ignore_ascii_case(served))
        })
}

/// Whether `line` of `source` holds a wikilink or a markdown link to `target`, both root-relative. A wikilink names
/// the note's root-relative path or its file name, with or without the extension; a markdown link is a path relative
/// to `source`'s folder.
fn links_to(source: &Path, line: &str, target: &Path) -> bool {
    let target_text = target.to_string_lossy();
    let without_extension = target.with_extension("");
    let without_extension = without_extension.to_string_lossy();
    let stem = target.file_stem().unwrap_or_default().to_string_lossy();
    let file_name = target.file_name().unwrap_or_default().to_string_lossy();
    let wikilink = |name: &str| {
        let name = name.split(['|', '#']).next().unwrap_or_default().trim();
        [&*target_text, &*without_extension, &*stem, &*file_name]
            .iter()
            .any(|form| name.eq_ignore_ascii_case(form))
    };
    if line
        .split("[[")
        .skip(1)
        .filter_map(|rest| rest.split_once("]]"))
        .any(|(name, _)| wikilink(name))
    {
        return true;
    }
    let folder = source.parent().unwrap_or(Path::new(""));
    line.split("](").skip(1).any(|rest| {
        let destination = rest.split(')').next().unwrap_or_default().trim();
        let destination = match destination.strip_prefix('<') {
            Some(angled) => angled.split('>').next().unwrap_or_default(),
            None => destination.split(' ').next().unwrap_or_default(),
        };
        let destination = destination.split('#').next().unwrap_or_default();
        if destination.is_empty() || destination.contains(':') || destination.starts_with('/') {
            return false;
        }
        normalize(&folder.join(unescape(destination)))
            .is_some_and(|path| path.to_string_lossy().eq_ignore_ascii_case(&target_text))
    })
}

/// `path` with `.` and `..` folded away, or `None` when it climbs above the root.
fn normalize(path: &Path) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::Normal(name) => out.push(name),
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    return None;
                }
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    Some(out)
}

/// A link destination with its `%XX` escapes decoded.
fn unescape(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let hex = bytes
            .get(at + 1..at + 3)
            .and_then(|hex| std::str::from_utf8(hex).ok())
            .and_then(|hex| u8::from_str_radix(hex, 16).ok());
        match (bytes[at], hex) {
            (b'%', Some(byte)) => {
                out.push(byte);
                at += 3;
            }
            (byte, _) => {
                out.push(byte);
                at += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

fn tools() -> Value {
    let tool = |name: &str, description: &str, argument: &str, about: &str| {
        json!({
            "name": name,
            "description": description,
            "inputSchema": {
                "type": "object",
                "properties": {(argument): {"type": "string", "description": about}},
                "required": [argument],
            },
        })
    };
    json!([
        tool(
            "read",
            "Read a note: a .md, .markdown or .txt file in the folder.",
            "path",
            "The note's path, relative to the folder"
        ),
        tool(
            "search",
            "Find the lines in the folder's notes that hold some text, ignoring case. Returns path:line: text.",
            "query",
            "The text to find"
        ),
        tool(
            "backlinks",
            "Find the lines in other notes that link to a note, by [[wikilink]] or markdown link. Returns path:line: text.",
            "note",
            "The note's path, relative to the folder"
        ),
        json!({
            "name": "decisions",
            "description": "List the agents' changes the user kept or reverted in Dewline, oldest first, as a JSON array.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session": {"type": "string", "description": "Only this agent session's decisions"},
                    "since": {"type": "string", "description": "Only decisions at or after this UTC time: 2026-10-30, 2026-10-30T18:00:00Z"},
                },
            },
        }),
        tool(
            "append_to_inbox",
            "Add a dated entry to the end of the user's inbox note. The only change this server can make.",
            "text",
            "The entry's markdown"
        ),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_name_the_note_by_path_or_name() {
        let target = Path::new("projects/launch plan.md");
        let links = |source: &str, line: &str| links_to(Path::new(source), line, target);
        assert!(links("a.md", "see [[launch plan]] today"));
        assert!(links("a.md", "see [[Launch Plan|the plan]]"));
        assert!(links("a.md", "see [[projects/launch plan#Goals]]"));
        assert!(links("a.md", "see [[launch plan.md]]"));
        assert!(links("a.md", "[plan](projects/launch%20plan.md)"));
        assert!(links(
            "a.md",
            "[plan](<projects/launch plan.md#goals> \"title\")"
        ));
        assert!(links("projects/b.md", "[plan](./launch%20plan.md)"));
        assert!(links("notes/c.md", "[plan](../projects/launch%20plan.md)"));
        assert!(!links("a.md", "[[launch]] and [[plan]]"));
        assert!(!links("a.md", "[plan](launch%20plan.md)"));
        assert!(!links(
            "a.md",
            "[plan](https://example.com/projects/launch%20plan.md)"
        ));
        assert!(!links("a.md", "[plan](../../projects/launch%20plan.md)"));
    }

    #[test]
    fn only_notes_outside_dot_folders_are_served() {
        assert!(served(Path::new("a/b.md")));
        assert!(served(Path::new("a/B.MARKDOWN")));
        assert!(served(Path::new("todo.txt")));
        assert!(!served(Path::new(".git/HEAD.md")));
        assert!(!served(Path::new("a/.secret.md")));
        assert!(!served(Path::new("a/b.html")));
        assert!(!served(Path::new("a/md")));
    }
}
