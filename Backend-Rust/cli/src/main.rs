//! `recall` — CLI client for the Infinite Recall local HTTP API.
//!
//! Wraps the daemon at `http://127.0.0.1:7331` with a stable command surface
//! designed for both humans and coding agents. Agents should always pass
//! `--json` (see `AGENTS.md` at the repo root); humans get a compact tabular
//! view by default.
//!
//! Build (workspace): `cd Backend-Rust && cargo build --release -p recall-cli`
//!
//! Layout:
//! - `client.rs` — blocking `reqwest` wrapper, JSON in/out
//! - `auth.rs`   — token loading (delegates to `infinite_recall_api::token`)
//! - `error.rs`  — typed errors with stable exit codes
//! - `output.rs` — `--json` passthrough vs human renderer
//! - `commands/` — one module per top-level verb

mod auth;
mod client;
mod commands;
mod error;
mod output;

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

use crate::error::CliError;

/// Top-level parser. Global flags live on `GlobalOpts` and are reachable from
/// every subcommand thanks to `global = true`.
#[derive(Parser, Debug)]
#[command(
    name = "recall",
    version,
    about = "CLI client for the Infinite Recall local API",
    long_about = "Wraps the local Infinite Recall HTTP daemon. All data is on-device.\n\
                  Coding agents should always pass --json. See AGENTS.md."
)]
struct Cli {
    #[command(flatten)]
    global: GlobalOpts,

    #[command(subcommand)]
    command: Command,
}

#[derive(Parser, Debug, Clone)]
pub struct GlobalOpts {
    /// Emit raw JSON instead of human-readable output.
    #[arg(long, global = true)]
    pub json: bool,

    /// Path to the bearer-token file. Defaults to the daemon's standard
    /// location (or `INFINITE_RECALL_TOKEN_PATH`).
    #[arg(long, global = true, value_name = "PATH")]
    pub token_path: Option<PathBuf>,

    /// API base URL.
    #[arg(long, global = true, default_value = "http://127.0.0.1:7331")]
    pub base_url: String,

    /// HTTP timeout in seconds.
    #[arg(long, global = true, default_value_t = 30)]
    pub timeout: u64,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Daemon health probe (unauthenticated).
    Health,

    /// Transcription sessions and their segments.
    Conversations {
        #[command(subcommand)]
        action: commands::conversations::Action,
    },

    /// Extracted memories (long-term facts).
    Memories {
        #[command(subcommand)]
        action: commands::memories::Action,
    },

    /// Action items / todos pulled from conversations and screen activity.
    #[command(name = "action-items")]
    ActionItems {
        #[command(subcommand)]
        action: commands::action_items::Action,
    },

    /// Known people in the local contact graph.
    People {
        #[command(subcommand)]
        action: commands::people::Action,
    },

    /// Unified full-text search (OCR / audio / visual).
    Search(commands::search::CmdArgs),

    /// Daily activity rollup (conversations, memories, action items, screenshots).
    Scores(commands::scores::CmdArgs),
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match dispatch(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            // Codes are i32 internally; everything we use fits in u8.
            ExitCode::from(e.exit_code() as u8)
        }
    }
}

fn dispatch(cli: Cli) -> Result<(), CliError> {
    let opts = cli.global;
    match cli.command {
        Command::Health => commands::health::run(&opts),
        Command::Conversations { action } => commands::conversations::run(&opts, action),
        Command::Memories { action } => commands::memories::run(&opts, action),
        Command::ActionItems { action } => commands::action_items::run(&opts, action),
        Command::People { action } => commands::people::run(&opts, action),
        Command::Search(args) => commands::search::run(&opts, args),
        Command::Scores(args) => commands::scores::run(&opts, args),
    }
}
