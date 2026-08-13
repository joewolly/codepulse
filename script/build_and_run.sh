#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodePulse"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
APP_HELPER_BINARY="$APP_HELPERS/codepulse-integration"
APP_CONTROL_BINARY="$APP_HELPERS/codepulsectl"
INFO_PLIST="$APP_CONTENTS/Info.plist"
INFO_TEMPLATE="$ROOT_DIR/Resources/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/CodePulse.icns"
VERIFICATION_DIR="$(mktemp -d /private/tmp/CodePulse-staging.XXXXXX)"
STAGED_APP_BUNDLE="$VERIFICATION_DIR/$APP_NAME.app"
STAGED_CONTENTS="$STAGED_APP_BUNDLE/Contents"
STAGED_MACOS="$STAGED_CONTENTS/MacOS"
STAGED_HELPERS="$STAGED_CONTENTS/Helpers"
STAGED_RESOURCES="$STAGED_CONTENTS/Resources"
STAGED_FRAMEWORKS="$STAGED_CONTENTS/Frameworks"
STAGED_BINARY="$STAGED_MACOS/$APP_NAME"
STAGED_HELPER_BINARY="$STAGED_HELPERS/codepulse-integration"
STAGED_CONTROL_BINARY="$STAGED_HELPERS/codepulsectl"
STAGED_INFO_PLIST="$STAGED_CONTENTS/Info.plist"

cleanup_verification_dir() {
  rm -rf "$VERIFICATION_DIR"
}
trap cleanup_verification_dir EXIT

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

swift build --package-path "$ROOT_DIR" --product "$APP_NAME"
swift build --package-path "$ROOT_DIR" --product codepulse-integration
swift build --package-path "$ROOT_DIR" --product codepulsectl
BUILD_BIN_DIR="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
BUILD_HELPER="$BUILD_BIN_DIR/codepulse-integration"
BUILD_CONTROL="$BUILD_BIN_DIR/codepulsectl"
SPARKLE_FRAMEWORK="$BUILD_BIN_DIR/Sparkle.framework"

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: SwiftPM did not stage Sparkle.framework beside the CodePulse product" >&2
  exit 1
fi
if [[ ! -x "$BUILD_HELPER" ]]; then
  echo "error: SwiftPM did not produce the codepulse-integration helper" >&2
  exit 1
fi
if [[ ! -x "$BUILD_CONTROL" ]]; then
  echo "error: SwiftPM did not produce codepulsectl" >&2
  exit 1
fi

mkdir -p "$STAGED_MACOS" "$STAGED_HELPERS" "$STAGED_RESOURCES" "$STAGED_FRAMEWORKS"
cp "$BUILD_BINARY" "$STAGED_BINARY"
cp "$BUILD_HELPER" "$STAGED_HELPER_BINARY"
cp "$BUILD_CONTROL" "$STAGED_CONTROL_BINARY"
chmod +x "$STAGED_BINARY"
chmod +x "$STAGED_HELPER_BINARY"
chmod +x "$STAGED_CONTROL_BINARY"
cp "$INFO_TEMPLATE" "$STAGED_INFO_PLIST"
cp "$ICON_SOURCE" "$STAGED_RESOURCES/CodePulse.icns"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$STAGED_FRAMEWORKS/Sparkle.framework"
/usr/bin/plutil -lint "$STAGED_INFO_PLIST" >/dev/null

if ! /usr/bin/otool -l "$STAGED_BINARY" | /usr/bin/grep -A2 LC_RPATH | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
  /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$STAGED_BINARY"
fi

/usr/bin/otool -L "$STAGED_BINARY" | /usr/bin/grep -F '@rpath/Sparkle.framework/' >/dev/null || {
  echo "error: CodePulse executable is not linked to Sparkle.framework" >&2
  exit 1
}

[[ -L "$STAGED_FRAMEWORKS/Sparkle.framework/Versions/Current" ]] || {
  echo "error: staged Sparkle.framework did not preserve framework symlinks" >&2
  exit 1
}

[[ -x "$STAGED_HELPER_BINARY" ]] || {
  echo "error: bundled codepulse-integration helper is missing" >&2
  exit 1
}

[[ -x "$STAGED_CONTROL_BINARY" ]] || {
  echo "error: bundled codepulsectl is missing" >&2
  exit 1
}

/usr/bin/xattr -cr "$STAGED_APP_BUNDLE"
/usr/bin/xattr -r -d com.apple.FinderInfo "$STAGED_APP_BUNDLE" >/dev/null 2>&1 || true
/usr/bin/xattr -r -d 'com.apple.fileprovider.fpfs#P' "$STAGED_APP_BUNDLE" >/dev/null 2>&1 || true
/usr/bin/codesign --force --sign - "$STAGED_APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP_BUNDLE"

if [[ -L "$DIST_DIR" || ( -e "$DIST_DIR" && ! -d "$DIST_DIR" ) ]]; then
  echo "error: refusing to use an unsafe dist path: $DIST_DIR" >&2
  exit 1
fi
mkdir -p "$DIST_DIR"
if [[ -L "$DIST_DIR" || ! -d "$DIST_DIR" ]]; then
  echo "error: dist path is not a real directory: $DIST_DIR" >&2
  exit 1
fi
if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
  [[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || {
    echo "error: refusing to replace non-directory app path: $APP_BUNDLE" >&2
    exit 1
  }
  rm -rf "$APP_BUNDLE"
fi
/usr/bin/ditto "$STAGED_APP_BUNDLE" "$APP_BUNDLE"

bundle_content_manifest() {
  local bundle_path="$1"
  (
    cd "$bundle_path"
    find -P . -type f -print | sort | while IFS= read -r path; do
      /usr/bin/shasum -a 256 "$path"
    done
    find -P . -type l -print | sort | while IFS= read -r path; do
      printf 'symlink %s -> %s\n' "$path" "$(readlink "$path")"
    done
  )
}

if ! /usr/bin/cmp -s <(bundle_content_manifest "$STAGED_APP_BUNDLE") <(bundle_content_manifest "$APP_BUNDLE"); then
  echo "error: copied staged app content differs from the strictly verified local bundle" >&2
  exit 1
fi
/usr/bin/xattr -cr "$APP_BUNDLE"
/usr/bin/xattr -r -d com.apple.FinderInfo "$APP_BUNDLE" >/dev/null 2>&1 || true
/usr/bin/xattr -r -d 'com.apple.fileprovider.fpfs#P' "$APP_BUNDLE" >/dev/null 2>&1 || true
echo "--strict-verified-local-stage:passed (temporary stage removed on exit)"
echo "--copied-staged-app:$APP_BUNDLE"

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
