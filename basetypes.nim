import options
import strutils
export options

type SvdBitrange* = tuple
  lsb, msb: Natural

type SvdFieldEnum* = object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_registers.html#elem_enumeratedValues
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
  #dimArrayIndex*: Option[string]

type SvdField* = object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_registers.html#elem_field
  name*: string
  derivedFrom*: Option[string]
  description*: Option[string]
  bitRange*: SvdBitrange
  enumValues*: Option[SvdFieldEnum]
  dimGroup*: SvdDimElementGroup

type SvdRegisterAccess* = enum
  raReadOnly
  raWriteOnly
  raReadWrite
  raWriteOnce
  raReadWriteOnce

type SvdRegisterProperties* = object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_special.html#registerPropertiesGroup_gr
  size*: Natural
  access*: SvdRegisterAccess
  # Other fields not implemented for the moment
  # protection
  # resetValue
  # resetMask

type SvdRegister* = ref object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_registers.html#elem_register
  name*: string
  derivedFrom*: Option[string]
  addressOffset*: Natural
  description*: Option[string]
  properties*: SvdRegisterProperties
  fields*: seq[SvdField]
  nimTypeName*: string
  dimGroup*: SvdDimElementGroup

type SvdCluster* {.acyclic.} = ref object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_registers.html#elem_cluster
  name*: string
  derivedFrom*: Option[string]
  description*: Option[string]
  headerStructName*: Option[string]
  addressOffset*: Natural
  registers*: seq[SvdRegister]
  clusters*: seq[SvdCluster]
  nimTypeName*: string
  dimGroup*: SvdDimElementGroup

type SvdInterrupt* = object
  name*: string
  description*: Option[string]
  value*: int

type SvdPeripheral* = ref object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_peripherals.html#elem_peripheral
  name*: string
  derivedFrom*: Option[string]
  description*: Option[string]
  baseAddress*: Natural
  prependToName*: Option[string]
  appendToName*: Option[string]
  headerStructName*: Option[string]
  registers*: seq[SvdRegister]
  clusters*: seq[SvdCluster]
  interrupts*: seq[SvdInterrupt]
  nimTypeName*: string
  dimGroup*: SvdDimElementGroup

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
    mpuPresent*: int
    fpuPresent*: int
    nvicPrioBits*: int
    vendorSystickConfig*: int

type
  SvdDevice* = ref object
    peripherals*: seq[SvdPeripheral]
    metadata*: SvdDeviceMetadata
    cpu*: SvdCpu

# Any SVD entity that supports dimElementGroup
type SomeSvdDimable* = SvdPeripheral | SvdCluster | SvdRegister | SvdField

type
  SVDError* = object of CatchableError ## \
    ## Raised when SVD file does not meet the SVD spec

  NotImplementedError* = object of CatchableError ## \
    ## Raised when a feature of the SVD spec is not implemened by this program

func isDimList*[T: SomeSvdDimable](e: T): bool =
  e.dimGroup.dim.isSome and not e.name.endsWith("[%s]")

func isDimArray*[T: SomeSvdDimable](e: T): bool =
  e.dimGroup.dim.isSome and e.name.endsWith("[%s]")

iterator allRegisters*(p: SvdPeripheral): SvdRegister =
  for r in p.registers:
    yield r

  var clusterStack: seq[SvdCluster]
  for c in p.clusters: clusterStack.add c
  while clusterStack.len > 0:
    let c = clusterStack.pop
    for r in c.registers:
      yield r
    for child in c.clusters: clusterStack.add child

template isWritable*(r: SvdRegister): bool =
  r.properties.access in {raWriteOnce, raReadWrite, raWriteOnly, raReadWriteOnce}

template isReadable*(r: SvdRegister): bool =
  r.properties.access in {raReadOnly, raReadWrite, raReadWriteOnce}
