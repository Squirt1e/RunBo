#!/usr/bin/env bash
# Check real branded artwork and a relocated SwiftPM resource bundle, without opening user data.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --scratch-path .build-app --product RunBo
build="$(swift build --scratch-path .build-app --show-bin-path)"
objects=()
for target in App Core SwiftTerm; do
    while IFS= read -r source; do
        base="$(basename "$source")"
        [[ "$base" == AppEntry.swift ]] && continue
        objects+=("$build/$target.build/$base.o")
    done < "$build/$target.build/sources"
done
output="$(mktemp -d "${TMPDIR:-/tmp}/app-icon-verifier.XXXXXX")"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 -I "$build/Modules" \
    scripts/verify-icons.swift "${objects[@]}" -lsqlite3 -o "$output/verify-icons"
"$output/verify-icons"

app="$output/Icon Check.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$output/verify-icons" "$app/Contents/MacOS/verify-icons"
cp -R "$build/RunBo_App.bundle" "$app/Contents/Resources/"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>verify-icons</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' \
    > "$app/Contents/Info.plist"
"$app/Contents/MacOS/verify-icons" --packaged

iconutil -c iconset resources/AppIcon.icns -o "$output/AppIcon.iconset"
for size in 16 32 128 256 512; do
    test -f "$output/AppIcon.iconset/icon_${size}x${size}.png"
    test -f "$output/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
cmp "$output/AppIcon.iconset/icon_512x512@2x.png" src/app/Assets/AppIcon.png
echo "PASS AppIcon.icns contains all ten macOS slots and the same 1024px master"
