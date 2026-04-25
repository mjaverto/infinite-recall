# Infinite Recall — Backend-Rust HTTP API

Version: `infinite-recall-api 0.1.0` | Base URL: `http://127.0.0.1:7331` | Shape: `omi-local-v1`

---

## Overview

The Backend-Rust daemon is a thin **read-only** axum HTTP server that exposes the
Swift app's GRDB SQLite database over a local REST API. It does not own any data;
the Swift app is the sole writer. The Rust process opens the SQLite file in
read-only mode and serves JSON on `127.0.0.1:7331`.

The database lives at:

```
~/Library/Application Support/Omi/users/anonymous/omi.db
```

The API surface is intentionally shaped after the upstream Omi cloud API so that
MCP clients (Claude Code, Cursor, custom scripts) can talk to it with minimal
adaptation. **All data is on-device. No outbound network requests are made.**

Key tables the API reads:

| Table | API endpoint(s) |
|---|---|
| `transcription_sessions` | `/v1/conversations` |
| `transcription_segments` | `/v1/conversations/:id` (nested) |
| `memories` | `/v3/memories`, `/v3/memories/:id` |
| `action_items` | `/v1/action-items` |
| `people` | `/v1/people`, `/v1/people/:id` |
| `screenshots` + `screenshots_fts` | `/v1/search?content_type=ocr` |
| `visual_activity` + `visual_activity_fts` | `/v1/search?content_type=visual` |
| `pending_work` | `/v1/health` (pending_work block) |

SQLite schema ground truth: `Desktop/Sources/Rewind/Core/RewindDatabase.swift`
(GRDB migrations). The Rust code reads whatever columns exist; see each handler
for exact column names.

---

## Starting the Server

Run once to build the binary and register the launchd agent:

```bash
./scripts/setup-api-server.sh
```

This builds `Backend-Rust/` with `cargo build --release`, installs the binary to
`/usr/local/bin/infinite-recall-api`, copies the plist to
`~/Library/LaunchAgents/com.infiniterecall.api.plist`, and loads the agent.

For non-interactive / in-app install (no sudo, binary lands in
`~/Library/Application Support/InfiniteRecall/bin/`):

```bash
./scripts/setup-api-server.sh --yes
```

Logs:

```
/tmp/infinite-recall-api.out.log
/tmp/infinite-recall-api.err.log
```

Manual launchd control:

```bash
launchctl unload  ~/Library/LaunchAgents/com.infiniterecall.api.plist
launchctl load    ~/Library/LaunchAgents/com.infiniterecall.api.plist
```

The plist sets `KeepAlive = true` and `RunAtLoad = true`, so the daemon starts
automatically at login after the first `load`.

---

## Authentication

### Token location

```
~/Library/Application Support/InfiniteRecall/api-token.txt  (mode 0600)
```

The token is a 64-character hex string (32 random bytes). It is generated
automatically on first run by the daemon. The Swift app's MCP API card reads the
same file and can copy it to the clipboard.

Token path can be overridden via the environment variable
`INFINITE_RECALL_TOKEN_PATH`.

### How to send it

All authed routes require:

```
Authorization: Bearer <token>
```

### Shell helper

```bash
TOKEN=$(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7331/v1/conversations?limit=5
```

Or inline:

```bash
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)" \
     http://127.0.0.1:7331/v1/health
```

### 401 response

Missing or wrong token returns HTTP 401 with no body from the middleware. The
auth check uses constant-time comparison to prevent timing attacks.

---

## Common Error Shapes

All errors return JSON:

```json
{ "error": "<code>", "message": "<human string>" }
```

| HTTP Status | `error` field | Cause |
|---|---|---|
| 400 | `bad_request` | Invalid query parameter (e.g., malformed date, empty `q`) |
| 401 | — | Missing or incorrect `Authorization: Bearer` header (body may be empty) |
| 404 | `not_found` | Row with the given `:id` does not exist |
| 500 | `internal` | SQLite error, I/O failure, or unexpected panic |

Example 404:

```json
{ "error": "not_found", "message": "not found" }
```

Example 400 (bad date on `/v1/scores`):

