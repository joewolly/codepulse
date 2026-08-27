#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodePulse"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/dist/release"
INFO_TEMPLATE="$ROOT_DIR/Resources/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/CodePulse.icns"
RELEASE_APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
APP_BUNDLE="$RELEASE_APP_BUNDLE"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
APP_HELPER_BINARY="$APP_HELPERS/codepulse-integration"
APP_CONTROL_BINARY="$APP_HELPERS/codepulsectl"
INFO_PLIST="$APP_CONTENTS/Info.plist"
VOLUME_NAME="CodePulse"

APP_ONLY=false
SKIP_SMOKE=false
ADHOC_SIGN="${CODEPULSE_ADHOC_SIGN:-1}"
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
ARM64_HELPER=""
X86_64_HELPER=""
UNIVERSAL_HELPER=""
ARM64_CONTROL=""
X86_64_CONTROL=""
UNIVERSAL_CONTROL=""
SPARKLE_FRAMEWORK=""

usage() {
  cat <<'USAGE'
Usage: ./script/package_release.sh [options]

Build a native CodePulse release app and an ad-hoc-signed drag-to-install DMG.

Options:
  --app-only     Build and validate CodePulse.app without creating a DMG.
  --skip-smoke   Skip the read-only DMG mount/install-layout validation.
  --adhoc-sign   Apply a local ad-hoc signature to the app bundle (default).
  --unsigned     Skip Apple code signing for diagnostic testing only.
  --help         Show this help text.

Version overrides:
  CODEPULSE_VERSION=1.4.0 CODEPULSE_BUILD=1400 ./script/package_release.sh
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
  local bundle_path="${1:-$APP_BUNDLE}"
  /usr/bin/xattr -cr "$bundle_path"
  /usr/bin/xattr -r -d com.apple.FinderInfo "$bundle_path" >/dev/null 2>&1 || true
  /usr/bin/xattr -r -d 'com.apple.fileprovider.fpfs#P' "$bundle_path" >/dev/null 2>&1 || true
}

copy_bundle_without_metadata() {
  local source_path="$1"
  local destination_path="$2"
  /usr/bin/ditto \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    "$source_path" \
    "$destination_path"
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
      --unsigned)
        ADHOC_SIGN=0
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

  for command in swift lipo hdiutil plutil file shasum xattr open diskutil ditto install_name_tool otool strip; do
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
  APP_BUNDLE="$TEMP_DIR/$APP_NAME.app"
  APP_CONTENTS="$APP_BUNDLE/Contents"
  APP_MACOS="$APP_CONTENTS/MacOS"
  APP_HELPERS="$APP_CONTENTS/Helpers"
  APP_RESOURCES="$APP_CONTENTS/Resources"
  APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
  APP_BINARY="$APP_MACOS/$APP_NAME"
  APP_HELPER_BINARY="$APP_HELPERS/codepulse-integration"
  APP_CONTROL_BINARY="$APP_HELPERS/codepulsectl"
  INFO_PLIST="$APP_CONTENTS/Info.plist"
  echo "Packaging CodePulse $VERSION (build $BUILD_NUMBER)"
  echo "Temporary build workspace: $TEMP_DIR"
}

