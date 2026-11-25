import std/strformat
import std/strutils
import std/sequtils
import std/algorithm
import std/tables
import std/sets
import std/options
import std/os
import regex

import ../basetypes
import ../utils
import ../cpuirq
import ./model
import ./typemap
import ./generate

const Indent = "  "

proc renderNimImportExports(ctx: CodeGenContext, outf: File) =
  outf.write(
    "# Peripheral access API for $# microcontrollers (generated using svd2nim)\n\n" %
      ctx.dev.metadata.name.toUpper()
  )
  outf.writeLine("import std/volatile")
  outf.writeLine("import std/bitops")
  outf.writeLine("import uncheckedenums")
  outf.write("\n")
  outf.writeLine("export volatile")
  outf.writeLine("export uncheckedenums")
  outf.write("\n")

  # Supress name hints
  outf.write("{.hint[name]: off.}\n\n")

  # Enable overloadable enums for nim v1.x
  outf.write:
    """
    when NimMajor < 2:
      {.experimental: "overloadableEnums".}
    """.dedent.strip
  outf.write "\n\n"

proc renderType(typ: CodeGenTypeDef, tg: File) =
  let
    star = if typ.public: "*" else: ""
    typName = typ.name.sanitizeIdent
  tg.writeLine(fmt"type {typName}{star} = object")
  for f in typ.members:
    let
      fstar = if f.public: "*" else: ""
      fname = f.name.stripPlaceHolder.sanitizeIdent
    tg.writeLine(Indent & fmt"{fName}{fstar}: {f.typeName}")

proc renderRegister(
    reg: SvdRegisterTreeNode,
    typeName: string,
    numIndent: Natural,
    baseAddress: Natural,
    tg: File,
) =
  assert reg.kind == rnkRegister

  if reg.isDimArray:
    tg.write("[\n")
    for arrIndex in 0 ..< (reg.dimGroup.dim.get):
      let address =
        baseAddress + reg.addressOffset + arrIndex * (reg.dimGroup.dimIncrement.get)
      let locIndent = repeat(Indent, numIndent + 1)
      tg.write(fmt"{locIndent}{typeName}(loc: {address:#x})," & "\n")
    tg.write(repeat(Indent, numIndent) & "],\n")
  else:
    let address = baseAddress + reg.addressOffset
    tg.write(fmt"{typeName}(loc: {address:#x}'u)," & "\n")

proc renderCluster(
  ctx: CodeGenContext,
  cluster: SvdRegisterTreeNode,
  numIndent: Natural,
  baseAddress: Natural,
  tg: File,
)

