//! `recall people` — list / show known people.

use clap::Subcommand;

use crate::{auth, client::Client, error::CliError, output, GlobalOpts};

#[derive(Subcommand, Debug)]
pub enum Action {
    /// List all people, alphabetical.
    List,
    /// Show one person by id.
    Show {
        /// Person id (text column).
        id: String,
    },
}

pub fn run(opts: &GlobalOpts, action: Action) -> Result<(), CliError> {
    let token = auth::require_token(opts)?;
    let client = Client::new(opts.base_url.clone(), Some(token), opts.timeout)?;

    match action {
        Action::List => {
            let v = client.get("/v1/people", &[])?;
            output::emit(opts.json, &v, render_list);
        }
        Action::Show { id } => {
            let v = client.get(&format!("/v1/people/{id}"), &[])?;
            output::emit(opts.json, &v, render_show);
        }
    }
    Ok(())
}

fn render_list(v: &serde_json::Value) {
    println!("{:<36}  {:<6}  {:<30}", "ID", "EMOJI", "DISPLAY_NAME");
    for r in v
        .get("people")
        .and_then(|x| x.as_array())
        .into_iter()
        .flatten()
    {
        println!(
            "{:<36}  {:<6}  {:<30}",
            output::truncate(output::s(r, "id"), 36),
            output::s(r, "default_emoji"),
            output::truncate(output::s(r, "display_name"), 30),
        );
    }
}

fn render_show(v: &serde_json::Value) {
    println!("id:            {}", output::s(v, "id"));
    println!("display_name:  {}", output::s(v, "display_name"));
    println!("default_emoji: {}", output::s(v, "default_emoji"));
    println!("created_at:    {}", output::s(v, "created_at"));
    println!("updated_at:    {}", output::s(v, "updated_at"));
}
