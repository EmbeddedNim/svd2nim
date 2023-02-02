import std/tables
import std/sequtils
import std/strutils
import std/options
import std/algorithm
import std/strformat

import ./basetypes
import ./utils


func copyEnum(en: SvdFieldEnum, newParent: SvdId): SvdFieldEnum =
  new result
  result[] = en[]
  result.id = newParent / en.id.name


func copyField(field: SvdField, newParent: SvdId): SvdField =
  new result
  result[] = field[]
  result.id = newParent / field.id.name
  if result.enumValues.isSome:
    result.enumValues = some result.enumValues.get.copyEnum(result.id)


func copySubtree(node: SvdRegisterTreeNode, newParent: SvdId): SvdRegisterTreeNode =
  new result
  result[] = node[]
  result.id = newParent / result.name
  if result.typeBase.isNone:
    result.typeBase = some node.id
  case result.kind
  of rnkCluster:
    if result.registers.isSome:
      result.registers = some result.registers.get.mapIt(
        copySubtree(it, result.id)
      )
  of rnkRegister:
    result.fields = result.fields.mapIt(it.copyField(result.id))


func derivePeripheral*(p: var SvdPeripheral, base: SvdPeripheral) =
  if p.prependToName.isNone: p.prependToName = base.prependToName
  if p.appendToName.isNone: p.appendToName = base.appendToName
  if p.headerStructName.isNone: p.headerStructName = base.headerStructName
  p.dimGroup = update(base.dimGroup, p.dimGroup)
  p.properties = update(base.properties, p.properties)

  if p.registers.isNone and
      p.headerStructName == base.headerStructName and
      p.properties == base.properties:
    p.typeBase = some base.id

  if p.registers.isNone and base.registers.isSome:
    let regs = base.registers.get.mapIt(copySubtree(it, p.id))
    p.registers = some regs


func deriveRegisterTreeNode*(n: var SvdRegisterTreeNode, base: SvdRegisterTreeNode) =
  assert base.kind == n.kind
  n.dimGroup = update(base.dimGroup, n.dimGroup)
  n.properties = update(base.properties, n.properties)

  case n.kind:
  of rnkCluster:
    if n.headerStructName.isNone:
      n.headerStructName = base.headerStructName

    if n.registers.isNone and
        n.headerStructName == base.headerStructName and
        n.properties == base.properties:
      n.typeBase = some base.id

    if n.registers.isNone and base.registers.isSome:
      let regs = base.registers.get.mapIt(copySubtree(it, n.id))
      n.registers = some regs

  of rnkRegister:
    if n.fields.len == 0 and n.properties == base.properties:
      n.typeBase = some base.id
    if n.fields.len == 0:
      #TODO: Make fields Option so derives can override with no fields
      n.fields = base.fields.mapIt(copyField(it, n.id))


func derivedBaseId[T: SomeSvdId](x: T): SvdId =
  if '.' in x.derivedFrom.get:
    x.derivedFrom.get.toSvdId
  else:
    x.id.parent / x.derivedFrom.get


func buildRegisterNodeIndex(dev: SvdDevice): Table[SvdId, SvdRegisterTreeNode] =
  for per in dev.peripherals.values:
    for n in per.walkRegisters:
      assert n.id notin result
      result[n.id] = n


proc deriveRegisterNodes(dev: var SvdDevice) =
  # DFS then reverse to ensure that deepest entities are derived first
  var toBeDerived: seq[SvdRegisterTreeNode]
  for per in dev.peripherals.values:
    for n in per.walkRegisters:
      if n.derivedFrom.isSome:
        toBeDerived.add n
  reverse toBeDerived

  let index = buildRegisterNodeIndex dev
  for n in toBeDerived.mitems:
    let base = index[n.derivedBaseId]
    if base.derivedFrom.isSome:
      raise newException(NotImplementedError, "Chained derived not supported: " & $n.id)
    deriveRegisterTreeNode(n, base)


proc derivePeripherals(dev: var SvdDevice) =
  for per in dev.peripherals.mvalues:
    if per.derivedFrom.isSome:
      let base = dev.peripherals[per.derivedFrom.get.toSvdId]
      if base.derivedFrom.isSome:
        raise newException(NotImplementedError, "Chained derived not supported: " & $per.id)
      derivePeripheral(per, base)


proc deriveAll*(dev: var SvdDevice) =
  # Derive deepest entities first
  dev.deriveRegisterNodes
  dev.derivePeripherals


