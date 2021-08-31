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

func appendTypeName*(parentName: string, name: string): string =
  if parentName.endsWith(typeSuffix):
    result = result & parentName[0 .. ^(typeSuffix.len+1)]
  else:
    result = result & parentName
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

func getTypeFields(
  n: SvdEntity,
  children: seq[SvdEntity],
  rp: SvdRegisterProperties): seq[TypeDefField] =

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
      typeName: "ptr uint" & $rp.size.get
    )

func createTypeDefs*(dev: SvdDevice): OrderedTable[string, CodeGenTypeDef] =
  # Note: returns type definitions in the REVERSE order that they should be written
  let
    graph = dev.peripherals.buildEntityGraph()
    periphNodes = toSeq(graph.items).filterIt(it.kind == sePeripheral)

  # Do DFS and pass down RegisterProperties of parents so that they can
  # be inherited by child registers
  var stack: seq[(SvdEntity, SvdRegisterProperties)]
  for pNode in periphNodes:
    stack.add (
      pNode,
      dev.registerProperties.updateProperties(pNode.periph.registerProperties)
    )

  while stack.len > 0:
    let
      (n, rp) = stack.pop
      newRp = rp.updateProperties(n.getRegisterProperties)
      children = toSeq(graph.edges(n))
      tname = n.getNimTypeName

    if tname notin result:
      result[tname] = CodeGenTypeDef(
        name: tname,
        public: false,
        fields: n.getTypeFields(children, newRp)
      )

    for c in children:
      stack.add (c, newRp)

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

      let pos = field.bitRange.lsb
      for (k, v) in svdEnum.values:
        en.fields.add (key: k, val: (v shl pos))
      # TODO: If enum already in table, validate that it is identical
      result[en.name] = en
