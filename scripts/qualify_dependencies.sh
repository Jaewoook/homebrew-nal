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
      [ $# -ge 2 ] || { echo "Error: --formula-dir requires a value" >&2; exit 1; }
      FORMULA_DIR="$2"
      shift 2
      ;;
    --tap)
      [ $# -ge 2 ] || { echo "Error: --tap requires a value" >&2; exit 1; }
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

  begin
    require "tab"
    Tab.singleton_class.prepend(Module.new do
      def for_keg(keg)
        tab = super
        remaps = Thread.current[:nal_tap_remaps]
        if remaps && !remaps.empty?
          keg_path = keg.to_s.chomp("/")
          real_keg = begin
            File.realpath(keg_path)
          rescue SystemCallError
            keg_path
          end
          target_tap = remaps[File.dirname(keg_path)] || remaps[File.dirname(real_keg)]
          if target_tap && tab&.source.is_a?(Hash) && tab.source["tap"] == "homebrew/core"
            remapped = tab.dup
            remapped.source = tab.source.merge("tap" => target_tap.to_s)
            remapped.tap = target_tap if remapped.respond_to?(:tap=)
            tab = remapped
          end
        end
        tab
      end
    end)

    require "formula_installer"
    FormulaInstaller.prepend(Module.new do
      def install_dependency(dep, dep_formula = dep.to_formula)
        if dep_formula.tap&.to_s == "{tap_name}"
          prev_remaps = Thread.current[:nal_tap_remaps] || {{}}
          rack_str = dep_formula.rack.to_s.chomp("/")
          rack_keys = [rack_str]
          begin
            rack_keys << File.realpath(rack_str)
          rescue SystemCallError
          end
          remaps = prev_remaps.dup
          rack_keys.uniq.each {{ |k| remaps[k] = dep_formula.tap }}
          Thread.current[:nal_tap_remaps] = remaps
          begin
            super
          ensure
            Thread.current[:nal_tap_remaps] = prev_remaps
          end
        else
          super
        end
      end
    end)
  rescue LoadError
  end
end

"""

header_re = re.compile(
    r'^unless Dependency\.singleton_class\.const_defined\?\(:NAL_TAP_DEDUP\)\n'
    r'(?:[ \t]*\n|[ \t]+[^\n]*\n)*?^end\n*',
    re.MULTILINE
)
magic_comment_re = re.compile(
    r'\A((?:#[^\n]*(?:frozen_string_literal|typed|encoding|warn_indent)[^\n]*\n)+)\n*'
)
tap_dep_re = re.compile(r'^(\s*depends_on\s+")' + re.escape(tap_name) + r'/([^"]+)(".*)$')
plain_dep_re = re.compile(r'^(\s*depends_on\s+")([^"/]+)(".*)$')
build_or_test_re = re.compile(r'=>.*:(build|test)\b')
on_linux_start_re = re.compile(r'^(\s*)on_(?:linux|arm)\s+do\b')

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
                if m_linux and not re.search(r'\bend\s*$', line.strip()):
                    linux_indent = m_linux.group(1)
            else:
                if re.match(r'^' + re.escape(linux_indent) + r'end\b', line):
                    linux_indent = None

            # First normalize any existing tap-qualified depends_on on this line
            m_tap = tap_dep_re.match(line)
            if m_tap:
                line = m_tap.group(1) + m_tap.group(2) + m_tap.group(3) + ('\n' if line.endswith('\n') else '')

            # Qualify runtime dependencies outside on_linux/on_arm blocks if present in available_deps
            code_only = re.sub(r'#.*$', '', line)
            if linux_indent is None and not build_or_test_re.search(code_only):
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
            if magic_comment_re.match(new_body):
                new_content = magic_comment_re.sub(
                    lambda m: m.group(1) + '\n' + dedup_header,
                    new_body,
                    count=1,
                )
            else:
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