proc expand(p: SvdPeripheral): seq[SvdPeripheral] =
  ## Expand dim list peripheral
  if not p.isDimList: return @[p]
  let
    dIncr = p.dimGroup.dimIncrement.get
    dimIndex = toSeq(0 ..< p.dimGroup.dim.get).mapIt($it)
  for (idx, idxString) in dimIndex.pairs:
    var newElem = new SvdPeripheral
    newElem[] = p[]
    newElem.name = p.name.replace("%s", idxString)
    newElem.id = newElem.name.toSvdId
    newElem.baseAddress.inc (dIncr * idx)
    if newElem.typeBase.isNone:
      newElem.typeBase = some p.id
    if p.registers.isSome:
      let regs = p.registers.get.mapIt(copySubtree(it, newElem.id))
      newElem.registers = some regs
    result.add newElem


func expand(e: SvdRegisterTreeNode): seq[SvdRegisterTreeNode] =
  ## Expand dim list node (cluster/register)
  if not e.isDimList: return @[e]

  if e.dimGroup.dimIncrement.isNone:
    raise newException(SVDError, e.name & " has dim but no dimIncrement")
  let dIncr = e.dimGroup.dimIncrement.get

  let dimIndex = toSeq(0 ..< e.dimGroup.dim.get).mapIt($it)
  for (idx, idxString) in dimIndex.pairs:
    var newElem = new SvdRegisterTreeNode
    newElem[] = e[]
    newElem.name = e.name.replace("%s", idxString)
    newElem.id = e.id.parent / newElem.name
    newElem.addressOffset.inc (dIncr * idx)
    if newElem.typeBase.isNone:
      newElem.typeBase = some e.id
    if e.kind == rnkCluster and e.registers.isSome:
      let regs = e.registers.get.mapIt(copySubtree(it, newElem.id))
      newElem.registers = some regs
    result.add newElem


proc expandChildren(e: var SvdRegisterTreeNode) =
  ## Recursively expand children of node
  if e.kind != rnkCluster or e.registers.isNone: return

  var expChildren: seq[SvdRegisterTreeNode]
  for child in e.iterRegisters:
    var childExpansion = child.expand
    for expChild in childExpansion.mitems:
      expChild.expandChildren
      expChildren.add expChild
  e.registers = some expChildren


proc expandAll(periph: SvdPeripheral): seq[SvdPeripheral] =
  ## Expand peripheral and all child dim lists

  for expPeriph in periph.expand:
    result.add expPeriph
    if expPeriph.registers.isNone:
      continue

    # Expand child registers/clusters
    var expChildren: seq[SvdRegisterTreeNode]
    for child in expPeriph.iterRegisters:
      var childExpansion = child.expand
      for expChild in childExpansion.mitems:
        expChild.expandChildren
        expChildren.add expChild
    expPeriph.registers = some expChildren


proc expandAll*(dev: var SvdDevice) =
  var expandedPeriphs: OrderedTable[SvdId, SvdPeripheral]
  for p in dev.peripherals.values:
    for expPeriph in p.expandAll:
      expandedPeriphs[expPeriph.id] = expPeriph
  dev.peripherals = expandedPeriphs


proc resolveRegProperties(dev: SvdDevice, reg: SvdRegisterTreeNode):
                          ResolvedRegProperties =
  let periph = dev.peripherals[reg.id.parentPeripheral]
  var
    idStack: seq[SvdId]
    curId = reg.id
  while curId != periph.id:
    idStack.add curId
    curId = curId.parent

  var props = dev.properties
  props = props.update(periph.properties)

  var parent: SvdRegisterTreeNode
  for parentId in idStack.ritems:
    if parent.isNil:
      parent = periph.child(parentId)
    else:
      parent = parent.child(parentId)
    assert not parent.isNil
    props = props.update(parent.properties)

  if props.access.isNone:
    stderr.writeLine fmt"""WARNING: Property "access" for register {reg.id} is undefined. Defaulting to read-write."""
    props.access = some raReadWrite

  if props.size.isNone:
    stderr.writeLine fmt"""WARNING: Property "size" for register {reg.id} is undefined. Defaulting to 32 bits."""
    props.size = some 32.Natural

  if props.resetValue.isNone:
    stderr.writeLine fmt"""WARNING: Property "resetValue" for register {reg.id} is undefined. Defaulting to 0x0."""
    props.resetValue = some 0'i64

  result.size = props.size.get
  result.access = props.access.get
  result.resetValue = props.resetValue.get

proc resolveAllProperties*(dev: var SvdDevice) =
  for periph in dev.peripherals.values:
    for reg in periph.walkRegistersOnly:
      reg.resolvedProperties = resolveRegProperties(dev, reg)
