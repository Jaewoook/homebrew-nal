#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/formula_helpers.sh
source "${SCRIPT_DIR}/formula_helpers.sh"

FORMULA_NAME="${1:?Formula name argument required}"

if ! is_valid_formula_name "$FORMULA_NAME"; then
  echo "::error::Invalid formula name: $FORMULA_NAME" >&2
  exit 1
fi

git_bot_commit_and_push \
  "Formula/${FORMULA_NAME}.rb" \
  "No changes to commit for ${FORMULA_NAME}." \
  "Add bottle block for ${FORMULA_NAME} [skip ci]"
