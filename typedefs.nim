# Generate object type definitions to be written in nim code output
import basetypes
import entities
import sequtils
import tables
import algorithm
import strformat
import strutils
import utils

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
