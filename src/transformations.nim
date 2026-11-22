import std/tables
import std/sequtils
import std/strutils
import std/options
import std/algorithm
import std/strformat

import ./basetypes
import ./utils

func parseDimIndices*(dim: Natural, dimIndex: Option[string]): seq[string] =
  ## Resolve the list of instance indices for a dim element group.
  ##
  ## SVD allows a ``<dimIndex>`` tag to specify the indices used when
  ## expanding a dim list (e.g. ``"1,2,3,4"`` or a range like ``"1-4"``,
  ## or a mix such as ``"0,2-4"``). When the tag is missing or empty, the
  ## default indices are ``0 .. dim-1``. The returned sequence has one entry
  ## per instance and is used to build the concrete names (via ``%s``
  ## substitution) of the expanded elements. Addresses are still derived from
  ## the positional index (0 .. dim-1) times ``dimIncrement``.
  if dimIndex.isNone or dimIndex.get.strip.len == 0:
    # No explicit indices: fall back to the default 0-based sequence.
    for i in 0 ..< dim:
      result.add $i
    return

  for part in dimIndex.get.split(','):
    let t = part.strip
    if t.contains('-'):
      # A range such as "1-4" expands to each integer in between.
      let halves = t.split('-')
      if halves.len == 2:
        try:
          let a = parseInt(halves[0].strip)
          let b = parseInt(halves[1].strip)
          for v in a .. b:
            result.add $v
          continue
        except ValueError:
          # Not a numeric range; treat the whole token as a literal index.
          discard
    # A single (possibly non-numeric) index token.
    result.add t

  if result.len == 0:
    # Defensive fallback if parsing produced nothing.
    for i in 0 ..< dim:
      result.add $i

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
      result.registers = some result.registers.get.mapIt(copySubtree(it, result.id))
  of rnkRegister:
    result.fields = result.fields.mapIt(it.copyField(result.id))

func derivePeripheral*(p: var SvdPeripheral, base: SvdPeripheral) =
  if p.prependToName.isNone:
    p.prependToName = base.prependToName
  if p.appendToName.isNone:
    p.appendToName = base.appendToName
  if p.headerStructName.isNone:
    p.headerStructName = base.headerStructName
  p.dimGroup = update(base.dimGroup, p.dimGroup)
  p.properties = update(base.properties, p.properties)

  if p.registers.isNone and p.headerStructName == base.headerStructName and
      p.properties == base.properties:
    p.typeBase = some base.id

  if p.registers.isNone and base.registers.isSome:
    let regs = base.registers.get.mapIt(copySubtree(it, p.id))
    p.registers = some regs

func deriveRegisterTreeNode*(n: var SvdRegisterTreeNode, base: SvdRegisterTreeNode) =
  assert base.kind == n.kind
  n.dimGroup = update(base.dimGroup, n.dimGroup)
  n.properties = update(base.properties, n.properties)

  case n.kind
  of rnkCluster:
    if n.headerStructName.isNone:
      n.headerStructName = base.headerStructName

    if n.registers.isNone and n.headerStructName == base.headerStructName and
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
        raise
          newException(NotImplementedError, "Chained derived not supported: " & $per.id)
      derivePeripheral(per, base)

proc deriveEnum(
    index: TableRef[string, seq[SvdFieldEnum]], parentId: SvdId, derivedFrom: string
): Option[SvdFieldEnum] =
  var base: SvdFieldEnum = nil
  let
    derFromParts = derivedFrom.strip.split('.')
    candidates = index[derFromParts[^1]]

  for cand in candidates:
    let
      candIdParts = cand.id.split
      first = candIdParts.len - min(derFromParts.len, candIdParts.len)
    if candIdParts[first .. candIdParts.high] == derFromParts:
      if not base.isNil:
        warn fmt"""Ambiguous derivedFrom "{derivedFrom}" in enumeratedValues of field {$parentId}. Ignoring this enumeratedValues entry."""
        return none(SvdFieldEnum)
      base = cand

  if base.isNil:
    warn fmt"""derivedFrom "{derivedFrom}" in enumeratedValues of field {$parentId} was not found. Ignoring this enumeratedValues entry."""
    return none(SvdFieldEnum)

  var resultObj = new SvdFieldEnum
  resultObj[] = base[]
  resultObj.id = parentId / base.id.name
  result = some resultObj

