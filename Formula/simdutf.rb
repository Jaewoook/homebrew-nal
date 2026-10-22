class Simdutf < Formula
  desc "Unicode conversion routines, fast"
  homepage "https://simdutf.github.io/simdutf/"
  url "https://github.com/simdutf/simdutf/archive/refs/tags/v9.3.2.tar.gz"
  sha256 "d92a0a4ce216dcebf18af20fed7ea7279fa535683f790fdaeed39827a234f567"
  license any_of: ["Apache-2.0", "MIT"]
  compatibility_version 7
  head "https://github.com/simdutf/simdutf.git", branch: "master"

  livecheck do
    url :stable
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  bottle do
    root_url "https://github.com/Jaewoook/homebrew-nal/releases/download/simdutf.9.3.2"
    rebuild 1
    sha256 cellar: :any, sequoia: "12f8160319525ed2b75cff8090ebf517ae0cf51cb31fbf14c9a4963a0a01b054"
  end

  depends_on "jaewoook/nal/cmake" => :build

  def install
    # C++20 is needed by `node`
    args = %W[
      -DBUILD_SHARED_LIBS=ON
      -DCMAKE_INSTALL_RPATH=#{rpath}
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
      -DCPM_LOCAL_PACKAGES_ONLY=ON
      -DPython3_EXECUTABLE=#{which("python3")}
      -DSIMDUTF_BENCHMARKS=OFF
      -DSIMDUTF_CXX_STANDARD=20
    ]
    system "cmake", "-S", ".", "-B", "build", *args, *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    (testpath/"test.cpp").write <<~CPP
      #include <simdutf.h>
      #include <iostream>

      int main() {
        std::cout << simdutf::validate_utf8("hello", 5) << std::endl;
        return 0;
      }
    CPP
    system ENV.cxx, "test.cpp", "-I#{include}", "-L#{lib}", "-lsimdutf", "-o", "test"
    system "./test"
  end
end
