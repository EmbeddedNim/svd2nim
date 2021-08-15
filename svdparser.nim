import strutils
import xmlparser
import xmltree
import options
import strtabs
import regex
import strformat

###############################################################################
# Models
###############################################################################

type SvdBitrange = tuple
  lsb, msb: Natural

type SvdFieldEnum* = object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_registers.html#elem_enumeratedValues
  name*: Option[string]
  derivedFrom*: Option[string]
  headerEnumName*: Option[string]
  values*: seq[tuple[name: string, val: int]]

type SvdField* = object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_registers.html#elem_field
  name*: string
  derivedFrom*: Option[string]
  description*: Option[string]
  bitRange*: SvdBitrange
  enumValues*: Option[SvdFieldEnum]

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

type SvdCluster* {.acyclic.} = ref object
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_registers.html#elem_cluster
  name*: string
  derivedFrom*: Option[string]
  description*: Option[string]
  headerStructName*: Option[string]
  addressOffset*: Natural
  registers*: seq[SvdRegister]
  clusters*: seq[SvdCluster]

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

type
  SvdDeviceMetadata* = ref object
    file*: string
    name*: string
    nameLower*: string
    description*: string
    licenseBlock*: string

type
  SvdInterrupt* = ref object
    name*: string
    index*: int
    description*: string

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
    interrupts*: seq[SvdInterrupt]
    metadata*: SvdDeviceMetadata
    cpu*: SvdCpu


###############################################################################
# Private Procedures
###############################################################################
proc getText(element: XmlNode): string =
  if element.isNil():
    return "none"
  return element.innerText()

proc formatText(text: string): string =
  var ftext = text.replace(re("[ \t\n]+"), " ") # Collapse whitespace
  ftext = ftext.replace("\\n", "\n")
  ftext = ftext.strip()
  return ftext

func parseHexOrDecInt(s: string) : int =
  # Parse string to integer. According to CMSIS spect, if the string
  # starts with 0X or 0x it is to be interpreted as hexadecimal.
  # TODO: Implementing parsing binary if string starts with #
  if s.toLower().startsWith("0x"):
    result = fromHex[int](s)
  else:
    result = parseInt(s)

func getChildTextOpt(pNode: XmlNode, tag:string): Option[string] =
  # Get text of child tag, or none if tag not found.
  let c = pNode.child(tag)
  if c.isNil:
    return none(string)
  elif c.kind notin {xnText, xnCData, xnElement}:
    return none(string)
  else:
    return some(c.innerText)

func getChildNaturalOpt(pNode: XmlNode, tag:string): Option[Natural] =
    # Get text of child tag cas as Natural, or none if tag not found.
    let text = pNode.getChildTextOpt(tag)
    if text.isNone:
      return none(Natural)
    else:
      return some(text.get().parseHexOrDecInt.Natural)

func updateRegisterProperties(
  node: XmlNode,
  parentProps: SvdRegisterProperties):
  SvdRegisterProperties =

  # Update an existing RegisterProperties object with the properties specified
  # by the current node, if applicable.
  #
  # RegisterProperties can be specified by parent node of a Register. The properties
  # are inherited but can be modified by children.
  # See: https://arm-software.github.io/CMSIS_5/SVD/html/elem_special.html#registerPropertiesGroup_gr

  result = parentProps
  let
    size = node.getChildNaturalOpt("size")
    access = node.getChildTextOpt("access")

  if size.isSome: result.size = size.get
  if access.isSome:
    result.access = case access.get:
      of "read-write": raReadWrite
      of "read-only": raReadOnly
      of "write-only": raWriteOnly
      of "writeOnce": raWriteOnce
      of "read-writeOnce": raReadWriteOnce
      else: result.access

func attrOpt(n: XmlNode, name: string): Option[string] =
  # Return some(attr_value) if attr exists, otherwise none
  if isNil(n.attrs):
    none(string)
  elif name in n.attrs:
    some(n.attrs[name])
  else:
    none(string)

