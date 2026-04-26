//! `recall search` — unified FTS / LIKE search across OCR, audio, visual.

use clap::Args;

use crate::{auth, client::Client, error::CliError, output, GlobalOpts};

#[derive(Args, Debug)]
pub struct CmdArgs {
    /// Search query.
    pub query: String,

    /// Which corpus to search.
    #[arg(
        long = "type",
        value_name = "KIND",
        value_parser = ["ocr", "audio", "visual", "both"],
        default_value = "both",
    )]
    pub kind: String,

    /// Filter to a specific app name (exact match on `appName`).
    #[arg(long)]
    pub app: Option<String>,

    /// ISO 8601 inclusive lower bound on the result timestamp.
    #[arg(long, value_name = "DATE")]
    pub since: Option<String>,

    /// ISO 8601 exclusive upper bound on the result timestamp.
    #[arg(long, value_name = "DATE")]
    pub until: Option<String>,

    /// Max results per corpus (independent for `--type both`).
    #[arg(long, default_value_t = 50)]
    pub limit: i64,
}

pub fn run(opts: &GlobalOpts, args: CmdArgs) -> Result<(), CliError> {
    let token = auth::require_token(opts)?;
    let client = Client::new(opts.base_url.clone(), Some(token), opts.timeout)?;

    let mut q: Vec<(&str, String)> = vec![
        ("q", args.query),
        ("content_type", args.kind),
        ("limit", args.limit.to_string()),
    ];
    if let Some(a) = args.app {
        q.push(("app", a));
    }
    if let Some(s) = args.since {
        q.push(("start", s));
    }
    if let Some(e) = args.until {
        q.push(("end", e));
    }

    let v = client.get("/v1/search", &q)?;
    output::emit(opts.json, &v, render);
    Ok(())
}

fn render(v: &serde_json::Value) {
    let count = |k: &str| {
        v.get(k)
            .and_then(|x| x.as_array())
            .map(|a| a.len())
            .unwrap_or(0)
    };
    let q = output::s(v, "query");
    println!(
        "query={q:?}  ocr={}  audio={}  visual={}",
        count("ocr_hits"),
        count("audio_hits"),
        count("visual_hits"),
    );

    for h in v
        .get("ocr_hits")
        .and_then(|x| x.as_array())
        .into_iter()
        .flatten()
    {
        println!(
            "  ocr     {}  {:<20}  {}",
            output::s(h, "timestamp"),
            output::truncate(output::s(h, "app_name"), 20),
            output::truncate(output::s(h, "snippet"), 80),
        );
    }
    for h in v
        .get("audio_hits")
        .and_then(|x| x.as_array())
        .into_iter()
        .flatten()
    {
        println!(
            "  audio   sess={} sp{} {:>6.2}s  {}",
            output::i(h, "session_id"),
            output::i(h, "speaker"),
            output::f(h, "start_time"),
            output::truncate(output::s(h, "text"), 80),
        );
    }
    for h in v
        .get("visual_hits")
        .and_then(|x| x.as_array())
        .into_iter()
        .flatten()
    {
        println!(
            "  visual  {}  {:<20}  {}",
            output::s(h, "sampled_at"),
            output::truncate(output::s(h, "app_name"), 20),
            output::truncate(output::s(h, "snippet"), 80),
        );
    }
}
