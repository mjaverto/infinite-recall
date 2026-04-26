# Contributing

Infinite Recall is a personal project. External contributions are welcome but the
bar is high: prefer small, focused changes with clear rationale.

---

## Dev setup

**Requirements**

- macOS 14.4+
- Xcode Command Line Tools: `xcode-select --install`
- Homebrew packages: `brew install pkg-config webp`
- `cargo` (stable) for Backend-Rust: [rustup.rs](https://rustup.rs)

**Optional**

- Python 3.11+ with `mlx-lm` and `mlx-vlm` for local LLM sidecars (the app
  ships setup scripts — you do not need to install these by hand for normal Swift
  development)

---

## Building

**Compile-check only** (fast, no app launch):

```bash
xcrun swift build -c debug --package-path Desktop
```

**Full build + sign + launch:**

```bash
OMI_APP_NAME="Infinite Recall" \
OMI_SKIP_BACKEND=1 OMI_SKIP_AUTH=1 OMI_SKIP_TUNNEL=1 OMI_SKIP_PYTHON=1 \
./run.sh --yolo
```

The `OMI_SKIP_*` flags disable all inherited Omi cloud services. They must always
be set when building locally.

**Backend-Rust (API daemon):**

```bash
cd Backend-Rust && cargo build
```

The `scripts/setup-api-server.sh` wrapper handles first-run token generation and
launchd plist installation.

---

## Project layout

```
Desktop/Sources/          Swift source tree
  AppState/               Global state, API client (local-only stub)
  Capture/                ScreenCaptureService, AudioCaptureService,
                          SystemAudioCaptureService
  Diarization/            MFCC and SpeakerKit backends
  LLM/                    MLXLifecycleManager, VLMLifecycleManager,
                          IdleAIController, LocalLLMClient, VisionLLMClient
  Persistence/            GRDB schema, migration chain, storage helpers
  REST/                   MCPAPIService, Backend-Rust wrappers
  UI/                     SwiftUI views (MainWindow, Rewind, settings panels)
  Assistants/             Focus / Task / Insight / Memory assistants
Backend-Rust/src/         axum REST handler, SQLite reader, auth middleware
scripts/                  setup-mlx-server.sh, setup-vlm-server.sh,
                          setup-api-server.sh
```

---

## Code style

- Follow the Swift conventions already in the codebase — no major style deviations
  in a PR.
- Keep prose in comments tight. No filler phrases.
- No telemetry, no outbound network calls, no cloud dependencies. If a change would
  add any of these it will be declined.
- `isLocalOnlyMode = true` is an invariant. Do not add conditional cloud paths.

---

## Commit conventions

```
type(scope): one-line summary in present tense
```

Common types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`.
Scope is the rough component: `capture`, `transcription`, `llm`, `vlm`, `api`,
`ui`, `persistence`, `diarization`, `build`.

Examples from the log:

```
feat(chat): retrieve local context (transcripts + visual + memories) on each turn
fix(transcription): RMS silence gate skips Whisper pass on quiet windows
chore(ui): remove inherited "Get Infinite Recall Device" hardware promo
```

---

## Pull requests

- One logical change per PR. Mixed refactors + features make review hard.
- Test by running the full app (`./run.sh --yolo`) before opening a PR. Compile-
  check alone is not sufficient — many bugs only appear at runtime.
- Document any new UserDefaults keys, launchd plists, or file-system paths in the
  PR description. These are the hardest things to discover later.
- Security-relevant changes (auth, token handling, TCC permissions) require
  explicit discussion before implementation — see [SECURITY.md](SECURITY.md).
