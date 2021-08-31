import unittest
import typedefs
import svdparser
import tables

suite "Create codegen typedefs":
  setup:
    let
      device {.used.} = readSVD("./tests/ARM_Example.svd")
      samd21 {.used.} = readSVD("./tests/ATSAMD21G18A.svd")

  test "Create type defs":
    let
      deviceTypes = device.createTypeDefs()
      samd21Types = samd21.createTypeDefs()

    # For now, just check that we create type defs without crashing
    # TODO: Add checks here
    check:
      deviceTypes.len > 0
      samd21Types.len > 0
