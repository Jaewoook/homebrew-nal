#!/usr/bin/env bash
# ==============================================================================
# formula_helpers.sh - Shared formula parsing and patch-fetching helpers
# ==============================================================================

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
