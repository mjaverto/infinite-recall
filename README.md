# Infinite Recall

Local-first, always-on screen + audio recorder for macOS. Private rewind, on-device
transcription, on-device LLM extraction. Omi-shaped REST API for MCP-compatible
clients (Claude Code, Cursor, etc.).

Status: in development. Forked from Omi `desktop/` (see `ATTRIBUTION.md`).

## What it does

- Always-on screen capture (ScreenCaptureKit) and audio capture (mic + system audio
  via CoreAudio Process Tap)
- On-device transcription via WhisperKit (Whisper, Core ML)
- On-device memory + action-item extraction via local LLM (mlx-lm.server)
- Local SQLite database (GRDB), no cloud sync
- Menu bar control with Safe Mode pause (time-boxed or indefinite)
- Battery-aware processing — recording always on, heavy ML work defers when on
  battery and drains when plugged in
- REST API (Omi-compatible shape) for external clients

## What it does not do

- No sign-in. No Apple/Google/Firebase auth. No account.
- No cloud sync, no telemetry, no analytics. Data never leaves your Mac.
- No subscriptions, payments, or premium features.

## Requirements

- macOS 14.4+ (CoreAudio Process Tap requirement)
- Apple Silicon recommended (M1/M2/M3/M4) for on-device ML
- ~25 GB free disk for local LLM model

## Build

```bash
OMI_APP_NAME="omi-irecall" \
OMI_SKIP_BACKEND=1 OMI_SKIP_AUTH=1 OMI_SKIP_TUNNEL=1 OMI_SKIP_PYTHON=1 \
./run.sh --yolo
```

## License

MIT. See `LICENSE`.
