#!/usr/bin/env bash
# ==============================================================================
# test_formula_helpers.sh - Unit tests for shared helpers in formula_helpers.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/formula_helpers.sh
source "${SCRIPT_DIR}/scripts/formula_helpers.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Test 1: Validation predicates and emit_github_output ==="
if ! is_valid_formula_name "openjdk@25" || ! is_valid_formula_name "gtk+3" || is_valid_formula_name "../bad" || is_valid_formula_name "app@beta"; then
  echo "Assertion failed: is_valid_formula_name behavior mismatch" >&2
  exit 1
fi
if ! is_valid_cask_name "ghostty@nightly" || is_valid_cask_name "bad/cask"; then
  echo "Assertion failed: is_valid_cask_name behavior mismatch" >&2
  exit 1
fi
if ! is_valid_formula_version "1.2.3" || is_valid_formula_version "unknown" || is_valid_formula_version "" || is_valid_formula_version "bad/ver"; then
  echo "Assertion failed: is_valid_formula_version behavior mismatch" >&2
  exit 1
fi

STDOUT_VAL=$(GITHUB_OUTPUT="" emit_github_output "test_key" "hello world")
if [ "$STDOUT_VAL" != "test_key=hello world" ]; then
  echo "Assertion failed: emit_github_output stdout mismatch: $STDOUT_VAL" >&2
  exit 1
fi
OUT_FILE="${TMP_DIR}/gh_out.txt"
GITHUB_OUTPUT="$OUT_FILE" emit_github_output "commit_sha" "abc123"
if [ "$(cat "$OUT_FILE")" != "commit_sha=abc123" ]; then
  echo "Assertion failed: emit_github_output file append mismatch" >&2
  exit 1
fi
echo "Test 1 passed!"

echo "=== Test 2: resolve_upstream_api_version & update_formula_state ==="
MOCK_BIN="${TMP_DIR}/bin"
mkdir -p "$MOCK_BIN"
cat <<'EOF' > "${MOCK_BIN}/curl"
#!/usr/bin/env bash
url="${!#}"
if [[ "$url" == *"/demo.json" ]]; then
  echo '{"versions":{"stable":"3.4.5"},"revision":2}'
  exit 0
fi
exit 1
EOF
chmod +x "${MOCK_BIN}/curl"

API_RES=$(PATH="${MOCK_BIN}:$PATH" resolve_upstream_api_version "demo" "https://api.example.test")
if [ "$API_RES" != "3.4.5|2" ]; then
  echo "Assertion failed: expected 3.4.5|2, got $API_RES" >&2
  exit 1
fi
MISS_RES=$(PATH="${MOCK_BIN}:$PATH" resolve_upstream_api_version "missing" "https://api.example.test")
if [ "$MISS_RES" != "|0" ]; then
  echo "Assertion failed: expected |0 fallback, got $MISS_RES" >&2
  exit 1
fi

STATE_FILE="${TMP_DIR}/state.json"
echo '{"demo":{"custom_note":"keep"}}' > "$STATE_FILE"
update_formula_state "$STATE_FILE" "demo" "3.4.5" 2 "deadbeef" "is_dependency"
if [ "$(jq -r '.demo.version' "$STATE_FILE")" != "3.4.5" ] || [ "$(jq -r '.demo.revision' "$STATE_FILE")" != "2" ] || [ "$(jq -r '.demo.is_dependency' "$STATE_FILE")" != "true" ] || [ "$(jq -r '.demo.custom_note' "$STATE_FILE")" != "keep" ]; then
  echo "Assertion failed: update_formula_state corrupted fields" >&2
  cat "$STATE_FILE" >&2
  exit 1
fi
echo "Test 2 passed!"

echo "=== Test 3: extract_formula_deps handles runtime vs --include-build, on_linux/on_arm, and taps ==="
cat <<'EOF' > "${TMP_DIR}/sample.rb"
class Sample < Formula
  depends_on "jaewoook/nal/libpng"
  depends_on "cmake" => :build
  depends_on "pytest" => :test
  depends_on "go" => [:build, :test]
  depends_on "gcc" if DevelopmentTools.clang_build_version <= 1500 # legacy
  depends_on :xcode # ignored symbol

  # depends_on "commented_out"
  on_linux do
    depends_on "alsa-lib"
  end
  on_arm do
    depends_on "arm_dep"
  end
