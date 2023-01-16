# Package
version     = "0.4.0"
author      = "The svd2nim contributors"
description = "Convert CMSIS ARM SVD files to nim register memory mappings"
license     = "MIT"
bin         = @["svd2nim"]
binDir      = "build/"

# Deps

requires "nim >= 1.4"
requires "regex >= 0.19.0"
requires "docopt >= 0.6.7"

# Tasks

task intTest, "Run integration test":
  exec "nimble build"
  exec "./build/svd2nim --ignorePrepend ./tests/ATSAMD21G18A.svd"
  exec "nim r ./tests/integration_test.nim"
