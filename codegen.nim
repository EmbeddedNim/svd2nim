import basetypes
import strformat
import strutils
import sequtils
import algorithm
import utils
import tables
import expansions
import regex
import sets

const Indent = "  "

const typeSuffix*  = "_Type"

type TypeDefField* = object
  name*: string
  bitsize*: Option[Natural]
  public*: bool
  typeName*: string

type CodeGenTypeDef* = ref object
  # Nim object type definition
  name*: string
  public*: bool
  fields*: seq[TypeDefField]

type CodeGenEnumDef* = object
  # Nin enum type definition
  name*: string
  public*: bool
  fields*: seq[tuple[key: string, val: int]]

type CodeGenProcDef* = object
  keyword*: string
  name*: string
  public*: bool
  args*: seq[tuple[name: string, typ: string]]
  retType*: Option[string]
  body*: string

func appendTypeName*(parentName: string, name: string): string =
  if parentName.endsWith(typeSuffix):
    result = parentName[0 .. ^(typeSuffix.len+1)]
  else:
    result = parentName
  result = result & "_" & name

func buildTypeName*(p: SvdPeripheral): string =
  if p.dimGroup.dimName.isSome:
    result = p.dimGroup.dimName.get
  elif p.headerStructName.isSome:
    result = p.headerStructName.get
  else:
    result = p.name.stripPlaceHolder
  result = result & typeSuffix

func buildTypeName*(c: SvdCluster, parentTypeName: string): string =
  if c.dimGroup.dimName.isSome:
    result = c.dimGroup.dimName.get
  elif c.headerStructName.isSome:
    result = c.headerStructName.get
  else:
    result = appendTypeName(parentTypeName, c.name.stripPlaceHolder)
  result = result & typeSuffix

func intName(r: SvdRegister): string = "uint" & $r.properties.size

func getTypeFields(n: SvdEntity, children: seq[SvdEntity]): seq[TypeDefField] =
  case n.kind:
  of {sePeripheral, seCluster}:
    for cNode in children.sorted(cmpAddrOffset):
      let typeName =
        if cNode.isDimArray:
          let dim = cNode.getDimGroup.dim.get
          fmt"array[{dim}, {cNode.getNimTypeName}]"
        else:
          cNode.getNimTypeName

      result.add TypeDefField(
        name: cNode.getName,
        public: true,
        typeName: typeName,
      )
  of seRegister:
    # Registers have a single (private) field, the pointer
    result.add TypeDefField(
      name: "p",
      public: false,
      typeName: "ptr " & n.register.intName
    )

func createTypeDefs*(dev: SvdDevice): OrderedTable[string, CodeGenTypeDef] =
  # Note: returns type definitions in the REVERSE order that they should be written
  let
    graph = dev.peripherals.buildEntityGraph()
    periphNodes = toSeq(graph.items).filterIt(it.kind == sePeripheral)

  for pNode in periphNodes:
    for n in graph.dfs(pNode):
      let
        tname = n.getNimTypeName
        children = toSeq(graph.edges(n))
      if tname notin result:
        result[tname] = CodeGenTypeDef(
          name: tname,
          public: false,
          fields: n.getTypeFields(children)
        )

func size(f: SvdField): Natural =
  f.bitRange.msb - f.bitRange.lsb + 1

func nextIntSize(bitSize: (0..64)): Natural =
  for i in [8, 16, 32, 64]:
    if i >= bitsize: return i

func bitRangeTypeString(bitSize: int): string =
  let
    intSize = nextIntSize(bitSize)
    suffix = "u" & $intSize
    hi = (1 shl bitSize) - 1
  fmt"0{suffix} .. {hi}{suffix}"

proc cmpLsb(a, b: SvdField): int =
  cmp(a.bitRange.lsb, b.bitRange.lsb)

func padFields(fields: seq[SvdField], regSize: Natural): seq[SvdField] =
  # Create RESERVED fields for padding bitfield enums
  let tmp = fields.sorted(cmpLsb)
  var
    prevMsb = -1
    rsvCount = 0
  for fd in tmp:
    let curLsb = fd.bitRange.lsb
    if curLsb > prevMsb + 1:
      result.add SvdField(
        name: "RESERVED" & (if rsvCount == 0: "" else: $rsvCount),
        bitRange: (lsb: (prevMsb+1).Natural, msb: (curLsb-1).Natural),
      )
      inc rsvCount
    prevMsb = fd.bitRange.msb
    result.add fd
  if prevMsb < (regSize - 1):
    # pad end of register
    result.add SvdField(
      name: "RESERVED" & (if rsvCount == 0: "" else: $rsvCount),
      bitRange: (lsb: (prevMsb+1).Natural, msb: (regSize-1).Natural),
    )

