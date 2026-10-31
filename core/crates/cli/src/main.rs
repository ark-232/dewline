mod control;
mod doctor;
mod export;
mod hook;
mod mcp;
mod notify;
mod patch;
mod target;

use std::env;
use std::ffi::{OsStr, OsString};
use std::io::{self, Read};
use std::path::PathBuf;
use std::process::{Command as Process, ExitCode, Stdio};

use clap::{Parser, Subcommand};
use dewline_core::{decisions, inbox};

use control::Socket;

/// Dewline from the terminal.
#[derive(Parser)]
#[command(
    name = "dewline",
    version,
    about,
    arg_required_else_help = true,
    disable_help_subcommand = true
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Open files in Dewline, starting it if it isn't running
    Open {
        /// A file, with the caret at LINE and COLUMN when given (both count from 1)
        #[arg(required = true, value_name = "FILE[:LINE[:COLUMN]]")]
        files: Vec<OsString>,
        /// Return once every file's window has closed, as EDITOR="dewline open --wait" needs
        #[arg(long)]
        wait: bool,
    },
    /// Tell Dewline which file an agent's tool is changing; agents' hooks run it with the event's JSON on stdin
    Notify {
        /// Whose hook runs it
        #[arg(long, value_enum)]
        hook: notify::Vendor,
    },
    /// List the agents' changes you kept and reverted, oldest first
    Changes {
        /// Print a JSON array, one object per decision
        #[arg(long)]
        json: bool,
        /// Only this agent session's decisions
        #[arg(long, value_name = "ID")]
        session: Option<String>,
        /// Only decisions at or after this UTC time: 2026-10-30, 2026-10-30T18:00:00Z
        #[arg(long, value_name = "TIME")]
        since: Option<String>,
    },
    /// Add a dated entry to the inbox, ~/Documents/Dewline/Inbox.md
    Capture {
        /// The entry's text; without it, stdin is read
        text: Vec<String>,
    },
    /// Export a markdown file as HTML, PDF or DOCX
    #[command(long_about = "Export a markdown file as HTML, PDF or DOCX.\n\n\
                      HTML and DOCX are written here, with images in the file's folder inlined; diagrams and math keep \
                      their source. PDF needs the Dewline app: this command hands the file to it.")]
    Export {
        file: PathBuf,
        #[arg(long, value_enum)]
        to: export::Format,
        /// Where the export goes; beside FILE with the format's extension by default
        #[arg(short = 'o')]
        out: Option<PathBuf>,
    },
    /// Serve a folder's notes to an agent over stdio (MCP): read, search, backlinks, decisions and append_to_inbox
    Mcp {
        /// The folder served; never your home folder or above it, ~/Library, or a folder holding .ssh
        root: PathBuf,
    },
    /// Check the app's version, the agent hooks and the companion tools
    Doctor {
        /// Merge Dewline's hooks into Claude Code's, Codex's and Cursor's settings, asking first
        #[arg(long)]
        install_hooks: bool,
        /// Print the broken relative links and CLAUDE.md @imports of the markdown files under DIR, and nothing else
        #[arg(long, value_name = "DIR", conflicts_with = "install_hooks")]
        links: Option<PathBuf>,
    },
}

fn main() -> ExitCode {
    let command = match Cli::try_parse() {
        Ok(cli) => cli.command,
        // A hook's exit status reaches the agent: Claude Code and Codex take 2 as a refusal of the tool call.
        Err(error) if env::args_os().nth(1).as_deref() == Some(OsStr::new("notify")) => {
            let _ = error.print();
            return ExitCode::SUCCESS;
        }
        Err(error) => error.exit(),
    };
    let result = match command {
        Command::Open { files, wait } => open(&files, wait),
        Command::Notify { hook } => {
            notify::run(hook);
            return ExitCode::SUCCESS;
        }
        Command::Changes {
            json,
            session,
            since,
        } => return changes(json, session.as_deref(), since.as_deref()),
        Command::Capture { text } => capture(text),
        Command::Export { file, to, out } => export::run(&file, to, out.as_deref()),
        Command::Mcp { root } => mcp::run(&root),
        Command::Doctor {
            links: Some(dir), ..
        } => doctor::links(&dir),
        Command::Doctor { install_hooks, .. } => doctor::run(install_hooks),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            for line in message.lines() {
                eprintln!("dewline: {}", printable(line));
            }
            ExitCode::FAILURE
        }
    }
}

/// Checks every file before asking the app for any, so a bad name opens nothing.
fn open(files: &[OsString], wait: bool) -> Result<(), String> {
    let cwd = env::current_dir().map_err(|error| format!("the current folder: {error}"))?;
    let home = env::home_dir();
    let mut targets = Vec::new();
    let mut errors = Vec::new();
    for file in files {
        match target::resolve(file, &cwd, home.as_deref()) {
            Ok(target) => targets.push(target),
            Err(error) => errors.push(error),
        }
    }
    if !errors.is_empty() {
        return Err(errors.join("\n"));
    }
    let socket = Socket::find()?;
    let connections = targets
        .iter()
        .map(|target| socket.open(target, wait))
        .collect::<Result<Vec<_>, _>>()?;
    socket.activate();
    if wait {
        for connection in connections {
            connection.wait()?;
        }
    }
    Ok(())
}

fn changes(json: bool, session: Option<&str>, since: Option<&str>) -> ExitCode {
    let read = decisions::standard_root()
        .ok_or_else(|| "no home folder".to_owned())
        .and_then(|root| {
            decisions::read(&root, session, since)
                .map_err(|error| format!("the decisions log: {error}"))
        });
    let records = match read {
        Ok(records) => records,
        Err(message) => {
            eprintln!("dewline: {message}");
            return ExitCode::FAILURE;
        }
    };
    if json {
        println!("{}", serde_json::Value::Array(records));
        return ExitCode::SUCCESS;
    }
    for record in records {
        let field = |key: &str| printable(record[key].as_str().unwrap_or(""));
        println!(
            "{}  {:<8}  {} {}  {}",
            field("time"),
            field("decision"),
            field("vendor"),
            field("session"),
            field("file")
        );
    }
    ExitCode::SUCCESS
}

