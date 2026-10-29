#!/usr/bin/env bash
# ==============================================================================
# sync_dependencies.sh - Resolve and register upstream runtime dependencies
# ==============================================================================
set -euo pipefail

FORMULA_DIR="Formula"
STATE_FILE=".formula-versions.json"
UPSTREAM_BASE="https://raw.githubusercontent.com/Homebrew/homebrew-core/master"
TAP_NAME="jaewoook/nal"
MAX_DEPTH=2

TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --formula-dir)
      FORMULA_DIR="$2"
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
  --formula-dir DIR      Formula directory (default: Formula)
  --state-file FILE      Formula versions state file (default: .formula-versions.json)
  --upstream-base URL    Base URL for upstream formulas
  --tap TAP_NAME         Tap name (default: jaewoook/nal)
  --max-depth N          Maximum transitive dependency depth (default: 2)
  -h, --help             Show this help message
EOF
      exit 0
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

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
    grep -v -E '^[[:space:]]*no_autobump!' "$tmp" > "$dest"
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
  # Strip on_linux blocks and extract runtime depends_on (ignoring :build and :test, including array syntax like [:build, :test])
  awk '
    /^[[:space:]]*on_linux[[:space:]]+do([[:space:]]|$)/ {
      in_linux = 1
      match($0, /^[[:space:]]*/)
      linux_indent = RLENGTH
      next
    }
    in_linux {
      match($0, /^[[:space:]]*/)
      if (RLENGTH == linux_indent && $0 ~ /^[[:space:]]*end([[:space:]]|$)/) {
        in_linux = 0
      }
      next
    }
    { print }
  ' "$rb_file" 2>/dev/null \
    | grep -E '^[[:space:]]*depends_on[[:space:]]+"[^"]+"' 2>/dev/null \
    | grep -v -E '=>.*:(build|test)' \
    | grep -v -E 'if[[:space:]]+DevelopmentTools\.clang_build_version[[:space:]]*<=[[:space:]]*1500' \
    | sed -E 's/^[[:space:]]*depends_on[[:space:]]+"([^"]+)".*/\1/' \
    | sed "s|^${TAP_NAME}/||" \
    | sort -u || true
}

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

  # Record in state JSON with is_dependency: true if new or not yet recorded
  local local_sha
  local_sha=$(calc_sha256 "$target_path")
  local local_ver
  local_ver=$(grep -E '^[[:space:]]*version[[:space:]]+' "$target_path" | head -n 1 | awk '{print $2}' | tr -d '"'\''' || echo "")
  if [ -z "$local_ver" ]; then
    local_ver=$(grep -oE 'url[[:space:]]+".*-(.*)\.tar' "$target_path" | sed -E 's/.*-(.*)\.tar/\1/' || echo "unknown")
  fi
  local local_rev
  local_rev=$(grep -E '^[[:space:]]*revision[[:space:]]+[0-9]+' "$target_path" | awk '{print $2}' || echo "0")
  local_rev=${local_rev:-0}

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local tmp_state
  tmp_state=$(mktemp)
  jq --arg n "$dep" \
     --arg v "$local_ver" \
     --argjson r "$local_rev" \
     --arg s "$local_sha" \
     --arg t "$timestamp" \
     '.[$n] = ((.[$n] // {}) + {version: $v, revision: $r, sha256: $s, last_updated: $t, is_dependency: true})' \
     "$STATE_FILE" > "$tmp_state" && mv "$tmp_state" "$STATE_FILE"

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
