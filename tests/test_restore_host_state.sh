#!/usr/bin/env bash
# ==============================================================================
# test_restore_host_state.sh - Test suite for host environment restoration
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESTORE_SCRIPT="${REPO_ROOT}/scripts/restore_host_state.sh"

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# Create mock bins
MOCK_BIN="${TEST_TMP}/bin"
mkdir -p "$MOCK_BIN"

INTEL_BREW_LOG="${TEST_TMP}/intel_brew.log"
ARM64_BREW_LOG="${TEST_TMP}/arm64_brew.log"
ARM64_ENV_LOG="${TEST_TMP}/arm64_env.log"
ARM64_INSTALLED_FILE="${TEST_TMP}/arm64_installed.txt"
INTEL_CASK_INSTALLED_FILE="${TEST_TMP}/intel_cask_installed.txt"

cat <<'EOF' > "${MOCK_BIN}/intel_brew"
#!/usr/bin/env bash
echo "$@" >> "$INTEL_BREW_LOG"
case "$1" in
  list)
    if [[ " $* " == *" --cask "* ]]; then
      target="${@: -1}"
      if grep -q "^${target}$" "$INTEL_CASK_INSTALLED_FILE" 2>/dev/null; then
        echo "$target 1.0.0"
        exit 0
      fi
    fi
    exit 1
    ;;
  uninstall)
    exit 0
    ;;
  autoremove)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${MOCK_BIN}/intel_brew"

cat <<'EOF' > "${MOCK_BIN}/arm64_brew"
#!/usr/bin/env bash
echo "$@" >> "$ARM64_BREW_LOG"
printf 'CMAKE=%s|NONINTERACTIVE=%s|NO_AUTO_UPDATE=%s|NO_ASK=%s|PATH=%s\n' \
  "${CMAKE_APPLE_SILICON_PROCESSOR-<unset>}" \
  "${NONINTERACTIVE:-}" \
  "${HOMEBREW_NO_AUTO_UPDATE:-}" \
  "${HOMEBREW_NO_ASK:-}" \
  "${PATH}" >> "$ARM64_ENV_LOG"
case "$1" in
  list)
    # Target is the last argument
    target="${@: -1}"
    if grep -q "^${target}$" "$ARM64_INSTALLED_FILE" 2>/dev/null; then
      echo "$target 1.0.0"
      exit 0
    else
      exit 1
    fi
    ;;
  reinstall|install|uninstall)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${MOCK_BIN}/arm64_brew"

export INTEL_BREW_BIN="${MOCK_BIN}/intel_brew"
export ARM64_BREW_BIN="${MOCK_BIN}/arm64_brew"
export HOST_STATE_DIR="${TEST_TMP}/state"
export INTEL_BREW_LOG
export ARM64_BREW_LOG
export ARM64_ENV_LOG
export ARM64_INSTALLED_FILE
export INTEL_CASK_INSTALLED_FILE

echo "=== Test 1: Record and restore formula that was PREVIOUSLY INSTALLED (sanitized arm64 env) ==="
rm -f "$INTEL_BREW_LOG" "$ARM64_BREW_LOG" "$ARM64_ENV_LOG"
echo "mytool" > "$ARM64_INSTALLED_FILE"

CMAKE_APPLE_SILICON_PROCESSOR="x86_64" PATH="/usr/local/bin:/usr/bin:/bin" bash "$RESTORE_SCRIPT" record-state formula mytool
grep -q "PREV_INSTALLED=true" "${HOST_STATE_DIR}/formula_mytool.env"

CMAKE_APPLE_SILICON_PROCESSOR="x86_64" PATH="/usr/local/bin:/usr/bin:/bin" bash "$RESTORE_SCRIPT" restore formula mytool

# Check Intel brew uninstalled it
grep -q "uninstall --ignore-dependencies mytool" "$INTEL_BREW_LOG"
# Check ARM64 brew reinstalled it
grep -q "reinstall mytool" "$ARM64_BREW_LOG"
# Verify CMAKE_APPLE_SILICON_PROCESSOR unset, NONINTERACTIVE/NO_AUTO_UPDATE/NO_ASK set, and arm64 bin dir in PATH
if ! grep -q "CMAKE=<unset>|NONINTERACTIVE=1|NO_AUTO_UPDATE=1|NO_ASK=1|" "$ARM64_ENV_LOG" || \
   ! grep -q "PATH=.*${MOCK_BIN}" "$ARM64_ENV_LOG"; then
  echo "Assertion failed: run_arm64_brew env was not properly sanitized" >&2
  cat "$ARM64_ENV_LOG" >&2
  exit 1
fi
echo "Test 1 passed!"

echo "=== Test 2: Record and restore formula that was NOT PREVIOUSLY INSTALLED ==="
rm -f "$INTEL_BREW_LOG" "$ARM64_BREW_LOG"
rm -f "$ARM64_INSTALLED_FILE"
touch "$ARM64_INSTALLED_FILE"