fn capture(words: Vec<String>) -> Result<(), String> {
    let text = if words.is_empty() {
        let mut text = String::new();
        io::stdin()
            .read_to_string(&mut text)
            .map_err(|error| format!("stdin: {error}"))?;
        text
    } else {
        words.join(" ")
    };
    let path = inbox_path()?;
    inbox::append(&path, "cli", &text).map_err(|error| format!("{}: {error}", path.display()))
}

/// The inbox file every capture appends to: the app's `DewlineInboxPath` setting (Settings > Files), else
/// ~/Documents/Dewline/Inbox.md.
fn inbox_path() -> Result<PathBuf, String> {
    let home = env::home_dir().ok_or("there is no home folder for the inbox")?;
    let set = Process::new("/usr/bin/defaults")
        .args(["read", "dev.arkwerx.dewline", "DewlineInboxPath"])
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok());
    Ok(set
        .as_deref()
        .and_then(|path| setting_path(path, &home))
        .unwrap_or_else(|| inbox::default_path(&home)))
}

/// A path setting as the app reads it: absolute, or under `~/`.
fn setting_path(value: &str, home: &std::path::Path) -> Option<PathBuf> {
    let value = value.trim_end_matches('\n');
    if let Some(rest) = value.strip_prefix("~/") {
        Some(home.join(rest))
    } else {
        value.starts_with('/').then(|| PathBuf::from(value))
    }
}

/// Paths and the app's messages with control characters replaced, so a
/// hostile name can't drive the terminal.
fn printable(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_control() { '\u{FFFD}' } else { c })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    fn parse(args: &[&str]) -> Result<(Vec<OsString>, bool), clap::Error> {
        match Cli::try_parse_from(args)?.command {
            Command::Open { files, wait } => Ok((files, wait)),
            _ => Err(clap::Error::new(clap::error::ErrorKind::InvalidSubcommand)),
        }
    }

    #[test]
    fn open_takes_files_and_wait_in_any_order() {
        Cli::command().debug_assert();
        let files = |names: &[&str]| names.iter().map(OsString::from).collect::<Vec<_>>();
        assert_eq!(
            parse(&["dewline", "open", "plan.md", "notes.md:3:1", "--wait"]).unwrap(),
            (files(&["plan.md", "notes.md:3:1"]), true)
        );
        assert_eq!(
            parse(&["dewline", "open", "--wait", "plan.md"]).unwrap(),
            (files(&["plan.md"]), true)
        );
        assert_eq!(
            parse(&["dewline", "open", "plan.md"]).unwrap(),
            (files(&["plan.md"]), false)
        );
        // After --, a name that looks like a flag is a file.
        assert_eq!(
            parse(&["dewline", "open", "--", "--wait"]).unwrap(),
            (files(&["--wait"]), false)
        );
    }

    #[test]
    fn the_other_commands_parse() {
        let command = |args: &[&str]| Cli::try_parse_from(args).map(|cli| cli.command);
        assert!(matches!(
            command(&["dewline", "capture", "buy", "milk"]),
            Ok(Command::Capture { text }) if text == ["buy", "milk"]
        ));
        assert!(
            matches!(command(&["dewline", "capture"]), Ok(Command::Capture { text }) if text.is_empty())
        );
        assert!(matches!(
            command(&["dewline", "export", "a.md", "--to", "pdf", "-o", "b.pdf"]),
            Ok(Command::Export {
                to: export::Format::Pdf,
                out: Some(_),
                ..
            })
        ));
        assert!(command(&["dewline", "export", "a.md"]).is_err());
        assert!(command(&["dewline", "export", "a.md", "--to", "docx"]).is_err());
        assert!(command(&["dewline", "mcp"]).is_err());
        assert!(matches!(
            command(&["dewline", "doctor", "--install-hooks"]),
            Ok(Command::Doctor {
                install_hooks: true,
                links: None
            })
        ));
    }

    #[test]
    fn printable_keeps_text_and_drops_escapes() {
        assert_eq!(
            printable("café \u{1b}]0;title\u{7}\r"),
            "café \u{FFFD}]0;title\u{FFFD}\u{FFFD}"
        );
    }

    #[test]
    fn notify_takes_one_hook() {
        for (args, hook) in [
            (
                &["dewline", "notify", "--hook", "claude"][..],
                notify::Vendor::Claude,
            ),
            (
                &["dewline", "notify", "--hook=codex"],
                notify::Vendor::Codex,
            ),
        ] {
            let Command::Notify { hook: parsed } = Cli::try_parse_from(args).unwrap().command
            else {
                panic!("{args:?}")
            };
            assert_eq!(parsed, hook);
        }
        for args in [
            &["dewline", "notify"][..],
            &["dewline", "notify", "--hook", "cursor"],
            &["dewline", "notify", "--hook", "claude", "extra"],
        ] {
            assert!(Cli::try_parse_from(args).is_err(), "{args:?}");
        }
    }

    #[test]
    fn open_needs_a_file() {
        for args in [
            &["dewline"][..],
            &["dewline", "open"],
            &["dewline", "open", "--wait"],
            &["dewline", "open", "--line", "3", "plan.md"],
            &["dewline", "help"],
            &["dewline", "plan.md"],
        ] {
            assert!(parse(args).is_err(), "{args:?}");
        }
    }
}
