#!/usr/bin/env bash
# ==============================================================================
# test_build_bottle.sh - Test suite for build_bottle.sh dependency linking & cleanup
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/scripts/build_bottle.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

WORK_DIR="${TMP_DIR}/work"
MOCK_BIN="${TMP_DIR}/bin"
mkdir -p "$WORK_DIR" "$MOCK_BIN"

BREW_LOG="${TMP_DIR}/brew.log"
ARM64_LOG="${TMP_DIR}/arm64.log"
UNLINKED_STATE_FILE="${TMP_DIR}/unlinked_deps.txt"

cat <<'EOF' > "${MOCK_BIN}/intel_brew"
#!/usr/bin/env bash
set -euo pipefail
echo "$@" >> "$BREW_LOG"
case "$1" in
  trust)
    exit 0
    ;;
  ruby)
    script="${2:-}"
    if [ "$script" = "-e" ]; then
      code="${3:-}"
    else
      code="$script"
    fi
    if [[ "$code" == *"Utils::Bottles.tag"* ]]; then
      echo "sequoia"
      exit 0
    fi
    if [[ "$code" == *"ArchRequirement"* ]]; then
      exit 0
    fi
    if [[ "$code" == *"pkg_version"* ]]; then
      echo "1.0.0"
      exit 0
    fi
    if [[ "$code" == *"installed_kegs.any?"* ]]; then
      if [ "${MOCK_NEEDS_INSTALL:-1}" = "0" ]; then
        exit 0
      fi
      exit 1
    fi
    if [[ "$code" == *"fetch_packages_api"* ]]; then
      exit 0
    fi
    if [[ "$code" == *"recursive_dependencies"* ]]; then
      if [ -f "$UNLINKED_STATE_FILE" ]; then
        cat "$UNLINKED_STATE_FILE"
      fi
      exit 0
    fi
    if [[ "$code" == *"built_as_bottle = true"* ]]; then
      exit 0
    fi
    exit 0
    ;;
  list)
    exit 1
    ;;
  install)
    if [[ " $* " == *" --build-from-source "* ]]; then
      if [ -n "${MOCK_BUILD_SLEEP_SIGNAL_MARKER:-}" ]; then
        printf "%s\n" "$PPID" > "$MOCK_BUILD_SLEEP_SIGNAL_MARKER"
        sleep 1
      fi
      if [ "${MOCK_BUILD_FAIL:-0}" = "1" ]; then
        echo "Error: mock source build failure" >&2
        exit 1
      fi
    fi
    exit 0
    ;;
  link)
    dep="${@: -1}"
    if [ -n "${MOCK_LINK_FAIL_DEP:-}" ] && [ "$dep" = "$MOCK_LINK_FAIL_DEP" ]; then
      echo "Error: Could not symlink $dep due to mock conflict" >&2
      exit 1
    fi
    if [ -f "$UNLINKED_STATE_FILE" ]; then
      tmp_state=$(mktemp)
      grep -vxF "$dep" "$UNLINKED_STATE_FILE" > "$tmp_state" || true
      mv "$tmp_state" "$UNLINKED_STATE_FILE"
    fi
    exit 0
    ;;
  unlink)
    dep="${@: -1}"
    printf "%s\n" "$dep" >> "$UNLINKED_STATE_FILE"
    exit 0
    ;;
  bottle)
    if [[ " $* " == *" --merge "* ]]; then
      exit 0
    fi
    touch "demo--1.0.0.sequoia.bottle.json"
    touch "demo--1.0.0.sequoia.bottle.tar.gz"
    exit 0
    ;;
  uninstall|autoremove)
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
echo "$@" >> "$ARM64_LOG"
exit 1
EOF
chmod +x "${MOCK_BIN}/arm64_brew"

export INTEL_BREW_BIN="${MOCK_BIN}/intel_brew"
export ARM64_BREW_BIN="${MOCK_BIN}/arm64_brew"
export HOST_STATE_DIR="${TMP_DIR}/host_state"
export BREW_LOG
export ARM64_LOG
export UNLINKED_STATE_FILE
export FORCE_SOURCE_BUILD=true

log_line() {
  local pattern="$1"
  grep -nE "$pattern" "$BREW_LOG" | head -n 1 | cut -d: -f1 || true
}

reset_case() {
  rm -f "$BREW_LOG" "$ARM64_LOG" "$UNLINKED_STATE_FILE" "$WORK_DIR"/demo-*.tar.gz "$WORK_DIR"/demo-*.json "$TMP_DIR/signal_ready"
  touch "$UNLINKED_STATE_FILE"
  export MOCK_LINK_FAIL_DEP=""
  export MOCK_BUILD_FAIL=0
  export MOCK_NEEDS_INSTALL=1
  export MOCK_BUILD_SLEEP_SIGNAL_MARKER=""
}

