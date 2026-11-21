#!/usr/bin/env bash
# ==============================================================================
# formula_helpers.sh - Shared formula fetching, parsing, and patch helpers
# ==============================================================================

# Cross-platform SHA256 checksum (sha256sum / shasum / openssl)
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

# Fetch and sanitize an upstream formula .rb file; prints resolved source URL.
# Usage: fetch_upstream_formula <name> <upstream_base> <dest>
fetch_upstream_formula() {
  local name="$1"
  local upstream_base="$2"
  local dest="$3"

  local first_char
  first_char=$(printf "%s" "${name:0:1}" | tr '[:upper:]' '[:lower:]')
  local lib_url="${upstream_base}/Formula/lib/${name}.rb"
  local sharded_url="${upstream_base}/Formula/${first_char}/${name}.rb"
  local root_url="${upstream_base}/Formula/${name}.rb"

  local tmp
  tmp=$(mktemp)
  local source_url=""
  if [[ "$name" == lib* ]] && curl -sSfL "$lib_url" -o "$tmp" 2>/dev/null; then
    source_url="$lib_url"
  elif curl -sSfL "$sharded_url" -o "$tmp" 2>/dev/null; then
    source_url="$sharded_url"
  elif curl -sSfL "$root_url" -o "$tmp" 2>/dev/null; then
    source_url="$root_url"
  else
    rm -f "$tmp"
    return 1
  fi

  local grep_rc=0
  grep -v -E '^[[:space:]]*no_autobump!' "$tmp" > "$dest" || grep_rc=$?
  rm -f "$tmp"
  if [ "$grep_rc" -gt 1 ]; then
    return "$grep_rc"
  fi
  printf '%s\n' "$source_url"
  return 0
}

# List upstream versioned sibling formulas (<formula>@<ver>) sorted newest-first.
# Usage: list_versioned_candidates <formula> <upstream_raw_base> [meta_json]
list_versioned_candidates() {
  local formula="$1"
  local upstream_raw_base="$2"
  local meta_json="${3:-}"

  python3 - "$formula" "$upstream_raw_base" "$meta_json" <<'PY'
import json, os, re, sys, urllib.error, urllib.request

formula, raw_base, meta_raw = sys.argv[1:4]
pat = re.compile(r'^' + re.escape(formula) + r'@([0-9]+(?:\.[0-9]+)*)$')
candidates = set()

if meta_raw:
    try:
        data = json.loads(meta_raw)
        for item in data.get("versioned_formulae") or []:
            if pat.match(str(item)):
                candidates.add(str(item))
    except Exception:
        pass

if not candidates and raw_base.startswith("file://"):
    base_dir = raw_base[len("file://"):]
    first_char = formula[0].lower()
    search_dirs = [
        os.path.join(base_dir, "Formula", first_char),
        os.path.join(base_dir, "Formula"),
    ]
    if formula.startswith("lib"):
        search_dirs.insert(0, os.path.join(base_dir, "Formula", "lib"))
    for d in search_dirs:
        if os.path.isdir(d):
            for fname in os.listdir(d):
                if fname.endswith(".rb"):
                    stem = fname[:-3]
                    if pat.match(stem):
                        candidates.add(stem)

if not candidates:
    m_gh = re.match(r'^https://raw\.githubusercontent\.com/([^/]+/[^/]+)/([^/]+)$', raw_base.rstrip("/"))
    if m_gh:
        repo, ref = m_gh.group(1), m_gh.group(2)
        first_char = formula[0].lower()
        shards = ["lib", first_char] if formula.startswith("lib") else [first_char]
        headers = {"User-Agent": "homebrew-nal", "Accept": "application/vnd.github+json"}
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or os.environ.get("SYNC_PAT") or ""
        if token:
            headers["Authorization"] = f"Bearer {token}"
        for shard in shards:
            api_url = f"https://api.github.com/repos/{repo}/contents/Formula/{shard}?ref={ref}"
            try:
                req = urllib.request.Request(api_url, headers=headers)
                with urllib.request.urlopen(req, timeout=10) as resp:
                    entries = json.loads(resp.read().decode("utf-8"))
                if isinstance(entries, list):
                    for entry in entries:
                        fname = entry.get("name") or ""
                        if fname.endswith(".rb"):
                            stem = fname[:-3]
                            if pat.match(stem):
                                candidates.add(stem)
                if candidates:
                    break
            except urllib.error.HTTPError as e:
                if e.code != 404:
                    sys.stderr.write(f"Warning: GitHub API lookup failed ({e.code}) for {api_url}\n")
            except Exception as e:
                sys.stderr.write(f"Warning: GitHub API lookup error for {api_url}: {e}\n")

def ver_key(name):
    m = pat.match(name)
    if not m:
        return ()
    return tuple(int(p) for p in m.group(1).split("."))

for name in sorted(candidates, key=ver_key, reverse=True):
    print(name)
PY
}

