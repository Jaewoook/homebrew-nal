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

OUT_MULTI=$(cd "$TMP_DIR" && PATH="$TMP_DIR/mock_bin:$PATH" bash "$MIRROR_HELPER" multi_os --dry-run)
if ! echo "$OUT_MULTI" | grep -q "FAST_PATH_A:sequoia:"; then
  echo "Assertion failed: expected sequoia tag priority over tahoe, got: $OUT_MULTI"
  exit 1
fi

# 3. Standalone GitHub formula without x86_64 GHCR bottle (Fast-Path B dry-run check)
cat <<'EOF' > "$TMP_DIR/Formula/gitleaks.rb"
class Gitleaks < Formula
  desc "Audit git repos for secrets"
  homepage "https://github.com/gitleaks/gitleaks"
  url "https://github.com/gitleaks/gitleaks/archive/refs/tags/v8.24.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  depends_on "go" => :build
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

echo "All try_mirror_formula_binary tests passed!"
