import std/unittest
import std/sequtils
import std/tables
import std/sets
import ./codegen {.all.}
import ./svd2nim
import ./utils
import ./basetypes

func toTable(s: seq[CodeGenTypeDef]): Table[string, CodeGenTypeDef] =
  for td in s:
    result[td.name] = td

suite "ARM Example typedefs":
  setup:
    let
      device {.used.} = processSvd("./tests/ARM_Example.svd")
      devTypeMap = device.buildTypeMap
      deviceTypes = createTypeDefs(device, devTypeMap).toTable

  test "Create type defs":
    check:
      deviceTypes.len == 10
      deviceTypes["TIMER0_Type"].members.len == 8
      deviceTypes["TIMER0_Type"].members[0].name == "CR"
      deviceTypes["TIMER0_Type"].members[0].typeName == "TIMER0_CR_Type"
      deviceTypes["TIMER0_Type"].members[7].name == "RELOAD"
      deviceTypes["TIMER0_Type"].members[7].typeName == "array[4, TIMER0_RELOAD_Type]"
      deviceTypes["TIMER0_COUNT_Type"].members.len == 1
      deviceTypes["TIMER0_COUNT_Type"].members[0].name == "loc"
      deviceTypes["TIMER0_COUNT_Type"].members[0].typeName == "uint"

suite "SAMD21 typedefs":
  setup:
    let
      samd21 {.used.} = processSvd("./tests/ATSAMD21G18A.svd")
      samd21TypeMap = samd21.buildTypeMap
      samd21Types = createTypeDefs(samd21, samd21TypeMap).toTable

  test "Create type defs":
    check:
      samd21Types.len == 446

      # Test with a cluster
      samd21Types["TC3_Type"].members.len == 3
      samd21Types["TC3_Type"].members.mapIt(it.name) == @["COUNT8", "COUNT16", "COUNT32"]
      samd21Types["TC3_Type"].members.mapIt(it.typeName) == @[
        "TcCount8_Type", "TcCount16_Type", "TcCount32_Type"
      ]
      samd21Types["TcCount8_Type"].members.len == 15
      samd21Types["TcCount8_COUNT_Type"].members.len == 1
      samd21Types["TcCount8_COUNT_Type"].members[0].name == "loc"
      samd21Types["TcCount8_COUNT_Type"].members[0].typeName == "uint"

  test "Append and prepend register names":
    setOptions CodeGenOptions(ignorePrepend: true)
    let
      samd21TypeMapNoPre = samd21.buildTypeMap
      samd21TypesNoPre = samd21.createTypeDefs(samd21TypeMapNoPre).toTable

    check:
      samd21Types["AC_Type"].members[0].name == "AC_CTRLA"
      samd21TypesNoPre["AC_Type"].members[0].name == "CTRLA"

  test "Create field enums":
    let
      symbols = initHashSet[string]()
      samd21enums = createFieldEnums(samd21.peripherals["GCLK".toSvdId], samd21TypeMap, symbols)
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

suite "Misc codegen tests":
  test "Sanitize Identifiers":
    check:
      sanitizeIdent("16k") == "x16k" # starts with number
      sanitizeIdent("Trail_Underscore_") == "Trail_Underscore"
      sanitizeIdent("Two__Underscores__") == "Two_Underscores"
      sanitizeIdent("ADDR") == "ADDRx" # is a keyword