echo "=== Test 1: Links unlinked deps before --only-dependencies & build, unlinks after build before restore ==="
reset_case
printf "jpeg-turbo\nlittle-cms2\n" > "$UNLINKED_STATE_FILE"

(
  cd "$WORK_DIR"
  env -u GITHUB_ACTIONS SKIP_HOST_RESTORE=false bash "$BUILD_SCRIPT" demo
)

link_jpeg_line=$(log_line "^link --formula jpeg-turbo$")
link_lcms_line=$(log_line "^link --formula little-cms2$")
only_deps_line=$(log_line "^install --only-dependencies ")
build_line=$(log_line "^install --build-from-source ")
unlink_jpeg_line=$(log_line "^unlink --formula jpeg-turbo$")
unlink_lcms_line=$(log_line "^unlink --formula little-cms2$")
restore_uninstall_line=$(log_line "^uninstall --ignore-dependencies demo$")

if [ -z "$link_jpeg_line" ] || [ -z "$link_lcms_line" ] || [ -z "$only_deps_line" ] || [ -z "$build_line" ] || [ -z "$unlink_jpeg_line" ] || [ -z "$unlink_lcms_line" ] || [ -z "$restore_uninstall_line" ]; then
  echo "Assertion failed: missing expected brew step in Test 1" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
if [ "$link_jpeg_line" -ge "$only_deps_line" ] || [ "$link_lcms_line" -ge "$only_deps_line" ] || [ "$only_deps_line" -ge "$build_line" ]; then
  echo "Assertion failed: deps must link before --only-dependencies and before --build-from-source" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
if [ "$unlink_jpeg_line" -le "$build_line" ] || [ "$unlink_lcms_line" -le "$build_line" ]; then
  echo "Assertion failed: temp links must only unlink after --build-from-source" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
if [ "$unlink_jpeg_line" -ge "$restore_uninstall_line" ] || [ "$unlink_lcms_line" -ge "$restore_uninstall_line" ]; then
  echo "Assertion failed: temp links must unlink before host state restoration" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
if [ "$(grep -c "^link --formula " "$BREW_LOG")" -ne 2 ] || [ "$(grep -c "^unlink --formula " "$BREW_LOG")" -ne 2 ]; then
  echo "Assertion failed: expected exactly 2 link and 2 unlink calls" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
if [ ! -f "$WORK_DIR/demo-1.0.0.sequoia.bottle.tar.gz" ]; then
  echo "Assertion failed: normalized bottle archive not found" >&2
  exit 1
fi
echo "Test 1 passed!"

echo "=== Test 2: No link/unlink calls when all dependencies are already linked ==="
reset_case

(
  cd "$WORK_DIR"
  env -u GITHUB_ACTIONS SKIP_HOST_RESTORE=true bash "$BUILD_SCRIPT" demo
)

if grep -qE "^(link|unlink) " "$BREW_LOG"; then
  echo "Assertion failed: unexpected link/unlink call when no unlinked deps exist" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
echo "Test 2 passed!"

echo "=== Test 3: Aborts before --only-dependencies/--build-from-source and restores partial links + host state on link failure ==="
reset_case
printf "jpeg-turbo\nlittle-cms2\n" > "$UNLINKED_STATE_FILE"
export MOCK_LINK_FAIL_DEP="little-cms2"

if (cd "$WORK_DIR" && env -u GITHUB_ACTIONS SKIP_HOST_RESTORE=false bash "$BUILD_SCRIPT" demo); then
  echo "Assertion failed: expected build_bottle.sh to fail when dep link fails" >&2
  exit 1
fi
if grep -qE "^install (--only-dependencies|--build-from-source)" "$BREW_LOG"; then
  echo "Assertion failed: install steps should not run after link failure" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
unlink_jpeg_line=$(log_line "^unlink --formula jpeg-turbo$")
restore_uninstall_line=$(log_line "^uninstall --ignore-dependencies demo$")
if [ -z "$unlink_jpeg_line" ] || [ -z "$restore_uninstall_line" ] || [ "$unlink_jpeg_line" -ge "$restore_uninstall_line" ]; then
  echo "Assertion failed: partial temp link must unlink before host state restoration on link error" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
echo "Test 3 passed!"

echo "=== Test 4: Error during --build-from-source unlinks all temp deps before restore_host_state runs ==="
reset_case
printf "jpeg-turbo\nlittle-cms2\n" > "$UNLINKED_STATE_FILE"
export MOCK_BUILD_FAIL=1

