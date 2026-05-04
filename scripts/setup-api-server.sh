#!/usr/bin/env bash
# Build & install the local Infinite Recall REST API as a launchd agent.
#
# Mirrors the mlx-lm sidecar pattern. Idempotent: re-run after rebuilds.
#
# When invoked by the in-app installer (Swift LocalAIInstaller), the script
# emits structured `PROGRESS:` lines on stdout. The binary always installs
# to `/usr/local/bin/` — never inside ~/Library/Application Support/ — so a
# wipe of app state (schema migration, manual reset, etc.) does not delete
# the daemon binary out from under launchd. Pass --yes /
# INFINITE_RECALL_AUTO_CONFIRM=1 to skip the sudo prompt confirmation.
set -euo pipefail

# Emit a `failed` step on any early exit so the calling Swift LocalAIInstaller
# stops waiting for a "done" message and surfaces the error to the user.
trap 'rc=$?; if [ $rc -ne 0 ]; then printf "PROGRESS:STEP=failed\n"; fi' EXIT

BIN_NAME="infinite-recall-api"
CLI_BIN_NAME="recall"
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

INSTALL_DIR="/usr/local/bin"

progress() { printf "PROGRESS:%s\n" "$1"; }

# Headless safety: if AUTO_CONFIRM=1 and we'd need sudo but sudo would
# prompt, fail loudly instead of hanging the in-app installer on a TTY
# password prompt that nobody can see.
if [ "$AUTO_CONFIRM" = "1" ] && [ ! -w "$INSTALL_DIR" ] && ! sudo -n true 2>/dev/null; then
    progress "STEP=needs_sudo"
    echo "ERROR: $INSTALL_DIR not writable and sudo would prompt — re-run with passwordless sudo arranged" >&2
    exit 2
fi

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

BUILT_CLI="$CRATE_DIR/target/release/$CLI_BIN_NAME"
if [[ ! -x "$BUILT_CLI" ]]; then
    echo "ERROR: build did not produce $BUILT_CLI" >&2
    exit 1
fi

progress "STEP=installing_launchd"
echo "==> Installing $BIN_NAME to $INSTALL_DIR"
if [ -w "$INSTALL_DIR" ]; then
    INSTALL="install"
else
    INSTALL="sudo install"
fi
$INSTALL -d -m 0755 "$INSTALL_DIR"
$INSTALL -m 0755 "$BUILT" "$INSTALL_DIR/$BIN_NAME"
$INSTALL -m 0755 "$BUILT_CLI" "$INSTALL_DIR/$CLI_BIN_NAME"
echo "==> Installed $CLI_BIN_NAME to $INSTALL_DIR/$CLI_BIN_NAME"

echo "==> Installing launchd plist to $TARGET_PLIST"
mkdir -p "$LAUNCH_DIR"
install -m 0644 "$SOURCE_PLIST" "$TARGET_PLIST"

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
