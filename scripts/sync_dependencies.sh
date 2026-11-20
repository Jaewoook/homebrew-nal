#!/usr/bin/env bash
# ==============================================================================
# sync_dependencies.sh - Resolve and register upstream runtime dependencies
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/formula_helpers.sh
source "${SCRIPT_DIR}/formula_helpers.sh"

FORMULA_DIR="Formula"
PATCHES_DIR=""
STATE_FILE=".formula-versions.json"
UPSTREAM_BASE="${UPSTREAM_BASE:-https://raw.githubusercontent.com/Homebrew/homebrew-core/master}"
UPSTREAM_API_BASE="${UPSTREAM_API_BASE:-https://formulae.brew.sh/api/formula}"
TAP_NAME="jaewoook/nal"
MAX_DEPTH=2

TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --formula-dir)
      FORMULA_DIR="$2"
      shift 2
      ;;
    --patches-dir)
      PATCHES_DIR="$2"
      shift 2
      ;;
    --state-file)
      STATE_FILE="$2"
      shift 2
      ;;
    --upstream-base)
      UPSTREAM_BASE="$2"
      shift 2
      ;;
    --upstream-api-base)
      UPSTREAM_API_BASE="$2"
      shift 2
      ;;
    --tap)
      TAP_NAME="$2"
      shift 2
      ;;
    --max-depth)
      MAX_DEPTH="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [options] formula1 [formula2 ...]

Options:
  --formula-dir DIR       Formula directory (default: Formula)
  --patches-dir DIR       Patches directory (default: <parent of Formula dir>/Patches)
  --state-file FILE       Formula versions state file (default: .formula-versions.json)
  --upstream-base URL     Base URL for upstream formulas
  --upstream-api-base URL Base URL for upstream formula JSON API
  --tap TAP_NAME          Tap name (default: jaewoook/nal)
  --max-depth N           Maximum transitive dependency depth (default: 2)
  -h, --help              Show this help message
EOF
      exit 0
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

if [ -z "$PATCHES_DIR" ]; then
  FORMULA_PARENT=$(dirname "$FORMULA_DIR")
  if [ "$FORMULA_PARENT" = "." ]; then
    PATCHES_DIR="Patches"
  else
    PATCHES_DIR="${FORMULA_PARENT}/Patches"
  fi
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "No target formulas specified for dependency sync."
  exit 0
fi

mkdir -p "$FORMULA_DIR"
if [ ! -f "$STATE_FILE" ]; then
  echo "{}" > "$STATE_FILE"
fi

calc_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  fi
}

