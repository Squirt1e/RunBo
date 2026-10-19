#!/usr/bin/env bash
# Builds "RunBo.app" without Xcode, using the Command Line Tools toolchain.
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
APP_NAME="RunBo"
APP="${APP_OUTPUT_PATH:-$ROOT/build/$APP_NAME.app}"

# SwiftPM wraps manifest compilation in its own sandbox; inside another sandbox
# (CI, agent harnesses) that nested sandbox_apply fails, so 允许调用方关掉它。
SWIFT_FLAGS="${SWIFT_FLAGS:-}"

# SwiftPM clones SwiftTerm over HTTPS; HTTP/2 to github.com is unreliable on some
# networks, so pin HTTP/1.1 for the git subprocesses it spawns.
export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-1}"
export GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-http.version}"
export GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-HTTP/1.1}"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "Missing Resources/AppIcon.icns; run bash scripts/generate-app-icons.sh first." >&2
    exit 1
fi

echo "==> Building $APP_NAME ($CONFIG)"
swift build $SWIFT_FLAGS -c "$CONFIG" --product RunBo --scratch-path "$SCRATCH_PATH"
BIN_DIR="$(swift build $SWIFT_FLAGS -c "$CONFIG" --product RunBo --scratch-path "$SCRATCH_PATH" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RunBo" "$APP/Contents/MacOS/RunBo"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resources must travel with the app, not rely on the local build directory.
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || echo "    (codesign unavailable; the app still runs locally)"

echo "==> Done: $APP"
