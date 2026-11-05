#!/usr/bin/env bash
# ==============================================================================
# sync_formulas.sh - Upstream Formula Sync Script for Homebrew Taps
# ==============================================================================
set -euo pipefail

UPSTREAM_RAW_BASE=${UPSTREAM_RAW_BASE:-"https://raw.githubusercontent.com/Homebrew/homebrew-core/master"}
UPSTREAM_API_BASE=${UPSTREAM_API_BASE:-"https://formulae.brew.sh/api/formula"}
UPSTREAM_CASK_RAW_BASE=${UPSTREAM_CASK_RAW_BASE:-"https://raw.githubusercontent.com/Homebrew/homebrew-cask/HEAD"}
UPSTREAM_CASK_API_BASE=${UPSTREAM_CASK_API_BASE:-"https://formulae.brew.sh/api/cask"}
STATE_FILE=".formula-versions.json"
CASK_STATE_FILE=".cask-versions.json"
FORMULA_DIR="Formula"
CASK_DIR="Casks"

# ------------------------------------------------------------------------------
# Default Options & Environment Overrides
# ------------------------------------------------------------------------------
EXPLICIT_FORMULAS="false"
if [[ -n "${FORMULAS:-}" ]]; then
  EXPLICIT_FORMULAS="true"
fi
FORMULAS=${FORMULAS:-""}
CASKS=${CASKS:-""}
FORCE_SYNC=${FORCE_SYNC:-"false"}
DRY_RUN=${DRY_RUN:-"false"}
AUTO_COMMIT=${AUTO_COMMIT:-"false"}
AUTO_PUSH=${AUTO_PUSH:-"false"}
GIT_BRANCH=${GIT_BRANCH:-"main"}
IS_DEPENDENCY=${IS_DEPENDENCY:-"false"}
WITH_DEPS=${WITH_DEPS:-"false"}
AUTO_PRESERVE=${AUTO_PRESERVE:-"true"}
NO_GPG_SIGN=${NO_GPG_SIGN:-"false"}

CLI_FORMULAS=()
CLI_CASKS=()
PARSE_MODE="formulas"

# ------------------------------------------------------------------------------
# Parse CLI Arguments
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [formula1 formula2 ...]

Options:
  -f, --formulas LIST   Space- or comma-separated list of formula names (e.g. "node node@22")
  --casks LIST          Space- or comma-separated list of cask names (e.g. "ghostty")
  --force               Force sync even if local and upstream versions match
  -d, --dry-run         Perform version check without saving or committing
  -c, --commit          Commit updated formula(s)/cask(s) to git
  --no-commit           Do not commit updated formula(s)/cask(s) to git
  -p, --push            Push commits to remote repository
  -b, --branch BRANCH   Target git branch (default: main)
  --no-gpg-sign         Disable GPG signing when committing to git
  --as-dependency       Tag formula as a dependency in state tracking
  --with-deps           Automatically resolve and register runtime dependencies
  --no-preserve         Do not auto-preserve previous major versions as <formula>@<version>
  -h, --help            Show this help message

