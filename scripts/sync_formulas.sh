#!/usr/bin/env bash
# ==============================================================================
# sync_formulas.sh - Upstream Formula Sync Script for Homebrew Taps
# ==============================================================================
set -euo pipefail

UPSTREAM_RAW_BASE="https://raw.githubusercontent.com/Homebrew/homebrew-core/master"
UPSTREAM_API_BASE="https://formulae.brew.sh/api/formula"
STATE_FILE=".formula-versions.json"
FORMULA_DIR="Formula"

# ------------------------------------------------------------------------------
# Default Options & Environment Overrides
# ------------------------------------------------------------------------------
FORMULAS=${FORMULAS:-"llvm gcc"}
FORCE_SYNC=${FORCE_SYNC:-"false"}
DRY_RUN=${DRY_RUN:-"false"}
AUTO_COMMIT=${AUTO_COMMIT:-"false"}
AUTO_PUSH=${AUTO_PUSH:-"false"}
GIT_BRANCH=${GIT_BRANCH:-"main"}

CLI_FORMULAS=()

# ------------------------------------------------------------------------------
# Parse CLI Arguments
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [formula1 formula2 ...]

Options:
  -f, --formulas LIST   Space- or comma-separated list of formula names
  --force               Force sync even if local and upstream versions match
  -d, --dry-run         Perform version check without saving or committing
  -c, --commit          Commit updated formula(s) to git
  -p, --push            Push commits to remote repository
  -b, --branch BRANCH   Target git branch (default: main)
  -h, --help            Show this help message

Environment Variables:
  FORMULAS, FORCE_SYNC, DRY_RUN, AUTO_COMMIT, AUTO_PUSH, GIT_BRANCH
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--formulas)
      FORMULAS="$2"
      shift 2
      ;;
    --force)
      FORCE_SYNC="true"
      shift
      ;;
    -d|--dry-run)
      DRY_RUN="true"
      shift
      ;;
    -c|--commit)
      AUTO_COMMIT="true"
      shift
      ;;
    -p|--push)
      AUTO_PUSH="true"
      shift
      ;;
    -b|--branch)
      GIT_BRANCH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      ;;
    *)
      CLI_FORMULAS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#CLI_FORMULAS[@]} -gt 0 ]]; then
  FORMULAS="${CLI_FORMULAS[*]}"
fi

# Normalize formulas list (replace commas with spaces)
FORMULAS=$(echo "$FORMULAS" | tr ',' ' ')

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

# Cross-platform SHA256 checksum (macOS shasum vs Linux sha256sum)
calc_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    echo "Error: No sha256 utility (sha256sum, shasum, openssl) found!" >&2
    exit 1
  fi
}

