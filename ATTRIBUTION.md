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
- On-device speaker diarization added (no cloud)

## On-device speaker diarization

The `Desktop/Sources/Diarization/` module ships a lightweight, fully on-device
speaker diarization pipeline. v1 uses a deterministic MFCC-based embedding
(no model files, no downloads) computed via Apple's Accelerate framework.

- **Approach**: 26-dim L2-normalized MFCC mean+std embedding per speech turn,
  cosine-matched to per-person centroids (threshold 0.65) stored in GRDB.
- **VAD**: simple energy-based with hangover; intentionally kept minimal so
  failures here can't block the always-on capture pipeline.
- **No external model is downloaded**. A neural embedding (pyannote-audio
  segmentation + WeSpeaker, ported to Core ML or ONNX) can drop into the same
  `MFCCExtractor.embed(samples:)` interface later — see TODOs in
  `SpeakerDiarizationService.swift`.
- **License**: Original code, MIT-licensed under this project.

The architectural blueprint is in `~/.claude/plans/stop-all-versions-of-humble-hennessy.md`.