iterator findAllDirect(n: XmlNode, tag: string): XmlNode =
  # Iterate over all direct children with given tag
  for cld in n.items:
    if cld.kind != xnElement: # Only xnElement allows tag access
      continue
    if cld.tag == tag:
      yield cld

func parseFieldEnum(eNode: XmlNode): SvdFieldEnum =
  assert eNode.tag == "enumeratedValues"
  result.name = eNode.getChildTextOpt("name")
  result.derivedFrom = eNode.attrOpt("derivedFrom")
  result.headerEnumName = eNode.getChildTextOpt("headerEnumName")

  let usage = eNode.child("usage")
  if not isNil(usage) and usage.innerText != "read-write":
    raise newException(ValueError, "Separate read/write enums not implemented")

  for enumValueNode in eNode.findAllDirect("enumeratedValue"):
    let valueNode = enumValueNode.child("value")
    if isNil(valueNode):
      # Support for isDefault not implementented, ignore
      continue
    let
      name = enumValueNode.child("name").innerText
      val = valueNode.innerText.parseHexOrDecInt
    result.values.add (name: name, val: val)

func parseField(fNode: XmlNode): SvdField =
  assert fNode.tag == "field"
  result.name = fNode.child("name").innerText
  result.derivedFrom = fNode.attrOpt("derivedFrom")
  result.description = fNode.getChildTextOpt("description")

  # Get list of child tag names
  var childTags = newSeq[string]()
  for elem in fNode:
    if elem.kind == xnElement: childTags.add elem.tag

  # SVD spec allows three ways to specify the location and size of bitfields
  # Here we check for th three possibilities and parse them to the SvdBitrange
  # type, which is close to the bitRangePattern spec.
  if childTags.contains("bitOffset") and childTags.contains("bitWidth"):
    # bitRangeOffsetWidthStyle
    let
      bitOffset: Natural = fNode.child("bitOffset").innerText.parseHexOrDecInt
      bitWidth: Natural = fNode.child("bitWidth").innerText.parseHexOrDecInt
    result.bitRange = (lsb: bitOffset, msb: (bitOffset + bitWidth - 1).Natural)
  elif childTags.contains("lsb") and childTags.contains("msb"):
    # bitRangeOffsetWidthStyle
    let
      lsb: Natural = fNode.child("lsb").innerText.parseHexOrDecInt
      msb: Natural = fNode.child("msb").innerText.parseHexOrDecInt
    result.bitRange = (lsb: lsb, msb: msb)
  elif childTags.contains("bitRange"):
    # bitRangePattern
    let
      pat = re"\[([[:alnum:]]+):([[:alnum:]]+)\]"
      text = fNode.child("bitRange").innerText
    var m: RegexMatch
    doAssert text.match(pat, m)
    let
      msb: Natural = m.group(0, text)[0].parseHexOrDecInt
      lsb: Natural = m.group(1, text)[0].parseHexOrDecInt
    result.bitRange = (lsb: lsb, msb: msb)
  else:
    raise newException(ValueError, fmt"Invalid bit range specification in field '{result.name}'")

  let enumVals = fNode.child("enumeratedValues")
  if not isNil(enumVals):
    result.enumValues = some(enumVals.parseFieldEnum)
  else:
    result.enumValues = none(SvdFieldEnum)

func parseRegister(rNode: XmlNode, rp: SvdRegisterProperties): SvdRegister =
  assert rNode.tag == "register"
  result = new(SvdRegister)

  result.name = rNode.child("name").innerText
  result.derivedFrom = rNode.attrOpt("derivedFrom")
  result.addressOffset = rNode.child("addressOffset").innerText.parseHexOrDecInt.Natural
  result.description = rNode.getChildTextOpt("description")
  result.properties = rNode.updateRegisterProperties(rp)

  let fieldsTag = rnode.child("fields")
  if not isNil(fieldsTag):
    for fieldNode in fieldsTag.findAllDirect("field"):
      result.fields.add fieldNode.parseField

