import std/strformat
import std/strutils
import std/sequtils
import std/algorithm
import std/tables
import std/sets
import std/options
import std/os
import std/streams
import regex

import ../basetypes
import ../utils
import ../cpuirq
import ./model
import ./typemap
import ./generate

const Indent = "  "

template w(s: string): untyped =
  mixin ctx
  ctx.output.write s

template wl(s: string): untyped =
  mixin ctx
  ctx.output.writeLine s

proc renderNimImportExports(ctx: CodeGenContext) =
  w "# Peripheral access API for $# microcontrollers (generated using svd2nim)\n\n" %
    ctx.dev.metadata.name.toUpper()
  wl "import std/volatile"
  wl "import std/bitops"
  wl "import uncheckedenums"
  w "\n"
  wl "export volatile"
  wl "export uncheckedenums"
  w "\n"

  # Supress name hints
  w "{.hint[name]: off.}\n\n"

  # Enable overloadable enums for nim v1.x
  w:
    """
    when NimMajor < 2:
      {.experimental: "overloadableEnums".}
    """.dedent.strip
  w "\n\n"

proc renderType(ctx: CodeGenContext, typ: CodeGenTypeDef) =
  let
    star = if typ.public: "*" else: ""
    typName = typ.name.sanitizeIdent
  wl fmt"type {typName}{star} = object"
  for f in typ.members:
    let
      fstar = if f.public: "*" else: ""
      fname = f.name.stripPlaceHolder.sanitizeIdent
    wl Indent & fmt"{fName}{fstar}: {f.typeName}"

proc renderRegister(
    ctx: CodeGenContext,
    reg: SvdRegisterTreeNode,
    typeName: string,
    numIndent: Natural,
    baseAddress: Natural,
) =
  assert reg.kind == rnkRegister

  if reg.isDimArray:
    w "[\n"
    for arrIndex in 0 ..< (reg.dimGroup.dim.get):
      let address =
        baseAddress + reg.addressOffset + arrIndex * (reg.dimGroup.dimIncrement.get)
      let locIndent = repeat(Indent, numIndent + 1)
      w fmt"{locIndent}{typeName}(loc: {address:#x})," & "\n"
    w repeat(Indent, numIndent) & "],\n"
  else:
    let address = baseAddress + reg.addressOffset
    w fmt"{typeName}(loc: {address:#x}'u)," & "\n"

proc renderCluster(
  ctx: CodeGenContext,
  cluster: SvdRegisterTreeNode,
  numIndent: Natural,
  baseAddress: Natural,
)

proc renderObjectMembers(
    ctx: CodeGenContext, e: SvdRegisterParent, baseAddress: Natural, numIndent: Natural
) =
  when typeof(e) is SvdRegisterTreeNode:
    assert e.kind == rnkCluster

  let children = block:
    var c = toSeq e.iterRegisters
    c.sort cmpAddrOffset
    c

  let locIndent = repeat(Indent, numIndent)

  for c in children:
    let
      fName = ctx.getObjectMemberName(c)
      typeName = ctx.typeMap[c.id]
    w fmt"{locIndent}{fName}: "

    case c.kind
    of rnkRegister:
      ctx.renderRegister(c, typeName, numIndent, baseAddress)
    of rnkCluster:
      ctx.renderCluster(c, numIndent, baseAddress)

proc renderCluster(
    ctx: CodeGenContext,
    cluster: SvdRegisterTreeNode,
    numIndent: Natural,
    baseAddress: Natural,
) =
  assert cluster.kind == rnkCluster
  let typeName = ctx.typeMap[cluster.id]

  if cluster.isDimArray:
    # TODO: dim array of clusters has not been tested. Find or create SVD snippet
    # using this codepath to test.
    let locIndent = repeat(Indent, numIndent + 1)
    w "[\n"
    for arrIndex in 0 ..< (cluster.dimGroup.dim.get):
      let address =
        baseAddress + cluster.addressOffset +
        arrIndex * (cluster.dimGroup.dimIncrement.get)
      w fmt"{locIndent}{typeName}(" & "\n"
      ctx.renderObjectMembers(cluster, address, numIndent + 2)
      w locIndent & ",\n"
    w repeat(Indent, numIndent) & "],\n"
  else:
    let address = baseAddress + cluster.addressOffset
    w fmt"{typeName}(" & "\n"
    ctx.renderObjectMembers(cluster, address, numIndent + 1)
    w repeat(Indent, numIndent) & "),\n"

