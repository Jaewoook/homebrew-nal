#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/scripts/sync_formulas.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Formula"
mkdir -p "$TMP_DIR/mock_upstream/Formula/n"

# Setup mock upstream: node 26.0.0 and node@24 24.22.1
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/n/node.rb"
class Node < Formula
  desc "Node JavaScript runtime"
  url "https://nodejs.org/dist/v26.0.0/node-v26.0.0.tar.gz"
  version "26.0.0"
end
EOF

cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/n/node@24.rb"
class NodeAT24 < Formula
  desc "Node JavaScript runtime (v24)"
  url "https://nodejs.org/dist/v24.22.1/node-v24.22.1.tar.gz"
  version "24.22.1"
end
EOF

# Setup local git repo
cd "$TMP_DIR"
git init -q
git checkout -b main -q
touch .gitkeep
git add .gitkeep
git -c user.name="Test" -c user.email="test@test.com" commit -m "Initial commit" --no-gpg-sign -q

# Set initial local formula at version 24.0.0
cat <<'EOF' > Formula/node.rb
class Node < Formula
  desc "Node JavaScript runtime"
  url "https://nodejs.org/dist/v24.0.0/node-v24.0.0.tar.gz"
  version "24.0.0"
end
EOF

cat <<'EOF' > .formula-versions.json
{
  "node": {
    "version": "24.0.0",
    "revision": 0,
    "sha256": "dummy"
  }
}
EOF
git add Formula/node.rb .formula-versions.json
git -c user.name="Test" -c user.email="test@test.com" commit -m "Add node 24" --no-gpg-sign -q

# Execute sync_formulas with --commit and --no-gpg-sign
UPSTREAM_RAW_BASE="file://${TMP_DIR}/mock_upstream" \
UPSTREAM_API_BASE="file://${TMP_DIR}/mock_upstream/api" \
bash "$SYNC_SCRIPT" --force --commit --no-gpg-sign node

# 1. Verify commit was created
LATEST_COMMIT_MSG=$(git log -1 --format="%s")
if [[ "$LATEST_COMMIT_MSG" != *"Update node formula to 26.0.0"* ]]; then
  echo "Assertion failed: unexpected commit message: '$LATEST_COMMIT_MSG'"
  exit 1
fi

# 2. Verify both node.rb and node@24.rb are in the commit
COMMIT_FILES=$(git show --stat --oneline HEAD)
if ! echo "$COMMIT_FILES" | grep -q "Formula/node.rb"; then
  echo "Assertion failed: Formula/node.rb not in commit"
  exit 1
fi
if ! echo "$COMMIT_FILES" | grep -q "Formula/node@24.rb"; then
  echo "Assertion failed: Formula/node@24.rb not in commit"
  exit 1
fi

# 3. Verify .git/config was NOT polluted with commit.gpgsign false
if git config --local commit.gpgsign 2>/dev/null; then
  echo "Assertion failed: .git/config contains local commit.gpgsign setting"
  exit 1
fi

# 4. Verify "unknown" state version falls back to formula version (does not block upgrade)
#    and referenced Patches/ files are downloaded and committed alongside formula
mkdir -p "$TMP_DIR/mock_upstream/Formula/g" "$TMP_DIR/mock_upstream/Patches/glibdemo"
echo "patch-bytes" > "$TMP_DIR/mock_upstream/Patches/glibdemo/fix.diff"
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/g/glibdemo.rb"
class Glibdemo < Formula
  desc "Demo with patch"
  url "https://example.com/glibdemo-2.0.0.tar.xz"
  patch do
    file "Patches/glibdemo/fix.diff"
  end
end
EOF
cat <<'EOF' > Formula/glibdemo.rb
class Glibdemo < Formula
  desc "Demo with patch"
  url "https://example.com/glibdemo-1.0.0.tar.xz"
end
EOF
jq '.glibdemo = {"version": "unknown", "revision": 0, "sha256": "dummy"}' .formula-versions.json > .state.tmp && mv .state.tmp .formula-versions.json
git add Formula/glibdemo.rb .formula-versions.json
git -c user.name="Test" -c user.email="test@test.com" commit -m "Add glibdemo with unknown state" --no-gpg-sign -q

UPSTREAM_RAW_BASE="file://${TMP_DIR}/mock_upstream" \
UPSTREAM_API_BASE="file://${TMP_DIR}/mock_upstream/api" \
bash "$SYNC_SCRIPT" --commit --no-gpg-sign glibdemo

if ! grep -q '2.0.0' Formula/glibdemo.rb; then
  echo "Assertion failed: glibdemo was not upgraded when state version was 'unknown'"
  exit 1
fi
if ! git show --stat HEAD | grep -q "Patches/glibdemo/fix.diff"; then
  echo "Assertion failed: Patches/glibdemo/fix.diff was not committed"
  exit 1
fi

