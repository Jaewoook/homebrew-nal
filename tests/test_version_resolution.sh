#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/scripts/sync_formulas.sh"

# 1. Test CLI help includes --versions
HELP_OUT=$(bash "$SYNC_SCRIPT" --help)
if ! echo "$HELP_OUT" | grep -q -- "--versions"; then
  echo "Assertion failed: --versions not found in sync_formulas.sh help"
  exit 1
fi

# 2. Test dry-run with default latest version (should check "node", not "node@22")
OUT_LATEST=$(bash "$SYNC_SCRIPT" --dry-run node)
if ! echo "$OUT_LATEST" | grep -q "Checking formula: node"; then
  echo "Assertion failed: default did not check node"
  exit 1
fi
if echo "$OUT_LATEST" | grep -q "Checking formula: node@"; then
  echo "Assertion failed: default (latest) unexpectedly checked versioned formulas"
  exit 1
fi

# 3. Test dry-run with explicit version formula (node@22)
OUT_SPECIFIC=$(bash "$SYNC_SCRIPT" --dry-run node@22)
if ! echo "$OUT_SPECIFIC" | grep -q "Checking formula: node@22"; then
  echo "Assertion failed: explicit version did not check node@22"
  exit 1
fi

# 4. Test dry-run with colon syntax (node:22)
OUT_COLON=$(bash "$SYNC_SCRIPT" --dry-run node:22)
if ! echo "$OUT_COLON" | grep -q "Checking formula: node@22"; then
  echo "Assertion failed: colon syntax did not check node@22"
  exit 1
fi

# 5. Test dry-run with --versions 20,22
OUT_MULTI=$(bash "$SYNC_SCRIPT" --dry-run --versions 20,22 node)
if ! echo "$OUT_MULTI" | grep -q "Checking formula: node@20"; then
  echo "Assertion failed: --versions did not check node@20"
  exit 1
fi
if ! echo "$OUT_MULTI" | grep -q "Checking formula: node@22"; then
  echo "Assertion failed: --versions did not check node@22"
  exit 1
fi

echo "All version resolution tests passed!"
