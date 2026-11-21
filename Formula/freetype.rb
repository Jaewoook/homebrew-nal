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

class Freetype < Formula
  desc "Software library to render fonts"
  homepage "https://www.freetype.org/"
  url "https://downloads.sourceforge.net/project/freetype/freetype2/2.15.0/freetype-2.15.0.tar.xz"
  mirror "https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz"
  sha256 "93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5"
  license "FTL"
  compatibility_version 1

  livecheck do
    url :stable
    regex(/url=.*?freetype[._-]v?(\d+(?:\.\d+)+)\.t/i)
  end

  bottle do
    root_url "https://github.com/Jaewoook/homebrew-nal/releases/download/freetype.2.15.0"
    rebuild 2
    sha256 cellar: :any, sequoia: "af1b42f6e54b86f3f4a95ea7958ae63122923d3abaae4863b6cf670ee02f32e7"
  end

  depends_on "pkgconf" => :build
  depends_on "jaewoook/nal/brotli"
  depends_on "jaewoook/nal/libpng"

  uses_from_macos "bzip2"

  on_linux do
    depends_on "zlib-ng-compat"
  end

  deny_network_access!

  def install
    # Avoid enabling macOS 15.4+ hvf feature for bottle compatibility
    ENV["ac_cv_header_hvf_Scaler_h"] = "no" if OS.mac? && MacOS.version <= :sequoia

    # This file will be installed to bindir, so we want to avoid embedding the
    # absolute path to the pkg-config shim.
    inreplace "builds/unix/freetype-config.in", "%PKG_CONFIG%", "pkg-config"

    system "./configure", "--prefix=#{prefix}",
                          "--enable-freetype-config",
                          "--with-brotli",
                          "--without-harfbuzz"
    system "make"
    system "make", "install"

    inreplace [bin/"freetype-config", lib/"pkgconfig/freetype2.pc"],
      prefix, opt_prefix
  end

  test do
    system bin/"freetype-config", "--cflags", "--libs", "--ftversion",
                                  "--exec-prefix", "--prefix"
  end
end
