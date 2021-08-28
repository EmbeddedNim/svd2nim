import basetypes
import tables
import sets
import hashes
import strutils
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

      # See above note. Currently, derived registers that redefine fields are
      # not supported. Would need to define a new type.
      doAssert r.fields.len == 0
      r.fields = parent.fields.deepCopy
      r.nimTypeName = parent.nimTypeName
