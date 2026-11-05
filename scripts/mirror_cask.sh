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

if [[ ! "$CASK_NAME" =~ ^[a-zA-Z0-9._+-]+(@[a-zA-Z0-9._+-]+)?$ ]]; then
  echo "::error::Invalid cask name: $CASK_NAME" >&2
  exit 1
fi

CASK_FILE="Casks/${CASK_NAME}.rb"
if [[ ! -f "$CASK_FILE" ]]; then
  echo "::error::Cask file not found: $CASK_FILE" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${GITHUB_ACTIONS:-}" ] && [ "${SKIP_HOST_RESTORE:-false}" != "true" ] && [ -f "${SCRIPT_DIR}/restore_host_state.sh" ]; then
  bash "${SCRIPT_DIR}/restore_host_state.sh" record-state cask "$CASK_NAME"
  trap 'bash "${SCRIPT_DIR}/restore_host_state.sh" restore cask "$CASK_NAME"' EXIT
fi

# 1. Parse Cask metadata for Intel (x86_64)
PARSED_META=$(python3 - "$CASK_FILE" <<'PY'
import re, sys, urllib.parse

rb_path = sys.argv[1]
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

# Extract on_intel block if present
intel_block = ""
intel_block_m = re.search(r'\bon_intel\s+do\b(.*?)\bend\b', content, re.DOTALL)
if intel_block_m:
    intel_block = intel_block_m.group(1)

# Remove on_arm block so we don't accidentally match arm64 version/url/sha256
content_no_arm = re.sub(r'\bon_arm\s+do\b.*?\bend\b', '', content, flags=re.DOTALL)

# Extract version (prefer on_intel version if overridden)
ver_m = re.search(r'^\s*version\s+"([^"]+)"', intel_block, re.MULTILINE) or re.search(r'^\s*version\s+"([^"]+)"', content_no_arm, re.MULTILINE)
if not ver_m:
    sys.stderr.write("Could not parse version from cask.\n")
    sys.exit(1)
version = ver_m.group(1)

# Extract sha256 (handle multi-line sha256 arm: "...", intel: "..." or sha256 "..." or :no_check)
sha256 = ""
sha_intel_m = re.search(r'sha256\s+(?:arm:\s*"[^"]+"\s*,\s*)?intel:\s*"([^"]+)"', content, re.DOTALL)
if sha_intel_m:
    sha256 = sha_intel_m.group(1)
else:
    sha_m = re.search(r'^\s*sha256\s+"([^"]+)"', intel_block, re.MULTILINE) or re.search(r'^\s*sha256\s+"([^"]+)"', content_no_arm, re.MULTILINE)
    if sha_m:
        sha256 = sha_m.group(1)
    elif re.search(r'^\s*sha256\s+:no_check\b', content_no_arm, re.MULTILINE):
        sha256 = ":no_check"

# Extract url
url_m = re.search(r'^\s*url\s+"([^"]+)"', intel_block, re.MULTILINE) or re.search(r'^\s*url\s+"([^"]+)"', content_no_arm, re.MULTILINE)
if not url_m:
    sys.stderr.write("Could not parse url from cask.\n")
    sys.exit(1)
raw_url = url_m.group(1)

# Interpolate #{arch} and #{version...}
csv_parts = version.split(",")
major_minor_patch = csv_parts[0].split(".")
replacements = {
    "#{arch}": arch_val,
    "#{version}": version,
    "#{version.csv.first}": csv_parts[0],
    "#{version.csv.second}": csv_parts[1] if len(csv_parts) > 1 else "",
    "#{version.csv.third}": csv_parts[2] if len(csv_parts) > 2 else "",
    "#{version.major}": major_minor_patch[0] if len(major_minor_patch) > 0 else "",
    "#{version.minor}": major_minor_patch[1] if len(major_minor_patch) > 1 else "",
    "#{version.patch}": major_minor_patch[2] if len(major_minor_patch) > 2 else "",
    "#{version.dots_to_underscores}": version.replace(".", "_"),
    "#{version.dots_to_hyphens}": version.replace(".", "-"),
}
resolved_url = raw_url
for k, v in replacements.items():
    resolved_url = resolved_url.replace(k, v)

parsed_url = urllib.parse.urlparse(resolved_url)
basename = parsed_url.path.rstrip("/").split("/")[-1]
if not basename:
    basename = f"cask-binary-{csv_parts[0]}.dmg"

print(f"{csv_parts[0]}|{sha256}|{resolved_url}|{basename}")
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

if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA=$(shasum -a 256 "$ASSET_FILENAME" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA=$(sha256sum "$ASSET_FILENAME" | awk '{print $1}')
else
  ACTUAL_SHA=$(openssl dgst -sha256 "$ASSET_FILENAME" | awk '{print $NF}')
fi

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
    done < <(find "$dir" -maxdepth 5 -type f -print0 2>/dev/null)
    if [[ $found_macho -eq 1 && $found_x86 -eq 0 ]]; then
      echo "::error::Cask $CASK_NAME contains Mach-O binaries but none support x86_64!" >&2
      return 1
    fi
    return 0
  }

  VERIFY_STATUS=0
  case "$ASSET_FILENAME" in
    *.zip)
      unzip -q "$ASSET_FILENAME" -d "$VERIFY_TMP" 2>/dev/null || true
      check_macho_dir "$VERIFY_TMP" || VERIFY_STATUS=1
      ;;
    *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2)
      tar -xf "$ASSET_FILENAME" -C "$VERIFY_TMP" 2>/dev/null || true
      check_macho_dir "$VERIFY_TMP" || VERIFY_STATUS=1
      ;;
    *.dmg)
      if command -v hdiutil >/dev/null 2>&1; then
        MOUNT_DIR="$VERIFY_TMP/mnt"
        mkdir -p "$MOUNT_DIR"
        if hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$ASSET_FILENAME" >/dev/null 2>&1; then
          check_macho_dir "$MOUNT_DIR" || VERIFY_STATUS=1
          hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
        fi
      fi
      ;;
  esac
  rm -rf "$VERIFY_TMP"
  if [[ $VERIFY_STATUS -ne 0 ]]; then
    exit 1
  fi
