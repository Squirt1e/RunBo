#!/usr/bin/env bash
# Safe to invoke from a task: build separately, then hand off to launchd before quitting.
# --check builds and validates the package without scheduling a quit, replacement or launch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=debug
CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --check) CHECK_ONLY=1 ;;
        -h|--help)
            echo "Usage: bash scripts/rebuild-and-restart.sh [debug|release] [--check]"
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

APP_NAME="$(/usr/bin/plutil -extract CFBundleName raw -o - "$ROOT/config/Info.plist")"
BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$ROOT/config/Info.plist")"
mkdir -p "$ROOT/build"
WORK="$(mktemp -d "$ROOT/build/.rebuild.XXXXXX")"
KEEP_WORK=0
cleanup() {
    if [[ "$KEEP_WORK" == 0 ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
APP="$ROOT/build/$APP_NAME.app"
STAGED="$WORK/$APP_NAME.app"
HELPER="$WORK/restart-built-app"
RESULT="$WORK/result.json"

# Compile first: a broken restarter must never cause us to quit a working app.
swiftc -swift-version 5 "$ROOT/scripts/restart-built-app.swift" -o "$HELPER"
APP_OUTPUT_PATH="$STAGED" bash "$ROOT/scripts/build-app.sh" "$CONFIG"
"$HELPER" --check "$APP" "$STAGED" "$RESULT"

if [[ "$CHECK_ONLY" == 1 ]]; then
    KEEP_WORK=1
    echo "CHECK ONLY: no App was quit, replaced or launched."
    echo "Staged package: $STAGED"
    exit 0
fi

LABEL="$BUNDLE_ID.rebuild.$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
# A nohup child can still belong to the task's PTY process group. launchd owns this
# worker instead, so normal App shutdown cannot kill the waiter or its relaunch.
launchctl submit -l "$LABEL" -o "$WORK/restart.log" -e "$WORK/restart.err" -- \
    /bin/sh -c '
        "$1" --restart "$2" "$3" "$4"
        status=$?
        /bin/launchctl remove "$5" >/dev/null 2>&1
        exit "$status"
    ' sh "$HELPER" "$APP" "$STAGED" "$RESULT" "$LABEL"
KEEP_WORK=1
printf 'Restart scheduled: all terminals will end through normal App quit.\n'
printf 'Job: %s\nResult: %s\nLog: %s\n' "$LABEL" "$RESULT" "$WORK/restart.log"
