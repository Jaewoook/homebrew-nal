#!/usr/bin/env bash
set -euo pipefail

FORMULA_NAME="${1:?Formula name argument required}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git config commit.gpgsign false

git add "Formula/${FORMULA_NAME}.rb"
if ! git diff --staged --quiet; then
  git commit --no-gpg-sign -m "Add bottle block for ${FORMULA_NAME} [skip ci]"
  # Pull and rebase cleanly now that working tree is clean
  git pull --rebase origin main
  git push origin main
else
  echo "No changes to commit for ${FORMULA_NAME}."
fi

COMMIT_SHA=$(git rev-parse HEAD)
echo "commit_sha=$COMMIT_SHA" >> "$GITHUB_OUTPUT"
