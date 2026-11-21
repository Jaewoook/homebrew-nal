#!/usr/bin/env bash
set -euo pipefail
export SKIP_HOST_RESTORE=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR_HELPER="${SCRIPT_DIR}/scripts/try_mirror_formula_binary.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Formula" "$TMP_DIR/mock_bin"

# 1. Formula with custom tap dependency should return non-zero (fallback to source build)
cat <<'EOF' > "$TMP_DIR/Formula/custom_dep_app.rb"
class CustomDepApp < Formula
  desc "Has custom tap dep"
  url "https://example.com/app-1.0.0.tar.gz"
  depends_on "jaewoook/nal/openssl@3"
end
EOF

if (cd "$TMP_DIR" && bash "$MIRROR_HELPER" custom_dep_app --dry-run); then
  echo "Assertion failed: formula with jaewoook/nal dependency should not use binary fast-path"
  exit 1
fi

cat <<'EOF' > "$TMP_DIR/mock_bin/intel_brew"
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --cellar)
    echo "${MOCK_CELLAR_DIR:-$TMP_DIR/Cellar}"
    ;;
  ruby)
    code="${3:-${2:-}}"
    if [[ "$code" == *"Utils::Bottles.tag"* ]]; then
      echo "${MOCK_HOST_TAG:-sequoia}"
    elif [[ "$code" == *"Tab.empty"* ]]; then
      :
    fi
    ;;
  bottle)
    if [[ " $* " == *" --merge "* ]]; then
      exit 0
    fi
    formula="${@: -1}"
    formula="${formula##*/}"
    ver="${MOCK_PKG_VER:-1.0.0}"
    touch "${formula}--${ver}.sequoia.bottle.json" "${formula}--${ver}.sequoia.bottle.tar.gz"
    ;;
esac
EOF
chmod +x "$TMP_DIR/mock_bin/intel_brew"
export INTEL_BREW_BIN="$TMP_DIR/mock_bin/intel_brew"
export MOCK_CELLAR_DIR="$TMP_DIR/Cellar"

# 1b. Invalid formula name must fail cleanly
if (cd "$TMP_DIR" && bash "$MIRROR_HELPER" "../evil" --dry-run 2>/dev/null); then
  echo "Assertion failed: invalid formula name should be rejected"
  exit 1
fi

# 2. Formula with upstream x86_64 bottle in formulae.brew.sh API (Fast-Path A dry-run check)
cat <<'EOF' > "$TMP_DIR/Formula/jq_demo.rb"
class JqDemo < Formula
  desc "Lightweight and flexible command-line JSON processor"
  url "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1.tar.gz"
  version "1.7.1"
end
EOF

cat <<'EOF' > "$TMP_DIR/mock_bin/curl"
#!/usr/bin/env bash
URL="${!#}"
if [[ "$URL" == *"formulae.brew.sh/api/formula/jq_demo.json"* ]]; then
  cat <<'JSON'
{
  "name": "jq_demo",
  "versions": { "stable": "1.7.1" },
  "revision": 0,
  "bottle": {
    "stable": {
      "rebuild": 0,
      "files": {
        "sonoma": {
          "url": "https://ghcr.io/v2/homebrew/core/jq_demo/blobs/sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
          "sha256": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        }
      }
    }
  }
}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$TMP_DIR/mock_bin/curl"

OUT_A=$(cd "$TMP_DIR" && PATH="$TMP_DIR/mock_bin:$PATH" bash "$MIRROR_HELPER" jq_demo --dry-run)
if ! echo "$OUT_A" | grep -q "FAST_PATH_A:sonoma:https://ghcr.io/v2/homebrew/core/jq_demo/blobs/sha256:1234567890abcdef"; then
  echo "Assertion failed: expected FAST_PATH_A detection, got: $OUT_A"
  exit 1
fi

# 2b. Test host OS prioritization: when both tahoe and sequoia exist, sequoia must be preferred on sequoia host
cat <<'EOF' > "$TMP_DIR/Formula/multi_os.rb"
class MultiOs < Formula
  desc "Multi OS formula"
  url "https://example.com/multi-os-1.0.0.tar.gz"
  version "1.0.0"
end
EOF

