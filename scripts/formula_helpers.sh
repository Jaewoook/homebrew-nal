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

  grep -v -E '^[[:space:]]*no_autobump!' "$tmp" > "$dest" || true
  rm -f "$tmp"
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
import json, os, re, sys, urllib.request

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
        for shard in shards:
            api_url = f"https://api.github.com/repos/{repo}/contents/Formula/{shard}?ref={ref}"
            try:
                req = urllib.request.Request(api_url, headers={"User-Agent": "homebrew-nal"})
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
            except Exception:
                pass

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

  shopt -s nullglob
  for f in "${formula_name}"--*.tar.gz; do
    [ -f "$f" ] || continue
    target_name="${formula_name}-${f#"$bottle_prefix"}"
    echo "Renaming bottle archive $f -> $target_name"
    mv -- "$f" "$target_name"
  done

  if ! compgen -G "${formula_name}-*.tar.gz" >/dev/null; then
    echo "::error::Normalized bottle archive ${formula_name}-*.tar.gz not found!" >&2
    return 1
  fi
}
