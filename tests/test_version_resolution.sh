#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/scripts/sync_formulas.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_UPSTREAM="${TMP_DIR}/upstream"
MOCK_WORK="${TMP_DIR}/work"
mkdir -p \
  "${MOCK_UPSTREAM}/Formula/n" \
  "${MOCK_UPSTREAM}/Formula/l" \
  "${MOCK_UPSTREAM}/api" \
  "${MOCK_WORK}/scripts" \
  "${MOCK_WORK}/Formula"
cp "$SYNC_SCRIPT" "${MOCK_WORK}/scripts/sync_formulas.sh"
cp "${SCRIPT_DIR}/scripts/formula_helpers.sh" "${MOCK_WORK}/scripts/formula_helpers.sh"
echo "{}" > "${MOCK_WORK}/.formula-versions.json"
echo "{}" > "${MOCK_WORK}/.cask-versions.json"

cat <<'EOF' > "${MOCK_UPSTREAM}/Formula/n/node.rb"
class Node < Formula
  desc "Node latest"
  url "https://example.com/node-24.0.0.tar.xz"
end
EOF
echo '{"name":"node","versions":{"stable":"24.0.0"},"revision":0}' > "${MOCK_UPSTREAM}/api/node.json"

cat <<'EOF' > "${MOCK_UPSTREAM}/Formula/n/node@22.rb"
class NodeAT22 < Formula
  desc "Node 22"
  url "https://example.com/node-22.14.0.tar.xz"
end
EOF
echo '{"name":"node@22","versions":{"stable":"22.14.0"},"revision":0}' > "${MOCK_UPSTREAM}/api/node@22.json"

cat <<'EOF' > "${MOCK_UPSTREAM}/Formula/l/llvm@18.rb"
class LlvmAT18 < Formula
  desc "LLVM 18"
  url "https://example.com/llvm-18.1.8.src.tar.xz"
end
EOF
echo '{"name":"llvm@18","versions":{"stable":"18.1.8"},"revision":0}' > "${MOCK_UPSTREAM}/api/llvm@18.json"

# 1. Test CLI help does not have --versions option
HELP_OUT=$(bash "$SYNC_SCRIPT" --help)
if echo "$HELP_OUT" | grep -q -- "--versions"; then
  echo "Assertion failed: --versions should not exist in sync_formulas.sh help"
  exit 1
fi

# 2. Test dry-run with unversioned formula offline (checks "node" 24.0.0, not "node@22")
OUT_LATEST=$(
  cd "$MOCK_WORK"
  UPSTREAM_RAW_BASE="file://${MOCK_UPSTREAM}" UPSTREAM_API_BASE="file://${MOCK_UPSTREAM}/api" \
    bash "${MOCK_WORK}/scripts/sync_formulas.sh" --dry-run node
)
if ! echo "$OUT_LATEST" | grep -q "Checking formula: node" || ! echo "$OUT_LATEST" | grep -q "Upstream has newer version: 24.0.0"; then
  echo "Assertion failed: did not resolve mocked node 24.0.0: $OUT_LATEST"
  exit 1
fi
if echo "$OUT_LATEST" | grep -q "Checking formula: node@"; then
  echo "Assertion failed: unversioned formula unexpectedly checked versioned formulas"
  exit 1
fi

# 3. Test dry-run with explicit version formula (node@22)
OUT_SPECIFIC=$(
  cd "$MOCK_WORK"
  UPSTREAM_RAW_BASE="file://${MOCK_UPSTREAM}" UPSTREAM_API_BASE="file://${MOCK_UPSTREAM}/api" \
    bash "${MOCK_WORK}/scripts/sync_formulas.sh" --dry-run node@22
)
if ! echo "$OUT_SPECIFIC" | grep -q "Checking formula: node@22" || ! echo "$OUT_SPECIFIC" | grep -q "Upstream has newer version: 22.14.0"; then
  echo "Assertion failed: did not resolve mocked node@22 22.14.0: $OUT_SPECIFIC"
  exit 1
fi

# 4. Test dry-run --push does NOT mutate repo or push
git -C "$MOCK_WORK" init -q
git -C "$MOCK_WORK" checkout -b main -q
mkdir -p "${MOCK_WORK}/mock_bin"
cat <<'EOF' > "${MOCK_WORK}/mock_bin/git"
#!/usr/bin/env bash
if [ "${1:-}" = "push" ] || [ "${1:-}" = "pull" ]; then
  echo "ERROR: push/pull called during --dry-run" >&2
  exit 99
fi
exec /usr/bin/git "$@"
EOF
chmod +x "${MOCK_WORK}/mock_bin/git"

OUT_MULTI=$(
  cd "$MOCK_WORK"
  PATH="${MOCK_WORK}/mock_bin:$PATH" \
  UPSTREAM_RAW_BASE="file://${MOCK_UPSTREAM}" UPSTREAM_API_BASE="file://${MOCK_UPSTREAM}/api" \
    bash "${MOCK_WORK}/scripts/sync_formulas.sh" --dry-run --push node node@22 llvm@18
)
if ! echo "$OUT_MULTI" | grep -q "Checking formula: node" || \
   ! echo "$OUT_MULTI" | grep -q "Checking formula: node@22" || \
   ! echo "$OUT_MULTI" | grep -q "Checking formula: llvm@18" || \
   ! echo "$OUT_MULTI" | grep -q "Upstream has newer version: 18.1.8"; then
  echo "Assertion failed: multi-formula mock sync failed: $OUT_MULTI"
  exit 1
fi

# 5. Test prerelease -> final comparison (1.0.0-rc1 -> 1.0.0)
echo 'class Node < Formula; end' > "${MOCK_WORK}/Formula/node.rb"
jq '.node = {"version":"1.0.0-rc1","revision":0,"upstream_sha256":"old","last_updated":"2025-01-01T00:00:00Z"}' \
  "${MOCK_WORK}/.formula-versions.json" > "${TMP_DIR}/state.json" && mv "${TMP_DIR}/state.json" "${MOCK_WORK}/.formula-versions.json"
cat <<'EOF' > "${MOCK_UPSTREAM}/Formula/n/node.rb"
class Node < Formula
  desc "Node release"
  url "https://example.com/node-1.0.0.tar.xz"
end
EOF
echo '{"name":"node","versions":{"stable":"1.0.0"},"revision":0}' > "${MOCK_UPSTREAM}/api/node.json"
OUT_PRE=$(
  cd "$MOCK_WORK"
  UPSTREAM_RAW_BASE="file://${MOCK_UPSTREAM}" UPSTREAM_API_BASE="file://${MOCK_UPSTREAM}/api" \
    bash "${MOCK_WORK}/scripts/sync_formulas.sh" --dry-run node
)
if ! echo "$OUT_PRE" | grep -q "Upstream has newer version: 1.0.0 (local: 1.0.0-rc1)"; then
  echo "Assertion failed: final 1.0.0 should be considered newer than 1.0.0-rc1: $OUT_PRE"
  exit 1
fi

# 6. Missing -b argument should fail cleanly instead of unbound variable crash
if bash "$SYNC_SCRIPT" -b 2>/dev/null; then
  echo "Assertion failed: -b without value should exit non-zero"
  exit 1
fi

echo "All version resolution tests passed!"
