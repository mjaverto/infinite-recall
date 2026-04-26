// Infinite Recall fork: bundled installer scripts.
//
// We ship the install scripts and launchd plists as Swift string literals
// instead of as Resources copied through SPM. Why:
//
//   1. SPM `.copy(...)` and `.process(...)` paths must live inside the package
//      root (`Desktop/`). The scripts live at the repo root (`scripts/`).
//      Pulling them in would require either a pre-build phase that mirrors
//      them into `Desktop/Resources/scripts/` (extra build complexity) or a
//      symlink (fragile across signed-app bundles, breaks on `swift build`).
//
//   2. `.process(...)` runs Apple's resource processor over text files which
//      mangles bash heredocs, line endings, and plist comments. `.copy(...)`
//      avoids that but you still need the path to live under `Sources/`.
//
//   3. String literals are zero-config. They're embedded straight into the
//      executable, survive code signing, and require no Package.swift changes.
//      Trade-off: when someone edits `scripts/setup-mlx-server.sh` they MUST
//      also re-run `scripts/sync-bundled.sh` (or hand-edit the literals here)
//      so the in-app installer stays in sync. We document that contract here.
//
// Sync contract: keep the literals below byte-identical to the corresponding
// files under `scripts/`. CI should diff them; for now, manual sync.

import Foundation

enum BundledScripts {

  // MARK: - Public extraction API

  /// Directory where extracted scripts live at runtime.
  /// `~/Library/Application Support/InfiniteRecall/scripts/`
  static var extractionDirectory: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
      .appendingPathComponent("Library/Application Support/InfiniteRecall/scripts", isDirectory: true)
  }

  /// Extract the MLX setup script + its plist template to disk and return the
  /// absolute path to the script. Idempotent — overwrites on every call so an
  /// updated app build always replaces stale on-disk copies.
  @discardableResult
  static func extractMLXScripts() throws -> URL {
    let dir = extractionDirectory
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let scriptURL = dir.appendingPathComponent("setup-mlx-server.sh")
    let plistURL = dir.appendingPathComponent("com.infiniterecall.mlx.plist")
    try writeExecutable(setupMLXServer, to: scriptURL)
    try writeText(mlxLaunchdPlist, to: plistURL)
    return scriptURL
  }

  /// Extract the API setup script + its plist template; returns the script path.
  @discardableResult
  static func extractAPIScripts() throws -> URL {
    let dir = extractionDirectory
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let scriptURL = dir.appendingPathComponent("setup-api-server.sh")
    let plistURL = dir.appendingPathComponent("com.infiniterecall.api.plist")
    try writeExecutable(setupAPIServer, to: scriptURL)
    try writeText(apiLaunchdPlist, to: plistURL)
    return scriptURL
  }

  /// Extract the VLM (mlx-vlm) setup script + its plist template; returns the
  /// script path. Sibling of `extractMLXScripts()` for the vision tier on
  /// 127.0.0.1:8081.
  @discardableResult
  static func extractVLMScripts() throws -> URL {
    let dir = extractionDirectory
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let scriptURL = dir.appendingPathComponent("setup-vlm-server.sh")
    let plistURL = dir.appendingPathComponent("com.infiniterecall.vlm.plist")
    try writeExecutable(setupVLMServer, to: scriptURL)
    try writeText(vlmLaunchdPlist, to: plistURL)
    return scriptURL
  }

  // MARK: - Helpers

  private static func writeText(_ contents: String, to url: URL) throws {
    try contents.data(using: .utf8)?.write(to: url, options: .atomic)
  }

  private static func writeExecutable(_ contents: String, to url: URL) throws {
    try writeText(contents, to: url)
    // chmod 0o755
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: url.path)
  }

  // MARK: - Embedded resources
  // Keep these byte-identical to scripts/ in the repo root.

  static let setupMLXServer: String = ##"""
