//! `recall memories` — list / show extracted memories.

use clap::Subcommand;

use crate::{auth, client::Client, error::CliError, output, GlobalOpts};

#[derive(Subcommand, Debug)]
pub enum Action {
    /// List memories, newest first.
    List {
        #[arg(long, default_value_t = 50)]
        limit: i64,
        /// Filter to a specific category (exact match).
        #[arg(long, value_name = "CAT")]
        category: Option<String>,
    },
    /// Show a single memory.
    Show {
        /// Memory row id.
        id: i64,
    },
}

pub fn run(opts: &GlobalOpts, action: Action) -> Result<(), CliError> {
    let token = auth::require_token(opts)?;
    let client = Client::new(opts.base_url.clone(), Some(token), opts.timeout)?;

    match action {
        Action::List { limit, category } => {
            let mut q: Vec<(&str, String)> = vec![("limit", limit.to_string())];
            if let Some(c) = category {
                q.push(("category", c));
            }
            let v = client.get("/v3/memories", &q)?;
            output::emit(opts.json, &v, render_list);
        }
        Action::Show { id } => {
            let v = client.get(&format!("/v3/memories/{id}"), &[])?;
            output::emit(opts.json, &v, render_show);
        }
    }
    Ok(())
}

fn render_list(v: &serde_json::Value) {
    println!("{:>6}  {:<14}  {:<60}", "ID", "CATEGORY", "CONTENT");
    for r in v
        .get("memories")
        .and_then(|x| x.as_array())
        .into_iter()
        .flatten()
    {
        println!(
            "{:>6}  {:<14}  {:<60}",
            output::i(r, "id"),
            output::truncate(output::s(r, "category"), 14),
            output::truncate(output::s(r, "content"), 60),
        );
    }
}

fn render_show(v: &serde_json::Value) {
    println!("id:          {}", output::i(v, "id"));
    println!("category:    {}", output::s(v, "category"));
    println!("source:      {}", output::s(v, "source"));
    println!("created_at:  {}", output::s(v, "created_at"));
    println!("updated_at:  {}", output::s(v, "updated_at"));
    println!("content:");
    println!("  {}", output::s(v, "content"));
}
