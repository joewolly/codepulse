#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodePulse"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/dist/release"
INFO_TEMPLATE="$ROOT_DIR/Resources/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/CodePulse.icns"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
VOLUME_NAME="CodePulse"

APP_ONLY=false
SKIP_SMOKE=false
ADHOC_SIGN="${CODEPULSE_ADHOC_SIGN:-0}"
TEMP_DIR=""
MOUNT_POINT=""
MOUNTED=false
VERSION=""
BUILD_NUMBER=""
DMG_PATH=""
CHECKSUMS_PATH="$RELEASE_DIR/checksums.txt"
ARM64_BINARY=""
X86_64_BINARY=""
UNIVERSAL_BINARY=""
SPARKLE_FRAMEWORK=""

usage() {
  cat <<'USAGE'
Usage: ./script/package_release.sh [options]

Build a native CodePulse release app and an unsigned drag-to-install DMG.

Options:
  --app-only     Build and validate CodePulse.app without creating a DMG.
  --skip-smoke   Skip the read-only DMG mount/install-layout validation.
  --adhoc-sign   Apply an optional local ad-hoc signature to the app bundle.
  --help         Show this help text.

Version overrides:
  CODEPULSE_VERSION=0.4.2 CODEPULSE_BUILD=402 ./script/package_release.sh
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

cleanup() {
  if [[ "$MOUNTED" == true && -n "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
    MOUNTED=false
  fi

  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    /bin/rm -rf "$TEMP_DIR"
  fi
}

trap cleanup EXIT INT TERM

clear_bundle_metadata() {
  /usr/bin/xattr -cr "$APP_BUNDLE"
  /usr/bin/xattr -r -d com.apple.FinderInfo "$APP_BUNDLE" >/dev/null 2>&1 || true
  /usr/bin/xattr -r -d 'com.apple.fileprovider.fpfs#P' "$APP_BUNDLE" >/dev/null 2>&1 || true
}

parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app-only)
        APP_ONLY=true
        ;;
      --skip-smoke)
        SKIP_SMOKE=true
        ;;
      --adhoc-sign)
        ADHOC_SIGN=1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1 (use --help for usage)"
        ;;
    esac
    shift
  done
}

validate_environment() {
  [[ "$(uname -s)" == "Darwin" ]] || die "release packaging requires macOS"

  for command in swift lipo hdiutil plutil file shasum xattr open diskutil ditto install_name_tool otool find; do
    require_command "$command"
  done

  if [[ "$ADHOC_SIGN" == "1" || "$ADHOC_SIGN" == "true" ]]; then
    require_command codesign
  fi

  [[ -f "$INFO_TEMPLATE" ]] || die "missing canonical app metadata: $INFO_TEMPLATE"
  [[ -f "$ICON_SOURCE" ]] || die "missing app icon: $ICON_SOURCE"
  /usr/bin/plutil -lint "$INFO_TEMPLATE" >/dev/null || die "invalid app metadata plist: $INFO_TEMPLATE"

  BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_TEMPLATE")"
  [[ "$BUNDLE_ID" == "com.joewolly.CodePulse" ]] || die "unexpected bundle identifier in Info.plist: $BUNDLE_ID"
}

determine_version() {
  local template_version template_build
  template_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO_TEMPLATE")"
  template_build="$(/usr/bin/plutil -extract CFBundleVersion raw "$INFO_TEMPLATE")"
  VERSION="${CODEPULSE_VERSION:-$template_version}"
  BUILD_NUMBER="${CODEPULSE_BUILD:-$template_build}"

  [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "CODEPULSE_VERSION must contain one to three numeric components: $VERSION"
  [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "CODEPULSE_BUILD must be numeric: $BUILD_NUMBER"
  DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
}

prepare_workspace() {
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codepulse-release.XXXXXX")"
  mkdir -p "$RELEASE_DIR"
  echo "Packaging CodePulse $VERSION (build $BUILD_NUMBER)"
  echo "Temporary build workspace: $TEMP_DIR"
}

build_release() {
  local arm64_scratch="$TEMP_DIR/build-arm64"
  local x86_64_scratch="$TEMP_DIR/build-x86_64"
  local arm64_bin_path x86_64_bin_path

  echo "Building optimized arm64 release binary"
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$arm64_scratch" \
    --configuration release \
    --triple arm64-apple-macosx13.0 \
    --product "$APP_NAME"
  arm64_bin_path="$(swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$arm64_scratch" \
    --configuration release \
    --triple arm64-apple-macosx13.0 \
    --show-bin-path)"
  ARM64_BINARY="$arm64_bin_path/$APP_NAME"
  [[ -x "$ARM64_BINARY" ]] || die "SwiftPM did not produce the arm64 release executable: $ARM64_BINARY"

  SPARKLE_FRAMEWORK="$(/usr/bin/find "$arm64_scratch" -type d -name Sparkle.framework -print -quit 2>/dev/null || true)"
  [[ -d "$SPARKLE_FRAMEWORK" ]] || die "SwiftPM did not resolve Sparkle.framework in the arm64 release workspace"

  echo "Building optimized x86_64 release binary"
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$x86_64_scratch" \
    --configuration release \
    --triple x86_64-apple-macosx13.0 \
    --product "$APP_NAME"
  x86_64_bin_path="$(swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$x86_64_scratch" \
    --configuration release \
    --triple x86_64-apple-macosx13.0 \
    --show-bin-path)"
  X86_64_BINARY="$x86_64_bin_path/$APP_NAME"
  [[ -x "$X86_64_BINARY" ]] || die "SwiftPM did not produce the x86_64 release executable: $X86_64_BINARY"

  UNIVERSAL_BINARY="$TEMP_DIR/$APP_NAME-universal"
  /usr/bin/lipo -create -output "$UNIVERSAL_BINARY" "$ARM64_BINARY" "$X86_64_BINARY"
  chmod 755 "$UNIVERSAL_BINARY"

  local architecture_info
  architecture_info="$(/usr/bin/lipo -info "$UNIVERSAL_BINARY")"
  [[ "$architecture_info" == *arm64* && "$architecture_info" == *x86_64* ]] || die "Universal 2 validation failed: $architecture_info"
  echo "Architecture: $architecture_info"
}