#!/usr/bin/env bash
# Infinite Recall — one-shot installer for the local mlx-lm.server sidecar.
#
# What this does:
#   1. Installs `uv` (fast Python tool runner) if missing.
#   2. Installs the `mlx-lm` Python package via `uv tool install`.
#   3. Optionally pulls the default 4-bit Qwen 7B-Instruct model from Hugging
#      Face (~4.3 GB on disk, ~7-9 GB resident — prompts before downloading,
#      unless --yes / env INFINITE_RECALL_AUTO_CONFIRM=1 is set).
#   4. Drops a launchd plist at ~/Library/LaunchAgents/com.infiniterecall.mlx.plist
#      and `launchctl load`s it so the server runs at login on 127.0.0.1:8080.
#
# Model override (highest priority wins):
#   --model <hf-path>            CLI flag
#   INFINITE_RECALL_MODEL=<path> env var (preferred)
#   INFINITE_RECALL_MLX_MODEL    legacy env var (still honored)
# Otherwise falls back to the built-in default below. This lets a user who
# already pulled Qwen 2.5-32B keep using it without re-downloading the 7B
# model — they just pass --model mlx-community/Qwen2.5-32B-Instruct-4bit.
#
# Re-running is safe — every step is idempotent.
#
# When invoked by the in-app installer (Swift LocalAIInstaller), the script
# emits structured `PROGRESS:` lines on stdout that the host parses to drive
# the UI step list and the model download progress bar.

set -euo pipefail

LABEL="com.infiniterecall.mlx"
# Default LLM. Smaller-by-default for new installs (was Qwen2.5-32B-Instruct-4bit).
# Verified on huggingface.co: Apache 2.0, ~4.3 GB on disk, 32k context, same
# Qwen2.5 chat template as the previous 32B default.
# Overridable by the in-app installer when the user picks a non-default
# option from the Local Model picker, via INFINITE_RECALL_MLX_MODEL env var.
DEFAULT_MODEL="${INFINITE_RECALL_MLX_MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
HOST="127.0.0.1"
PORT="8080"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_TEMPLATE="${SCRIPT_DIR}/com.infiniterecall.mlx.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/InfiniteRecall"

# Non-interactive mode for the in-app installer.
AUTO_CONFIRM="${INFINITE_RECALL_AUTO_CONFIRM:-0}"
# Resolve model override: --model wins over env, env wins over default.
# Honor both INFINITE_RECALL_MODEL (preferred) and INFINITE_RECALL_MLX_MODEL
# (legacy — already referenced in the embedded Python heredoc below).
MODEL="${INFINITE_RECALL_MODEL:-${INFINITE_RECALL_MLX_MODEL:-${DEFAULT_MODEL}}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) AUTO_CONFIRM=1; shift ;;
    --model) MODEL="$2"; shift 2 ;;
    --model=*) MODEL="${1#--model=}"; shift ;;
    *) shift ;;
  esac
done
# Re-export so the embedded Python sees the resolved value regardless of which
# env var the caller used.
export INFINITE_RECALL_MLX_MODEL="${MODEL}"
export INFINITE_RECALL_MODEL="${MODEL}"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
warn() { printf "\033[33m%s\033[0m\n" "$1"; }
err()  { printf "\033[31m%s\033[0m\n" "$1" >&2; }
progress() { printf "PROGRESS:%s\n" "$1"; }

progress "STEP=checking_prereqs"

# ---------------------------------------------------------------------------
# 1. Install uv
# ---------------------------------------------------------------------------
progress "STEP=installing_uv"
if ! command -v uv >/dev/null 2>&1; then
  bold "→ Installing uv (Python tool runner)..."
  if command -v brew >/dev/null 2>&1; then
    brew install uv
  else
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # Pull uv onto PATH for the rest of this script.
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
else
  bold "✓ uv already installed: $(uv --version)"
fi

UV_BIN="$(command -v uv)"
if [ -z "${UV_BIN}" ]; then
  err "uv install seemed to succeed but uv is not on PATH. Open a new shell and rerun."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Install mlx-lm
# ---------------------------------------------------------------------------
progress "STEP=installing_mlx"
bold "→ Installing mlx-lm via uv..."
uv tool install --upgrade mlx-lm

# ---------------------------------------------------------------------------
# 3. Optionally download the default model
# ---------------------------------------------------------------------------
progress "STEP=downloading_model"
MODEL_CACHE_DIR="${HOME}/.cache/huggingface/hub/models--${MODEL//\//--}"
DOWNLOAD_OK=0
if [ -d "${MODEL_CACHE_DIR}" ]; then
  bold "✓ Model already present at ${MODEL_CACHE_DIR}"
  progress "DOWNLOAD_PCT=100"
  DOWNLOAD_OK=1
