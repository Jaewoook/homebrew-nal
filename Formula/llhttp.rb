class Llhttp < Formula
  desc "Port of http_parser to llparse"
  homepage "https://llhttp.org/"
  url "https://github.com/nodejs/llhttp/archive/refs/tags/release/v9.4.3.tar.gz"
  sha256 "1eb813c7437b31a87496a1cd3ed79f00746720f5e7e29c79b42c02cb69f36c39"
  license "MIT"
  compatibility_version 2

  bottle do
    root_url "https://github.com/Jaewoook/homebrew-nal/releases/download/llhttp.9.4.3"
    rebuild 1
    sha256 cellar: :any, sequoia: "270829c2cc2a8d8ebf113d2ad0e4c83edf7fadfbe9ce05f5ec462ff514d80336"
  end

  depends_on "jaewoook/nal/cmake" => :build

  def install
    system "cmake", "-S", ".", "-B", "build", *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    (testpath/"test.c").write <<~'C'
      #include <stdio.h>
      #include <string.h>
      #include <llhttp.h>

      int handle_on_message_complete(llhttp_t* parser) {
        fprintf(stdout, "Message completed!\n");
        return 0;
      }

      int main(void) {
        llhttp_t parser;
        llhttp_settings_t settings;
        llhttp_settings_init(&settings);
        settings.on_message_complete = handle_on_message_complete;
        llhttp_init(&parser, HTTP_BOTH, &settings);

        const char* request = "GET / HTTP/1.1\r\n\r\n";
        int request_len = strlen(request);
        enum llhttp_errno err = llhttp_execute(&parser, request, request_len);

        if (err == HPE_OK) {
          fprintf(stdout, "Successfully parsed!\n");
          return 0;
        } else {
          fprintf(stderr, "Parse error: %s %s\n", llhttp_errno_name(err), llhttp_get_error_reason(&parser));
          return 1;
        }
      }
    C
    system ENV.cc, "test.c", "-o", "test", "-L#{lib}", "-lllhttp"
    assert_equal "Message completed!\nSuccessfully parsed!\n", shell_output("./test")
  end
end
