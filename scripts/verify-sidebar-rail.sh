#!/usr/bin/env bash
# Background-only: hidden windows, temporary data, no activation, input injection or production App launch.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="${SCRATCH_PATH:-.build-app}"
swift build --scratch-path "$scratch" --product RunBo
build="$(swift build --scratch-path "$scratch" --show-bin-path)"
objects=()
for target in TerminalDeck TerminalDeckKit SwiftTerm; do
  while IFS= read -r source; do
    base="$(basename "$source")"
    [[ "$base" == TerminalDeckApp.swift ]] && continue
    objects+=("$build/$target.build/$base.o")
  done < "$build/$target.build/sources"
done
output="$(mktemp -d "${TMPDIR:-/tmp}/sidebar-rail-verifier.XXXXXX")"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 -I "$build/Modules" \
  scripts/verify-sidebar-rail.swift "${objects[@]}" -lsqlite3 -o "$output/verify-sidebar-rail"
"$output/verify-sidebar-rail" "$@"
