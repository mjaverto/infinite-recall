# Infinite Recall — Agent Onboarding Guide

This file is the entry point for AI agents (Claude Code via MCP, Cursor, custom
scripts) that want to read the user's local data through the Infinite Recall API.

---

## What This Is

Infinite Recall is a **local-first macOS app** that continuously captures screen
and audio, transcribes speech on-device with WhisperKit, extracts memories and
action items with a local LLM, and indexes visual activity with a vision LLM.

**Everything lives on the user's machine.** There is no cloud sync, no remote
database, no outbound network traffic from the app or the API server. Agent calls
to the API are loopback-only (`127.0.0.1:7331`).

As an agent you can:

- Search conversations by keyword across audio transcripts, OCR text, and visual
  activity summaries
- Retrieve full conversation transcripts with per-speaker segment timing
- Query extracted memories (facts, preferences, and observations the LLM derived
  from conversations)
- List open or completed action items
- Look up known people and correlate them with conversations
- Search screen activity (what the user was looking at) by app, time window, or
  content keyword
- Get daily activity rollups (screenshot count, conversation count, etc.)

**No write operations exist.** This API is strictly read-only. Agents cannot
create, update, or delete any records.

---

## Prerequisites

The Backend-Rust API server must be running. Verify:

```bash
curl http://127.0.0.1:7331/v1/health
```

If the server is not running, start it:

```bash
~/src/infinite-recall/scripts/setup-api-server.sh
```

This builds the binary and registers it as a launchd agent that starts at login.
See `Backend-Rust/API.md` for full setup details.

---

## MCP Setup (Claude Code / Cursor)

The Settings panel in Infinite Recall (Settings → AI / Models → MCP API card)
shows a ready-to-paste `claude mcp add` command with the correct token already
filled in. Click "Copy command" there for the authoritative one-liner.

The general form is:

```bash
claude mcp add infinite-recall \
  --transport http \
  --url http://127.0.0.1:7331 \
  --header "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)"
```

Run this once per machine. Claude Code will persist the config and use it for
future sessions.

### Fallback: manual `mcp.json` snippet

If you prefer to configure the MCP client manually, add this to your
`mcp.json` (location depends on client — Claude Code uses
`~/.claude/mcp.json`):

```json
{
  "mcpServers": {
    "infinite-recall": {
      "transport": "http",
      "url": "http://127.0.0.1:7331",
      "headers": {
        "Authorization": "Bearer <paste token here>"
      }
    }
  }
}
```

Replace `<paste token here>` with the contents of
`~/Library/Application Support/InfiniteRecall/api-token.txt` (without the
trailing newline). The token is a 64-character hex string.

---

## Auth Pattern for Custom Agents

Read the bearer token once at startup. Set it as an environment variable or
store it in a local variable. Send it on every authed request.

```bash
# Shell
TOKEN=$(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7331/v1/conversations
```

```python
# Python
from pathlib import Path
import requests

token = Path.home() / "Library/Application Support/InfiniteRecall/api-token.txt"
bearer = token.read_text().strip()
headers = {"Authorization": f"Bearer {bearer}"}

resp = requests.get("http://127.0.0.1:7331/v1/conversations", headers=headers)
resp.raise_for_status()
conversations = resp.json()["conversations"]
```

```javascript
// Node.js
import { readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

const token = readFileSync(
  join(homedir(), "Library/Application Support/InfiniteRecall/api-token.txt"),
  "utf8"
).trim();

const resp = await fetch("http://127.0.0.1:7331/v1/conversations", {
  headers: { Authorization: `Bearer ${token}` },
});
const { conversations } = await resp.json();
```

**Do not log or print the token.** It grants full read access to all local data.

---

## Privacy Posture

- The API server binds exclusively to `127.0.0.1`. No network interface except
  loopback can reach it.
- The Swift app and the Rust daemon make zero outbound network connections during
  normal operation (apart from one-time model downloads during initial setup).
  Verified with `lsof`.
- All telemetry SDKs (Sentry, PostHog, Mixpanel, Heap, Firebase) have been
  stripped or disabled.
- Agent calls never leave the user's machine via this API.

---

## Capabilities Reference

| Capability | Endpoint | Key parameters |
|---|---|---|
| List recent conversations | `GET /v1/conversations` | `limit`, `offset`, `start_date`, `end_date` |
| Get full transcript | `GET /v1/conversations/:id` | path: integer ID |
| Search audio (spoken words) | `GET /v1/search?content_type=audio` | `q`, `limit` |
| Search screen OCR | `GET /v1/search?content_type=ocr` | `q`, `app`, `start`, `end` |
| Search visual summaries | `GET /v1/search?content_type=visual` | `q`, `app`, `start`, `end` |
| Search everything | `GET /v1/search?content_type=both` | `q`, `app`, `start`, `end`, `limit` |
| List memories | `GET /v3/memories` | `limit`, `offset`, `category` |
| Get one memory | `GET /v3/memories/:id` | path: integer ID |
| List action items | `GET /v1/action-items` | `limit`, `offset`, `completed` |
| List people | `GET /v1/people` | — |
| Get one person | `GET /v1/people/:id` | path: string ID |
| Daily activity rollup | `GET /v1/scores` | `date` (YYYY-MM-DD) |
| Health check | `GET /v1/health` | — (no auth required) |