else
  PROCEED=0
  if [ "${AUTO_CONFIRM}" = "1" ]; then
    PROCEED=1
  else
    warn "Model: ${MODEL}"
    warn "(The default 7B model is ~4.3 GB; larger overrides will be larger.)"
    printf "Download it now? [y/N] "
    read -r REPLY
    case "${REPLY}" in
      [yY]|[yY][eE][sS]) PROCEED=1 ;;
    esac
  fi

  if [ "${PROCEED}" = "1" ]; then
    bold "→ Downloading model (this may take a while)..."
    # We use huggingface_hub.snapshot_download with a progress callback that
    # emits structured `PROGRESS:DOWNLOAD_*` lines the host parses for the
    # UI progress bar. tqdm is disabled so stdout stays clean.
    #
    # The callback approximates total bytes from the union of file sizes
    # reported by the HF metadata. We sum bytes as files complete, plus the
    # in-flight file's tqdm fraction approximation via os.path.getsize().
    HF_HUB_DISABLE_PROGRESS_BARS=1 \
    uv tool run --from mlx-lm python - <<'PY'
import os, sys, threading, time, traceback
from huggingface_hub import snapshot_download, HfApi
from huggingface_hub.utils import (
    RepositoryNotFoundError,
    GatedRepoError,
    HfHubHTTPError,
)

MODEL = os.environ.get("INFINITE_RECALL_MODEL") or os.environ.get("INFINITE_RECALL_MLX_MODEL", "mlx-community/Qwen2.5-7B-Instruct-4bit")

def emit(msg: str) -> None:
    sys.stdout.write(f"PROGRESS:{msg}\n")
    sys.stdout.flush()

# Probe total size up front so we can produce a real percent.
try:
    info = HfApi().model_info(MODEL, files_metadata=True)
    total = sum((s.size or 0) for s in info.siblings)
except Exception:
    total = 0

cache_dir = os.path.expanduser(f"~/.cache/huggingface/hub/models--{MODEL.replace('/', '--')}")
stop = threading.Event()

def watcher():
    while not stop.is_set():
        bytes_on_disk = 0
        for root, _, files in os.walk(cache_dir):
            for f in files:
                try:
                    bytes_on_disk += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
        emit(f"DOWNLOAD_BYTES={bytes_on_disk}")
        if total:
            pct = min(99, int(bytes_on_disk * 100 / total))
            emit(f"DOWNLOAD_PCT={pct}")
        time.sleep(2)

