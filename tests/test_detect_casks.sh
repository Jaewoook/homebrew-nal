#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECT_SCRIPT="${SCRIPT_DIR}/scripts/detect_formulas.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Formula" "$TMP_DIR/Casks" "$TMP_DIR/scripts"
cp "$DETECT_SCRIPT" "$TMP_DIR/scripts/detect_formulas.sh"

cat <<'EOF' > "$TMP_DIR/Formula/docker.rb"
class Docker < Formula
  desc "Pack, ship and run any application as a lightweight container"
end
EOF

cat <<'EOF' > "$TMP_DIR/Casks/docker.rb"
cask "docker" do
  version "4.38.0"
  desc "App to build and share containerised applications and microservices"
end
EOF

cat <<'EOF' > "$TMP_DIR/Casks/ghostty.rb"
cask "ghostty" do
  version "1.1.2"
end
EOF

OUT1="$TMP_DIR/out1.txt"
(
  cd "$TMP_DIR"
  CASK_INPUT="ghostty" GITHUB_OUTPUT="$OUT1" bash scripts/detect_formulas.sh
)

CASKS_JSON=$(grep '^casks=' "$OUT1" | cut -d= -f2-)
FORMULAS_JSON=$(grep '^formulas=' "$OUT1" | cut -d= -f2-)
CASK_COUNT=$(grep '^cask_count=' "$OUT1" | cut -d= -f2-)
TOTAL_COUNT=$(grep '^count=' "$OUT1" | cut -d= -f2-)

if [ "$CASKS_JSON" != '["ghostty"]' ] || [ "$FORMULAS_JSON" != '[]' ] || [ "$CASK_COUNT" != "1" ] || [ "$TOTAL_COUNT" != "1" ]; then
  echo "Assertion failed for CASK_INPUT=ghostty: casks=$CASKS_JSON formulas=$FORMULAS_JSON cask_count=$CASK_COUNT count=$TOTAL_COUNT"
  exit 1
fi

# Same-name collision test: FORMULA_INPUT=docker vs CASK_INPUT=docker
OUT2="$TMP_DIR/out2.txt"
(
  cd "$TMP_DIR"
  FORMULA_INPUT="docker" GITHUB_OUTPUT="$OUT2" bash scripts/detect_formulas.sh
)
if [ "$(grep '^formulas=' "$OUT2" | cut -d= -f2-)" != '["docker"]' ] || [ "$(grep '^casks=' "$OUT2" | cut -d= -f2-)" != '[]' ]; then
  echo "Assertion failed: FORMULA_INPUT=docker should only select Formula/docker.rb"
  exit 1
fi

OUT3="$TMP_DIR/out3.txt"
(
  cd "$TMP_DIR"
  CASK_INPUT="docker" GITHUB_OUTPUT="$OUT3" bash scripts/detect_formulas.sh
)
if [ "$(grep '^casks=' "$OUT3" | cut -d= -f2-)" != '["docker"]' ] || [ "$(grep '^formulas=' "$OUT3" | cut -d= -f2-)" != '[]' ]; then
  echo "Assertion failed: CASK_INPUT=docker should only select Casks/docker.rb"
  exit 1
fi

echo "All detect_casks tests passed!"
