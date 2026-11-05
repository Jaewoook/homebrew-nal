#!/usr/bin/env bash
# ==============================================================================
# try_mirror_formula_binary.sh - Fast-path x86_64 binary mirroring for Formulas
#   Fast-Path A: Mirror existing upstream x86_64 / all bottle from GHCR
#   Fast-Path B: Repackage standalone GitHub Release darwin-x86_64 binary
#   Returns 0 if bottle was mirrored/packaged, 1 if caller should build from source
# ==============================================================================
set -euo pipefail

FORMULA_NAME="${1:?Formula name required}"
DRY_RUN="false"
PKG_VERSION_ARG=""

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    *)
      PKG_VERSION_ARG="$1"
      shift
      ;;
  esac
done

FORMULA_FILE="Formula/${FORMULA_NAME}.rb"
if [[ ! -f "$FORMULA_FILE" ]]; then
  echo "Formula file $FORMULA_FILE not found." >&2
  exit 1
fi

# 1. Eligibility check: skip fast-path if formula has custom tap runtime dependencies or local patches
if grep -Eq '^[[:space:]]*depends_on[[:space:]]+"jaewoook/nal/' "$FORMULA_FILE"; then
  echo "Formula $FORMULA_NAME depends on custom jaewoook/nal formula(s); requires source build."
  exit 1
fi

if grep -Eq '^[[:space:]]*patch[[:space:]]+do' "$FORMULA_FILE" || [ -d "Patches/${FORMULA_NAME}" ]; then
  echo "Formula $FORMULA_NAME has custom patches; requires source build."
  exit 1
fi

# 2. Resolve version & revision from Formula file (or argument)
read -r BASE_VERSION REVISION PKG_VERSION < <(python3 - "$FORMULA_FILE" "$PKG_VERSION_ARG" <<'PY'
import re, sys

rb_path = sys.argv[1]
pkg_arg = sys.argv[2]

with open(rb_path, "r", encoding="utf-8") as f:
    content = f.read()

ver_match = re.search(r'^\s*version\s+"([^"]+)"', content, re.MULTILINE)
rev_match = re.search(r'^\s*revision\s+(\d+)', content, re.MULTILINE)
rev = int(rev_match.group(1)) if rev_match else 0

if ver_match:
    base_ver = ver_match.group(1)
else:
    url_match = re.search(r'^\s*url\s+"([^"]+)"', content, re.MULTILINE)
    base_ver = ""
    if url_match:
        url = url_match.group(1)
        m = re.search(r'(?:v|-)(\d+(?:\.\d+)+[a-zA-Z0-9._-]*?)(?:\.tar\.[a-z0-9]+|\.tgz|\.zip)$', url)
        if m:
            base_ver = m.group(1)

if pkg_arg:
    pkg_ver = pkg_arg
    if not base_ver:
        base_ver = pkg_arg.split("_")[0]
else:
    pkg_ver = f"{base_ver}_{rev}" if (base_ver and rev > 0) else base_ver

print(f"{base_ver} {rev} {pkg_ver}")
PY
)

if [[ -z "$BASE_VERSION" ]]; then
  echo "Could not determine version for $FORMULA_NAME." >&2
  exit 1
fi

RELEASE_TAG="${FORMULA_NAME}.${PKG_VERSION}"
ROOT_URL="https://github.com/Jaewoook/homebrew-nal/releases/download/${RELEASE_TAG}"

# ==============================================================================
# Fast-Path A: Upstream GHCR Bottle Mirroring (x86_64_* or all)
# ==============================================================================
API_URL="https://formulae.brew.sh/api/formula/${FORMULA_NAME}.json"
API_JSON=$(curl -sSfL "$API_URL" 2>/dev/null || true)

