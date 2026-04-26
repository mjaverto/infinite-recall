//! `recall conversations` — list / show transcription sessions.

use clap::Subcommand;

use crate::{auth, client::Client, error::CliError, output, GlobalOpts};

#[derive(Subcommand, Debug)]
pub enum Action {
    /// List conversations, newest first.
    List {
        #[arg(long, default_value_t = 50)]
        limit: i64,
        /// ISO 8601 inclusive lower bound on `started_at` (e.g. `2025-04-24T00:00:00`).
        #[arg(long, value_name = "DATE")]
        since: Option<String>,
        /// ISO 8601 exclusive upper bound on `started_at`.
        #[arg(long, value_name = "DATE")]
        until: Option<String>,
    },
    /// Show one conversation with all transcript segments.
    Show {
        /// Conversation row id.
        id: i64,
    },
}

pub fn run(opts: &GlobalOpts, action: Action) -> Result<(), CliError> {
    let token = auth::require_token(opts)?;
    let client = Client::new(opts.base_url.clone(), Some(token), opts.timeout)?;

    match action {
        Action::List { limit, since, until } => {
            let mut q: Vec<(&str, String)> = vec![("limit", limit.to_string())];
            if let Some(s) = since {
                q.push(("start_date", s));
            }
            if let Some(e) = until {
                q.push(("end_date", e));
            }
            let v = client.get("/v1/conversations", &q)?;
            output::emit(opts.json, &v, render_list);
        }
        Action::Show { id } => {
            let v = client.get(&format!("/v1/conversations/{id}"), &[])?;
            output::emit(opts.json, &v, render_show);
        }
    }
    Ok(())
}

fn render_list(v: &serde_json::Value) {
    println!(
        "{:>6}  {:<24}  {:<10}  {:<8}  {:<8}",
        "ID", "STARTED_AT", "STATUS", "SOURCE", "LANG"
    );
    for r in v
        .get("conversations")
        .and_then(|x| x.as_array())
        .into_iter()
        .flatten()
    {
        println!(
            "{:>6}  {:<24}  {:<10}  {:<8}  {:<8}",
            output::i(r, "id"),
            output::truncate(output::s(r, "started_at"), 24),
            output::truncate(output::s(r, "status"), 10),
            output::truncate(output::s(r, "source"), 8),
            output::truncate(output::s(r, "language"), 8),
        );
    }
}

fn render_show(v: &serde_json::Value) {
    if let Some(c) = v.get("conversation") {
        println!("conversation:");
        println!("  id:          {}", output::i(c, "id"));
        println!("  started_at:  {}", output::s(c, "started_at"));
        println!("  finished_at: {}", output::s(c, "finished_at"));
        println!("  status:      {}", output::s(c, "status"));
        println!("  source:      {}", output::s(c, "source"));
        println!("  language:    {}", output::s(c, "language"));
        println!("  timezone:    {}", output::s(c, "timezone"));
    }
    let segs = v.get("transcript_segments").and_then(|x| x.as_array());
    let count = segs.map(|s| s.len()).unwrap_or(0);
    println!("transcript_segments ({count}):");
    for s in segs.into_iter().flatten() {
        println!(
            "  [{:>7.2}] sp{}: {}",
            output::f(s, "start"),
            output::i(s, "speaker_id"),
            output::truncate(output::s(s, "text"), 100),
        );
    }
}