stage_app_bundle() {
  echo "Staging $APP_NAME.app"
  if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
    [[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || die "refusing to replace non-directory app path: $APP_BUNDLE"
    /bin/rm -rf "$APP_BUNDLE"
  fi

  mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
  cp "$UNIVERSAL_BINARY" "$APP_BINARY"
  cp "$INFO_TEMPLATE" "$INFO_PLIST"
  cp "$ICON_SOURCE" "$APP_RESOURCES/CodePulse.icns"
  /usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"
  chmod 755 "$APP_BINARY"

  /usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
  /usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$INFO_PLIST"

  if ! /usr/bin/otool -l "$APP_BINARY" | /usr/bin/grep -A2 LC_RPATH | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
    /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_BINARY"
  fi

  # Finder metadata and resource forks are not part of the release bundle and
  # can make strict codesign verification fail on otherwise valid apps.
  clear_bundle_metadata
}

optionally_adhoc_sign() {
  if [[ "$ADHOC_SIGN" == "1" || "$ADHOC_SIGN" == "true" ]]; then
    echo "Applying optional ad-hoc signature"
    /usr/bin/codesign --force --sign - "$APP_BUNDLE"
    clear_bundle_metadata
  else
    echo "Signing: intentionally unsigned (no Developer ID or ad-hoc signature)"
  fi
}

verify_bundle() {
  local bundle_id bundle_executable display_name package_type short_version bundle_version minimum_system ls_ui_element icon_file architecture_info feed_url public_ed_key

  [[ -d "$APP_BUNDLE/Contents" ]] || die "missing app bundle Contents directory"
  [[ -f "$INFO_PLIST" ]] || die "missing app Info.plist"
  [[ -x "$APP_BINARY" ]] || die "missing executable: $APP_BINARY"
  [[ -f "$APP_RESOURCES/CodePulse.icns" ]] || die "missing app icon resource"
  [[ -d "$APP_FRAMEWORKS/Sparkle.framework" ]] || die "missing embedded Sparkle.framework"
  [[ -L "$APP_FRAMEWORKS/Sparkle.framework/Versions/Current" ]] || die "Sparkle.framework symlinks were not preserved"
  /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null || die "staged Info.plist is invalid"

  bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST")"
  bundle_executable="$(/usr/bin/plutil -extract CFBundleExecutable raw "$INFO_PLIST")"
  display_name="$(/usr/bin/plutil -extract CFBundleDisplayName raw "$INFO_PLIST")"
  package_type="$(/usr/bin/plutil -extract CFBundlePackageType raw "$INFO_PLIST")"
  short_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
  bundle_version="$(/usr/bin/plutil -extract CFBundleVersion raw "$INFO_PLIST")"
  minimum_system="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST")"
  ls_ui_element="$(/usr/bin/plutil -extract LSUIElement raw "$INFO_PLIST")"
  icon_file="$(/usr/bin/plutil -extract CFBundleIconFile raw "$INFO_PLIST")"
  feed_url="$(/usr/bin/plutil -extract SUFeedURL raw "$INFO_PLIST")"
  public_ed_key="$(/usr/bin/plutil -extract SUPublicEDKey raw "$INFO_PLIST")"

  [[ "$bundle_id" == "$BUNDLE_ID" ]] || die "bundle identifier mismatch: $bundle_id"
  [[ "$bundle_executable" == "$APP_NAME" ]] || die "executable metadata mismatch: $bundle_executable"
  [[ "$display_name" == "$APP_NAME" ]] || die "display name mismatch: $display_name"
  [[ "$package_type" == "APPL" ]] || die "package type mismatch: $package_type"
  [[ "$short_version" == "$VERSION" ]] || die "version mismatch: $short_version"
  [[ "$bundle_version" == "$BUILD_NUMBER" ]] || die "build number mismatch: $bundle_version"
  [[ "$minimum_system" == "13.0" ]] || die "minimum system mismatch: $minimum_system"
  [[ "$ls_ui_element" == "true" ]] || die "LSUIElement must remain enabled: $ls_ui_element"
  [[ "$icon_file" == "CodePulse" ]] || die "unexpected icon declaration: $icon_file"
  [[ "$feed_url" == "https://github.com/joewolly/codepulse/releases/latest/download/appcast.xml" ]] || die "unexpected Sparkle feed URL: $feed_url"
  [[ "$public_ed_key" == "EX4J6W41dIHFiPsqUhlk6Jp/VsX/2AxoYmCDlsqzuDM=" ]] || die "unexpected Sparkle public EdDSA key"

  architecture_info="$(/usr/bin/lipo -info "$APP_BINARY")"
  [[ "$architecture_info" == *arm64* && "$architecture_info" == *x86_64* ]] || die "final executable is not Universal 2: $architecture_info"
  /usr/bin/file "$APP_BINARY"

  /usr/bin/otool -L "$APP_BINARY" | /usr/bin/grep -F '@rpath/Sparkle.framework/' >/dev/null || die "final executable is not linked to Sparkle.framework"
  /usr/bin/otool -l "$APP_BINARY" | /usr/bin/grep -A2 LC_RPATH | /usr/bin/grep -F '@executable_path/../Frameworks' >/dev/null || die "final executable is missing the Sparkle framework rpath"

  if [[ "$ADHOC_SIGN" == "1" || "$ADHOC_SIGN" == "true" ]]; then
    /usr/bin/codesign --verify --strict --verbose=2 "$APP_BUNDLE"
  fi
}

create_dmg() {
  local dmg_root="$TEMP_DIR/dmg-root"
  echo "Creating $DMG_PATH"

  if [[ -L "$DMG_PATH" ]]; then
    die "refusing to replace symlinked DMG path: $DMG_PATH"
  fi
  if [[ -e "$DMG_PATH" ]]; then
    /bin/rm -f "$DMG_PATH"
  fi

  mkdir -p "$dmg_root"
  ditto "$APP_BUNDLE" "$dmg_root/$APP_NAME.app"
  ln -s /Applications "$dmg_root/Applications"

  /usr/bin/hdiutil create \
    -ov \
    -format UDZO \
    -volname "$VOLUME_NAME" \
    -srcfolder "$dmg_root" \
    "$DMG_PATH"
}

generate_checksum() {
  local digest
  digest="$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')"
  [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || die "could not generate SHA-256 checksum"
  if [[ -L "$CHECKSUMS_PATH" ]]; then
    die "refusing to replace symlinked checksum path: $CHECKSUMS_PATH"
  fi
  printf 'SHA256 (%s) = %s\n' "$(basename "$DMG_PATH")" "$digest" > "$CHECKSUMS_PATH"
  echo "SHA-256: $digest"
}

smoke_validate_artifact() {
  if [[ "$SKIP_SMOKE" == true ]]; then
    echo "Skipping DMG mount smoke validation (--skip-smoke)"
    return
  fi

  if [[ "$APP_ONLY" == true ]]; then
    echo "App-only mode: bundle validation is complete"
    return
  fi

  MOUNT_POINT="$TEMP_DIR/mounted"
  mkdir -p "$MOUNT_POINT"
  echo "Mounting DMG for read-only layout validation"
  /usr/bin/hdiutil attach \
    -nobrowse \
    -readonly \
    -mountpoint "$MOUNT_POINT" \
    "$DMG_PATH" >/dev/null
  MOUNTED=true

  local mounted_volume_name
  mounted_volume_name="$(/usr/sbin/diskutil info "$MOUNT_POINT" | /usr/bin/awk -F': ' '/Volume Name/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')"
  [[ "$mounted_volume_name" == "$VOLUME_NAME" ]] || die "unexpected DMG volume name: $mounted_volume_name"
  [[ -d "$MOUNT_POINT/$APP_NAME.app" ]] || die "DMG does not contain $APP_NAME.app"
  [[ -d "$MOUNT_POINT/$APP_NAME.app/Contents/Frameworks/Sparkle.framework" ]] || die "DMG app does not contain Sparkle.framework"
  [[ -L "$MOUNT_POINT/Applications" ]] || die "DMG does not contain an Applications symlink"
  [[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] || die "Applications symlink does not point to /Applications"

  /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null
  MOUNTED=false
  echo "DMG layout smoke validation passed"
}

main() {
  parse_options "$@"
  validate_environment
  determine_version
  prepare_workspace
  build_release
  stage_app_bundle
  optionally_adhoc_sign
  verify_bundle

  if [[ "$APP_ONLY" == true ]]; then
    echo "Release app ready: $APP_BUNDLE"
    smoke_validate_artifact
    return
  fi

  create_dmg
  generate_checksum
  smoke_validate_artifact
  echo "Release artifacts ready in $RELEASE_DIR"
}

main "$@"
