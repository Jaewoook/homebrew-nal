#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/scripts/sync_formulas.sh"

# 1. Test CLI help does not have --versions option
HELP_OUT=$(bash "$SYNC_SCRIPT" --help)
if echo "$HELP_OUT" | grep -q -- "--versions"; then
  echo "Assertion failed: --versions should not exist in sync_formulas.sh help"
  exit 1
fi

# 2. Test dry-run with unversioned formula (checks "node", not "node@22")
OUT_LATEST=$(bash "$SYNC_SCRIPT" --dry-run node)
if ! echo "$OUT_LATEST" | grep -q "Checking formula: node"; then
  echo "Assertion failed: did not check formula node"
  exit 1
fi
if echo "$OUT_LATEST" | grep -q "Checking formula: node@"; then
  echo "Assertion failed: unversioned formula unexpectedly checked versioned formulas"
  exit 1
fi

# 3. Test dry-run with explicit version formula (node@22)
OUT_SPECIFIC=$(bash "$SYNC_SCRIPT" --dry-run node@22)
if ! echo "$OUT_SPECIFIC" | grep -q "Checking formula: node@22"; then
  echo "Assertion failed: did not check formula node@22"
  exit 1
fi

# 4. Test dry-run with multiple formulas (both latest and versioned: node node@22 llvm@18)
OUT_MULTI=$(bash "$SYNC_SCRIPT" --dry-run node node@22 llvm@18)
if ! echo "$OUT_MULTI" | grep -q "Checking formula: node"; then
  echo "Assertion failed: multi did not check node"
  exit 1
fi
if ! echo "$OUT_MULTI" | grep -q "Checking formula: node@22"; then
  echo "Assertion failed: multi did not check node@22"
  exit 1
fi
if ! echo "$OUT_MULTI" | grep -q "Checking formula: llvm@18"; then
  echo "Assertion failed: multi did not check llvm@18"
  exit 1
fi

echo "All version resolution tests passed!"
