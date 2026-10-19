#!/usr/bin/env bash
# Isolated layer-backed render/interaction checks; no production database or foreground input.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --scratch-path .build-app --product RunBo
build="$(swift build --scratch-path .build-app --show-bin-path)"
objects=()
for target in TerminalDeck TerminalDeckKit SwiftTerm; do
  while IFS= read -r source; do
    base="$(basename "$source")"
    [[ "$base" == TerminalDeckApp.swift ]] && continue
    objects+=("$build/$target.build/$base.o")
  done < "$build/$target.build/sources"
done
output="$(mktemp -d "${TMPDIR:-/tmp}/scrollbar-verifier.XXXXXX")"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 -I "$build/Modules" \
  scripts/verify-scrollbars.swift "${objects[@]}" -lsqlite3 -o "$output/verify-scrollbars"
"$output/verify-scrollbars" "$@"
