#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT_SCRIPT="${SCRIPT_DIR}/scripts/commit_bottle.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

BARE_REPO="$TMP_DIR/remote.git"
WORK_DIR="$TMP_DIR/work"

# Initialize bare remote
git init --bare -q "$BARE_REPO"

# Clone working copy
git clone -q "$BARE_REPO" "$WORK_DIR"
cd "$WORK_DIR"
git checkout -b main -q
touch .gitkeep
git add .gitkeep
git -c user.name="Test" -c user.email="test@test.com" commit -m "Initial commit" --no-gpg-sign -q
git push -u origin main -q

# Set a sentinel local config to ensure commit_bottle restores it
git config --local user.name "Original User"
git config --local user.email "original@example.com"

# Prepare formula change
mkdir -p Formula
cat <<'EOF' > Formula/demo.rb
class Demo < Formula
  desc "Demo formula"
  # bottle block update
end
EOF

# Execute commit_bottle script
OUTPUT_FILE="$TMP_DIR/output.txt"
GITHUB_OUTPUT="$OUTPUT_FILE" bash "$COMMIT_SCRIPT" demo

# 1. Verify commit author & committer
LATEST_AUTHOR=$(git log -1 --format="%an <%ae>")
LATEST_COMMITTER=$(git log -1 --format="%cn <%ce>")
if [ "$LATEST_AUTHOR" != "NAL Bot <nal-git-system@jaewook.me>" ]; then
  echo "Assertion failed: author is '$LATEST_AUTHOR', expected 'NAL Bot <nal-git-system@jaewook.me>'"
  exit 1
fi
if [ "$LATEST_COMMITTER" != "NAL Bot <nal-git-system@jaewook.me>" ]; then
  echo "Assertion failed: committer is '$LATEST_COMMITTER', expected 'NAL Bot <nal-git-system@jaewook.me>'"
  exit 1
fi

# 2. Verify GPG signature
SIG_OUT=$(git log -1 --show-signature 2>&1)
if ! echo "$SIG_OUT" | grep -q "Good signature from \"NAL System (NAL Git System) <nal-git-system@jaewook.me>\""; then
  echo "Assertion failed: commit was not properly signed by NAL Bot key."
  echo "$SIG_OUT"
  exit 1
fi

# 3. Verify local git config was restored
CURR_LOCAL_NAME=$(git config --local user.name || true)
CURR_LOCAL_EMAIL=$(git config --local user.email || true)
if [ "$CURR_LOCAL_NAME" != "Original User" ]; then
  echo "Assertion failed: local user.name was not restored (got: '$CURR_LOCAL_NAME')"
  exit 1
fi
if [ "$CURR_LOCAL_EMAIL" != "original@example.com" ]; then
  echo "Assertion failed: local user.email was not restored (got: '$CURR_LOCAL_EMAIL')"
  exit 1
fi

echo "All commit_bottle signing and state restoration tests passed!"
