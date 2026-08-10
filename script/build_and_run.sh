#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodePulse"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
INFO_TEMPLATE="$ROOT_DIR/Resources/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/CodePulse.icns"

if [[ ! -f "$INFO_TEMPLATE" ]]; then
  echo "error: missing canonical app metadata: $INFO_TEMPLATE" >&2
  exit 1
fi

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "error: missing app icon: $ICON_SOURCE" >&2
  exit 1
fi

BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_TEMPLATE")"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --package-path "$ROOT_DIR"
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$INFO_TEMPLATE" "$INFO_PLIST"
cp "$ICON_SOURCE" "$APP_RESOURCES/CodePulse.icns"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
