mod control;
mod hook;
mod notify;
mod patch;
mod target;

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Parser, Subcommand, ValueEnum};

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
    /// Write a markdown file in another format
    Export {
        /// The markdown file; its images come from its own folder
        file: PathBuf,
        /// The format to write
        #[arg(long, value_enum)]
        to: Format,
        /// Where to write it; by default beside the file, with the format's extension
        #[arg(long, short)]
        output: Option<PathBuf>,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum Format {
    Docx,
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
        Command::Export { file, to, output } => export(&file, to, output),
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

fn export(file: &Path, to: Format, output: Option<PathBuf>) -> Result<(), String> {
    let name = printable(&file.display().to_string());
    let markdown = fs::read_to_string(file).map_err(|error| format!("{name}: {error}"))?;
    let folder = file.parent().filter(|folder| !folder.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let (bytes, extension) = match to {
        Format::Docx => (
            dewline_core::export::docx::docx(&markdown, folder).map_err(|error| format!("{name}: {error}"))?,
            "docx",
        ),
    };
    let output = output.unwrap_or_else(|| file.with_extension(extension));
    fs::write(&output, bytes).map_err(|error| format!("{}: {error}", printable(&output.display().to_string())))
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
        let Command::Open { files, wait } = Cli::try_parse_from(args)?.command else {
            panic!("{args:?} is not open");
        };
        Ok((files, wait))
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
    fn open_refuses_what_it_does_not_take() {
        for args in [
            &["dewline"][..],
            &["dewline", "open"],
            &["dewline", "open", "--wait"],
            &["dewline", "open", "--line", "3", "plan.md"],
            &["dewline", "help"],
            &["dewline", "capture"],
            &["dewline", "plan.md"],
        ] {
            assert!(parse(args).is_err(), "{args:?}");
        }
    }
}
