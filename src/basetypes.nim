import std/options
import std/strutils
import std/tables
import ./utils


type SvdId* = object
  parts: seq[string]


const RootId* = SvdId(parts: @[])


type SvdFieldEnum* = ref object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_registers.html#elem_enumeratedValues
  id*: SvdId
  name*: Option[string]
  derivedFrom*: Option[string]
  headerEnumName*: Option[string]
  values*: seq[tuple[name: string, val: int]]



type SvdDimElementGroup* = object
  dim*: Option[Natural]
  dimIncrement*: Option[Natural]
  # TODO: Implement support for dimIndex and dimArrayIndex
  #dimIndex*: Option[string]
  dimName*: Option[string]



type SvdRegisterAccess* = enum
  raReadOnly
  raWriteOnly
  raReadWrite
  raWriteOnce
  raReadWriteOnce


type SvdField* = ref object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_registers.html#elem_field
  id*: SvdId
  name*: string
  derivedFrom*: Option[string]
  description*: Option[string]
  lsb*: Natural
  msb*: Natural
  enumValues*: Option[SvdFieldEnum]
  dimGroup*: SvdDimElementGroup
  access*: Option[SvdRegisterAccess]


type SvdRegisterProperties* = object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_special.html#registerPropertiesGroup_gr
  size*: Option[Natural]
  access*: Option[SvdRegisterAccess]
  resetValue*: Option[int64]
  # Other fields not implemented for the moment
  # protection
  # resetMask


## Fully resolved register properties, based on inherited parent properties
type ResolvedRegProperties* = object
  size*: Natural
  access*: SvdRegisterAccess
  resetValue*: int64


type SvdRegisterNodeKind* = enum rnkCluster, rnkRegister


## Represents either a Cluster or Register element, which may by
## nested arbitrarily deep.
type SvdRegisterTreeNode* = ref object
  id*: SvdId
  name*: string
  baseName*: string
  derivedFrom*: Option[string]
  addressOffset*: Natural
  description*: Option[string]
  properties*: SvdRegisterProperties
  dimGroup*: SvdDimElementGroup
  typeBase*: Option[SvdId]
  case kind*: SvdRegisterNodeKind
  of rnkCluster:
    headerStructName*: Option[string]
    registers*: Option[seq[SvdRegisterTreeNode]]
  of rnkRegister:
    resolvedProperties*: ResolvedRegProperties
    fields*: seq[SvdField]

type SvdInterrupt* = object
  name*: string
  description*: string
  value*: int

type SvdPeripheral* = ref object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_peripherals.html#elem_peripheral
  id*: SvdId
  name*: string
  baseName*: string
  derivedFrom*: Option[string]
  description*: Option[string]
  baseAddress*: Natural
  prependToName*: Option[string]
  appendToName*: Option[string]
  headerStructName*: Option[string]
  properties*: SvdRegisterProperties
  registers*: Option[seq[SvdRegisterTreeNode]]
  interrupts*: seq[SvdInterrupt]
  dimGroup*: SvdDimElementGroup
  typeBase*: Option[SvdId]

type
  SvdDeviceMetadata* = ref object
    file*: string
    name*: string
    description*: string
    licenseBlock*: Option[string]

type
  SvdCpu* = ref object
    name*: string
    revision*: string
    endian*: string
    mpuPresent*: bool
    fpuPresent*: bool
    vtorPresent*: bool
    nvicPrioBits*: int
    vendorSystickConfig*: bool


type
  SvdDevice* = ref object
    metadata*: SvdDeviceMetadata
    cpu*: SvdCpu
    properties*: SvdRegisterProperties
    peripherals*: OrderedTable[SvdId, SvdPeripheral]


## Any SVD entity that supports dimElementGroup
type SomeSvdDimable* = SvdPeripheral | SvdRegisterTreeNode | SvdField

## Any SVD type that contains child registers
type SvdRegisterParent* = SvdPeripheral | SvdRegisterTreeNode