```json
{ "error": "bad_request", "message": "bad request: date must be YYYY-MM-DD" }
```

---

## Rate Limits and Concurrency

None enforced. The server is local-only and single-user. The SQLite connection
pool is managed internally; requests that hit the database run on a blocking
thread pool to avoid stalling the async executor. Concurrent reads are safe
because the database is opened read-only.

---

## Public Routes (no auth required)

Public routes are intentionally unauthenticated so that launchd health checks and
monitors can poll without a token.

---

## GET /v1/health

Returns the API and database status plus a summary of the `pending_work` queue.

### Response

```json
{
  "status": "ok",
  "db_readable": true,
  "pending_work": {
    "queued": 3,
    "claimed": 1,
    "failed": 0,
    "dead": 0,
    "oldest_queued_seconds": 47.2,
    "migrated": true
  }
}
```

| Field | Type | Description |
|---|---|---|
| `status` | `"ok"` \| `"degraded"` | `"degraded"` when the DB probe query fails |
| `db_readable` | bool | Whether `SELECT 1` succeeded |
| `pending_work.queued` | integer | Rows with `status = 'queued'` |
| `pending_work.claimed` | integer | Rows with `status = 'claimed'` (in-flight in the Swift app) |
| `pending_work.failed` | integer | Rows with `status = 'failed'` (will be retried) |
| `pending_work.dead` | integer | Rows with `status = 'dead'` (exhausted retries) |
| `pending_work.oldest_queued_seconds` | float \| null | Age in seconds of the oldest queued row; null if queue is empty |
| `pending_work.migrated` | bool | `false` if the `pending_work` table does not yet exist in the DB (app has not run the migration yet); all counts are 0 in that case |

The `pending_work` block is cached for 5 seconds to avoid hammering the DB on
rapid health polls.

When `migrated` is `false`, the Swift app has not yet executed the GRDB migration
that creates the `pending_work` table. The API is still functional; only the
queue summary is unavailable.

### Curl example

```bash
curl http://127.0.0.1:7331/v1/health
```

---

## GET /v1/version

Returns the binary name, semver version, and API shape identifier.

### Response

```json
{
  "name": "infinite-recall-api",
  "version": "0.1.0",
  "api_shape": "omi-local-v1"
}
```

### Curl example

```bash
curl http://127.0.0.1:7331/v1/version
```

---

## Authenticated Routes

All routes below require `Authorization: Bearer <token>`.

---

## GET /v1/conversations

List transcription sessions, newest first.

### Query parameters

| Parameter | Type | Default | Max | Description |
|---|---|---|---|---|
| `limit` | integer | 50 | 500 | Number of results |
| `offset` | integer | 0 | — | Pagination offset |
| `start_date` | ISO 8601 string | — | — | Inclusive lower bound on `startedAt` (e.g., `2025-04-01T00:00:00`) |
| `end_date` | ISO 8601 string | — | — | Exclusive upper bound on `startedAt` |

### Response

```json
{
  "conversations": [
    {
      "id": 42,
      "started_at": "2025-04-24T09:15:00.000",
      "finished_at": "2025-04-24T09:47:33.000",
      "source": "audio",
      "language": "en",
      "timezone": "America/New_York",
      "status": "completed",
      "created_at": "2025-04-24T09:15:00.000",
      "updated_at": "2025-04-24T09:47:33.000"
    }
  ],
  "limit": 50,
  "offset": 0
}
```

| Field | Type | Description |
|---|---|---|
| `id` | integer | Row ID in `transcription_sessions` |
| `started_at` | string \| null | Session start timestamp (GRDB datetime string, UTC) |
| `finished_at` | string \| null | Session end timestamp; null if still recording |
| `source` | string | Recording source (e.g., `"audio"`) |
| `language` | string | Detected language code |
| `timezone` | string | IANA timezone at capture time |
| `status` | string | Session status (e.g., `"completed"`, `"recording"`) |
| `created_at` | string \| null | Row creation timestamp |
| `updated_at` | string \| null | Row last-modified timestamp |

### Curl example

```bash
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)" \
     "http://127.0.0.1:7331/v1/conversations?limit=10&start_date=2025-04-24T00:00:00"
```

