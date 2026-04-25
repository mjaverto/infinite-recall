#!/usr/bin/env bash
# Build & install the local Infinite Recall REST API as a launchd agent.
#
# Mirrors the mlx-lm sidecar pattern. Idempotent: re-run after rebuilds to
# bounce the agent.
set -euo pipefail

BIN_NAME="infinite-recall-api"
INSTALL_DIR="/usr/local/bin"
PLIST_NAME="com.infiniterecall.api.plist"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$REPO_ROOT/Backend-Rust"
SOURCE_PLIST="$REPO_ROOT/scripts/$PLIST_NAME"
TARGET_PLIST="$LAUNCH_DIR/$PLIST_NAME"

echo "==> Building $BIN_NAME (release)"
( cd "$CRATE_DIR" && cargo build --release )

BUILT="$CRATE_DIR/target/release/$BIN_NAME"
if [[ ! -x "$BUILT" ]]; then
    echo "ERROR: build did not produce $BUILT" >&2
    exit 1
fi

echo "==> Installing $BIN_NAME to $INSTALL_DIR (sudo)"
sudo install -m 0755 "$BUILT" "$INSTALL_DIR/$BIN_NAME"

echo "==> Installing launchd plist to $TARGET_PLIST"
mkdir -p "$LAUNCH_DIR"
cp "$SOURCE_PLIST" "$TARGET_PLIST"

# Reload (unload if present, then load). Tolerate missing.
if launchctl list | grep -q '\bcom.infiniterecall.api\b'; then
    echo "==> Unloading existing launchd job"
    launchctl unload "$TARGET_PLIST" || true
fi

echo "==> Loading launchd job"
launchctl load "$TARGET_PLIST"

echo
echo "==> Done. API on http://127.0.0.1:7331"
echo "    Token: $HOME/Library/Application Support/InfiniteRecall/api-token.txt"
echo "    Logs:  /tmp/infinite-recall-api.{out,err}.log"
