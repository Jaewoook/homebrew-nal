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
    require "formula_installer"
    FormulaInstaller.prepend(Module.new do
      def install_dependency(dep, dep_formula = dep.to_formula)
        if dep_formula.tap&.to_s&.start_with?("jaewoook/nal")
          keg_paths = [dep_formula.linked_keg, dep_formula.prefix]
          keg_paths += dep_formula.rack.subdirs if dep_formula.rack.directory?
          keg_paths.uniq.each do |keg_path|
            next unless keg_path&.directory?

            target = keg_path.symlink? ? Utils::Path.resolved_path(keg_path) : keg_path
            begin
              keg = Keg.new(target)
              if keg.tab&.source.is_a?(Hash) && keg.tab.source["tap"] == "homebrew/core"
                keg.tab.source["tap"] = dep_formula.tap.to_s
                keg.tab.tap = dep_formula.tap if keg.tab.respond_to?(:tap=)
              end
            rescue StandardError
            end
          end
        end
        super
      end
    end)
  rescue LoadError
  end
end

class Uvwasi < Formula
  desc "WASI syscall API built atop libuv"
  homepage "https://github.com/nodejs/uvwasi"
  url "https://github.com/nodejs/uvwasi/archive/refs/tags/v0.0.23.tar.gz"
  sha256 "cdb148aac298883b51da887657deca910c7c02f35435e24f125cef536fe8d5e1"
  license "MIT"
  compatibility_version 1
  head "https://github.com/nodejs/uvwasi.git", branch: "main"

  bottle do
    root_url "https://github.com/Jaewoook/homebrew-nal/releases/download/uvwasi.0.0.23"
    rebuild 2
    sha256 cellar: :any, sequoia: "875825320ce7130d7067d14717c235240bc7c44449eb9541b6a3963bbc4dca95"
  end

  depends_on "cmake" => :build
  depends_on "jaewoook/nal/libuv"

  # Remove find_dependency for a not-installed module in CMake config
  patch do
    url "https://github.com/nodejs/uvwasi/commit/fcc0be004867939389aba3cc715ea90b86ab869c.patch?full_index=1"
    sha256 "4a3a388e9831709089270b7c6bc779d86257857192dee247d32ec360cd7819cc"
    type :unofficial
    resolves "https://github.com/nodejs/uvwasi/pull/313"
  end

  deny_network_access!

  def install
    system "cmake", "-S", ".", "-B", "build", *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    # Adapted from "Example Usage" in README.
    (testpath/"test-uvwasi.c").write <<~C
      #include <stdlib.h>
      #include <string.h>
      #include "uv.h"
      #include "uvwasi.h"

      int main(void) {
        uvwasi_t uvwasi;
        uvwasi_options_t init_options;
        uvwasi_errno_t err;

        memset(&init_options, 0, sizeof(init_options));

        /* Setup the initialization options. */
        init_options.in = 0;
        init_options.out = 1;
        init_options.err = 2;
        init_options.fd_table_size = 4;

        init_options.argc = 1;
        init_options.argv = calloc(init_options.argc, sizeof(char*));
        init_options.argv[0] = strdup("test-uvwasi");

        init_options.envp = calloc(1, sizeof(char*));
        init_options.envp[0] = NULL;

        init_options.preopenc = 1;
        init_options.preopens = calloc(1, sizeof(uvwasi_preopen_t));
        init_options.preopens[0].mapped_path = strdup("/sandbox");
        init_options.preopens[0].real_path = strdup("/tmp");

        init_options.allocator = NULL;

        /* Initialize the sandbox. */
        err = uvwasi_init(&uvwasi, &init_options);

        if (err != UVWASI_ESUCCESS) {
          fprintf(stderr, "uvwasi_init() failed: %d\\n", err);
          return 1;
        }

        /* Clean up resources. */
        uvwasi_destroy(&uvwasi);
        return 0;
      }
    C

    ENV.append_to_cflags "-I#{include} -I#{formula_opt_include("libuv")}"
    ENV.append "LDFLAGS", "-L#{lib}"
    ENV.append "LDLIBS", "-luvwasi"

    system "make", "test-uvwasi"
    system "./test-uvwasi"
  end
end