bash "$RESTORE_SCRIPT" record-state formula uninstalled_tool
grep -q "PREV_INSTALLED=false" "${HOST_STATE_DIR}/formula_uninstalled_tool.env"

bash "$RESTORE_SCRIPT" restore formula uninstalled_tool

# Check Intel brew uninstalled it
grep -q "uninstall --ignore-dependencies uninstalled_tool" "$INTEL_BREW_LOG"
# Check ARM64 brew ensured uninstalled
grep -q "uninstall --ignore-dependencies uninstalled_tool" "$ARM64_BREW_LOG"
# Ensure reinstall was NOT called
if grep -q "reinstall uninstalled_tool" "$ARM64_BREW_LOG"; then
  echo "Error: reinstall should not be called for uninstalled package!" >&2
  exit 1
fi
echo "Test 2 passed!"

echo "=== Test 3: Cask untouched in Intel Homebrew skips unnecessary /opt/homebrew reinstall ==="
rm -f "$INTEL_BREW_LOG" "$ARM64_BREW_LOG" "$INTEL_CASK_INSTALLED_FILE"
touch "$INTEL_CASK_INSTALLED_FILE"
echo "ghostty" > "$ARM64_INSTALLED_FILE"

bash "$RESTORE_SCRIPT" record-state cask ghostty
grep -q "PREV_INSTALLED=true" "${HOST_STATE_DIR}/cask_ghostty.env"

bash "$RESTORE_SCRIPT" restore cask ghostty

if grep -q "reinstall --cask" "$ARM64_BREW_LOG" || grep -q "uninstall --cask" "$ARM64_BREW_LOG"; then
  echo "Error: untouched Intel cask must NOT reinstall/uninstall /opt/homebrew cask!" >&2
  cat "$ARM64_BREW_LOG" >&2
  exit 1
fi
echo "Test 3 passed!"

echo "=== Test 3b: Cask touched in Intel Homebrew triggers /usr/local uninstall and /opt/homebrew restore ==="
rm -f "$INTEL_BREW_LOG" "$ARM64_BREW_LOG"
echo "ghostty" > "$ARM64_INSTALLED_FILE"
echo "" > "$INTEL_CASK_INSTALLED_FILE"

bash "$RESTORE_SCRIPT" record-state cask ghostty
echo "ghostty" > "$INTEL_CASK_INSTALLED_FILE"
bash "$RESTORE_SCRIPT" restore cask ghostty

grep -q "uninstall --cask --force ghostty" "$INTEL_BREW_LOG"
grep -q "reinstall --cask --force ghostty" "$ARM64_BREW_LOG"
echo "Test 3b passed!"

echo "=== Test 4: Touched Intel Cask that was NOT PREVIOUSLY INSTALLED in ARM64 ==="
rm -f "$INTEL_BREW_LOG" "$ARM64_BREW_LOG"
rm -f "$ARM64_INSTALLED_FILE"
touch "$ARM64_INSTALLED_FILE"
echo "" > "$INTEL_CASK_INSTALLED_FILE"

bash "$RESTORE_SCRIPT" record-state cask non_installed_cask
echo "non_installed_cask" > "$INTEL_CASK_INSTALLED_FILE"
bash "$RESTORE_SCRIPT" restore cask non_installed_cask

# Check Intel brew uninstalled cask
grep -q "uninstall --cask --force non_installed_cask" "$INTEL_BREW_LOG"
# Check ARM64 brew uninstalled cask
grep -q "uninstall --cask --force non_installed_cask" "$ARM64_BREW_LOG"
# Ensure reinstall was NOT called
if grep -q "reinstall --cask" "$ARM64_BREW_LOG"; then
  echo "Error: reinstall --cask should not be called for uninstalled cask!" >&2
  exit 1
fi
echo "Test 4 passed!"

echo "=== Test 5: Graceful restoration when arm64 brew is not present ==="
rm -f "$INTEL_BREW_LOG" "$ARM64_BREW_LOG"
export ARM64_BREW_BIN="/nonexistent/bin/brew"

bash "$RESTORE_SCRIPT" record-state formula some_tool
bash "$RESTORE_SCRIPT" restore formula some_tool

grep -q "uninstall --ignore-dependencies some_tool" "$INTEL_BREW_LOG"
echo "Test 5 passed!"

echo "=== Test 6: Fallback when state file is missing ==="
export ARM64_BREW_BIN="${MOCK_BIN}/arm64_brew"
rm -f "$INTEL_BREW_LOG" "$ARM64_BREW_LOG"
echo "fallback_tool" > "$ARM64_INSTALLED_FILE"
rm -rf "$HOST_STATE_DIR"

bash "$RESTORE_SCRIPT" restore formula fallback_tool

grep -q "uninstall --ignore-dependencies fallback_tool" "$INTEL_BREW_LOG"
grep -q "reinstall fallback_tool" "$ARM64_BREW_LOG"
echo "Test 6 passed!"

echo "=== All test_restore_host_state tests passed! ==="