proc renderPeripheral(ctx: CodeGenContext, periph: SvdPeripheral): string =
  let
    insName = periph.name.stripPlaceHolder.sanitizeIdent
    pTypeName = ctx.typeMap[periph.id]

  if periph.isDimArray:
    # TODO: dim array of peripherals has not been tested. Find or create SVD snippet
    # using this codepath to test.
    wl fmt"const {insName}* = ["
    for arrIndex in 0 ..< (periph.dimGroup.dim.get):
      let address = periph.baseAddress + arrIndex * periph.dimGroup.dimIncrement.get
      w fmt"{Indent}{pTypeName}(" & "\n"
      ctx.renderObjectMembers(periph, address, 2)
      w Indent & "),\n"
    w Indent & "],\n\n"
  else:
    wl fmt"const {insName}* = {pTypeName}("
    ctx.renderObjectMembers(periph, periph.baseAddress, 1)
    w ")\n\n"

  result = insname

proc renderEnum(ctx: CodeGenContext, en: CodeGenEnumDef) =
  let
    star = if en.public: "*" else: ""
    pragmaStr =
      if en.pragma.len > 0:
        fmt" {{.{en.pragma}.}}"
      else:
        ""
  wl fmt"type {en.name}{star}{pragmaStr} = enum"
  for (k, v) in en.fields:
    wl fmt"{Indent}{k} = {v:#x},"
  w "\n"

proc renderDistinctTypes(ctx: CodeGenContext, typedefs: seq[CodeGenDistinctDef]) =
  if typedefs.len == 0:
    return
  wl "type"
  for def in typedefs:
    let star = if def.public: "*" else: ""
    wl fmt"{Indent}{def.name}{star} = distinct {def.basetype}"
  w "\n"

proc renderProcDef(ctx: CodeGenContext, prd: CodeGenProcDef) =
  let
    retString =
      if prd.retType.len > 0:
        ": " & prd.retType
      else:
        ""
    star = if prd.public: "*" else: ""
    pragmaStr =
      if prd.pragma.len > 0:
        " {." & prd.pragma.join(", ") & ".}"
      else:
        ""

  var argStringSeq: seq[string]
  for argObj in prd.args:
    let defValStr =
      if argObj.defaultVal.isNone:
        ""
      else:
        " = " & argObj.defaultVal.get
    argStringSeq.add fmt"{argObj.name}: {argObj.typ}{defValStr}"
  let argString = argStringSeq.join ", "

  wl fmt"{prd.keyword} {prd.name}{star}({argString}){retString}{pragmaStr} ="
  for line in prd.body.splitLines:
    wl Indent & line
  w "\n"

func asSingleLine(s: string): string =
  s.splitLines.mapIt(it.strip).join(" ")

proc renderHeader(ctx: CodeGenContext, text: string) =
  w "\n"
  w repeat("#", 80)
  w "\n"
  w text
  w "\n"
  w repeat("#", 80)
  w "\n"

proc renderInterrupts(ctx: CodeGenContext) =
  renderHeader(ctx, "# Interrupt Number Definition")
  wl "type IRQn* = enum"
  let
    cmExcHdr = "# #### CPU Core Exception Numbers "
    devIrqHdr = "# #### Device Peripheral Interrupts "
  template irqHeader(s: string) {.dirty.} =
    wl s & repeat("#", 80 - len(s))

  # CPU core interupts
  irqHeader cmExcHdr
  let cpuKey = ctx.dev.cpu.name.replace("+", "PLUS")
  if cpuKey in CpuIrqTable:
    let coreInterrupts = CpuIrqTable[cpuKey]
    for cIrq in coreInterrupts:
      let desc = CpuIrqArray[cIrq].description
      wl fmt"  {$cIrq:20} = {cIrq.int:4} # {desc}"
  else:
    # Unknown CPU and CPU-specific exceptions
    wl "# Unknown CPU, svd2nim could not generate CPU exception numbers\n"

  # Peripheral interrupts
  irqHeader devIrqHdr
  let interrupts = toSeq(ctx.dev.peripherals.values)
    .mapIt(it.interrupts)
    .foldl(a & b)
    .sortedByIt(it.value)
  for (i, iter) in interrupts.pairs:
    if i > 0 and iter.value == interrupts[i - 1].value:
      # Skip duplicated interrupts
      continue
    wl fmt"  irq{iter.name:17} = {iter.value:4} # {iter.description.asSingleLine}"

func convertCpuRevision(text: string): uint =
  # Based on:
  # https://github.com/Open-CMSIS-Pack/devtools/blob/259aa1f6755bd96497acdf403a008a4ba4cb2d66/tools/svdconv/SVDModel/src/SvdUtils.cpp#L246
  let pat = re2"r(\d+)p(\d+)"
  let revText = text.toLowerAscii
  var m: RegexMatch2
  doAssert revText.match(pat, m)
  let
    major = revText[m.group(0)].parseUInt
    minor = revText[m.group(1)].parseUInt
  result = (major shl 8) or (minor)

func quoted(s: string): string =
  '"' & s & '"'

