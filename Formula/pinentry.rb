class Pinentry < Formula
  desc "Passphrase entry dialog utilizing the Assuan protocol"
  homepage "https://www.gnupg.org/related_software/pinentry/"
  url "https://www.gnupg.org/ftp/gcrypt/pinentry/pinentry-1.3.3.tar.bz2"
  mirror "https://www.mirrorservice.org/sites/ftp.gnupg.org/gcrypt/pinentry/pinentry-1.3.3.tar.bz2"
  sha256 "c2970f16d6afb66ecddfca767d743936c86239bff936eed7fd7597a678414b63"
  license "GPL-2.0-or-later"
  compatibility_version 1

  livecheck do
    url "https://gnupg.org/ftp/gcrypt/pinentry/"
    regex(/href=.*?pinentry[._-]v?(\d+(?:\.\d+)+)\.t/i)
  end

  bottle do
    root_url "https://github.com/Jaewoook/homebrew-nal/releases/download/pinentry.1.3.3"
    rebuild 1
    sha256 cellar: :any, sequoia: "9d99e3fdf627b2e9091e37a19cbae70739ed94c59a7d4e6a02d4f465bc694b4b"
  end

  depends_on "pkgconf" => :build
  depends_on "libassuan"
  depends_on "libgpg-error"

  uses_from_macos "ncurses"

  on_linux do
    depends_on "glib"
    depends_on "libsecret"
  end

  def install
    # Fix compile with newer Clang
    ENV.append_to_cflags "-Wno-implicit-function-declaration" if DevelopmentTools.clang_build_version >= 1403

    args = %w[
      --disable-silent-rules
      --disable-pinentry-fltk
      --disable-pinentry-gnome3
      --disable-pinentry-gtk2
      --disable-pinentry-qt
      --disable-pinentry-qt5
      --disable-pinentry-tqt
      --enable-pinentry-tty
    ]

    system "./configure", *args, *std_configure_args
    system "make", "install"
  end

  test do
    system bin/"pinentry", "--version"
    system bin/"pinentry-tty", "--version"
  end
end
