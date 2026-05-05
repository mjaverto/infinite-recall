#!/bin/bash
set -e

# Ensure system tools win over user shims (e.g. pyenv shadows /usr/bin/xattr,
# and pyxattr does not support -r, which makes `xattr -cr` abort under set -e).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# ─── Help ──────────────────────────────────────────────────────────────
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'USAGE'
Usage: ./run.sh [options]

Build and run the Omi Desktop dev app with local backend services.

Options (via environment variables):
  IR_SKIP_BACKEND=1      Skip starting Rust backend (use remote backend via IR_API_URL)
  IR_SKIP_AUTH=1          Skip starting Python auth service (use remote auth via IR_AUTH_URL)
  IR_SKIP_TUNNEL=1        Skip Cloudflare tunnel (use IR_API_URL from .env directly)
  AUTH_PORT=10200           Auth service port (default: 10200)
  PORT=7331                 Rust backend port (default: 7331, never use 8080)
  IR_APP_NAME="Infinite Recall Dev"   Optional app name override (default: "Infinite Recall")
  IR_PYTHON_API_URL="..."  Python backend URL (subscriptions, payments, etc; default: https://api.omi.me)
  IR_SIGN_IDENTITY="..."  Code signing identity (auto-detected if not set)
  IR_ENABLE_LOCAL_AUTOMATION=1  Enable agent-swift automation bridge
  IR_ENABLE_APPLE_SIGNIN=1  Opt into Sign in with Apple entitlement (requires profile)
  IR_PROVISIONING_PROFILE=/path/to/profile.provisionprofile
                            Profile to embed when IR_ENABLE_APPLE_SIGNIN=1

Required files:
  Backend-Rust/.env         Environment variables (copy from ../.env.example)
  Backend-Rust/google-credentials.json  GCP service account key

Required tools:
  cargo, xcrun/swift, python3, npm, node, codesign, cloudflared (unless skipped)

Port allocation (avoid 8080 to prevent port conflicts):
  Auth default: 10200    Backend default: 7331

Examples:
  ./run.sh                                  # Full local dev (backend + auth + tunnel + app)
  IR_SKIP_BACKEND=1 IR_SKIP_AUTH=1 ./run.sh  # App only (backend running elsewhere)
  IR_SKIP_TUNNEL=1 ./run.sh                # No Cloudflare tunnel (use direct URL)
  ./run.sh --yolo                            # Quick start: use prod backend, no local services
USAGE
    exit 0
fi

# ─── YOLO mode: quick start, skip all local services ─────────────────
# Local-only fork — no cloud calls happen even if envs are set.
# Skips local Rust backend, auth, and tunnel; uses stubbed paths only.
if [ "$1" = "--yolo" ]; then
    echo ""
    echo "=========================================="
    echo "  YOLO MODE — local-only quick start"
    echo "=========================================="
    echo ""
    echo "  Quick start: skip local backend/auth/tunnel and use"
    echo "  stubbed paths. Local-only fork — no cloud calls happen"
    echo "  even if envs are set."
    echo ""
    echo "=========================================="
    echo ""

    export IR_SKIP_BACKEND=1
    export IR_SKIP_AUTH=1
    export IR_SKIP_TUNNEL=1
    export IR_API_URL="http://127.0.0.1:7331"          # local Backend-Rust default
    export IR_PYTHON_API_URL=""
    export IR_AUTH_URL=""                               # auth is stubbed in this fork
    export FIREBASE_API_KEY=""                           # Firebase is dormant (not initialized)
fi

# Clear system OPENAI_API_KEY so .env takes precedence
unset OPENAI_API_KEY

# Use Xcode's default toolchain to match the SDK version
unset TOOLCHAINS

# Timing utilities
SCRIPT_START_TIME=$(date +%s.%N)
STEP_START_TIME=$SCRIPT_START_TIME

TEMP_FILES=()
BACKEND_PID=""
AUTH_PID=""
TUNNEL_PID=""

cleanup() {
    if [ -n "${TUNNEL_PID:-}" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo "Stopping tunnel (PID: $TUNNEL_PID)..."
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
    if [ -n "${AUTH_PID:-}" ] && kill -0 "$AUTH_PID" 2>/dev/null; then
        echo "Stopping auth service (PID: $AUTH_PID)..."
        kill "$AUTH_PID" 2>/dev/null || true
    fi
    if [ -n "${BACKEND_PID:-}" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "Stopping backend (PID: $BACKEND_PID)..."
        kill "$BACKEND_PID" 2>/dev/null || true
    fi
    if [ "${#TEMP_FILES[@]}" -gt 0 ]; then
        rm -f "${TEMP_FILES[@]}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

step() {
    local now=$(date +%s.%N)
    local step_elapsed=$(echo "$now - $STEP_START_TIME" | bc)
    local total_elapsed=$(echo "$now - $SCRIPT_START_TIME" | bc)
    if [ "$STEP_START_TIME" != "$SCRIPT_START_TIME" ]; then
        printf "  └─ done (%.2fs)\n" "$step_elapsed"
    fi
    STEP_START_TIME=$now
    printf "[%6.1fs] %s\n" "$total_elapsed" "$1"
}

substep() {
    local now=$(date +%s.%N)
    local total_elapsed=$(echo "$now - $SCRIPT_START_TIME" | bc)
    printf "[%6.1fs]   ├─ %s\n" "$total_elapsed" "$1"
}

is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

migrate_stale_backend_env() {
    # Heal Backend-Rust/.env files written from the pre-#73 template, where the
    # default port was 10201 (Omi-fork era). Those values get auto-exported by
    # the surrounding `set -a; source ...; set +a` and then propagate into the
    # bundled app's .env (see ~line 879), reproducing the dead-port symptom
    # ("snapshot failed: Could not connect to the server").
    local env_file="$1"
    [ -f "$env_file" ] || return 0
    local migrated=0
    # IR_API_URL=http://host:10201 (with optional trailing path/whitespace).
    # Use BSD-sed-friendly patterns: anchor on the literal value boundaries
    # rather than alternation groups.
    if grep -qE '^IR_API_URL=.*:10201([^0-9]|$)' "$env_file"; then
        sed -i '' -E 's|^(IR_API_URL=.*):10201$|\1:7331|' "$env_file"
        sed -i '' -E 's|^(IR_API_URL=.*):10201([^0-9])|\1:7331\2|' "$env_file"
        migrated=1
    fi
    if grep -qE '^PORT=10201[[:space:]]*$' "$env_file"; then
        sed -i '' -E 's|^PORT=10201[[:space:]]*$|PORT=7331|' "$env_file"
        migrated=1
    fi
    if [ "$migrated" = "1" ]; then
        substep "Migrated stale port 10201 -> 7331 in $env_file (Omi-fork era default)"
    fi
}

warn_if_daemon_stale() {
    local installed="$HOME/Library/Application Support/InfiniteRecall/bin/infinite-recall-api"
    local src_dir
    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/Backend-Rust" 2>/dev/null && pwd)"
    [ -x "$installed" ] || return 0
    [ -d "$src_dir" ] || return 0
    local newer
    newer=$(find "$src_dir" \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' \) -type f -newer "$installed" -print 2>/dev/null)
    [ -n "$newer" ] || return 0
    {
        echo ""
        echo "=========================================="
        echo "  WARNING: stale launchd daemon detected"
        echo "=========================================="
        echo "  IR_SKIP_BACKEND=1 is set, but the installed daemon at"
        echo "    $installed"
        echo "  is older than Backend-Rust/ source files. New routes (e.g."
        echo "  /v1/activity/snapshot) will 404 until you reinstall."
        echo ""
        echo "  Newer source files:"
        printf '%s\n' "$newer" | head -3 | sed 's/^/    /'
        echo ""
        echo "  Fix:  ./scripts/setup-api-server.sh --yes"
        echo "=========================================="
        echo ""
    } >&2
}

make_temp_file() {
    local var_name="$1"
    local template="$2"
    local file
    file="$(mktemp "${TMPDIR:-/tmp}/${template}.XXXXXX")" || exit 1
    TEMP_FILES+=("$file")
    printf -v "$var_name" '%s' "$file"
}

plist_set_string() {
    local plist_path="$1"
    local key="$2"
    local value="$3"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist_path" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist_path"
}

make_local_dev_entitlements() {
    local source="$1"
    local dest="$2"
    cp "$source" "$dest"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.applesignin" "$dest" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$dest" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$dest" 2>/dev/null || true
}

make_apple_signin_entitlements() {
    local source="$1"
    local dest="$2"
    local application_identifier="$3"
    local team_id="$4"

    cp "$source" "$dest"
    plist_set_string "$dest" "com.apple.application-identifier" "$application_identifier"
    plist_set_string "$dest" "com.apple.developer.team-identifier" "$team_id"
}

resolve_apple_signin_profile() {
    if [ -n "${IR_PROVISIONING_PROFILE:-}" ]; then
        printf '%s\n' "$IR_PROVISIONING_PROFILE"
    elif [ -f "Desktop/embedded-dev.provisionprofile" ]; then
        printf '%s\n' "Desktop/embedded-dev.provisionprofile"
    elif [ -f "Desktop/embedded.provisionprofile" ]; then
        printf '%s\n' "Desktop/embedded.provisionprofile"
    fi
    return 0
}

apple_signin_profile_error() {
    echo ""
    echo "ERROR: IR_ENABLE_APPLE_SIGNIN=1 requires a provisioning profile."
    echo "       Set IR_PROVISIONING_PROFILE=/path/to/profile.provisionprofile"
    echo "       or add Desktop/embedded-dev.provisionprofile."
    echo ""
    echo "       For normal local development, unset IR_ENABLE_APPLE_SIGNIN;"
    echo "       ./run.sh --yolo will sign with local/dev entitlements instead."
    echo ""
}

resolve_sign_identity() {
    if [ -n "$SIGN_IDENTITY" ]; then
        return 0
    fi

    # For dev builds: prefer Apple Development (matches Mac Development provisioning profile,
    # required for native Sign In with Apple). Fall back to Developer ID if unavailable.
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
    if [ -z "$SIGN_IDENTITY" ]; then
        SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
    fi
}

resolve_sign_identity_team_id() {
    local identity="$1"
    local line=""
    local identity_hash=""
    local identity_name=""
    local team_id=""

    while IFS= read -r line; do
        identity_hash=$(printf '%s\n' "$line" | awk '{print $2}')
        identity_name=$(printf '%s\n' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')
        if [ "$identity" = "$identity_hash" ] || [ "$identity" = "$identity_name" ]; then
            team_id=$(printf '%s\n' "$identity_name" | sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\)).*/\1/p')
            if [ -n "$team_id" ]; then
                printf '%s\n' "$team_id"
                return 0
            fi
        fi
    done < <(security find-identity -v -p codesigning 2>/dev/null || true)

    printf '%s\n' "$identity" | sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\)).*/\1/p'
}

resolve_sign_identity_sha1() {
    local identity="$1"
    local line=""
    local identity_hash=""
    local identity_name=""

    while IFS= read -r line; do
        identity_hash=$(printf '%s\n' "$line" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
        identity_name=$(printf '%s\n' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')
        if [ "$identity" = "$identity_hash" ] || [ "$(printf '%s' "$identity" | tr '[:lower:]' '[:upper:]')" = "$identity_hash" ] || [ "$identity" = "$identity_name" ]; then
            printf '%s\n' "$identity_hash"
            return 0
        fi
    done < <(security find-identity -v -p codesigning 2>/dev/null || true)
}

sign_identity_error() {
    echo ""
    echo "ERROR: No signing identity found. Ad-hoc signing causes macOS to reset"
    echo "       Screen Recording permissions for ALL Omi apps (including prod/beta)."
    echo ""
    echo "  Fix: Install an Apple Development certificate in Keychain Access,"
    echo "       or set IR_SIGN_IDENTITY to a valid identity:"
    echo "       IR_SIGN_IDENTITY=\"Apple Development: you@example.com\" ./run.sh"
    echo ""
}

validate_apple_signin_profile() {
    local profile_path="$1"
    local profile_plist=""
    local profile_decode_error=""
    local profile_validation_info=""
    local identity_team_id=""
    local identity_sha1=""
    local tab=""
    local key=""
    local value=""

    make_temp_file profile_plist "omi-dev-profile"
    make_temp_file profile_decode_error "omi-dev-profile-decode-error"
    make_temp_file profile_validation_info "omi-dev-profile-info"

    identity_team_id=$(resolve_sign_identity_team_id "$SIGN_IDENTITY")
    if [ -z "$identity_team_id" ]; then
        echo "ERROR: IR_ENABLE_APPLE_SIGNIN=1 could not determine the signing identity team ID for: $SIGN_IDENTITY"
        exit 1
    fi
    identity_sha1=$(resolve_sign_identity_sha1 "$SIGN_IDENTITY")
    if [ -z "$identity_sha1" ]; then
        echo "ERROR: IR_ENABLE_APPLE_SIGNIN=1 could not determine the signing identity certificate SHA-1 for: $SIGN_IDENTITY"
        exit 1
    fi

    if ! security cms -D -i "$profile_path" > "$profile_plist" 2>"$profile_decode_error"; then
        echo "ERROR: IR_ENABLE_APPLE_SIGNIN=1 but provisioning profile could not be decoded with security cms -D: $profile_path"
        if [ -s "$profile_decode_error" ]; then
            sed 's/^/       /' "$profile_decode_error"
        fi
        exit 1
    fi

    if ! python3 - "$profile_path" "$profile_plist" "$BUNDLE_ID" "$identity_team_id" "$identity_sha1" > "$profile_validation_info" <<'PY'
from datetime import datetime, timezone
import hashlib
import plistlib
import sys

profile_path, plist_path, bundle_id, identity_team_id, identity_sha1 = sys.argv[1:6]


def fail(message):
    print(f"ERROR: IR_ENABLE_APPLE_SIGNIN=1 {message}", file=sys.stderr)
    sys.exit(1)


def normalized_string_list(value):
    if isinstance(value, str):
        return [value] if value else []
    if isinstance(value, (list, tuple)):
        return [item for item in value if isinstance(item, str) and item]
    return []


def csv(values):
    return ", ".join(values) if values else "<none>"


def bundle_matches_profile_pattern(pattern, actual_bundle_id):
    if pattern == actual_bundle_id:
        return True
    if "*" not in pattern:
        return False
    # Apple wildcard App IDs are suffix wildcards, e.g. TEAMID.* or TEAMID.com.example.*.
    # Treat other wildcard placements as invalid rather than over-matching.
    if pattern == "*":
        return True
    if not pattern.endswith("*"):
        return False
    prefix = pattern[:-1]
    return actual_bundle_id.startswith(prefix) and len(actual_bundle_id) > len(prefix)

try:
    with open(plist_path, "rb") as fh:
        profile = plistlib.load(fh)
except Exception as exc:
    fail(f"profile decoded from {profile_path!r} is not a valid plist: {exc}")

team_ids = normalized_string_list(profile.get("TeamIdentifier"))
if not team_ids:
    fail("profile is missing a valid TeamIdentifier array")
team_ids = list(dict.fromkeys(team_ids))

expiration = profile.get("ExpirationDate")
if not isinstance(expiration, datetime):
    fail("profile is missing a valid ExpirationDate")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=timezone.utc)
if expiration <= datetime.now(timezone.utc):
    fail(f"profile expired at {expiration.isoformat()}")

developer_certs = profile.get("DeveloperCertificates")
if not isinstance(developer_certs, list) or not developer_certs:
    fail("profile is missing DeveloperCertificates")
profile_cert_sha1s = []
for cert in developer_certs:
    if hasattr(cert, "data"):
        cert = cert.data
    if not isinstance(cert, bytes):
        fail("profile DeveloperCertificates contains a non-certificate entry")
    profile_cert_sha1s.append(hashlib.sha1(cert).hexdigest().upper())
if identity_sha1.upper() not in profile_cert_sha1s:
    fail(
        "profile DeveloperCertificates do not include signing identity certificate "
        f"({identity_sha1.upper()})"
    )

entitlements = profile.get("Entitlements")
if not isinstance(entitlements, dict):
    fail("profile is missing an Entitlements dictionary")

application_identifier = (
    entitlements.get("com.apple.application-identifier")
    or entitlements.get("application-identifier")
)
if not isinstance(application_identifier, str) or "." not in application_identifier:
    fail("profile is missing a valid Entitlements application identifier")

application_team_id, bundle_pattern = application_identifier.split(".", 1)
team_identifier_entitlement = entitlements.get("com.apple.developer.team-identifier")
apple_signin_values = normalized_string_list(entitlements.get("com.apple.developer.applesignin"))

if identity_team_id not in team_ids:
    fail(
        "profile TeamIdentifier entries "
        f"({csv(team_ids)}) do not include signing identity team ({identity_team_id})"
    )
if application_team_id != identity_team_id:
    fail(
        "profile application identifier team "
        f"({application_team_id}) does not match signing identity team ({identity_team_id})"
    )
if application_team_id not in team_ids:
    fail(
        "profile application identifier team "
        f"({application_team_id}) is not present in TeamIdentifier ({csv(team_ids)})"
    )
if isinstance(team_identifier_entitlement, str) and team_identifier_entitlement != identity_team_id:
    fail(
        "profile com.apple.developer.team-identifier "
        f"({team_identifier_entitlement}) does not match signing identity team ({identity_team_id})"
    )
if "Default" not in apple_signin_values:
    fail(
        "profile Entitlements must include com.apple.developer.applesignin with Default "
        f"(got {csv(apple_signin_values)})"
    )
if not bundle_matches_profile_pattern(bundle_pattern, bundle_id):
    fail(
        "profile application identifier "
        f"({application_identifier}) does not match bundle id ({bundle_id})"
    )

print(f"PROFILE_TEAM_ID\t{identity_team_id}")
print(f"PROFILE_APPLICATION_IDENTIFIER\t{application_identifier}")
print(f"SIGNED_APPLICATION_IDENTIFIER\t{identity_team_id}.{bundle_id}")
PY
    then
        exit 1
    fi

    tab=$(printf '\t')
    while IFS="$tab" read -r key value; do
        case "$key" in
            PROFILE_TEAM_ID) APPLE_SIGNIN_PROFILE_TEAM_ID="$value" ;;
            PROFILE_APPLICATION_IDENTIFIER) APPLE_SIGNIN_PROFILE_APP_IDENTIFIER="$value" ;;
            SIGNED_APPLICATION_IDENTIFIER) APPLE_SIGNIN_SIGNED_APP_IDENTIFIER="$value" ;;
        esac
    done < "$profile_validation_info"

    if [ -z "$APPLE_SIGNIN_PROFILE_TEAM_ID" ] || [ -z "$APPLE_SIGNIN_SIGNED_APP_IDENTIFIER" ]; then
        echo "ERROR: IR_ENABLE_APPLE_SIGNIN=1 failed to extract required entitlements from: $profile_path"
        exit 1
    fi
}

# App configuration
BINARY_NAME="Omi Computer"  # Package.swift target — binary paths, pkill, CFBundleExecutable
APP_NAME="${IR_APP_NAME:-Infinite Recall}"
IS_NAMED_BUNDLE=false
[ -n "${IR_APP_NAME:-}" ] && IS_NAMED_BUNDLE=true

slugify_identifier() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

if [ "$IS_NAMED_BUNDLE" = false ]; then
    EXPECTED_BUNDLE_ID="com.omi.desktop-dev"
    EXPECTED_URL_SCHEME="omi-computer-dev"
else
    APP_SLUG="$(slugify_identifier "$APP_NAME")"
    if [ -z "$APP_SLUG" ]; then
        echo "ERROR: IR_APP_NAME must contain at least one letter or number"
        exit 1
    fi
    EXPECTED_BUNDLE_ID="com.omi.$APP_SLUG"
    EXPECTED_URL_SCHEME="omi-$APP_SLUG"
fi

BUNDLE_ID="${IR_BUNDLE_ID:-$EXPECTED_BUNDLE_ID}"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_PATH="/Applications/$APP_NAME.app"
APP_DESKTOP_PATH="$HOME/Desktop/$APP_NAME.app"
APP_DOWNLOADS_PATH="$HOME/Downloads/$APP_NAME.app"
SIGN_IDENTITY="${IR_SIGN_IDENTITY:-}"
URL_SCHEME="${IR_URL_SCHEME:-$EXPECTED_URL_SCHEME}"
ENABLE_APPLE_SIGNIN=false
is_truthy "${IR_ENABLE_APPLE_SIGNIN:-0}" && ENABLE_APPLE_SIGNIN=true
APPLE_SIGNIN_PROFILE_SOURCE=""
APPLE_SIGNIN_PROFILE_TEAM_ID=""
APPLE_SIGNIN_PROFILE_APP_IDENTIFIER=""
APPLE_SIGNIN_SIGNED_APP_IDENTIFIER=""
if [ "$ENABLE_APPLE_SIGNIN" = true ]; then
    APPLE_SIGNIN_PROFILE_SOURCE="$(resolve_apple_signin_profile)"
    if [ -z "$APPLE_SIGNIN_PROFILE_SOURCE" ] || [ ! -f "$APPLE_SIGNIN_PROFILE_SOURCE" ]; then
        apple_signin_profile_error
        exit 1
    fi
fi

if [ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
    echo "ERROR: APP_NAME '$APP_NAME' must use bundle ID '$EXPECTED_BUNDLE_ID' (got '$BUNDLE_ID')"
    exit 1
fi

if [ "$URL_SCHEME" != "$EXPECTED_URL_SCHEME" ]; then
    echo "ERROR: APP_NAME '$APP_NAME' must use URL scheme '$EXPECTED_URL_SCHEME' (got '$URL_SCHEME')"
    exit 1
fi

# Resolve signing identity before expensive backend/build/bundle work so opt-in
# provisioning profile issues fail fast.
resolve_sign_identity
if [ -z "$SIGN_IDENTITY" ]; then
    sign_identity_error
    exit 1
fi
if [ "$ENABLE_APPLE_SIGNIN" = true ]; then
    validate_apple_signin_profile "$APPLE_SIGNIN_PROFILE_SOURCE"
fi

AUTOMATION_ARGS=()
if [ "${IR_ENABLE_LOCAL_AUTOMATION:-0}" = "1" ]; then
    AUTOMATION_PORT="${IR_AUTOMATION_PORT:-47777}"
    AUTOMATION_ARGS+=(--automation-bridge "--automation-port=$AUTOMATION_PORT")
fi

# Backend configuration (Rust)
BACKEND_DIR="$(cd "$(dirname "$0")/Backend-Rust" && pwd)"
AUTH_DIR="$(cd "$(dirname "$0")/Auth-Python" && pwd)"
TUNNEL_URL="${TUNNEL_URL:-}"
AUTH_PORT="${AUTH_PORT:-10200}"

AUTH_DEBUG_LOG=/private/tmp/auth-debug.log
rm -f $AUTH_DEBUG_LOG
auth_debug() { echo "[AUTH DEBUG][$(date +%H:%M:%S)] $1" >> $AUTH_DEBUG_LOG; }
touch $AUTH_DEBUG_LOG

step "Killing existing instances..."
auth_debug "BEFORE pkill: auth_isSignedIn=$(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"
auth_debug "BEFORE pkill: ALL_KEYS=$(defaults read "$BUNDLE_ID" 2>&1 | grep -E 'auth_|hasCompleted|hasLaunched|currentTier|userShow' || true)"
# Only kill the dev app — never touch Omi Beta (production)
pkill -f "$APP_NAME.app" 2>/dev/null || true
# Note: don't pkill cloudflared here — other agents may have tunnels running on this machine
# Kill any old Rust backend by process name (port-agnostic)
pgrep -f "omi-desktop-backend" 2>/dev/null | while read pid; do
    substep "Killing old backend (PID: $pid)"
    kill -9 "$pid" 2>/dev/null || true
done
sleep 0.5  # Let cfprefsd flush after process death
auth_debug "AFTER pkill: auth_isSignedIn=$(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"
auth_debug "AFTER pkill: ALL_KEYS=$(defaults read "$BUNDLE_ID" 2>&1 | grep -E 'auth_|hasCompleted|hasLaunched|currentTier|userShow' || true)"

# Clear log file for fresh run (must be before backend starts)
rm -f /tmp/omi-dev.log 2>/dev/null || true

step "Cleaning up conflicting app bundles..."
# Clean old build names from local build dir
rm -rf "$BUILD_DIR/Omi Computer.app" 2>/dev/null
rm -rf "$APP_BUNDLE" 2>/dev/null
CONFLICTING_APPS=(
    "$APP_PATH"
    "$APP_DESKTOP_PATH"
    "$APP_DOWNLOADS_PATH"
    "$(dirname "$0")/../app/build/macos/Build/Products/Debug/Omi.app"
    "$(dirname "$0")/../app/build/macos/Build/Products/Release/Omi.app"
)
for app in "${CONFLICTING_APPS[@]}"; do
    if [ -d "$app" ]; then
        substep "Removing: $app"
        rm -rf "$app"
    fi
done
# Also remove any stale dev app bundles nested inside Flutter builds.
find "$(dirname "$0")/../app/build" -name "$APP_NAME.app" -type d -exec rm -rf {} + 2>/dev/null || true
# Kill stale app bundles from other repo clones (e.g. ~/omi-desktop/)
# These confuse LaunchServices and get launched instead of the /Applications copy.
find "$HOME" -maxdepth 4 -name "$APP_NAME.app" -type d -not -path "$APP_BUNDLE" -not -path "$APP_PATH" 2>/dev/null | while read stale; do
    substep "Removing stale clone: $stale"
    rm -rf "$stale"
done

if [ "${IR_SKIP_TUNNEL:-0}" != "1" ]; then
    step "Starting Cloudflare quick tunnel..."
    if command -v cloudflared >/dev/null 2>&1; then
        TUNNEL_LOG=$(mktemp /tmp/cloudflared-XXXXXX.log)
        cloudflared tunnel --url http://localhost:${BACKEND_PORT:-8080} > "$TUNNEL_LOG" 2>&1 &
        TUNNEL_PID=$!
        for i in {1..20}; do
            TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1)
            if [ -n "$TUNNEL_URL" ]; then break; fi
            sleep 0.5
        done
        if [ -n "$TUNNEL_URL" ]; then
            rm -f "$TUNNEL_LOG"
            substep "Tunnel URL: $TUNNEL_URL"
        else
            substep "Warning: Could not capture tunnel URL (see $TUNNEL_LOG for details)"
        fi
    else
        substep "cloudflared not found — skipping tunnel (set IR_API_URL in .env instead)"
    fi
else
    substep "Skipping tunnel (IR_SKIP_TUNNEL=1)"
fi

# ─── Load .env and credentials ─────────────────────────────────────────
cd "$BACKEND_DIR"

# Copy .env if not present — try sibling dirs, then scaffold from .env.example
if [ ! -f ".env" ] && [ -f "../backend/.env" ]; then
    cp "../backend/.env" ".env"
elif [ ! -f ".env" ] && [ -f "../Backend/.env" ]; then
    cp "../Backend/.env" ".env"
fi
if [ ! -f ".env" ] && [ "$1" != "--yolo" ]; then
    echo ""
    echo "=== First-time setup ==="
    echo "No .env file found at $BACKEND_DIR/.env"
    echo ""
    echo "Quick start:"
    echo "  1. cp .env.example .env"
    echo "  2. Fill in required values (see comments in .env.example)"
    echo "  3. Place google-credentials.json in $BACKEND_DIR/"
    echo "     (GCP service account key with Firestore + Firebase Auth access)"
    echo ""
    echo "Minimal .env for local dev:"
    echo "  PORT=7331"
    echo "  FIREBASE_PROJECT_ID=based-hardware-dev"
    echo "  FIREBASE_API_KEY=<from GCP console>"
    echo "  GOOGLE_APPLICATION_CREDENTIALS=./google-credentials.json"
    echo ""
    echo "Or skip the backend entirely:"
    echo "  IR_SKIP_BACKEND=1 IR_SKIP_AUTH=1 ./run.sh"
    echo "  (set IR_API_URL and IR_AUTH_URL in .env.app to point to a remote backend)"
    echo ""
    echo "Or just use the production backend (no setup needed):"
    echo "  ./run.sh --yolo"
    echo "==========================="
    exit 1
fi

# Symlink google-credentials.json if not present
if [ ! -f "google-credentials.json" ] && [ -f "../backend/google-credentials.json" ]; then
    ln -sf "../backend/google-credentials.json" "google-credentials.json"
elif [ ! -f "google-credentials.json" ] && [ -f "../Backend/google-credentials.json" ]; then
    ln -sf "../Backend/google-credentials.json" "google-credentials.json"
fi

# Guard: reject stale OMI_* keys that would silently miss the IR_ bootstrap.
# Without this, a leftover OMI_PYTHON_API_URL=http://localhost:8080 silently falls
# through to the production default https://api.omi.me — wrong behavior, no diagnostic.
if [ -f "$BACKEND_DIR/.env" ] && grep -qE "^OMI_[A-Z]" "$BACKEND_DIR/.env"; then
    echo "ERROR: $BACKEND_DIR/.env contains legacy OMI_* keys:" >&2
    grep -E "^OMI_[A-Z][A-Z0-9_]*=" "$BACKEND_DIR/.env" | sed 's/=.*//; s/^/  /' >&2
    echo "" >&2
    echo "  These were renamed to IR_*. Update them and re-run:" >&2
    echo "    sed -i '' -E 's/^OMI_([A-Z])/IR_\\1/' $BACKEND_DIR/.env" >&2
    exit 1
fi

# Read environment from .env (skip if missing — yolo mode doesn't need it)
if [ -f "$BACKEND_DIR/.env" ]; then
    migrate_stale_backend_env "$BACKEND_DIR/.env"
    set -a; source "$BACKEND_DIR/.env"; set +a
fi

# Read backend PORT from env (default: 7331, never use 8080)
BACKEND_PORT="${PORT:-7331}"
export PORT="$BACKEND_PORT"

# Validate credentials (needed for both backend and auth)
CREDS_PATH="$BACKEND_DIR/google-credentials.json"
if [ "${IR_SKIP_BACKEND:-0}" != "1" ] && [ ! -f "$CREDS_PATH" ]; then
    echo "ERROR: Missing credentials file: $CREDS_PATH"
    echo ""
    echo "  Option A: Place your GCP service account key here:"
    echo "    cp /path/to/google-credentials.json $CREDS_PATH"
    echo ""
    echo "  Option B: Skip the local backend and use a remote one:"
    echo "    IR_SKIP_BACKEND=1 ./run.sh"
    exit 1
fi
if [ -f "$CREDS_PATH" ]; then
    export GOOGLE_APPLICATION_CREDENTIALS="$CREDS_PATH"
fi

# Validate FIREBASE_PROJECT_ID (required unless yolo mode — no local backend)
if [ -z "$FIREBASE_PROJECT_ID" ] && [ "${IR_SKIP_BACKEND:-0}" != "1" ]; then
    echo "ERROR: FIREBASE_PROJECT_ID is not set."
    echo ""
    echo "  Add to $BACKEND_DIR/.env:"
    echo "    FIREBASE_PROJECT_ID=based-hardware       # prod Firestore"
    echo "    FIREBASE_PROJECT_ID=based-hardware-dev   # dev Firestore"
    exit 1
fi
if [ -n "$FIREBASE_AUTH_PROJECT_ID" ]; then
    substep "Auth project: tokens validated against $FIREBASE_AUTH_PROJECT_ID, Firestore on $FIREBASE_PROJECT_ID"
fi
substep "Firebase project: $FIREBASE_PROJECT_ID | Backend port: $BACKEND_PORT | Auth port: $AUTH_PORT"
cd - > /dev/null

# ─── Start Rust backend ───────────────────────────────────────────────
if [ "${IR_SKIP_BACKEND:-0}" != "1" ]; then
    step "Starting Rust backend..."
    cd "$BACKEND_DIR"

    # Build if binary doesn't exist or source is newer
    if [ ! -f "target/release/omi-desktop-backend" ] || [ -n "$(find src -newer target/release/omi-desktop-backend 2>/dev/null)" ]; then
        step "Building Rust backend (cargo build --release)..."
        cargo build --release
    fi

    ./target/release/omi-desktop-backend &
    BACKEND_PID=$!
    cd - > /dev/null

    step "Waiting for backend to start..."
    for i in {1..30}; do
        if curl -s "http://localhost:$BACKEND_PORT" > /dev/null 2>&1; then
            substep "Backend is ready!"
            break
        fi
        if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
            echo "ERROR: Backend failed to start. Check $BACKEND_DIR/.env and credentials."
            exit 1
        fi
        sleep 0.5
    done
else
    substep "Skipping backend (IR_SKIP_BACKEND=1) — using IR_API_URL from .env"
    warn_if_daemon_stale
fi

# ─── Start Python auth service ────────────────────────────────────────
if [ "${IR_SKIP_AUTH:-0}" != "1" ]; then
    step "Starting Python auth service (port $AUTH_PORT)..."
    if [ -d "$AUTH_DIR" ]; then
        # Set up venv if needed
        if [ ! -d "$AUTH_DIR/.venv" ]; then
            substep "Creating virtualenv..."
            python3 -m venv "$AUTH_DIR/.venv"
            "$AUTH_DIR/.venv/bin/pip" install -q -r "$AUTH_DIR/requirements.txt"
        fi
        # Auth service shares credentials with the Rust backend
        (
            cd "$AUTH_DIR"
            if [ -f "$BACKEND_DIR/.env" ]; then
                migrate_stale_backend_env "$BACKEND_DIR/.env"
                set -a; source "$BACKEND_DIR/.env"; set +a
            fi
            export GOOGLE_APPLICATION_CREDENTIALS="$CREDS_PATH"
            export BASE_API_URL="http://localhost:$AUTH_PORT"
            .venv/bin/uvicorn main:app --host 0.0.0.0 --port "$AUTH_PORT" --log-level warning &
            echo $!
        ) &
        AUTH_PID=$!
        sleep 1
        if curl -s "http://localhost:$AUTH_PORT/docs" > /dev/null 2>&1; then
            substep "Auth service is ready on port $AUTH_PORT"
        else
            substep "Auth service starting (PID: $AUTH_PID)..."
        fi
    else
        substep "Auth-Python/ not found — skipping (auth will use IR_AUTH_URL from .env)"
    fi
else
    substep "Skipping auth service (IR_SKIP_AUTH=1) — using IR_AUTH_URL from .env"
fi

# Check if another SwiftPM instance is running (will block our build)
SWIFTPM_PID=$(pgrep -f "swiftpm-workspace-state|swift-build|swift-package" 2>/dev/null | head -1)
if [ -n "$SWIFTPM_PID" ]; then
    step "Waiting for other SwiftPM instance (PID: $SWIFTPM_PID) to finish..."
    while kill -0 "$SWIFTPM_PID" 2>/dev/null; do
        sleep 1
    done
fi

step "Building agent (npm install + tsc)..."
AGENT_DIR="$(dirname "$0")/agent"
if [ -d "$AGENT_DIR" ]; then
    cd "$AGENT_DIR"
    if [ ! -d "node_modules" ] || [ "package.json" -nt "node_modules/.package-lock.json" ]; then
        substep "Installing npm dependencies"
        npm install --no-fund --no-audit 2>&1 | tail -1
    fi
    substep "Compiling TypeScript and copying assets"
    npm run build --silent
    cd - > /dev/null
else
    echo "Warning: agent directory not found at $AGENT_DIR"
fi

step "Checking schema docs..."
if [ -f scripts/check_schema_docs.sh ]; then
    bash scripts/check_schema_docs.sh || substep "Schema docs check failed (non-fatal)"
fi

step "Building Swift app (swift build -c debug)..."
xcrun swift build -c debug --package-path Desktop

auth_debug "AFTER swift build: auth_isSignedIn=$(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"

step "Creating app bundle..."
substep "Creating directories"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

substep "Copying binary ($(du -h "Desktop/.build/debug/$BINARY_NAME" 2>/dev/null | cut -f1))"
cp -f "Desktop/.build/debug/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

substep "Adding rpath for Frameworks"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true

# Sparkle/HeapSwiftCore/CSSwiftProtobuf removed from Package.swift — no framework copy needed.

# Copy libwebp dylibs and rewrite load paths
WEBP_LIB="$(pkg-config --variable=libdir libwebp 2>/dev/null)/libwebp.7.dylib"
if [ -f "$WEBP_LIB" ]; then
    substep "Bundling libwebp"
    cp "$WEBP_LIB" "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib"
    # Find libsharpyuv (libwebp dependency)
    SHARPYUV_LIB="$(dirname "$WEBP_LIB")/libsharpyuv.0.dylib"
    if [ -f "$SHARPYUV_LIB" ]; then
        cp "$SHARPYUV_LIB" "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib"
        install_name_tool -id "@rpath/libsharpyuv.0.dylib" "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib"
    fi
    install_name_tool -id "@rpath/libwebp.7.dylib" "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib"
    install_name_tool -change "$WEBP_LIB" "@rpath/libwebp.7.dylib" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
fi

substep "Copying Info.plist"
cp -f Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BINARY_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $URL_SCHEME" "$APP_BUNDLE/Contents/Info.plist"

auth_debug "AFTER plist edits: auth_isSignedIn=$(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"

# GoogleService-Info.plist removed — Firebase is not used.

# Copy resource bundle (contains app assets like permissions.gif, herologo.png, etc.)
RESOURCE_BUNDLE="Desktop/.build/arm64-apple-macosx/debug/Omi Computer_Omi Computer.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    substep "Copying resource bundle ($(du -sh "$RESOURCE_BUNDLE" 2>/dev/null | cut -f1))"
    cp -Rf "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

substep "Copying agent"
if [ -d "$AGENT_DIR/dist" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/agent"
    cp -Rf "$AGENT_DIR/dist" "$APP_BUNDLE/Contents/Resources/agent/"
    cp -f "$AGENT_DIR/package.json" "$APP_BUNDLE/Contents/Resources/agent/"
    cp -Rf "$AGENT_DIR/node_modules" "$APP_BUNDLE/Contents/Resources/agent/"
fi

substep "Copying pi-mono-extension (for piMono harness)"
PI_MONO_EXT_DIR="$(dirname "$0")/pi-mono-extension"
if [ -d "$PI_MONO_EXT_DIR" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/pi-mono-extension"
    cp -f "$PI_MONO_EXT_DIR/index.ts" "$APP_BUNDLE/Contents/Resources/pi-mono-extension/"
    cp -f "$PI_MONO_EXT_DIR/package.json" "$APP_BUNDLE/Contents/Resources/pi-mono-extension/"
else
    echo "Warning: pi-mono-extension not found at $PI_MONO_EXT_DIR"
fi

substep "Copying .env.app"
if [ -f ".env.app.dev" ]; then
    cp -f .env.app.dev "$APP_BUNDLE/Contents/Resources/.env"
elif [ -f ".env.app" ]; then
    cp -f .env.app "$APP_BUNDLE/Contents/Resources/.env"
else
    touch "$APP_BUNDLE/Contents/Resources/.env"
    if [ -z "$TUNNEL_URL" ] && [ -z "$IR_API_URL" ] && [ -z "$EFFECTIVE_API_URL" ]; then
        echo "WARNING: No .env.app or .env.app.dev found AND no IR_API_URL/TUNNEL_URL set." >&2
        echo "WARNING: Shipping an empty .env — the app will fall back to its built-in IR_API_URL default (http://127.0.0.1:7331)." >&2
        echo "WARNING: If you intended a remote backend, create .env.app with IR_API_URL=... before rebuilding." >&2
    fi
fi
# Set IR_API_URL: tunnel URL if available, otherwise from .env or local backend
if [ -n "$TUNNEL_URL" ]; then
    EFFECTIVE_API_URL="$TUNNEL_URL"
elif [ -n "$IR_API_URL" ]; then
    EFFECTIVE_API_URL="$IR_API_URL"
else
    EFFECTIVE_API_URL="http://localhost:$BACKEND_PORT"
fi
if grep -q "^IR_API_URL=" "$APP_BUNDLE/Contents/Resources/.env"; then
    sed -i '' "s|^IR_API_URL=.*|IR_API_URL=$EFFECTIVE_API_URL|" "$APP_BUNDLE/Contents/Resources/.env"
else
    echo "IR_API_URL=$EFFECTIVE_API_URL" >> "$APP_BUNDLE/Contents/Resources/.env"
fi
substep "IR_API_URL=$EFFECTIVE_API_URL"
# Bootstrap FIREBASE_API_KEY — check env var first (yolo mode), then backend .env
if ! grep -q "^FIREBASE_API_KEY=" "$APP_BUNDLE/Contents/Resources/.env"; then
    FIREBASE_KEY="${FIREBASE_API_KEY:-}"
    if [ -z "$FIREBASE_KEY" ] && [ -f "$BACKEND_DIR/.env" ]; then
        FIREBASE_KEY=$(grep "^FIREBASE_API_KEY=" "$BACKEND_DIR/.env" | head -1 | cut -d= -f2-)
    fi
    if [ -n "$FIREBASE_KEY" ]; then
        echo "FIREBASE_API_KEY=$FIREBASE_KEY" >> "$APP_BUNDLE/Contents/Resources/.env"
        substep "Bootstrapped FIREBASE_API_KEY"
    fi
fi
# Bootstrap IR_AUTH_URL — check env var first (yolo mode), then backend .env, then local auth
if ! grep -q "^IR_AUTH_URL=" "$APP_BUNDLE/Contents/Resources/.env"; then
    AUTH_URL="${IR_AUTH_URL:-}"
    if [ -z "$AUTH_URL" ] && [ -f "$BACKEND_DIR/.env" ]; then
        AUTH_URL=$(grep "^IR_AUTH_URL=" "$BACKEND_DIR/.env" | head -1 | cut -d= -f2-)
    fi
    if [ -z "$AUTH_URL" ]; then
        AUTH_URL="http://localhost:${AUTH_PORT}/"
        substep "IR_AUTH_URL not set — defaulting to local auth service: $AUTH_URL"
    fi
    echo "IR_AUTH_URL=$AUTH_URL" >> "$APP_BUNDLE/Contents/Resources/.env"
    substep "Set IR_AUTH_URL=$AUTH_URL"
fi
# Bootstrap IR_PYTHON_API_URL — main Omi Python backend (subscriptions, payments, transcription)
# Do NOT fall back to IR_API_URL — that's the Rust desktop-backend which doesn't serve these routes
if ! grep -q "^IR_PYTHON_API_URL=" "$APP_BUNDLE/Contents/Resources/.env"; then
    PYTHON_API_URL="${IR_PYTHON_API_URL:-}"
    if [ -z "$PYTHON_API_URL" ] && [ -f "$BACKEND_DIR/.env" ]; then
        PYTHON_API_URL=$(grep "^IR_PYTHON_API_URL=" "$BACKEND_DIR/.env" | head -1 | cut -d= -f2-)
    fi
    if [ -z "$PYTHON_API_URL" ]; then
        PYTHON_API_URL="https://api.omi.me"
        substep "IR_PYTHON_API_URL not set — defaulting to production: $PYTHON_API_URL"
    fi
    echo "IR_PYTHON_API_URL=$PYTHON_API_URL" >> "$APP_BUNDLE/Contents/Resources/.env"
    substep "Set IR_PYTHON_API_URL=$PYTHON_API_URL"
fi

substep "Copying app icon"
cp -f omi_icon.icns "$APP_BUNDLE/Contents/Resources/OmiIcon.icns" 2>/dev/null || true

substep "Creating PkgInfo"
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Embed provisioning profile only when restricted Sign in with Apple is requested.
# Default local/dev builds intentionally avoid restricted Apple capabilities so
# clone-and-run works without a paid team provisioning profile.
if [ "$ENABLE_APPLE_SIGNIN" = true ]; then
    substep "Embedding provisioning profile for Sign in with Apple: $APPLE_SIGNIN_PROFILE_SOURCE"
    cp "$APPLE_SIGNIN_PROFILE_SOURCE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
else
    substep "Local/dev signing — skipping provisioning profile and restricted Apple entitlements"
fi

auth_debug "BEFORE signing: $(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"

step "Removing extended attributes (xattr -cr)..."
# SwiftPM copies some dylibs (libsharpyuv, libwebp) with read-only perms,
# which makes `xattr -cr` fail with EACCES. Make the bundle writable first.
chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"

step "Signing app with hardened runtime..."
# A stable signing identity is resolved before expensive backend/build/bundle work.
# Ad-hoc signing (--sign -) generates a new CDHash each build, causing macOS to
# reset Screen Recording, Accessibility, and Notification permissions every time.
if [ -n "$SIGN_IDENTITY" ]; then
    substep "Using identity: $SIGN_IDENTITY"
    # Sparkle/CSSwiftProtobuf removed from Package.swift — no sign blocks needed.
    if [ -f "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib" ]; then
        substep "Signing libsharpyuv"
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib"
    fi
    if [ -f "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib" ]; then
        substep "Signing libwebp"
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib"
    fi
    # HeapSwiftCore removed from Package.swift — no sign block needed.
    # Sign the bundled node binary with developer identity + Node.entitlements
    # (macOS requires executables inside app bundles to be properly signed)
    NODE_BIN="$APP_BUNDLE/Contents/Resources/Omi Computer_Omi Computer.bundle/node"
    if [ -f "$NODE_BIN" ]; then
        substep "Signing bundled node binary"
        codesign --force --options runtime --entitlements Desktop/Node.entitlements --sign "$SIGN_IDENTITY" "$NODE_BIN"
    fi

    # Local/dev is the default: strip restricted Sign in with Apple so macOS
    # does not reject clone-and-run builds that lack a matching profile.
    EFFECTIVE_ENTITLEMENTS=""
    PROFILE_PATH="$APP_BUNDLE/Contents/embedded.provisionprofile"

    if [ "$ENABLE_APPLE_SIGNIN" = true ]; then
        make_temp_file EFFECTIVE_ENTITLEMENTS "omi-apple-signin-entitlements"
        make_apple_signin_entitlements "Desktop/Omi.entitlements" "$EFFECTIVE_ENTITLEMENTS" "$APPLE_SIGNIN_SIGNED_APP_IDENTIFIER" "$APPLE_SIGNIN_PROFILE_TEAM_ID"
        substep "Using Sign in with Apple entitlements matched to $APPLE_SIGNIN_PROFILE_APP_IDENTIFIER"
    else
        make_temp_file EFFECTIVE_ENTITLEMENTS "omi-local-dev-entitlements"
        make_local_dev_entitlements "Desktop/Omi.entitlements" "$EFFECTIVE_ENTITLEMENTS"
        rm -f "$PROFILE_PATH"
        substep "Using local/dev entitlements (com.apple.developer.applesignin removed; set IR_ENABLE_APPLE_SIGNIN=1 to opt in)"
    fi
    substep "Signing app bundle"
    codesign --force --options runtime --entitlements "$EFFECTIVE_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    sign_identity_error
    exit 1
fi

step "Removing quarantine attributes..."
chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"

step "Installing to /Applications/..."
# Install to /Applications/ so "Quit & Reopen" (after granting screen recording
# permission) launches the correct binary instead of a stale copy elsewhere.
ditto "$APP_BUNDLE" "$APP_PATH"
substep "Installed to $APP_PATH"

step "Clearing stale LaunchServices registration..."
# Unregister first to clear any launch-disabled flag from stale entries,
# then let `open` re-register the app fresh. Without this, notifications
# fail with "Notifications are not allowed for this application" because
# the launch-disabled flag prevents notification center registration.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
$LSREGISTER -u "$APP_BUNDLE" 2>/dev/null || true
$LSREGISTER -u "$APP_PATH" 2>/dev/null || true
# Purge stale registrations from old DMG staging dirs and unmounted volumes
# These create ghost entries that can cause notification icons to show a
# generic folder instead of the app icon
for stale in /private/tmp/omi-dmg-staging-*/Omi\ Beta.app; do
    [ -d "$stale" ] || $LSREGISTER -u "$stale" 2>/dev/null || true
done
# Register the /Applications/ copy as the canonical bundle for this bundle ID
$LSREGISTER -f "$APP_PATH" 2>/dev/null || true

step "Starting app..."

# Print summary
NOW=$(date +%s.%N)
TOTAL_TIME=$(echo "$NOW - $SCRIPT_START_TIME" | bc)
printf "  └─ done (%.2fs)\n" "$(echo "$NOW - $STEP_START_TIME" | bc)"
echo ""
echo "=== Services Running (total: ${TOTAL_TIME%.*}s) ==="
if [ -n "$BACKEND_PID" ]; then
    echo "Backend:  http://localhost:$BACKEND_PORT (PID: $BACKEND_PID)"
else
    echo "Backend:  skipped (IR_SKIP_BACKEND=1)"
fi
if [ -n "$AUTH_PID" ]; then
    echo "Auth:     http://localhost:$AUTH_PORT (PID: $AUTH_PID)"
else
    echo "Auth:     skipped"
fi
if [ -n "$TUNNEL_PID" ]; then
    echo "Tunnel:   $TUNNEL_URL (PID: $TUNNEL_PID)"
else
    echo "Tunnel:   skipped"
fi
echo "App:      $APP_PATH"
echo "API URL:  $EFFECTIVE_API_URL"
if [ "${#AUTOMATION_ARGS[@]}" -gt 0 ]; then
    echo "Automation bridge: http://127.0.0.1:${AUTOMATION_PORT}"
fi
echo "========================================"
echo ""

auth_debug "BEFORE launch: $(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"
if [ "${#AUTOMATION_ARGS[@]}" -gt 0 ]; then
    open "$APP_PATH" --args "${AUTOMATION_ARGS[@]}" || "$APP_PATH/Contents/MacOS/$BINARY_NAME" "${AUTOMATION_ARGS[@]}" &
else
    open "$APP_PATH" || "$APP_PATH/Contents/MacOS/$BINARY_NAME" &
fi

# Keep script running until Ctrl+C
echo "Press Ctrl+C to stop all services..."
if [ -n "$BACKEND_PID" ]; then
    wait "$BACKEND_PID"
elif [ -n "$AUTH_PID" ]; then
    wait "$AUTH_PID"
else
    # No backend or auth — just wait for user to Ctrl+C
    while true; do sleep 60; done
fi