---

## GET /v1/conversations/:id

Fetch a single conversation by its integer row ID, with all transcript segments.

### Path parameter

| Parameter | Type | Description |
|---|---|---|
| `id` | integer | `transcription_sessions.id` |

### Response

```json
{
  "conversation": {
    "id": 42,
    "started_at": "2025-04-24T09:15:00.000",
    "finished_at": "2025-04-24T09:47:33.000",
    "source": "audio",
    "language": "en",
    "timezone": "America/New_York",
    "status": "completed",
    "created_at": "2025-04-24T09:15:00.000",
    "updated_at": "2025-04-24T09:47:33.000"
  },
  "transcript_segments": [
    {
      "speaker_id": 1,
      "text": "Let's go over the pull requests from yesterday.",
      "start": 0.48,
      "end": 3.12,
      "order": 0
    },
    {
      "speaker_id": 2,
      "text": "Sure. I merged the embeddings branch.",
      "start": 3.54,
      "end": 6.01,
      "order": 1
    }
  ]
}
```

Segment fields:

| Field | Type | Description |
|---|---|---|
| `speaker_id` | integer | Speaker index assigned by the diarization pipeline |
| `text` | string | Transcribed text (WhisperKit special tokens already stripped) |
| `start` | float | Start time in seconds relative to session start |
| `end` | float | End time in seconds relative to session start |
| `order` | integer | Sequence order within the session |

Returns 404 if no session with the given ID exists.

### Curl example

```bash
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)" \
     http://127.0.0.1:7331/v1/conversations/42
```

---

## GET /v3/memories

List extracted memories, newest first. Soft-deleted rows (`deleted = 1`) are
excluded.

### Query parameters

| Parameter | Type | Default | Max | Description |
|---|---|---|---|---|
| `limit` | integer | 50 | 500 | Number of results |
| `offset` | integer | 0 | — | Pagination offset |
| `category` | string | — | — | Filter to a specific category value (exact match) |

### Response

```json
{
  "memories": [
    {
      "id": 7,
      "backend_id": null,
      "content": "Michael prefers morning standup before 9 AM.",
      "category": "preference",
      "tags": "[\"work\",\"schedule\"]",
      "visibility": "private",
      "source": "conversation",
      "source_app": null,
      "conversation_id": "42",
      "confidence": 0.91,
      "reviewed": false,
      "manually_added": false,
      "created_at": "2025-04-24T09:50:00.000",
      "updated_at": "2025-04-24T09:50:00.000"
    }
  ],
  "limit": 50,
  "offset": 0
}
```

| Field | Type | Description |
|---|---|---|
| `id` | integer | Row ID in `memories` |
| `backend_id` | string \| null | Upstream Omi cloud ID; null in local-only mode |
| `content` | string | Full memory text |
| `category` | string | Category label assigned by the extraction LLM |
| `tags` | string \| null | JSON-encoded string array stored in `tagsJson` column |
| `visibility` | string | `"private"` or other visibility value |
| `source` | string \| null | Extraction source (e.g., `"conversation"`) |
| `source_app` | string \| null | App name if memory came from screen activity |
| `conversation_id` | string \| null | Linked conversation row ID, as a string |
| `confidence` | float \| null | Extraction confidence score |
| `reviewed` | bool | Whether the user has reviewed this memory |
| `manually_added` | bool | Whether the user added this memory manually |
| `created_at` | string \| null | Creation timestamp |
| `updated_at` | string \| null | Last-modified timestamp |

### Curl example

```bash
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)" \
     "http://127.0.0.1:7331/v3/memories?limit=20&category=preference"
```

---

## GET /v3/memories/:id

Fetch a single memory by its integer row ID.

### Path parameter

| Parameter | Type | Description |
|---|---|---|
| `id` | integer | `memories.id` |

### Response

Single `Memory` object (same schema as a list item above). Returns 404 if the ID
does not exist or the row is soft-deleted.

### Curl example

```bash
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)" \
     http://127.0.0.1:7331/v3/memories/7
```

---

## GET /v1/action-items