# Extract formula metadata: prints "<version>|<revision>|<arm64_only>"
extract_formula_meta() {
  local rb_file="$1"
  python3 - "$rb_file" <<'PY'
import re, sys, urllib.parse

rb_path = sys.argv[1]
with open(rb_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

ignore_indent = None
in_class = False
class_indent = None
version = ""
revision = 0
url = ""
url_tag = ""
requires_arm64 = False
has_on_intel = False

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent_m = re.match(r'^([ \t]*)', raw_line)
    indent = indent_m.group(1) if indent_m else ""

    if not in_class:
        if re.match(r'^[ \t]*class\s+\S+\s*<\s*Formula\b', raw_line):
            in_class = True
            class_indent = indent
        continue

    if indent == class_indent and re.match(r'^[ \t]*end\b', raw_line):
        break

    if ignore_indent is not None:
        if indent == ignore_indent and re.match(r'^[ \t]*end\b', raw_line):
            ignore_indent = None
        continue

    if re.match(r'^[ \t]*def\s+', raw_line):
        if not re.search(r'\bend\s*$', stripped):
            ignore_indent = indent
        continue

    if re.match(r'^[ \t]*(?:head|bottle|livecheck|resource|fails_with|patch|test|on_linux|on_arm|caveats|service)\b.*\bdo(?:\s*\|[^|]*\|)?\s*(?:#.*)?$', raw_line):
        if not re.search(r'\bend\s*$', stripped):
            ignore_indent = indent
        continue

    if re.match(r'^[ \t]*on_intel\b', raw_line):
        has_on_intel = True

    if re.match(r'^[ \t]*depends_on\s+(?:arch:\s*:arm64|:arch\s*=>\s*:arm64)\b', raw_line):
        requires_arm64 = True

    m_ver = re.match(r'^[ \t]*version\s+["\']([^"\']+)["\']', raw_line)
    if m_ver and not version:
        version = m_ver.group(1)
        continue

    m_rev = re.match(r'^[ \t]*revision\s+(\d+)\b', raw_line)
    if m_rev and revision == 0:
        revision = int(m_rev.group(1))
        continue

    m_url = re.match(r'^[ \t]*url\s+["\']([^"\']+)["\']', raw_line)
    if m_url and not url:
        url = m_url.group(1)
        m_tag = re.search(r'\btag:\s*["\']([^"\']+)["\']', raw_line)
        if m_tag:
            url_tag = m_tag.group(1)
        continue

if not version and url:
    path = urllib.parse.urlparse(url).path
    basename = path.rstrip("/").split("/")[-1]
    stem = re.sub(r'(?:\.tar\.[a-z0-9]+|\.tgz|\.tbz2?|\.txz|\.zip|\.pem)$', '', basename, flags=re.IGNORECASE)
    stem = re.sub(r'[-.](?:src|sources|ga|release|orig)$', '', stem, flags=re.IGNORECASE)
    m = (
        re.search(r'(\d{4}-\d{2}-\d{2})$', stem)
        or re.search(r'(?:^|[-_])[vV]?(\d+(?:\.\d+)+(?:[-.]?(?:alpha|beta|rc|pre|post|p|pl|dev)\d*|[a-z])?)$', stem, re.IGNORECASE)
        or re.search(r'[a-zA-Z][vV]?(\d+(?:\.\d+)+[a-z]?)$', stem)
        or re.search(r'/v?(\d+(?:\.\d+)+(?:[-.]?(?:alpha|beta|rc|pre|post|p|pl|dev)\d*)?)(?:/|$)', path, re.IGNORECASE)
        or re.search(r'(?:^|[-_])[vV]?(\d+)$', stem)
    )
    if m:
        version = m.group(1)
    elif url_tag:
        m_t = re.search(r'[vV]?(\d+(?:\.\d+)+(?:[-.]?(?:alpha|beta|rc|pre|post|p|pl|dev)\d*)?)', url_tag, re.IGNORECASE)
        if m_t:
            version = m_t.group(1)

arm64_only = "true" if (requires_arm64 and not has_on_intel) else "false"
print(f"{version}|{revision}|{arm64_only}")
PY
}

# Download any Patches/ files referenced outside on_linux/on_arm blocks and comments.
# Usage: fetch_referenced_patches <rb_file> <upstream_base> <patches_dir> [overwrite]
fetch_referenced_patches() {
  local rb_file="$1"
  local upstream_base="$2"
  local patches_dir="$3"
  local overwrite="${4:-true}"
  [ -f "$rb_file" ] || return 0

  local patch_files
  patch_files=$(python3 - "$rb_file" <<'PY'
import re, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    lines = f.readlines()

skip_indent = None
found = set()
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent_m = re.match(r'^([ \t]*)', line)
    indent = indent_m.group(1) if indent_m else ""
    if skip_indent is not None:
        if indent == skip_indent and re.match(r'^[ \t]*end\b', line):
            skip_indent = None
        continue
    if re.match(r'^[ \t]*on_(?:linux|arm)\s+do\b', line) and not re.search(r'\bend\s*$', stripped):
        skip_indent = indent
        continue
    code = re.sub(r'\s+#.*$', '', line)
    for m in re.findall(r'Patches/[a-zA-Z0-9._+-]+(?:/[a-zA-Z0-9._+-]+)+', code):
        if ".." not in m.split("/"):
            found.add(m)

for item in sorted(found):
    print(item)
PY
)
  if [ -z "$patch_files" ]; then
    return 0
  fi

  mkdir -p "$patches_dir"
  local patch_rel
  for patch_rel in $patch_files; do
    local patch_sub="${patch_rel#Patches/}"
    local patch_dest="${patches_dir}/${patch_sub}"
    if ! python3 -c 'import os, sys; p = os.path.realpath(sys.argv[1]); b = os.path.realpath(sys.argv[2]); sys.exit(0 if p.startswith(b + os.sep) else 1)' "$patch_dest" "$patches_dir"; then
      echo "  [ERROR] Refusing suspicious patch path: $patch_rel" >&2
      return 1
    fi
    if [ "$overwrite" != "true" ] && [ -f "$patch_dest" ]; then
      continue
    fi
    local patch_url="${upstream_base}/${patch_rel}"
    echo "  [PATCH] Downloading referenced patch: $patch_rel"
    mkdir -p "$(dirname "$patch_dest")"
    local tmp_patch
    tmp_patch=$(mktemp)
    if curl -sSfL "$patch_url" -o "$tmp_patch"; then
      mv "$tmp_patch" "$patch_dest"
      echo "  [PATCH] Saved $patch_dest"
    else
      rm -f "$tmp_patch"
      echo "  [ERROR] Failed to download patch from $patch_url" >&2
      return 1
    fi
  done
}

# Normalize Homebrew double-hyphen bottle filenames (<formula>--<ver> -> <formula>-<ver>)
# using Bash 3.2-safe prefix removal, and verify at least one archive exists.
# Usage: normalize_bottle_archives <formula_name>
normalize_bottle_archives() {
  local formula_name="$1"
  local bottle_prefix="${formula_name}--"
  local f target_name
  local had_nullglob=0

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  for f in "${formula_name}"--*.tar.gz; do
    [ -f "$f" ] || continue
    target_name="${formula_name}-${f#"$bottle_prefix"}"
    echo "Renaming bottle archive $f -> $target_name"
    mv -- "$f" "$target_name"
  done

  if ! compgen -G "${formula_name}-*.tar.gz" >/dev/null; then
    if [ "$had_nullglob" -eq 0 ]; then shopt -u nullglob; fi
    echo "::error::Normalized bottle archive ${formula_name}-*.tar.gz not found!" >&2
    return 1
  fi
  if [ "$had_nullglob" -eq 0 ]; then shopt -u nullglob; fi
}

# Validate Homebrew formula name syntax (<name> or <name>@<version>)
is_valid_formula_name() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9._+-]+(@[0-9.]+)?$ ]]
}

