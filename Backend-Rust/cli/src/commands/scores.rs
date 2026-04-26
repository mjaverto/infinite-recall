//! `recall scores` — daily activity rollup.

use clap::Args;

use crate::{auth, client::Client, error::CliError, output, GlobalOpts};

#[derive(Args, Debug)]
pub struct CmdArgs {
    /// `YYYY-MM-DD`. Defaults to today (UTC) on the server.
    #[arg(long, value_name = "YYYY-MM-DD")]
    pub date: Option<String>,
}

pub fn run(opts: &GlobalOpts, args: CmdArgs) -> Result<(), CliError> {
    let token = auth::require_token(opts)?;
    let client = Client::new(opts.base_url.clone(), Some(token), opts.timeout)?;

    let mut q: Vec<(&str, String)> = vec![];
    if let Some(d) = args.date {
        q.push(("date", d));
    }

    let v = client.get("/v1/scores", &q)?;
    output::emit(opts.json, &v, |v| {
        println!("date:                   {}", output::s(v, "date"));
        if let Some(c) = v.get("counts") {
            println!("screenshots:            {}", output::i(c, "screenshots"));
            println!("conversations:          {}", output::i(c, "conversations"));
            println!("memories:               {}", output::i(c, "memories"));
            println!("action_items:           {}", output::i(c, "action_items"));
            println!(
                "action_items_completed: {}",
                output::i(c, "action_items_completed")
            );
        }
    });
    Ok(())
}