func hasFields(r: SvdRegister): bool =
  # If defines a single field of the same size as the register, then
  # consider that there is no field.
  r.fields.len > 0 and
  not (r.fields.len == 1 and r.fields[0].size == r.properties.size)

func getFieldStructName(reg: SvdRegister): string =
  reg.nimTypeName.appendTypeName("Fields")

func createBitFieldStructs*(p: SvdPeripheral): OrderedTable[string, CodeGenTypeDef] =
  for reg in p.allRegisters:
    if not reg.hasFields(): continue # Don't emit struct def if no fields
    var td = CodeGenTypeDef(
      name: reg.getFieldStructName,
      public: true
    )
    for field in reg.fields.padFields(reg.properties.size):
      td.fields.add TypeDefField(
        name: field.name,
        bitsize: field.size.some,
        public: not field.name.startsWith("RESERVED"),
        typeName: if field.size == 1: "bool" else: bitRangeTypeString(field.size)
      )
    result[td.name] = td

func createFieldEnums*(p: SvdPeripheral): OrderedTable[string, CodeGenEnumDef] =
  for reg in p.allRegisters:
    for field in reg.fields:
      if field.enumValues.isNone: continue
      let svdEnum = field.enumValues.get
      var en: CodeGenEnumDef
      en.public = true
      en.name =
        if svdEnum.headerEnumName.isSome:
          svdEnum.headerEnumName.get
        else:
          appendTypeName(reg.nimTypeName, field.name)

      for (k, v) in svdEnum.values:
        en.fields.add (key: k.sanitizeIdent, val: v)
      # TODO: If enum already in table, validate that it is identical
      result[en.name] = en

func createAccessors*(p: SvdPeripheral): OrderedTable[string, CodeGenProcDef] =
  for reg in p.allRegisters:
    let intname = "uint" & $reg.properties.size
    let valType =
      if reg.hasFields:
        reg.getFieldStructName
      else:
        intname

    if reg.isReadable:
      var readTpl = CodeGenProcDef(
        keyword: "template",
        name: "read",
        public: true,
        args: @[("reg", reg.nimTypeName)],
        retType: valType.some,
      )
      readTpl.body =
        if reg.hasFields:
          fmt"cast[{valType}](volatileLoad(reg.p))"
        else:
          "volatileLoad(reg.p)"
      result[fmt"read[{reg.nimTypeName}]"] = readTpl

    if reg.isWritable:
      var writeTpl = CodeGenProcDef(
        keyword: "template",
        name: "write",
        public: true,
        args: @[
          ("reg", reg.nimTypeName),
          ("val", valType),
        ],
      )
      writeTpl.body =
        if reg.hasFields:
          fmt"volatileStore(reg.p, cast[{intname}](val))"
        else:
          "volatileStore(reg.p, val)"

      result[fmt"write[{reg.nimTypeName}]"] = writeTpl

proc renderType*(typ: CodeGenTypeDef, tg: File) =
  let
    star = if typ.public: "*" else: ""
    typName = typ.name.sanitizeIdent
  tg.writeLine(fmt"type {typName}{star} = object")
  for f in typ.fields:
    let
      fstar = if f.public: "*" else: ""
      fname = f.name.stripPlaceHolder.sanitizeIdent
      prag = if f.bitsize.isSome: fmt" {{.bitsize:{f.bitsize.get}.}}" else: ""
    tg.writeLine(Indent & fmt"{fName}{fstar}{prag}: {f.typeName}")

proc renderRegister(
  r: SvdRegister,
  numIndent: Natural,
  baseAddress: Natural,
  tg: File) =

  let intName = "uint" & $r.properties.size

  if r.isDimArray:
    tg.write("[\n")
    for arrIndex in 0 ..< (r.dimGroup.dim.get):
      let address = baseAddress +
                    r.addressOffset +
                    arrIndex * (r.dimGroup.dimIncrement.get)
      let locIndent = repeat(Indent, numIndent + 1)
      tg.write(fmt"{locIndent}{r.nimTypeName}(p: cast[ptr {intName}]({address:#x}))," & "\n")
    tg.write(repeat(Indent, numIndent) & "]\n")
  else:
    let address = baseAddress + r.addressOffset
    tg.write(fmt"{r.nimTypeName}(p: cast[ptr {intName}]({address:#x}))," & "\n")

proc renderCluster(
  cluster: SvdCluster,
  numIndent: Natural,
  baseAddress: Natural,
  tg: File)

