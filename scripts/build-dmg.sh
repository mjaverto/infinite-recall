#!/bin/bash
# scripts/build-dmg.sh — Distribution-packaging script for Infinite Recall.
#
# Produces a signed + notarized + stapled .dmg suitable for shipping to end
# users outside the Mac App Store. This is the parallel "release" path — the
# dev workflow (run.sh) is unchanged.
#
# Required env vars (validated at startup):
#   APPLE_ID                 Apple ID used to submit notarization (email).
#   APP_SPECIFIC_PASSWORD    App-specific password for that Apple ID
#                            (https://appleid.apple.com → Sign-In and Security).
#   TEAM_ID                  Apple Developer Team ID (10-char alphanumeric).
#
# Optional env vars:
#   OMI_SIGN_IDENTITY        Code-signing identity. Defaults to first
#                            "Developer ID Application" cert in the keychain.
#   OMI_APP_NAME             Display + bundle name. Default: "Infinite Recall".
#   OMI_VERSION              Override version string (otherwise read from
#                            Desktop/Info.plist:CFBundleShortVersionString,
#                            falling back to `git describe --tags`).
#
# DMG backdrop:
#   Drop a 540x380 (or similar) PNG at dmg-assets/background.png. If absent,
#   the script falls back to a plain DMG without a backdrop.
#
# Output:
#   dist/InfiniteRecall-<VERSION>.dmg

set -euo pipefail

# Same PATH guard as run.sh — pyenv's xattr shim breaks `xattr -cr`.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# ─── Resolve repo paths ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ─── Timing helpers (match run.sh style) ───────────────────────────────
SCRIPT_START_TIME=$(date +%s)
STEP_START_TIME=$SCRIPT_START_TIME

step() {
    local now
    now=$(date +%s)
    local total=$((now - SCRIPT_START_TIME))
    local step_elapsed=$((now - STEP_START_TIME))
    if [ "$STEP_START_TIME" != "$SCRIPT_START_TIME" ]; then
        printf "  └─ done (%ds)\n" "$step_elapsed"
    fi
    STEP_START_TIME=$now
    printf "[%4ds] %s\n" "$total" "$1"
}

substep() {
    local now
    now=$(date +%s)
    local total=$((now - SCRIPT_START_TIME))
    printf "[%4ds]   ├─ %s\n" "$total" "$1"
}

die() {
    printf "\nERROR: %s\n\n" "$1" >&2
    exit 1
}

# ─── Validate required env vars ────────────────────────────────────────
step "Validating environment..."
MISSING_VARS=()
[ -z "${APPLE_ID:-}" ] && MISSING_VARS+=("APPLE_ID")
[ -z "${APP_SPECIFIC_PASSWORD:-}" ] && MISSING_VARS+=("APP_SPECIFIC_PASSWORD")
[ -z "${TEAM_ID:-}" ] && MISSING_VARS+=("TEAM_ID")
if [ "${#MISSING_VARS[@]}" -gt 0 ]; then
    echo ""
    echo "Required environment variables are missing:"
    for v in "${MISSING_VARS[@]}"; do
        echo "  - $v"
    done
    echo ""
    echo "Set them and re-run, e.g.:"
    echo "  export APPLE_ID=\"you@example.com\""
    echo "  export APP_SPECIFIC_PASSWORD=\"abcd-efgh-ijkl-mnop\""
    echo "  export TEAM_ID=\"ABCDE12345\""
    echo "  ./scripts/build-dmg.sh"
    echo ""
    exit 1
fi
substep "APPLE_ID=$APPLE_ID  TEAM_ID=$TEAM_ID"

for tool in xcrun codesign hdiutil spctl /usr/libexec/PlistBuddy; do
    command -v "$tool" >/dev/null 2>&1 || [ -x "$tool" ] || die "Required tool not found: $tool"
done

# ─── Configuration ─────────────────────────────────────────────────────
APP_NAME="${OMI_APP_NAME:-Infinite Recall}"
BINARY_NAME="Omi Computer"   # Package.swift target name (matches run.sh)
BUNDLE_ID="com.omi.infinite-recall"

INFO_PLIST="Desktop/Info.plist"
[ -f "$INFO_PLIST" ] || die "Desktop/Info.plist not found at $REPO_ROOT/$INFO_PLIST"

# Version: prefer explicit override → Info.plist → git tag → "0.0.0".
if [ -n "${OMI_VERSION:-}" ]; then
    VERSION="$OMI_VERSION"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || true)
    if [ -z "$VERSION" ] || [ "$VERSION" = "0" ]; then
        VERSION=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
    fi
    [ -z "$VERSION" ] && VERSION="0.0.0"
fi
substep "Version: $VERSION"