cat <<'EOF' > "$TMP_DIR/mock_bin/curl"
#!/usr/bin/env bash
URL="${!#}"
if [[ "$URL" == *"formulae.brew.sh/api/formula/multi_os.json"* ]]; then
  cat <<'JSON'
{
  "name": "multi_os",
  "versions": { "stable": "1.0.0" },
  "revision": 0,
  "bottle": {
    "stable": {
      "rebuild": 0,
      "files": {
        "tahoe": {
          "url": "https://ghcr.io/v2/homebrew/core/multi_os/blobs/sha256:tahoeblob",
          "sha256": "tahoeblob"
        },
        "sequoia": {
          "url": "https://ghcr.io/v2/homebrew/core/multi_os/blobs/sha256:sequoiablob",
          "sha256": "sequoiablob"
        }
      }
    }
  }
}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$TMP_DIR/mock_bin/curl"

OUT_MULTI=$(cd "$TMP_DIR" && PATH="$TMP_DIR/mock_bin:$PATH" MOCK_HOST_TAG="sequoia" bash "$MIRROR_HELPER" multi_os --dry-run)
if ! echo "$OUT_MULTI" | grep -q "FAST_PATH_A:sequoia:"; then
  echo "Assertion failed: expected sequoia tag priority over tahoe, got: $OUT_MULTI"
  exit 1
fi

# 2c. Newer-only upstream bottle (tahoe only on sequoia host) must fall back (exit 1)
cat <<'EOF' > "$TMP_DIR/Formula/tahoe_only.rb"
class TahoeOnly < Formula
  desc "Tahoe only formula"
  url "https://example.com/tahoe-1.0.0.tar.gz"
  version "1.0.0"
end
EOF
mkdir -p "$TMP_DIR/api_mock/formula"
cat <<'JSON' > "$TMP_DIR/api_mock/formula/tahoe_only.json"
{
  "name": "tahoe_only",
  "versions": { "stable": "1.0.0" },
  "revision": 0,
  "bottle": {
    "stable": {
      "rebuild": 0,
      "files": {
        "tahoe": {
          "url": "file:///nonexistent/tahoe.tar.gz",
          "sha256": "deadbeef"
        }
      }
    }
  }
}
JSON
if (cd "$TMP_DIR" && MOCK_HOST_TAG="sequoia" UPSTREAM_API_BASE="file://$TMP_DIR/api_mock" bash "$MIRROR_HELPER" tahoe_only --dry-run); then
  echo "Assertion failed: tahoe-only bottle must NOT be selected on sequoia host"
  exit 1
fi

# 3. Standalone GitHub formula without x86_64 GHCR bottle (Fast-Path B dry-run check)
# Also verify array build/test tags ([:build, :test]) and on_linux runtime deps do not disqualify Fast-Path B
cat <<'EOF' > "$TMP_DIR/Formula/gitleaks.rb"
class Gitleaks < Formula
  desc "Audit git repos for secrets"
  homepage "https://github.com/gitleaks/gitleaks"
  url "https://github.com/gitleaks/gitleaks/archive/refs/tags/v8.24.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  depends_on "go" => [:build, :test]

  on_linux do
    depends_on "zlib-ng-compat"
  end
end
EOF

cat <<'EOF' > "$TMP_DIR/mock_bin/curl"
#!/usr/bin/env bash
URL="${!#}"
if [[ "$URL" == *"formulae.brew.sh/api/formula/gitleaks.json"* ]]; then
  cat <<'JSON'
{
  "name": "gitleaks",
  "versions": { "stable": "8.24.0" },
  "revision": 0,
  "bottle": {
    "stable": {
      "files": {
        "arm64_sequoia": {
          "url": "https://ghcr.io/v2/homebrew/core/gitleaks/blobs/sha256:aaaa",
          "sha256": "aaaa"
        }
      }
    }
  }
}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$TMP_DIR/mock_bin/curl"

cat <<'EOF' > "$TMP_DIR/mock_bin/gh"
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  cat <<'JSON'
{
  "tagName": "v8.24.0",
  "assets": [
    {
      "name": "gitleaks_8.24.0_darwin_arm64.tar.gz",
      "url": "https://github.com/gitleaks/gitleaks/releases/download/v8.24.0/gitleaks_8.24.0_darwin_arm64.tar.gz"
    },
    {
      "name": "gitleaks_8.24.0_darwin_x64.tar.gz",
      "url": "https://github.com/gitleaks/gitleaks/releases/download/v8.24.0/gitleaks_8.24.0_darwin_x64.tar.gz"
    }
  ]
}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$TMP_DIR/mock_bin/gh"