proc renderObjectMembers(
    ctx: CodeGenContext,
    e: SvdRegisterParent,
    baseAddress: Natural,
    numIndent: Natural,
    tg: File,
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
    tg.write(fmt"{locIndent}{fName}: ")

    case c.kind
    of rnkRegister:
      renderRegister(c, typeName, numIndent, baseAddress, tg)
    of rnkCluster:
      ctx.renderCluster(c, numIndent, baseAddress, tg)

proc renderCluster(
    ctx: CodeGenContext,
    cluster: SvdRegisterTreeNode,
    numIndent: Natural,
    baseAddress: Natural,
    tg: File,
) =
  assert cluster.kind == rnkCluster
  let typeName = ctx.typeMap[cluster.id]

  if cluster.isDimArray:
    # TODO: dim array of clusters has not been tested. Find or create SVD snippet
    # using this codepath to test.
    let locIndent = repeat(Indent, numIndent + 1)
    tg.write("[\n")
    for arrIndex in 0 ..< (cluster.dimGroup.dim.get):
      let address =
        baseAddress + cluster.addressOffset +
        arrIndex * (cluster.dimGroup.dimIncrement.get)
      tg.write(fmt"{locIndent}{typeName}(" & "\n")
      ctx.renderObjectMembers(cluster, address, numIndent + 2, tg)
      tg.write(locIndent & "),\n")
    tg.write(repeat(Indent, numIndent) & "],\n")
  else:
    let address = baseAddress + cluster.addressOffset
    tg.write(fmt"{typeName}(" & "\n")
    ctx.renderObjectMembers(cluster, address, numIndent + 1, tg)
    tg.write(repeat(Indent, numIndent) & "),\n")

proc renderPeripheral(ctx: CodeGenContext, periph: SvdPeripheral, tg: File): string =
  let
    insName = periph.name.stripPlaceHolder.sanitizeIdent
    pTypeName = ctx.typeMap[periph.id]

  if periph.isDimArray:
    # TODO: dim array of peripherals has not been tested. Find or create SVD snippet
    # using this codepath to test.
    tg.writeLine(fmt"const {insName}* = [")
    for arrIndex in 0 ..< (periph.dimGroup.dim.get):
      let address = periph.baseAddress + arrIndex * periph.dimGroup.dimIncrement.get
      tg.write(fmt"{Indent}{pTypeName}(" & "\n")
      ctx.renderObjectMembers(periph, address, 2, tg)
      tg.write(Indent & "),\n")
    tg.write(Indent & "],\n\n")
  else:
    tg.writeLine(fmt"const {insName}* = {pTypeName}(")
    ctx.renderObjectMembers(periph, periph.baseAddress, 1, tg)
    tg.write(")\n\n")

  result = insname

proc renderEnum(en: CodeGenEnumDef, tg: File) =
  let
    star = if en.public: "*" else: ""
    pragmaStr =
      if en.pragma.len > 0:
        fmt" {{.{en.pragma}.}}"
      else:
        ""
  tg.writeLine(fmt"type {en.name}{star}{pragmaStr} = enum")
  for (k, v) in en.fields:
    tg.writeLine(fmt"{Indent}{k} = {v:#x},")
  tg.write "\n"

proc renderDistinctTypes(typedefs: seq[CodeGenDistinctDef], tg: File) =
  if typedefs.len == 0:
    return
  tg.writeLine "type"
  for def in typedefs:
    let star = if def.public: "*" else: ""
    tg.writeLine fmt"{Indent}{def.name}{star} = distinct {def.basetype}"
  tg.write("\n")

proc renderProcDef(prd: CodeGenProcDef, tg: File) =
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

  tg.writeLine(fmt"{prd.keyword} {prd.name}{star}({argString}){retString}{pragmaStr} =")
  for line in prd.body.splitLines:
    tg.writeLine Indent & line
  tg.write "\n"

func asSingleLine(s: string): string =
  s.splitLines.mapIt(it.strip).join(" ")

proc renderHeader(text: string, outf: File) =
  outf.write("\n")
  outf.write(repeat("#", 80))
  outf.write("\n")
  outf.write(text)
  outf.write("\n")
  outf.write(repeat("#", 80))
  outf.write("\n")

proc renderInterrupts(ctx: CodeGenContext, outf: File) =
  renderHeader("# Interrupt Number Definition", outf)
  outf.writeLine("type IRQn* = enum")
  let
    cmExcHdr = "# #### CPU Core Exception Numbers "
    devIrqHdr = "# #### Device Peripheral Interrupts "
  template irqHeader(s: string) {.dirty.} =
    outf.writeLine(s & repeat("#", 80 - len(s)))

  # CPU core interupts
  irqHeader cmExcHdr
  let cpuKey = ctx.dev.cpu.name.replace("+", "PLUS")
  if cpuKey in CpuIrqTable:
    let coreInterrupts = CpuIrqTable[cpuKey]
    for cIrq in coreInterrupts:
      let desc = CpuIrqArray[cIrq].description
      outf.writeLine fmt"  {$cIrq:20} = {cIrq.int:4} # {desc}"
  else:
    # Unknown CPU and CPU-specific exceptions
    outf.writeLine "# Unknown CPU, svd2nim could not generate CPU exception numbers\n"

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
    outf.writeLine fmt"  irq{iter.name:17} = {iter.value:4} # {iter.description.asSingleLine}"

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

proc renderDeviceConsts(ctx: var CodeGenContext, outf: File) =
  if not ctx.dev.cpu.isNil:
    outf.write("# Some information about this device.\n")

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
      outf.writeLine fmt"const {k}* = {v}"
      ctx.symbols.incl nimIdentKey(k)

proc renderCoreModule(ctx: CodeGenContext, devFileName: string) =
  const coreBindings = {"core_cm0plus": staticRead("../core/core_cm0plus.nim")}
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
    contents = staticRead ".." / "utils" / modname
  writeFile(joinPath(outFileName.parentDir, modname), contents)

proc renderPeripheralRegTypeDefs(ctx: var CodeGenContext, outf: File) =
  renderHeader("# Type definitions for peripheral registers", outf)
  let typeDefs = ctx.createTypeDefs()
  for t in typeDefs:
    ctx.symbols.incl nimIdentKey(t.name)
    t.renderType(outf)
    outf.writeLine("")

proc renderPeripheralInstances(ctx: var CodeGenContext, outf: File) =
  renderHeader("# Peripheral object instances", outf)
  for periph in ctx.dev.peripherals.values:
    let constName = ctx.renderPeripheral(periph, outf)
    ctx.symbols.incl nimIdentKey(constName)

proc renderPeripheralRegAccessors(ctx: var CodeGenContext, outf: File) =
  ## Use sets to deduplicate generated code types and procs
  renderHeader("# Accessors for peripheral registers", outf)
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
    renderDistinctTypes(typedefs, outf)

    for (name, en) in ctx.createFieldEnums(p).pairs:
      if name in enumDefs:
        continue
      enumDefs.incl name
      ctx.symbols.incl nimIdentKey(en.name)
      renderEnum(en, outf)

    for (name, acc) in ctx.createAccessors(p).pairs:
      if name in accDefs:
        continue
      accDefs.incl name
      renderProcDef(acc, outf)

    for (name, bfacc) in ctx.createBitfieldAccessors(p).pairs:
      if name in accDefs:
        continue
      accDefs.incl name
      renderProcDef(bfacc, outf)

proc renderDevice*(
    dev: SvdDevice,
    dirpath: string,
    ignoreAppend: bool = false,
    ignorePrepend: bool = false,
) =
  var ctx =
    initCodeGenContext(dev, ignoreAppend = ignoreAppend, ignorePrepend = ignorePrepend)
  let outFileName = dirPath / ctx.dev.metadata.name.toLower() & ".nim"
  var outf = open(outFileName, fmWrite)
  defer:
    outf.close()

  renderNimImportExports(ctx, outf)

  ctx.renderDeviceConsts(outf)
  renderInterrupts(ctx, outf)
  renderCoreModule(ctx, outFileName)
  renderUncheckedenums(outFileName)

  ctx.buildTypeMap()

  ctx.renderPeripheralRegTypeDefs(outf)
  ctx.renderPeripheralInstances(outf)
  ctx.renderPeripheralRegAccessors(outf)
