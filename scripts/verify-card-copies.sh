#!/usr/bin/env bash
# AppModel/native SwiftUI checks in isolated temporary stores; never opens the user's data.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --scratch-path .build-app --product RunBo
build="$(swift build --scratch-path .build-app --show-bin-path)"
objects=()
for target in App Core SwiftTerm; do
  while IFS= read -r source; do
    base="$(basename "$source")"
    # Import the App's testable types, but don't link its real @main/AppDelegate lifecycle.
    [[ "$base" == AppEntry.swift ]] && continue
    objects+=("$build/$target.build/$base.o")
  done < "$build/$target.build/sources"
done
output="$(mktemp -d "${TMPDIR:-/tmp}/card-copy-verifier.XXXXXX")"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -swift-version 5 -I "$build/Modules" \
  scripts/verify-card-copies.swift "${objects[@]}" -lsqlite3 -o "$output/verify-card-copies"
"$output/verify-card-copies" "$@"
