//! `recall health` — public daemon probe (no auth required).
//!
//! Tolerant of a missing token file: we still set `--token-path` if the user
//! passed one (so a wrong path fails fast with exit 4), but otherwise call
//! the endpoint anonymously. This matches the daemon's public-route policy.

use crate::{auth, client::Client, error::CliError, output, GlobalOpts};

pub fn run(opts: &GlobalOpts) -> Result<(), CliError> {
    let token = auth::load_token(opts)?;
    let client = Client::new(opts.base_url.clone(), token, opts.timeout)?;
    let v = client.get("/v1/health", &[])?;

    output::emit(opts.json, &v, |v| {
        println!("status:       {}", output::s(v, "status"));
        println!("db_readable:  {}", output::b(v, "db_readable"));
        if let Some(pw) = v.get("pending_work") {
            println!(
                "pending_work: queued={} claimed={} failed={} dead={} migrated={}",
                output::i(pw, "queued"),
                output::i(pw, "claimed"),
                output::i(pw, "failed"),
                output::i(pw, "dead"),
                output::b(pw, "migrated"),
            );
        }
    });
    Ok(())
}
