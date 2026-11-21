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

if ! grep -q 'sha256 arm:   "0000000000000000000000000000000000000000000000000000000000000000"' "$WORK_DIR/Casks/multi_arch.rb"; then
  echo "Assertion failed: multi_arch.rb ARM SHA256 was corrupted"
  cat "$WORK_DIR/Casks/multi_arch.rb"
  exit 1
fi

if ! grep -q 'intel: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"' "$WORK_DIR/Casks/multi_arch.rb"; then
  echo "Assertion failed: multi_arch.rb Intel SHA256 was not updated"
  cat "$WORK_DIR/Casks/multi_arch.rb"
  exit 1
fi

# 3b. Test multi-arch cask with sha256 inside on_arm and on_intel blocks (Docker style) + nested if/end + inline url kwargs
cat <<'EOF' > "$WORK_DIR/Casks/docker_style.rb"
cask "docker_style" do
  version "4.35.0"

  on_arm do
    if MacOS.version >= :sequoia
      sha256 "1111111111111111111111111111111111111111111111111111111111111111"
      url "https://example.com/docker-#{version}-arm64.dmg", verified: "example.com/"
    end
  end
  on_intel do
    if MacOS.version >= :sequoia
      sha256 "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
      url "https://example.com/docker-#{version}-amd64.dmg", verified: "example.com/"
    end
  end

  name "DockerStyle"
  desc "Docker style cask test"
  homepage "https://example.com/"
end
EOF

PATH="$WORK_DIR/mock_bin:$PATH" SKIP_ARCH_BINARY_MOUNT=true GITHUB_OUTPUT="$OUT_FILE" bash "$MIRROR_CASK_SCRIPT" docker_style

# Verify on_arm sha256 is intact
if ! grep -q 'sha256 "1111111111111111111111111111111111111111111111111111111111111111"' "$WORK_DIR/Casks/docker_style.rb"; then
  echo "Assertion failed: docker_style.rb on_arm sha256 was corrupted"
  cat "$WORK_DIR/Casks/docker_style.rb"
  exit 1
fi

# Verify on_intel url is rewritten without dangling verified: kwarg
if ! grep -q 'url "https://github.com/Jaewoook/homebrew-nal/releases/download/cask-docker_style.4.35.0/docker-4.35.0-amd64.dmg"$' "$WORK_DIR/Casks/docker_style.rb"; then
  echo "Assertion failed: docker_style.rb on_intel url was not cleanly rewritten"
  cat "$WORK_DIR/Casks/docker_style.rb"
  exit 1
fi

# 3c. Nested if..end BEFORE url/sha256 inside on_intel, intel: :no_check, and #{version.no_dots}
cat <<'EOF' > "$WORK_DIR/Casks/nested_intel.rb"
cask "nested_intel" do
  version "1.2.3"
  sha256 arm:   "1111111111111111111111111111111111111111111111111111111111111111",
         intel: :no_check

  on_intel do
    if MacOS.version < :sonoma
      caveats "Legacy macOS warning"
    end
    url "https://example.com/nested-#{version.no_dots}.dmg",
        verified: "example.com/",
        user_agent: :fake
  end

  name "NestedIntel"
end
EOF
PATH="$WORK_DIR/mock_bin:$PATH" SKIP_ARCH_BINARY_MOUNT=true GITHUB_OUTPUT="$OUT_FILE" bash "$MIRROR_CASK_SCRIPT" nested_intel
if ! grep -q 'url "https://github.com/Jaewoook/homebrew-nal/releases/download/cask-nested_intel.1.2.3/nested-123.dmg"' "$WORK_DIR/Casks/nested_intel.rb" || \
   grep -q 'intel: :no_check' "$WORK_DIR/Casks/nested_intel.rb" || \
   grep -q 'verified:\|user_agent:' "$WORK_DIR/Casks/nested_intel.rb"; then
  echo "Assertion failed: nested_intel.rb failed Critical #3 or Important #6 checks"
  cat "$WORK_DIR/Casks/nested_intel.rb"
  exit 1
fi

