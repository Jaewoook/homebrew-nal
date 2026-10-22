class Gdb < Formula
  desc "GNU debugger"
  homepage "https://www.gnu.org/software/gdb/"
  url "https://ftpmirror.gnu.org/gdb/gdb-18.1.tar.xz"
  mirror "https://ftp.gnu.org/gnu/gdb/gdb-18.1.tar.xz"
  sha256 "cd9fc3fe2b47743840e42c1592d3d87f8302eb18639c0b8b4ba0898002e2348f"
  license "GPL-3.0-or-later"
  compatibility_version 1
  head "https://sourceware.org/git/binutils-gdb.git", branch: "master"

  bottle do
    root_url "https://github.com/Jaewoook/homebrew-nal/releases/download/gdb.18.1"
    rebuild 1
    sha256 sequoia: "0e6b56eaf6936ace8a3d981dbe42e81c0a06646cad8160708ef3ebe17033ec97"
  end

  depends_on "pkgconf" => :build
  depends_on "gmp"
  depends_on "mpfr"
  depends_on "ncurses" # https://github.com/Homebrew/homebrew-core/issues/224294
  depends_on "python@3.14"
  depends_on "jaewoook/nal/readline"
  depends_on "jaewoook/nal/xz" # required for lzma support
  depends_on "jaewoook/nal/zstd"

  uses_from_macos "expat", since: :sequoia # minimum macOS due to python

  # Workaround for https://github.com/Homebrew/brew/issues/19315
  on_sequoia :or_newer do
    on_intel do
      depends_on "expat"
    end
  end

  on_system :linux, macos: :ventura_or_newer do
    depends_on "texinfo" => :build
  end

  on_linux do
    depends_on "guile"
    depends_on "jaewoook/nal/zlib-ng-compat"
  end

  def install
    # Fix `error: use of undeclared identifier 'startup_with_shell'`
    inreplace "gdb/darwin-nat.c", "#include \"inferior.h\"",
                                  "#include \"inferior.h\"\n#include \"gdbsupport/common-inferior.h\""

    args = %W[
      --enable-targets=all
      --disable-binutils
      --disable-nls
      --enable-tui
      --with-curses
      --with-expat
      --with-lzma
      --with-python=#{python3}
      --with-system-readline
      --with-system-zlib
      --with-zstd
    ]

    # Fix: Apple Silicon build, this is only way to build native GDB
    if OS.mac? && Hardware::CPU.arm?
      # Workaround: "--target" must be "faked"
      args << "--target=x86_64-apple-darwin20"
      args << "--program-prefix="
    end

    mkdir "build" do
      system "../configure", *args, *std_configure_args
      system "make"

      # Don't install bfd or opcodes, as they are provided by binutils
      system "make", "install-gdb", "maybe-install-gdbserver"
    end
  end

  def caveats
    on_macos do
      <<~EOS
        gdb requires special privileges to access Mach ports.
        You will need to codesign the binary. For instructions, see:

          https://sourceware.org/gdb/wiki/PermissionsDarwin
      EOS
    end
  end

  test do
    system bin/"gdb", bin/"gdb", "-configuration"
  end
end
