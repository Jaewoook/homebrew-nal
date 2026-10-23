#!/usr/bin/env bash
set -euo pipefail

FORMULA_NAME="${1:?Formula name argument required}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

BOT_NAME="${BOT_NAME:-NAL Bot}"
BOT_EMAIL="${BOT_EMAIL:-nal-git-system@jaewook.me}"
BOT_GPG_KEY="${BOT_GPG_KEY:-024D4017DFF5360A}"

# Preserve any existing local git config so the runner machine stays clean
ORIG_USER_NAME=$(git config --local user.name 2>/dev/null || true)
ORIG_USER_EMAIL=$(git config --local user.email 2>/dev/null || true)
ORIG_SIGNINGKEY=$(git config --local user.signingkey 2>/dev/null || true)
ORIG_GPGSIGN=$(git config --local commit.gpgsign 2>/dev/null || true)

restore_git_config() {
  if [ -n "$ORIG_USER_NAME" ]; then git config --local user.name "$ORIG_USER_NAME"; else git config --local --unset user.name 2>/dev/null || true; fi
  if [ -n "$ORIG_USER_EMAIL" ]; then git config --local user.email "$ORIG_USER_EMAIL"; else git config --local --unset user.email 2>/dev/null || true; fi
  if [ -n "$ORIG_SIGNINGKEY" ]; then git config --local user.signingkey "$ORIG_SIGNINGKEY"; else git config --local --unset user.signingkey 2>/dev/null || true; fi
  if [ -n "$ORIG_GPGSIGN" ]; then git config --local commit.gpgsign "$ORIG_GPGSIGN"; else git config --local --unset commit.gpgsign 2>/dev/null || true; fi
}
trap restore_git_config EXIT INT TERM

export GIT_AUTHOR_NAME="$BOT_NAME"
export GIT_AUTHOR_EMAIL="$BOT_EMAIL"
export GIT_COMMITTER_NAME="$BOT_NAME"
export GIT_COMMITTER_EMAIL="$BOT_EMAIL"

GIT_SIGN_ARGS=(
  -c user.name="$BOT_NAME"
  -c user.email="$BOT_EMAIL"
)

# Optional GPG signing: sign only if a key is provided and available in GPG keyring
if [ -n "$BOT_GPG_KEY" ] && gpg --list-secret-keys "$BOT_GPG_KEY" >/dev/null 2>&1; then
  GIT_SIGN_ARGS+=(
    -c user.signingkey="$BOT_GPG_KEY"
    -c commit.gpgsign=true
  )
else
  GIT_SIGN_ARGS+=(
    -c commit.gpgsign=false
  )
fi

git add "Formula/${FORMULA_NAME}.rb"
if ! git diff --staged --quiet; then
  git "${GIT_SIGN_ARGS[@]}" commit -m "Add bottle block for ${FORMULA_NAME} [skip ci]"
  # Pull and rebase cleanly now that working tree is clean
  git "${GIT_SIGN_ARGS[@]}" pull --rebase origin main
  git push origin main
else
  echo "No changes to commit for ${FORMULA_NAME}."
fi

COMMIT_SHA=$(git rev-parse HEAD)
echo "commit_sha=$COMMIT_SHA" >> "$GITHUB_OUTPUT"
