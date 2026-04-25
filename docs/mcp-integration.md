# Infinite Recall — MCP integration

The local API runs on `http://127.0.0.1:7331`. Authentication is a single
bearer token written to:

```
~/Library/Application Support/InfiniteRecall/api-token.txt
```

The file is mode 0600 and is generated on first run of `infinite-recall-api`.

## Install the daemon

```bash
./scripts/setup-api-server.sh
```

This builds `Backend-Rust` in release, installs the binary to
`/usr/local/bin/infinite-recall-api`, drops a launchd plist into
`~/Library/LaunchAgents/com.infiniterecall.api.plist`, and loads it.

## Smoke test

```bash
curl -s http://127.0.0.1:7331/v1/health
curl -s -H "Authorization: Bearer $(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)" \
     "http://127.0.0.1:7331/v1/conversations?limit=5"
```

## Wire to Claude Code / Cursor / any MCP client

There is no first-party MCP server here yet — the Rust daemon serves plain
REST. The simplest way to expose it as an MCP tool is a generic REST→MCP
bridge. Example with `mcp-rest-bridge` (or any equivalent npm package, swap
to the bridge of your choice):

```bash
claude mcp add infinite-recall -- \
  npx -y mcp-rest-bridge \
    --base-url http://127.0.0.1:7331 \
    --bearer  "$(cat ~/Library/Application\ Support/InfiniteRecall/api-token.txt)"
```

If no off-the-shelf bridge fits, write a thin custom MCP server that
proxies the routes below; the surface is small.

## Routes

All routes are **read-only**. The Swift app owns writes.

| Method | Path                              | Notes                                     |
|--------|-----------------------------------|-------------------------------------------|
| GET    | `/v1/health`                      | Public. `{ "status": "ok" }`              |
| GET    | `/v1/version`                     | Public. Build identity.                   |
| GET    | `/v1/conversations`               | `limit`, `offset`, `start_date`, `end_date` |
| GET    | `/v1/conversations/:id`           | Full session + ordered transcript segments |
| GET    | `/v3/memories`                    | `limit`, `offset`, `category`             |
| GET    | `/v3/memories/:id`                |                                           |
| GET    | `/v1/action-items`                | `limit`, `offset`, `completed`            |
| GET    | `/v1/people`                      |                                           |
| GET    | `/v1/people/:id`                  |                                           |
| GET    | `/v1/search`                      | `q`, `content_type=audio\|ocr\|both`, `app`, `start`, `end` |
| GET    | `/v1/scores`                      | `date=YYYY-MM-DD`. Activity rollup.       |

`/v1/search` uses the existing `screenshots_fts` FTS5 index for OCR search;
audio search uses a `LIKE` scan on `transcription_segments.text` (no FTS
mirror exists for transcripts yet).

## Environment

| Var | Default |
|-----|---------|
| `INFINITE_RECALL_DB`         | `~/Library/Application Support/Omi/users/anonymous/omi.db` |
| `INFINITE_RECALL_BIND`       | `127.0.0.1:7331` |
| `INFINITE_RECALL_TOKEN_PATH` | `~/Library/Application Support/InfiniteRecall/api-token.txt` |

The daemon opens SQLite with `SQLITE_OPEN_READ_ONLY`. The Swift app's
WAL writers are unaffected.