# Validate Homebrew cask/package identifier syntax
is_valid_cask_name() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9._+-]+(@[a-zA-Z0-9._+-]+)?$ ]]
}

# Emit a key=value pair to GITHUB_OUTPUT if set, otherwise print to stdout
emit_github_output() {
  local key="$1"
  local value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$key" "$value"
  fi
}

# Check whether a stored formula version string is valid and usable (not missing or corrupt)
is_valid_formula_version() {
  local ver="${1:-}"
  [[ -n "$ver" && "$ver" != "unknown" && "$ver" != *$'\n'* && "$ver" != *"/"* ]]
}

# Fetch stable version and revision from Homebrew API JSON; prints "<ver>|<rev>"
# Usage: resolve_upstream_api_version <formula_name> <api_base_url>
resolve_upstream_api_version() {
  local name="$1"
  local api_base="${2:-}"
  local ver=""
  local rev=0

  if [[ -n "$api_base" ]]; then
    local api_json
    api_json=$(curl -sSfL "${api_base}/${name}.json" 2>/dev/null || true)
    if [[ -n "$api_json" ]]; then
      ver=$(echo "$api_json" | jq -r '.versions.stable // empty' 2>/dev/null || true)
      rev=$(echo "$api_json" | jq -r '.revision // 0' 2>/dev/null || echo "0")
      rev=${rev:-0}
    fi
  fi

  printf '%s|%s\n' "$ver" "$rev"
}