OUT_B=$(cd "$TMP_DIR" && PATH="$TMP_DIR/mock_bin:$PATH" bash "$MIRROR_HELPER" gitleaks --dry-run)
if ! echo "$OUT_B" | grep -q "FAST_PATH_B:gitleaks/gitleaks:v8.24.0:gitleaks_8.24.0_darwin_x64.tar.gz"; then
  echo "Assertion failed: expected FAST_PATH_B detection, got: $OUT_B"
  exit 1
fi

# 4. Formula with "all" in its name (smallstep) must NOT match darwin_arm64 asset
cat <<'EOF' > "$TMP_DIR/Formula/smallstep.rb"
class Smallstep < Formula
  desc "Smallstep CLI"
  homepage "https://github.com/smallstep/cli"
  url "https://github.com/smallstep/cli/archive/refs/tags/v0.27.2.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  depends_on "go" => :build
end
EOF

cat <<'EOF' > "$TMP_DIR/mock_bin/gh"
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  cat <<'JSON'
{
  "tagName": "v0.27.2",
  "assets": [
    {
      "name": "smallstep_darwin_arm64.tar.gz",
      "url": "https://github.com/smallstep/cli/releases/download/v0.27.2/smallstep_darwin_arm64.tar.gz"
    },
    {
      "name": "smallstep_darwin_amd64.tar.gz",
      "url": "https://github.com/smallstep/cli/releases/download/v0.27.2/smallstep_darwin_amd64.tar.gz"
    }
  ]
}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$TMP_DIR/mock_bin/gh"

OUT_SMALLSTEP=$(cd "$TMP_DIR" && PATH="$TMP_DIR/mock_bin:$PATH" bash "$MIRROR_HELPER" smallstep --dry-run)
if ! echo "$OUT_SMALLSTEP" | grep -q "FAST_PATH_B:smallstep/cli:v0.27.2:smallstep_darwin_amd64.tar.gz"; then
  echo "Assertion failed: expected smallstep_darwin_amd64.tar.gz, got: $OUT_SMALLSTEP"
  exit 1
fi

# 5. Test Bash 3.2 (/bin/bash) bottle filename normalization does not insert literal quotes
NORM_DIR="$TMP_DIR/norm"
mkdir -p "$NORM_DIR"
touch "$NORM_DIR/glib--2.90.1.sequoia.bottle.2.tar.gz" "$NORM_DIR/foo--bar--1.0.sequoia.bottle.tar.gz"
(
  cd "$NORM_DIR"
  /bin/bash -euo pipefail -c '
    source "$1"
    normalize_bottle_archives glib
    normalize_bottle_archives foo--bar
  ' -- "${SCRIPT_DIR}/scripts/formula_helpers.sh"
)
if [ ! -f "$NORM_DIR/glib-2.90.1.sequoia.bottle.2.tar.gz" ]; then
  echo "Assertion failed: glib bottle filename normalization failed under /bin/bash"
  ls -la "$NORM_DIR"
  exit 1
fi
if [ ! -f "$NORM_DIR/foo--bar-1.0.sequoia.bottle.tar.gz" ]; then
  echo "Assertion failed: foo--bar bottle filename normalization failed under /bin/bash"
  ls -la "$NORM_DIR"
  exit 1
fi

# 6. Non-dry-run Fast-Path A: multi-line license and stable do block insertion must keep valid Ruby syntax
FP_A_DIR="$TMP_DIR/fp_a"
mkdir -p "$FP_A_DIR/Formula" "$FP_A_DIR/api/formula" "$FP_A_DIR/blobs"
echo "dummy bottle content" > "$FP_A_DIR/blobs/bottle.txt"
tar -czf "$FP_A_DIR/blobs/sample.tar.gz" -C "$FP_A_DIR/blobs" bottle.txt
SAMPLE_SHA=$(shasum -a 256 "$FP_A_DIR/blobs/sample.tar.gz" | awk '{print $1}')