Environment Variables:
  FORMULAS, CASKS, FORCE_SYNC, DRY_RUN, AUTO_COMMIT, AUTO_PUSH, GIT_BRANCH, NO_GPG_SIGN, AUTO_PRESERVE
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--formulas)
      EXPLICIT_FORMULAS="true"
      PARSE_MODE="formulas"
      if [[ $# -gt 1 && "$2" != -* ]]; then
        FORMULAS="$2"
        shift 2
      else
        shift
      fi
      ;;
    --casks)
      PARSE_MODE="casks"
      if [[ $# -gt 1 && "$2" != -* ]]; then
        CASKS="$2"
        shift 2
      else
        shift
      fi
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
    --no-commit)
      AUTO_COMMIT="false"
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
    --no-gpg-sign)
      NO_GPG_SIGN="true"
      shift
      ;;
    --as-dependency)
      IS_DEPENDENCY="true"
      shift
      ;;
    --with-deps)
      WITH_DEPS="true"
      shift
      ;;
    --no-preserve)
      AUTO_PRESERVE="false"
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      ;;
    *)
      if [[ "$PARSE_MODE" == "casks" ]]; then
        CLI_CASKS+=("$1")
      else
        EXPLICIT_FORMULAS="true"
        CLI_FORMULAS+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ ${#CLI_FORMULAS[@]} -gt 0 ]]; then
  if [[ -n "$FORMULAS" ]]; then
    FORMULAS="${FORMULAS} ${CLI_FORMULAS[*]}"
  else
    FORMULAS="${CLI_FORMULAS[*]}"
  fi
fi

if [[ ${#CLI_CASKS[@]} -gt 0 ]]; then
  if [[ -n "$CASKS" ]]; then
    CASKS="${CASKS} ${CLI_CASKS[*]}"
  else
    CASKS="${CLI_CASKS[*]}"
  fi
fi

# Normalize lists (replace commas with spaces)
FORMULAS=$(echo "$FORMULAS" | tr ',' ' ')
CASKS=$(echo "$CASKS" | tr ',' ' ')

# If neither formulas nor casks were explicitly provided, default formulas to "llvm gcc"
# and casks to any tracked keys in .cask-versions.json
if [[ -z "${FORMULAS// /}" && -z "${CASKS// /}" ]]; then
  FORMULAS="llvm gcc"
  if [[ -f "$CASK_STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
    CASKS=$(jq -r 'keys | join(" ")' "$CASK_STATE_FILE" 2>/dev/null || echo "")
  fi
fi

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

# Centralized Git commit and push helpers
git_commit() {
  local commit_msg="$1"
  shift
  local files_to_stage=("$@")

  if [[ "$AUTO_COMMIT" != "true" ]]; then
    return 0
  fi

  if [[ ${#files_to_stage[@]} -gt 0 ]]; then
    git add -- "${files_to_stage[@]}"
  fi

  if git diff --staged --quiet; then
    echo "  [GIT] No staged changes found to commit."
    return 0
  fi

  echo "  [GIT] Committing: $commit_msg"
  local commit_cmd=(git commit)
  if [[ "$NO_GPG_SIGN" == "true" ]]; then
    commit_cmd+=(--no-gpg-sign)
  fi
  "${commit_cmd[@]}" -m "$commit_msg"
}

git_push_changes() {
  if [[ "$AUTO_PUSH" != "true" ]]; then
    return 0
  fi

  echo "  [GIT] Pulling latest changes and pushing to branch $GIT_BRANCH..."
  git pull --rebase origin "$GIT_BRANCH"
  git push origin HEAD:"$GIT_BRANCH"
  echo "  [GIT] Successfully pushed commits!"
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
if [[ "$DRY_RUN" != "true" ]]; then
  mkdir -p "$FORMULA_DIR" "$CASK_DIR"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "{}" > "$STATE_FILE"
  fi
  if [[ ! -f "$CASK_STATE_FILE" ]]; then
    echo "{}" > "$CASK_STATE_FILE"
  fi
fi

echo "=================================================="
echo "Homebrew Tap Upstream Sync (Shell)"
echo "Formulas to check: ${FORMULAS:-none}"
echo "Casks to check:    ${CASKS:-none}"
echo "Force sync:        $FORCE_SYNC"
echo "Dry run:           $DRY_RUN"
echo "Auto commit:       $AUTO_COMMIT"
echo "Auto push:         $AUTO_PUSH"
echo "Target branch:     $GIT_BRANCH"
echo "=================================================="

UPDATED_LIST=()
UPDATED_CASKS_LIST=()

for FORMULA in $FORMULAS; do
  PRESERVED_CANDIDATE_PATH=""
  echo ""
  if [[ ! "$FORMULA" =~ ^[a-zA-Z0-9._+-]+(@[0-9.]+)?$ ]]; then
    echo "  [ERROR] Invalid formula name '$FORMULA', skipping!" >&2
    continue
  fi
  echo "Checking formula: $FORMULA"
  LOCAL_PATH="$FORMULA_DIR/${FORMULA}.rb"

  # 1. Fetch upstream formula file (.rb)
  # Homebrew-core shards formulas by first letter (Formula/<letter>/<formula>.rb) or Formula/lib/<formula>.rb
  FIRST_CHAR=$(printf "%s" "${FORMULA:0:1}" | tr '[:upper:]' '[:lower:]')
  LIB_URL="${UPSTREAM_RAW_BASE}/Formula/lib/${FORMULA}.rb"
  SHARDED_URL="${UPSTREAM_RAW_BASE}/Formula/${FIRST_CHAR}/${FORMULA}.rb"
  ROOT_URL="${UPSTREAM_RAW_BASE}/Formula/${FORMULA}.rb"

  TMP_RB=$(mktemp)
  SOURCE_URL=""
  if [[ "$FORMULA" == lib* ]] && curl -sSfL "$LIB_URL" -o "$TMP_RB" 2>/dev/null; then
    SOURCE_URL="$LIB_URL"
  elif curl -sSfL "$SHARDED_URL" -o "$TMP_RB" 2>/dev/null; then
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

  # Auto-preserve previous major version as <formula>@<prev_version> on major bumps
  if [[ "$AUTO_PRESERVE" == "true" && -n "$LOCAL_VER" && "$FORMULA" != *"@"* && -f "$LOCAL_PATH" ]]; then
    LOCAL_MAJOR=$(echo "$LOCAL_VER" | cut -d. -f1)
    UPSTREAM_MAJOR=$(echo "$UPSTREAM_VER" | cut -d. -f1)

    LOCAL_MINOR=$(echo "$LOCAL_VER" | cut -d. -f2)
    UPSTREAM_MINOR=$(echo "$UPSTREAM_VER" | cut -d. -f2)
    LOCAL_MAJOR_MINOR="${LOCAL_MAJOR}.${LOCAL_MINOR}"
    UPSTREAM_MAJOR_MINOR="${UPSTREAM_MAJOR}.${UPSTREAM_MINOR}"

    PREV_CANDIDATES=()
    if [[ -n "$LOCAL_MAJOR" && -n "$UPSTREAM_MAJOR" && "$LOCAL_MAJOR" != "$UPSTREAM_MAJOR" ]]; then
      PREV_CANDIDATES+=("${FORMULA}@${LOCAL_MAJOR}")
    fi
    if [[ -n "$LOCAL_MINOR" && -n "$UPSTREAM_MINOR" && "$LOCAL_MAJOR_MINOR" != "$UPSTREAM_MAJOR_MINOR" ]]; then
      PREV_CANDIDATES+=("${FORMULA}@${LOCAL_MAJOR_MINOR}")
    fi

    for CANDIDATE in "${PREV_CANDIDATES[@]}"; do
      if [[ ! "$CANDIDATE" =~ ^[a-zA-Z0-9._+-]+(@[0-9.]+)?$ ]]; then
        continue
      fi
      CANDIDATE_PATH="$FORMULA_DIR/${CANDIDATE}.rb"
      if [[ -f "$CANDIDATE_PATH" ]]; then
        continue
      fi

      CANDIDATE_CHAR=$(printf "%s" "${CANDIDATE:0:1}" | tr '[:upper:]' '[:lower:]')
      CANDIDATE_LIB="${UPSTREAM_RAW_BASE}/Formula/lib/${CANDIDATE}.rb"
      CANDIDATE_SHARDED="${UPSTREAM_RAW_BASE}/Formula/${CANDIDATE_CHAR}/${CANDIDATE}.rb"
      CANDIDATE_ROOT="${UPSTREAM_RAW_BASE}/Formula/${CANDIDATE}.rb"

      TMP_CANDIDATE=$(mktemp)
      CANDIDATE_FOUND=false
      if [[ "$CANDIDATE" == lib* ]] && curl -sSfL "$CANDIDATE_LIB" -o "$TMP_CANDIDATE" 2>/dev/null; then
        CANDIDATE_FOUND=true
      elif curl -sSfL "$CANDIDATE_SHARDED" -o "$TMP_CANDIDATE" 2>/dev/null || curl -sSfL "$CANDIDATE_ROOT" -o "$TMP_CANDIDATE" 2>/dev/null; then
        CANDIDATE_FOUND=true
      fi

      if [[ "$CANDIDATE_FOUND" == "true" ]]; then
        echo "  [AUTO-PRESERVE] Major version bump detected (${LOCAL_VER} -> ${FULL_VER})."
        echo "                  Preserving previous version as: $CANDIDATE"

        grep -v -E '^[[:space:]]*no_autobump!' "$TMP_CANDIDATE" > "$CANDIDATE_PATH"
        rm -f "$TMP_CANDIDATE"

        CANDIDATE_SHA=$(calc_sha256 "$CANDIDATE_PATH")
        CANDIDATE_VER=$(grep -E '^[[:space:]]*version[[:space:]]+' "$CANDIDATE_PATH" | head -n 1 | awk '{print $2}' | tr -d '"'\''' || echo "$LOCAL_VER")
        if [[ -z "$CANDIDATE_VER" ]]; then
          CANDIDATE_VER=$(grep -oE 'url[[:space:]]+".*-(.*)\.tar' "$CANDIDATE_PATH" | sed -E 's/.*-(.*)\.tar/\1/' || echo "$LOCAL_VER")
        fi
        CANDIDATE_REV=$(grep -E '^[[:space:]]*revision[[:space:]]+[0-9]+' "$CANDIDATE_PATH" | awk '{print $2}' || echo "0")
        CANDIDATE_REV=${CANDIDATE_REV:-0}

        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        TMP_STATE=$(mktemp)
        jq --arg n "$CANDIDATE" \
           --arg v "$CANDIDATE_VER" \
           --argjson r "$CANDIDATE_REV" \
           --arg s "$CANDIDATE_SHA" \
           --arg t "$TIMESTAMP" \
           '.[$n] = ((.[$n] // {}) + {version: $v, revision: $r, sha256: $s, last_updated: $t, is_versioned: true})' \
           "$STATE_FILE" > "$TMP_STATE" && mv "$TMP_STATE" "$STATE_FILE"

        UPDATED_LIST+=("$CANDIDATE")
        PRESERVED_CANDIDATE_PATH="$CANDIDATE_PATH"
        break
      else
        rm -f "$TMP_CANDIDATE"
      fi
    done
  fi

  # Apply update
  mv "$TMP_RB" "$LOCAL_PATH"

  # Qualify any existing tap runtime dependencies in the updated formula(s)
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$SCRIPT_DIR/qualify_dependencies.sh" ]]; then
    QUALIFY_ARGS=(--formula-dir "$FORMULA_DIR" "$FORMULA")
    if [[ -n "$PRESERVED_CANDIDATE_PATH" && -f "$PRESERVED_CANDIDATE_PATH" ]]; then
      QUALIFY_ARGS+=("$(basename "$PRESERVED_CANDIDATE_PATH" .rb)")
    fi
    bash "$SCRIPT_DIR/qualify_dependencies.sh" "${QUALIFY_ARGS[@]}" >/dev/null
  fi

  # Fetch any patches referenced by the formula in Patches/
  PATCH_FILES=$(grep -oE 'Patches/[a-zA-Z0-9._+-]+/[a-zA-Z0-9._/-]+' "$LOCAL_PATH" 2>/dev/null || true)
  if [[ -n "$PATCH_FILES" ]]; then
    mkdir -p "Patches"
    for PATCH_REL in $PATCH_FILES; do
      if [[ "$PATCH_REL" == *".."* ]] || ! python3 -c 'import os, sys; p = os.path.realpath(sys.argv[1]); b = os.path.realpath("Patches"); sys.exit(0 if p.startswith(b + os.sep) else 1)' "$PATCH_REL"; then
        echo "  [ERROR] Refusing suspicious patch path: $PATCH_REL" >&2
        continue
      fi
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
  if [[ "$IS_DEPENDENCY" == "true" ]]; then
    jq --arg n "$FORMULA" \
       --arg v "$UPSTREAM_VER" \
       --argjson r "$UPSTREAM_REV" \
       --arg s "$UPSTREAM_SHA" \
       --arg t "$TIMESTAMP" \
       '.[$n] = ((.[$n] // {}) + {version: $v, revision: $r, sha256: $s, last_updated: $t, is_dependency: true})' \
       "$STATE_FILE" > "$TMP_STATE" && mv "$TMP_STATE" "$STATE_FILE"
  else
    jq --arg n "$FORMULA" \
       --arg v "$UPSTREAM_VER" \
       --argjson r "$UPSTREAM_REV" \
       --arg s "$UPSTREAM_SHA" \
       --arg t "$TIMESTAMP" \
       '.[$n] = ((.[$n] // {}) + {version: $v, revision: $r, sha256: $s, last_updated: $t})' \
       "$STATE_FILE" > "$TMP_STATE" && mv "$TMP_STATE" "$STATE_FILE"
  fi

  UPDATED_LIST+=("$FORMULA")

  # 5. Git Commit and Push per formula
  if [[ "$AUTO_COMMIT" == "true" ]]; then
    FILES_TO_STAGE=("$LOCAL_PATH" "$STATE_FILE")
    if [[ -n "$PRESERVED_CANDIDATE_PATH" && -f "$PRESERVED_CANDIDATE_PATH" ]]; then
      FILES_TO_STAGE+=("$PRESERVED_CANDIDATE_PATH")
    fi
    if [[ -d "Patches" ]]; then
      FILES_TO_STAGE+=("Patches")
    fi

    COMMIT_MSG="Update $FORMULA formula to $FULL_VER"
    git_commit "$COMMIT_MSG" "${FILES_TO_STAGE[@]}"
  fi
done

if [[ "$WITH_DEPS" == "true" && ${#UPDATED_LIST[@]} -gt 0 && "$DRY_RUN" != "true" ]]; then
  echo ""
  echo "Syncing runtime dependencies for updated formulas: ${UPDATED_LIST[*]}"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$SCRIPT_DIR/sync_dependencies.sh" ]]; then
    bash "$SCRIPT_DIR/sync_dependencies.sh" "${UPDATED_LIST[@]}"
  fi
  if [[ "$AUTO_COMMIT" == "true" ]]; then
    git_commit "Register runtime dependencies for ${UPDATED_LIST[*]}" "$FORMULA_DIR" "$STATE_FILE"
  fi
fi

# ------------------------------------------------------------------------------
# Cask Sync Loop
# ------------------------------------------------------------------------------
for CASK in $CASKS; do
  echo ""
  if [[ ! "$CASK" =~ ^[a-zA-Z0-9._+-]+(@[a-zA-Z0-9._+-]+)?$ ]]; then
    echo "  [ERROR] Invalid cask name '$CASK', skipping!" >&2
    continue
  fi
  echo "Checking cask: $CASK"
  LOCAL_CASK_PATH="$CASK_DIR/${CASK}.rb"

  # 1. Fetch upstream cask metadata from Homebrew Cask API
  CASK_API_URL="${UPSTREAM_CASK_API_BASE}/${CASK}.json"
  CASK_META_JSON=$(curl -sSfL "$CASK_API_URL" 2>/dev/null || true)

  UPSTREAM_CASK_VER=""
  RUBY_SOURCE_PATH=""
  if [[ -n "$CASK_META_JSON" ]]; then
    UPSTREAM_CASK_VER=$(echo "$CASK_META_JSON" | jq -r '.version // empty')
    RUBY_SOURCE_PATH=$(echo "$CASK_META_JSON" | jq -r '.ruby_source_path // empty')
  fi

  FIRST_CHAR=$(printf "%s" "${CASK:0:1}" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$RUBY_SOURCE_PATH" ]]; then
    RUBY_SOURCE_PATH="Casks/${FIRST_CHAR}/${CASK}.rb"
  fi

  TMP_CASK_RB=$(mktemp)
  CASK_SOURCE_URL="${UPSTREAM_CASK_RAW_BASE}/${RUBY_SOURCE_PATH}"
  CASK_FALLBACK_URL="${UPSTREAM_CASK_RAW_BASE}/Casks/${FIRST_CHAR}/${CASK}.rb"
  CASK_ROOT_URL="${UPSTREAM_CASK_RAW_BASE}/Casks/${CASK}.rb"

  if curl -sSfL -o "$TMP_CASK_RB" "$CASK_SOURCE_URL" 2>/dev/null; then
    :
  elif curl -sSfL -o "$TMP_CASK_RB" "$CASK_FALLBACK_URL" 2>/dev/null; then
    CASK_SOURCE_URL="$CASK_FALLBACK_URL"
  elif curl -sSfL -o "$TMP_CASK_RB" "$CASK_ROOT_URL" 2>/dev/null; then
    CASK_SOURCE_URL="$CASK_ROOT_URL"
  else
    echo "  [ERROR] Could not download cask for '$CASK' from upstream!" >&2
    rm -f "$TMP_CASK_RB"
    continue
  fi

  SANITIZED_CASK_TMP=$(mktemp)
  grep -v -E '^[[:space:]]*no_autobump!' "$TMP_CASK_RB" > "$SANITIZED_CASK_TMP" || true
  mv "$SANITIZED_CASK_TMP" "$TMP_CASK_RB"

  if [[ -z "$UPSTREAM_CASK_VER" ]]; then
    UPSTREAM_CASK_VER=$(grep -E '^[[:space:]]*version[[:space:]]+' "$TMP_CASK_RB" | head -n 1 | awk '{print $2}' | tr -d '"'\''' || true)
  fi

  UPSTREAM_CASK_SHA=$(calc_sha256 "$TMP_CASK_RB")

  LOCAL_CASK_VER=""
  LOCAL_CASK_SHA=""
  if [[ -f "$LOCAL_CASK_PATH" ]]; then
    LOCAL_CASK_SHA=$(calc_sha256 "$LOCAL_CASK_PATH")
    LOCAL_CASK_VER=$(jq -r --arg n "$CASK" '.[$n].version // .[$n] // empty' "$CASK_STATE_FILE" 2>/dev/null || true)
    if [[ -z "$LOCAL_CASK_VER" ]]; then
      LOCAL_CASK_VER=$(grep -E '^[[:space:]]*version[[:space:]]+' "$LOCAL_CASK_PATH" | head -n 1 | awk '{print $2}' | tr -d '"'\''' || true)
    fi
  fi

  echo "  Upstream Cask: version=${UPSTREAM_CASK_VER:-unknown} (from $CASK_SOURCE_URL)"
  echo "  Local Cask:    version=${LOCAL_CASK_VER:-none}"

  CASK_NEEDS_UPDATE=false
  if [[ "$FORCE_SYNC" == "true" ]]; then
    CASK_NEEDS_UPDATE=true
  elif [[ ! -f "$LOCAL_CASK_PATH" ]]; then
    CASK_NEEDS_UPDATE=true
  elif is_upstream_newer "$UPSTREAM_CASK_VER" 0 "$LOCAL_CASK_VER" 0; then
    CASK_NEEDS_UPDATE=true
  fi

  if [[ "$CASK_NEEDS_UPDATE" != "true" ]]; then
    echo "  [SKIP] Local cask is already at latest version (${LOCAL_CASK_VER})."
    rm -f "$TMP_CASK_RB"
    continue
  fi

  echo "  [UPDATE] Syncing cask $CASK version ${UPSTREAM_CASK_VER} (local: ${LOCAL_CASK_VER:-none})"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would write $LOCAL_CASK_PATH and commit."
    UPDATED_CASKS_LIST+=("$CASK")
    rm -f "$TMP_CASK_RB"
    continue
  fi

  mv "$TMP_CASK_RB" "$LOCAL_CASK_PATH"

  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  TMP_CASK_STATE=$(mktemp)
  jq --arg n "$CASK" \
     --arg v "$UPSTREAM_CASK_VER" \
     --arg s "$UPSTREAM_CASK_SHA" \
     --arg t "$TIMESTAMP" \
     '.[$n] = ((if (.[$n] | type) == "object" then .[$n] else {} end) + {version: $v, sha256: $s, last_updated: $t})' \
     "$CASK_STATE_FILE" > "$TMP_CASK_STATE" && mv "$TMP_CASK_STATE" "$CASK_STATE_FILE"

  UPDATED_CASKS_LIST+=("$CASK")

  if [[ "$AUTO_COMMIT" == "true" ]]; then
    git_commit "Update $CASK cask to $UPSTREAM_CASK_VER" "$LOCAL_CASK_PATH" "$CASK_STATE_FILE"
  fi
done

TOTAL_UPDATED_COUNT=$(( ${#UPDATED_LIST[@]} + ${#UPDATED_CASKS_LIST[@]} ))

# Push all accumulated commits once at the end
if [[ "$AUTO_PUSH" == "true" && $TOTAL_UPDATED_COUNT -gt 0 ]]; then
  git_push_changes
fi

# Set GitHub Actions output if running in CI
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  if [[ $TOTAL_UPDATED_COUNT -gt 0 ]]; then
    echo "has_updates=true" >> "$GITHUB_OUTPUT"
    echo "updated=true" >> "$GITHUB_OUTPUT"
  else
    echo "has_updates=false" >> "$GITHUB_OUTPUT"
    echo "updated=false" >> "$GITHUB_OUTPUT"
  fi
  echo "updated_formulas=${UPDATED_LIST[*]:-}" >> "$GITHUB_OUTPUT"
  echo "formulas=${UPDATED_LIST[*]:-}" >> "$GITHUB_OUTPUT"
  echo "updated_casks=${UPDATED_CASKS_LIST[*]:-}" >> "$GITHUB_OUTPUT"
  echo "casks=${UPDATED_CASKS_LIST[*]:-}" >> "$GITHUB_OUTPUT"
  echo "cask_count=${#UPDATED_CASKS_LIST[@]}" >> "$GITHUB_OUTPUT"
  echo "count=${TOTAL_UPDATED_COUNT}" >> "$GITHUB_OUTPUT"
fi

echo ""
echo "=================================================="
if [[ $TOTAL_UPDATED_COUNT -eq 0 ]]; then
  echo "Sync complete: All formulas and casks are already up-to-date."
else
  echo "Sync complete: Updated ${#UPDATED_LIST[@]} formula(s) (${UPDATED_LIST[*]:-none}) and ${#UPDATED_CASKS_LIST[@]} cask(s) (${UPDATED_CASKS_LIST[*]:-none})"
fi
echo "=================================================="