# Atomically update an entry in .formula-versions.json
# Usage: update_formula_state <state_file> <name> <version> <revision> <sha256> [extra_flag_field]
update_formula_state() {
  local state_file="$1"
  local name="$2"
  local ver="$3"
  local rev="${4:-0}"
  local sha="$5"
  local extra_flag="${6:-}"
  local timestamp tmp_state

  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  tmp_state=$(mktemp)

  if [[ -n "$extra_flag" ]]; then
    jq --arg n "$name" \
       --arg v "$ver" \
       --argjson r "$rev" \
       --arg s "$sha" \
       --arg t "$timestamp" \
       --arg f "$extra_flag" \
       '.[$n] = ((.[$n] // {}) + {version: $v, revision: $r, sha256: $s, last_updated: $t} + {($f): true})' \
       "$state_file" > "$tmp_state" && mv "$tmp_state" "$state_file"
  else
    jq --arg n "$name" \
       --arg v "$ver" \
       --argjson r "$rev" \
       --arg s "$sha" \
       --arg t "$timestamp" \
       '.[$n] = ((.[$n] // {}) + {version: $v, revision: $r, sha256: $s, last_updated: $t})' \
       "$state_file" > "$tmp_state" && mv "$tmp_state" "$state_file"
  fi
}

# Extract macOS Intel formula dependency names outside on_linux/on_arm blocks and comments.
# Usage: extract_formula_deps <rb_file> [--include-build] [--tap TAP_NAME] [--strip-any-tap]
extract_formula_deps() {
  local rb_file="$1"
  shift
  local include_build="false"
  local tap_name=""
  local strip_any_tap="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include-build)
        include_build="true"
        shift
        ;;
      --tap)
        tap_name="$2"
        shift 2
        ;;
      --strip-any-tap)
        strip_any_tap="true"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  [ -f "$rb_file" ] || return 0

  python3 - "$rb_file" "$include_build" "$tap_name" "$strip_any_tap" <<'PY'
