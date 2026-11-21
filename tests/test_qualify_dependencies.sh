#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUALIFY_SCRIPT="${SCRIPT_DIR}/scripts/qualify_dependencies.sh"

if [ ! -f "$QUALIFY_SCRIPT" ]; then
  echo "Error: $QUALIFY_SCRIPT does not exist"
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Formula"

# Create a dependency formula
cat <<'EOF' > "$TMP_DIR/Formula/bar.rb"
class Bar < Formula
  desc "Bar library"
end
EOF

# Create a dependent formula with:
# - an unqualified runtime dependency that exists in Formula/ (bar)
# - an unqualified dependency that DOES NOT exist in Formula/ (baz)
# - an already tap-qualified runtime dependency (jaewoook/nal/bar)
# - build and array-tagged build/test dependencies (should NOT be qualified)
# - a pre-qualified build dependency (should be unqualified)
# - a Linux-only dependency inside on_linux (should NOT be qualified)
cat <<'EOF' > "$TMP_DIR/Formula/foo.rb"
class Foo < Formula
  desc "Foo program"
  depends_on "bar"
  depends_on "baz"
  depends_on "jaewoook/nal/bar"
  depends_on "bar" => :build
  depends_on "bar" => [:build, :test]
  depends_on "jaewoook/nal/bar" => :test

  on_linux do
    depends_on "bar"
  end
end
EOF

# Run qualify script pointing to the custom Formula dir
bash "$QUALIFY_SCRIPT" --formula-dir "$TMP_DIR/Formula" --tap "jaewoook/nal"

# Assertions
FOO_CONTENT=$(cat "$TMP_DIR/Formula/foo.rb")
BAR_CONTENT=$(cat "$TMP_DIR/Formula/bar.rb")

# 1. Runtime "bar" should be replaced with "jaewoook/nal/bar"
if ! echo "$FOO_CONTENT" | grep -Fq 'depends_on "jaewoook/nal/bar"'; then
  echo "Assertion failed: depends_on \"bar\" was not qualified"
  exit 1
fi

# 2. Build and test dependencies should NOT be qualified
if echo "$FOO_CONTENT" | grep -Eq 'depends_on "jaewoook/nal/bar"[[:space:]]*=>'; then
  echo "Assertion failed: build/test dependency was qualified with tap prefix"
  exit 1
fi
if ! echo "$FOO_CONTENT" | grep -Fq 'depends_on "bar" => :build'; then
  echo "Assertion failed: depends_on \"bar\" => :build was altered"
  exit 1
fi
if ! echo "$FOO_CONTENT" | grep -Fq 'depends_on "bar" => [:build, :test]'; then
  echo "Assertion failed: depends_on \"bar\" => [:build, :test] was altered"
  exit 1
fi
if ! echo "$FOO_CONTENT" | grep -Fq 'depends_on "bar" => :test'; then
  echo "Assertion failed: pre-qualified :test dependency was not reverted to unqualified"
  exit 1
fi

# 3. "baz" should NOT be qualified because Formula/baz.rb does not exist
if echo "$FOO_CONTENT" | grep -Fq 'depends_on "jaewoook/nal/baz"'; then
  echo "Assertion failed: depends_on \"baz\" was qualified even though baz.rb does not exist"
  exit 1
fi
if ! echo "$FOO_CONTENT" | grep -Fq 'depends_on "baz"'; then
  echo "Assertion failed: depends_on \"baz\" was altered"
  exit 1
fi

# 4. No double prefix (e.g. jaewoook/nal/jaewoook/nal/bar)
if echo "$FOO_CONTENT" | grep -Fq 'jaewoook/nal/jaewoook/nal/bar'; then
  echo "Assertion failed: double prefix detected"
  exit 1
fi

# 5. NAL_TAP_DEDUP header should be present in foo.rb (has qualified deps) and absent in bar.rb (no qualified deps)
if ! echo "$FOO_CONTENT" | grep -Fq 'NAL_TAP_DEDUP'; then
  echo "Assertion failed: NAL_TAP_DEDUP header was not injected into foo.rb"
  exit 1