t = threading.Thread(target=watcher, daemon=True)
t.start()
try:
    try:
        snapshot_download(MODEL)
    except RepositoryNotFoundError:
        reason = f"Repository not found: {MODEL}"
        emit(f"DOWNLOAD_FAIL={reason}")
        traceback.print_exc(file=sys.stderr)
        sys.exit(2)
    except GatedRepoError:
        reason = f"Repository is gated and requires authentication: {MODEL}"
        emit(f"DOWNLOAD_FAIL={reason}")
        traceback.print_exc(file=sys.stderr)
        sys.exit(2)
    except HfHubHTTPError as e:
        status = e.response.status_code if hasattr(e, "response") else "?"
        reason = f"Hugging Face Hub error ({status}) for {MODEL}: {e}"
        emit(f"DOWNLOAD_FAIL={reason}")
        traceback.print_exc(file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        reason = f"Download failed for {MODEL}: {type(e).__name__}: {e}"
        emit(f"DOWNLOAD_FAIL={reason}")
        traceback.print_exc(file=sys.stderr)
        sys.exit(2)
finally:
    stop.set()
    t.join(timeout=3)

emit("DOWNLOAD_PCT=100")
PY
    DOWNLOAD_OK=1
  else
    warn "Skipping model download. The launchd agent will fail to start until the model is fetched."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Install launchd plist
# ---------------------------------------------------------------------------
progress "STEP=installing_launchd"
if [ ! -f "${PLIST_TEMPLATE}" ]; then
  err "Plist template missing: ${PLIST_TEMPLATE}"
  exit 1
fi

mkdir -p "$(dirname "${PLIST_DEST}")"
mkdir -p "${LOG_DIR}"

bold "→ Rendering launchd plist to ${PLIST_DEST}"
# Substitute __USER_HOME__ and __UV_BIN__ placeholders.
sed \
  -e "s|__USER_HOME__|${HOME}|g" \
  -e "s|__UV_BIN__|${UV_BIN}|g" \
  -e "s|__MODEL__|${MODEL}|g" \
  -e "s|__HOST__|${HOST}|g" \
  -e "s|__PORT__|${PORT}|g" \
  "${PLIST_TEMPLATE}" > "${PLIST_DEST}"

# Reload (unload-then-load) to pick up any plist changes.
progress "STEP=starting_service"
if launchctl list | grep -q "${LABEL}"; then
  bold "→ Unloading existing agent..."
  launchctl unload "${PLIST_DEST}" || true
fi
bold "→ Loading agent..."
launchctl load "${PLIST_DEST}"

progress "STEP=done"
bold "✓ Done. mlx-lm.server should now be running on ${HOST}:${PORT}."
echo
echo "  Verify:   curl http://${HOST}:${PORT}/v1/models"
echo "  Logs:     ${LOG_DIR}/mlx.{out,err}.log"
echo "  Stop:     launchctl unload ${PLIST_DEST}"
"""##

  static let setupAPIServer: String = ##"""
#!/usr/bin/env bash
# Build & install the local Infinite Recall REST API as a launchd agent.
#
# Mirrors the mlx-lm sidecar pattern. Idempotent: re-run after rebuilds to
# bounce the agent.
#
# When invoked by the in-app installer (Swift LocalAIInstaller), the script
# emits structured `PROGRESS:` lines on stdout. In that mode the binary is
# installed into `~/Library/Application Support/InfiniteRecall/bin/` to avoid
# sudo prompts. Pass --yes / set INFINITE_RECALL_AUTO_CONFIRM=1 to opt in.
set -euo pipefail

BIN_NAME="infinite-recall-api"
PLIST_NAME="com.infiniterecall.api.plist"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$REPO_ROOT/Backend-Rust"
SOURCE_PLIST="$REPO_ROOT/scripts/$PLIST_NAME"
TARGET_PLIST="$LAUNCH_DIR/$PLIST_NAME"

# Non-interactive mode for the in-app installer.
AUTO_CONFIRM="${INFINITE_RECALL_AUTO_CONFIRM:-0}"
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_CONFIRM=1 ;;
  esac
done

# When running headless from the app, install to user dir (no sudo).
if [ "${AUTO_CONFIRM}" = "1" ]; then
    INSTALL_DIR="$HOME/Library/Application Support/InfiniteRecall/bin"
else
    INSTALL_DIR="/usr/local/bin"
fi

progress() { printf "PROGRESS:%s\n" "$1"; }

progress "STEP=checking_prereqs"
if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo not found on PATH. Install Rust toolchain via https://rustup.rs/" >&2
    exit 1
fi

progress "STEP=installing_mlx"  # reuse the "build" slot in the UI
echo "==> Building $BIN_NAME (release)"
( cd "$CRATE_DIR" && cargo build --release )

BUILT="$CRATE_DIR/target/release/$BIN_NAME"
if [[ ! -x "$BUILT" ]]; then
    echo "ERROR: build did not produce $BUILT" >&2
    exit 1
fi

progress "STEP=installing_launchd"
echo "==> Installing $BIN_NAME to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if [ "${AUTO_CONFIRM}" = "1" ]; then
    install -m 0755 "$BUILT" "$INSTALL_DIR/$BIN_NAME"
else
    sudo install -m 0755 "$BUILT" "$INSTALL_DIR/$BIN_NAME"
fi

echo "==> Installing launchd plist to $TARGET_PLIST"
mkdir -p "$LAUNCH_DIR"
# Render the plist with the actual binary path (so user-dir installs work).
sed -e "s|/usr/local/bin/${BIN_NAME}|${INSTALL_DIR}/${BIN_NAME}|g" \
    "$SOURCE_PLIST" > "$TARGET_PLIST"

# Reload (unload if present, then load). Tolerate missing.
progress "STEP=starting_service"
if launchctl list | grep -q '\bcom.infiniterecall.api\b'; then
    echo "==> Unloading existing launchd job"
    launchctl unload "$TARGET_PLIST" || true
fi

echo "==> Loading launchd job"
launchctl load "$TARGET_PLIST"

progress "STEP=done"
echo
echo "==> Done. API on http://127.0.0.1:7331"
echo "    Token: $HOME/Library/Application Support/InfiniteRecall/api-token.txt"
echo "    Logs:  /tmp/infinite-recall-api.{out,err}.log"
"""##

  static let mlxLaunchdPlist: String = ##"""
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Infinite Recall — launchd agent template for mlx-lm.server.
  Placeholders are replaced by scripts/setup-mlx-server.sh:
    __USER_HOME__  -> $HOME
    __UV_BIN__     -> absolute path to `uv`
    __MODEL__      -> Hugging Face model id
    __HOST__       -> bind host (default 127.0.0.1)
    __PORT__       -> bind port (default 8080)
-->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.infiniterecall.mlx</string>

  <key>ProgramArguments</key>
  <array>
    <string>__UV_BIN__</string>
    <string>tool</string>
    <string>run</string>
    <string>--from</string>
    <string>mlx-lm</string>
    <string>mlx_lm.server</string>
    <string>--model</string>
    <string>__MODEL__</string>
    <string>--host</string>
    <string>__HOST__</string>
    <string>--port</string>
    <string>__PORT__</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>ProcessType</key>
  <string>Interactive</string>

  <key>StandardOutPath</key>
  <string>__USER_HOME__/Library/Logs/InfiniteRecall/mlx.out.log</string>

  <key>StandardErrorPath</key>
  <string>__USER_HOME__/Library/Logs/InfiniteRecall/mlx.err.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>__USER_HOME__/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
"""##

  static let setupVLMServer: String = ##"""
#!/usr/bin/env bash
# Infinite Recall — one-shot installer for the local mlx-vlm.server sidecar.
#
# This is the VISION tier (image-text-to-text) sibling of setup-mlx-server.sh.
# Runs on 127.0.0.1:8081 so it can coexist with the text tier on :8080.
#
# What this does:
#   1. Installs `uv` (fast Python tool runner) if missing.
#   2. Installs the `mlx-vlm` Python package via `uv tool install`. Distinct
#      from `mlx-lm` — they ship separate server binaries and tokenizers.
#   3. Optionally pulls the default 4-bit Qwen3-VL-8B model from Hugging Face
#      (~5–6 GB on disk; prompts unless --yes / INFINITE_RECALL_AUTO_CONFIRM=1).
#   4. Drops a launchd plist at ~/Library/LaunchAgents/com.infiniterecall.vlm.plist
#      and `launchctl load`s it so the server runs at login on 127.0.0.1:8081.
#
# Model override (highest priority wins):
#   --model <hf-path>            CLI flag
#   INFINITE_RECALL_VLM_MODEL=<path> env var
# Otherwise falls back to the built-in default below.
#
# Re-running is safe — every step is idempotent.
#
# When invoked by the in-app installer (Swift LocalAIInstaller), the script
# emits structured `PROGRESS:` lines on stdout that the host parses to drive
# the UI step list and the model download progress bar.

set -euo pipefail

LABEL="com.infiniterecall.vlm"
# Default VLM. Verified on huggingface.co: Apache 2.0, image-text-to-text
# pipeline tag, MLX-converted from Qwen/Qwen3-VL-8B-Instruct via mlx-vlm.
# ~5–6 GB on disk for 4-bit weights.
DEFAULT_MODEL="${INFINITE_RECALL_VLM_MODEL:-mlx-community/Qwen3-VL-8B-Instruct-4bit}"
HOST="127.0.0.1"
PORT="8081"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_TEMPLATE="${SCRIPT_DIR}/com.infiniterecall.vlm.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/InfiniteRecall"

# Non-interactive mode for the in-app installer.
AUTO_CONFIRM="${INFINITE_RECALL_AUTO_CONFIRM:-0}"
MODEL="${INFINITE_RECALL_VLM_MODEL:-${DEFAULT_MODEL}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) AUTO_CONFIRM=1; shift ;;
    --model) MODEL="$2"; shift 2 ;;
    --model=*) MODEL="${1#--model=}"; shift ;;
    *) shift ;;
  esac
