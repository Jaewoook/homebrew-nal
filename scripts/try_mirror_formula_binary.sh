#!/usr/bin/env bash
# ==============================================================================
# try_mirror_formula_binary.sh - Fast-path x86_64 binary mirroring for Formulas
#   Fast-Path A: Mirror existing upstream x86_64 / all bottle from GHCR
#   Fast-Path B: Repackage standalone GitHub Release darwin-x86_64 binary
#   Returns 0 if bottle was mirrored/packaged, 1 if caller should build from source
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/formula_helpers.sh
source "${SCRIPT_DIR}/formula_helpers.sh"

# Ensure execution under Rosetta 2 (x86_64) on Apple Silicon hosts
if [ "$(uname -m)" = "arm64" ]; then
  exec arch -x86_64 /bin/bash "$0" "$@"
fi

BREW_BIN="${INTEL_BREW_BIN:-/usr/local/bin/brew}"
FORMULA_NAME="${1:?Formula name required}"
if ! is_valid_formula_name "$FORMULA_NAME"; then
  echo "::error::Invalid formula name: $FORMULA_NAME" >&2
  exit 1
fi
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

if grep -Eq '^[[:space:]]*patch([[:space:]]+(:p[0-9]+[[:space:]]*,[[:space:]]*)?do\b|[[:space:]]+:DATA\b)' "$FORMULA_FILE" || [ -d "Patches/${FORMULA_NAME}" ]; then
  echo "Formula $FORMULA_NAME has custom patches; requires source build."
  exit 1
fi

# 2. Resolve version & revision from Formula file (or argument)
META=$(extract_formula_meta "$FORMULA_FILE")
IFS='|' read -r BASE_VERSION REVISION _ <<< "$META"
REVISION=${REVISION:-0}

if [[ -n "$PKG_VERSION_ARG" ]]; then
  PKG_VERSION="$PKG_VERSION_ARG"
  if [[ -z "$BASE_VERSION" ]]; then
    BASE_VERSION="${PKG_VERSION_ARG%%_*}"
  fi
elif [[ -n "$BASE_VERSION" && "$REVISION" -gt 0 ]]; then
  PKG_VERSION="${BASE_VERSION}_${REVISION}"
else
  PKG_VERSION="$BASE_VERSION"
fi

if [[ -z "$BASE_VERSION" ]]; then
  echo "Could not determine version for $FORMULA_NAME." >&2
  exit 1
fi

RELEASE_TAG="${FORMULA_NAME}.${PKG_VERSION}"
ROOT_URL="https://github.com/Jaewoook/homebrew-nal/releases/download/${RELEASE_TAG}"

# ==============================================================================
# Fast-Path A: Upstream GHCR Bottle Mirroring (x86_64_* or all)
# ==============================================================================
API_URL="${UPSTREAM_API_BASE:-https://formulae.brew.sh/api}/formula/${FORMULA_NAME}.json"
API_JSON=$(curl -sSfL "$API_URL" 2>/dev/null || true)

HOST_BOTTLE_TAG=$("$BREW_BIN" ruby -e 'puts Utils::Bottles.tag.to_s rescue ""' 2>/dev/null || echo "")
if [[ -z "$HOST_BOTTLE_TAG" ]]; then
  MACOS_VER=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo "")
  case "$MACOS_VER" in
    16) HOST_BOTTLE_TAG="tahoe" ;;
    15) HOST_BOTTLE_TAG="sequoia" ;;
    14) HOST_BOTTLE_TAG="sonoma" ;;
    13) HOST_BOTTLE_TAG="ventura" ;;
    12) HOST_BOTTLE_TAG="monterey" ;;
    *) HOST_BOTTLE_TAG="sequoia" ;;
  esac
fi

