//! `recall action-items` — list (B-reads) plus mutations (B-writes).
//!
//! Mutations all wrap the corresponding routes added in Task #2 (A-2):
//! - `create`     → `POST   /v1/action-items`
//! - `update`     → `PATCH  /v1/action-items/:id`
//! - `complete`   → `POST   /v1/action-items/:id/complete` `{completed:true}`
//! - `uncomplete` → `POST   /v1/action-items/:id/complete` `{completed:false}`
//! - `delete`     → `DELETE /v1/action-items/:id`
//!
//! All mutation responses share the `{action_item: {...}}` envelope, so we
//! render them through one shared helper.

use clap::Subcommand;
use serde_json::{json, Map, Value};

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

    /// Create a new action item. Returns the created row (`source="cli"`).
    Create {
        /// Action item text. Whitespace-only descriptions are rejected.
        #[arg(long)]
        description: String,

        /// ISO 8601 due timestamp (e.g. `2025-04-30T17:00:00Z`).
        #[arg(long, value_name = "DATE")]
        due_at: Option<String>,

        /// Priority label (`high`, `medium`, `low`, or any string).
        #[arg(long, value_name = "LABEL")]
        priority: Option<String>,

        /// Linked `transcription_sessions.id`, as a string.
        #[arg(long, value_name = "ID")]
        conversation_id: Option<String>,

        /// App name for screen-derived items.
        #[arg(long, value_name = "APP")]
        source_app: Option<String>,
    },

    /// Update fields on an existing action item. Only flags you pass are sent.
    Update {
        /// Action item id.
        id: i64,

        #[arg(long)]
        description: Option<String>,

        #[arg(long, value_name = "DATE")]
        due_at: Option<String>,

        #[arg(long, value_name = "LABEL")]
        priority: Option<String>,

        #[arg(long, value_name = "ID")]
        conversation_id: Option<String>,

        #[arg(long, value_name = "APP")]
        source_app: Option<String>,

        #[arg(long, value_name = "CAT")]
        category: Option<String>,
    },

    /// Mark an action item completed.
    Complete {
        /// Action item id.
        id: i64,
    },

    /// Mark an action item not completed.
    Uncomplete {
        /// Action item id.
        id: i64,
    },

    /// Soft-delete an action item. Returns the pre-delete snapshot.
    Delete {
        /// Action item id.
        id: i64,
    },
}

pub fn run(opts: &GlobalOpts, action: Action) -> Result<(), CliError> {
    let token = auth::require_token(opts)?;
    let client = Client::new(opts.base_url.clone(), Some(token), opts.timeout)?;

    match action {
        Action::List { completed, limit } => list(&client, opts, completed, limit),
        Action::Create {
            description,
            due_at,
            priority,
            conversation_id,
            source_app,
        } => {
            let body = build_create_body(description, due_at, priority, conversation_id, source_app);
            let v = client.post("/v1/action-items", &body)?;
            emit_one(opts, &v);
            Ok(())
        }
        Action::Update {
            id,
            description,
            due_at,
            priority,
            conversation_id,
            source_app,
            category,
        } => {
            let body = build_update_body(
                description,
                due_at,
                priority,
                conversation_id,
                source_app,
                category,
            )?;
            let v = client.patch(&format!("/v1/action-items/{id}"), &body)?;
            emit_one(opts, &v);
            Ok(())
        }
        Action::Complete { id } => set_completed(&client, opts, id, true),
        Action::Uncomplete { id } => set_completed(&client, opts, id, false),
        Action::Delete { id } => {
            let v = client.delete(&format!("/v1/action-items/{id}"))?;
            emit_one(opts, &v);
            Ok(())
        }
    }
}

fn list(
    client: &Client,
    opts: &GlobalOpts,
    completed: Option<bool>,
    limit: i64,
) -> Result<(), CliError> {
    let mut q: Vec<(&str, String)> = vec![("limit", limit.to_string())];
    if let Some(c) = completed {
        q.push(("completed", c.to_string()));
    }
    let v = client.get("/v1/action-items", &q)?;
    output::emit(opts.json, &v, render_list);
    Ok(())
}

fn set_completed(
    client: &Client,
    opts: &GlobalOpts,
    id: i64,
    completed: bool,
) -> Result<(), CliError> {
    let body = json!({ "completed": completed });
    let v = client.post(&format!("/v1/action-items/{id}/complete"), &body)?;
    emit_one(opts, &v);
    Ok(())
}

fn build_create_body(
    description: String,
    due_at: Option<String>,
    priority: Option<String>,
    conversation_id: Option<String>,
    source_app: Option<String>,
) -> Value {
    let mut m = Map::new();
    m.insert("description".into(), Value::String(description));
    if let Some(v) = due_at {
        m.insert("due_at".into(), Value::String(v));
    }
    if let Some(v) = priority {
        m.insert("priority".into(), Value::String(v));
    }
    if let Some(v) = conversation_id {
        m.insert("conversation_id".into(), Value::String(v));
    }
    if let Some(v) = source_app {
        m.insert("source_app".into(), Value::String(v));
    }
    Value::Object(m)
}

fn build_update_body(
    description: Option<String>,
    due_at: Option<String>,
    priority: Option<String>,
    conversation_id: Option<String>,
    source_app: Option<String>,
    category: Option<String>,
) -> Result<Value, CliError> {
    let mut m = Map::new();
    let pairs: [(&str, Option<String>); 6] = [
        ("description", description),
        ("due_at", due_at),
        ("priority", priority),
        ("conversation_id", conversation_id),
        ("source_app", source_app),
        ("category", category),
    ];
    for (k, v) in pairs {
        if let Some(s) = v {
            m.insert(k.to_string(), Value::String(s));
        }
    }
    if m.is_empty() {
        return Err(CliError::Runtime(
            "update needs at least one field flag (e.g. --description, --priority)".into(),
        ));
    }
    Ok(Value::Object(m))
}

fn emit_one(opts: &GlobalOpts, v: &Value) {
    output::emit(opts.json, v, |v| {
        let item = v.get("action_item").unwrap_or(v);
        let mark = if output::b(item, "completed") { "[x]" } else { "[ ]" };
        println!(
            "{}  id={}  priority={}  description={}",
            mark,
            output::i(item, "id"),
            output::s(item, "priority"),
            output::s(item, "description"),
        );
    });
}

fn render_list(v: &Value) {
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
