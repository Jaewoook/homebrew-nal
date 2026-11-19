class Graphite2 < Formula
  desc "Smart font renderer for non-Roman scripts"
  homepage "https://graphite.sil.org/"
  url "https://github.com/silnrsi/graphite/releases/download/1.3.15/graphite2-1.3.15.tgz"
  sha256 "c6bc8b4252724665297f7cad0c55897285c673f9b8e6db3522ace833593fe0b1"
  license any_of: ["MIT", "MPL-2.0", "LGPL-2.1-or-later", "GPL-2.0-or-later"]
  compatibility_version 1
  head "https://github.com/silnrsi/graphite.git", branch: "master"
  bottle do
    root_url "https://github.com/Jaewoook/homebrew-nal/releases/download/graphite2.1.3.15"
    sha256 cellar: :any, sonoma: "fd55694135675287cd54778988e7ea785246ac5bc0ad49a4434b0fcf25e64e4d"
  end

  depends_on "cmake" => :build

  on_linux do
    depends_on "freetype" => :build
  end

  resource "testfont", :test do
    url "https://scripts.sil.org/pub/woff/fonts/Simple-Graphite-Font.ttf"
    sha256 "7e573896bbb40088b3a8490f83d6828fb0fd0920ac4ccdfdd7edb804e852186a"
  end

  allow_network_access! :test

  def install
    args = %W[
      -DCMAKE_INSTALL_RPATH=#{rpath}
    ]
    system "cmake", "-S", ".", "-B", "build", *args, *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"

    inreplace lib/"pkgconfig/graphite2.pc", prefix.realpath, opt_prefix
  end

  test do
    resource("testfont").stage do
      shape = shell_output("#{bin}/gr2fonttest Simple-Graphite-Font.ttf 'abcde'")
      assert_match(/67.*36.*37.*38.*71/m, shape)
    end
  end
end