if [[ -n "$API_JSON" ]]; then
  FAST_A_INFO=$(python3 - "$BASE_VERSION" "$REVISION" "$HOST_BOTTLE_TAG" <<'PY' "$API_JSON"
import json, sys

base_ver = sys.argv[1]
rev = int(sys.argv[2])
host_tag = sys.argv[3].lower()
raw = sys.argv[4]

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

# Build priority list: host OS tag first, then older backward-compatible macOS versions,
# then universal 'all'. Exclude newer macOS generations so e.g. sequoia falls back to
# source build instead of mirroring an incompatible tahoe bottle.
macos_generations = ["monterey", "ventura", "sonoma", "sequoia", "tahoe"]

# Find index of host tag (fallback to sequoia if unknown)
clean_host = host_tag.replace("x86_64_", "")
host_idx = macos_generations.index(clean_host) if clean_host in macos_generations else 3

older_generations = list(reversed(macos_generations[:host_idx]))

priority = [f"x86_64_{clean_host}", clean_host]
for g in older_generations:
    priority.extend([f"x86_64_{g}", g])
priority.append("all")

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
    if (( BOTTLE_REBUILD > 0 )); then
      BOTTLE_FILENAME="${FORMULA_NAME}-${PKG_VERSION}.${BOTTLE_TAG}.bottle.${BOTTLE_REBUILD}.tar.gz"
    else
      BOTTLE_FILENAME="${FORMULA_NAME}-${PKG_VERSION}.${BOTTLE_TAG}.bottle.tar.gz"
    fi

    DOWNLOAD_OK="false"
    if [[ "$BOTTLE_URL" == https://ghcr.io/* ]]; then
      GHCR_REPO_PATH=$(echo "$BOTTLE_URL" | sed -E 's|^https://ghcr\.io/v2/||; s|/blobs/sha256:.*$||')
      GHCR_TOKEN_BASE="${GHCR_TOKEN_BASE:-https://ghcr.io/token}"
      GHCR_TOKEN=$(curl -sSfL "${GHCR_TOKEN_BASE}?service=ghcr.io&scope=repository:${GHCR_REPO_PATH}:pull" | jq -r '.token // empty' || true)
      if [[ -n "$GHCR_TOKEN" ]] && curl -sSfL -H "Authorization: Bearer ${GHCR_TOKEN}" -o "$BOTTLE_FILENAME" "$BOTTLE_URL"; then
        DOWNLOAD_OK="true"
      fi
    else
      if curl -sSfL -o "$BOTTLE_FILENAME" "$BOTTLE_URL"; then
        DOWNLOAD_OK="true"
      fi
    fi

    if [[ "$DOWNLOAD_OK" == "true" ]]; then
      ACTUAL_SHA=$(calc_sha256 "$BOTTLE_FILENAME")
      if [[ "$ACTUAL_SHA" == "$BOTTLE_SHA" ]]; then
        python3 - "$FORMULA_FILE" "$ROOT_URL" "$BOTTLE_TAG" "$BOTTLE_SHA" "$BOTTLE_REBUILD" "$BOTTLE_CELLAR" <<'PY'
import re, sys

rb_path, root_url, tag, sha, rebuild_str, cellar = sys.argv[1:7]
rebuild = int(rebuild_str)

with open(rb_path, "r", encoding="utf-8") as f:
    content = f.read()

def build_block(indent):
    lines = [f"{indent}bottle do", f'{indent}  root_url "{root_url}"']
    if rebuild > 0:
        lines.append(f"{indent}  rebuild {rebuild}")
    if cellar in (":any", ":any_skip_relocation"):
        lines.append(f'{indent}  sha256 cellar: {cellar}, {tag}: "{sha}"')
    else:
        lines.append(f'{indent}  sha256 {tag}: "{sha}"')
    lines.append(f"{indent}end")
    return "\n".join(lines)

m_existing = re.search(r'^([ \t]*)bottle\s+do\b.*?^\1end\b', content, re.MULTILINE | re.DOTALL)
if m_existing:
    new_block = build_block(m_existing.group(1))
    content = re.sub(
        r'^([ \t]*)bottle\s+do\b.*?^\1end\b',
        lambda _m: new_block,
        content,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )
else:
    def strip_quotes_and_comments(s):
        out = []
        i = 0
        n = len(s)
        in_quote = None
        while i < n:
            ch = s[i]
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

    lines_raw = content.splitlines(keepends=True)
    in_class = False
    class_indent = ""
    body_indent = "  "
    block_depth = 0
    bracket_depth = 0
    insert_idx = None
    last_meta_end_idx = None

    section_re = re.compile(
        r'^(?:depends_on|uses_from_macos|keg_only|pour_bottle\?|link_overwrite|'
        r'conflicts_with|deprecated!|disable!|deny_network_access!|'
        r'on_macos|on_linux|on_intel|on_arm|on_system|'
        r'resource|patch|service|caveats|def|test)\b'
    )
    meta_end_re = re.compile(
        r'^(?:desc|homepage|url|mirror|sha256|version|revision|compatibility_version|'
        r'version_scheme|license|head|livecheck|stable|option|no_autobump!)\b'
    )

    for idx, raw_line in enumerate(lines_raw):
        stripped = raw_line.strip()
        if not in_class:
            m_cls = re.match(r'^([ \t]*)class\s+\S+\s*<\s*Formula\b', raw_line)
            if m_cls:
                in_class = True
                class_indent = m_cls.group(1)
            continue

        if stripped == "" or stripped.startswith("#"):
            continue

        if bracket_depth == 0 and block_depth == 0:
            m_ind = re.match(r'^([ \t]*)', raw_line)
            cur_ind = m_ind.group(1) if m_ind else ""
            if len(cur_ind) > len(class_indent) and body_indent == "  ":
                body_indent = cur_ind
            if cur_ind == class_indent and re.match(r'^end\b', stripped):
                insert_idx = idx
                break
            if section_re.match(stripped):
                insert_idx = idx
                break

        cleaned = strip_quotes_and_comments(raw_line)
        open_b = cleaned.count("[") + cleaned.count("{") + cleaned.count("(")
        close_b = cleaned.count("]") + cleaned.count("}") + cleaned.count(")")
        opens = len(re.findall(r'(?:^|[\s;])do(?:\s*\|[^|]*\|)?\s*$', cleaned))
        if re.match(r'^\s*(?:def|if|unless|case|begin|while|for)\b', cleaned):
            opens += 1
        closes = len(re.findall(r'(?<![:.@])\bend\b', cleaned))

        was_open = (bracket_depth > 0 or block_depth > 0)
        bracket_depth = max(0, bracket_depth + open_b - close_b)
        block_depth = max(0, block_depth + opens - closes)
        if bracket_depth == 0 and block_depth == 0 and (meta_end_re.match(stripped) or was_open):
            last_meta_end_idx = idx + 1

    new_block = build_block(body_indent)
    if insert_idx is None:
        insert_idx = last_meta_end_idx if last_meta_end_idx is not None else len(lines_raw)
    prefix_blank = "\n" if insert_idx > 0 and lines_raw[insert_idx - 1].strip() != "" else ""
    suffix_blank = (
        "\n"
        if insert_idx < len(lines_raw)
        and lines_raw[insert_idx].strip() != ""
        and not lines_raw[insert_idx].lstrip().startswith("end")
        else ""
    )
    lines_raw.insert(insert_idx, f"{prefix_blank}{new_block}\n{suffix_blank}")
    content = "".join(lines_raw)

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

# ==============================================================================
# Fast-Path B: Standalone GitHub Release Binary Repackaging
# ==============================================================================
# Disqualify Fast-Path B if the formula declares any macOS runtime formula dependencies
if [[ -n "$(extract_formula_deps "$FORMULA_FILE")" ]]; then
  exit 1
fi

GH_INFO=$(python3 - "$FORMULA_FILE" "$BASE_VERSION" <<'PY'
import re, sys

rb_path, base_ver = sys.argv[1], sys.argv[2]
with open(rb_path, "r", encoding="utf-8") as f:
    content = f.read()

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
CELLAR_DIR=""
BOTTLE_PACKAGED="false"
cleanup_fast_b() {
  [ -n "${WORK_TMP:-}" ] && rm -rf "$WORK_TMP"
  if [ "${BOTTLE_PACKAGED:-false}" != "true" ] && [ -n "${CELLAR_DIR:-}" ]; then
    rm -rf "$CELLAR_DIR"
  fi
}
trap cleanup_fast_b EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

# Validate clean single/standalone binary archive layout before packaging:
# reject shared libraries (.dylib/.so), runtime subdirectories (lib/libexec/share),
# scripts/non-doc extras, and colliding binary basenames.
MACHO_BINS=()
SEEN_BIN_NAMES=()
while IFS= read -r -d '' f; do
  rel="${f#"$WORK_TMP/extracted/"}"
  base="$(basename "$f")"
  low_base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  low_rel="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')"
  ftype="$(file "$f" 2>/dev/null || true)"

  case "$low_base" in
    *.dylib|*.so|*.so.*)
      echo "Archive $ASSET_NAME contains shared library $rel; falling back to source build." >&2
      exit 1
      ;;
  esac
  if printf '%s' "$ftype" | grep -q "Mach-O.*dynamically linked shared library"; then
    echo "Archive $ASSET_NAME contains Mach-O shared library $rel; falling back to source build." >&2
    exit 1
  fi
  if printf '%s' "$low_rel" | grep -Eq '(^|/)(lib|libexec|share|include|etc)/'; then
    echo "Archive $ASSET_NAME contains non-binary runtime directory ($rel); falling back to source build." >&2
    exit 1
  fi

  if printf '%s' "$ftype" | grep -q "Mach-O.*executable"; then
    if lipo -archs "$f" 2>/dev/null | grep -qw "x86_64"; then
      for prev_name in ${SEEN_BIN_NAMES[@]+"${SEEN_BIN_NAMES[@]}"}; do
        if [ "$prev_name" = "$base" ]; then
          echo "Archive $ASSET_NAME contains duplicate binary basename '$base'; falling back to source build." >&2
          exit 1
        fi
      done
      SEEN_BIN_NAMES+=("$base")
      MACHO_BINS+=("$f")
    fi
  else
    case "$low_base" in
      license*|licence*|readme*|copying*|notice*|authors*|changelog*|*.md|*.txt|*.[1-8]|.ds_store)
        ;;
      *)
        echo "Archive $ASSET_NAME contains extra non-doc file ($rel); falling back to source build." >&2
        exit 1
        ;;
    esac
  fi
done < <(find "$WORK_TMP/extracted" -type f -print0)

if [[ ${#MACHO_BINS[@]} -ne 1 ]]; then
  echo "Archive $ASSET_NAME does not contain a single standalone Mach-O x86_64 executable (found ${#MACHO_BINS[@]}); falling back to source build." >&2
  exit 1
fi

CELLAR_BASE="${HOMEBREW_CELLAR:-}"
if [[ -z "$CELLAR_BASE" ]]; then
  CELLAR_BASE=$("$BREW_BIN" --cellar 2>/dev/null || echo "/usr/local/Cellar")
fi
CELLAR_DIR="${CELLAR_BASE}/${FORMULA_NAME}/${PKG_VERSION}"
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
if "$BREW_BIN" ruby -e '
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
  "$BREW_BIN" bottle --force-core-tap --root-url="$ROOT_URL" --json "jaewoook/nal/${FORMULA_NAME}"; then

  if merge_and_normalize_bottle "$BREW_BIN" "$FORMULA_NAME"; then
    BOTTLE_PACKAGED="true"
    echo "Successfully packaged prebuilt binary into bottle for $FORMULA_NAME"
    exit 0
  fi
fi

exit 1
exit 1