List action items, newest first. Soft-deleted rows are excluded.

### Query parameters

| Parameter | Type | Default | Max | Description |
|---|---|---|---|---|
| `limit` | integer | 50 | 500 | Number of results |
| `offset` | integer | 0 | — | Pagination offset |
| `completed` | bool | — | — | `true` to show only completed; `false` for open only; omit for all |

### Response

```json
{
  "action_items": [
    {
      "id": 3,
      "backend_id": null,
      "description": "File expense report for April conference",
      "completed": false,
      "source": "conversation",
      "conversation_id": "42",
      "priority": "high",
      "category": "finance",
      "due_at": null,
      "source_app": null,
      "created_at": "2025-04-24T10:00:00.000",
      "updated_at": "2025-04-24T10:00:00.000"
    }
  ],
  "limit": 50,
  "offset": 0
}
```

| Field | Type | Description |
|---|---|---|
| `id` | integer | Row ID in `action_items` |
| `backend_id` | string \| null | Upstream Omi cloud ID; null in local-only mode |
| `description` | string | Action item text |
| `completed` | bool | Whether the item is marked done |
| `source` | string \| null | Extraction source |
| `conversation_id` | string \| null | Linked conversation ID, as a string |
| `priority` | string \| null | Priority label (e.g., `"high"`, `"medium"`, `"low"`) |
| `category` | string \| null | Category label |
| `due_at` | string \| null | Due date/time if set |
| `source_app` | string \| null | App name if item came from screen activity |
| `created_at` | string \| null | Creation timestamp |
| `updated_at` | string \| null | Last-modified timestamp |

### Curl example

```bash
# Open action items only
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)" \
     "http://127.0.0.1:7331/v1/action-items?completed=false&limit=25"
```

---

## GET /v1/people

List all known people, sorted alphabetically by display name.

### Query parameters

None. No pagination (the people table is typically small).

### Response

```json
{
  "people": [
    {
      "id": "person-uuid-or-rowid",
      "display_name": "Alice",
      "default_emoji": "👩‍💻",
      "created_at": "2025-03-10T08:00:00.000",
      "updated_at": "2025-04-01T12:00:00.000"
    }
  ]
}
```

| Field | Type | Description |
|---|---|---|
| `id` | string | Person identifier (stored as text in `people.id`) |
| `display_name` | string | Human-readable name |
| `default_emoji` | string \| null | Optional emoji avatar |
| `created_at` | string \| null | Creation timestamp |
| `updated_at` | string \| null | Last-modified timestamp |

### Curl example

```bash
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)" \
     http://127.0.0.1:7331/v1/people
```

---

## GET /v1/people/:id

Fetch a single person by their text ID.

### Path parameter

| Parameter | Type | Description |
|---|---|---|
| `id` | string | `people.id` (text column) |

### Response

Single `Person` object (same schema as a list item above). Returns 404 if not found.

### Curl example

```bash
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)" \
     "http://127.0.0.1:7331/v1/people/person-uuid-or-rowid"
```

---

## GET /v1/scores

Daily activity rollup synthesized from primary tables. There is no dedicated
scores table; counts are computed on request.

### Query parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `date` | `YYYY-MM-DD` string | Today (UTC) | The calendar day to summarize |

Returns HTTP 400 if `date` is not a valid `YYYY-MM-DD` string.

### Response

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

| Field | Type | Description |
|---|---|---|
| `date` | string | The requested date |
| `counts.screenshots` | integer | Screenshots captured on that day |
| `counts.conversations` | integer | Transcription sessions started on that day |
| `counts.memories` | integer | Memories created on that day (non-deleted) |
| `counts.action_items` | integer | Action items created on that day (non-deleted) |
| `counts.action_items_completed` | integer | Action items marked completed on that day (by `updatedAt`) |

Note: `screenshots` counts rows in the `screenshots` table; this table must exist
in the DB. If the app has not yet captured any screenshots the count will be 0.

### Curl example

```bash
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)" \
     "http://127.0.0.1:7331/v1/scores?date=2025-04-24"
```

---

## GET /v1/search

Unified full-text and keyword search across OCR text, audio transcripts, and
VLM-derived visual activity summaries.

