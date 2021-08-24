import svdparser
import strutils
import regex
import algorithm
import tables

#[ Create nim elements for registers and their parent objects (peripherals and
clusters) from parsed SVD objects.

Here an "Instance" is a generic term that refers to either a Peripheral, a
Cluster or a Register. In CMSIS, a Register is a pointer to an integer in memory
that are used to interact with a device peripheral. A Cluster is a group of
Registers and Clusters. A Peripheral contains all the registers that are
relevant to the corresponding device peripheral, optionally grouped within
Clusters. Only Clusters may be grouped arbitrarily deep.

In the Nim code to be generated, we need to generate object type definitions
for these Instances, as well as instances of the objects for each Instance.
]#

type InstanceKind* = enum
  inPeripheral, # Root of tree
  inCluster,    # Clusters can be nested
  inRegister,   # Registers are leaf nodes

type InstanceNode* = ref object
  # Tree structure of Nim instances, so that they can be written in the
  # topologically correct order.
  case kind*: InstanceKind
    of inPeripheral: periph*: SvdPeripheral
    of inCluster: cluster*: SvdCluster
    of inRegister:
      register*: SvdRegister
      absAddr*: Natural # Absolute memory adress, ie, base address of register
                        # + all applicable offsets.
  children*: seq[InstanceNode]
  typeName*: string

type TypeDefField* = object
  name*: string
  public*: bool
  typeName*: string
  instanceKind*: InstanceKind

type CodeGenTypeDef* = ref object
  name*: string
  public*: bool
  fields*: seq[TypeDefField]

func reverse[T](s: seq[T]): seq[T] =
  result = newSeqOfCap[T](s.len)
  for i in countdown(s.high, s.low):
    result.add s[i]

iterator ritems[T](s: seq[T]): T =
  for i in countdown(s.high, s.low):
    yield s[i]

func sanitizeIdent*(ident: string): string =
  # Sanitize identifier so that it conforms to nim's rules
  # Exported (*) for testing purposes
  const reptab: array[4, (Regex, string)] = [
    (re"[!$%&*+-./:<=>?@\\^|~]", ""),         # Operators
    (re"[\[\]\(\)`\{\},;\.:]", ""),           # Other tokens
    (re"_(_)+", "_"),                         # Subsequent underscores
    (re"_$", ""),                             # Trailing underscore
  ]

  result = ident
  for (reg, repl) in reptab:
    result = result.replace(reg, repl)

func getName*(node: InstanceNode): string =
  result = case node.kind:
    of inPeripheral: node.periph.name
    of inRegister: node.register.name
    of inCluster: node.cluster.name

func getBaseTypeName(p: SvdPeripheral): string =
  if p.headerStructName.isSome:
    p.headerStructName.get
  else:
    p.name

func buildTypeName(p: SvdPeripheral): string =
  p.getBaseTypeName & "_Type"

func buildTypeName(n: InstanceNode, parents: seq[InstanceNode]): string =
  # Get name of type definition to be generated according to CMSIS spec for
  # struct name.
  let elems = parents & n
  var parts = newSeqOfCap[string](elems.len)
  parts.add "Type"

  for e in elems.ritems:
    case e.kind:
    of inPeripheral:
      parts.add e.periph.getBaseTypeName()
    of inCluster:
      if e.cluster.headerStructName.isSome:
        parts.add e.cluster.headerStructName.get()
        break
      else:
        parts.add e.cluster.name
    of inRegister:
      parts.add e.register.name

  result = parts.reverse.join("_").sanitizeIdent

func intName(r: SvdRegister): string =
  # Get integer type name for register
  doAssert r.properties.size mod 8 == 0
  let byteSz = r.properties.size div 8
  doAssert byteSz in {8, 16, 32, 64}
  result = "uint" & $byteSz


func getAbsAddr(r: SvdRegister, parents: seq[InstanceNode]): int =
  doAssert parents.len > 0
  doAssert parents[0].kind == inPeripheral
  result = parents[0].periph.baseAddress
  for i in 1..parents.high:
    let p = parents[i]
    doAssert p.kind == inCluster
    result.inc p.cluster.addressOffset
  result.inc r.addressOffset

proc cmpAddrOffset(a, b: InstanceNode): int =
  # Compare address offset
  # Note: Peripherals don't have offsets, only base absolute addresses
  var aOffset, bOffset: int
  case a.kind:
    of inCluster: aOffset = a.cluster.addressOffset
    of inRegister: aOffset = a.register.addressOffset
    of inPeripheral: doAssert false
  case b.kind:
    of inCluster: aOffset = b.cluster.addressOffset
    of inRegister: aOffset = b.register.addressOffset
    of inPeripheral: doAssert false
  return cmp(aOffset, bOffset)

func toNode(reg: SvdRegister): InstanceNode =
  result = InstanceNode(
    kind: inRegister,
    register: reg,
  )
  # Register is a leaf node, no children

func toSubtree(cl: SvdCluster): InstanceNode =
  result = InstanceNode(
    kind: inCluster,
    cluster: cl,
  )

  for reg in cl.registers:
    result.children.add reg.toNode()
  for childCluster in cl.clusters:
    result.children.add childCluster.toSubtree()
  result.children.sort(cmpAddrOffset)

proc inheritProps(n: var InstanceNode, parents: seq[InstanceNode]) =
  # Traverse instance tree to fill in properties that are "inherited" from
  # parent nodes, such as typedef names and register addresses.
  n.typeName = buildTypeName(n, parents)
  if n.kind == inRegister:
    n.absAddr = getAbsAddr(n.register, parents)

  let thisParents = parents & n
  for c in n.children.mitems: inheritProps(c, thisParents)

func buildTree(p: SvdPeripheral): InstanceNode =
  result = InstanceNode(
    kind: inPeripheral,
    periph: p,
    typeName: p.buildTypeName)

  for reg in p.registers:
    result.children.add reg.toNode()
  for cl in p.clusters:
    result.children.add cl.toSubtree()
  result.children.sort(cmpAddrOffset)

  for c in result.children.mitems: inheritProps(c, @[result])

func getSortedInstances*(p: SvdPeripheral): seq[InstanceNode] =
  # Produces items in the order that the instance definitions should be
  # written to the output file.

  # Do DFS then reverse result order.

  let root = p.buildTree
  var
    stack = newSeq[InstanceNode]()
    tmp = newSeq[InstanceNode]()
  stack.add root

  while stack.len > 0:
    let cur = stack.pop
    tmp.add cur
    # Reverse order so that children will be in the initial memory order
    # after the final reverse call.
    for c in cur.children.ritems:
      stack.add c

  result = tmp.reverse

func typeFields(n: InstanceNode): seq[TypeDefField] =
  case n.kind:
  of inPeripheral:
    result = @[]
  of inCluster:
    for cNode in n.children:
      result.add TypeDefField(
        name: cNode.getName,
        public: true,
        typeName: ""
        )
  of inRegister:
    # Registers have a single (private) field, the pointer
    result.add TypeDefField(
      name: "p",
      public: false,
      typeName: "ptr " & n.register.intName)

func createTypeDefs*(instances: seq[InstanceNode]): OrderedTable =
  for ist in instances:
    let tname = ist.typeName
    if tname notin result:
      result[tname] = CodeGenTypeDef(
        name: tname,
        public: false,
        fields: ist.typeFields
      )
