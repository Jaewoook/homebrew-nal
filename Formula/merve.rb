unless Dependency.singleton_class.const_defined?(:NAL_TAP_DEDUP)
  Dependency.singleton_class.prepend(Module.new do
    const_set(:NAL_TAP_DEDUP, true)
    def merge_repeats(all)
      all.group_by { |d| Utils.name_from_full_name(d.name) }.filter_map do |_, deps|
        pref = deps.find { |d| d.name.start_with?("jaewoook/nal/") } || deps.first
        pref&.class&.new(pref.name, merge_tags(deps), **(pref.uses_from_macos? ? { bounds: pref.bounds } : {}))
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
        if dep_formula.tap&.to_s == "jaewoook/nal"
          prev_remaps = Thread.current[:nal_tap_remaps] || {}
          rack_str = dep_formula.rack.to_s.chomp("/")
          rack_keys = [rack_str]
          begin
            rack_keys << File.realpath(rack_str)
          rescue SystemCallError
          end
          remaps = prev_remaps.dup
          rack_keys.uniq.each { |k| remaps[k] = dep_formula.tap }
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

class Merve < Formula
  desc "C++ lexer for extracting named exports from CommonJS modules"
  homepage "https://github.com/nodejs/merve"
  url "https://github.com/nodejs/merve/archive/refs/tags/v1.2.2.tar.gz"
  sha256 "8f19c2132447b9113545ffd399cb2bc1e61c6166743921b04883f8e1d778d69e"
  license "Apache-2.0"
  revision 4

  bottle do
    root_url "https://github.com/Jaewoook/homebrew-nal/releases/download/merve.1.2.2_4"
    rebuild 1
    sha256 cellar: :any, sequoia: "71da9691f644709cb4141b904bbfd73bd67c053e7b51a901b86bb2473aed55aa"
  end

  depends_on "cmake" => :build
  depends_on "jaewoook/nal/simdutf"

  deny_network_access!

  def install
    args = %w[
      -DMERVE_TESTING=OFF
      -DMERVE_USE_SIMDUTF=ON
      -DBUILD_SHARED_LIBS=ON
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    ]
    system "cmake", "-S", ".", "-B", "build", *std_cmake_args, *args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    (testpath/"test-merv.c").write <<~'C'
      #include "merve_c.h"
      #include <stdio.h>
      #include <string.h>

      int main(void) {
        const char *source = "exports.foo = 1;\nexports.bar = 2;\n";
        merve_analysis result = merve_parse_commonjs(source, strlen(source), NULL);
        merve_string export_name;

        if (!result || !merve_is_valid(result)) return 1;

        export_name = merve_get_export_name(result, 1);
        printf("%zu %.*s %u\n",
               merve_get_exports_count(result),
               (int) export_name.length, export_name.data,
               merve_get_export_line(result, 1));
        merve_free(result);
        return 0;
      }
    C
    system ENV.cc, "test-merv.c", "-I#{include}", "-L#{lib}", "-lmerve", "-o", "test-merv"
    assert_equal "2 bar 2\n", shell_output("./test-merv")
  end
end