### Query parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `q` | string | **required** | Search query. Empty string returns 400. |
| `content_type` | string | `both` | Which corpus to search (see below) |
| `app` | string | — | Filter to a specific app name (exact match on `appName` column) |
| `start` | ISO 8601 string | — | Inclusive lower bound on the result timestamp |
| `end` | ISO 8601 string | — | Exclusive upper bound on the result timestamp |
| `limit` | integer | 50 | Max results per corpus (1–500). Applied independently to each branch when `content_type=both`. |

### `content_type` values

| Value | Backend | Description |
|---|---|---|
| `ocr` | FTS5 `MATCH` against `screenshots_fts` | Screen OCR text from captured screenshots |
| `audio` | `LIKE '%q%'` against `transcription_segments.text` | Spoken word search. Note: LIKE scan, not FTS. Case-insensitive only by SQLite collation. |
| `visual` | FTS5 `MATCH` against `visual_activity_fts` | VLM-derived visual summaries, UI state descriptions, and OCR snapshots from the frame sampling pipeline (Sprint HH). Rows populate only when the VLM sidecar is running. |
| `both` | All three above, merged | All three corpora; each gets up to `limit` results independently. |

The `q` string is phrase-quoted before being passed to FTS5 (double-quotes are
stripped from the input and the whole query is wrapped in `"..."`) to force
literal phrase matching. The audio branch uses a SQL `LIKE` with `%q%`.

### Response

```json
{
  "query": "GitHub PR",
  "content_type": "both",
  "ocr_hits": [
    {
      "screenshot_id": 5012,
      "timestamp": "2025-04-24T11:33:45.000",
      "app_name": "Google Chrome",
      "window_title": "infinite-recall / pull requests — GitHub",
      "snippet": "…merged <b>GitHub PR</b> #47 into main…"
    }
  ],
  "audio_hits": [
    {
      "session_id": 42,
      "segment_order": 17,
      "speaker": 1,
      "start_time": 122.4,
      "end_time": 125.8,
      "text": "I opened a GitHub PR for the embeddings work."
    }
  ],
  "visual_hits": [
    {
      "visual_activity_id": 88,
      "screenshot_id": 5015,
      "sampled_at": "2025-04-24T11:35:00.000",
      "app_name": "Google Chrome",
      "window_title": "infinite-recall / pull requests — GitHub",
      "visual_summary": "User reviewing a GitHub pull request diff. Two files changed.",
      "snippet": "…reviewing <b>GitHub PR</b> diff…"
    }
  ]
}
```

OCR hit fields:

| Field | Type | Description |
|---|---|---|
| `screenshot_id` | integer | Row ID in `screenshots` |
| `timestamp` | string \| null | Screenshot capture time |
| `app_name` | string | Active app at capture time |
| `window_title` | string \| null | Active window title |
| `snippet` | string | FTS5 `snippet()` excerpt with `<b>` highlights |

Audio hit fields:

| Field | Type | Description |
|---|---|---|
| `session_id` | integer | `transcription_sessions.id` |
| `segment_order` | integer | Position within the session |
| `speaker` | integer | Speaker ID |
| `start_time` | float | Seconds from session start |
| `end_time` | float | Seconds from session start |
| `text` | string | Matched segment text |

Visual hit fields:

| Field | Type | Description |
|---|---|---|
| `visual_activity_id` | integer | Row ID in `visual_activity` |
| `screenshot_id` | integer | Associated screenshot row ID |
| `sampled_at` | string \| null | Frame sampling timestamp |
| `app_name` | string \| null | App name at sample time |
| `window_title` | string \| null | Window title at sample time |
| `visual_summary` | string \| null | Full VLM-generated summary of the frame (may be null if VLM pipeline has not run) |
| `snippet` | string | FTS5 `snippet()` excerpt with `<b>` highlights |

### Notes on visual search

`visual_hits` will be empty until the VLM sidecar (`mlx-vlm` on port 8081) has
processed at least one frame. The `visual_summary` field on individual hits may
be null for rows indexed before the VLM pipeline was running
(see `VisualActivityIndexer.isVLMAvailable()` in the Swift source — there is a
known stub issue where this returns `false` even when the sidecar is healthy;
tracked in the plan).