build_release() {
  local arm64_scratch="$TEMP_DIR/build-arm64"
  local x86_64_scratch="$TEMP_DIR/build-x86_64"
  local arm64_bin_path x86_64_bin_path
  local source_prefix_map="$ROOT_DIR=/CodePulse"
  local arm64_scratch_prefix_map="$TEMP_DIR=/CodePulseBuild"
  local x86_64_scratch_prefix_map="$TEMP_DIR=/CodePulseBuild"

  echo "Building optimized arm64 release binary"
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$arm64_scratch" \
    --configuration release \
    --triple arm64-apple-macosx13.0 \
    --product "$APP_NAME" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$arm64_scratch_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$arm64_scratch_prefix_map"
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$arm64_scratch" \
    --configuration release \
    --triple arm64-apple-macosx13.0 \
    --product codepulse-integration \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$arm64_scratch_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$arm64_scratch_prefix_map"
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$arm64_scratch" \
    --configuration release \
    --triple arm64-apple-macosx13.0 \
    --product codepulsectl \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$arm64_scratch_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$arm64_scratch_prefix_map"
  arm64_bin_path="$(swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$arm64_scratch" \
    --configuration release \
    --triple arm64-apple-macosx13.0 \
    --show-bin-path \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$arm64_scratch_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$arm64_scratch_prefix_map")"
  ARM64_BINARY="$arm64_bin_path/$APP_NAME"
  ARM64_HELPER="$arm64_bin_path/codepulse-integration"
  ARM64_CONTROL="$arm64_bin_path/codepulsectl"
  SPARKLE_FRAMEWORK="$arm64_bin_path/Sparkle.framework"
  [[ -x "$ARM64_BINARY" ]] || die "SwiftPM did not produce the arm64 release executable: $ARM64_BINARY"
  [[ -x "$ARM64_HELPER" ]] || die "SwiftPM did not produce the arm64 integration helper: $ARM64_HELPER"
  [[ -x "$ARM64_CONTROL" ]] || die "SwiftPM did not produce the arm64 codepulsectl: $ARM64_CONTROL"
  [[ -d "$SPARKLE_FRAMEWORK" ]] || die "SwiftPM did not stage Sparkle.framework beside the arm64 release product"

  echo "Building optimized x86_64 release binary"
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$x86_64_scratch" \
    --configuration release \
    --triple x86_64-apple-macosx13.0 \
    --product "$APP_NAME" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$x86_64_scratch_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$x86_64_scratch_prefix_map"
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$x86_64_scratch" \
    --configuration release \
    --triple x86_64-apple-macosx13.0 \
    --product codepulse-integration \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$x86_64_scratch_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$x86_64_scratch_prefix_map"
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$x86_64_scratch" \
    --configuration release \
    --triple x86_64-apple-macosx13.0 \
    --product codepulsectl \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$x86_64_scratch_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$x86_64_scratch_prefix_map"
  x86_64_bin_path="$(swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$x86_64_scratch" \
    --configuration release \
    --triple x86_64-apple-macosx13.0 \
    --show-bin-path \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$x86_64_scratch_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$source_prefix_map" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$x86_64_scratch_prefix_map")"
  X86_64_BINARY="$x86_64_bin_path/$APP_NAME"
  X86_64_HELPER="$x86_64_bin_path/codepulse-integration"
  X86_64_CONTROL="$x86_64_bin_path/codepulsectl"
  [[ -x "$X86_64_BINARY" ]] || die "SwiftPM did not produce the x86_64 release executable: $X86_64_BINARY"
  [[ -x "$X86_64_HELPER" ]] || die "SwiftPM did not produce the x86_64 integration helper: $X86_64_HELPER"
  [[ -x "$X86_64_CONTROL" ]] || die "SwiftPM did not produce the x86_64 codepulsectl: $X86_64_CONTROL"
  [[ -d "$x86_64_bin_path/Sparkle.framework" ]] || die "SwiftPM did not stage Sparkle.framework beside the x86_64 release product"

  UNIVERSAL_BINARY="$TEMP_DIR/$APP_NAME-universal"
  /usr/bin/lipo -create -output "$UNIVERSAL_BINARY" "$ARM64_BINARY" "$X86_64_BINARY"
  UNIVERSAL_HELPER="$TEMP_DIR/codepulse-integration-universal"
  /usr/bin/lipo -create -output "$UNIVERSAL_HELPER" "$ARM64_HELPER" "$X86_64_HELPER"
  UNIVERSAL_CONTROL="$TEMP_DIR/codepulsectl-universal"
  /usr/bin/lipo -create -output "$UNIVERSAL_CONTROL" "$ARM64_CONTROL" "$X86_64_CONTROL"
  chmod 755 "$UNIVERSAL_BINARY"
  chmod 755 "$UNIVERSAL_HELPER"
  chmod 755 "$UNIVERSAL_CONTROL"

  local architecture_info
  architecture_info="$(/usr/bin/lipo -info "$UNIVERSAL_BINARY")"
  [[ "$architecture_info" == *arm64* && "$architecture_info" == *x86_64* ]] || die "Universal 2 validation failed: $architecture_info"
  echo "Architecture: $architecture_info"
  architecture_info="$(/usr/bin/lipo -info "$UNIVERSAL_HELPER")"
  [[ "$architecture_info" == *arm64* && "$architecture_info" == *x86_64* ]] || die "Universal 2 helper validation failed: $architecture_info"
  echo "Integration helper architecture: $architecture_info"
  architecture_info="$(/usr/bin/lipo -info "$UNIVERSAL_CONTROL")"
  [[ "$architecture_info" == *arm64* && "$architecture_info" == *x86_64* ]] || die "Universal 2 codepulsectl validation failed: $architecture_info"
  echo "codepulsectl architecture: $architecture_info"
}