cat <<'EOF' > "$FP_A_DIR/Formula/multiline_lic.rb"
class MultilineLic < Formula
  desc "Multi-line license formula"
  homepage "https://example.com"
  url "https://example.com/multiline-1.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  license all_of: [
    "GPL-2.0-or-later",
    "MIT",
  ]

  depends_on "pkgconf" => :build
end
EOF
cat <<JSON > "$FP_A_DIR/api/formula/multiline_lic.json"
{
  "name": "multiline_lic",
  "versions": { "stable": "1.0.0" },
  "revision": 0,
  "bottle": {
    "stable": {
      "rebuild": 0,
      "files": {
        "sequoia": {
          "url": "file://${FP_A_DIR}/blobs/sample.tar.gz",
          "sha256": "${SAMPLE_SHA}",
          "cellar": ":any_skip_relocation"
        }
      }
    }
  }
}
JSON

(
  cd "$FP_A_DIR"
  MOCK_HOST_TAG="sequoia" UPSTREAM_API_BASE="file://${FP_A_DIR}/api" \
    bash "$MIRROR_HELPER" multiline_lic "1.0.0"
)
if [ ! -f "$FP_A_DIR/multiline_lic-1.0.0.sequoia.bottle.tar.gz" ]; then
  echo "Assertion failed: Fast-Path A non-dry-run did not download bottle archive"
  exit 1
fi
if command -v ruby >/dev/null 2>&1 && ! ruby -c "$FP_A_DIR/Formula/multiline_lic.rb" >/dev/null; then
  echo "Assertion failed: multiline_lic.rb has invalid Ruby syntax after bottle do insertion"
  cat "$FP_A_DIR/Formula/multiline_lic.rb"
  exit 1
fi
python3 - "$FP_A_DIR/Formula/multiline_lic.rb" <<'PY'
import sys
txt = open(sys.argv[1]).read()
assert 'license all_of: [\n    "GPL-2.0-or-later",\n    "MIT",\n  ]' in txt, f"license block corrupted:\n{txt}"
assert txt.index("]") < txt.index("bottle do") < txt.index('depends_on "pkgconf"'), f"bottle do misplaced:\n{txt}"
PY

cat <<'EOF' > "$FP_A_DIR/Formula/stable_blk.rb"
class StableBlk < Formula
  desc "Stable block formula"
  homepage "https://example.com"

  stable do
    url "https://example.com/stableblk-2.0.0.tar.gz"
    sha256 "2222222222222222222222222222222222222222222222222222222222222222"
  end

  keg_only :provided_by_macos
end
EOF
cat <<JSON > "$FP_A_DIR/api/formula/stable_blk.json"
{
  "name": "stable_blk",
  "versions": { "stable": "2.0.0" },
  "revision": 0,
  "bottle": {
    "stable": {
      "rebuild": 0,
      "files": {
        "sequoia": {
          "url": "file://${FP_A_DIR}/blobs/sample.tar.gz",
          "sha256": "${SAMPLE_SHA}"
        }
      }
    }
  }
}
JSON
(
  cd "$FP_A_DIR"
  MOCK_HOST_TAG="sequoia" UPSTREAM_API_BASE="file://${FP_A_DIR}/api" \
    bash "$MIRROR_HELPER" stable_blk "2.0.0"
)
if command -v ruby >/dev/null 2>&1 && ! ruby -c "$FP_A_DIR/Formula/stable_blk.rb" >/dev/null; then
  echo "Assertion failed: stable_blk.rb has invalid Ruby syntax"
  cat "$FP_A_DIR/Formula/stable_blk.rb"
  exit 1
fi
python3 - "$FP_A_DIR/Formula/stable_blk.rb" <<'PY'
import sys
txt = open(sys.argv[1]).read()
stable_end = txt.index("  end", txt.index("stable do"))
assert stable_end < txt.index("bottle do") < txt.index("keg_only"), f"bottle do inserted inside stable do:\n{txt}"
PY

