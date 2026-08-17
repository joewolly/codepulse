#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodePulse"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$ROOT_DIR/dist/release/$APP_NAME.app}"

if [[ "$APP_BUNDLE" != /* ]]; then
  APP_BUNDLE="$ROOT_DIR/$APP_BUNDLE"
fi

[[ -d "$APP_BUNDLE" ]] || {
  echo "error: application bundle does not exist: $APP_BUNDLE" >&2
  exit 1
}

APP_BUNDLE="$(cd "$APP_BUNDLE" && pwd -P)"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
[[ -x "$APP_BINARY" ]] || {
  echo "error: packaged executable is missing or not executable: $APP_BINARY" >&2
  exit 1
}

OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codepulse-release-smoke.XXXXXX")"
OUTPUT_FILE="$OUTPUT_DIR/output.log"
PID=""

process_is_ours() {
  [[ -n "$PID" ]] || return 1
  kill -0 "$PID" >/dev/null 2>&1 || return 1
  local command_line
  command_line="$(ps -p "$PID" -o command= 2>/dev/null || true)"
  [[ "$command_line" == "$APP_BINARY" || "$command_line" == "$APP_BINARY "* ]]
}

cleanup() {
  if process_is_ours; then
    kill "$PID" >/dev/null 2>&1 || true
    for _ in {1..20}; do
      process_is_ours || break
      sleep 0.1
    done
    if process_is_ours; then
      kill -KILL "$PID" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$OUTPUT_DIR"
}
trap cleanup EXIT INT TERM

echo "Launching packaged application: $APP_BINARY"
"$APP_BINARY" >"$OUTPUT_FILE" 2>&1 &
PID=$!
echo "Started CodePulse PID $PID; waiting 5 seconds for survival"

for _ in {1..50}; do
  if ! process_is_ours; then
    set +e
    wait "$PID"
    STATUS=$?
    set -e

    echo "FAIL: CodePulse exited before the 5-second survival interval (status $STATUS)" >&2
    echo "--- captured stdout/stderr ---" >&2
    if [[ -s "$OUTPUT_FILE" ]]; then
      cat "$OUTPUT_FILE" >&2
    else
      echo "(no captured output)" >&2
    fi

    DIAGNOSTIC_DIR="${HOME:-}/Library/Logs/DiagnosticReports"
    if [[ -d "$DIAGNOSTIC_DIR" ]]; then
      RECENT_REPORTS="$(find "$DIAGNOSTIC_DIR" -maxdepth 1 -type f \( -name "$APP_NAME*.crash" -o -name "$APP_NAME*.ips" \) -mmin -5 -print 2>/dev/null | tail -5)"
      if [[ -n "$RECENT_REPORTS" ]]; then
        echo "--- recent crash reports ---" >&2
        printf '%s\n' "$RECENT_REPORTS" >&2
      fi
    fi
    exit 1
  fi
  sleep 0.1
done

if ! process_is_ours; then
  echo "FAIL: CodePulse exited at the end of the survival interval" >&2
  exit 1
fi

echo "PASS: packaged CodePulse remained alive for approximately 5 seconds"