# 5. Verify arm64-only macOS formula is skipped without modifying repo
mkdir -p "$TMP_DIR/mock_upstream/Formula/a"
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/a/armtool.rb"
class Armtool < Formula
  desc "ARM64 only"
  url "https://example.com/armtool-1.0.0.tar.gz"
  on_macos do
    depends_on arch: :arm64
  end
end
EOF
UPSTREAM_RAW_BASE="file://${TMP_DIR}/mock_upstream" \
UPSTREAM_API_BASE="file://${TMP_DIR}/mock_upstream/api" \
bash "$SYNC_SCRIPT" --commit --no-gpg-sign armtool
if [ -f Formula/armtool.rb ]; then
  echo "Assertion failed: arm64-only formula should not be synced"
  exit 1
fi

# 5b. Verify arm64-only unversioned formula falls back to latest Intel-compatible versioned sibling
mkdir -p "$TMP_DIR/mock_upstream/Formula/j"
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/j/jdkdemo.rb"
class Jdkdemo < Formula
  desc "JDK 27 arm64 only"
  url "https://example.com/jdkdemo-27.0.0.tar.gz"
  on_macos do
    depends_on arch: :arm64
  end
end
EOF
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/j/jdkdemo@26.rb"
class JdkdemoAT26 < Formula
  desc "JDK 26 also arm64 only"
  url "https://example.com/jdkdemo-26.0.0.tar.gz"
  on_macos do
    depends_on arch: :arm64
  end
end
EOF
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/j/jdkdemo@25.rb"
class JdkdemoAT25 < Formula
  desc "JDK 25 Intel compatible"
  url "https://example.com/jdkdemo-25.0.5.tar.gz"
end
EOF
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/j/jdkdemo@21.rb"
class JdkdemoAT21 < Formula
  desc "JDK 21 older Intel compatible"
  url "https://example.com/jdkdemo-21.0.9.tar.gz"
end
EOF

UPSTREAM_RAW_BASE="file://${TMP_DIR}/mock_upstream" \
UPSTREAM_API_BASE="file://${TMP_DIR}/mock_upstream/api" \
bash "$SYNC_SCRIPT" --commit --no-gpg-sign jdkdemo

if [ -f Formula/jdkdemo.rb ] || [ -f "Formula/jdkdemo@26.rb" ] || [ -f "Formula/jdkdemo@21.rb" ]; then
  echo "Assertion failed: unexpected jdkdemo variant synced"
  ls -la Formula/
  exit 1
fi
if [ ! -f "Formula/jdkdemo@25.rb" ]; then
  echo "Assertion failed: expected latest Intel-compatible fallback Formula/jdkdemo@25.rb"
  exit 1
fi
JDK25_VER=$(jq -r '.["jdkdemo@25"].version // empty' .formula-versions.json)
if [ "$JDK25_VER" != "25.0.5" ]; then
  echo "Assertion failed: expected jdkdemo@25 version 25.0.5 in state, got '$JDK25_VER'"
  exit 1
fi

# 6. Verify --with-deps commits dependency formula AND its referenced Patches/ file
mkdir -p "$TMP_DIR/mock_upstream/Formula/w" "$TMP_DIR/mock_upstream/Formula/d" "$TMP_DIR/mock_upstream/Patches/depwithpatch"
echo "dep-patch-bytes" > "$TMP_DIR/mock_upstream/Patches/depwithpatch/fix.diff"
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/d/depwithpatch.rb"
class Depwithpatch < Formula
  desc "Dependency with patch"
  url "https://example.com/depwithpatch-1.5.0.tar.xz"
  patch do
    file "Patches/depwithpatch/fix.diff"
  end
end
EOF
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/w/withdepapp.rb"
class Withdepapp < Formula
  desc "App with patched dependency"
  url "https://example.com/withdepapp-1.0.0.tar.xz"
  depends_on "depwithpatch"
end
EOF
UPSTREAM_RAW_BASE="file://${TMP_DIR}/mock_upstream" \
UPSTREAM_API_BASE="file://${TMP_DIR}/mock_upstream/api" \
bash "$SYNC_SCRIPT" --with-deps --commit --no-gpg-sign withdepapp

if [ ! -f Formula/depwithpatch.rb ] || [ ! -f Patches/depwithpatch/fix.diff ]; then
  echo "Assertion failed: --with-deps did not fetch dependency formula or its patch"
  exit 1
fi
if ! git show --stat HEAD | grep -q "Patches/depwithpatch/fix.diff"; then
  echo "Assertion failed: --with-deps dependency commit did not stage Patches/depwithpatch/fix.diff"
  exit 1
fi
if ! grep -Fq 'depends_on "jaewoook/nal/depwithpatch"' Formula/withdepapp.rb; then
  echo "Assertion failed: --with-deps did not qualify dependency in Formula/withdepapp.rb"
  exit 1
fi

echo "All sync_formulas git commit refactoring tests passed!"
