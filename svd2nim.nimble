# Package
version     = "0.4.1"
author      = "The svd2nim contributors"
description = "Convert CMSIS ARM SVD files to nim register memory mappings"
license     = "MIT"
bin         = @["svd2nim"]
binDir      = "build/"
srcDir      = "src"

#  Deps

requires "nim >= 1.4"
requires "regex >= 0.19.0"
requires "docopt >= 0.6.7"

before test:
  exec "nimble build"
  exec "./build/svd2nim --ignore-prepend ./tests/ATSAMD21G18A.svd -o tests/atsamd21g18a.nim"
