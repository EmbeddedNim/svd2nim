import std/strformat

# Package
version     = "0.5.0"
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


when defined windows:
  const svd2nimExec = "svd2nim.exe"
else:
  const svd2nimExec = "svd2nim"

before test:
  # This is used for the "integration" test, which checks register addresses
  # in the generated nim file.
  exec "nimble build"
  mkDir("tmp")
  exec fmt"./build/{svd2nimExec} --ignore-prepend ./tests/ATSAMD21G18A.svd -o tmp"

task release, "Build in release mode":
  switch("define", "release")
  setCommand("c", "src/svd2nim.nim")