proc renderFields[T: SvdCluster | SvdPeripheral](
  p: T,
  baseAddress: Natural,
  numIndent: Natural,
  tg: File) =

  let fields = block:
    var fields: seq[SvdEntity]
    for c in p.clusters: fields.add c.toEntity(p.name)
    for r in p.registers: fields.add r.toEntity(p.name)
    fields.sort(cmpAddrOffset)
    fields

  let locIndent = repeat(Indent, numIndent)

  for f in fields:
    let fName = f.getName.stripPlaceHolder.sanitizeIdent
    tg.write(fmt"{locIndent}{fName}: ")

    case f.kind:
    of seRegister:
      renderRegister(f.register, numIndent, baseAddress, tg)
    of seCluster:
      renderCluster(f.cluster, numIndent, baseAddress, tg)
    of sePeripheral:
      doAssert false

proc renderCluster(
  cluster: SvdCluster,
  numIndent: Natural,
  baseAddress: Natural,
  tg: File) =

  if cluster.isDimArray:
    # TODO: dim array of clusters has not been tested. Find or create SVD snippet
    # using this codepath to test.
    let locIndent = repeat(Indent, numIndent + 1)
    tg.write("[\n")
    for arrIndex in 0 ..< (cluster.dimGroup.dim.get):
      let address = baseAddress +
                    cluster.addressOffset +
                    arrIndex * (cluster.dimGroup.dimIncrement.get)
      tg.write(fmt"{locIndent}{cluster.nimTypeName}(" & "\n")
      renderFields(cluster, address, numIndent+2, tg)
      tg.write(locIndent & "),\n")
    tg.write(repeat(Indent, numIndent) & "]\n")
  else:
    let
      address = baseAddress + cluster.addressOffset
    tg.write(fmt"{cluster.nimTypeName}(" & "\n")
    renderFields(cluster, address, numIndent+1, tg)
    tg.write(repeat(Indent, numIndent) & "),\n")

proc renderPeripheral*(p: SvdPeripheral, tg: File) =
  let insName = p.name.stripPlaceHolder.sanitizeIdent

  if p.isDimArray:
    # TODO: dim array of peripherals has not been tested. Find or create SVD snippet
    # using this codepath to test.
    tg.writeLine(fmt"let {insName}* = [")
    for arrIndex in 0 ..< (p.dimGroup.dim.get):
      let address = p.baseAddress + arrIndex * p.dimGroup.dimIncrement.get
      tg.write(fmt"{Indent}{p.nimTypeName}(" & "\n")
      renderFields(p, address, 2, tg)
      tg.write(Indent & "),\n")
    tg.write(Indent & "]\n\n")
  else:
    tg.writeLine(fmt"let {insName}* = {p.nimTypeName}(")
    renderFields(p, p.baseAddress, 1, tg)
    tg.write(")\n\n")

proc renderEnum*(en: CodeGenEnumDef, tg: File) =
  let star = if en.public: "*" else: ""
  tg.writeLine(fmt"type {en.name}{star} {{.pure.}} = enum")
  for (k, v) in en.fields:
    tg.writeLine(fmt"{Indent}{k} = {v:#x},")
  tg.write "\n"

proc renderProcDef*(prd: CodeGenProcDef, tg: File) =
  let
    argString = prd.args.mapIt(it.name & ": " & it.typ).join(", ")
    retString = if prd.retType.isSome: ": " & prd.retType.get else: ""
    star = if prd.public: "*" else: ""
  tg.writeLine(fmt"{prd.keyword} {prd.name}{star}({argString}){retString} = ")
  for line in prd.body.splitLines:
    tg.writeLine Indent & line
  tg.write "\n"

proc renderHeader(text: string, outf: File) =
  outf.write("\n")
  outf.write(repeat("#",80))
  outf.write("\n")
  outf.write(text)
  outf.write("\n")
  outf.write(repeat("#",80))
  outf.write("\n")

