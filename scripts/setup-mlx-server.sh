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
DEFAULT_MODEL="mlx-community/Qwen2.5-7B-Instruct-4bit"
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
import os, sys, threading, time
from huggingface_hub import snapshot_download, HfApi

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
    snapshot_download(MODEL)
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