fi

# Rewrite Casks/<name>.rb to point url and sha256 to the mirrored GitHub Release asset
python3 - "$CASK_FILE" "$VERSION" "$ACTUAL_SHA" "$MIRRORED_URL" <<'PY'
import re, sys

rb_path, version, sha, mirrored_url = sys.argv[1:5]
with open(rb_path, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Replace multi-line or single-line sha256 (including arm:/intel: pairs)
content = re.sub(
    r'^(\s*)sha256\s+(?:arm:\s*"[^"]+"\s*,\s*intel:\s*"[^"]+"|intel:\s*"[^"]+"\s*,\s*arm:\s*"[^"]+"|"[^"]+"|:no_check)',
    rf'\1sha256 "{sha}"',
    content,
    count=1,
    flags=re.MULTILINE | re.DOTALL,
)

# 2. If on_intel block exists with a url, rewrite the url inside on_intel; otherwise rewrite the top-level url
def rewrite_url_in_block(text: str) -> str:
    return re.sub(
        r'^(\s*)url\s+"[^"]+"(?:\s*,\s*\n(?:\s+[a-z_]+:.*\n)+)?',
        rf'\1url "{mirrored_url}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )

if re.search(r'\bon_intel\s+do\b.*?\burl\s+"[^"]+".*?\bend\b', content, re.DOTALL):
    content = re.sub(
        r'(\bon_intel\s+do\b)(.*?)(\bend\b)',
        lambda m: m.group(1) + rewrite_url_in_block(m.group(2)) + m.group(3),
        content,
        count=1,
        flags=re.DOTALL,
    )
else:
    content = rewrite_url_in_block(content)

with open(rb_path, "w", encoding="utf-8") as f:
    f.write(content)
PY

if [[ -n "$GITHUB_ENV" ]]; then
  echo "RELEASE_TAG=${RELEASE_TAG}" >> "$GITHUB_ENV"
  echo "RELEASE_TITLE=${RELEASE_TITLE}" >> "$GITHUB_ENV"
  echo "CASK_FILE=${ASSET_FILENAME}" >> "$GITHUB_ENV"
  echo "CASK_VERSION=${VERSION}" >> "$GITHUB_ENV"
fi

if [[ -n "$GITHUB_OUTPUT" ]]; then
  echo "cask_file=${ASSET_FILENAME}" >> "$GITHUB_OUTPUT"
  echo "release_tag=${RELEASE_TAG}" >> "$GITHUB_OUTPUT"
  echo "release_title=${RELEASE_TITLE}" >> "$GITHUB_OUTPUT"
  echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
else
  echo "cask_file=${ASSET_FILENAME}"
  echo "release_tag=${RELEASE_TAG}"
  echo "release_title=${RELEASE_TITLE}"
  echo "version=${VERSION}"
fi
