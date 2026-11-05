#!/usr/bin/env bash
set -euo pipefail
export SKIP_HOST_RESTORE=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR_CASK_SCRIPT="${SCRIPT_DIR}/scripts/mirror_cask.sh"
COMMIT_CASK_SCRIPT="${SCRIPT_DIR}/scripts/commit_cask.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

BARE_REPO="$TMP_DIR/remote.git"
WORK_DIR="$TMP_DIR/work"
git init --bare -q "$BARE_REPO"
git clone -q "$BARE_REPO" "$WORK_DIR"
cd "$WORK_DIR"
git checkout -b main -q
mkdir -p Casks mock_bin
touch .gitkeep
git add .gitkeep
git -c user.name="Test" -c user.email="test@test.com" commit -m "Initial commit" --no-gpg-sign -q
git push -u origin main -q

# 1. Test arm64-only cask rejection
cat <<'EOF' > "$WORK_DIR/Casks/arm_only.rb"
cask "arm_only" do
  version "1.0.0"
  depends_on arch: :arm64
  url "https://example.com/arm_only.dmg"
end
EOF

if bash "$MIRROR_CASK_SCRIPT" arm_only; then
  echo "Assertion failed: arm_only cask should be rejected"
  exit 1
fi

# 2. Test valid universal/x86_64 cask mirroring and URL rewrite
cat <<'EOF' > "$WORK_DIR/Casks/ghostty.rb"
cask "ghostty" do
  version "1.1.2"
  sha256 "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

  url "https://release.files.ghostty.org/#{version}/Ghostty.dmg"
  name "Ghostty"
  desc "Terminal emulator"
  homepage "https://ghostty.org/"

  app "Ghostty.app"
end
EOF

# Mock curl to write "test" (sha256: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08)
cat <<'EOF' > "$WORK_DIR/mock_bin/curl"
#!/usr/bin/env bash
OUT_FILE=""
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "-o" ]; then
    next=$((i+1))
    OUT_FILE="${!next}"
  fi
done
if [ -n "$OUT_FILE" ]; then
  printf "test" > "$OUT_FILE"
fi
exit 0
EOF
chmod +x "$WORK_DIR/mock_bin/curl"

OUT_FILE="$TMP_DIR/github_output.txt"
PATH="$WORK_DIR/mock_bin:$PATH" SKIP_ARCH_BINARY_MOUNT=true GITHUB_OUTPUT="$OUT_FILE" bash "$MIRROR_CASK_SCRIPT" ghostty

RELEASE_TAG=$(grep '^release_tag=' "$OUT_FILE" | cut -d= -f2-)
if [ "$RELEASE_TAG" != "cask-ghostty.1.1.2" ]; then
  echo "Assertion failed: expected release_tag=cask-ghostty.1.1.2, got '$RELEASE_TAG'"
  exit 1
fi

if ! grep -q 'url "https://github.com/Jaewoook/homebrew-nal/releases/download/cask-ghostty.1.1.2/Ghostty.dmg"' "$WORK_DIR/Casks/ghostty.rb"; then
  echo "Assertion failed: Casks/ghostty.rb url was not rewritten to mirrored GitHub release URL"
  cat "$WORK_DIR/Casks/ghostty.rb"
  exit 1
fi

# 3. Test multi-arch cask (on_arm before on_intel + multi-line sha256 arm:/intel:)
cat <<'EOF' > "$WORK_DIR/Casks/multi_arch.rb"
cask "multi_arch" do
  arch arm: "aarch64", intel: "x86_64"

  version "2.0.0"
  sha256 arm:   "0000000000000000000000000000000000000000000000000000000000000000",
         intel: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

  on_arm do
    url "https://example.com/multi_arch-#{version}-arm64.dmg"
  end
  on_intel do
    url "https://example.com/multi_arch-#{version}-#{arch}.dmg"
  end

  name "MultiArch"
  desc "Multi-arch cask test"
  homepage "https://example.com/"
end
EOF

PATH="$WORK_DIR/mock_bin:$PATH" SKIP_ARCH_BINARY_MOUNT=true GITHUB_OUTPUT="$OUT_FILE" bash "$MIRROR_CASK_SCRIPT" multi_arch

if ! grep -q 'url "https://github.com/Jaewoook/homebrew-nal/releases/download/cask-multi_arch.2.0.0/multi_arch-2.0.0-x86_64.dmg"' "$WORK_DIR/Casks/multi_arch.rb"; then
  echo "Assertion failed: multi_arch.rb Intel URL was not rewritten to mirrored x86_64 asset"
  cat "$WORK_DIR/Casks/multi_arch.rb"
  exit 1
fi

if grep -Eq '^[[:space:]]*intel:' "$WORK_DIR/Casks/multi_arch.rb"; then
  echo "Assertion failed: dangling intel: line left in multi_arch.rb"
  cat "$WORK_DIR/Casks/multi_arch.rb"
  exit 1
fi

# 4. Test commit_cask.sh
BOT_GPG_KEY="" GITHUB_OUTPUT="$OUT_FILE" bash "$COMMIT_CASK_SCRIPT" ghostty "1.1.2"
LATEST_MSG=$(git log -1 --format="%s")
if [ "$LATEST_MSG" != "cask(ghostty): mirror binary for 1.1.2" ]; then
  echo "Assertion failed: expected commit message 'cask(ghostty): mirror binary for 1.1.2', got '$LATEST_MSG'"
  exit 1
fi

echo "All mirror_cask and commit_cask tests passed!"