DIST_DIR="$REPO_ROOT/dist"
TMP_DIR="$REPO_ROOT/.build-dmg-tmp"
APP_BUNDLE="$TMP_DIR/$APP_NAME.app"
DMG_STAGE_DIR="$TMP_DIR/dmg-stage"
DMG_PATH="$DIST_DIR/InfiniteRecall-$VERSION.dmg"
DMG_VOLNAME="Infinite Recall $VERSION"
ENTITLEMENTS="Desktop/Omi-Release.entitlements"
[ -f "$ENTITLEMENTS" ] || ENTITLEMENTS="Desktop/Omi.entitlements"
[ -f "$ENTITLEMENTS" ] || die "No entitlements file found (Desktop/Omi-Release.entitlements or Desktop/Omi.entitlements)."

# ─── Resolve signing identity ──────────────────────────────────────────
SIGN_IDENTITY="${OMI_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
fi
[ -n "$SIGN_IDENTITY" ] || die "No 'Developer ID Application' identity found in keychain. Install one or set OMI_SIGN_IDENTITY."
substep "Signing identity: $SIGN_IDENTITY"

# ─── Idempotent cleanup ────────────────────────────────────────────────
step "Cleaning prior tmp + output..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR" "$DIST_DIR" "$DMG_STAGE_DIR"
rm -f "$DMG_PATH"
# Detach any leftover mounted volume from a prior failed run.
if mount | grep -q "/Volumes/$DMG_VOLNAME"; then
    hdiutil detach "/Volumes/$DMG_VOLNAME" -force >/dev/null 2>&1 || true
fi

# ─── Build release binary ──────────────────────────────────────────────
step "Building Swift app (release)..."
xcrun swift build -c release --package-path Desktop

RELEASE_BIN="Desktop/.build/release/$BINARY_NAME"
[ -f "$RELEASE_BIN" ] || die "Release binary not produced at $RELEASE_BIN"

# ─── Assemble bundle (mirrors run.sh layout) ───────────────────────────
step "Assembling app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

substep "Copying binary"
cp -f "$RELEASE_BIN" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true

# Sparkle (autoupdate framework — bundled by SwiftPM)
SPARKLE_FRAMEWORK="Desktop/.build/arm64-apple-macosx/release/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    substep "Copying Sparkle.framework"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
fi

# Heap analytics SDK (dormant at runtime but linked).
HEAP_FRAMEWORK="Desktop/.build/artifacts/heap-swift-core-sdk/HeapSwiftCore/HeapSwiftCore.xcframework/macos-arm64_x86_64/HeapSwiftCore.framework"
if [ -d "$HEAP_FRAMEWORK" ]; then
    substep "Copying HeapSwiftCore.framework"
    cp -R "$HEAP_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
fi
CSPROTOBUF_FRAMEWORK="Desktop/.build/artifacts/csswiftprotobuf/CSSwiftProtobuf/CSSwiftProtobuf.xcframework/macos-arm64_x86_64/CSSwiftProtobuf.framework"
if [ -d "$CSPROTOBUF_FRAMEWORK" ]; then
    substep "Copying CSSwiftProtobuf.framework"
    cp -R "$CSPROTOBUF_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
fi

# libwebp + libsharpyuv (image deps — same rpath rewrites as run.sh).
WEBP_DIR=""
if command -v pkg-config >/dev/null 2>&1; then
    WEBP_DIR="$(pkg-config --variable=libdir libwebp 2>/dev/null || true)"
fi
WEBP_LIB="${WEBP_DIR}/libwebp.7.dylib"
if [ -n "$WEBP_DIR" ] && [ -f "$WEBP_LIB" ]; then
    substep "Bundling libwebp + libsharpyuv"
    cp "$WEBP_LIB" "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib"
    SHARPYUV_LIB="$WEBP_DIR/libsharpyuv.0.dylib"
    if [ -f "$SHARPYUV_LIB" ]; then
        cp "$SHARPYUV_LIB" "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib"
        install_name_tool -id "@rpath/libsharpyuv.0.dylib" "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib"
    fi
    install_name_tool -id "@rpath/libwebp.7.dylib" "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib"
    install_name_tool -change "$WEBP_LIB" "@rpath/libwebp.7.dylib" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true
fi

# Info.plist
substep "Writing Info.plist (version $VERSION, bundle $BUNDLE_ID)"
cp -f "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BINARY_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Resource bundle (image assets, etc).
RESOURCE_BUNDLE="Desktop/.build/arm64-apple-macosx/release/${BINARY_NAME}_${BINARY_NAME}.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    substep "Copying resource bundle"
    cp -Rf "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# App icon
if [ -f "omi_icon.icns" ]; then
    cp -f omi_icon.icns "$APP_BUNDLE/Contents/Resources/OmiIcon.icns"
