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

FORMULA_NAME="${1:?Formula name argument required}"

echo "=========================================="
echo "Building bottle for $FORMULA_NAME..."
echo "=========================================="

# Clean any lingering bottle archives from workspace
rm -f *.bottle.tar.gz *.bottle.json *.tar.gz

# Uninstall existing formula if present to avoid cross-tap conflicts
if /usr/local/bin/brew list --formula --versions "$FORMULA_NAME" >/dev/null 2>&1; then
  echo "Uninstalling existing $FORMULA_NAME to prevent tap conflict..."
  /usr/local/bin/brew uninstall --ignore-dependencies "$FORMULA_NAME" || true
fi

# Install dependencies first (allows source-building unbottled dependencies)
/usr/local/bin/brew install --only-dependencies "jaewoook/nal/$FORMULA_NAME"

# Determine formula version for release tag and title
FORMULA_VERSION=$(/usr/local/bin/brew ruby -e 'puts Formula["jaewoook/nal/'"${FORMULA_NAME}"'"].pkg_version')
RELEASE_TAG="${FORMULA_NAME}.${FORMULA_VERSION}"
RELEASE_TITLE="${FORMULA_NAME} ${FORMULA_VERSION}"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "RELEASE_TAG=${RELEASE_TAG}" >> "$GITHUB_ENV"
  echo "RELEASE_TITLE=${RELEASE_TITLE}" >> "$GITHUB_ENV"
fi
echo "Prepared release target: $RELEASE_TITLE (tag: $RELEASE_TAG)"

# Build formula for bottling
/usr/local/bin/brew install --build-bottle "jaewoook/nal/$FORMULA_NAME"
/usr/local/bin/brew bottle --root-url="https://github.com/Jaewoook/homebrew-nal/releases/download/${RELEASE_TAG}" --json "jaewoook/nal/$FORMULA_NAME"

# Locate and merge bottle JSON metadata into formula
BOTTLE_JSON=$(ls ${FORMULA_NAME}--*.bottle.json 2>/dev/null | head -n 1 || true)
if [ -n "$BOTTLE_JSON" ] && [ -f "$BOTTLE_JSON" ]; then
  echo "Merging bottle information from $BOTTLE_JSON into Formula/${FORMULA_NAME}.rb..."
  /usr/local/bin/brew bottle --merge --write --no-commit "$BOTTLE_JSON"
else
  echo "::error::Bottle JSON file not found for $FORMULA_NAME!"
  exit 1
fi

# Normalize bottle archive filename: rename double-hyphen to single-hyphen
for f in ${FORMULA_NAME}--*.tar.gz; do
  [ -f "$f" ] || continue
  TARGET_NAME="${f/--/-}"
  echo "Renaming bottle archive $f -> $TARGET_NAME"
  mv "$f" "$TARGET_NAME"
done