# 3d. Real Mach-O verification (SKIP_ARCH_BINARY_MOUNT=false)
if command -v clang >/dev/null 2>&1 && command -v lipo >/dev/null 2>&1; then
  echo 'int main(void){return 0;}' > "$TMP_DIR/hello.c"
  mkdir -p "$TMP_DIR/macho_arm" "$TMP_DIR/macho_x86"
  clang -arch arm64 "$TMP_DIR/hello.c" -o "$TMP_DIR/macho_arm/appbin"
  clang -arch x86_64 "$TMP_DIR/hello.c" -o "$TMP_DIR/macho_x86/appbin"
  (cd "$TMP_DIR/macho_arm" && zip -q "$TMP_DIR/arm_only.zip" appbin)
  tar -czf "$TMP_DIR/x86_ok.tar.gz" -C "$TMP_DIR/macho_x86" appbin

  ARM_ZIP_SHA=$(shasum -a 256 "$TMP_DIR/arm_only.zip" | awk '{print $1}')
  cat <<EOF > "$WORK_DIR/Casks/arm_zip_cask.rb"
cask "arm_zip_cask" do
  version "1.0.0"
  sha256 "${ARM_ZIP_SHA}"
  url "file://${TMP_DIR}/arm_only.zip"
  name "ArmZip"
end
EOF
  if SKIP_ARCH_BINARY_MOUNT=false bash "$MIRROR_CASK_SCRIPT" arm_zip_cask 2>/dev/null; then
    echo "Assertion failed: arm64-only zip should fail Mach-O x86_64 verification"
    exit 1
  fi

  cat <<'EOF' > "$WORK_DIR/Casks/corrupt_zip_cask.rb"
cask "corrupt_zip_cask" do
  version "1.0.0"
  sha256 :no_check
  url "https://example.com/corrupt.zip"
  name "CorruptZip"
end
EOF
  if PATH="$WORK_DIR/mock_bin:$PATH" SKIP_ARCH_BINARY_MOUNT=false bash "$MIRROR_CASK_SCRIPT" corrupt_zip_cask 2>/dev/null; then
    echo "Assertion failed: corrupt zip must fail extraction check instead of silently passing"
    exit 1
  fi

  X86_TGZ_SHA=$(shasum -a 256 "$TMP_DIR/x86_ok.tar.gz" | awk '{print $1}')
  cat <<EOF > "$WORK_DIR/Casks/x86_tgz_cask.rb"
cask "x86_tgz_cask" do
  version "1.0.0"
  sha256 "${X86_TGZ_SHA}"
  url "file://${TMP_DIR}/x86_ok.tar.gz"
  name "X86Tgz"
end
EOF
  SKIP_ARCH_BINARY_MOUNT=false GITHUB_OUTPUT="$OUT_FILE" bash "$MIRROR_CASK_SCRIPT" x86_tgz_cask
  if ! grep -q 'url "https://github.com/Jaewoook/homebrew-nal/releases/download/cask-x86_tgz_cask.1.0.0/x86_ok.tar.gz"' "$WORK_DIR/Casks/x86_tgz_cask.rb"; then
    echo "Assertion failed: valid x86_64 tar.gz did not pass Mach-O verification and rewrite"
    exit 1
  fi
fi

# 4. Test commit_cask.sh (subject line exact + [skip ci] in body)
BOT_GPG_KEY="" GITHUB_OUTPUT="$OUT_FILE" bash "$COMMIT_CASK_SCRIPT" ghostty "1.1.2"
LATEST_MSG=$(git log -1 --format="%s")
FULL_MSG=$(git log -1 --format="%B")
if [ "$LATEST_MSG" != "cask(ghostty): mirror binary for 1.1.2" ]; then
  echo "Assertion failed: expected commit message 'cask(ghostty): mirror binary for 1.1.2', got '$LATEST_MSG'"
  exit 1
fi
if ! echo "$FULL_MSG" | grep -q '\[skip ci\]'; then
  echo "Assertion failed: commit_cask.sh should include [skip ci] in commit body"
  exit 1
fi

echo "All mirror_cask and commit_cask tests passed!"
