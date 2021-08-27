import types
import tables
import sets
import hashes
import strutils
import sequtils
import strformat

type SvdEntityKind = enum
  sePeripheral, # Root of tree
  seCluster,    # Clusters can be nested
  seRegister,   # Registers are leaf nodes

type SvdEntity = ref object
  case kind: SvdEntityKind
    of sePeripheral: periph: SvdPeripheral
    of seCluster: cluster: SvdCluster
    of seRegister: register: SvdRegister
  fqName*: string # Fully qualified name, eg PeripheraA.ClusterB.RegisterC

func hash(a: SvdEntity): Hash =
  a.fqName.hash

type Graph*[T] = object
  edgeTable: Table[T, HashSet[T]]

# For debugging
func dumps[T](g: Graph[T]): string {.used.} =
  for (k, v) in g.edgeTable.pairs:
    let vStr = toSeq(v).mapIt($it).join(", ")
    result = result & fmt"{$k} -> [{vStr}]" & "\n"

func contains*[T](g: Graph[T], a: T): bool =
  g.edgeTable.contains(a)

#iterator edges[T](g: Graph[T], a: T): T =
#  for b in g.edgeTable[a]:
#    yield b

func `$`*(e: SvdEntity): string =
  e.fqName & " (" & $(e.hash) & ")"

func addNode*[T](g: var Graph[T], a: T) =
  discard g.edgeTable.hasKeyOrPut(a, initHashSet[T]())

func addEdge*[T](g: var Graph[T], a, b: T) =
  if g.edgeTable.hasKeyOrPut(a, [b].toHashSet):
    g.edgeTable[a].incl b
  g.addNode b

iterator items[T](g: Graph[T]): T =
  for k in g.edgeTable.keys:
    yield k

iterator dfs*[T](g: Graph[T], start: T): T =
  var stack: seq[T]
  stack.add start
  while stack.len > 0:
    let a = stack.pop
    yield a
    for b in g.edgeTable[a]:
      stack.add b

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

func toEntity(c: SvdCluster, scope: string): SvdEntity =
  SvdEntity(
    kind: seCluster,
    cluster: c,
    fqName: scope & "." & c.name
  )

func toEntity(r: SvdRegister, scope: string): SvdEntity =
  SvdEntity(
    kind: seRegister,
    register: r,
    fqName: scope & "." & r.name
  )

func buildEntityGraph(periphs: seq[SvdPeripheral]): Graph[SvdEntity] =
  var stack: seq[SvdEntity]
  for p in periphs:
    let pNode = SvdEntity(kind: sePeripheral, periph: p, fqName: p.name)
    doAssert pNode notin result
    result.addNode pNode
    stack.add pNode

  while stack.len > 0:
    let n = stack.pop
    result.addNode n

    case n.kind:
    of sePeripheral:
      for ct in n.periph.clusters:
        let ctNode = ct.toEntity(n.fqName)
        doAssert ctNode notin result
        result.addEdge(n, ctNode)
        stack.add ctNode
      for reg in n.periph.registers:
        let regNode = reg.toEntity(n.fqName)
        doAssert regNode notin result
        result.addEdge(n, regNode)
        stack.add regNode
    of seCluster:
      for ct in n.cluster.clusters:
        let ctNode = ct.toEntity(n.fqName)
        doAssert ctNode notin result
        result.addEdge(n, ctNode)
        stack.add ctNode
      for reg in n.cluster.registers:
        let regNode = reg.toEntity(n.fqName)
        doAssert regNode notin result
        result.addEdge(n, regNode)
        stack.add regNode
    of seRegister:
      discard # No children to add

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