---

## Common Tasks with Examples

All examples assume:

```bash
TOKEN=$(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)
```

### 1. Find conversations from yesterday about a topic

```bash
# Yesterday's date (macOS date command)
YESTERDAY=$(date -v-1d +%Y-%m-%d)

curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/conversations?start_date=${YESTERDAY}T00:00:00&end_date=${YESTERDAY}T23:59:59&limit=50"
```

Then search the transcript text:

```bash
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/search?q=deployment&content_type=audio&start=${YESTERDAY}T00:00:00&end=${YESTERDAY}T23:59:59"
```

### 2. List open action items

```bash
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/action-items?completed=false&limit=50"
```

Sample response excerpt:

```json
{
  "action_items": [
    {
      "id": 3,
      "description": "File expense report for April conference",
      "completed": false,
      "priority": "high",
      "due_at": null
    }
  ],
  "limit": 50,
  "offset": 0
}
```

### 3. Search screen activity for "GitHub PR"

```bash
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/search?q=GitHub+PR&content_type=ocr"
```

To restrict to a specific app:

```bash
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/search?q=GitHub+PR&content_type=ocr&app=Google+Chrome"
```

OCR hits include a `snippet` field with `<b>` tags around matched terms.

### 4. Get a memory's full content

```bash
# List recent memories
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v3/memories?limit=10"

# Fetch one by ID
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v3/memories/7"
```

### 5. Fetch one conversation with its full transcript

```bash
# First get the ID from the list endpoint
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/conversations?limit=5"

# Then fetch with segments
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/conversations/42"
```

The response includes `transcript_segments` ordered by `order` with per-speaker
`start`/`end` timing in seconds.

### 6. Filter screen search by app and time window

```bash
curl -H "Authorization: Bearer $TOKEN" \
     "http://127.0.0.1:7331/v1/search?q=budget&content_type=ocr&app=Microsoft+Excel&start=2025-04-01T00:00:00&end=2025-04-30T23:59:59&limit=20"
```

Use `content_type=visual` instead for VLM-derived activity summaries (available
once the vision sidecar has indexed frames).

---

## Limits

- **Single-user only.** The app always runs as the `anonymous` user. There is no
  multi-user support and no user-switching in this API.
- **Read-only.** No endpoints exist for creating, editing, or deleting data.
- **Pagination.** Most list endpoints support `limit` (max 500) and `offset` for
  cursor-free pagination. `/v1/people` has no pagination parameters.
- **Search is synchronous.** FTS5 queries (OCR, visual) are fast. The audio
  branch uses a full-table `LIKE` scan and may be slower on large databases.
- **Visual hits require VLM.** `visual_hits` in search results are empty until
  the vision LLM sidecar (`mlx-vlm` on port 8081) has processed frames. The VLM
  must be running for new frames to be indexed.
- **No semantic/vector search via this API.** Embedding-based similarity search
  is performed inside the Swift app; there is no vector search endpoint here.

---

## Errors and Retry

| HTTP status | Meaning | Action |
|---|---|---|
| 200 | Success | Consume the JSON body |
| 400 | Bad request (invalid parameter) | Fix the query string before retrying |
| 401 | Token missing or wrong | Re-read `api-token.txt` — the token may have been rotated. Reconstruct the `Authorization` header. |
| 404 | ID not found | The row does not exist or was soft-deleted. Do not retry. |
| 500 | Internal server error | Check `/tmp/infinite-recall-api.err.log`. May indicate a DB corruption or missing table. |

On 401: the token file is the source of truth. Re-read it and retry once. If
still 401, the server may need to be restarted (`launchctl unload` then
`launchctl load` the plist).

On 500: inspect the error log at `/tmp/infinite-recall-api.err.log`. Common
cause is a missing SQLite table (e.g., `screenshots` or `visual_activity` if the
app has not yet run those migrations). The health endpoint (`/v1/health`) does
not require auth and is always a safe probe.

---

## Schema Reference

Full route documentation with request/response shapes, field tables, and curl
examples: `Backend-Rust/API.md`

SQLite schema (GRDB migrations, ground truth): `Desktop/Sources/Rewind/Core/RewindDatabase.swift`
