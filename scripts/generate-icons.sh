#!/usr/bin/env bash
# Generate macOS app icon (.icns) and menu bar template imageset from SVG sources.
# Inputs:  dmg-assets/logo/icon.svg, dmg-assets/logo/menubar-template.svg
# Outputs: Desktop/AppIcon.iconset/, Desktop/omi_icon.icns,
#          Desktop/Sources/Resources/MenuBarIcon.imageset/{Contents.json,16,32,48 PNGs}

set -euo pipefail

# Resolve repo root (script lives in scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

# Dependency check
if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "error: rsvg-convert not found." >&2
  echo "       install with: brew install librsvg" >&2
  exit 1
fi
if ! command -v iconutil >/dev/null 2>&1; then
  echo "error: iconutil not found (macOS only)." >&2
  exit 1
fi

ICON_SVG="dmg-assets/logo/icon.svg"
MENU_SVG="dmg-assets/logo/menubar-template.svg"
ICONSET_DIR="Desktop/AppIcon.iconset"
ICNS_OUT="Desktop/omi_icon.icns"
MENU_DIR="Desktop/Sources/Resources/MenuBarIcon.imageset"

[ -f "${ICON_SVG}" ] || { echo "error: missing ${ICON_SVG}" >&2; exit 1; }
[ -f "${MENU_SVG}" ] || { echo "error: missing ${MENU_SVG}" >&2; exit 1; }

# --- App icon: render PNGs into .iconset using Apple's standard names ---
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

render_icon () {
  local size="$1" name="$2"
  rsvg-convert -w "${size}" -h "${size}" "${ICON_SVG}" -o "${ICONSET_DIR}/${name}"
}

# Apple HIG iconset naming: pairs of @1x and @2x.
render_icon 16    icon_16x16.png
render_icon 32    icon_16x16@2x.png
render_icon 32    icon_32x32.png
render_icon 64    icon_32x32@2x.png
render_icon 128   icon_128x128.png
render_icon 256   icon_128x128@2x.png
render_icon 256   icon_256x256.png
render_icon 512   icon_256x256@2x.png
render_icon 512   icon_512x512.png
render_icon 1024  icon_512x512@2x.png

iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_OUT}"

# --- Menu bar template imageset (rendered as Template image, system tints) ---
mkdir -p "${MENU_DIR}"
rsvg-convert -w 16 -h 16 "${MENU_SVG}" -o "${MENU_DIR}/MenuBarIcon.png"
rsvg-convert -w 32 -h 32 "${MENU_SVG}" -o "${MENU_DIR}/MenuBarIcon@2x.png"
rsvg-convert -w 48 -h 48 "${MENU_SVG}" -o "${MENU_DIR}/MenuBarIcon@3x.png"

# Also write a top-level MenuBarIcon.png in Resources/ — this is what
# OmiApp.swift actually loads via Bundle.resourceBundle.url(forResource:
# "MenuBarIcon", withExtension: "png"). Without this, the Swift code reads
# a stale PNG (or falls back to the SF Symbol). Render at 32px for crisp
# HiDPI; Swift scales it down to 16px tall at runtime.
rsvg-convert -w 32 -h 32 "${MENU_SVG}" -o "Desktop/Sources/Resources/MenuBarIcon.png"

cat > "${MENU_DIR}/Contents.json" <<'JSON'
{
  "images" : [
    {
      "idiom" : "mac",
      "scale" : "1x",
      "filename" : "MenuBarIcon.png"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "filename" : "MenuBarIcon@2x.png"
    },
    {
      "idiom" : "mac",
      "scale" : "3x",
      "filename" : "MenuBarIcon@3x.png"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
JSON

# --- Report output ---
echo ""
echo "Generated files:"
for f in "${ICONSET_DIR}"/*.png "${ICNS_OUT}" "${MENU_DIR}"/*.png "${MENU_DIR}/Contents.json"; do
  if [ -f "$f" ]; then
    bytes=$(wc -c <"$f" | tr -d ' ')
    printf "  %-60s  %s bytes\n" "$f" "$bytes"
  fi
done
echo ""
echo "Done. App icon: ${ICNS_OUT}"
echo "      Menu bar imageset: ${MENU_DIR}"
