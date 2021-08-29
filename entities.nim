#[
  This module defines a variant type "SvdEntity" which can hold different SVD
  entities (Peripheral, Rergister, etc). This is useful to construct a complete
  graph of the SVD structure. This module also includes a genereric Graph type
  for this purpose and a function to build such a graph from a collection of
  Peripherals.
]#

import sets
import basetypes
import tables
import hashes
import sequtils
import strformat

type SvdEntityKind* = enum
  sePeripheral, # Root of tree
  seCluster,    # Clusters can be nested
  seRegister,   # Registers are leaf nodes

type SvdEntity* = ref object
  case kind*: SvdEntityKind
    of sePeripheral: periph*: SvdPeripheral
    of seCluster: cluster*: SvdCluster
    of seRegister: register*: SvdRegister
  fqName*: string # Fully qualified name, eg PeripheraA.ClusterB.RegisterC

func hash*(a: SvdEntity): Hash =
  a.fqName.hash

type Graph*[T] = object
  edgeTable: Table[T, HashSet[T]]

type SvdGraph* = Graph[SvdEntity]

# For debugging
func dumps[T](g: Graph[T]): string {.used.} =
  for (k, v) in g.edgeTable.pairs:
    let vStr = toSeq(v).mapIt($it).join(", ")
    result = result & fmt"{$k} -> [{vStr}]" & "\n"

func contains*[T](g: Graph[T], a: T): bool =
  g.edgeTable.contains(a)

iterator edges*[T](g: Graph[T], a: T): T =
  for b in g.edgeTable[a].items:
    yield b

func `$`*(e: SvdEntity): string =
  e.fqName & " (" & $(e.hash) & ")"

func addNode*[T](g: var Graph[T], a: T) =
  discard g.edgeTable.hasKeyOrPut(a, initHashSet[T]())

func addEdge*[T](g: var Graph[T], a, b: T) =
  if g.edgeTable.hasKeyOrPut(a, [b].toHashSet):
    g.edgeTable[a].incl b
  g.addNode b

iterator items*[T](g: Graph[T]): T =
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

func toEntity*(c: SvdCluster, scope: string): SvdEntity =
  SvdEntity(
    kind: seCluster,
    cluster: c,
    fqName: scope & "." & c.name
  )

func toEntity*(r: SvdRegister, scope: string): SvdEntity =
  SvdEntity(
    kind: seRegister,
    register: r,
    fqName: scope & "." & r.name
  )

func buildEntityGraph*(periphs: seq[SvdPeripheral]): SvdGraph =
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

proc cmpAddrOffset*(a, b: SvdEntity): int =
  # Compare address offset
  # Note: Peripherals don't have offsets, only base absolute addresses
  var aOffset, bOffset: int
  case a.kind:
    of seCluster: aOffset = a.cluster.addressOffset
    of seRegister: aOffset = a.register.addressOffset
    of sePeripheral: doAssert false
  case b.kind:
    of seCluster: bOffset = b.cluster.addressOffset
    of seRegister: bOffset = b.register.addressOffset
    of sePeripheral: doAssert false
  return cmp(aOffset, bOffset)

func getNimTypeName*(n: SvdEntity): string =
  case n.kind:
  of sePeripheral: n.periph.nimTypeName
  of seCluster: n.cluster.nimTypeName
  of seRegister: n.register.nimTypeName

func getName*(node: SvdEntity): string =
  result = case node.kind:
    of sePeripheral: node.periph.name
    of seRegister: node.register.name
    of seCluster: node.cluster.name

func getRegisterProperties*(n: SvdEntity): SvdRegisterProperties =
  case n.kind:
  of sePeripheral: n.periph.registerProperties
  of seCluster: n.cluster.registerProperties
  of seRegister: n.register.properties

func isDimArray*(e: SvdEntity): bool =
  case e.kind
  of sePeripheral: e.periph.isDimArray
  of seCluster: e.cluster.isDimArray
  of seRegister: e.register.isDimArray

func getDimGroup*(e: SvdEntity): SvdDimElementGroup =
  case e.kind
  of sePeripheral: e.periph.dimGroup
  of seCluster: e.cluster.dimGroup
  of seRegister: e.register.dimGroup
