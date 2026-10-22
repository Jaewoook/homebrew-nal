#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/scripts/sync_formulas.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Formula"
mkdir -p "$TMP_DIR/mock_upstream/Formula/n"

# 1. Setup mock upstream:
# node.rb (version 26.0.0)
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/n/node.rb"
class Node < Formula
  desc "Node JavaScript runtime"
  url "https://nodejs.org/dist/v26.0.0/node-v26.0.0.tar.gz"
  version "26.0.0"
end
EOF

# node@24.rb (version 24.22.1)
cat <<'EOF' > "$TMP_DIR/mock_upstream/Formula/n/node@24.rb"
class NodeAT24 < Formula
  desc "Node JavaScript runtime (v24)"
  url "https://nodejs.org/dist/v24.22.1/node-v24.22.1.tar.gz"
  version "24.22.1"
end
EOF

# 2. Setup local tap with node.rb at version 24.0.0
cat <<'EOF' > "$TMP_DIR/Formula/node.rb"
class Node < Formula
  desc "Node JavaScript runtime"
  url "https://nodejs.org/dist/v24.0.0/node-v24.0.0.tar.gz"
  version "24.0.0"
end
EOF

# Initialize state JSON with local version 24.0.0
cat <<'EOF' > "$TMP_DIR/.formula-versions.json"
{
  "node": {
    "version": "24.0.0",
    "revision": 0,
    "sha256": "dummy"
  }
}
EOF

# 3. Run sync_formulas pointing to mock upstream
(
  cd "$TMP_DIR"
  UPSTREAM_RAW_BASE="file://${TMP_DIR}/mock_upstream" \
  UPSTREAM_API_BASE="file://${TMP_DIR}/mock_upstream/api" \
  bash "$SYNC_SCRIPT" --force node
)

# 4. Assertions:
# A. Formula/node.rb must be updated to 26.0.0
if ! grep -q 'version "26.0.0"' "$TMP_DIR/Formula/node.rb"; then
  echo "Assertion failed: Formula/node.rb was not updated to 26.0.0"
  exit 1
fi

# B. Formula/node@24.rb must have been automatically created and preserved
if [ ! -f "$TMP_DIR/Formula/node@24.rb" ]; then
  echo "Assertion failed: Formula/node@24.rb was not automatically created on major bump"
  exit 1
fi

if ! grep -q 'version "24.22.1"' "$TMP_DIR/Formula/node@24.rb"; then
  echo "Assertion failed: Formula/node@24.rb does not contain version 24.22.1"
  exit 1
fi

# C. .formula-versions.json must track node@24
NODE24_VER=$(jq -r '.["node@24"].version // empty' "$TMP_DIR/.formula-versions.json")
if [ "$NODE24_VER" != "24.22.1" ]; then
  echo "Assertion failed: .formula-versions.json does not track node@24 version (got: $NODE24_VER)"
  exit 1
fi

echo "All auto-preserve tests passed!"
