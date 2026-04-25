#!/usr/bin/env bash
# Infinite Recall — one-shot installer for the local mlx-lm.server sidecar.
#
# What this does:
#   1. Installs `uv` (fast Python tool runner) if missing.
#   2. Installs the `mlx-lm` Python package via `uv tool install`.
#   3. Optionally pulls the default 4-bit Qwen 32B model from Hugging Face
#      (~18 GB on disk — prompts before downloading).
#   4. Drops a launchd plist at ~/Library/LaunchAgents/com.infiniterecall.mlx.plist
#      and `launchctl load`s it so the server runs at login on 127.0.0.1:8080.
#
# Re-running is safe — every step is idempotent.

set -euo pipefail

LABEL="com.infiniterecall.mlx"
DEFAULT_MODEL="mlx-community/Qwen2.5-32B-Instruct-4bit"
HOST="127.0.0.1"
PORT="8080"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_TEMPLATE="${SCRIPT_DIR}/com.infiniterecall.mlx.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/InfiniteRecall"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
warn() { printf "\033[33m%s\033[0m\n" "$1"; }
err()  { printf "\033[31m%s\033[0m\n" "$1" >&2; }

# ---------------------------------------------------------------------------
# 1. Install uv
# ---------------------------------------------------------------------------
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
bold "→ Installing mlx-lm via uv..."
uv tool install --upgrade mlx-lm

# ---------------------------------------------------------------------------
# 3. Optionally download the default model
# ---------------------------------------------------------------------------
MODEL_CACHE_DIR="${HOME}/.cache/huggingface/hub/models--${DEFAULT_MODEL//\//--}"
if [ -d "${MODEL_CACHE_DIR}" ]; then
  bold "✓ Model already present at ${MODEL_CACHE_DIR}"
else
  warn "The default model is ~18 GB on disk."
  warn "Model: ${DEFAULT_MODEL}"
  printf "Download it now? [y/N] "
  read -r REPLY
  case "${REPLY}" in
    [yY]|[yY][eE][sS])
      bold "→ Downloading model (this may take a while)..."
      # Run via uv so we don't pollute the system Python; huggingface_hub is a
      # transitive dep of mlx-lm so it's already available in the tool env.
      uv tool run --from mlx-lm python -c \
"from huggingface_hub import snapshot_download; snapshot_download('${DEFAULT_MODEL}')"
      ;;
    *)
      warn "Skipping model download. The launchd agent will fail to start until the model is fetched."
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 4. Install launchd plist
# ---------------------------------------------------------------------------
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
  -e "s|__MODEL__|${DEFAULT_MODEL}|g" \
  -e "s|__HOST__|${HOST}|g" \
  -e "s|__PORT__|${PORT}|g" \
  "${PLIST_TEMPLATE}" > "${PLIST_DEST}"

# Reload (unload-then-load) to pick up any plist changes.
if launchctl list | grep -q "${LABEL}"; then
  bold "→ Unloading existing agent..."
  launchctl unload "${PLIST_DEST}" || true
fi
bold "→ Loading agent..."
launchctl load "${PLIST_DEST}"

bold "✓ Done. mlx-lm.server should now be running on ${HOST}:${PORT}."
echo
echo "  Verify:   curl http://${HOST}:${PORT}/v1/models"
echo "  Logs:     ${LOG_DIR}/mlx.{out,err}.log"
echo "  Stop:     launchctl unload ${PLIST_DEST}"
