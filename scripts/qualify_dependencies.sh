#!/usr/bin/env bash
# ==============================================================================
# qualify_dependencies.sh - Qualify tap dependencies with tap prefix
# ==============================================================================
set -euo pipefail

FORMULA_DIR="Formula"
TAP_NAME="jaewoook/nal"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --formula-dir)
      FORMULA_DIR="$2"
      shift 2
      ;;
    --tap)
      TAP_NAME="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--formula-dir DIR] [--tap TAP_NAME]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [ ! -d "$FORMULA_DIR" ]; then
  echo "Formula directory $FORMULA_DIR does not exist. Skipping qualification."
  exit 0
fi

# List all formula names present in the formula directory
AVAILABLE_FORMULAS=()
for f in "$FORMULA_DIR"/*.rb; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .rb)
  AVAILABLE_FORMULAS+=("$name")
done

if [ ${#AVAILABLE_FORMULAS[@]} -eq 0 ]; then
  exit 0
fi

echo "Qualifying dependencies in $FORMULA_DIR for tap '$TAP_NAME'..."

python3 - <<EOF "$FORMULA_DIR" "$TAP_NAME" "${AVAILABLE_FORMULAS[@]}"
import sys
import os
import re

formula_dir = sys.argv[1]
tap_name = sys.argv[2]
available_deps = sys.argv[3:]

for dep in available_deps:
    # Match: depends_on "dep"
    pattern = re.compile(r'(depends_on\s+")' + re.escape(dep) + r'(")')
    replacement = r'\g<1>' + tap_name + '/' + dep + r'\g<2>'

    for fname in os.listdir(formula_dir):
        if not fname.endswith('.rb'):
            continue
        current_name = fname[:-3]
        if current_name == dep:
            continue
        filepath = os.path.join(formula_dir, fname)
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
            new_content = pattern.sub(replacement, content)
            if new_content != content:
                with open(filepath, 'w', encoding='utf-8') as f:
                    f.write(new_content)
        except Exception as e:
            sys.stderr.write(f"Error processing {filepath}: {e}\n")
EOF

echo "Dependency qualification complete."
