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
