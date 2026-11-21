#!/usr/bin/env bash
# ==============================================================================
# mirror_cask.sh - Download, verify x86_64 support, and rewrite Homebrew Cask
#   to mirror the binary in Jaewoook/homebrew-nal GitHub Releases under
#   tag: cask-<name>.<version>
# ==============================================================================
set -euo pipefail

CASK_NAME="${1:?Cask name argument required}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-}"
GITHUB_ENV="${GITHUB_ENV:-}"
REPO="${REPO:-Jaewoook/homebrew-nal}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/formula_helpers.sh
source "${SCRIPT_DIR}/formula_helpers.sh"

if ! is_valid_cask_name "$CASK_NAME"; then
  echo "::error::Invalid cask name: $CASK_NAME" >&2
  exit 1
fi

CASK_FILE="Casks/${CASK_NAME}.rb"
if [[ ! -f "$CASK_FILE" ]]; then
  echo "::error::Cask file not found: $CASK_FILE" >&2
  exit 1
fi

RESTORE_HOST_STATE_ON_EXIT="false"
CLEANUP_DONE="false"
VERIFY_TMP=""
MOUNT_DIR=""
MOUNT_MOUNTED="false"
cleanup_on_exit() {
  [ "$CLEANUP_DONE" = "true" ] && return 0
  CLEANUP_DONE="true"
  if [ "$MOUNT_MOUNTED" = "true" ] && [ -n "${MOUNT_DIR:-}" ] && command -v hdiutil >/dev/null 2>&1; then
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    MOUNT_MOUNTED="false"
  fi
  [ -n "${VERIFY_TMP:-}" ] && rm -rf "$VERIFY_TMP"
  if [ "$RESTORE_HOST_STATE_ON_EXIT" = "true" ]; then
    bash "${SCRIPT_DIR}/restore_host_state.sh" restore cask "$CASK_NAME"
  fi
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if maybe_record_local_host_state "cask" "$CASK_NAME" "$SCRIPT_DIR"; then
  RESTORE_HOST_STATE_ON_EXIT="true"
fi

# 1. Parse Cask metadata for Intel (x86_64)
PARSED_META=$(python3 - "$CASK_FILE" "$CASK_NAME" <<'PY'
import re, sys, urllib.parse

rb_path = sys.argv[1]
cask_name = sys.argv[2]
with open(rb_path, "r", encoding="utf-8") as f:
    content = f.read()

# Reject arm64-only casks
if re.search(r'depends_on\s+arch:\s*:arm64\b', content) and not re.search(r'\bon_intel\s+do\b', content):
    sys.stderr.write("Cask requires :arm64 architecture and has no Intel build.\n")
    sys.exit(2)

# Resolve arch helper variable if present: arch arm: "...", intel: "..."
arch_val = "x86_64"
arch_match = re.search(r'\barch\s+([^\n]+)', content)
if arch_match:
    intel_m = re.search(r'intel:\s*"([^"]*)"', arch_match.group(1))
    if intel_m:
        arch_val = intel_m.group(1)

# Extract on_intel block if present (indentation-anchored so nested if/end does not truncate)
intel_block = ""
intel_block_m = re.search(r'^([ \t]*)on_intel\s+do\b(.*?)^\1end\b', content, re.MULTILINE | re.DOTALL)
if intel_block_m:
    intel_block = intel_block_m.group(2)

# Remove on_arm block so we don't accidentally match arm64 version/url/sha256
content_no_arm = re.sub(r'^([ \t]*)on_arm\s+do\b.*?^\1end\b', '', content, flags=re.MULTILINE | re.DOTALL)

# Extract version (prefer on_intel version if overridden)
ver_m = re.search(r'^\s*version\s+"([^"]+)"', intel_block, re.MULTILINE) or re.search(r'^\s*version\s+"([^"]+)"', content_no_arm, re.MULTILINE)
if not ver_m:
    sys.stderr.write("Could not parse version from cask.\n")
    sys.exit(1)
version = ver_m.group(1)

# Extract sha256 (handle multi-line sha256 arm: "...", intel: "..." or :no_check)
sha256 = ""
sha_intel_m = re.search(r'sha256\s+(?:arm:\s*(?:"[^"]+"|:no_check)\s*,\s*)?intel:\s*("([^"]+)"|:no_check)', content, re.DOTALL)
if sha_intel_m:
    sha256 = sha_intel_m.group(2) or ":no_check"
else:
    sha_m = re.search(r'^\s*sha256\s+"([^"]+)"', intel_block, re.MULTILINE) or re.search(r'^\s*sha256\s+"([^"]+)"', content_no_arm, re.MULTILINE)
    if sha_m:
        sha256 = sha_m.group(1)
    elif re.search(r'^\s*sha256\s+:no_check\b', intel_block, re.MULTILINE) or re.search(r'^\s*sha256\s+:no_check\b', content_no_arm, re.MULTILINE):
        sha256 = ":no_check"

# Extract url
url_m = re.search(r'^\s*url\s+"([^"]+)"', intel_block, re.MULTILINE) or re.search(r'^\s*url\s+"([^"]+)"', content_no_arm, re.MULTILINE)
if not url_m:
    sys.stderr.write("Could not parse url from cask.\n")
    sys.exit(1)
raw_url = url_m.group(1)

# Interpolate #{arch} and #{version...}
csv_parts = version.split(",")
csv_first = csv_parts[0]
major_minor_patch = csv_first.split(".")
major = major_minor_patch[0] if len(major_minor_patch) > 0 else ""
minor = major_minor_patch[1] if len(major_minor_patch) > 1 else ""
patch = major_minor_patch[2] if len(major_minor_patch) > 2 else ""
major_minor = f"{major}.{minor}" if minor else major
major_minor_patch_str = ".".join(major_minor_patch[:3])
replacements = {
    "#{arch}": arch_val,
    "#{version}": version,
    "#{version.before_comma}": csv_first,
    "#{version.after_comma}": csv_parts[1] if len(csv_parts) > 1 else "",
    "#{version.csv.first}": csv_first,
    "#{version.csv.second}": csv_parts[1] if len(csv_parts) > 1 else "",
    "#{version.csv.third}": csv_parts[2] if len(csv_parts) > 2 else "",
    "#{version.csv.first.major}": major,
    "#{version.csv.first.minor}": minor,
    "#{version.csv.first.patch}": patch,
    "#{version.major}": major,
    "#{version.minor}": minor,
    "#{version.patch}": patch,
    "#{version.major_minor}": major_minor,
    "#{version.major_minor_patch}": major_minor_patch_str,
    "#{version.no_dots}": csv_first.replace(".", ""),
    "#{version.dots_to_underscores}": version.replace(".", "_"),
    "#{version.dots_to_hyphens}": version.replace(".", "-"),
}
resolved_url = raw_url
for k, v in replacements.items():
    resolved_url = resolved_url.replace(k, v)

parsed_url = urllib.parse.urlparse(resolved_url)
raw_basename = parsed_url.path.rstrip("/").split("/")[-1]
clean_basename = urllib.parse.unquote(raw_basename)
clean_basename = re.sub(r'[^a-zA-Z0-9._-]', '_', clean_basename)
if not clean_basename or clean_basename.startswith(".") or "." not in clean_basename:
    clean_basename = f"{cask_name}-{csv_parts[0]}.dmg"

print(f"{csv_parts[0]}|{sha256}|{resolved_url}|{clean_basename}")
PY
) || {
  echo "::error::Failed to parse or validate Intel support for Cask $CASK_NAME" >&2
  exit 1
}

IFS='|' read -r VERSION EXPECTED_SHA RESOLVED_URL ASSET_FILENAME <<< "$PARSED_META"

RELEASE_TAG="cask-${CASK_NAME}.${VERSION}"
RELEASE_TITLE="cask-${CASK_NAME} ${VERSION}"
MIRRORED_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${ASSET_FILENAME}"

echo "=========================================="
echo "Mirroring Cask: $CASK_NAME ($VERSION)"
echo "Upstream URL:   $RESOLVED_URL"
echo "Asset Filename: $ASSET_FILENAME"
echo "Release Tag:    $RELEASE_TAG"
echo "=========================================="

rm -f -- "$ASSET_FILENAME"
if ! curl -sSfL -o "$ASSET_FILENAME" "$RESOLVED_URL"; then
  echo "::error::Failed to download cask binary from $RESOLVED_URL" >&2
  exit 1
fi

ACTUAL_SHA=$(calc_sha256 "$ASSET_FILENAME")

if [[ -n "$EXPECTED_SHA" && "$EXPECTED_SHA" != ":no_check" && "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "::error::SHA256 mismatch for $ASSET_FILENAME: expected $EXPECTED_SHA, got $ACTUAL_SHA" >&2
  rm -f -- "$ASSET_FILENAME"
  exit 1
fi

# Optional Mach-O architecture check on downloaded archive/DMG
if [[ "${SKIP_ARCH_BINARY_MOUNT:-false}" != "true" ]] && command -v lipo >/dev/null 2>&1; then
  VERIFY_TMP=$(mktemp -d)
  check_macho_dir() {
    local dir="$1"
    local found_macho=0
    local found_x86=0
    while IFS= read -r -d '' f; do
      if file "$f" 2>/dev/null | grep -q "Mach-O"; then
        found_macho=1
        if lipo -archs "$f" 2>/dev/null | grep -qw "x86_64"; then
          found_x86=1
          break
        fi
      fi
    done < <(find "$dir" -maxdepth 8 -type f -print0 2>/dev/null)
    if [[ $found_macho -eq 1 && $found_x86 -eq 0 ]]; then
      echo "::error::Cask $CASK_NAME contains Mach-O binaries but none support x86_64!" >&2
      return 1
    fi
    return 0
  }

  VERIFY_STATUS=0
  case "$ASSET_FILENAME" in
    *.zip)
      if unzip -q "$ASSET_FILENAME" -d "$VERIFY_TMP" 2>/dev/null; then
        check_macho_dir "$VERIFY_TMP" || VERIFY_STATUS=1
      else
        echo "::error::Failed to extract zip archive $ASSET_FILENAME for Mach-O verification." >&2
        VERIFY_STATUS=1
      fi
      ;;
    *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2)
      if tar -xf "$ASSET_FILENAME" -C "$VERIFY_TMP" 2>/dev/null; then
        check_macho_dir "$VERIFY_TMP" || VERIFY_STATUS=1
      else
        echo "::error::Failed to extract tar archive $ASSET_FILENAME for Mach-O verification." >&2
        VERIFY_STATUS=1
      fi
      ;;
    *.dmg)
      if command -v hdiutil >/dev/null 2>&1; then
        MOUNT_DIR="$VERIFY_TMP/mnt"
        mkdir -p "$MOUNT_DIR"
        if hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$ASSET_FILENAME" >/dev/null 2>&1; then
          MOUNT_MOUNTED="true"
          check_macho_dir "$MOUNT_DIR" || VERIFY_STATUS=1
          hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
          MOUNT_MOUNTED="false"
        else
          echo "::error::Failed to attach DMG image $ASSET_FILENAME for Mach-O verification." >&2
          VERIFY_STATUS=1
        fi
      fi
      ;;
  esac
  rm -rf "$VERIFY_TMP"
  VERIFY_TMP=""
  MOUNT_DIR=""
  if [[ $VERIFY_STATUS -ne 0 ]]; then
    rm -f -- "$ASSET_FILENAME"
    exit 1
  fi
