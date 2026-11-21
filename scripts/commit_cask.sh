#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/formula_helpers.sh
source "${SCRIPT_DIR}/formula_helpers.sh"

CASK_NAME="${1:?Cask name argument required}"
CASK_VERSION="${2:-}"

if ! is_valid_cask_name "$CASK_NAME"; then
  echo "::error::Invalid cask name: $CASK_NAME" >&2
  exit 1
fi

CASK_FILE="Casks/${CASK_NAME}.rb"
if [[ -z "$CASK_VERSION" && -f "$CASK_FILE" ]]; then
  CASK_VERSION=$(grep -E '^[[:space:]]*version[[:space:]]+' "$CASK_FILE" | head -n 1 | awk '{print $2}' | tr -d '"'\''' | cut -d, -f1 || echo "latest")
fi

git_bot_commit_and_push \
  "$CASK_FILE" \
  "No changes to commit for cask ${CASK_NAME}." \
  "cask(${CASK_NAME}): mirror binary for ${CASK_VERSION}" \
  "[skip ci]"