import re, sys

rb_path, include_build_str, tap_name, strip_any_str = sys.argv[1:5]
include_build = include_build_str == "true"
strip_any = strip_any_str == "true"

with open(rb_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

skip_indent = None
deps = set()

for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent_m = re.match(r'^([ \t]*)', line)
    indent = indent_m.group(1) if indent_m else ""
    if skip_indent is not None:
        if indent == skip_indent and re.match(r'^[ \t]*end\b', line):
            skip_indent = None
        continue
    if re.match(r'^[ \t]*on_(?:linux|arm)\s+do\b', line) and not re.search(r'\bend\s*$', stripped):
        skip_indent = indent
        continue

    code_only = re.sub(r'#.*$', '', line)
    m_dep = re.match(r'^[ \t]*depends_on[ \t]+"([^"]+)"(.*)$', code_only)
    if not m_dep:
        continue
    dep_name, rest = m_dep.group(1), m_dep.group(2)

    if re.search(r'\bif\s+DevelopmentTools\.clang_build_version\s*<=\s*1500\b', code_only):
        continue

    if include_build:
        if re.search(r'=>.*:test\b', rest) and not re.search(r'=>.*:build\b', rest):
            continue
    else:
        if re.search(r'=>.*:(build|test)\b', rest):
            continue

    if strip_any and "/" in dep_name:
        dep_name = dep_name.split("/")[-1]
    elif tap_name and dep_name.startswith(tap_name + "/"):
        dep_name = dep_name[len(tap_name) + 1:]

    deps.add(dep_name)

for d in sorted(deps):
    print(d)
PY
}

# Locate <formula>--*.bottle.json, merge bottle metadata into formula, and normalize filenames.
# Returns: 0 on success, 2 if bottle JSON file is not found, 1 on merge/normalize error.
merge_and_normalize_bottle() {
  local brew_bin="$1"
  local formula_name="$2"
  local bottle_json_files bottle_json
  local had_nullglob=0

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  bottle_json_files=("${formula_name}"--*.bottle.json)
  if [ "$had_nullglob" -eq 0 ]; then shopt -u nullglob; fi
  bottle_json="${bottle_json_files[0]:-}"
  if [ -z "$bottle_json" ] || [ ! -f "$bottle_json" ]; then
    return 2
  fi

  echo "Merging bottle information from $bottle_json into Formula/${formula_name}.rb..."
  "$brew_bin" bottle --merge --write --no-commit "$bottle_json" || return 1
  normalize_bottle_archives "$formula_name"
}

# Snapshot /opt/homebrew host state when running locally outside GitHub Actions.
# Prints "true" or "false" indicating whether host restore should run on exit.
maybe_record_local_host_state() {
  local pkg_type="$1"
  local pkg_name="$2"
  local script_dir="$3"

  if [ -z "${GITHUB_ACTIONS:-}" ] && [ "${SKIP_HOST_RESTORE:-false}" != "true" ] && [ -f "${script_dir}/restore_host_state.sh" ]; then
    bash "${script_dir}/restore_host_state.sh" record-state "$pkg_type" "$pkg_name"
    return 0
  fi
  return 1
}

_push_origin_main_with_retry() {
  local max_attempts="${1:-3}"
  shift || true
  local attempt=1

  while [ "$attempt" -le "$max_attempts" ]; do
    if ! git "$@" pull --rebase origin main; then
      git rebase --abort 2>/dev/null || true
      echo "::error::git pull --rebase origin main failed due to conflict; aborted rebase." >&2
      return 1
    fi
    if git push origin main; then
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      echo "Warning: git push origin main failed (attempt ${attempt}/${max_attempts}); retrying after rebase..." >&2
    fi
    attempt=$((attempt + 1))
  done

  echo "::error::git push origin main failed after ${max_attempts} attempts." >&2
  return 1
}

