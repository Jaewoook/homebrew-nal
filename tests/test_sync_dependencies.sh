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
mkdir -p "$MOCK_UPSTREAM/Formula/h" "$MOCK_UPSTREAM/Formula/lib" "$MOCK_UPSTREAM/Formula/c" "$MOCK_UPSTREAM/Formula/l" "$MOCK_UPSTREAM/Patches/helper"
cat <<'EOF' > "$MOCK_UPSTREAM/Patches/helper/fix-paths.diff"
--- a/foo
+++ b/foo
@@ -1 +1 @@
-old
+new
EOF

cat <<'EOF' > "$MOCK_UPSTREAM/Formula/h/helper.rb"
class Helper < Formula
  desc "Helper library"
  url "https://example.com/helper-1.2.3-sources.tgz"
  depends_on "cmake" => [:build, :test]

  resource "extra" do
    url "https://example.com/extra-0.9.0.tar.gz"
  end

  fails_with :gcc do
    version "11"
  end

  patch do
    file "Patches/helper/fix-paths.diff"
  end
end
EOF

cat <<'EOF' > "$MOCK_UPSTREAM/Formula/lib/libfoo.rb"
class Libfoo < Formula
  desc "Libfoo library sharded under Formula/lib"
  version "1.0.0"
  depends_on "helper"
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

# Verify that referenced patch for dependency formula was downloaded
if [ ! -f "$TMP_DIR/Patches/helper/fix-paths.diff" ]; then
  echo "Assertion failed: Patches/helper/fix-paths.diff was not downloaded"
  exit 1
fi

# Verify accurate version extraction (must not pick up fails_with "11" or resource "0.9.0" or "unknown")
HELPER_VER=$(jq -r '.helper.version // empty' "$TMP_DIR/.formula-versions.json")
if [ "$HELPER_VER" != "1.2.3" ]; then
  echo "Assertion failed: expected helper version '1.2.3', got '$HELPER_VER'"
  exit 1
fi

# Verify existing valid state entry is not clobbered on re-run when formula already exists
jq '.helper.last_updated = "2020-01-01T00:00:00Z"' "$TMP_DIR/.formula-versions.json" > "$TMP_DIR/.state.tmp" && mv "$TMP_DIR/.state.tmp" "$TMP_DIR/.formula-versions.json"
bash "$SYNC_DEPS_SCRIPT" \
  --formula-dir "$TMP_DIR/Formula" \
  --state-file "$TMP_DIR/.formula-versions.json" \
  --upstream-base "file://${MOCK_UPSTREAM}" \
  --upstream-api-base "file://${MOCK_UPSTREAM}/api" \
  --tap "jaewoook/nal" \
  app
PRESERVED_TS=$(jq -r '.helper.last_updated // empty' "$TMP_DIR/.formula-versions.json")
if [ "$PRESERVED_TS" != "2020-01-01T00:00:00Z" ]; then
  echo "Assertion failed: existing valid state entry timestamp was overwritten (got '$PRESERVED_TS')"
  exit 1
fi

# Verify missing patch causes non-zero exit without creating formula/partial patch
mkdir -p "$MOCK_UPSTREAM/Formula/b"
cat <<'EOF' > "$MOCK_UPSTREAM/Formula/b/broken_dep.rb"
class BrokenDep < Formula
  desc "Missing patch dependency"
  url "https://example.com/broken-1.0.0.tar.gz"
  patch do
    file "Patches/broken_dep/missing.diff"
  end
end
EOF
cat <<'EOF' > "$TMP_DIR/Formula/app_broken.rb"
class AppBroken < Formula
  desc "Broken App"
  version "1.0.0"
  depends_on "broken_dep"
end
EOF
if bash "$SYNC_DEPS_SCRIPT" \
  --formula-dir "$TMP_DIR/Formula" \
  --state-file "$TMP_DIR/.formula-versions.json" \
  --upstream-base "file://${MOCK_UPSTREAM}" \
  --upstream-api-base "file://${MOCK_UPSTREAM}/api" \
  --tap "jaewoook/nal" \
  app_broken 2>/dev/null; then
  echo "Assertion failed: sync_dependencies should fail when a referenced patch fails to download"
  exit 1
fi
if [ -f "$TMP_DIR/Formula/broken_dep.rb" ] || [ -f "$TMP_DIR/Patches/broken_dep/missing.diff" ]; then
  echo "Assertion failed: broken_dep.rb or partial patch was left behind after failed patch download"
  exit 1
fi

echo "All sync_dependencies tests passed!"
