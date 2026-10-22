#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECT_SCRIPT="${SCRIPT_DIR}/scripts/detect_formulas.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Formula"
mkdir -p "$TMP_DIR/scripts"

# Copy detect_formulas.sh to TMP_DIR
cp "$DETECT_SCRIPT" "$TMP_DIR/scripts/detect_formulas.sh"

# Create a dependency formula
cat <<'EOF' > "$TMP_DIR/Formula/dep_c.rb"
class DepC < Formula
  desc "Dep C"
end
EOF

# Create an intermediate dependency
cat <<'EOF' > "$TMP_DIR/Formula/dep_b.rb"
class DepB < Formula
  desc "Dep B"
  depends_on "jaewoook/nal/dep_c"
end
EOF

# Create a top-level formula
cat <<'EOF' > "$TMP_DIR/Formula/app_a.rb"
class AppA < Formula
  desc "App A"
  depends_on "jaewoook/nal/dep_b"
  depends_on "jaewoook/nal/dep_c"
end
EOF

OUTPUT_FILE="$TMP_DIR/output.txt"

# Run detect_formulas with out-of-order inputs: app_a, dep_c, dep_b
(
  cd "$TMP_DIR"
  FORMULA_INPUT="app_a dep_c dep_b" GITHUB_OUTPUT="$OUTPUT_FILE" bash scripts/detect_formulas.sh
)

# Extract formulas array from GITHUB_OUTPUT
FORMULAS_JSON=$(grep '^formulas=' "$OUTPUT_FILE" | cut -d= -f2-)

# Expected order: dep_c must come before dep_b, and dep_b must come before app_a
INDEX_C=$(echo "$FORMULAS_JSON" | jq 'index("dep_c")')
INDEX_B=$(echo "$FORMULAS_JSON" | jq 'index("dep_b")')
INDEX_A=$(echo "$FORMULAS_JSON" | jq 'index("app_a")')

if [ "$INDEX_C" -ge "$INDEX_B" ]; then
  echo "Assertion failed: dep_c ($INDEX_C) must come before dep_b ($INDEX_B)"
  exit 1
fi

if [ "$INDEX_B" -ge "$INDEX_A" ]; then
  echo "Assertion failed: dep_b ($INDEX_B) must come before app_a ($INDEX_A)"
  exit 1
fi

# Test versioned formula detection with app_a and app_a@2
cat <<'EOF' > "$TMP_DIR/Formula/app_a@2.rb"
class AppAAT2 < Formula
  desc "App A v2"
end
EOF

(
  cd "$TMP_DIR"
  FORMULA_INPUT="app_a app_a@2" GITHUB_OUTPUT="$OUTPUT_FILE" bash scripts/detect_formulas.sh
)

EXPANDED_JSON=$(grep '^formulas=' "$OUTPUT_FILE" | cut -d= -f2-)
if ! echo "$EXPANDED_JSON" | jq -e 'index("app_a")' >/dev/null || ! echo "$EXPANDED_JSON" | jq -e 'index("app_a@2")' >/dev/null; then
  echo "Assertion failed: detect_formulas did not detect app_a and app_a@2"
  exit 1
fi

echo "All detect_formulas ordering tests passed!"
