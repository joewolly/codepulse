#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/docs/images"

mkdir -p "$OUTPUT_DIR"

TZ=UTC \
LC_ALL=en_US.UTF-8 \
CODEPULSE_SCREENSHOT_OUTPUT_DIR="$OUTPUT_DIR" \
swift test \
  --package-path "$ROOT_DIR" \
  --configuration debug \
  --filter ReadmeScreenshotTests/testGenerateReadmeScreenshots

for image in menu-bar-session history insights; do
  test -s "$OUTPUT_DIR/$image.png"
done

echo "README screenshots written to $OUTPUT_DIR"