if [[ -n "$API_JSON" ]]; then
  FAST_A_INFO=$(python3 - "$BASE_VERSION" "$REVISION" <<'PY' "$API_JSON"
import json, sys

base_ver = sys.argv[1]
rev = int(sys.argv[2])
raw = sys.argv[3]

try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

up_ver = (data.get("versions") or {}).get("stable") or ""
up_rev = int(data.get("revision") or 0)

if up_ver != base_ver or up_rev != rev:
    sys.exit(0)

bottle_stable = (data.get("bottle") or {}).get("stable") or {}
files = bottle_stable.get("files") or {}
rebuild = int(bottle_stable.get("rebuild") or 0)

# Priority order of Intel / Universal bottle tags
priority = [
    "x86_64_tahoe", "tahoe",
    "x86_64_sequoia", "sequoia",
    "x86_64_sonoma", "sonoma",
    "x86_64_ventura", "ventura",
    "x86_64_monterey", "monterey",
    "all",
]

for tag in priority:
    if tag in files:
        entry = files[tag]
        url = entry.get("url") or ""
        sha = entry.get("sha256") or ""
        cellar = entry.get("cellar") or bottle_stable.get("cellar") or ":any_skip_relocation"
        if url and sha:
            print(f"{tag}|{url}|{sha}|{rebuild}|{cellar}")
            sys.exit(0)
PY
)

  if [[ -n "$FAST_A_INFO" ]]; then
    IFS='|' read -r BOTTLE_TAG BOTTLE_URL BOTTLE_SHA BOTTLE_REBUILD BOTTLE_CELLAR <<< "$FAST_A_INFO"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "FAST_PATH_A:${BOTTLE_TAG}:${BOTTLE_URL}"
      exit 0
    fi

    echo "Fast-Path A: Found upstream x86_64/all bottle (${BOTTLE_TAG}) for ${FORMULA_NAME} ${PKG_VERSION}"
    GHCR_REPO_PATH=$(echo "$BOTTLE_URL" | sed -E 's|^https://ghcr\.io/v2/||; s|/blobs/sha256:.*$||')
    GHCR_TOKEN=$(curl -sSfL "https://ghcr.io/token?service=ghcr.io&scope=repository:${GHCR_REPO_PATH}:pull" | jq -r '.token // empty' || true)

    if [[ -n "$GHCR_TOKEN" ]]; then
      if (( BOTTLE_REBUILD > 0 )); then
        BOTTLE_FILENAME="${FORMULA_NAME}-${PKG_VERSION}.${BOTTLE_TAG}.bottle.${BOTTLE_REBUILD}.tar.gz"
      else
        BOTTLE_FILENAME="${FORMULA_NAME}-${PKG_VERSION}.${BOTTLE_TAG}.bottle.tar.gz"
      fi

      if curl -sSfL -H "Authorization: Bearer ${GHCR_TOKEN}" -o "$BOTTLE_FILENAME" "$BOTTLE_URL"; then
        ACTUAL_SHA=$(shasum -a 256 "$BOTTLE_FILENAME" | awk '{print $1}')
        if [[ "$ACTUAL_SHA" == "$BOTTLE_SHA" ]]; then
          python3 - "$FORMULA_FILE" "$ROOT_URL" "$BOTTLE_TAG" "$BOTTLE_SHA" "$BOTTLE_REBUILD" "$BOTTLE_CELLAR" <<'PY'
import re, sys

rb_path, root_url, tag, sha, rebuild_str, cellar = sys.argv[1:7]
rebuild = int(rebuild_str)

with open(rb_path, "r", encoding="utf-8") as f:
    content = f.read()

lines = ['  bottle do', f'    root_url "{root_url}"']
if rebuild > 0:
    lines.append(f'    rebuild {rebuild}')
if cellar in (":any", ":any_skip_relocation"):
    lines.append(f'    sha256 cellar: {cellar}, {tag}: "{sha}"')
else:
    lines.append(f'    sha256 {tag}: "{sha}"')
lines.append('  end')
new_block = "\n".join(lines)

if re.search(r'^\s*bottle\s+do\b.*?^\s*end\b', content, re.MULTILINE | re.DOTALL):
    content = re.sub(r'^\s*bottle\s+do\b.*?^\s*end\b', new_block, content, count=1, flags=re.MULTILINE | re.DOTALL)
elif re.search(r'^\s*license\s+[^\n]+\n', content, re.MULTILINE):
    content = re.sub(r'(^\s*license\s+[^\n]+\n)', r'\1\n' + new_block + '\n', content, count=1, flags=re.MULTILINE)
elif re.search(r'^\s*sha256\s+[^\n]+\n', content, re.MULTILINE):
    content = re.sub(r'(^\s*sha256\s+[^\n]+\n)', r'\1\n' + new_block + '\n', content, count=1, flags=re.MULTILINE)
