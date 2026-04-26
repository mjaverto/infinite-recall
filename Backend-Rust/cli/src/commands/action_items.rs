//! `recall action-items` — list (B-reads) and, in B-writes, mutate todos.
//!
//! Only `list` ships in B-reads. The mutation variants land in Task #4 and
//! plug into this same `Action` enum so the command surface stays a single
//! `recall action-items <verb>` namespace.

use clap::Subcommand;

use crate::{auth, client::Client, error::CliError, output, GlobalOpts};

#[derive(Subcommand, Debug)]
pub enum Action {
    /// List action items, newest first.
    List {
        /// Show only completed items. Pass `--completed=false` for open only;
        /// omit entirely for all.
        #[arg(
            long,
            num_args = 0..=1,
            default_missing_value = "true",
            value_name = "BOOL",
        )]
        completed: Option<bool>,

        #[arg(long, default_value_t = 50)]
        limit: i64,
    },
}

pub fn run(opts: &GlobalOpts, action: Action) -> Result<(), CliError> {
    let token = auth::require_token(opts)?;
    let client = Client::new(opts.base_url.clone(), Some(token), opts.timeout)?;

    match action {
        Action::List { completed, limit } => {
            let mut q: Vec<(&str, String)> = vec![("limit", limit.to_string())];
            if let Some(c) = completed {
                q.push(("completed", c.to_string()));
            }
            let v = client.get("/v1/action-items", &q)?;
            output::emit(opts.json, &v, render_list);
        }
    }
    Ok(())
}

fn render_list(v: &serde_json::Value) {
    println!(
        "{:>6}  {:<3}  {:<10}  {:<60}",
        "ID", "DON", "PRIORITY", "DESCRIPTION"
    );
    for r in v
        .get("action_items")
        .and_then(|x| x.as_array())
        .into_iter()
        .flatten()
    {
        let mark = if output::b(r, "completed") { "[x]" } else { "[ ]" };
        println!(
            "{:>6}  {:<3}  {:<10}  {:<60}",
            output::i(r, "id"),
            mark,
            output::truncate(output::s(r, "priority"), 10),
            output::truncate(output::s(r, "description"), 60),
        );
    }
}
