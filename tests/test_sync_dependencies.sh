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

# Create a mock upstream directory with helper (Formula/h/) and libfoo (Formula/lib/)
MOCK_UPSTREAM="$TMP_DIR/upstream"
mkdir -p "$MOCK_UPSTREAM/Formula/h" "$MOCK_UPSTREAM/Formula/lib" "$MOCK_UPSTREAM/Formula/c" "$MOCK_UPSTREAM/Formula/l"
cat <<'EOF' > "$MOCK_UPSTREAM/Formula/h/helper.rb"
class Helper < Formula
  desc "Helper library"
  version "1.2.3"
  depends_on "cmake" => [:build, :test]
end
EOF

cat <<'EOF' > "$MOCK_UPSTREAM/Formula/lib/libfoo.rb"
class Libfoo < Formula
  desc "Libfoo library sharded under Formula/lib"
  version "1.0.0"
end
EOF

cat <<'EOF' > "$MOCK_UPSTREAM/Formula/c/cmake.rb"
class Cmake < Formula
  desc "CMake build tool"
  version "4.0.0"
end
EOF

cat <<'EOF' > "$MOCK_UPSTREAM/Formula/l/linuxonly.rb"
class Linuxonly < Formula
  desc "Linux-only library"
  version "1.0.0"
end
EOF

# Create an app formula in local tap referencing helper, libfoo, cmake (build/test), and linuxonly (on_linux)
cat <<'EOF' > "$TMP_DIR/Formula/app.rb"
class App < Formula
  desc "Sample App"
  version "2.0.0"
  depends_on "cmake" => :build
  depends_on "cmake" => [:build, :test]
  depends_on "helper"
  depends_on "libfoo"

  on_linux do
    depends_on "linuxonly"
  end
end
EOF

# Run sync_dependencies with custom upstream url or base
bash "$SYNC_DEPS_SCRIPT" \
  --formula-dir "$TMP_DIR/Formula" \
  --state-file "$TMP_DIR/.formula-versions.json" \
  --upstream-base "file://${MOCK_UPSTREAM}" \
  --tap "jaewoook/nal" \
  app

# Verify that Formula/helper.rb and Formula/libfoo.rb were fetched
if [ ! -f "$TMP_DIR/Formula/helper.rb" ]; then
  echo "Assertion failed: Formula/helper.rb was not created"
  exit 1
fi
if [ ! -f "$TMP_DIR/Formula/libfoo.rb" ]; then
  echo "Assertion failed: Formula/libfoo.rb (under Formula/lib/) was not created"
  exit 1
fi

# Verify that build/test (cmake) and on_linux (linuxonly) dependencies were NOT fetched
if [ -f "$TMP_DIR/Formula/cmake.rb" ]; then
  echo "Assertion failed: build/test dependency cmake.rb should NOT be fetched"
  exit 1
fi
if [ -f "$TMP_DIR/Formula/linuxonly.rb" ]; then
  echo "Assertion failed: on_linux dependency linuxonly.rb should NOT be fetched"
  exit 1
fi

# Verify that app.rb has qualified runtime dependencies: helper and libfoo
if ! grep -Fq 'depends_on "jaewoook/nal/helper"' "$TMP_DIR/Formula/app.rb"; then
  echo "Assertion failed: app.rb helper dependency was not qualified"
  exit 1
fi
if ! grep -Fq 'depends_on "jaewoook/nal/libfoo"' "$TMP_DIR/Formula/app.rb"; then
  echo "Assertion failed: app.rb libfoo dependency was not qualified"
  exit 1
fi

# Verify that .formula-versions.json contains helper and libfoo with is_dependency: true
IS_DEP=$(jq -r '.helper.is_dependency // false' "$TMP_DIR/.formula-versions.json")
if [ "$IS_DEP" != "true" ]; then
  echo "Assertion failed: helper was not marked with is_dependency: true in .formula-versions.json"
  exit 1
fi
IS_LIBFOO_DEP=$(jq -r '.libfoo.is_dependency // false' "$TMP_DIR/.formula-versions.json")
if [ "$IS_LIBFOO_DEP" != "true" ]; then
  echo "Assertion failed: libfoo was not marked with is_dependency: true in .formula-versions.json"
  exit 1
fi

echo "All sync_dependencies tests passed!"
