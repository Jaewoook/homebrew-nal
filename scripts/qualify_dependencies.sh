#!/usr/bin/env bash
# ==============================================================================
# qualify_dependencies.sh - Qualify tap runtime dependencies with tap prefix
# ==============================================================================
set -euo pipefail

FORMULA_DIR="Formula"
TAP_NAME="jaewoook/nal"
TARGETS=()

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
      echo "Usage: $(basename "$0") [--formula-dir DIR] [--tap TAP_NAME] [formula1 ...]"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      TARGETS+=("$1")
      shift
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

python3 - "$FORMULA_DIR" "$TAP_NAME" "${#TARGETS[@]}" ${TARGETS[@]+"${TARGETS[@]}"} "${AVAILABLE_FORMULAS[@]}" <<'EOF'
import sys
import os
import re

formula_dir = sys.argv[1]
tap_name = sys.argv[2]
num_targets = int(sys.argv[3])
targets = set(sys.argv[4:4 + num_targets])
available_deps = set(sys.argv[4 + num_targets:])

dedup_header = f"""unless Dependency.singleton_class.const_defined?(:NAL_TAP_DEDUP)
  Dependency.singleton_class.prepend(Module.new do
    const_set(:NAL_TAP_DEDUP, true)
    def merge_repeats(all)
      all.group_by {{ |d| Utils.name_from_full_name(d.name) }}.filter_map do |_, deps|
        pref = deps.find {{ |d| d.name.start_with?("{tap_name}/") }} || deps.first
        pref&.class&.new(pref.name, merge_tags(deps), **(pref.uses_from_macos? ? {{ bounds: pref.bounds }} : {{}}))
      end
    end
  end)
end

"""

header_re = re.compile(
    r'\Aunless Dependency\.singleton_class\.const_defined\?\(:NAL_TAP_DEDUP\)\n.*?\nend\n+',
    re.DOTALL
)
tap_dep_re = re.compile(r'^(\s*depends_on\s+")' + re.escape(tap_name) + r'/([^"]+)(".*)$')
plain_dep_re = re.compile(r'^(\s*depends_on\s+")([^"/]+)(".*)$')
build_or_test_re = re.compile(r'=>.*:(build|test)\b')
on_linux_start_re = re.compile(r'^(\s*)on_linux\s+do\b')

for fname in sorted(os.listdir(formula_dir)):
    if not fname.endswith('.rb'):
        continue
    current_name = fname[:-3]
    if targets and current_name not in targets:
        continue

    filepath = os.path.join(formula_dir, fname)
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

        body = header_re.sub('', content)
        lines = body.splitlines(keepends=True)
        out_lines = []
        linux_indent = None

        for line in lines:
            if linux_indent is None:
                m_linux = on_linux_start_re.match(line)
                if m_linux:
                    linux_indent = m_linux.group(1)
            else:
                if re.match(r'^' + re.escape(linux_indent) + r'end\b', line):
                    linux_indent = None

            # First normalize any existing tap-qualified depends_on on this line
            m_tap = tap_dep_re.match(line)
            if m_tap:
                line = m_tap.group(1) + m_tap.group(2) + m_tap.group(3) + ('\n' if line.endswith('\n') else '')

            # Qualify runtime dependencies outside on_linux blocks if present in available_deps
            if linux_indent is None and not build_or_test_re.search(line):
                m_plain = plain_dep_re.match(line)
                if m_plain:
                    dep_name = m_plain.group(2)
                    if dep_name in available_deps and dep_name != current_name:
                        line = (
                            m_plain.group(1)
                            + tap_name + '/' + dep_name
                            + m_plain.group(3)
                            + ('\n' if line.endswith('\n') else '')
                        )

            out_lines.append(line)

        new_body = ''.join(out_lines)
        if f'depends_on "{tap_name}/' in new_body:
            new_content = dedup_header + new_body
        else:
            new_content = new_body

        if new_content != content:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(new_content)
    except Exception as e:
        sys.stderr.write(f"Error processing {filepath}: {e}\n")
EOF

echo "Dependency qualification complete."
