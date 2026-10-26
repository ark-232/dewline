mod control;
mod target;

use std::env;
use std::ffi::OsString;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

use control::Socket;

/// Dewline from the terminal.
#[derive(Parser)]
#[command(name = "dewline", version, about, arg_required_else_help = true)]
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
}

fn main() -> ExitCode {
    let Command::Open { files, wait } = Cli::parse().command;
    match open(&files, wait) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("dewline: {message}");
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
        return Err(errors.join("\ndewline: "));
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