else:
    content = re.sub(r'(^\s*url\s+[^\n]+\n)', r'\1\n' + new_block + '\n', content, count=1, flags=re.MULTILINE)

with open(rb_path, "w", encoding="utf-8") as f:
    f.write(content)
PY
          echo "Successfully mirrored GHCR bottle to $BOTTLE_FILENAME and updated $FORMULA_FILE"
          exit 0
        else
          echo "Warning: SHA256 mismatch for downloaded GHCR bottle ($ACTUAL_SHA != $BOTTLE_SHA)" >&2
          rm -f "$BOTTLE_FILENAME"
        fi
      fi
    fi
  fi
fi

# ==============================================================================
# Fast-Path B: Standalone GitHub Release Binary Repackaging
# ==============================================================================
GH_INFO=$(python3 - "$FORMULA_FILE" "$BASE_VERSION" <<'PY'
import re, sys

rb_path, base_ver = sys.argv[1], sys.argv[2]
with open(rb_path, "r", encoding="utf-8") as f:
    content = f.read()

# Check runtime dependencies: any depends_on without :build or :test or :macos/:xcode disqualifies Fast-Path B
for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith("#") or not stripped.startswith("depends_on"):
        continue
    if "=> :build" in stripped or "=> :test" in stripped or "depends_on :macos" in stripped or "depends_on :xcode" in stripped:
        continue
    # Found a runtime dependency
    sys.exit(0)

url_match = re.search(r'^\s*url\s+"https://github\.com/([^/]+/[^/]+)/([^"]+)"', content, re.MULTILINE)
if not url_match:
    sys.exit(0)

repo = url_match.group(1).removesuffix(".git")
rest = url_match.group(2)
tag_match = re.search(r'(?:tags/|download/|archive/)(v?\d+[^/]*?)(?:\.tar\.gz|\.tgz|\.zip|/)', rest)
tag = tag_match.group(1) if tag_match else f"v{base_ver}"
print(f"{repo}|{tag}")
PY
)

if [[ -z "$GH_INFO" ]]; then
  exit 1
fi

IFS='|' read -r GH_REPO GH_TAG <<< "$GH_INFO"

if ! command -v gh >/dev/null 2>&1; then
  exit 1
fi

RELEASE_JSON=$(gh release view "$GH_TAG" --repo "$GH_REPO" --json tagName,assets 2>/dev/null || gh release view "v${BASE_VERSION}" --repo "$GH_REPO" --json tagName,assets 2>/dev/null || gh release view "${BASE_VERSION}" --repo "$GH_REPO" --json tagName,assets 2>/dev/null || true)

if [[ -z "$RELEASE_JSON" ]]; then
  exit 1
fi

ASSET_INFO=$(python3 - <<'PY' "$RELEASE_JSON"
import json, re, sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

tag = data.get("tagName") or ""
assets = data.get("assets") or []

for asset in assets:
    name = asset.get("name") or ""
    url = asset.get("url") or ""
    low = name.lower()
    if low.endswith((".sha256", ".sig", ".asc", ".sbom", ".txt", ".deb", ".rpm", ".msi", ".apk")):
        continue
    if not low.endswith((".tar.gz", ".tgz", ".tar.xz", ".zip")):
        continue
    # Exclude non-macOS and arm64-only archives unless explicitly universal
    if re.search(r'(?:^|[_.-])(linux|windows|win32|win64|freebsd|openbsd|netbsd|android|armv6|armv7|i386|386|ppc64|s390x)(?:[_.-]|$)', low):
        continue
    if re.search(r'(?:^|[_.-])(arm64|aarch64)(?:[_.-]|$)', low) and not re.search(r'(?:^|[_.-])(universal|all)(?:[_.-]|$)', low):
        continue
    is_mac = bool(re.search(r'(?:^|[_.-])(darwin|macos|osx|mac|apple)(?:[_.-]|$)', low))
    is_x86 = bool(re.search(r'(?:^|[_.-])(x86_64|amd64|x64|universal|all)(?:[_.-]|$)', low))
    if is_mac and is_x86:
        print(f"{tag}|{name}|{url}")
        sys.exit(0)
PY
)

if [[ -z "$ASSET_INFO" ]]; then
  exit 1
fi