## Any SVD type with an id
type SomeSvdId* = SvdPeripheral | SvdRegisterTreeNode | SvdField | SvdFieldEnum

type
  ## Raised when SVD file does not meet the SVD spec
  SVDError* = object of CatchableError

  ## Raised when a feature of the SVD spec is not implemened by this program
  NotImplementedError* = object of CatchableError


func toSvdId*(s: string): SvdId =
  SvdId(parts: s.split('.'))


func `$`*(id: SvdId): string =
  id.parts.join(".")


func `/`*(a: SvdId, b: string): SvdId =
  result = a
  result.parts.add b


func split*(id: SvdId): seq[string] = id.parts


func parent*(id: SvdId): SvdId =
  result = id
  if result.parts.len > 0:
    result.parts.setLen(result.parts.len - 1)


func name*(id: SvdId): string =
  if id.parts.len > 0:
    id.parts[^1]
  else: ""


func parentPeripheral*(id: SvdId): SvdId =
  result = id
  if result.parts.len > 0:
    result.parts.setLen(1)


func isRoot*(id: SvdId): bool =
  id.parts.len == 0


func isDimList*[T: SomeSvdDimable](e: T): bool =
  e.dimGroup.dim.isSome and not e.name.endsWith("[%s]")


func isDimArray*[T: SomeSvdDimable](e: T): bool =
  e.dimGroup.dim.isSome and e.name.endsWith("[%s]")


iterator iterRegisters*[T: SvdRegisterParent](p: T): SvdRegisterTreeNode =
  ## Iterate direct children register nodes
  if p.registers.isSome:
    for c in p.registers.get:
      yield c


iterator riterRegisters*[T: SvdRegisterParent](p: T): SvdRegisterTreeNode =
  ## Iterate direct children register nodes in reverse order
  if p.registers.isSome:
    for c in p.registers.get.ritems:
      yield c


iterator walkRegisters*(p: SvdPeripheral): SvdRegisterTreeNode =
  ## Recursively iterate through the full register tree in depth-first order
  var stack: seq[SvdRegisterTreeNode]
  for c in p.riterRegisters:
    stack.add c

  while stack.len > 0:
    let node = stack.pop
    yield node
    if node.kind == rnkCluster:
      for c in node.riterRegisters:
        stack.add c


iterator walkRegistersOnly*(p: SvdPeripheral): SvdRegisterTreeNode =
  ## Recursively iterate through the full register tree in depth-first order
  ## Only yield Register items, ignore Clusters.
  for n in p.walkRegisters:
    if n.kind == rnkRegister: yield n


proc isWritable*(access: SvdRegisterAccess): bool =
  access in {raWriteOnce, raReadWrite, raWriteOnly, raReadWriteOnce}


proc isReadable*(access: SvdRegisterAccess): bool =
  access in {raReadOnly, raReadWrite, raReadWriteOnce}


func update*(base, with: SvdRegisterProperties): SvdRegisterProperties =
  result = base
  if with.size.isSome: result.size = with.size
  if with.access.isSome: result.access = with.access
  if with.resetValue.isSome: result.resetValue = with.resetValue


func update*(base, with: SvdDimElementGroup): SvdDimElementGroup =
  result = base
  if with.dim.isSome: result.dim = with.dim
  if with.dimIncrement.isSome: result.dimIncrement = with.dimIncrement
  if with.dimName.isSome: result.dimName = with.dimName


proc cmpAddrOffset*(a, b: SvdRegisterTreeNode): int =
  ## Compare address offset, useful for sorting children in typedefs
  ## Note: Peripherals don't have offsets, only base absolute addresses
  return cmp(a.addressOffset, b.addressOffset)


func child*(p: SvdRegisterParent, id: SvdId): SvdRegisterTreeNode =
  ## Find child register with given id
  for c in p.iterRegisters:
    if c.id == id:
      return c


func bitsize*(f: SvdField): Natural =
  f.msb - f.lsb + 1