# Version comparison using sort -V
# Returns 0 (true) if upstream is strictly newer than local, 1 (false) otherwise
is_upstream_newer() {
  local v_up="$1"
  local r_up="${2:-0}"
  local v_loc="$3"
  local r_loc="${4:-0}"

  # If no local version exists, upstream is definitely newer
  if [[ -z "$v_loc" ]]; then
    return 0
  fi

  # If version strings match, compare revisions numerically
  if [[ "$v_up" == "$v_loc" ]]; then
    if (( r_up > r_loc )); then
      return 0
    else
      return 1
    fi
  fi

  # Compare versions using sort -V (version sort)
  local newest
  newest=$(printf "%s\n%s\n" "$v_loc" "$v_up" | sort -V | tail -n 1)
  if [[ "$newest" == "$v_up" ]]; then
    return 0
  else
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Dependency Verification
# ------------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' is required to parse Homebrew JSON metadata. Please install jq." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: 'curl' is required to fetch upstream formulas. Please install curl." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Main Sync Logic
# ------------------------------------------------------------------------------
mkdir -p "$FORMULA_DIR"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "{}" > "$STATE_FILE"
fi

echo "=================================================="
echo "Homebrew Tap Upstream Sync (Shell)"
echo "Formulas to check: $FORMULAS"
echo "Force sync:        $FORCE_SYNC"
echo "Dry run:           $DRY_RUN"
echo "Auto commit:       $AUTO_COMMIT"
echo "Auto push:         $AUTO_PUSH"
echo "Target branch:     $GIT_BRANCH"
echo "=================================================="

UPDATED_LIST=()

for FORMULA in $FORMULAS; do
  echo ""
  echo "Checking formula: $FORMULA"
  LOCAL_PATH="$FORMULA_DIR/${FORMULA}.rb"

  # 1. Fetch upstream formula file (.rb)
  # Homebrew-core shards formulas by first letter (Formula/<letter>/<formula>.rb)
  FIRST_CHAR=$(printf "%s" "${FORMULA:0:1}" | tr '[:upper:]' '[:lower:]')
  SHARDED_URL="${UPSTREAM_RAW_BASE}/Formula/${FIRST_CHAR}/${FORMULA}.rb"
  ROOT_URL="${UPSTREAM_RAW_BASE}/Formula/${FORMULA}.rb"

  TMP_RB=$(mktemp)
  SOURCE_URL=""
  if curl -sSfL "$SHARDED_URL" -o "$TMP_RB" 2>/dev/null; then
    SOURCE_URL="$SHARDED_URL"
  elif curl -sSfL "$ROOT_URL" -o "$TMP_RB" 2>/dev/null; then
    SOURCE_URL="$ROOT_URL"
  else
    echo "  [ERROR] Could not download formula for '$FORMULA' from upstream!"
    rm -f "$TMP_RB"
    continue
  fi

  # Strip directives that are only valid in official Homebrew taps (e.g. no_autobump!)
  SANITIZED_TMP=$(mktemp)
  grep -v -E '^[[:space:]]*no_autobump!' "$TMP_RB" > "$SANITIZED_TMP"
  mv "$SANITIZED_TMP" "$TMP_RB"

  UPSTREAM_SHA=$(calc_sha256 "$TMP_RB")

  # 2. Fetch upstream version & revision from Homebrew API
  API_URL="${UPSTREAM_API_BASE}/${FORMULA}.json"
  META_JSON=$(curl -sSfL "$API_URL" 2>/dev/null || true)

  UPSTREAM_VER=""
  UPSTREAM_REV=0
  if [[ -n "$META_JSON" ]]; then
    UPSTREAM_VER=$(echo "$META_JSON" | jq -r '.versions.stable // empty')
    UPSTREAM_REV=$(echo "$META_JSON" | jq -r '.revision // 0')
  fi

  # Fallback: extract version/revision from .rb if API didn't return stable
  if [[ -z "$UPSTREAM_VER" ]]; then
    UPSTREAM_REV=$(grep -E '^[[:space:]]*revision[[:space:]]+[0-9]+' "$TMP_RB" | awk '{print $2}' || echo "0")
    UPSTREAM_REV=${UPSTREAM_REV:-0}
    UPSTREAM_VER=$(grep -E '^[[:space:]]*version[[:space:]]+' "$TMP_RB" | head -n 1 | awk '{print $2}' | tr -d '"'\''' || true)
  fi

  # 3. Retrieve local version & revision
  LOCAL_VER=""
  LOCAL_REV=0
  LOCAL_SHA=""

  if [[ -f "$LOCAL_PATH" ]]; then
    LOCAL_SHA=$(calc_sha256 "$LOCAL_PATH")
    LOCAL_VER=$(jq -r --arg n "$FORMULA" '.[$n].version // empty' "$STATE_FILE" 2>/dev/null || true)
    LOCAL_REV=$(jq -r --arg n "$FORMULA" '.[$n].revision // 0' "$STATE_FILE" 2>/dev/null || echo "0")
    LOCAL_REV=${LOCAL_REV:-0}

    # If state file was empty but local formula exists, fallback to regex
    if [[ -z "$LOCAL_VER" ]]; then
      LOCAL_REV=$(grep -E '^[[:space:]]*revision[[:space:]]+[0-9]+' "$LOCAL_PATH" | awk '{print $2}' || echo "0")
      LOCAL_REV=${LOCAL_REV:-0}
      LOCAL_VER=$(grep -E '^[[:space:]]*version[[:space:]]+' "$LOCAL_PATH" | head -n 1 | awk '{print $2}' | tr -d '"'\''' || true)
    fi
  fi

  echo "  Upstream: version=${UPSTREAM_VER:-unknown}, revision=${UPSTREAM_REV} (from $SOURCE_URL)"
  echo "  Local:    version=${LOCAL_VER:-none}, revision=${LOCAL_REV}"

  # 4. Compare: Check if update is required
  if [[ -n "$LOCAL_SHA" && "$LOCAL_SHA" == "$UPSTREAM_SHA" && "$FORCE_SYNC" != "true" ]]; then
    echo "  [SKIP] Formula file is byte-for-byte identical to upstream."
    rm -f "$TMP_RB"
    continue
  fi

  NEEDS_UPDATE=false
  if [[ "$FORCE_SYNC" == "true" ]]; then
    NEEDS_UPDATE=true
  elif is_upstream_newer "$UPSTREAM_VER" "$UPSTREAM_REV" "$LOCAL_VER" "$LOCAL_REV"; then
    NEEDS_UPDATE=true
  fi

  if [[ "$NEEDS_UPDATE" != "true" ]]; then
    echo "  [SKIP] Local formula is already at latest version (${LOCAL_VER}_${LOCAL_REV})."
    rm -f "$TMP_RB"
    continue
  fi

  FULL_VER="${UPSTREAM_VER}"
  if (( UPSTREAM_REV > 0 )); then
    FULL_VER="${UPSTREAM_VER}_${UPSTREAM_REV}"
  fi
  echo "  [UPDATE] Upstream has newer version: ${FULL_VER} (local: ${LOCAL_VER:-none})"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would write $LOCAL_PATH and commit."
    UPDATED_LIST+=("$FORMULA")
    rm -f "$TMP_RB"
    continue
  fi

  # Apply update
  mv "$TMP_RB" "$LOCAL_PATH"

  # Fetch any patches referenced by the formula in Patches/
  PATCH_FILES=$(grep -oE 'Patches/[^"'\'' ]+' "$LOCAL_PATH" 2>/dev/null || true)
  if [[ -n "$PATCH_FILES" ]]; then
    for PATCH_REL in $PATCH_FILES; do
      PATCH_URL="${UPSTREAM_RAW_BASE}/${PATCH_REL}"
      echo "  [PATCH] Downloading referenced patch: $PATCH_REL"
      mkdir -p "$(dirname "$PATCH_REL")"
      if curl -sSfL "$PATCH_URL" -o "$PATCH_REL"; then
        echo "  [PATCH] Saved $PATCH_REL"
      else
        echo "  [WARN] Failed to download patch from $PATCH_URL" >&2
      fi
    done
  fi

  # Update state JSON
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  TMP_STATE=$(mktemp)
  jq --arg n "$FORMULA" \
     --arg v "$UPSTREAM_VER" \
     --argjson r "$UPSTREAM_REV" \
     --arg s "$UPSTREAM_SHA" \
     --arg t "$TIMESTAMP" \
     '.[$n] = {version: $v, revision: $r, sha256: $s, last_updated: $t}' \
     "$STATE_FILE" > "$TMP_STATE" && mv "$TMP_STATE" "$STATE_FILE"

  UPDATED_LIST+=("$FORMULA")

  # 5. Git Commit and Push per formula
  if [[ "$AUTO_COMMIT" == "true" ]]; then
    echo "  [GIT] Committing changes for $FORMULA..."
    git add "$LOCAL_PATH" "$STATE_FILE"
    if [[ -d "Patches" ]]; then
      git add Patches
    fi

    # Avoid committing if no staged changes
    if git diff --staged --quiet; then
      echo "  [GIT] No staged changes found to commit."
    else
      COMMIT_MSG="Update $FORMULA formula to $FULL_VER"
      git commit -m "$COMMIT_MSG"

      if [[ "$AUTO_PUSH" == "true" ]]; then
        echo "  [GIT] Pulling latest changes and pushing commit to remote branch $GIT_BRANCH..."
        git pull --rebase origin "$GIT_BRANCH"
        git push origin "$GIT_BRANCH"
        echo "  [GIT] Successfully pushed commit!"
      fi
    fi
  fi
done

# Set GitHub Actions output if running in CI
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  if [[ ${#UPDATED_LIST[@]} -gt 0 ]]; then
    echo "has_updates=true" >> "$GITHUB_OUTPUT"
    echo "updated_formulas=${UPDATED_LIST[*]}" >> "$GITHUB_OUTPUT"
  else
    echo "has_updates=false" >> "$GITHUB_OUTPUT"
    echo "updated_formulas=" >> "$GITHUB_OUTPUT"
  fi
fi

echo ""
echo "=================================================="
if [[ ${#UPDATED_LIST[@]} -eq 0 ]]; then
  echo "Sync complete: All formulas are already up-to-date."
else
  echo "Sync complete: Updated ${#UPDATED_LIST[@]} formula(s): ${UPDATED_LIST[*]}"
fi
echo "=================================================="
