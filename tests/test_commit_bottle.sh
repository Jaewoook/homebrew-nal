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

# 2. Verify GPG signature (when host keyring is accessible)
if gpg --list-secret-keys 024D4017DFF5360A >/dev/null 2>&1; then
  SIG_OUT=$(git log -1 --show-signature 2>&1)
  if ! echo "$SIG_OUT" | grep -q "Good signature from \"NAL System (NAL Git System) <nal-git-system@jaewook.me>\""; then
    echo "Assertion failed: commit was not properly signed by NAL Bot key."
    echo "$SIG_OUT"
    exit 1
  fi
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

# 4. Verify custom bot identity and optional unsigned commit behavior
cat <<'EOF' > Formula/demo.rb
class Demo < Formula
  desc "Demo formula update 2"
  # second bottle block update
end
EOF

BOT_NAME="Custom Builder" BOT_EMAIL="builder@example.com" BOT_GPG_KEY="" bash "$COMMIT_SCRIPT" demo

CUSTOM_AUTHOR=$(git log -1 --format="%an <%ae>")
if [ "$CUSTOM_AUTHOR" != "Custom Builder <builder@example.com>" ]; then
  echo "Assertion failed: custom author is '$CUSTOM_AUTHOR', expected 'Custom Builder <builder@example.com>'"
  exit 1
fi
SIG_STATUS=$(git log -1 --format="%G?")
if [ "$SIG_STATUS" != "N" ]; then
  echo "Assertion failed: BOT_GPG_KEY=\"\" should disable signing (got %G?='$SIG_STATUS', expected 'N')"
  git log -1 --show-signature || true
  exit 1
fi

# 5. Verify BOT_NO_PUSH=true leaves remote behind until git_bot_push_main, and concurrent push race retries cleanly
cat <<'EOF' > Formula/demo.rb
class Demo < Formula
  desc "Demo formula update 3"
end
EOF
BEFORE_REMOTE_SHA=$(git ls-remote origin refs/heads/main | awk '{print $1}')
NO_PUSH_OUT="$TMP_DIR/no_push_out.txt"
BOT_GPG_KEY="" BOT_NO_PUSH=true GITHUB_OUTPUT="$NO_PUSH_OUT" bash "$COMMIT_SCRIPT" demo
AFTER_LOCAL_SHA=$(git rev-parse HEAD)
AFTER_REMOTE_SHA=$(git ls-remote origin refs/heads/main | awk '{print $1}')
if [ "$AFTER_LOCAL_SHA" = "$BEFORE_REMOTE_SHA" ] || [ "$AFTER_REMOTE_SHA" != "$BEFORE_REMOTE_SHA" ]; then
  echo "Assertion failed: BOT_NO_PUSH=true should commit locally without pushing"
  exit 1
fi

# Advance remote from another clone on an unrelated file to verify pull --rebase + push in git_bot_push_main
CLONE2="$TMP_DIR/work2"
git clone -q "$BARE_REPO" "$CLONE2"
(
  cd "$CLONE2"
  git checkout -q main
  echo "other" > other.txt
  git add other.txt
  git -c user.name="Peer" -c user.email="peer@example.com" commit -m "Peer commit" --no-gpg-sign -q
  git push -q origin main
)

BOT_GPG_KEY="" GITHUB_OUTPUT="$NO_PUSH_OUT" bash -c "source \"${SCRIPT_DIR}/scripts/formula_helpers.sh\" && git_bot_push_main"
FINAL_REMOTE_SHA=$(git ls-remote origin refs/heads/main | awk '{print $1}')
FINAL_LOCAL_SHA=$(git rev-parse HEAD)
if [ "$FINAL_LOCAL_SHA" != "$FINAL_REMOTE_SHA" ] || [ ! -f other.txt ]; then
  echo "Assertion failed: git_bot_push_main did not rebase onto peer commit and push cleanly"
  exit 1
fi

echo "All commit_bottle signing and state restoration tests passed!"
