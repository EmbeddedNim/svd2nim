import std/unittest
import std/sequtils
import std/tables
import std/sets
import codegen/internal
import svd2nim
import basetypes
import transformations
import ./utils_for_tests

func toTable(s: seq[CodeGenTypeDef]): Table[string, CodeGenTypeDef] =
  for td in s:
    result[td.name] = td

suite "ARM Example typedefs":
  setup:
    let device {.used.} = processSvd("./tests/ARM_Example.svd")
    var ctx {.used.} = initCodeGenContext(device)
    ctx.buildTypeMap()
    let deviceTypes = ctx.createTypeDefs().toTable

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
    let samd21 {.used.} = processSvd("./tests/ATSAMD21G18A.svd")
    var ctx {.used.} = initCodeGenContext(samd21)
    ctx.buildTypeMap()
    let samd21Types {.used.} = ctx.createTypeDefs().toTable

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
    var ctxNoPre = initCodeGenContext(samd21, ignorePrepend = true)
    ctxNoPre.buildTypeMap()
    let samd21TypesNoPre = ctxNoPre.createTypeDefs().toTable

    check:
      samd21Types["AC_Type"].members[0].name == "AC_CTRLA"
      samd21TypesNoPre["AC_Type"].members[0].name == "CTRLA"

  test "Create field enums":
    let samd21enums = ctx.createFieldEnums(samd21.peripherals["GCLK".toSvdId])

    let
      idEnum = samd21enums.findByName("GCLK_CLKCTRL_ID").get
      genEnum = samd21enums.findByName("GCLK_CLKCTRL_GEN").get

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
  setup:
    let dev {.used.} = new SvdDevice

  test "Sanitize Identifiers":
    check:
      sanitizeIdent("16k") == "x16k" # starts with number
      sanitizeIdent("Trail_Underscore_") == "Trail_Underscore"
      sanitizeIdent("Two__Underscores__") == "Two_Underscores"
      sanitizeIdent("ADDR") == "ADDRx" # is a keyword
      sanitizeIdent("_1INT_CLR") == "x1INT_CLR"

  test "parseDimIndices resolves explicit and ranged indices":
    check:
      parseDimIndices(4, string.none) == @["0", "1", "2", "3"]
      parseDimIndices(4, some("1,2,3,4")) == @["1", "2", "3", "4"]
      parseDimIndices(4, some("1-4")) == @["1", "2", "3", "4"]
      parseDimIndices(3, some("2,3,4")) == @["2", "3", "4"]

  test "conflicting enum values are prefixed":
    var ctx = initCodeGenContext(dev)
    ctx.symbols.incl nimIdentKey("FLASH")

    var field = SvdField(
      name: "X", enumValues: some SvdFieldEnum(id: "T.X".toSvdId, values: @[("Flash", 0), ("Other", 1)])
    )
    let cg = ctx.createEnum(field, "T")
    check:
      cg.fields[0].key != "Flash"

suite "RP2040 enums":
  setup:
    let rp2040 {.used.} = processSvd("./tests/RP2040.svd")
    var ctx {.used.} = initCodeGenContext(rp2040)
    ctx.buildTypeMap()

  test "Enumerated values are sorted in increasing order":
    let
      rp2040enums = ctx.createFieldEnums(rp2040.peripherals["ROSC".toSvdId])
      freqEnum = rp2040enums.findByName("ROSC_CTRL_FREQ_RANGE").get

    check:
      freqEnum.fields.mapIt(it.val) == @[4004, 4005, 4006, 4007]

suite "Derived enum codegen":
  setup:
    let stm32f429 {.used.} = processSvd("./tests/stm32f429.svd")
    var ctx {.used.} = initCodeGenContext(stm32f429)
    ctx.buildTypeMap()

  test "createFieldEnums deduplicates derived enums":
    let enums = ctx.createFieldEnums(stm32f429.peripherals["GPIOK".toSvdId])
    check:
      enums.findByName("GPIOK_MODER_MODER0").isSome
      enums.findByName("GPIOK_MODER_MODER1").isNone
      enums.findByName("GPIOK_MODER_MODER15").isNone

  test "getEnumTypeName uses base field name":
    var field = SvdField(
      name: "MODER1",
      enumValues: some SvdFieldEnum(id: "GPIOK.MODER.MODER0.MODER0".toSvdId)
    )
    check:
      getEnumTypeName(field, "GPIOK_MODER_Type") == "GPIOK_MODER_MODER0"

  test "getEnumTypeName honors headerEnumName":
    var field = SvdField(
      name: "X",
      enumValues: some SvdFieldEnum(id: "R.X".toSvdId, headerEnumName: some "CustomEnum")
    )
    check:
      getEnumTypeName(field, "R_Type") == "CustomEnum"
