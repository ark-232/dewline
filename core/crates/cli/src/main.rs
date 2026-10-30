mod control;
mod doctor;
mod export;
mod mcp;
mod target;

use std::env;
use std::ffi::OsString;
use std::io::{self, Read};
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use dewline_core::inbox;

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
    /// Add a dated entry to the inbox, ~/Documents/Dewline/Inbox.md
    Capture {
        /// The entry's text; without it, stdin is read
        text: Vec<String>,
    },
    /// Export a markdown file as HTML or PDF
    #[command(long_about = "Export a markdown file as HTML or PDF.\n\n\
                      HTML is written here, with images in the file's folder inlined; diagrams and math keep \
                      their source. PDF needs the Dewline app: this command hands the file to it.")]
    Export {
        file: PathBuf,
        #[arg(long, value_enum)]
        to: export::Format,
        /// Where the export goes; beside FILE with the format's extension by default
        #[arg(short = 'o')]
        out: Option<PathBuf>,
    },
    /// Serve a folder's notes to an agent over stdio (MCP): read, search, backlinks and append_to_inbox
    Mcp {
        /// The folder served; never your home folder or above it, ~/Library, or a folder holding .ssh
        root: PathBuf,
    },
    /// Check the app's version, the agent hooks and the companion tools
    Doctor {
        /// Merge Dewline's hooks into Claude Code's and Codex's settings, asking first
        #[arg(long)]
        install_hooks: bool,
    },
}

fn main() -> ExitCode {
    let result = match Cli::parse().command {
        Command::Open { files, wait } => open(&files, wait),
        Command::Capture { text } => capture(text),
        Command::Export { file, to, out } => export::run(&file, to, out.as_deref()),
        Command::Mcp { root } => mcp::run(&root),
        Command::Doctor { install_hooks } => doctor::run(install_hooks),
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

/// The inbox file every capture appends to.
fn inbox_path() -> Result<PathBuf, String> {
    env::home_dir()
        .map(|home| inbox::default_path(&home))
        .ok_or_else(|| "there is no home folder for the inbox".into())
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
                install_hooks: true
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
