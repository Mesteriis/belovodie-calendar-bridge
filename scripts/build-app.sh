#!/usr/bin/env bash
set -euo pipefail
BRIDGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BRIDGE_ROOT"
BRIDGE_CONFIGURATION="${BRIDGE_BUILD_CONFIGURATION:-debug}"
BRIDGE_APP="$BRIDGE_ROOT/build/BelovodieCalendarBridge.app"
swift build -c "$BRIDGE_CONFIGURATION" --product BelovodieCalendarBridge
BRIDGE_BIN_DIR="$(swift build -c "$BRIDGE_CONFIGURATION" --show-bin-path)"
mkdir -p "$BRIDGE_APP/Contents/MacOS"
cp "$BRIDGE_BIN_DIR/BelovodieCalendarBridge" "$BRIDGE_APP/Contents/MacOS/BelovodieCalendarBridge"
cp packaging/Info.plist "$BRIDGE_APP/Contents/Info.plist"
chmod 755 "$BRIDGE_APP/Contents/MacOS/BelovodieCalendarBridge"
# Identity is a private environment input. Ad-hoc is suitable for build/CI verification;
# use the same private Apple Development identity across local TCC launches.
if ! codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$BRIDGE_APP" >/dev/null 2>&1; then
    printf 'Signing failed. Check the private CODE_SIGN_IDENTITY configuration.\n' >&2
    exit 1
fi
plutil -lint "$BRIDGE_APP/Contents/Info.plist"
codesign --verify --strict "$BRIDGE_APP"
printf 'Built %s\n' "$BRIDGE_APP"