fi

# Rewrite Casks/<name>.rb to point url and sha256 to the mirrored GitHub Release asset
python3 - "$CASK_FILE" "$VERSION" "$ACTUAL_SHA" "$MIRRORED_URL" <<'PY'
import re, sys

rb_path, version, sha, mirrored_url = sys.argv[1:5]
with open(rb_path, "r", encoding="utf-8") as f:
    content = f.read()

def strip_quotes_and_comments(line_text):
    out = []
    i = 0
    n = len(line_text)
    in_quote = None
    while i < n:
        ch = line_text[i]
        if in_quote:
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            if ch == in_quote:
                in_quote = None
            i += 1
            continue
        if ch == "#":
            break
        if ch in ('"', "'"):
            in_quote = ch
            out.append(" ")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)

def replace_cask_url(text, target_url):
    """Replace the first url statement (including inline/multi-line kwargs and balanced brackets)."""
    m = re.search(r'^([ \t]*)url\s+"[^"]+"', text, re.MULTILINE)
    if not m:
        return text, False
    indent = m.group(1)
    lines = text.splitlines(keepends=True)
    # Locate which line m.start() falls on
    offset = 0
    start_line = 0
    for i, ln in enumerate(lines):
        if offset <= m.start() < offset + len(ln):
            start_line = i
            break
        offset += len(ln)

    bracket_depth = 0
    end_line = start_line
    for i in range(start_line, len(lines)):
        cleaned = strip_quotes_and_comments(lines[i]).rstrip()
        bracket_depth += cleaned.count("(") + cleaned.count("[") + cleaned.count("{")
        bracket_depth -= cleaned.count(")") + cleaned.count("]") + cleaned.count("}")
        bracket_depth = max(0, bracket_depth)
        end_line = i
        if bracket_depth == 0 and not cleaned.endswith((",", "\\")):
            break

    had_newline = lines[end_line].endswith("\n")
    replacement = f'{indent}url "{target_url}"' + ("\n" if had_newline else "")
    new_lines = lines[:start_line] + [replacement] + lines[end_line + 1:]
    return "".join(new_lines), True