done
export INFINITE_RECALL_VLM_MODEL="${MODEL}"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
warn() { printf "\033[33m%s\033[0m\n" "$1"; }
err()  { printf "\033[31m%s\033[0m\n" "$1" >&2; }
progress() { printf "PROGRESS:%s\n" "$1"; }

progress "STEP=checking_prereqs"

# ---------------------------------------------------------------------------
# 1. Install uv
# ---------------------------------------------------------------------------
progress "STEP=installing_uv"
if ! command -v uv >/dev/null 2>&1; then
  bold "→ Installing uv (Python tool runner)..."
  if command -v brew >/dev/null 2>&1; then
    brew install uv
  else
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
else
  bold "✓ uv already installed: $(uv --version)"
fi

UV_BIN="$(command -v uv)"
if [ -z "${UV_BIN}" ]; then
  err "uv install seemed to succeed but uv is not on PATH. Open a new shell and rerun."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Install mlx-vlm
# ---------------------------------------------------------------------------
progress "STEP=installing_mlx"
bold "→ Installing mlx-vlm via uv..."
uv tool install --upgrade mlx-vlm

# ---------------------------------------------------------------------------
# 3. Optionally download the default model
# ---------------------------------------------------------------------------
progress "STEP=downloading_model"
MODEL_CACHE_DIR="${HOME}/.cache/huggingface/hub/models--${MODEL//\//--}"
DOWNLOAD_OK=0
if [ -d "${MODEL_CACHE_DIR}" ]; then
  bold "✓ Model already present at ${MODEL_CACHE_DIR}"
  progress "DOWNLOAD_PCT=100"
  DOWNLOAD_OK=1