proc renderCortexMExceptionNumbers(cpu: SvdCpu, outf: File) =
  type exception = object
    name: string
    value: int
    description: string

  let exceptions: seq[exception] = @[
    exception(name: "NonMaskableInt", value: -14, description: "Exception 2: Non Maskable Interrupt"),
    exception(name: "HardFault", value: -13, description: "Exception 3: Hard fault Interrupt"),
    exception(name: "MemoryManagement", value: -12, description: "Exception 4: Memory Management Interrupt [Not on Cortex M0 variants]"),
    exception(name: "BusFault", value: -11, description: "Exception 5: Bus Fault Interrupt [Not on Cortex M0 variants]"),
    exception(name: "UsageFault", value: -10, description: "Exception 6: Usage Fault Interrupt [Not on Cortex M0 variants]"),
    exception(name: "SecureFault", value: -9, description: "Exception 7: Secure Fault Interrupt [Only on Armv8-M]"),
    exception(name: "SVCall", value: -5, description: "Exception 11: SV Call Interrupt"),
    exception(name: "DebugMonitor", value: -4, description: "Exception 12: Debug Monitor Interrupt [Not on Cortex M0 variants]"),
    exception(name: "PendSV", value: -2, description: "Exception 14: Pend SV Interrupt [Not on Cortex M0 variants]"),
    exception(name: "SysTick", value: -1, description: "Exception 15: System Tick Interrupt"),
    exception(name: "WWDG", value: 0, description: "Window WatchDog Interrupt"),
    exception(name: "PVD", value: 1, description: "PVD through EXTI Line detection Interrupt")
  ]
  # Render
  renderHeader("# Interrupt Number Definition", outf)
  outf.write("type IRQn* = enum\n")
  var hdr = "# #### Cortex-M Processor Exception Numbers "
  outf.write(hdr & repeat("#", 80-len(hdr)) & "\n")
  for excep in exceptions:
    if cpu.name.toUpper() in ["CM0","CM0+"]:
      if excep.value in [-12,-11,-10,-9,-4]:
        continue
    else:
      if excep.value in [-9]:
        continue
    if excep.value == 0:
      hdr = "# #### Device specific Interrupt numbers "
      outf.write(hdr & repeat("#", 80-len(hdr)) & "\n")
    var itername = "  $#_IRQn = $#," % [excep.name, excep.value.intToStr()]
    outf.write(itername)
    outf.write(repeat(" ", 40-len(itername)))
    outf.write("# $#\n" % excep.description)

func getInterrupts(dev: SvdDevice): seq[SvdInterrupt] =
  # Get interrupts from all periphs
  dev.peripherals
    .mapIt(it.interrupts)
    .foldl(a & b)
    .sortedByIt(it.value)

proc renderInterrupts(dev: SvdDevice, outf: File) =
  var maxIrq = 0
  # Find all interrupts
  for iter in dev.getInterrupts:
    if maxIrq < iter.value:
      maxIrq = iter.value
    if iter.value <= 1:
      continue
    var itername = format("  $#_IRQn = $#, " % [iter.name.toUpper, iter.value.intToStr()])
    outf.write(itername)
    outf.write(repeat(" ", 60-len(itername)))
    if iter.description.isSome:
      outf.write("# $#" % iter.description.get)
    outf.write("\n")

proc renderDevice*(d: SvdDevice, outf: File) =
  outf.write("# Peripheral access API for $# microcontrollers (generated using svd2nim)\n\n" % d.metadata.name.toUpper())
  outf.write("import volatile\n\n")

  if not d.cpu.isNil():
    outf.write("# Some information about this device.\n")
    outf.write("const DEVICE* = \"$#\"\n" % d.metadata.name)
  # CPU
    let cpuNameSan = d.cpu.name.replace(re"(M\d+)\+", "$1PLUS")
    outf.write("const $#_REV* = 0x0001\n" % cpuNameSan)
    outf.write("const MPU_PRESENT* = $#\n" % d.cpu.mpuPresent.intToStr())
    outf.write("const FPU_PRESENT* = $#\n" % d.cpu.fpuPresent.intToStr())
    outf.write("const NVIC_PRIO_BITS* = $#\n" % d.cpu.nvicPrioBits.intToStr())
    outf.write("const Vendor_SysTickConfig* = $#\n" % d.cpu.vendorSystickConfig.intToStr())

  renderCortexMExceptionNumbers(d.cpu, outf)
  renderInterrupts(d, outf)

  renderHeader("# Type definitions for peripheral registers", outf)
  let typeDefs = d.createTypeDefs()
  for t in toSeq(typeDefs.values).reversed:
    t.renderType(outf)
    outf.writeLine("")

  renderHeader("# Peripheral object instances", outf)
  for periph in d.peripherals:
    renderPeripheral(periph, outf)

  renderHeader("# Accessors for peripheral registers", outf)
  # Create hash sets so we don't duplicate typedefs or accessor templates
  # They are already deduplicated within a periph by the create* procs, but
  # duplicates can still be created from another periph, eg when perriphs
  # are derivedFrom or dimlists.
  var
    fieldStructTypes: HashSet[string]
    fieldEnumTypes: HashSet[string]
    accessors: HashSet[string]

  for periph in d.peripherals:
    for (k, objDef) in periph.createBitFieldStructs.pairs:
      if k notin fieldStructTypes:
        fieldStructTypes.incl k
        renderType(objDef, outf)
        outf.write("\n")
    for (k, en) in periph.createFieldEnums.pairs:
      if k notin fieldEnumTypes:
        fieldEnumTypes.incl k
        renderEnum(en, outf)
    for (k, acc) in periph.createAccessors.pairs:
      if k notin accessors:
        accessors.incl k
        renderProcDef(acc, outf)