has_on_intel = bool(re.search(r'^[ \t]*on_intel\s+do\b', content, re.MULTILINE))
has_on_arm = bool(re.search(r'^[ \t]*on_arm\s+do\b', content, re.MULTILINE))
rewrote_intel_url = False
rewrote_intel_sha = False

# First rewrite top-level intel: sha256 if defined (supports "..." and :no_check)
sha_top_intel_pattern = r'(sha256\s+(?:arm:\s*(?:"[^"]+"|:no_check)\s*,\s*)?intel:\s*)(?:"[^"]+"|:no_check)'
sha_top_intel_reverse = r'(sha256\s+intel:\s*)(?:"[^"]+"|:no_check)'
if re.search(sha_top_intel_pattern, content, re.DOTALL):
    content = re.sub(sha_top_intel_pattern, lambda m: f'{m.group(1)}"{sha}"', content, count=1, flags=re.DOTALL)
    rewrote_intel_sha = True
elif re.search(sha_top_intel_reverse, content, re.DOTALL):
    content = re.sub(sha_top_intel_reverse, lambda m: f'{m.group(1)}"{sha}"', content, count=1, flags=re.DOTALL)
    rewrote_intel_sha = True

if has_on_intel:
    def rewrite_intel_block(m):
        global rewrote_intel_url, rewrote_intel_sha
        header, body, footer = m.group(1) + m.group(2), m.group(3), m.group(4)
        body, did_url = replace_cask_url(body, mirrored_url)
        if did_url:
            rewrote_intel_url = True
        sha_intel_re = re.compile(r'^([ \t]*)sha256\s+(?:"[^"]+"|:no_check)', re.MULTILINE)
        if sha_intel_re.search(body):
            body = sha_intel_re.sub(lambda sm: f'{sm.group(1)}sha256 "{sha}"', body, count=1)
            rewrote_intel_sha = True
        elif did_url and not rewrote_intel_sha and has_on_arm:
            # Avoid overwriting a top-level sha256 still needed by on_arm: inject sha256 inside on_intel
            url_line_m = re.search(r'^([ \t]*)url\s+"[^"]+"[^\n]*\n?', body, re.MULTILINE)
            if url_line_m:
                ind = url_line_m.group(1)
                body = body[:url_line_m.start()] + f'{ind}sha256 "{sha}"\n' + body[url_line_m.start():]
                rewrote_intel_sha = True
        return header + body + footer

    content = re.sub(
        r'^([ \t]*)(on_intel\s+do\b)(.*?)(^\1end\b)',
        rewrite_intel_block,
        content,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )

