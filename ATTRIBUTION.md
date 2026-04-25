# Attribution

Infinite Recall is built on the shoulders of two excellent open-source projects.

## Omi (BasedHardware/omi) — MIT License

The desktop app shell — SwiftUI, ScreenCaptureKit integration, audio capture
service, Rewind UI, FloatingControlBar, GRDB persistence, DMG build pipeline —
is forked from the `desktop/` subtree of:

- **Source**: https://github.com/BasedHardware/omi/tree/main/desktop
- **Commit**: forked at `desktop/Desktop` v0.11.358 (Apr 23 2026)
- **License**: MIT (see `LICENSE`)
- **Copyright**: © 2024 Based Hardware Contributors

Substantial portions of `Desktop/Sources/`, `Backend-Rust/`, `agent/`,
`pi-mono-extension/`, `dmg-assets/`, `scripts/`, `e2e/`, and `run.sh` originate
from Omi and remain under the original MIT license.

## screenpipe (screenpipe/screenpipe) — MIT License

Audio capture device-polling robustness (the 500ms poll loop that re-anchors
the system audio tap when the user switches output devices, e.g. to AirPods)
is adapted from:

- **Source**: https://github.com/screenpipe/screenpipe
- **Reference**: `crates/screenpipe-audio/src/core/process_tap.rs`
- **License**: MIT
- **Copyright**: © screenpipe contributors

## Differences from upstream

Infinite Recall is a **local-first** rework. Major changes from Omi:

- Sign-in / Firebase Auth removed — app runs as a single local user with no
  cloud account
- Cloud transcription (Deepgram via WebSocket) replaced with on-device
  WhisperKit
- Cloud data plane (Firestore + Redis + Cloud Run) replaced with local SQLite
  via GRDB
- LLM extraction (memories, action items) routed through a local
  `mlx-lm.server` Python sidecar instead of cloud LLM APIs
- Telemetry (Sentry, PostHog, Mixpanel, Heap) removed
- Subscription / payment / OAuth flows removed
- Brand reset to "Infinite Recall"

The architectural blueprint is in `~/.claude/plans/stop-all-versions-of-humble-hennessy.md`.