end
EOF

RUNTIME_DEPS=$(extract_formula_deps "${TMP_DIR}/sample.rb" --tap "jaewoook/nal")
if [ "$RUNTIME_DEPS" != "libpng" ]; then
  echo "Assertion failed: expected only 'libpng' runtime dep, got: [$RUNTIME_DEPS]" >&2
  exit 1
fi

BUILD_AND_RUNTIME=$(extract_formula_deps "${TMP_DIR}/sample.rb" --include-build --strip-any-tap)
EXPECTED_BUILD_DEPS=$(printf "cmake\ngo\nlibpng")
if [ "$BUILD_AND_RUNTIME" != "$EXPECTED_BUILD_DEPS" ]; then
  echo "Assertion failed: expected cmake/go/libpng with --include-build, got: [$BUILD_AND_RUNTIME]" >&2
  exit 1
fi
echo "Test 3 passed!"

echo "=== Test 4: merge_and_normalize_bottle handles missing JSON and successful merge/rename ==="
BOTTLE_WORK="${TMP_DIR}/bottle_work"
mkdir -p "$BOTTLE_WORK"
export MOCK_BREW_LOG="${TMP_DIR}/mock_brew.log"
cat <<'EOF' > "${MOCK_BIN}/mock_brew"
#!/usr/bin/env bash
echo "$@" >> "$MOCK_BREW_LOG"
exit 0
EOF
chmod +x "${MOCK_BIN}/mock_brew"

(
  cd "$BOTTLE_WORK"
  rc=0
  merge_and_normalize_bottle "${MOCK_BIN}/mock_brew" "demo" || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "Assertion failed: expected rc=2 when bottle JSON missing, got $rc" >&2
    exit 1
  fi

  touch "demo--1.0.0.sequoia.bottle.json" "demo--1.0.0.sequoia.bottle.tar.gz"
  merge_and_normalize_bottle "${MOCK_BIN}/mock_brew" "demo"
  if [ ! -f "demo-1.0.0.sequoia.bottle.tar.gz" ]; then
    echo "Assertion failed: merged bottle tarball was not normalized" >&2
    exit 1
  fi
)
if ! grep -q "bottle --merge --write --no-commit demo--1.0.0.sequoia.bottle.json" "$MOCK_BREW_LOG"; then
  echo "Assertion failed: brew bottle --merge was not invoked" >&2
  exit 1
fi
echo "Test 4 passed!"

echo "=== Test 5: commit_bottle.sh handles no-changes cleanly and preserves local git config ==="
BARE_REPO="${TMP_DIR}/remote.git"
WORK_REPO="${TMP_DIR}/work_repo"
git init --bare -q "$BARE_REPO"
git clone -q "$BARE_REPO" "$WORK_REPO"
(
  cd "$WORK_REPO"
  git checkout -b main -q
  mkdir -p Formula
  echo "class Demo < Formula; end" > Formula/demo.rb
  git add Formula/demo.rb
  git -c user.name="Seed" -c user.email="seed@example.com" commit -m "Seed" --no-gpg-sign -q
  git push -u origin main -q

  git config --local user.name "Original Name"
  git config --local user.email "orig@example.com"
  NOOP_OUT="${TMP_DIR}/noop_out.txt"
  BOT_GPG_KEY="" GITHUB_OUTPUT="$NOOP_OUT" bash "${SCRIPT_DIR}/scripts/commit_bottle.sh" demo > "${TMP_DIR}/noop.log"
  if ! grep -q "No changes to commit for demo." "${TMP_DIR}/noop.log"; then
    echo "Assertion failed: expected no-changes message" >&2
    exit 1
  fi
  if [ "$(git config --local user.name)" != "Original Name" ] || [ "$(git config --local user.email)" != "orig@example.com" ]; then
    echo "Assertion failed: local git config not preserved after no-op commit" >&2
    exit 1
  fi
)
echo "Test 5 passed!"

echo "All formula_helpers tests passed!"