if (cd "$WORK_DIR" && env -u GITHUB_ACTIONS SKIP_HOST_RESTORE=false bash "$BUILD_SCRIPT" demo); then
  echo "Assertion failed: expected build_bottle.sh to fail when --build-from-source fails" >&2
  exit 1
fi
unlink_jpeg_line=$(log_line "^unlink --formula jpeg-turbo$")
unlink_lcms_line=$(log_line "^unlink --formula little-cms2$")
restore_uninstall_line=$(log_line "^uninstall --ignore-dependencies demo$")
if [ -z "$unlink_jpeg_line" ] || [ -z "$unlink_lcms_line" ] || [ -z "$restore_uninstall_line" ] || [ "$unlink_lcms_line" -ge "$restore_uninstall_line" ]; then
  echo "Assertion failed: expected full unlink + host restore order on build failure" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
echo "Test 4 passed!"

echo "=== Test 5: NEEDS_INSTALL=0 skips --build-from-source and GITHUB_ACTIONS=true skips host restore while unlinking temp deps ==="
reset_case
printf "jpeg-turbo\n" > "$UNLINKED_STATE_FILE"
export MOCK_NEEDS_INSTALL=0

(
  cd "$WORK_DIR"
  GITHUB_ACTIONS=true SKIP_HOST_RESTORE=false bash "$BUILD_SCRIPT" demo
)

if grep -q "^install --build-from-source" "$BREW_LOG"; then
  echo "Assertion failed: --build-from-source should be skipped when NEEDS_INSTALL=0" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
if grep -q "^uninstall --ignore-dependencies demo$" "$BREW_LOG"; then
  echo "Assertion failed: restore_host_state.sh should not run inside build_bottle.sh under GITHUB_ACTIONS=true" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
if ! grep -q "^unlink --formula jpeg-turbo$" "$BREW_LOG"; then
  echo "Assertion failed: temporary links should still unlink under GITHUB_ACTIONS=true" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
echo "Test 5 passed!"

echo "=== Test 6: SIGTERM cancellation unlinks temp deps and restores host state cleanly ==="
reset_case
printf "jpeg-turbo\n" > "$UNLINKED_STATE_FILE"
MARKER="${TMP_DIR}/signal_ready"
export MOCK_BUILD_SLEEP_SIGNAL_MARKER="$MARKER"

(
  cd "$WORK_DIR"
  exec env -u GITHUB_ACTIONS SKIP_HOST_RESTORE=false bash "$BUILD_SCRIPT" demo
) &
child_pid=$!