else
  PROCEED=0
  if [ "${AUTO_CONFIRM}" = "1" ]; then
    PROCEED=1
  else
    warn "Model: ${MODEL}"
    warn "(The default Qwen3-VL-8B 4-bit weights are ~5–6 GB.)"
    printf "Download it now? [y/N] "
    read -r REPLY
    case "${REPLY}" in
      [yY]|[yY][eE][sS]) PROCEED=1 ;;
    esac
  fi

  if [ "${PROCEED}" = "1" ]; then
    bold "→ Downloading model (this may take a while)..."
    HF_HUB_DISABLE_PROGRESS_BARS=1 \
    uv tool run --from mlx-vlm python - <<'PY'
import os, sys, threading, time, traceback
from huggingface_hub import snapshot_download, HfApi
from huggingface_hub.utils import (
    RepositoryNotFoundError,
    GatedRepoError,
    HfHubHTTPError,
)

MODEL = os.environ.get("INFINITE_RECALL_VLM_MODEL", "mlx-community/Qwen3-VL-8B-Instruct-4bit")

def emit(msg: str) -> None:
    sys.stdout.write(f"PROGRESS:{msg}\n")
    sys.stdout.flush()

try:
    info = HfApi().model_info(MODEL, files_metadata=True)
    total = sum((s.size or 0) for s in info.siblings)
except Exception:
    total = 0

cache_dir = os.path.expanduser(f"~/.cache/huggingface/hub/models--{MODEL.replace('/', '--')}")
stop = threading.Event()

def watcher():
    while not stop.is_set():
        bytes_on_disk = 0
        for root, _, files in os.walk(cache_dir):
            for f in files:
                try:
                    bytes_on_disk += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
        emit(f"DOWNLOAD_BYTES={bytes_on_disk}")
        if total:
            pct = min(99, int(bytes_on_disk * 100 / total))
            emit(f"DOWNLOAD_PCT={pct}")
        time.sleep(2)

