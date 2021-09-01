import unittest
import typedefs
import svdparser
import tables
import utils

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

  test "Create field enums":
    let
      samd21enums = samd21.getPeriphByName("GCLK").createFieldEnums
      idEnum = samd21enums["GCLK_CLKCTRL_ID"]
      genEnum = samd21enums["GCLK_CLKCTRL_GEN"]

    check:
      idEnum.fields.len == 36
      idEnum.fields[2].key == "FDPLL32K"
      idEnum.fields[2].val == 0x2

      genEnum.fields.len == 9
      genEnum.fields[0].key == "GCLK0"
      genEnum.fields[0].val == 0
      genEnum.fields[8].key == "GCLK8"
      genEnum.fields[8].val == 8
