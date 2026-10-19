#!/usr/bin/env bash
# Isolated app-model/native-component verification; never launches the production AppDelegate.
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
output="$(mktemp -d "${TMPDIR:-/tmp}/file-browser-verifier.XXXXXX")"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 -I "$build/Modules" \
  scripts/verify-file-browser.swift "${objects[@]}" -lsqlite3 -o "$output/verify-file-browser"
"$output/verify-file-browser" "$@"
