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

FORMULA_NAME="${1:?Formula name argument required}"

if [[ ! "$FORMULA_NAME" =~ ^[a-zA-Z0-9._+-]+(@[0-9.]+)?$ ]]; then
  echo "::error::Invalid formula name: $FORMULA_NAME" >&2
  exit 1
fi

echo "=========================================="
echo "Building bottle for $FORMULA_NAME..."
echo "=========================================="

# Clean any lingering bottle archives from workspace
rm -f -- *.bottle.tar.gz *.bottle.json *.tar.gz

# Ensure tap and formula are trusted by Homebrew to avoid UntrustedTapError
/usr/local/bin/brew trust --tap jaewoook/nal 2>/dev/null || true
/usr/local/bin/brew trust --formula "jaewoook/nal/${FORMULA_NAME}" 2>/dev/null || true

# Determine formula version for release tag and title
FORMULA_VERSION=$(/usr/local/bin/brew ruby -e 'puts Formula["jaewoook/nal/#{ARGV[0]}"].pkg_version' -- "$FORMULA_NAME")
if [[ ! "$FORMULA_VERSION" =~ ^[a-zA-Z0-9._+-]+$ ]]; then
  echo "::error::Invalid formula version resolved for $FORMULA_NAME: $FORMULA_VERSION" >&2
  exit 1
fi

RELEASE_TAG="${FORMULA_NAME}.${FORMULA_VERSION}"
RELEASE_TITLE="${FORMULA_NAME} ${FORMULA_VERSION}"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "RELEASE_TAG=${RELEASE_TAG}" >> "$GITHUB_ENV"
  echo "RELEASE_TITLE=${RELEASE_TITLE}" >> "$GITHUB_ENV"
fi
echo "Prepared release target: $RELEASE_TITLE (tag: $RELEASE_TAG)"

# Check if target version is already built in the Cellar
NEEDS_INSTALL=1
if /usr/local/bin/brew ruby -e '
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
  if /usr/local/bin/brew list --formula --versions "$FORMULA_NAME" >/dev/null 2>&1; then
    echo "Uninstalling existing $FORMULA_NAME to prevent tap conflict..."
    /usr/local/bin/brew uninstall --ignore-dependencies "$FORMULA_NAME" || true
  fi
fi

# Pre-warm Homebrew API packages cache outside sandbox to avoid sandbox network errors during linkage fix
/usr/local/bin/brew ruby -e 'Homebrew::API::Internal.fetch_packages_api! rescue nil' 2>/dev/null || true

# Install dependencies first (allows source-building unbottled dependencies)
/usr/local/bin/brew install --only-dependencies "jaewoook/nal/$FORMULA_NAME"

if [ "$NEEDS_INSTALL" -eq 1 ]; then
  # Build formula from source with full dependency environment (avoids UnbottledError while preserving keg-only build tools like python@3.15)
  # Use --skip-link to prevent collisions with existing binaries in /usr/local/bin (bottling only needs the Cellar keg)
  /usr/local/bin/brew install --build-from-source --skip-post-install --skip-link "jaewoook/nal/$FORMULA_NAME"
fi

# Mark installed receipt as built_as_bottle so brew bottle accepts it
/usr/local/bin/brew ruby -e 'tab = Tab.for_formula(Formula["jaewoook/nal/#{ARGV[0]}"]); tab.built_as_bottle = true; tab.write' -- "$FORMULA_NAME"

/usr/local/bin/brew bottle --root-url="https://github.com/Jaewoook/homebrew-nal/releases/download/${RELEASE_TAG}" --json "jaewoook/nal/$FORMULA_NAME"

# Locate and merge bottle JSON metadata into formula
shopt -s nullglob
BOTTLE_JSON_FILES=("${FORMULA_NAME}"--*.bottle.json)
BOTTLE_JSON="${BOTTLE_JSON_FILES[0]:-}"
if [ -n "$BOTTLE_JSON" ] && [ -f "$BOTTLE_JSON" ]; then
  echo "Merging bottle information from $BOTTLE_JSON into Formula/${FORMULA_NAME}.rb..."
  /usr/local/bin/brew bottle --merge --write --no-commit "$BOTTLE_JSON"
else
  echo "::error::Bottle JSON file not found for $FORMULA_NAME!"
  exit 1
fi

# Normalize bottle archive filename: rename double-hyphen to single-hyphen
for f in "${FORMULA_NAME}"--*.tar.gz; do
  [ -f "$f" ] || continue
  TARGET_NAME="${f/--/-}"
  echo "Renaming bottle archive $f -> $TARGET_NAME"
  mv -- "$f" "$TARGET_NAME"
done