waited=0
while [ ! -s "$MARKER" ] && [ "$waited" -lt 50 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
if [ ! -s "$MARKER" ]; then
  kill -KILL "$child_pid" 2>/dev/null || true
  echo "Assertion failed: build process did not reach build step in time" >&2
  exit 1
fi

target_pid=$(cat "$MARKER")
kill -TERM "$target_pid"
set +e
wait "$child_pid"
term_status=$?
set -e

if [ "$term_status" -eq 0 ]; then
  echo "Assertion failed: expected non-zero exit status on SIGTERM" >&2
  exit 1
fi
if grep -q "^bottle " "$BREW_LOG"; then
  echo "Assertion failed: script continued past SIGTERM to bottle step" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
if ! grep -q "^unlink --formula jpeg-turbo$" "$BREW_LOG" || ! grep -q "^uninstall --ignore-dependencies demo$" "$BREW_LOG"; then
  echo "Assertion failed: SIGTERM must trigger temp unlink and host restore" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
echo "Test 6 passed!"

echo "=== Test 7: Ruby dependency filter evaluates correctly against Formula/Dependable semantics ==="
ruby_snippet=$(sed -n '/# BEGIN_UNLINKED_DEPS_RUBY/,/# END_UNLINKED_DEPS_RUBY/p' "$BUILD_SCRIPT")
if [ -z "$ruby_snippet" ]; then
  echo "Assertion failed: could not extract Ruby filter snippet from build_bottle.sh" >&2
  exit 1
fi

filter_out=$(ruby -e '
  module Dependable
    PRUNE = :prune
  end
  StubBuild = Struct.new(:unused)
  StubDep = Struct.new(:formula_obj, :test_flag, :build_flag, :macos_dep, :macos_ok, :opt_pruned) do
    def to_formula; formula_obj; end
    def test?; test_flag; end
    def build?; build_flag; end
    def uses_from_macos?; macos_dep; end
    def use_macos_install?; macos_ok; end
    def prune_from_option?(_b); opt_pruned; end
  end
  StubKegFormula = Struct.new(:name, :keg_only_val, :installed_val, :linked_val, :kegs_count) do
    def keg_only?; keg_only_val; end
    def any_version_installed?; installed_val; end
    def linked?; linked_val; end
    def installed_kegs; Array.new(kegs_count, :keg); end
  end
  f_jpeg = StubKegFormula.new("jpeg-turbo", false, true, false, 1)
  f_dup  = StubKegFormula.new("jpeg-turbo", false, true, false, 1)
  f_keg  = StubKegFormula.new("icu4c@79", true, true, false, 1)
  f_lnk  = StubKegFormula.new("libpng", false, true, true, 1)
  f_miss = StubKegFormula.new("harfbuzz", false, false, false, 0)
  f_test = StubKegFormula.new("pytest", false, true, false, 1)
  f_mac  = StubKegFormula.new("unzip", false, true, false, 1)
  f_opt  = StubKegFormula.new("optional-dep", false, true, false, 1)
  f_multi = StubKegFormula.new("brotli", false, true, false, 2)

  root = Object.new
  deps_list = [
    StubDep.new(f_jpeg, false, false, false, false, false),
    StubDep.new(f_dup,  false, false, false, false, false),
    StubDep.new(f_keg,  false, false, false, false, false),
    StubDep.new(f_lnk,  false, false, false, false, false),
    StubDep.new(f_miss, false, false, false, false, false),
    StubDep.new(f_test, true,  false, false, false, false),
    StubDep.new(f_mac,  false, true,  true,  true,  false),
    StubDep.new(f_opt,  false, false, false, false, true),
    StubDep.new(f_multi,false, true,  false, false, false),
  ]
  root.define_singleton_method(:build) { StubBuild.new }
  root.define_singleton_method(:recursive_dependencies) do |&blk|
    deps_list.reject { |d| blk && blk.call(root, d) == Dependable::PRUNE }
  end
  Formula = { "jaewoook/nal/demo" => root }
  ARGV.replace(["demo"])
'"$ruby_snippet" 2>"${TMP_DIR}/ruby_err.txt")

expected=$(printf "jpeg-turbo\nbrotli")
if [ "$filter_out" != "$expected" ]; then
  echo "Assertion failed: unexpected Ruby filter output: [$filter_out]" >&2
  exit 1
fi
if ! grep -q "Dependency brotli has multiple installed versions" "${TMP_DIR}/ruby_err.txt"; then
  echo "Assertion failed: expected warning for multi-version Cellar dep" >&2
  cat "${TMP_DIR}/ruby_err.txt" >&2
  exit 1
fi
echo "Test 7 passed!"

echo "=== Test 8: FORCE_SOURCE_BUILD=false delegates to fast-path binary mirroring before source build ==="
reset_case
mkdir -p "$TMP_DIR/fp_api/formula" "$TMP_DIR/fp_blobs" "$WORK_DIR/Formula"
echo "fast bottle" > "$TMP_DIR/fp_blobs/data.txt"
tar -czf "$TMP_DIR/fp_blobs/fast.tar.gz" -C "$TMP_DIR/fp_blobs" data.txt
FAST_SHA=$(shasum -a 256 "$TMP_DIR/fp_blobs/fast.tar.gz" | awk '{print $1}')

cat <<'EOF' > "$WORK_DIR/Formula/fastdemo.rb"
class Fastdemo < Formula
  desc "Fast demo"
  homepage "https://example.com"
  url "https://example.com/fastdemo-1.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
end
EOF
cat <<JSON > "$TMP_DIR/fp_api/formula/fastdemo.json"
{
  "name": "fastdemo",
  "versions": { "stable": "1.0.0" },
  "revision": 0,
  "bottle": {
    "stable": {
      "rebuild": 0,
      "files": {
        "sequoia": {
          "url": "file://${TMP_DIR}/fp_blobs/fast.tar.gz",
          "sha256": "${FAST_SHA}"
        }
      }
    }
  }
}
JSON

(
  cd "$WORK_DIR"
  FORCE_SOURCE_BUILD=false UPSTREAM_API_BASE="file://${TMP_DIR}/fp_api" \
    env -u GITHUB_ACTIONS SKIP_HOST_RESTORE=true bash "$BUILD_SCRIPT" fastdemo
)
if ! grep -q 'bottle do' "$WORK_DIR/Formula/fastdemo.rb" || [ ! -f "$WORK_DIR/fastdemo-1.0.0.sequoia.bottle.tar.gz" ]; then
  echo "Assertion failed: FORCE_SOURCE_BUILD=false did not mirror fast-path bottle via build_bottle.sh" >&2
  exit 1
fi
if grep -q "^install " "$BREW_LOG"; then
  echo "Assertion failed: source build should not run when fast-path succeeds" >&2
  cat "$BREW_LOG" >&2
  exit 1
fi
echo "Test 8 passed!"

echo "All build_bottle tests passed!"