t = threading.Thread(target=watcher, daemon=True)
t.start()
try:
    try:
        snapshot_download(MODEL)
    except RepositoryNotFoundError:
        reason = f"Repository not found: {MODEL}"
        emit(f"DOWNLOAD_FAIL={reason}")
        traceback.print_exc(file=sys.stderr)
        sys.exit(2)
    except GatedRepoError:
        reason = f"Repository is gated and requires authentication: {MODEL}"
        emit(f"DOWNLOAD_FAIL={reason}")
        traceback.print_exc(file=sys.stderr)
        sys.exit(2)
    except HfHubHTTPError as e:
        status = e.response.status_code if hasattr(e, "response") else "?"
        reason = f"Hugging Face Hub error ({status}) for {MODEL}: {e}"
        emit(f"DOWNLOAD_FAIL={reason}")
        traceback.print_exc(file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        reason = f"Download failed for {MODEL}: {type(e).__name__}: {e}"
        emit(f"DOWNLOAD_FAIL={reason}")
        traceback.print_exc(file=sys.stderr)
        sys.exit(2)
finally:
    stop.set()
    t.join(timeout=3)

emit("DOWNLOAD_PCT=100")
PY
    DOWNLOAD_OK=1
  else
    warn "Skipping model download. The launchd agent will fail to start until the model is fetched."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Install launchd plist
# ---------------------------------------------------------------------------
progress "STEP=installing_launchd"
if [ ! -f "${PLIST_TEMPLATE}" ]; then
  err "Plist template missing: ${PLIST_TEMPLATE}"
  exit 1
fi

mkdir -p "$(dirname "${PLIST_DEST}")"
mkdir -p "${LOG_DIR}"

bold "→ Rendering launchd plist to ${PLIST_DEST}"
sed \
  -e "s|__USER_HOME__|${HOME}|g" \
  -e "s|__UV_BIN__|${UV_BIN}|g" \
  -e "s|__MODEL__|${MODEL}|g" \
  -e "s|__HOST__|${HOST}|g" \
  -e "s|__PORT__|${PORT}|g" \
  "${PLIST_TEMPLATE}" > "${PLIST_DEST}"

progress "STEP=starting_service"
if launchctl list | grep -q "${LABEL}"; then
  bold "→ Unloading existing agent..."
  launchctl unload "${PLIST_DEST}" || true
fi
bold "→ Loading agent..."
launchctl load "${PLIST_DEST}"

progress "STEP=done"
bold "✓ Done. mlx-vlm.server should now be running on ${HOST}:${PORT}."
echo
echo "  Verify:   curl http://${HOST}:${PORT}/v1/models"
echo "  Logs:     ${LOG_DIR}/vlm.{out,err}.log"
echo "  Stop:     launchctl unload ${PLIST_DEST}"
"""##

  static let vlmLaunchdPlist: String = ##"""
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Infinite Recall — launchd agent template for mlx-vlm.server (vision tier).
  Placeholders are replaced by scripts/setup-vlm-server.sh:
    __USER_HOME__  -> $HOME
    __UV_BIN__     -> absolute path to `uv`
    __MODEL__      -> Hugging Face model id
    __HOST__       -> bind host (default 127.0.0.1)
    __PORT__       -> bind port (default 8081)
-->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.infiniterecall.vlm</string>

  <key>ProgramArguments</key>
  <array>
    <string>__UV_BIN__</string>
    <string>tool</string>
    <string>run</string>
    <string>--from</string>
    <string>mlx-vlm</string>
    <string>mlx_vlm.server</string>
    <string>--model</string>
    <string>__MODEL__</string>
    <string>--host</string>
    <string>__HOST__</string>
    <string>--port</string>
    <string>__PORT__</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>ProcessType</key>
  <string>Interactive</string>

  <key>StandardOutPath</key>
  <string>__USER_HOME__/Library/Logs/InfiniteRecall/vlm.out.log</string>

  <key>StandardErrorPath</key>
  <string>__USER_HOME__/Library/Logs/InfiniteRecall/vlm.err.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>__USER_HOME__/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
"""##

  static let apiLaunchdPlist: String = ##"""
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.infiniterecall.api</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/infinite-recall-api</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>RUST_LOG</key>
        <string>info,infinite_recall_api=info</string>
        <key>INFINITE_RECALL_BIND</key>
        <string>127.0.0.1:7331</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/infinite-recall-api.out.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/infinite-recall-api.err.log</string>

    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
"""##
}
