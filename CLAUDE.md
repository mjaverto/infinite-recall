# Infinite Recall — Claude Project Context

Local-first macOS app: always-on screen + audio capture, on-device transcription,
private rewind/timeline, Omi-shaped REST API for MCP.

Forked from Omi `desktop/` (MIT). See `ATTRIBUTION.md`.

## Project layout

- `Desktop/` — SwiftUI macOS app (SwiftPM, no Xcode project)
- `Backend-Rust/` — local Rust daemon (axum, SQLite, mlx-lm proxy, control endpoints)
- `agent/`, `agent-cloud/`, `pi-mono-extension/` — inherited from Omi, scope TBD
- `Auth-Python/` — inherited from Omi; will be removed once auth is fully stripped
- `dmg-assets/`, `scripts/`, `e2e/` — inherited from Omi

## Building

```bash
xcrun swift build -c debug --package-path Desktop
```

For full app build + install + launch:

```bash
OMI_APP_NAME="Infinite Recall" \
OMI_SKIP_BACKEND=1 OMI_SKIP_AUTH=1 OMI_SKIP_TUNNEL=1 OMI_SKIP_PYTHON=1 \
./run.sh --yolo
```

The `OMI_APP_NAME` puts the build in `/Applications/Infinite Recall.app` so it
won't collide with any "Omi Dev" install on the same machine. Skip-flags
disable everything cloud — we don't need any of it.

## Local-first invariants

- **No Firebase, no Apple/Google sign-in, no Deepgram, no Cloud Run.**
  All cloud paths must be either deleted or stubbed.
- **All data on-device** under `~/Library/Application Support/InfiniteRecall/`.
  GRDB SQLite for app data; per-user falls back to `anonymous` (the only user).
- **Transcription**: WhisperKit (Apache 2.0), Core ML on-device. NEVER stream
  audio to a remote service.
- **LLM**: `mlx-lm.server` running locally on `127.0.0.1:8080` (managed via
  launchd), serving an OpenAI-compatible HTTP endpoint. Default model:
  4-bit Qwen-class 32B. Both the Rust daemon and the Swift app talk to it.
- **No telemetry**: Sentry, PostHog, Mixpanel, Heap all removed.

## Testing

- Logs: `/private/tmp/omi-dev.log` (legacy path, will rename)
- UI verification: `agent-swift connect --bundle-id com.omi.infinite-recall`
- `xcrun swift build` is **compile-check only** — does not start the app.
  Always `./run.sh` to actually test.

## Things the user wants help with first

1. Strip auth (no Apple/Google login required) — app launches straight to main UI
2. Rebrand from "Omi" to "Infinite Recall" (name, logo, visible strings)
3. Patched `run.sh` (xattr PATH issue with pyenv shim)
4. Verify build + launch under new bundle name
