use clap::Parser;

/// Dewline from the terminal.
#[derive(Parser)]
#[command(name = "dewline", version, about)]
struct Cli {}

fn main() {
    Cli::parse();
}
