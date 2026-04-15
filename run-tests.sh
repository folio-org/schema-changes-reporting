#!/usr/bin/env bash
# Run all bats tests for schema-changes-reporting scripts.
# Requires: bats-core, jq, python3, bash 4+
#
# Usage:
#   ./run-tests.sh          # run all tests
#   ./run-tests.sh helpers  # run only helpers.bats
#   ./run-tests.sh -h       # help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$SCRIPT_DIR/.github/tests"

# ── Ensure bash 4+ (required for mapfile) ────────────────────────────────
BASH_BIN="bash"
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  # Try homebrew bash on macOS
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH_BIN="/usr/local/bin/bash"
  else
    echo "ERROR: bash 4+ required (mapfile). Install via: brew install bash" >&2
    exit 1
  fi
fi

# ── Check dependencies ───────────────────────────────────────────────────
for CMD in bats jq python3 git; do
  if ! command -v "$CMD" &>/dev/null; then
    echo "ERROR: '$CMD' not found. Install it first." >&2
    exit 1
  fi
done

# ── Help ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0 [test_name]

Examples:
  $0              # run all tests
  $0 helpers        # run only helpers.bats
  $0 refs-resolver  # run only refs-resolver.bats
  $0 report-builder # run only report-builder.bats (partial match)

Dependencies:
  brew install bats-core bash jq python3
EOF
  exit 0
fi

# ── Determine which tests to run ─────────────────────────────────────────
if [[ -n "${1:-}" ]]; then
  MATCH=$(find "$TESTS_DIR" -name "*${1}*.bats" 2>/dev/null | head -1)
  if [[ -z "$MATCH" ]]; then
    echo "ERROR: No test file matching '*${1}*.bats' found in $TESTS_DIR" >&2
    exit 1
  fi
  TARGET="$MATCH"
else
  TARGET="$TESTS_DIR"
fi

# ── Run ──────────────────────────────────────────────────────────────────
echo "Using bash: $BASH_BIN ($($BASH_BIN --version | head -1))"
echo "Running: $TARGET"
echo ""

# Put correct bash first in PATH so bats and child processes use it
export PATH="$(dirname "$BASH_BIN"):$PATH"
exec bats "$TARGET"