stage_app_bundle() {
  echo "Staging $APP_NAME.app"
  if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
    [[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || die "refusing to replace non-directory app path: $APP_BUNDLE"
    /bin/rm -rf "$APP_BUNDLE"
  fi

  mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
  cp "$UNIVERSAL_BINARY" "$APP_BINARY"
  cp "$UNIVERSAL_HELPER" "$APP_HELPER_BINARY"
  cp "$UNIVERSAL_CONTROL" "$APP_CONTROL_BINARY"
  cp "$INFO_TEMPLATE" "$INFO_PLIST"
  cp "$ICON_SOURCE" "$APP_RESOURCES/CodePulse.icns"
  copy_bundle_without_metadata "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"
  chmod 755 "$APP_BINARY"
  chmod 755 "$APP_HELPER_BINARY"
  chmod 755 "$APP_CONTROL_BINARY"

  /usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
  /usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$INFO_PLIST"

  if ! /usr/bin/otool -l "$APP_BINARY" | /usr/bin/grep -A2 LC_RPATH | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
    /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_BINARY"
  fi

  # Swift release binaries can retain object/debug paths from the temporary
  # build workspace. Strip that metadata from the distributable executables;
  # it is not needed at runtime and must not leak local build paths.
  /usr/bin/strip -S "$APP_BINARY"
  /usr/bin/strip -S "$APP_HELPER_BINARY"
  /usr/bin/strip -S "$APP_CONTROL_BINARY"

  # Finder metadata and resource forks are not part of the release bundle and
  # can make strict codesign verification fail on otherwise valid apps.
  clear_bundle_metadata
}

optionally_adhoc_sign() {
  if [[ "$ADHOC_SIGN" == "1" || "$ADHOC_SIGN" == "true" ]]; then
    echo "Applying local ad-hoc signature"
    local signing_bundle="$APP_BUNDLE"
    local signing_helpers="$signing_bundle/Contents/Helpers"

    # The complete release bundle lives outside the checkout while it is
    # mutated and validated. This keeps Finder/File Provider metadata races
    # away from signing and strict verification.
    clear_bundle_metadata "$signing_bundle"

    # Sign nested executables before the outer app so the app seal contains
    # valid helper signatures. Sparkle ships its own ad-hoc-signed nested
    # framework components; preserve those signatures and verify them below.
    /usr/bin/codesign --force --sign - "$signing_helpers/codepulse-integration"
    /usr/bin/codesign --force --sign - "$signing_helpers/codepulsectl"
    /usr/bin/codesign --verify --strict --verbose=2 "$signing_helpers/codepulse-integration"
    /usr/bin/codesign --verify --strict --verbose=2 "$signing_helpers/codepulsectl"
    /usr/bin/codesign --verify --strict --verbose=2 "$signing_bundle/Contents/Frameworks/Sparkle.framework"
    /usr/bin/codesign --force --sign - "$signing_bundle"
    /usr/bin/codesign --verify --strict --verbose=2 "$signing_bundle"
  else
    echo "Signing: intentionally unsigned diagnostic bundle (no Developer ID or ad-hoc signature)"
  fi
}

verify_bundle() {
  local bundle_id bundle_executable display_name package_type short_version bundle_version minimum_system ls_ui_element icon_file architecture_info feed_url public_ed_key signature_details

  [[ -d "$APP_BUNDLE/Contents" ]] || die "missing app bundle Contents directory"
  [[ -f "$INFO_PLIST" ]] || die "missing app Info.plist"
  [[ -x "$APP_BINARY" ]] || die "missing executable: $APP_BINARY"
  [[ -x "$APP_HELPER_BINARY" ]] || die "missing integration helper: $APP_HELPER_BINARY"
  [[ -x "$APP_CONTROL_BINARY" ]] || die "missing codepulsectl: $APP_CONTROL_BINARY"
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
  architecture_info="$(/usr/bin/lipo -info "$APP_HELPER_BINARY")"
  [[ "$architecture_info" == *arm64* && "$architecture_info" == *x86_64* ]] || die "final integration helper is not Universal 2: $architecture_info"
  architecture_info="$(/usr/bin/lipo -info "$APP_CONTROL_BINARY")"
  [[ "$architecture_info" == *arm64* && "$architecture_info" == *x86_64* ]] || die "final codepulsectl is not Universal 2: $architecture_info"

  /usr/bin/otool -L "$APP_BINARY" | /usr/bin/grep -F '@rpath/Sparkle.framework/' >/dev/null || die "final executable is not linked to Sparkle.framework"
  /usr/bin/otool -l "$APP_BINARY" | /usr/bin/grep -A2 LC_RPATH | /usr/bin/grep -F '@executable_path/../Frameworks' >/dev/null || die "final executable is missing the Sparkle framework rpath"

  if [[ "$ADHOC_SIGN" == "1" || "$ADHOC_SIGN" == "true" ]]; then
    clear_bundle_metadata
    /usr/bin/codesign --verify --strict --verbose=2 "$APP_BUNDLE"
    signature_details="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
    [[ "$signature_details" == *"Identifier=$BUNDLE_ID"* ]] || die "ad-hoc signature identifier mismatch"
    [[ "$signature_details" == *"Signature=adhoc"* ]] || die "release app is not ad-hoc signed"
    [[ "$signature_details" == *"TeamIdentifier=not set"* ]] || die "release app unexpectedly has a signing team identifier"
    [[ "$signature_details" != *"Authority="* ]] || die "release app unexpectedly has a Developer ID certificate chain"
  fi
}

publish_release_bundle() {
  echo "Copying strictly verified app to $RELEASE_APP_BUNDLE"

  if [[ -L "$RELEASE_DIR" || ( -e "$RELEASE_DIR" && ! -d "$RELEASE_DIR" ) ]]; then
    die "refusing to use an unsafe release directory: $RELEASE_DIR"
  fi
  mkdir -p "$RELEASE_DIR"
  if [[ -L "$RELEASE_DIR" || ! -d "$RELEASE_DIR" ]]; then
    die "release directory is not a real directory: $RELEASE_DIR"
  fi

  if [[ -e "$RELEASE_APP_BUNDLE" || -L "$RELEASE_APP_BUNDLE" ]]; then
    [[ -d "$RELEASE_APP_BUNDLE" && ! -L "$RELEASE_APP_BUNDLE" ]] || die "refusing to replace non-directory app path: $RELEASE_APP_BUNDLE"
    /bin/rm -rf "$RELEASE_APP_BUNDLE"
  fi

  copy_bundle_without_metadata "$APP_BUNDLE" "$RELEASE_APP_BUNDLE"
  # The copy is no longer used for signing or strict validation. Remove only
  # transient metadata from this generated artifact; File Provider may
  # reattach FinderInfo to the developer checkout after this point.
  clear_bundle_metadata "$RELEASE_APP_BUNDLE"
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
  copy_bundle_without_metadata "$APP_BUNDLE" "$dmg_root/$APP_NAME.app"
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
  [[ -x "$MOUNT_POINT/$APP_NAME.app/Contents/Helpers/codepulse-integration" ]] || die "DMG app does not contain the integration helper"
  [[ -x "$MOUNT_POINT/$APP_NAME.app/Contents/Helpers/codepulsectl" ]] || die "DMG app does not contain codepulsectl"
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
  publish_release_bundle

  if [[ "$APP_ONLY" == true ]]; then
    echo "Release app ready: $RELEASE_APP_BUNDLE"
    smoke_validate_artifact
    return
  fi

  create_dmg
  generate_checksum
  smoke_validate_artifact
  echo "Release artifacts ready in $RELEASE_DIR"
}

main "$@"
