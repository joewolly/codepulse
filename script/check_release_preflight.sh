#!/usr/bin/env bash
set -euo pipefail

workflow_path="${1:-.github/workflows/release-preflight.yml}"
[[ -f "$workflow_path" ]] || {
  echo "error: missing release-preflight workflow: $workflow_path" >&2
  exit 1
}

fail() {
  echo "error: $*" >&2
  exit 1
}

validate_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

validate_build() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

assert_rejected_version() {
  if validate_version "$1"; then
    fail "hostile version fixture was accepted"
  fi
}

assert_rejected_build() {
  if validate_build "$1"; then
    fail "hostile build fixture was accepted"
  fi
}

validate_version "0.0.0" || fail "valid version fixture was rejected"
validate_build "1" || fail "valid build fixture was rejected"

for value in \
  '0.0.0"' \
  '0.0.0$(touch injected)' \
  '0.0.0; touch injected' \
  $'0.0.0\n1.0.0' \
  '--version' \
  '0.0'; do
  assert_rejected_version "$value"
done

for value in \
  '1"' \
  '1$(touch injected)' \
  '1; touch injected' \
  $'1\n2' \
  '--build' \
  '1.0'; do
  assert_rejected_build "$value"
done

awk '
  /^[[:space:]]+run:[[:space:]]*[|>]/ { in_run = 1; next }
  in_run && /^[^[:space:]]|^      - / { in_run = 0 }
  in_run && /\$\{\{[[:space:]]*inputs\./ {
    print "error: workflow_dispatch input interpolation appears in a run block at line " NR > "/dev/stderr"
    exit 1
  }
' "$workflow_path" || exit 1

! rg -q 'SPARKLE_PRIVATE_KEY_BASE64' "$workflow_path" ||
  fail "release preflight must not reference the production Sparkle key"
rg -q 'PREFLIGHT_VERSION: \$\{\{ inputs\.version \}\}' "$workflow_path" ||
  fail "version input is not passed through an environment variable"
rg -q 'PREFLIGHT_BUILD: \$\{\{ inputs\.build \}\}' "$workflow_path" ||
  fail "build input is not passed through an environment variable"
rg -q '\.build/artifacts/sparkle/Sparkle/bin' "$workflow_path" ||
  fail "release preflight does not use the deterministic Sparkle artifact path"

echo "Release preflight workflow safety checks passed"
