# AGENTS.md — Infinite Recall

> **For coding agents (Claude Code, Cursor, Codex, etc.).**
> Human contributors: see [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

---

## What this codebase is

Infinite Recall is a local-first macOS app that continuously captures screen and
audio, transcribes everything on-device with WhisperKit, and indexes activity into
a private SQLite database. A Rust daemon (`infinite-recall-api`) exposes that
database over a local REST API on `127.0.0.1:7331`. A companion CLI (`recall`)
wraps the API so agents can query — and write — activity data without raw HTTP.
All data stays on-device: no cloud, no telemetry, no auth beyond a local bearer
token auto-generated at first run.

---

## The `recall` CLI

`recall` is the correct way for an agent to interact with Infinite Recall data.
Prefer it over raw `curl` — it handles authentication, formats human output for
terminals, and emits clean JSON for machines.

**Always pass `--json`** in scripts and agent contexts. Without it, output is
human-readable tables whose format may change across versions.

```bash
# Confirm the daemon is alive before doing anything else
recall health --json
```

The daemon runs as a launchd user agent (`com.infiniterecall.api`) and starts
automatically at login after the first `./scripts/setup-api-server.sh` run.

### Global flags

| Flag | Default | Description |
|------|---------|-------------|
| `--json` | off | Emit raw JSON instead of human-readable output |
| `--base-url URL` | `http://127.0.0.1:7331` | Override daemon address |
| `--token-path PATH` | `~/Library/Application Support/InfiniteRecall/api-token.txt` | Override token file |
| `--timeout SECS` | 10 | Request timeout |

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Runtime error (network failure, parse error) |
| 2 | Usage error (bad flags — printed by clap) |
| 3 | Daemon unreachable (connection refused) |
| 4 | Auth failed (HTTP 401) |
| 5 | Not found (HTTP 404) |

---

## Choosing a command

```
What do I need?
│
├── Something that happened / what was on screen? ──→  recall search <q> --json
│
├── An audio conversation (transcript)? ────────────→  recall conversations list --json
│                                                       recall conversations show <id> --json
│
├── A stable fact the app extracted about me? ───────→  recall memories list --json
│                                                        recall memories show <id> --json
│
├── Action items / todos? ───────────────────────────→  recall action-items list --json
│   (also: create / update / complete / delete)          recall action-items create ...
│
├── Who was in a conversation? ──────────────────────→  recall people list --json
│                                                        recall people show <id> --json
│
└── How much activity happened on a day? ────────────→  recall scores --date YYYY-MM-DD --json
```

**Rule of thumb:**
- Searching for an event, incident, or "what was I looking at" → `search` or `conversations`
- Looking for a durable extracted fact (preferences, names, decisions) → `memories`
- Managing todos → `action-items`
- Daily summary / volume check → `scores`

---

## Command reference

Run `recall <subcommand> --help` for the authoritative flag list — examples
below were captured against a live daemon.

---

### `recall health`

Check whether the daemon is alive and the database is readable. No auth required.

```bash
recall health --json
```

Example response:
```json
{
  "db_readable": true,
  "pending_work": {
    "claimed": 0,
    "dead": 0,
    "failed": 0,
    "migrated": true,
    "oldest_queued_seconds": null,
    "queued": 0
  },
  "status": "ok"
}
```

`status` is `"ok"` or `"degraded"`. If `db_readable` is `false`, the SQLite file
is not accessible — typically because the Swift app has never run its migrations.

---

### `recall conversations`

List transcription sessions (audio recordings), newest first.

```bash
recall conversations list --json
recall conversations list --limit 10 --since 2025-04-24 --json
recall conversations list --since 2025-04-01 --until 2025-04-30 --json
```

Flags: `--limit N` (default 50, max 500), `--since DATE`, `--until DATE` (ISO 8601 or YYYY-MM-DD).

Example response (abbreviated):
```json
{
  "conversations": [
    {
      "created_at": "2026-04-26 11:12:15.213",
      "finished_at": null,
      "id": 82,
      "language": "multi",
      "source": "desktop",
      "started_at": "2026-04-26 11:12:15.213",
      "status": "recording",
      "timezone": "America/New_York",
      "updated_at": "2026-04-26 11:12:15.213"
    }
  ],
  "limit": 10,
  "offset": 0
}
```

`finished_at` is `null` while a session is still active. `status` is one of
`recording`, `processing`, `completed`.

Fetch a single conversation with its full transcript:

```bash
recall conversations show 42 --json
```

Response includes `"conversation": {...}` and `"transcript_segments": [{"speaker_id", "text", "start", "end", "order"}, ...]`.

---

### `recall memories`

List memories extracted from conversations and screen activity, newest first.
Soft-deleted rows are excluded.

```bash
recall memories list --json
recall memories list --limit 20 --json
recall memories list --category preference --json
```

Flags: `--limit N` (default 50, max 500), `--category CAT` (exact match).

Example response (abbreviated):
```json
{
  "limit": 20,
  "memories": [
    {
      "backend_id": null,
      "category": "system",
      "confidence": null,
      "content": "Focused on iTerm2: prod deploy",
      "conversation_id": null,
      "created_at": "2026-04-26 11:40:08.170",
      "id": 47,
      "manually_added": false,
      "reviewed": false,
      "source": "desktop",
      "source_app": "iTerm2",
      "tags": "[\"focus\",\"focused\",\"app:iTerm2\"]",
      "updated_at": "2026-04-26 11:40:08.170",
      "visibility": "private"
    }
  ],
  "offset": 0
}
```

`tags` is a JSON-encoded string (parse twice). `confidence` is null for
auto-extracted system memories; populated for LLM-derived memories.

Fetch one memory:

```bash
recall memories show 7 --json
```

---

### `recall action-items`

List action items (todos), newest first. Soft-deleted rows excluded.

```bash
recall action-items list --json              # open items only (default)
recall action-items list --completed --json  # completed items only
recall action-items list --limit 25 --json
```

Example response (abbreviated):
```json
{
  "action_items": [
    {
      "id": 3,
      "description": "File expense report for April conference",
      "completed": false,
      "priority": "high",
      "due_at": null,
      "conversation_id": "42"
    }
  ],
  "limit": 50,
  "offset": 0
}
```

**Action items are the only resource the CLI can mutate.** All write commands
return `{"action_item": {...}}` on success.

```bash
# Create
recall action-items create --description "Follow up with Alice re: budget" --json
recall action-items create --description "Send invoice" --due-at 2025-05-01 --priority high --json
recall action-items create --description "Review PR" --conversation-id 42 --json

# Update (patch — only supplied fields change)
recall action-items update 3 --description "File April expense report by Friday" --json
recall action-items update 3 --due-at 2025-05-02 --json

# Mark done / reopen
recall action-items complete   3 --json
recall action-items uncomplete 3 --json

# Soft-delete (item disappears from default list; not permanently destroyed)
recall action-items delete 3 --json
```

---

### `recall people`

List speaker profiles, alphabetically by display name. No pagination (table is
typically small).

```bash
recall people list --json
```

Example response:
```json
{
  "people": [
    {
      "id": "person-uuid-or-rowid",
      "display_name": "Alice",
      "default_emoji": "👩‍💻",
      "created_at": "2025-03-10T08:00:00.000"
    }
  ]
}
```

Fetch one person by their text ID:

```bash
recall people show person-uuid-or-rowid --json
```

---

### `recall search`

Full-text search across OCR screenshots, audio transcripts, and visual activity
summaries. Returns hits from all three corpora by default.

```bash
recall search "quarterly budget" --json
recall search "quarterly budget" --type ocr --json          # screenshots only
recall search "standup" --type audio --since 2025-04-24 --json
recall search "GitHub PR" --type visual --json              # visual activity only
recall search "deploy" --app Xcode --limit 20 --json
```

Flags:
- `--type ocr|audio|visual|both` (default: `both`)
- `--app NAME` — filter to a specific app (exact match on app name)
- `--since DATE`, `--until DATE` — ISO 8601 time bounds
- `--limit N` — max results per corpus (default 50, max 500; applied independently per corpus when `--type both`)

Example response (abbreviated, `--type both`):
```json
{
  "query": "quarterly budget",
  "content_type": "both",
  "ocr_hits": [
    {
      "screenshot_id": 5012,
      "timestamp": "2025-04-24T11:33:45.000",
      "app_name": "Numbers",
      "window_title": "Q1 Budget.numbers",
      "snippet": "…<b>quarterly budget</b> projections for…"
    }
  ],
  "audio_hits": [
    {
      "session_id": 42,
      "segment_order": 3,
      "speaker": 1,
      "start_time": 18.4,
      "end_time": 22.1,
      "text": "Let's go over the quarterly budget."
    }
  ],
  "visual_hits": []
}
```

> `visual_hits` will be empty until the VLM sidecar has processed at least one
> frame. See [Troubleshooting](#troubleshooting) if visual search is unexpectedly
> empty.

---

### `recall scores`

Daily activity rollup. Defaults to today (UTC).

```bash
recall scores --json
recall scores --date 2025-04-24 --json
```

Example response:
```json
{
  "date": "2025-04-24",
  "counts": {
    "screenshots": 1420,
    "conversations": 3,
    "memories": 12,
    "action_items": 5,
    "action_items_completed": 2
  }
}
```

---

## What `recall` does NOT do

If you need any of the following, **stop and tell the user** — do not attempt
workarounds.

| Capability | Status |
|-----------|--------|
| Vector / semantic search | Not implemented. FTS5 + LIKE only. |
| Raw SQL passthrough | No `execute_sql` command. Use the structured subcommands. |
| Conversation mutations | Conversations are append-only; the Swift app is the sole writer. |
| Memory mutations | Memories are auto-extracted. No create / edit / delete via CLI. |
| People mutations | Speaker profiles are managed by the Swift app only. |
| Firestore / cloud sync | Infinite Recall is local-only. No sync endpoint exists. |
| Streaming / live tail | All commands are request/response. No event-stream mode. |
| Browser automation | Out of scope for this CLI. |

---

## Troubleshooting

**Start here:**

```bash
recall health --json
```

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `exit 3` / "connection refused" | Daemon not running | `launchctl kickstart gui/$(id -u)/com.infiniterecall.api` |
| `exit 4` / auth error | Wrong or missing token | Open Infinite Recall → Settings → MCP API → Copy token; or verify `~/Library/Application Support/InfiniteRecall/api-token.txt` exists (mode 0600) |
| `exit 5` / not found | Bad ID | Verify the ID with a `list` command first |
| `recall: command not found` | Binary not on PATH | Re-run `./scripts/setup-api-server.sh`; it symlinks `recall` to `/usr/local/bin/recall` |
| Daemon starts then crashes | Binary missing or PATH issue | Re-run `./scripts/setup-api-server.sh` |
| `visual_hits` always empty | VLM sidecar not running, or `isVLMAvailable()` stub | Run `./scripts/setup-vlm-server.sh`; known stub issue tracked in the plan |

**Daemon logs:**

```bash
tail -f /tmp/infinite-recall-api.err.log
tail -f /tmp/infinite-recall-api.out.log
```

**Manual launchd control:**

```bash
# Stop
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.infiniterecall.api.plist

# Start
launchctl kickstart gui/$(id -u)/com.infiniterecall.api

# Legacy (older macOS)
launchctl unload  ~/Library/LaunchAgents/com.infiniterecall.api.plist
launchctl load    ~/Library/LaunchAgents/com.infiniterecall.api.plist
```

---

*For the full HTTP API surface (useful when adding new CLI commands), see
[Backend-Rust/API.md](Backend-Rust/API.md).*
