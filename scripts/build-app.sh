#!/usr/bin/env bash
# Builds the configured .app without Xcode, using the Command Line Tools toolchain.
#
#   ./scripts/build-app.sh              # release build into build/
#   ./scripts/build-app.sh debug        # debug build
#   SCRATCH_PATH=.build-app ./scripts/build-app.sh
#   SWIFT_FLAGS=--disable-sandbox ./scripts/build-app.sh   # 沙箱里跑不了嵌套沙箱时用
#   APP_OUTPUT_PATH=/path/to/RunBo.app ./scripts/build-app.sh debug  # 独立打包，不覆盖运行中的 App
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
SCRATCH_PATH="${SCRATCH_PATH:-$ROOT/.build-app}"
APP_NAME="$(/usr/bin/plutil -extract CFBundleName raw -o - "$ROOT/config/Info.plist")"
APP_EXECUTABLE="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$ROOT/config/Info.plist")"
APP="${APP_OUTPUT_PATH:-$ROOT/build/$APP_NAME.app}"

# SwiftPM wraps manifest compilation in its own sandbox; inside another sandbox
# (CI, agent harnesses) that nested sandbox_apply fails, so 允许调用方关掉它。
SWIFT_FLAGS="${SWIFT_FLAGS:-}"

# SwiftPM clones SwiftTerm over HTTPS; HTTP/2 to github.com is unreliable on some
# networks, so pin HTTP/1.1 for the git subprocesses it spawns.
export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-1}"
export GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-http.version}"
export GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-HTTP/1.1}"

if [[ ! -f "$ROOT/resources/AppIcon.icns" ]]; then
    echo "Missing resources/AppIcon.icns; run bash scripts/generate-icons.sh first." >&2
    exit 1
fi

echo "==> Building $APP_NAME ($CONFIG)"
swift build $SWIFT_FLAGS -c "$CONFIG" --product RunBo --scratch-path "$SCRATCH_PATH"
BIN_DIR="$(swift build $SWIFT_FLAGS -c "$CONFIG" --product RunBo --scratch-path "$SCRATCH_PATH" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RunBo" "$APP/Contents/MacOS/$APP_EXECUTABLE"
cp "$ROOT/config/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resources must travel with the app, not rely on the local build directory.
# Copy only the current app resource bundle and SwiftTerm resources; stale
# bundle names from earlier target layouts must not be shipped.
for bundle in "$BIN_DIR/RunBo_App.bundle" "$BIN_DIR"/SwiftTerm_*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || echo "    (codesign unavailable; the app still runs locally)"

echo "==> Done: $APP"
