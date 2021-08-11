
version     = "0.1.0"
author      = "The svd2nim contributors"
description = "Convert CMSIS ARM SVD files to nim register memory mappings"
license     = "MIT"
bin         = @["svd2nim"]
binDir      = "build/"

# Deps

requires "nim >= 1.4"
requires "regex >= 0.19.0"
requires "docopt >= 0.6.7"
requires "zip >= 0.3.1"