fetch_upstream_formula() {
  local dep="$1"
  local dest="$2"

  local first_char
  first_char=$(printf "%s" "${dep:0:1}" | tr '[:upper:]' '[:lower:]')
  local lib_url="${UPSTREAM_BASE}/Formula/lib/${dep}.rb"
  local sharded_url="${UPSTREAM_BASE}/Formula/${first_char}/${dep}.rb"
  local root_url="${UPSTREAM_BASE}/Formula/${dep}.rb"

  local tmp
  tmp=$(mktemp)

  local fetched=false
  if [[ "$dep" == lib* ]] && curl -sSfL "$lib_url" -o "$tmp" 2>/dev/null; then
    fetched=true
  elif curl -sSfL "$sharded_url" -o "$tmp" 2>/dev/null || curl -sSfL "$root_url" -o "$tmp" 2>/dev/null; then
    fetched=true
  fi

  if [ "$fetched" = true ]; then
    # Sanitize directives not permitted in custom taps
    grep -v -E '^[[:space:]]*no_autobump!' "$tmp" > "$dest" || true
    rm -f "$tmp"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

extract_runtime_deps() {
  local rb_file="$1"
  [ -f "$rb_file" ] || return 0
  # Strip on_linux/on_arm blocks and extract runtime depends_on (ignoring :build and :test, including array syntax like [:build, :test])
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*on_(linux|arm)[[:space:]]+do([[:space:]]|$)/ {
      in_skip = 1
      match($0, /^[[:space:]]*/)
      skip_indent = RLENGTH
      next
    }
    in_skip {
      match($0, /^[[:space:]]*/)
      if (RLENGTH == skip_indent && $0 ~ /^[[:space:]]*end([[:space:]]|$)/) {
        in_skip = 0
      }
      next
    }
    { print }
  ' "$rb_file" 2>/dev/null \
    | sed 's/#.*//' \
    | grep -E '^[[:space:]]*depends_on[[:space:]]+"[^"]+"' 2>/dev/null \
    | grep -v -E '=>.*:(build|test)\b' \
    | grep -v -E 'if[[:space:]]+DevelopmentTools\.clang_build_version[[:space:]]*<=[[:space:]]*1500' \
    | sed -E 's/^[[:space:]]*depends_on[[:space:]]+"([^"]+)".*/\1/' \
    | sed "s|^${TAP_NAME}/||" \
    | sort -u || true
}

VISITED_FILE=$(mktemp)
trap 'rm -f "$VISITED_FILE"' EXIT

register_dependency() {
  local dep="$1"
  local current_depth="$2"

  if [ "$current_depth" -gt "$MAX_DEPTH" ]; then
    return 0
  fi

  if [[ ! "$dep" =~ ^[a-zA-Z0-9._+-]+(@[0-9.]+)?$ ]]; then
    echo "  [WARN] Invalid dependency name '$dep', skipping!" >&2
    return 0
  fi

  local prev_depth
  prev_depth=$(awk -v d="$dep" '$1 == d { print $2; exit }' "$VISITED_FILE" 2>/dev/null || true)
  if [ -n "$prev_depth" ] && [ "$prev_depth" -le "$current_depth" ]; then
    return 0
  fi
  if [ -n "$prev_depth" ]; then
    local tmp_vis
    tmp_vis=$(mktemp)
    awk -v d="$dep" '$1 != d { print }' "$VISITED_FILE" > "$tmp_vis" && mv "$tmp_vis" "$VISITED_FILE"
  fi
  echo "$dep $current_depth" >> "$VISITED_FILE"

  local target_path="${FORMULA_DIR}/${dep}.rb"
  local is_new=0

  if [ ! -f "$target_path" ]; then
    echo "  [DEP] Fetching missing dependency formula: $dep"
    if fetch_upstream_formula "$dep" "$target_path"; then
      is_new=1
    else
      echo "  [WARN] Could not fetch formula for dependency '$dep' from upstream!" >&2
      return 0
    fi
  fi

  # Download any Patches/ files referenced by this dependency formula
  local overwrite_patches="false"
  if [ "$is_new" -eq 1 ]; then
    overwrite_patches="true"
  fi
  if ! fetch_referenced_patches "$target_path" "$UPSTREAM_BASE" "$PATCHES_DIR" "$overwrite_patches"; then
    if [ "$is_new" -eq 1 ]; then
      rm -f "$target_path"
    fi
    return 1
  fi

  # Update state JSON if new or if existing entry is missing/corrupt
  local existing_ver
  existing_ver=$(jq -r --arg n "$dep" '.[$n].version // empty' "$STATE_FILE" 2>/dev/null || true)
  local needs_state_update=0
  if [ "$is_new" -eq 1 ] || [ -z "$existing_ver" ] || [ "$existing_ver" = "unknown" ] || [[ "$existing_ver" == *$'\n'* ]] || [[ "$existing_ver" == *"/"* ]]; then
    needs_state_update=1
  fi

  if [ "$needs_state_update" -eq 1 ]; then
    local local_sha local_ver local_rev parsed_meta parsed_ver parsed_rev parsed_arm64
    local_sha=$(calc_sha256 "$target_path")
    local_ver=""
    local_rev=0

    if [ "$is_new" -eq 1 ] && [ -n "$UPSTREAM_API_BASE" ]; then
      local api_json
      api_json=$(curl -sSfL "${UPSTREAM_API_BASE}/${dep}.json" 2>/dev/null || true)
      if [ -n "$api_json" ]; then
        local_ver=$(echo "$api_json" | jq -r '.versions.stable // empty' 2>/dev/null || true)
        local_rev=$(echo "$api_json" | jq -r '.revision // 0' 2>/dev/null || echo "0")
        local_rev=${local_rev:-0}
      fi
    fi

    if [ -z "$local_ver" ]; then
      parsed_meta=$(extract_formula_meta "$target_path")
      IFS='|' read -r parsed_ver parsed_rev parsed_arm64 <<< "$parsed_meta"
      local_ver="${parsed_ver:-unknown}"
      local_rev="${parsed_rev:-0}"
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local tmp_state
    tmp_state=$(mktemp)
    if [ "$is_new" -eq 1 ] || ! jq -e --arg n "$dep" 'has($n)' "$STATE_FILE" >/dev/null 2>&1; then
      jq --arg n "$dep" \
         --arg v "$local_ver" \
         --argjson r "$local_rev" \
         --arg s "$local_sha" \
         --arg t "$timestamp" \
         '.[$n] = ((.[$n] // {}) + {version: $v, revision: $r, sha256: $s, last_updated: $t, is_dependency: true})' \
         "$STATE_FILE" > "$tmp_state" && mv "$tmp_state" "$STATE_FILE"
    else
      jq --arg n "$dep" \
         --arg v "$local_ver" \
         --argjson r "$local_rev" \
         --arg s "$local_sha" \
         --arg t "$timestamp" \
         '.[$n] = ((.[$n] // {}) + {version: $v, revision: $r, sha256: $s, last_updated: $t})' \
         "$STATE_FILE" > "$tmp_state" && mv "$tmp_state" "$STATE_FILE"
    fi
  fi

  # Recursively process runtime dependencies of this dependency
  local subdeps
  subdeps=$(extract_runtime_deps "$target_path")
  for subdep in $subdeps; do
    [ -n "$subdep" ] || continue
    [ "$subdep" != "$dep" ] || continue
    register_dependency "$subdep" $((current_depth + 1))
  done
}

echo "Resolving dependencies for: ${TARGETS[*]}"

for target in "${TARGETS[@]}"; do
  if [[ ! "$target" =~ ^[a-zA-Z0-9._+-]+(@[0-9.]+)?$ ]]; then
    echo "Invalid formula name '$target'. Skipping dependency resolution." >&2
    continue
  fi
  target_rb="${FORMULA_DIR}/${target}.rb"
  if [ ! -f "$target_rb" ]; then
    echo "Formula $target_rb not found locally. Skipping dependency resolution for $target."
    continue
  fi

  echo "Checking dependencies of $target..."
  direct_deps=$(extract_runtime_deps "$target_rb")
  for dep in $direct_deps; do
    [ -n "$dep" ] || continue
    [ "$dep" != "$target" ] || continue
    register_dependency "$dep" 1
  done
done

# Run qualify_dependencies script to update depends_on references
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUALIFY_SCRIPT="${SCRIPT_DIR}/qualify_dependencies.sh"
if [ -f "$QUALIFY_SCRIPT" ]; then
  bash "$QUALIFY_SCRIPT" --formula-dir "$FORMULA_DIR" --tap "$TAP_NAME"
fi

echo "Dependency registration and qualification complete."
