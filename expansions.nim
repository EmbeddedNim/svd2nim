import basetypes
import tables
import sets
import hashes
import strutils
import sequtils
import entities

func isDerived(n: SvdEntity): bool =
  case n.kind:
  of sePeripheral: n.periph.derivedFrom.isSome
  of seCluster: n.cluster.derivedFrom.isSome
  of seRegister: n.register.derivedFrom.isSome

func getDerivedFrom(n: SvdEntity): string =
  case n.kind:
  of sePeripheral: n.periph.derivedFrom.get
  of seCluster: n.cluster.derivedFrom.get
  of seRegister: n.register.derivedFrom.get

func buildEntityTable(graph: Graph[SvdEntity]): Table[string, SvdEntity] =
  for n in graph:
    # Traverse each subgraph that is formed from the Peripheral as a root
    if n.kind == sePeripheral:
      for a in graph.dfs(n):
        result[a.fqName] = a

iterator ritems[T](s: seq[T]): T =
  for i in countdown(s.high, s.low):
    yield s[i]

func updateDimGroup(base: SvdDimElementGroup, with: SvdDimElementGroup): SvdDimElementGroup =
  result = base
  if result.dim.isNone: result.dim = with.dim
  if result.dimIncrement.isNone: result.dimIncrement = with.dimIncrement
  if result.dimName.isNone: result.dimName = with.dimName

proc expandDerives*(periphs: var seq[SvdPeripheral]) =
  # Expand entities that are derivedFrom by copying relevant fields.
  let
    entityGraph = periphs.buildEntityGraph
    entityTable = entityGraph.buildEntityTable

  # Use DFS and reverse to ensure we resolve derivations in topological order
  var toBeDerived: seq[SvdEntity]
  for n in entityGraph:
    if n.kind == sePeripheral:
      for a in entityGraph.dfs(n):
        if a.isDerived:
          toBeDerived.add a

  for n in toBeDerived.ritems:
    var parentName = n.getDerivedFrom()
    # If derivedFrom is not fully qualified, prepend the current scope to
    # qualify it for lookup in the entity table
    if n.kind != sePeripheral and '.' notin parentName:
      let scope = n.fqName.split('.')[0 .. ^2].join(".")
      parentName = scope & "." & parentName

    let parentEntity = entityTable[parentName]
    doAssert parentEntity.kind == n.kind
    doAssert not parentEntity.isDerived # Support for chained derivations not impplemented
                                        # Would require more fancy topological sorting

    case n.kind:
    of sePeripheral:
      let parent = parentEntity.periph
      var p = n.periph
      if p.prependToName.isNone: p.prependToName = parent.prependToName
      if p.appendToName.isNone: p.appendToName = parent.appendToName
      if p.headerStructName.isNone: p.headerStructName = parent.headerStructName

      if p.registerProperties.size.isNone:
        p.registerProperties.size = parent.registerProperties.size
      if p.registerProperties.access.isNone:
        p.registerProperties.access = parent.registerProperties.access

      p.dimGroup = updateDimGroup(p.dimGroup, parent.dimGroup)

      # No support for derived items that redefine children clusters/peripherals
      # Otherwise we need to define a new type. Current implementation reuses parent type
      doAssert p.registers.len == 0
      doAssert p.clusters.len == 0
      p.registers = parent.registers.deepCopy
      p.clusters = parent.clusters.deepCopy
      p.nimTypeName = parent.nimTypeName

      # To the best of my understanding, it doesn't make sense to copy
      # interrupts from a derivation. If parent defines interrupts, then the
      # derived item should also define it's own interrupts.
      if parent.interrupts.len > 0: doAssert p.interrupts.len > 0

    of seCluster:
      let parent = parentEntity.cluster
      var c = n.cluster
      if c.headerStructName.isNone: c.headerStructName = parent.headerStructName

      if c.registerProperties.size.isNone:
        c.registerProperties.size = parent.registerProperties.size
      if c.registerProperties.access.isNone:
        c.registerProperties.access = parent.registerProperties.access

      c.dimGroup = updateDimGroup(c.dimGroup, parent.dimGroup)

      # No support for derived items that redefine children clusters/peripherals
      # Otherwise we need to define a new type. Current implementation reuses parent type
      doAssert c.registers.len == 0
      doAssert c.clusters.len == 0
      c.registers = parent.registers.deepCopy
      c.clusters = parent.clusters.deepCopy
      c.nimTypeName = parent.nimTypeName

    of seRegister:
      let parent = parentEntity.register
      var r = n.register

      if r.properties.size.isNone:
        r.properties.size = parent.properties.size
      if r.properties.access.isNone:
        r.properties.access = parent.properties.access

      r.dimGroup = updateDimGroup(r.dimGroup, parent.dimGroup)

      # See above note. Currently, derived registers that redefine fields are
      # not supported. Would need to define a new type.
      doAssert r.fields.len == 0
      r.fields = parent.fields.deepCopy
      r.nimTypeName = parent.nimTypeName

func expandDimList[T: SvdCluster | SvdRegister](e: T): seq[T] =
  if not e.isDimList: return @[e]

  if e.dimGroup.dimIncrement.isNone:
    raise newException(SVDError, e.name & " has dim but no dimIncrement")
  let dIncr = e.dimGroup.dimIncrement.get

  let dimIndex = toSeq(0 .. e.dimGroup.dim.get).mapIt($it)
  for i in 0..dimIndex.high:
    let idxName = dimIndex[i]
    var newElem: T
    deepCopy(newElem, e)
    newElem.name = e.name.replace("%s", idxName)
    debugEcho "Old name: " & e.name
    debugEcho "New name: " & newElem.name
    newElem.addressOffset.inc (dIncr * i)
    result.add newElem

func expandDimList(e: SvdPeripheral): seq[SvdPeripheral] =
  if not e.isDimList: return @[e]
  let
    dIncr = e.dimGroup.dimIncrement.get
    dimIndex = toSeq(0 .. e.dimGroup.dim.get).mapIt($it)
  for i in dimIndex:
    var newElem: SvdPeripheral
    deepCopy(newElem, e)
    newElem.name = e.name.replace("%s", i)
    newElem.baseAddress.inc dIncr
    result.add newElem

func expandClusterChildren(cluster: SvdCluster): SvdCluster =
  result = deepCopy(cluster)
  result.registers = @[]
  result.clusters = @[]

  for reg in cluster.registers:
    result.registers.add reg.expandDimList

  for child in cluster.clusters:
    result.clusters.add map(child.expandDimList, expandClusterChildren)

func expandAllDimLists*(peripherals: seq[SvdPeripheral]): seq[SvdPeripheral] =
  for p in peripherals:
    result.add p.expandDimList

  # TODO: Possible optimization: expand deepest elements first, so they don't
  # have to be re-expanded in copies of parents. Ie, Fields, then Registers,
  # then Clusters (nested), finallly Peripherals.
  # Here we do top-first for code simplicity.

  for p in result:
    var expRegisters: seq[SvdRegister]
    for reg in p.registers:
      expRegisters.add reg.expandDimList
    p.registers = expRegisters

    var expClusters: seq[SvdCluster]
    for cl in p.clusters:
      expClusters.add map(cl.expandDimList, expandClusterChildren)
    p.clusters = expClusters