IFS='|' read -r RESOLVED_TAG ASSET_NAME ASSET_URL <<< "$ASSET_INFO"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "FAST_PATH_B:${GH_REPO}:${RESOLVED_TAG}:${ASSET_NAME}"
  exit 0
fi

echo "Fast-Path B: Found prebuilt GitHub release asset ${ASSET_NAME} from ${GH_REPO}@${RESOLVED_TAG}"
WORK_TMP=$(mktemp -d)
trap 'rm -rf "$WORK_TMP"' EXIT

if ! curl -sSfL -o "$WORK_TMP/$ASSET_NAME" "$ASSET_URL"; then
  echo "Warning: Failed to download $ASSET_URL" >&2
  exit 1
fi

mkdir -p "$WORK_TMP/extracted"
case "$ASSET_NAME" in
  *.zip)
    unzip -q "$WORK_TMP/$ASSET_NAME" -d "$WORK_TMP/extracted"
    ;;
  *.tar.gz|*.tgz|*.tar.xz)
    tar -xf "$WORK_TMP/$ASSET_NAME" -C "$WORK_TMP/extracted"
    ;;
  *)
    exit 1
    ;;
esac

# Find Mach-O x86_64 executable(s)
MACHO_BINS=()
while IFS= read -r -d '' f; do
  if file "$f" | grep -q "Mach-O.*executable"; then
    if lipo -archs "$f" 2>/dev/null | grep -qw "x86_64"; then
      MACHO_BINS+=("$f")
    fi
  fi
done < <(find "$WORK_TMP/extracted" -type f -print0)

if [[ ${#MACHO_BINS[@]} -eq 0 ]]; then
  echo "Warning: No Mach-O x86_64 executable found in $ASSET_NAME; falling back to source build." >&2
  exit 1
fi

CELLAR_DIR="/usr/local/Cellar/${FORMULA_NAME}/${PKG_VERSION}"
rm -rf "$CELLAR_DIR"
mkdir -p "$CELLAR_DIR/bin"

for bin_path in "${MACHO_BINS[@]}"; do
  cp "$bin_path" "$CELLAR_DIR/bin/"
  chmod 0755 "$CELLAR_DIR/bin/$(basename "$bin_path")"
done

# Copy top-level documentation/license files if present
while IFS= read -r -d '' doc_path; do
  cp "$doc_path" "$CELLAR_DIR/" || true
done < <(find "$WORK_TMP/extracted" -maxdepth 2 -type f \( -iname "LICENSE*" -o -iname "README*" -o -iname "COPYING*" \) -print0)

# Generate Homebrew Tab receipt and bottle it
if /usr/local/bin/brew ruby -e '
  f = Formula["jaewoook/nal/#{ARGV[0]}"]
  tab = Tab.empty
  tab.homebrew_version = HOMEBREW_VERSION
  tab.tabfile = f.prefix/AbstractTab::FILENAME
  tab.built_as_bottle = true
  tab.installed_as_dependency = false
  tab.installed_on_request = true
  tab.time = Time.now.to_i
  tab.source["tap"] = "jaewoook/nal"
  tab.source["path"] = f.path.to_s
  tab.source["versions"] = { "stable" => f.stable.version.to_s, "version_scheme" => f.version_scheme }
  tab.write
' -- "$FORMULA_NAME" && \
  /usr/local/bin/brew bottle --force-core-tap --root-url="$ROOT_URL" --json "jaewoook/nal/${FORMULA_NAME}"; then

  shopt -s nullglob
  BOTTLE_JSON_FILES=("${FORMULA_NAME}"--*.bottle.json)
  BOTTLE_JSON="${BOTTLE_JSON_FILES[0]:-}"
  if [[ -n "$BOTTLE_JSON" && -f "$BOTTLE_JSON" ]]; then
    /usr/local/bin/brew bottle --merge --write --no-commit "$BOTTLE_JSON"
    for f in "${FORMULA_NAME}"--*.tar.gz; do
      [ -f "$f" ] || continue
      TARGET_NAME="${f/--/-}"
      mv -- "$f" "$TARGET_NAME"
    done
    echo "Successfully packaged prebuilt binary into bottle for $FORMULA_NAME"
    exit 0
  fi
fi

rm -rf "$CELLAR_DIR"
exit 1
