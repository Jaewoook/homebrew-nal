#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/scripts/sync_formulas.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/scripts" "$TMP_DIR/Formula" "$TMP_DIR/Casks" "$TMP_DIR/mock_bin"
cp "$SYNC_SCRIPT" "$TMP_DIR/scripts/sync_formulas.sh"
echo "{}" > "$TMP_DIR/.formula-versions.json"
echo "{}" > "$TMP_DIR/.cask-versions.json"

# Create mock curl in PATH
cat <<'EOF' > "$TMP_DIR/mock_bin/curl"
#!/usr/bin/env bash
URL="${!#}"
OUT_FILE=""
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "-o" ]; then
    next=$((i+1))
    OUT_FILE="${!next}"
  fi
done

if [[ "$URL" == *"formulae.brew.sh/api/cask/ghostty.json"* ]]; then
  cat <<'JSON'
{
  "token": "ghostty",
  "version": "1.1.2",
  "ruby_source_path": "Casks/g/ghostty.rb"
}
JSON
  exit 0
elif [[ "$URL" == *"raw.githubusercontent.com/Homebrew/homebrew-cask/HEAD/Casks/g/ghostty.rb"* ]]; then
  CONTENT='cask "ghostty" do
  version "1.1.2"
  sha256 "aaaabbbbccccddddeeeeffff0000111122223333444455556666777788889999"
  url "https://release.files.ghostty.org/#{version}/Ghostty.dmg"
  name "Ghostty"
  desc "Terminal emulator that uses platform-native UI and GPU acceleration"
  homepage "https://ghostty.org/"
  app "Ghostty.app"
end'
  if [ -n "$OUT_FILE" ]; then
    printf "%s\n" "$CONTENT" > "$OUT_FILE"
  else
    printf "%s\n" "$CONTENT"
  fi
  exit 0
fi
exit 1
EOF
chmod +x "$TMP_DIR/mock_bin/curl"

OUTPUT_FILE="$TMP_DIR/github_output.txt"
(
  cd "$TMP_DIR"
  PATH="$TMP_DIR/mock_bin:$PATH" GITHUB_OUTPUT="$OUTPUT_FILE" bash "$TMP_DIR/scripts/sync_formulas.sh" --casks ghostty --no-commit
)

if [ ! -f "$TMP_DIR/Casks/ghostty.rb" ]; then
  echo "Assertion failed: Casks/ghostty.rb was not created"
  exit 1
fi

TRACKED_VER=$(jq -r '.["ghostty"].version // .["ghostty"] // empty' "$TMP_DIR/.cask-versions.json")
if [ "$TRACKED_VER" != "1.1.2" ]; then
  echo "Assertion failed: expected ghostty version 1.1.2 in .cask-versions.json, got '$TRACKED_VER'"
  exit 1
fi

SYNCED_CASKS=$(grep '^casks=' "$OUTPUT_FILE" | cut -d= -f2-)
if [ "$SYNCED_CASKS" != "ghostty" ]; then
  echo "Assertion failed: expected casks=ghostty in GITHUB_OUTPUT, got '$SYNCED_CASKS'"
  exit 1
fi

# Test scheduled sync union: .cask-versions.json has ghostty, Casks/ has extra.rb
touch "$TMP_DIR/Casks/extra.rb"
(
  cd "$TMP_DIR"
  # Run in scheduled mode (no formulas or casks arguments)
  PATH="$TMP_DIR/mock_bin:$PATH" GITHUB_OUTPUT="$OUTPUT_FILE" bash "$TMP_DIR/scripts/sync_formulas.sh" --dry-run > "$TMP_DIR/scheduled.log" 2>&1 || true
)

if ! grep -q "Checking cask: extra" "$TMP_DIR/scheduled.log"; then
  echo "Assertion failed: extra.rb in Casks/ was not checked during scheduled sync"
  cat "$TMP_DIR/scheduled.log"
  exit 1
fi

if ! grep -q "Checking cask: ghostty" "$TMP_DIR/scheduled.log"; then
  echo "Assertion failed: ghostty in .cask-versions.json was not checked during scheduled sync"
  cat "$TMP_DIR/scheduled.log"
  exit 1
fi

echo "All sync_casks tests passed!"
