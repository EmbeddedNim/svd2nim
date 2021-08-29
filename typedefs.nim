# Generate object type definitions to be written in nim code output
import basetypes
import entities
import sequtils
import tables
import algorithm
import strformat

type TypeDefField* = object
  name*: string
  public*: bool
  typeName*: string

type CodeGenTypeDef* = ref object
  name*: string
  public*: bool
  fields*: seq[TypeDefField]

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