proc renderDeviceConsts(ctx: var CodeGenContext) =
  if not ctx.dev.cpu.isNil:
    w "# Some information about this device.\n"

    let
      cpuNameSan = ctx.dev.cpu.name.replace(re2"(M\d+)\+", "$1PLUS").sanitizeIdent
      cpuConsts = {
        "DEVICE": quoted(ctx.dev.metadata.name),
        fmt"{cpuNameSan}_REV": fmt"{convertCpuRevision(ctx.dev.cpu.revision):#06x}",
        "MPU_PRESENT": $ctx.dev.cpu.mpuPresent,
        "FPU_PRESENT": $ctx.dev.cpu.fpuPresent,
        "VTOR_PRESENT": $ctx.dev.cpu.vtorPresent,
        "NVIC_PRIO_BITS": $ctx.dev.cpu.nvicPrioBits,
        "Vendor_SysTickConfig": $ctx.dev.cpu.vendorSystickConfig,
      }

    for (k, v) in cpuConsts:
      wl fmt"const {k}* = {v}"
      ctx.symbols.incl nimIdentKey(k)

proc renderCoreModule(ctx: CodeGenContext, devFileName: string) =
  const coreBindings = {"core_cm0plus": staticRead("../../core/core_cm0plus.nim")}
  # TODO: core module for other CPUs
    .toTable

  let coreFile =
    case ctx.dev.cpu.name
    of "CM0+": "core_cm0plus"
    of "CM0P": "core_cm0plus"
    of "CM0PLUS": "core_cm0plus"
    else: ""

  if coreFile.len == 0:
    warn fmt"Core header bindings not implemented for CPU ""{ctx.dev.cpu.name}""."
    return

  let (dirPath, devModule, _) = splitFile devFileName

  # Import the generated device module in the core module
  let templated = coreBindings[coreFile].replace("{{DEVICE_MODULE}}", devModule)

  writeFile(joinPath(dirPath, coreFile & ".nim"), templated)

proc renderUncheckedenums(outFileName: string) =
  const
    modname = "uncheckedenums.nim"
    contents = staticRead "../../utils" / modname
  writeFile(joinPath(outFileName.parentDir, modname), contents)

proc renderPeripheralRegTypeDefs(ctx: var CodeGenContext) =
  renderHeader(ctx, "# Type definitions for peripheral registers")
  let typeDefs = ctx.createTypeDefs()
  for t in typeDefs:
    ctx.symbols.incl nimIdentKey(t.name)
    ctx.renderType(t)
    wl ""

proc renderPeripheralInstances(ctx: var CodeGenContext) =
  renderHeader(ctx, "# Peripheral object instances")
  for periph in ctx.dev.peripherals.values:
    let constName = ctx.renderPeripheral(periph)
    ctx.symbols.incl nimIdentKey(constName)

proc renderPeripheralRegAccessors(ctx: var CodeGenContext) =
  ## Use sets to deduplicate generated code types and procs
  renderHeader(ctx, "# Accessors for peripheral registers")
  var
    fieldDistinctDefs: HashSet[string]
    enumDefs: HashSet[string]
    accDefs: HashSet[string]

  for p in ctx.dev.peripherals.values:
    var typedefs: seq[CodeGenDistinctDef]
    for (name, def) in ctx.createBitfieldTypes(p).pairs:
      if name in fieldDistinctDefs:
        continue
      fieldDistinctDefs.incl name
      ctx.symbols.incl nimIdentKey(name)
      typedefs.add def
    ctx.renderDistinctTypes(typedefs)

    for (name, en) in ctx.createFieldEnums(p).pairs:
      if name in enumDefs:
        continue
      enumDefs.incl name
      ctx.symbols.incl nimIdentKey(en.name)
      ctx.renderEnum(en)

    for (name, acc) in ctx.createAccessors(p).pairs:
      if name in accDefs:
        continue
      accDefs.incl name
      ctx.renderProcDef(acc)

    for (name, bfacc) in ctx.createBitfieldAccessors(p).pairs:
      if name in accDefs:
        continue
      accDefs.incl name
      ctx.renderProcDef(bfacc)

proc renderDevice*(
    dev: SvdDevice,
    dirpath: string,
    ignoreAppend: bool = false,
    ignorePrepend: bool = false,
) =
  var ctx =
    initCodeGenContext(dev, ignoreAppend = ignoreAppend, ignorePrepend = ignorePrepend)
  let outFileName = dirPath / ctx.dev.metadata.name.toLower() & ".nim"
  var stream = newFileStream(outFileName, fmWrite)
  ctx.output = stream
  defer:
    stream.close()

  renderNimImportExports(ctx)

  ctx.renderDeviceConsts()
  renderInterrupts(ctx)
  renderCoreModule(ctx, outFileName)
  renderUncheckedenums(outFileName)

  ctx.buildTypeMap()

  ctx.renderPeripheralRegTypeDefs()
  ctx.renderPeripheralInstances()
  ctx.renderPeripheralRegAccessors()
