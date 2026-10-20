#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_DEPS_SCRIPT="${SCRIPT_DIR}/scripts/sync_dependencies.sh"
SYNC_FORMULAS_SCRIPT="${SCRIPT_DIR}/scripts/sync_formulas.sh"

if [ ! -f "$SYNC_DEPS_SCRIPT" ]; then
  echo "Error: $SYNC_DEPS_SCRIPT does not exist"
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Formula"
echo "{}" > "$TMP_DIR/.formula-versions.json"

# Create a mock upstream directory with a helper formula
MOCK_UPSTREAM="$TMP_DIR/upstream"
mkdir -p "$MOCK_UPSTREAM/Formula/h"
cat <<'EOF' > "$MOCK_UPSTREAM/Formula/h/helper.rb"
class Helper < Formula
  desc "Helper library"
  version "1.2.3"
end
EOF

# Create an app formula in local tap referencing helper
cat <<'EOF' > "$TMP_DIR/Formula/app.rb"
class App < Formula
  desc "Sample App"
  version "2.0.0"
  depends_on "cmake" => :build
  depends_on "helper"
end
EOF

# Run sync_dependencies with custom upstream url or base
bash "$SYNC_DEPS_SCRIPT" \
  --formula-dir "$TMP_DIR/Formula" \
  --state-file "$TMP_DIR/.formula-versions.json" \
  --upstream-base "file://${MOCK_UPSTREAM}" \
  --tap "jaewoook/nal" \
  app

# Verify that Formula/helper.rb was fetched
if [ ! -f "$TMP_DIR/Formula/helper.rb" ]; then
  echo "Assertion failed: Formula/helper.rb was not created"
  exit 1
fi

# Verify that app.rb has qualified dependency: depends_on "jaewoook/nal/helper"
if ! grep -Fq 'depends_on "jaewoook/nal/helper"' "$TMP_DIR/Formula/app.rb"; then
  echo "Assertion failed: app.rb dependency was not qualified"
  exit 1
fi

# Verify that .formula-versions.json contains helper with is_dependency: true
IS_DEP=$(jq -r '.helper.is_dependency // false' "$TMP_DIR/.formula-versions.json")
if [ "$IS_DEP" != "true" ]; then
  echo "Assertion failed: helper was not marked with is_dependency: true in .formula-versions.json"
  exit 1
fi

echo "All sync_dependencies tests passed!"
