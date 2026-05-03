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
IR_APP_NAME="Infinite Recall" \
IR_SKIP_BACKEND=1 IR_SKIP_AUTH=1 IR_SKIP_TUNNEL=1 IR_SKIP_PYTHON=1 \
./run.sh --yolo
```

The `IR_APP_NAME` puts the build in `/Applications/Infinite Recall.app` so it
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

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **infinite-recall** (23560 symbols, 195747 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/infinite-recall/context` | Codebase overview, check index freshness |
| `gitnexus://repo/infinite-recall/clusters` | All functional areas |
| `gitnexus://repo/infinite-recall/processes` | All execution flows |
| `gitnexus://repo/infinite-recall/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