_with_bot_git_env() {
  local fn_name="$1"
  shift

  local bot_name="${BOT_NAME:-NAL Bot}"
  local bot_email="${BOT_EMAIL:-nal-git-system@jaewook.me}"
  local bot_gpg_key="${BOT_GPG_KEY-024D4017DFF5360A}"

  (
    local orig_name orig_email orig_key orig_sign restore_done="false"
    orig_name=$(git config --local user.name 2>/dev/null || true)
    orig_email=$(git config --local user.email 2>/dev/null || true)
    orig_key=$(git config --local user.signingkey 2>/dev/null || true)
    orig_sign=$(git config --local commit.gpgsign 2>/dev/null || true)

    _restore_bot_git_config() {
      [ "$restore_done" = "true" ] && return 0
      restore_done="true"
      if [ -n "$orig_name" ]; then git config --local user.name "$orig_name"; else git config --local --unset user.name 2>/dev/null || true; fi
      if [ -n "$orig_email" ]; then git config --local user.email "$orig_email"; else git config --local --unset user.email 2>/dev/null || true; fi
      if [ -n "$orig_key" ]; then git config --local user.signingkey "$orig_key"; else git config --local --unset user.signingkey 2>/dev/null || true; fi
      if [ -n "$orig_sign" ]; then git config --local commit.gpgsign "$orig_sign"; else git config --local --unset commit.gpgsign 2>/dev/null || true; fi
    }
    trap _restore_bot_git_config EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    export GIT_AUTHOR_NAME="$bot_name"
    export GIT_AUTHOR_EMAIL="$bot_email"
    export GIT_COMMITTER_NAME="$bot_name"
    export GIT_COMMITTER_EMAIL="$bot_email"

    local git_sign_args=(
      -c user.name="$bot_name"
      -c user.email="$bot_email"
    )

    if [ -n "$bot_gpg_key" ] && gpg --list-secret-keys "$bot_gpg_key" >/dev/null 2>&1; then
      git_sign_args+=(
        -c user.signingkey="$bot_gpg_key"
        -c commit.gpgsign=true
      )
    else
      git_sign_args+=(
        -c commit.gpgsign=false
      )
    fi

    "$fn_name" "$@"
  )
}

_git_bot_commit_and_push_inner() {
  local file_path="$1"
  local no_changes_msg="$2"
  shift 2

  local msg_args=()
  local msg
  for msg in "$@"; do
    msg_args+=(-m "$msg")
  done

  git add -- "$file_path"
  if ! git diff --staged --quiet; then
    git "${git_sign_args[@]}" commit "${msg_args[@]}"
    emit_github_output "changed" "true"
    if [ "${BOT_NO_PUSH:-false}" != "true" ]; then
      _push_origin_main_with_retry 3 "${git_sign_args[@]}"
    fi
  else
    echo "$no_changes_msg"
    emit_github_output "changed" "false"
  fi

  local commit_sha
  commit_sha=$(git rev-parse HEAD)
  emit_github_output "commit_sha" "$commit_sha"
}

git_bot_push_main() {
  _git_bot_push_main_inner() {
    _push_origin_main_with_retry 3 "${git_sign_args[@]}"
    local commit_sha
    commit_sha=$(git rev-parse HEAD)
    emit_github_output "commit_sha" "$commit_sha"
  }
  _with_bot_git_env _git_bot_push_main_inner
}

# Stage, optionally GPG-sign/commit locally (unless BOT_NO_PUSH=true), and push
# with bot identity without altering caller traps or leaving local git config modified.
# Usage: git_bot_commit_and_push <file_path> <no_changes_msg> <commit_msg_1> [commit_msg_2 ...]
git_bot_commit_and_push() {
  _with_bot_git_env _git_bot_commit_and_push_inner "$@"
}
