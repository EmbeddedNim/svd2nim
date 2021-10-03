import std/unittest
import std/sequtils
import std/tables
import codegen
import svd2nim
import utils

suite "Create codegen typedefs":
  setup:
    let
      device {.used.} = processSvd("./tests/ARM_Example.svd")
      samd21 {.used.} = processSvd("./tests/ATSAMD21G18A.svd")

  test "Create type defs":
    let
      deviceTypes = device.createTypeDefs()
      samd21Types = samd21.createTypeDefs()

    check:
      deviceTypes.len == 10
      samd21Types.len == 445

      deviceTypes["TIMER0_Type"].fields.len == 8
      deviceTypes["TIMER0_Type"].fields[0].name == "CR"
      deviceTypes["TIMER0_Type"].fields[0].typeName == "TIMER0_CR_Type"
      deviceTypes["TIMER0_Type"].fields[7].name == "RELOAD"
      deviceTypes["TIMER0_Type"].fields[7].typeName == "array[4, TIMER0_RELOAD_Type]"
      deviceTypes["TIMER0_COUNT_Type"].fields.len == 1
      deviceTypes["TIMER0_COUNT_Type"].fields[0].name == "loc"
      deviceTypes["TIMER0_COUNT_Type"].fields[0].typeName == "uint"

      # Test with a cluster
      samd21Types["TC3_Type"].fields.len == 3
      samd21Types["TC3_Type"].fields.mapIt(it.name) == @["COUNT8", "COUNT16", "COUNT32"]
      samd21Types["TC3_Type"].fields.mapIt(it.typeName) == @[
        "TcCount8_Type", "TcCount16_Type", "TcCount32_Type"
      ]
      samd21Types["TcCount8_Type"].fields.len == 15
      samd21Types["TcCount8_COUNT_Type"].fields.len == 1
      samd21Types["TcCount8_COUNT_Type"].fields[0].name == "loc"
      samd21Types["TcCount8_COUNT_Type"].fields[0].typeName == "uint"

  test "Append and prepend register names":
    let samd21Types = samd21.createTypeDefs()
    setOptions CodeGenOptions(ignorePrepend: true)
    let samd21TypesNoPre = samd21.createTypeDefs()

    check:
      samd21Types["AC_Type"].fields[0].name == "AC_CTRLA"
      samd21TypesNoPre["AC_Type"].fields[0].name == "CTRLA"

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