### Curl examples

```bash
TOKEN=$(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)

# Search OCR text across all apps
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/search?q=quarterly+budget&content_type=ocr"

# Search only in Xcode windows
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/search?q=func+viewDidLoad&content_type=ocr&app=Xcode"

# Search audio transcripts from a specific time window
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/search?q=deployment&content_type=audio&start=2025-04-24T09:00:00&end=2025-04-24T18:00:00"

# Search visual activity summaries
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/search?q=GitHub+PR&content_type=visual"

# Search everything
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/search?q=standup&content_type=both&limit=20"
```

---

## Route Summary

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/v1/health` | None | DB probe + pending_work queue status |
| GET | `/v1/version` | None | Binary name and semver |
| GET | `/v1/conversations` | Bearer | List sessions; `limit`, `offset`, `start_date`, `end_date` |
| GET | `/v1/conversations/:id` | Bearer | Session + all transcript segments |
| GET | `/v3/memories` | Bearer | List memories; `limit`, `offset`, `category` |
| GET | `/v3/memories/:id` | Bearer | Single memory |
| GET | `/v1/action-items` | Bearer | List action items; `limit`, `offset`, `completed` |
| GET | `/v1/people` | Bearer | All people, alphabetical |
| GET | `/v1/people/:id` | Bearer | Single person |
| GET | `/v1/search` | Bearer | Unified search; `q`, `content_type`, `app`, `start`, `end`, `limit` |
| GET | `/v1/scores` | Bearer | Daily activity rollup; `date` |

There are no POST, PUT, PATCH, or DELETE endpoints. The API is strictly read-only.

Routes mentioned in the plan but **not yet registered** in `routes/mod.rs`:

- `/v1/visual-search` — folded into `/v1/search?content_type=visual` (Sprint HH closed this question; no separate route was added)

No other unregistered routes were found.

---

## Known Gaps and TODOs

- `VisualActivityIndexer.isVLMAvailable()` is hardcoded to `false` in the Swift
  app (Sprint HH stub). All `visual_activity` rows will have `visualSummary = null`
  until this is wired to `VisionLLMClient.shared.isReachable()`. Visual FTS rows
  are still indexed and searchable; only the summary field is missing.
- The audio search branch uses `LIKE '%q%'` rather than FTS5. For large transcript
  databases this will be slower than the OCR and visual branches. A `transcription_segments_fts`
  table is not yet present in the schema.
- `/v1/people` has no pagination parameters. If the people table grows large,
  `limit`/`offset` will need to be added.
- `/v1/scores` reads `screenshots.timestamp` but the `screenshots` table may not
  exist on first run (before any screen capture occurs). The query will return 0
  rather than an error because COUNT(*) on a missing table is caught as a SQLite
  error surfaced as HTTP 500. TODO: add table-existence guard matching the
  `pending_work` pattern in the health handler.

---

## SQLite Schema Reference

Ground truth for column names and types: `Desktop/Sources/Rewind/Core/RewindDatabase.swift`

The Rust API uses the exact GRDB column names (camelCase in SQLite, mapped to
snake_case in JSON output). Key mappings:

| SQLite column | JSON field |
|---|---|
| `startedAt` | `started_at` |
| `finishedAt` | `finished_at` |
| `createdAt` | `created_at` |
| `updatedAt` | `updated_at` |
| `backendId` | `backend_id` |
| `displayName` | `display_name` |
| `defaultEmoji` | `default_emoji` |
| `sourceApp` | `source_app` |
| `conversationId` | `conversation_id` |
| `manuallyAdded` | `manually_added` |
| `tagsJson` | `tags` |
| `sessionId` | `session_id` |
| `segmentOrder` | `segment_order` |
| `startTime` | `start_time` / `start` |
| `endTime` | `end_time` / `end` |
| `appName` | `app_name` |
| `windowTitle` | `window_title` |
| `sampledAt` | `sampled_at` |
| `screenshotId` | `screenshot_id` |
| `visualSummary` | `visual_summary` |