proc deriveEnums(dev: var SvdDevice) =
  var enumIndex = newTable[string, seq[SvdFieldEnum]]()

  # Traverse all fields to build the index
  for per in dev.peripherals.values:
    for reg in per.walkRegistersOnly:
      for field in reg.fields:
        if field.enumValues.isSome:
          let ev = field.enumValues.get
          if ev.name.isSome and ev.name.get.len > 0 and ev.derivedFrom.isNone:
            enumIndex.mgetOrPut(ev.name.get(), @[]).add ev

  # Traverse all fields again, this time derive enums
  for per in dev.peripherals.values:
    for reg in per.walkRegistersOnly:
      for field in reg.fields:
        if field.enumValues.isSome and field.enumValues.get.derivedFrom.isSome and
            field.enumValues.get.derivedFrom.get.len > 0:
          field.enumValues =
            deriveEnum(enumIndex, field.id, field.enumValues.get.derivedFrom.get)

proc deriveAll*(dev: var SvdDevice) =
  # Derive deepest entities first
  dev.deriveEnums
  dev.deriveRegisterNodes
  dev.derivePeripherals

proc expand(p: SvdPeripheral): seq[SvdPeripheral] =
  ## Expand dim list peripheral
  if not p.isDimList:
    return @[p]
  let
    dIncr = p.dimGroup.dimIncrement.get
    dimIndices = parseDimIndices(p.dimGroup.dim.get, p.dimGroup.dimIndex)
  for (idx, idxString) in dimIndices.pairs:
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

proc expand(field: SvdField): seq[SvdField] =
  ## Expand dim list Field element (bitfield)
  if not field.isDimList:
    return @[field]
  let
    dIncr = field.dimGroup.dimIncrement.get
    dimIndices = parseDimIndices(field.dimGroup.dim.get, field.dimGroup.dimIndex)
  for (idx, idxString) in dimIndices.pairs:
    var newElem = new SvdField
    newElem[] = field[]
    newElem.name = field.name.replace("%s", idxString)
    newElem.id = field.id.parent / newElem.name
    newElem.lsb.inc (dIncr * idx)
    newElem.msb.inc (dIncr * idx)
    result.add newElem

proc expandAllFields(p: var SvdPeripheral) =
  for reg in p.walkRegistersOnly:
    var newFields: seq[SvdField]
    for field in reg.fields:
      newFields.add field.expand
    reg.fields = newFields

func expand(e: SvdRegisterTreeNode): seq[SvdRegisterTreeNode] =
  ## Expand dim list node (cluster/register)
  if not e.isDimList:
    return @[e]

  if e.dimGroup.dimIncrement.isNone:
    raise newException(SVDError, e.name & " has dim but no dimIncrement")
  let dIncr = e.dimGroup.dimIncrement.get

  let dimIndices = parseDimIndices(e.dimGroup.dim.get, e.dimGroup.dimIndex)
  for (idx, idxString) in dimIndices.pairs:
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
  if e.kind != rnkCluster or e.registers.isNone:
    return

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
  for p in dev.peripherals.mvalues:
    expandAllFields p
    for expPeriph in p.expandAll:
      expandedPeriphs[expPeriph.id] = expPeriph
  dev.peripherals = expandedPeriphs

proc resolveRegProperties(
    dev: SvdDevice, reg: SvdRegisterTreeNode
): ResolvedRegProperties =
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
    warn fmt"""Property "access" for register {reg.id} is undefined. Defaulting to read-write."""
    props.access = some raReadWrite

  if props.size.isNone:
    warn fmt"""Property "size" for register {reg.id} is undefined. Defaulting to 32 bits."""
    props.size = some 32.Natural

  if props.resetValue.isNone:
    warn fmt"""Property "resetValue" for register {reg.id} is undefined. Defaulting to 0x0."""
    props.resetValue = some 0'i64

  result.size = props.size.get
  result.access = props.access.get
  result.resetValue = props.resetValue.get

proc resolveAllProperties*(dev: var SvdDevice) =
  for periph in dev.peripherals.values:
    for reg in periph.walkRegistersOnly:
      reg.resolvedProperties = resolveRegProperties(dev, reg)
