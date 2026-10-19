#!/usr/bin/env bash
# Render the real artwork view without launching the user's app or touching its store.
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
output="$(mktemp -d "${TMPDIR:-/tmp}/home-artwork-verifier.XXXXXX")"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 -I "$build/Modules" \
  scripts/verify-home-artwork.swift "${objects[@]}" -lsqlite3 -o "$output/verify-artwork"
"$output/verify-artwork"

# A relocated .app must use its own Contents/Resources, not the build-path fallback.
app="$output/Artwork Check.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$output/verify-artwork" "$app/Contents/MacOS/verify-artwork"
cp -R "$build/RunBo_App.bundle" "$app/Contents/Resources/"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>verify-artwork</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' \
  > "$app/Contents/Info.plist"
"$app/Contents/MacOS/verify-artwork" --packaged