# 7. Non-dry-run Fast-Path B with real x86_64 Mach-O binary (single binary accepted, dylib rejected)
if command -v clang >/dev/null 2>&1; then
  FP_B_DIR="$TMP_DIR/fp_b"
  mkdir -p "$FP_B_DIR/Formula" "$FP_B_DIR/src_good" "$FP_B_DIR/src_bad" "$FP_B_DIR/Cellar" "$FP_B_DIR/api/formula"
  echo 'int main(void){return 0;}' > "$FP_B_DIR/src_good/main.c"
  clang -arch x86_64 "$FP_B_DIR/src_good/main.c" -o "$FP_B_DIR/src_good/mytool"
  echo "MIT" > "$FP_B_DIR/src_good/LICENSE"
  tar -czf "$FP_B_DIR/mytool-darwin-x86_64.tar.gz" -C "$FP_B_DIR/src_good" mytool LICENSE

  cp "$FP_B_DIR/src_good/mytool" "$FP_B_DIR/src_bad/mytool"
  touch "$FP_B_DIR/src_bad/libhelper.dylib"
  tar -czf "$FP_B_DIR/badtool-darwin-x86_64.tar.gz" -C "$FP_B_DIR/src_bad" mytool libhelper.dylib

  cat <<'EOF' > "$FP_B_DIR/Formula/mytool.rb"
class Mytool < Formula
  desc "Standalone test tool"
  url "https://github.com/acme/mytool/archive/refs/tags/v1.0.0.tar.gz"
  version "1.0.0"
end
EOF
  cat <<'EOF' > "$FP_B_DIR/Formula/badtool.rb"
class Badtool < Formula
  desc "Dylib tool"
  url "https://github.com/acme/badtool/archive/refs/tags/v1.0.0.tar.gz"
  version "1.0.0"
end
EOF
  echo '{}' > "$FP_B_DIR/api/formula/mytool.json"
  echo '{}' > "$FP_B_DIR/api/formula/badtool.json"

  mkdir -p "$FP_B_DIR/mock_bin"
  cat <<EOF > "$FP_B_DIR/mock_bin/gh"
#!/usr/bin/env bash
if [ "\$1" = "release" ] && [ "\$2" = "view" ]; then
  if [[ " \$* " == *"acme/mytool"* ]]; then
    echo '{"tagName":"v1.0.0","assets":[{"name":"mytool-darwin-x86_64.tar.gz","url":"file://${FP_B_DIR}/mytool-darwin-x86_64.tar.gz"}]}'
    exit 0
  elif [[ " \$* " == *"acme/badtool"* ]]; then
    echo '{"tagName":"v1.0.0","assets":[{"name":"badtool-darwin-x86_64.tar.gz","url":"file://${FP_B_DIR}/badtool-darwin-x86_64.tar.gz"}]}'
    exit 0
  fi
fi
exit 1
EOF
  chmod +x "$FP_B_DIR/mock_bin/gh"

  (
    cd "$FP_B_DIR"
    PATH="$FP_B_DIR/mock_bin:$PATH" MOCK_CELLAR_DIR="$FP_B_DIR/Cellar" MOCK_PKG_VER="1.0.0" \
      UPSTREAM_API_BASE="file://${FP_B_DIR}/api" bash "$MIRROR_HELPER" mytool "1.0.0"
  )
  if [ ! -x "$FP_B_DIR/Cellar/mytool/1.0.0/bin/mytool" ] || [ ! -f "$FP_B_DIR/mytool-1.0.0.sequoia.bottle.tar.gz" ]; then
    echo "Assertion failed: Fast-Path B did not stage binary in mock --cellar or create bottle"
    exit 1
  fi

  if (
    cd "$FP_B_DIR"
    PATH="$FP_B_DIR/mock_bin:$PATH" MOCK_CELLAR_DIR="$FP_B_DIR/Cellar" MOCK_PKG_VER="1.0.0" \
      UPSTREAM_API_BASE="file://${FP_B_DIR}/api" bash "$MIRROR_HELPER" badtool "1.0.0" 2>/dev/null
  ); then
    echo "Assertion failed: Fast-Path B should reject archives containing .dylib files"
    exit 1
  fi
  if [ -d "$FP_B_DIR/Cellar/badtool" ]; then
    echo "Assertion failed: rejected Fast-Path B leaked Cellar directory"
    exit 1
  fi
fi

echo "All try_mirror_formula_binary tests passed!"
