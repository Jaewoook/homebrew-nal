#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUALIFY_SCRIPT="${SCRIPT_DIR}/scripts/qualify_dependencies.sh"

if [ ! -f "$QUALIFY_SCRIPT" ]; then
  echo "Error: $QUALIFY_SCRIPT does not exist"
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Formula"

# Create a dependency formula
cat <<'EOF' > "$TMP_DIR/Formula/bar.rb"
class Bar < Formula
  desc "Bar library"
end
EOF

# Create a dependent formula with:
# - an unqualified dependency that exists in Formula/ (bar)
# - an unqualified dependency that DOES NOT exist in Formula/ (baz)
# - an already tap-qualified dependency (jaewoook/nal/bar)
# - build and conditional dependencies
cat <<'EOF' > "$TMP_DIR/Formula/foo.rb"
class Foo < Formula
  desc "Foo program"
  depends_on "bar"
  depends_on "baz"
  depends_on "jaewoook/nal/bar"
  depends_on "bar" => :build
end
EOF

# Run qualify script pointing to the custom Formula dir
bash "$QUALIFY_SCRIPT" --formula-dir "$TMP_DIR/Formula" --tap "jaewoook/nal"

# Assertions
FOO_CONTENT=$(cat "$TMP_DIR/Formula/foo.rb")

# 1. "bar" should be replaced with "jaewoook/nal/bar"
if ! echo "$FOO_CONTENT" | grep -Fq 'depends_on "jaewoook/nal/bar"'; then
  echo "Assertion failed: depends_on \"bar\" was not qualified"
  exit 1
fi

# 2. "bar" => :build should be qualified
if ! echo "$FOO_CONTENT" | grep -Fq 'depends_on "jaewoook/nal/bar" => :build'; then
  echo "Assertion failed: depends_on \"bar\" => :build was not qualified"
  exit 1
fi

# 3. "baz" should NOT be qualified because Formula/baz.rb does not exist
if echo "$FOO_CONTENT" | grep -Fq 'depends_on "jaewoook/nal/baz"'; then
  echo "Assertion failed: depends_on \"baz\" was qualified even though baz.rb does not exist"
  exit 1
fi
if ! echo "$FOO_CONTENT" | grep -Fq 'depends_on "baz"'; then
  echo "Assertion failed: depends_on \"baz\" was altered"
  exit 1
fi

# 4. No double prefix (e.g. jaewoook/nal/jaewoook/nal/bar)
if echo "$FOO_CONTENT" | grep -Fq 'jaewoook/nal/jaewoook/nal/bar'; then
  echo "Assertion failed: double prefix detected"
  exit 1
fi

echo "All qualify_dependencies tests passed!"
