# Generate object type definitions to be written in nim code output
import basetypes
import entities
import sequtils
import tables
import algorithm

type TypeDefField* = object
  name*: string
  public*: bool
  typeName*: string

type CodeGenTypeDef* = ref object
  name*: string
  public*: bool
  fields*: seq[TypeDefField]

func getNimTypeName(n: SvdEntity): string =
  case n.kind:
  of sePeripheral: n.periph.nimTypeName
  of seCluster: n.cluster.nimTypeName
  of seRegister: n.register.nimTypeName

func getName(node: SvdEntity): string =
  result = case node.kind:
    of sePeripheral: node.periph.name
    of seRegister: node.register.name
    of seCluster: node.cluster.name

func getRegisterProperties(n: SvdEntity): SvdRegisterProperties =
  case n.kind:
  of sePeripheral: n.periph.registerProperties
  of seCluster: n.cluster.registerProperties
  of seRegister: n.register.properties

proc cmpAddrOffset(a, b: SvdEntity): int =
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

func updateProperties(parent, child: SvdRegisterProperties): SvdRegisterProperties =
  # Create a new RegisterProperties instance by update parent fields with child
  # fields if they are some.
  result = parent
  if child.size.isSome: result.size = child.size
  if child.access.isSome: result.access = child.access

func getTypeFields(
  n: SvdEntity,
  children: seq[SvdEntity],
  rp: SvdRegisterProperties): seq[TypeDefField] =

  case n.kind:
  of sePeripheral:
    for cNode in children.sorted(cmpAddrOffset):
      result.add TypeDefField(
        name: cNode.getName,
        public: true,
        typeName: cNode.getNimTypeName,
      )
  of seCluster:
    for cNode in children.sorted(cmpAddrOffset):
      result.add TypeDefField(
        name: cNode.getName,
        public: true,
        typeName: cNode.getNimTypeName
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

  while stack.len > 1:
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
