import svdparser
import strformat
import regex
import algorithm
import strformat

type PeripheralTreeNodeKind* = enum
  ptPeripheral, # Root of tree
  ptCluster,    # Clusters can be nested
  ptRegister,   # Registers are leaf nodes
  ptUnion,      # Unions contain multiple nodes located at the same memory location

type PeripheralTreeNode* = ref object
  case kind*: PeripheralTreeNodeKind
    of ptPeripheral: periph*: SvdPeripheral
    of ptCluster: cluster*: SvdCluster
    of ptRegister: register*: SvdRegister
    of ptUnion: typeName*: string
  children: seq[PeripheralTreeNode]
  addressOffset: Natural

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

func identifier(p: SvdPeripheral): string =
  if p.headerStructName.isSome:
    result = p.headerStructName.get
  else:
    result = fmt"{p.name}_Type"
  result = result.sanitizeIdent

func identifier(cl: SvdCluster): string =
  if cl.headerStructName.isSome:
    result = cl.headerStructName.get
  else:
    result = fmt"{cl.name}_Type"
  result = result.sanitizeIdent

func identifier(reg: SvdRegister): string =
  reg.name.sanitizeIdent

func getName*(node: PeripheralTreeNode): string =
  result = case node.kind:
    of ptPeripheral: node.periph.name
    of ptRegister: node.register.name
    of ptCluster: node.cluster.name
    of ptUnion: node.typeName

func buildUnionName(parentName: string, idx: int): string =
  result = fmt"{parentName}_Inner_Union_{idx}"

proc cmpAddr(a, b: PeripheralTreeNode): int =
  cmp(a.addressOffset, b.addressOffset)

func createUnions(nodes: seq[PeripheralTreeNode], parentName: string): seq[PeripheralTreeNode] =
  # Create union for all children at same offset
  assert nodes.isSorted(cmpAddr)

  var
    unionMembers = newSeq[PeripheralTreeNode]()
    prevNode = nodes[0]
    unionIdx = 0

  for i in 1 .. nodes.high:
    let curNode = nodes[i]
    if curNode.addressOffset == prevNode.addressOffset:
      if unionMembers.len == 0: unionMembers.add prevNode
      unionMembers.add curNode
      if i == nodes.high:
        # At last node, add union to result
        result.add PeripheralTreeNode(
          kind: ptUnion,
          children: unionMembers,
          addressOffset: curNode.addressOffset,
          typeName: buildUnionName(parentName, unionIdx)
        )
    else:
      if unionMembers.len > 0:
        # Add current union to result and create a new one
        result.add PeripheralTreeNode(
          kind: ptUnion,
          typeName: buildUnionName(parentName, unionIdx),
          children: unionMembers,
          addressOffset: prevNode.addressOffset
        )
    #    unionMembers = newSeq[PeripheralTreeNode]()
    #    unionIdx.inc
    #  else:
    #    result.add prevNode

    #  # Last node, add to result
    #  if i == nodes.high: result.add curNode
    prevNode = curNode

func toNode(reg: SvdRegister): PeripheralTreeNode =
  result = PeripheralTreeNode(
    kind: ptRegister,
    register: reg,
    addressOffset: reg.addressOffset
  )
  # Register is a leaf node, no children

func toSubtree(cl: SvdCluster): PeripheralTreeNode =
  result = PeripheralTreeNode(
    kind: ptCluster,
    cluster: cl,
    addressOffset: cl.addressOffset
  )

  var tmpChildren = newSeq[PeripheralTreeNode]()
  for reg in cl.registers:
    tmpChildren.add reg.toNode
  for childCluster in cl.clusters:
    tmpChildren.add childCluster.toSubtree

  tmpChildren.sort(cmpAddr)
  result.children = tmpChildren.createUnions(cl.name)

func buildTree(p: SvdPeripheral): PeripheralTreeNode =
  result = PeripheralTreeNode(kind: ptPeripheral, periph: p)

  var tmpChildren = newSeq[PeripheralTreeNode]()
  for reg in p.registers:
    tmpChildren.add reg.toNode
  for cl in p.clusters:
    tmpChildren.add cl.toSubtree

  tmpChildren.sort(cmpAddr)
  result.children = tmpChildren.createUnions(p.name)

func getSortedObjectDefs*(p: SvdPeripheral): seq[PeripheralTreeNode] =
  # Produces items in the order that the type definitions should be written
  # to the output file.
  # DFS and reverse result order.
  let root = p.buildTree
  var
    stack = newSeq[PeripheralTreeNode]()
    tmp = newSeq[PeripheralTreeNode]()
  stack.add root

  while stack.len > 0:
    let cur = stack.pop
    tmp.add cur
    for c in cur.children:
      stack.add c

  for i in 1 .. tmp.len:
    let node = tmp[^i]
    if node.kind != ptRegister:
      # Registers are object fields, no typedef required
      result.add node