fi

# PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Provisioning profile (only relevant for Developer ID if you have one for
# Sign-In with Apple; safe to skip for distribution if not present).
if [ -f "Desktop/embedded.provisionprofile" ]; then
    substep "Embedding provisioning profile"
    cp "Desktop/embedded.provisionprofile" "$APP_BUNDLE/Contents/embedded.provisionprofile"
fi

# Strip xattrs before signing (same EACCES guard as run.sh).
chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"

# ─── Sign frameworks + dylibs first, then bundle ───────────────────────
step "Signing with Developer ID..."
sign_one() {
    local target="$1"
    [ -e "$target" ] || return 0
    substep "Signing $(basename "$target")"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$target"
}

# Order matters: inner dylibs/frameworks before the outer bundle.
sign_one "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib"
sign_one "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib"
sign_one "$APP_BUNDLE/Contents/Frameworks/CSSwiftProtobuf.framework"
sign_one "$APP_BUNDLE/Contents/Frameworks/HeapSwiftCore.framework"
sign_one "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

substep "Signing app bundle with hardened runtime + entitlements ($ENTITLEMENTS)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

substep "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

# ─── Notarize ──────────────────────────────────────────────────────────
step "Submitting to Apple notary service..."
NOTARIZE_ZIP="$TMP_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
substep "Uploaded $(du -h "$NOTARIZE_ZIP" | cut -f1) — waiting (this can take several minutes)"
xcrun notarytool submit "$NOTARIZE_ZIP" \
    --apple-id "$APPLE_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

# ─── Staple ────────────────────────────────────────────────────────────
step "Stapling notarization ticket..."
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

# ─── Build DMG ─────────────────────────────────────────────────────────
step "Building DMG..."
substep "Staging $APP_NAME.app + /Applications symlink"
cp -R "$APP_BUNDLE" "$DMG_STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

# Optional backdrop. Drop a PNG at dmg-assets/background.png to enable.
BACKDROP_SRC="$REPO_ROOT/dmg-assets/background.png"
if [ -f "$BACKDROP_SRC" ]; then
    substep "Including dmg-assets/background.png as backdrop"
    mkdir -p "$DMG_STAGE_DIR/.background"
    cp "$BACKDROP_SRC" "$DMG_STAGE_DIR/.background/background.png"
fi

substep "Creating compressed UDZO image at $DMG_PATH"
hdiutil create \
    -volname "$DMG_VOLNAME" \
    -srcfolder "$DMG_STAGE_DIR" \
    -ov -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

# Window layout via AppleScript only when we have a backdrop. Without a
# backdrop we ship a "plain" DMG — Finder still shows app + Applications
# symlink side-by-side, just without custom positioning.
if [ -f "$BACKDROP_SRC" ]; then
    substep "Applying Finder window layout"
    # Re-create as RW, layout, then convert back to UDZO. This is the
    # standard hdiutil dance for backdrop + icon positioning.
    RW_DMG="$TMP_DIR/rw.dmg"
    rm -f "$RW_DMG"
    hdiutil convert "$DMG_PATH" -format UDRW -o "$RW_DMG" >/dev/null
    rm -f "$DMG_PATH"

    MOUNT_DIR="$TMP_DIR/mount"
    mkdir -p "$MOUNT_DIR"
    hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet
    osascript <<APPLESCRIPT || true
tell application "Finder"
    tell disk "$DMG_VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 740, 580}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        try
            set background picture of viewOptions to file ".background:background.png"
        end try
        set position of item "$APP_NAME.app" of container window to {140, 200}
        set position of item "Applications" of container window to {400, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    sync
    hdiutil detach "$MOUNT_DIR" -force -quiet || true
    hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
    rm -f "$RW_DMG"
fi

# Sign the DMG itself so Gatekeeper recognizes it.
substep "Signing DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

# ─── Verify ────────────────────────────────────────────────────────────
step "Verifying notarized DMG..."
MOUNT_DIR="$TMP_DIR/verify-mount"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -readonly -quiet
substep "spctl --assess on mounted bundle"
spctl --assess --type open --context context:primary-signature --verbose=2 "$MOUNT_DIR/$APP_NAME.app" || \
    die "spctl assessment failed — DMG is not properly notarized."
hdiutil detach "$MOUNT_DIR" -force -quiet

# ─── Done ──────────────────────────────────────────────────────────────
step "Done."
DMG_SIZE="$(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "=========================================="
echo "  Distribution build ready"
echo "=========================================="
echo "  Artifact: $DMG_PATH"
echo "  Size:     $DMG_SIZE"
echo "  Version:  $VERSION"
echo "  Identity: $SIGN_IDENTITY"
echo "=========================================="
