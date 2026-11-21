#!/usr/bin/env bash
set -euo pipefail

# Ensure execution under Rosetta 2 (x86_64) on Apple Silicon hosts
if [ "$(uname -m)" = "arm64" ]; then
  exec arch -x86_64 /bin/bash "$0" "$@"
fi

# Sanitize PATH to ensure Apple Silicon Homebrew (/opt/homebrew) is excluded
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

# Set architecture hints for tools like CMake
export CMAKE_APPLE_SILICON_PROCESSOR="x86_64"

# Disable prompts and auto-update in subshells
export HOMEBREW_NO_AUTO_UPDATE="1"
export HOMEBREW_NO_INSTALL_CLEANUP="1"
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK="1"
export HOMEBREW_NO_ASK="1"
export NONINTERACTIVE="1"

BREW_BIN="${INTEL_BREW_BIN:-/usr/local/bin/brew}"
FORMULA_NAME="${1:?Formula name argument required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/formula_helpers.sh
source "${SCRIPT_DIR}/formula_helpers.sh"

if ! is_valid_formula_name "$FORMULA_NAME"; then
  echo "::error::Invalid formula name: $FORMULA_NAME" >&2
  exit 1
fi

TEMP_LINKED_DEPS=()
RESTORE_HOST_STATE_ON_EXIT="false"
CLEANUP_DONE="false"