# Rewrite top-level sha256 if Intel sha256 wasn't already handled (outside on_arm)
if not rewrote_intel_sha:
    top_sha_re = re.compile(r'^([ \t]*)sha256\s+(?:"[^"]+"|:no_check)', re.MULTILINE)
    arm_m = re.search(r'^([ \t]*)on_arm\s+do\b.*?^\1end\b', content, re.MULTILINE | re.DOTALL)
    for sm in top_sha_re.finditer(content):
        if arm_m and arm_m.start() <= sm.start() < arm_m.end():
            continue
        content = content[:sm.start()] + f'{sm.group(1)}sha256 "{sha}"' + content[sm.end():]
        rewrote_intel_sha = True
        break

# Rewrite top-level url if no url existed inside on_intel (avoiding on_arm)
if not rewrote_intel_url:
    arm_m = re.search(r'^([ \t]*)on_arm\s+do\b.*?^\1end\b', content, re.MULTILINE | re.DOTALL)
    if arm_m:
        before_arm = content[:arm_m.start()]
        new_before, did_url = replace_cask_url(before_arm, mirrored_url)
        if did_url:
            content = new_before + content[arm_m.start():]
        else:
            after_arm = content[arm_m.end():]
            new_after, did_after = replace_cask_url(after_arm, mirrored_url)
            if did_after:
                content = content[:arm_m.end()] + new_after
    else:
        content, _ = replace_cask_url(content, mirrored_url)

with open(rb_path, "w", encoding="utf-8") as f:
    f.write(content)
PY

if [[ -n "$GITHUB_ENV" ]]; then
  echo "RELEASE_TAG=${RELEASE_TAG}" >> "$GITHUB_ENV"
  echo "RELEASE_TITLE=${RELEASE_TITLE}" >> "$GITHUB_ENV"
  echo "CASK_FILE=${ASSET_FILENAME}" >> "$GITHUB_ENV"
  echo "CASK_VERSION=${VERSION}" >> "$GITHUB_ENV"
fi

emit_github_output "cask_file" "$ASSET_FILENAME"
emit_github_output "release_tag" "$RELEASE_TAG"
emit_github_output "release_title" "$RELEASE_TITLE"
emit_github_output "version" "$VERSION"
