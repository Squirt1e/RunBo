#!/usr/bin/env bash
# Regenerate the approved Mist / Apricot app icon and monochrome menu template.
# Requires local rsvg-convert + macOS iconutil; normal app builds use the generated assets.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v rsvg-convert >/dev/null || { echo "Missing rsvg-convert (needed only to regenerate icons)." >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/runbo-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" "$ROOT/Resources/AppIcon.svg" \
        -o "$ICONSET/icon_${size}x${size}.png"
    pixels=$((size * 2))
    rsvg-convert -w "$pixels" -h "$pixels" "$ROOT/Resources/AppIcon.svg" \
        -o "$ICONSET/icon_${size}x${size}@2x.png"
done
rsvg-convert -w 22 -h 22 "$ROOT/Resources/MenuBarIcon.svg" -o "$WORK/MenuBarIcon.png"
rsvg-convert -w 44 -h 44 "$ROOT/Resources/MenuBarIcon.svg" -o "$WORK/MenuBarIcon@2x.png"
# PNGs without a profile are interpreted as generic RGB by AppKit, shifting the
# approved sRGB palette. Tag the encoded colours, without converting pixel values.
for png in "$ICONSET"/*.png "$WORK"/MenuBarIcon*.png; do
    sips --embedProfile "/System/Library/ColorSync/Profiles/sRGB Profile.icc" "$png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"
cp "$WORK/AppIcon.icns" "$ROOT/Resources/AppIcon.icns"
cp "$ICONSET/icon_512x512@2x.png" "$ROOT/Sources/TerminalDeck/Resources/AppIcon.png"
cp "$WORK/MenuBarIcon.png" "$ROOT/Sources/TerminalDeck/Resources/MenuBarIcon.png"
cp "$WORK/MenuBarIcon@2x.png" "$ROOT/Sources/TerminalDeck/Resources/MenuBarIcon@2x.png"
echo "Generated Mist / Apricot AppIcon.icns, 1024px runtime artwork, and 22/44px menu templates."
