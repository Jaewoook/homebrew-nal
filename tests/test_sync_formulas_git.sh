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

echo "All sync_formulas git commit refactoring tests passed!"
