import std/unittest
import std/sequtils
import std/tables
import std/sets
import codegen {.all.}
import svd2nim
import utils
import basetypes
import transformations

func toTable(s: seq[CodeGenTypeDef]): Table[string, CodeGenTypeDef] =
  for td in s:
    result[td.name] = td

suite "ARM Example typedefs":
  setup:
    let
      device {.used.} = processSvd("./tests/ARM_Example.svd")
      ctx {.used.} = newCodeGenContext()
      devTypeMap = device.buildTypeMap(ctx)
      deviceTypes = createTypeDefs(device, devTypeMap, ctx).toTable

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
      ctx {.used.} = newCodeGenContext()
      samd21TypeMap = samd21.buildTypeMap(ctx)
      samd21Types = createTypeDefs(samd21, samd21TypeMap, ctx).toTable

  test "Create type defs":
    check:
      samd21Types.len == 446

      # Test with a cluster
      samd21Types["TC3_Type"].members.len == 3
      samd21Types["TC3_Type"].members.mapIt(it.name) == @[
        "COUNT8", "COUNT16", "COUNT32"
      ]
      samd21Types["TC3_Type"].members.mapIt(it.typeName) ==
        @["TcCount8_Type", "TcCount16_Type", "TcCount32_Type"]
      samd21Types["TcCount8_Type"].members.len == 15
      samd21Types["TcCount8_COUNT_Type"].members.len == 1
      samd21Types["TcCount8_COUNT_Type"].members[0].name == "loc"
      samd21Types["TcCount8_COUNT_Type"].members[0].typeName == "uint"

  test "Append and prepend register names":
    let
      ctxNoPre = newCodeGenContext(CodeGenOptions(ignorePrepend: true))
      samd21TypeMapNoPre = samd21.buildTypeMap(ctxNoPre)
      samd21TypesNoPre = samd21.createTypeDefs(samd21TypeMapNoPre, ctxNoPre).toTable

    check:
      samd21Types["AC_Type"].members[0].name == "AC_CTRLA"
      samd21TypesNoPre["AC_Type"].members[0].name == "CTRLA"

  test "Create field enums":
    let
      ctx2 = newCodeGenContext()
      samd21enums =
        createFieldEnums(samd21.peripherals["GCLK".toSvdId], samd21TypeMap, ctx2)
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
      sanitizeIdent("_1INT_CLR") == "x1INT_CLR"

suite "RP2040 enums":
  setup:
    let
      rp2040 {.used.} = processSvd("./tests/RP2040.svd")
      ctx {.used.} = newCodeGenContext()
      rp2040TypeMap = rp2040.buildTypeMap(ctx)

  test "Enumerated values are sorted in increasing order":
    let
      rp2040enums =
        createFieldEnums(rp2040.peripherals["ROSC".toSvdId], rp2040TypeMap, ctx)
      freqEnum = rp2040enums["ROSC_CTRL_FREQ_RANGE"]

    check:
      freqEnum.fields.mapIt(it.val) == @[4004, 4005, 4006, 4007]

suite "Codegen dimIndex and symbol conflicts":
  test "parseDimIndices resolves explicit and ranged indices":
    check:
      parseDimIndices(4, string.none) == @["0", "1", "2", "3"]
      parseDimIndices(4, some("1,2,3,4")) == @["1", "2", "3", "4"]
      parseDimIndices(4, some("1-4")) == @["1", "2", "3", "4"]
      parseDimIndices(3, some("2,3,4")) == @["2", "3", "4"]

  test "conflicting enum values are prefixed":
    var ctx = newCodeGenContext()
    ctx.symbols.incl nimIdentKey("FLASH")
    var en = SvdFieldEnum(values: @[("Flash", 0), ("Other", 1)])
    var field = new SvdField
    field.name = "X"
    field.enumValues = some en
    let cg = createEnum(field, "T", ctx)
    check:
      cg.fields[0].key != "Flash"