func parseCluster(cNode: XmlNode, rp: SvdRegisterProperties): SvdCluster =
  assert cNode.tag == "cluster"
  result = new(SvdCluster)

  result.name = cNode.child("name").innerText
  result.derivedFrom = cNode.attrOpt("derivedFrom")
  result.description = cNode.getChildTextOpt("description")
  result.headerStructName = cNode.getChildTextOpt("headerStructName")
  result.addressOffset = cNode.child("addressOffset").innerText.parseHexOrDecInt.Natural

  let clusterRp = cNode.updateRegisterProperties(rp)

  for childClusterNode in cNode.findAllDirect("cluster"):
    result.clusters.add childClusterNode.parseCluster(clusterRp)
  for registerNode in cNode.findAllDirect("register"):
    result.registers.add registerNode.parseRegister(clusterRp)

func parsePeripheral(pNode: XmlNode, rp: SvdRegisterProperties): SvdPeripheral =
  assert pNode.tag == "peripheral"
  result = new(SvdPeripheral)

  result.name = pNode.child("name").innerText
  result.derivedFrom = pNode.attrOpt("derivedFrom")
  result.description = pNode.getChildTextOpt("description")
  result.baseAddress = pNode.child("baseAddress").innerText.parseHexOrDecInt.Natural
  result.appendToName = pNode.getChildTextOpt("appendToName")
  result.prependToName = pNode.getChildTextOpt("prependToName")
  result.headerStructName = pNode.getChildTextOpt("headerStructName")

  let periphRp = pNode.updateRegisterProperties(rp)

  let registersNode = pNode.child("registers")
  if not isNil(registersNode):
    for clusterNode in registersNode.findAllDirect("cluster"):
      result.clusters.add clusterNode.parseCluster(periphRp)
    for registerNode in registersNode.findAllDirect("register"):
      result.registers.add registerNode.parseRegister(periphRp)

###############################################################################
# Public Procedures
###############################################################################
proc readSVD*(path: string): SvdDevice =
  result = SvdDevice.new()
  let
    xml = path.loadXml()
    deviceName = xml.child("name").getText()
    deviceDescription = xml.child("description").getText().strip()
    defaultRegProps = xml.updateRegisterProperties(
      SvdRegisterProperties(access: raReadWrite, size: 32)
      )

  #TODO: Does the schema allow multiple license texts?
  var licenseTexts = xml.findAll("licenseText")
  var licenseText: string
  if licenseTexts.len() == 0:
    licenseText = ""
  elif licenseTexts.len() == 1:
    licenseText = licenseTexts[0].getText().formatText()
  else:
    raise newException(ValueError, "multiple <licenseText> elements")
  var licenseBlock = ""
  if licenseText != "":
    licenseBlock = "//    " & licenseText.replace("\n","\n//    ")
    licenseBlock = "\n" & licenseBlock

  result.metadata = SvdDeviceMetadata(
    file: path,
    name: deviceName,
    nameLower: deviceName.toLower(),
    description: deviceDescription,
    licenseBlock: licenseBlock
  )

  var cpuNode = xml.child("cpu")
  result.cpu = SvdCpu(
    name: cpuNode.child("name").getText(),
    revision: cpuNode.child("revision").getText(),
    endian: cpuNode.child("endian").getText(),
    mpuPresent: int(cpuNode.child("mpuPresent").getText().parseBool()),
    fpuPresent: int(cpuNode.child("fpuPresent").getText().parseBool()),
    nvicPrioBits: cpuNode.child("nvicPrioBits").getText().parseHexOrDecInt(),
    vendorSystickConfig: int(cpuNode.child("vendorSystickConfig").getText().parseBool())
  )

  for pNode in xml.child("peripherals").findAllDirect("peripheral"):
    result.peripherals.add pNode.parsePeripheral(defaultRegProps)

export options