fi
if ! echo "$FOO_CONTENT" | grep -Fq 'if dep_formula.tap&.to_s == "jaewoook/nal"'; then
  echo "Assertion failed: exact tap match check was not injected into foo.rb"
  exit 1
fi
if echo "$BAR_CONTENT" | grep -Fq 'NAL_TAP_DEDUP'; then
  echo "Assertion failed: NAL_TAP_DEDUP header should not be in bar.rb"
  exit 1
fi

# 6. Comments and `require` preamble before `class` must be preserved idempotently
cat <<'EOF' > "$TMP_DIR/Formula/preamble.rb"
# frozen_string_literal: true

require "language/go"

class Preamble < Formula
  desc "Formula with preamble"
  depends_on "bar"
end
EOF

bash "$QUALIFY_SCRIPT" --formula-dir "$TMP_DIR/Formula" --tap "jaewoook/nal" preamble
FIRST_RUN=$(cat "$TMP_DIR/Formula/preamble.rb")
bash "$QUALIFY_SCRIPT" --formula-dir "$TMP_DIR/Formula" --tap "jaewoook/nal" preamble
SECOND_RUN=$(cat "$TMP_DIR/Formula/preamble.rb")

if [ "$FIRST_RUN" != "$SECOND_RUN" ]; then
  echo "Assertion failed: qualify_dependencies.sh is not idempotent with preamble comments/require"
  exit 1
fi
if ! echo "$SECOND_RUN" | grep -Fq 'require "language/go"' || ! head -n 1 "$TMP_DIR/Formula/preamble.rb" | grep -Fq '# frozen_string_literal: true'; then
  echo "Assertion failed: preamble comment or require was stripped"
  exit 1
fi
if [ "$(grep -cF 'unless Dependency.singleton_class.const_defined?(:NAL_TAP_DEDUP)' "$TMP_DIR/Formula/preamble.rb")" -ne 1 ]; then
  echo "Assertion failed: duplicate NAL_TAP_DEDUP headers in preamble.rb"
  exit 1
fi

# 7. Ruby unit test of the injected Tab.for_keg + FormulaInstaller#install_dependency hook
if command -v ruby >/dev/null 2>&1; then
  ruby -e '
    load_dir = ARGV[0]
    $LOAD_PATH.unshift(load_dir)
    # Provide minimal Tab, FormulaInstaller, Dependency, and Formula doubles before loading foo.rb
    class Dependency; end
    class Formula
      def self.method_missing(*); end
    end
    class Tab
      attr_accessor :source
      def initialize(tap_str)
        @source = { "tap" => tap_str }
      end
      def tap=(v)
        @source["tap"] = v.to_s
      end
      def self.for_keg(_keg)
        new("homebrew/core")
      end
    end
    class FormulaInstaller
      attr_reader :seen_tap
      def install_dependency(_dep, dep_formula)
        @seen_tap = Tab.for_keg(File.join(dep_formula.rack, "1.0")).source["tap"]
      end
    end
    # Write stub tab.rb and formula_installer.rb in load_dir so require succeeds
    File.write(File.join(load_dir, "tab.rb"), "# loaded\n")
    File.write(File.join(load_dir, "formula_installer.rb"), "# loaded\n")

    eval(File.read(ARGV[1]))
    DepFormula = Struct.new(:tap, :rack)
    dep_f = DepFormula.new("jaewoook/nal", File.join(load_dir, "Cellar/bar"))
    fi = FormulaInstaller.new
    fi.install_dependency(Object.new, dep_f)
    abort("Expected remapped tap jaewoook/nal, got #{fi.seen_tap.inspect}") unless fi.seen_tap == "jaewoook/nal"
    outside_tap = Tab.for_keg(File.join(load_dir, "Cellar/bar/1.0")).source["tap"]
    abort("Expected Tab.for_keg outside super to stay homebrew/core, got #{outside_tap.inspect}") unless outside_tap == "homebrew/core"
  ' "$TMP_DIR" "$TMP_DIR/Formula/foo.rb"
fi

# 8. Missing option value should exit non-zero cleanly (not unbound variable)
if bash "$QUALIFY_SCRIPT" --tap 2>/dev/null; then
  echo "Assertion failed: --tap without value should fail"
  exit 1
fi

echo "All qualify_dependencies tests passed!"