cleanup_on_exit() {
  [ "$CLEANUP_DONE" = "true" ] && return 0
  CLEANUP_DONE="true"

  local dep
  for dep in "${TEMP_LINKED_DEPS[@]+"${TEMP_LINKED_DEPS[@]}"}"; do
    if ! "$BREW_BIN" unlink --formula "$dep" >/dev/null; then
      echo "::warning::Failed to unlink temporary dependency: $dep" >&2
    fi
  done
  if [ "$RESTORE_HOST_STATE_ON_EXIT" = "true" ]; then
    bash "${SCRIPT_DIR}/restore_host_state.sh" restore formula "$FORMULA_NAME"
  fi
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

link_unlinked_dependencies() {
  local formula_name="$1"
  local unlinked_deps=""
  unlinked_deps=$("$BREW_BIN" ruby -e '
    # BEGIN_UNLINKED_DEPS_RUBY
    f = Formula["jaewoook/nal/#{ARGV[0]}"]
    seen = {}
    deps = f.recursive_dependencies do |dependent, dep|
      next Dependable::PRUNE if dep.prune_from_option?(dependent.build)
      next Dependable::PRUNE if dep.test? && !dep.build?
      next Dependable::PRUNE if dep.uses_from_macos? && dep.use_macos_install?
    end
    deps.each do |d|
      df = d.to_formula rescue nil
      next unless df
      next if df.keg_only? || !df.any_version_installed? || df.linked?
      next if seen[df.name]

      seen[df.name] = true
      if df.installed_kegs.size > 1
        $stderr.puts "::warning::Dependency #{df.name} has multiple installed versions in Cellar; brew link may fail without cleanup."
      end
      puts df.name
    end
    # END_UNLINKED_DEPS_RUBY
  ' -- "$formula_name")

  local dep
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    echo "Linking unlinked non-keg-only dependency before build: $dep"
    "$BREW_BIN" link --formula "$dep"
    TEMP_LINKED_DEPS+=("$dep")
  done <<< "$unlinked_deps"
}

if maybe_record_local_host_state "formula" "$FORMULA_NAME" "$SCRIPT_DIR"; then
  RESTORE_HOST_STATE_ON_EXIT="true"
fi

echo "=========================================="
echo "Building bottle for $FORMULA_NAME..."
echo "=========================================="

# Clean any lingering bottle archives from workspace
rm -f -- *.bottle.tar.gz *.bottle.json *.tar.gz

# Ensure tap and formula are trusted by Homebrew to avoid UntrustedTapError
"$BREW_BIN" trust --tap jaewoook/nal 2>/dev/null || true
"$BREW_BIN" trust --formula "jaewoook/nal/${FORMULA_NAME}" 2>/dev/null || true

# Determine formula version for release tag and title
FORMULA_VERSION=$("$BREW_BIN" ruby -e 'puts Formula["jaewoook/nal/#{ARGV[0]}"].pkg_version' -- "$FORMULA_NAME")
if [[ ! "$FORMULA_VERSION" =~ ^[a-zA-Z0-9._+-]+$ ]]; then
  echo "::error::Invalid formula version resolved for $FORMULA_NAME: $FORMULA_VERSION" >&2
  exit 1
fi

# Fail fast if the formula has an unsatisfied architecture requirement (e.g. depends_on arch: :arm64)
if ! "$BREW_BIN" ruby -e '
  f = Formula["jaewoook/nal/#{ARGV[0]}"]
  unsatisfied = f.requirements.select { |r| r.is_a?(ArchRequirement) && !r.satisfied? }
  unless unsatisfied.empty?
    $stderr.puts "::error::Formula #{ARGV[0]} (#{f.pkg_version}) cannot build on x86_64: #{unsatisfied.map(&:message).join("; ")}"
    exit 1
  end
' -- "$FORMULA_NAME"; then
  exit 1
fi

RELEASE_TAG="${FORMULA_NAME}.${FORMULA_VERSION}"
RELEASE_TITLE="${FORMULA_NAME} ${FORMULA_VERSION}"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "RELEASE_TAG=${RELEASE_TAG}" >> "$GITHUB_ENV"
  echo "RELEASE_TITLE=${RELEASE_TITLE}" >> "$GITHUB_ENV"
fi
echo "Prepared release target: $RELEASE_TITLE (tag: $RELEASE_TAG)"

# Attempt Fast-Path Binary Mirroring (GHCR x86_64/all bottle or standalone GitHub Release x86_64 binary)
if [ "${FORCE_SOURCE_BUILD:-false}" != "true" ] && [ -f "${SCRIPT_DIR}/try_mirror_formula_binary.sh" ]; then
  if bash "${SCRIPT_DIR}/try_mirror_formula_binary.sh" "$FORMULA_NAME" "$FORMULA_VERSION"; then
    echo "Fast-path binary mirror succeeded for $FORMULA_NAME ($FORMULA_VERSION)!"
    exit 0
  fi
  echo "Fast-path binary mirror not applicable for $FORMULA_NAME; falling back to source build..."
fi

# Check if target version is already built in the Cellar
NEEDS_INSTALL=1
if "$BREW_BIN" ruby -e '
  formula_name = ARGV[0]
  target_version = ARGV[1]
  f = Formula["jaewoook/nal/#{formula_name}"]
  tab = Tab.for_formula(f) rescue nil
  if f.installed_kegs.any? { |k| k.version.to_s == target_version }
    if tab && tab.source&.[]("tap") != "jaewoook/nal"
      tab.tap = Tap.fetch("jaewoook/nal") rescue nil
      tab.source["tap"] = "jaewoook/nal" if tab.source
      tab.write
    end
    exit 0
  end
  exit 1
' -- "$FORMULA_NAME" "$FORMULA_VERSION" 2>/dev/null; then
  echo "$FORMULA_NAME $FORMULA_VERSION is already built in the Cellar. Reusing existing build..."
  NEEDS_INSTALL=0
else
  # Uninstall existing formula if present to avoid cross-tap or version conflicts
  if "$BREW_BIN" list --formula --versions "$FORMULA_NAME" >/dev/null 2>&1; then
    echo "Uninstalling existing $FORMULA_NAME to prevent tap conflict..."
    "$BREW_BIN" uninstall --ignore-dependencies "$FORMULA_NAME" || true
  fi
fi

# Pre-warm Homebrew API packages cache outside sandbox to avoid sandbox network errors during linkage fix
"$BREW_BIN" ruby -e 'Homebrew::API::Internal.fetch_packages_api! rescue nil' 2>/dev/null || true

# Ensure installed non-keg-only dependencies are linked before --only-dependencies
# in case --only-dependencies compiles an unbottled dependency from source
link_unlinked_dependencies "$FORMULA_NAME"

# Install dependencies first (allows source-building unbottled dependencies)
"$BREW_BIN" install --only-dependencies "jaewoook/nal/$FORMULA_NAME"

if [ "$NEEDS_INSTALL" -eq 1 ]; then
  # Re-check in case any dependency installed or left by --only-dependencies is unlinked
  link_unlinked_dependencies "$FORMULA_NAME"
  # Build formula from source with full dependency environment (avoids UnbottledError while preserving keg-only build tools like python@3.15)
  # Use --skip-link to prevent collisions with existing binaries in /usr/local/bin (bottling only needs the Cellar keg)
  "$BREW_BIN" install --build-from-source --skip-post-install --skip-link "jaewoook/nal/$FORMULA_NAME"
fi

# Mark installed receipt as built_as_bottle so brew bottle accepts it
"$BREW_BIN" ruby -e 'tab = Tab.for_formula(Formula["jaewoook/nal/#{ARGV[0]}"]); tab.built_as_bottle = true; tab.write' -- "$FORMULA_NAME"

"$BREW_BIN" bottle --root-url="https://github.com/Jaewoook/homebrew-nal/releases/download/${RELEASE_TAG}" --json "jaewoook/nal/$FORMULA_NAME"

merge_rc=0
merge_and_normalize_bottle "$BREW_BIN" "$FORMULA_NAME" || merge_rc=$?
if [ "$merge_rc" -eq 2 ]; then
  echo "::error::Bottle JSON file not found for $FORMULA_NAME!"
  exit 1
elif [ "$merge_rc" -ne 0 ]; then
  exit "$merge_rc"
fi
