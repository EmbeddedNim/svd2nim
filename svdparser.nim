import strutils
import xmlparser
import xmltree
import options
import strtabs
import regex
import expansions
import basetypes
import strformat
import utils

const typeSuffix  = "_Type"

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
  # Parse string to integer. According to CMSIS spec, if the string
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

func parseRegisterProperties(node: XmlNode): SvdRegisterProperties =
  discard
  let
    size = node.getChildNaturalOpt("size")
    access = node.getChildTextOpt("access")

  result.size = size

  if access.isSome:
    result.access = case access.get:
      of "read-write": raReadWrite.some
      of "read-only": raReadOnly.some
      of "write-only": raWriteOnly.some
      of "writeOnce": raWriteOnce.some
      of "read-writeOnce": raReadWriteOnce.some
      else: raise newException(SVDError, "Unknown access value: " & access.get)

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
    raise newException(NotImplementedError, "Separate read/write enums not implemented")

  for enumValueNode in eNode.findAllDirect("enumeratedValue"):
    let valueNode = enumValueNode.child("value")
    if isNil(valueNode):
      # Support for isDefault not implementented, ignore
      continue
    let
      name = enumValueNode.child("name").innerText
      val = valueNode.innerText.parseHexOrDecInt
    result.values.add (name: name, val: val)

func parseDimElementGroup(n: XmlNode): SvdDimElementGroup =
  result.dim = n.getChildNaturalOpt("dim")
  result.dimIncrement = n.getChildNaturalOpt("dimIncrement")
  #result.dimIndex = n.getChildTextOpt("dimIndex")
  result.dimName = n.getChildTextOpt("dimName")
  #result.dimIndex = n.getChildTextOpt("dimArrayIndex")

  if result.dim.isSome and result.dimIncrement.isNone:
    raise newException(SVDError, "Node has dim but no dimIncrement")

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
    raise newException(SVDError, fmt"Invalid bit range specification in field '{result.name}'")

  let enumVals = fNode.child("enumeratedValues")
  if not isNil(enumVals):
    result.enumValues = some(enumVals.parseFieldEnum)
  else:
    result.enumValues = none(SvdFieldEnum)

  result.dimGroup = fNode.parseDimElementGroup()

func parseRegister(rNode: XmlNode): SvdRegister =
  assert rNode.tag == "register"
  result = new(SvdRegister)

  result.name = rNode.child("name").innerText
  result.derivedFrom = rNode.attrOpt("derivedFrom")
  result.addressOffset = rNode.child("addressOffset").innerText.parseHexOrDecInt.Natural
  result.description = rNode.getChildTextOpt("description")
  result.properties = rNode.parseRegisterProperties

  let fieldsTag = rnode.child("fields")
  if not isNil(fieldsTag):
    for fieldNode in fieldsTag.findAllDirect("field"):
      result.fields.add fieldNode.parseField

  result.dimGroup = rNode.parseDimElementGroup()

func parseCluster(cNode: XmlNode): SvdCluster =
  assert cNode.tag == "cluster"
  result = new(SvdCluster)

  result.name = cNode.child("name").innerText
  result.derivedFrom = cNode.attrOpt("derivedFrom")
  result.description = cNode.getChildTextOpt("description")
  result.headerStructName = cNode.getChildTextOpt("headerStructName")
  result.addressOffset = cNode.child("addressOffset").innerText.parseHexOrDecInt.Natural
  result.registerProperties = cNode.parseRegisterProperties

  for childClusterNode in cNode.findAllDirect("cluster"):
    result.clusters.add childClusterNode.parseCluster()
  for registerNode in cNode.findAllDirect("register"):
    result.registers.add registerNode.parseRegister()

  result.dimGroup = cNode.parseDimElementGroup()

func appendTypeName(parentName: string, name: string): string =
  if parentName.endsWith(typeSuffix):
    result = result & parentName[0 .. ^(typeSuffix.len+1)]
  else:
    result = result & parentName
  result = result & "_" & name

func buildTypeName(p: SvdPeripheral): string =
  if p.dimGroup.dimName.isSome:
    result = p.dimGroup.dimName.get
  elif p.headerStructName.isSome:
    result = p.headerStructName.get
  else:
    result = p.name.stripPlaceHolder
  result = result & typeSuffix

func buildTypeName(c: SvdCluster, parentTypeName: string): string =
  if c.dimGroup.dimName.isSome:
    result = c.dimGroup.dimName.get
  elif c.headerStructName.isSome:
    result = c.headerStructName.get
  else:
    result = appendTypeName(parentTypeName, c.name.stripPlaceHolder)
  result = result & typeSuffix

func buildTypeName(r: SvdRegister, parentTypeName: string): string =
  if r.dimGroup.dimName.isSome:
    result = r.dimGroup.dimName.get
  else:
    result = appendTypeName(parentTypeName, r.name.stripPlaceHolder) & typeSuffix

func setAllTypeNames(c: var SvdCluster, parentTypeName: string) =
  c.nimTypeName = buildTypeName(c, parentTypeName)
  for child in c.clusters.mitems: child.setAllTypeNames(c.nimTypeName)
  for reg in c.registers.mitems:
    reg.nimTypeName = buildTypeName(reg, c.nimTypeName)

func setAllTypeNames(p: var SvdPeripheral) =
  p.nimTypeName = buildTypeName(p)
  for c in p.clusters.mitems: c.setAllTypeNames(p.nimTypeName)
  for reg in p.registers.mitems:
    reg.nimTypeName = buildTypeName(reg, p.nimTypeName)

func parsePeripheral(pNode: XmlNode): SvdPeripheral =
  assert pNode.tag == "peripheral"
  result = new(SvdPeripheral)

  result.name = pNode.child("name").innerText
  result.derivedFrom = pNode.attrOpt("derivedFrom")
  result.description = pNode.getChildTextOpt("description")
  result.baseAddress = pNode.child("baseAddress").innerText.parseHexOrDecInt.Natural
  result.appendToName = pNode.getChildTextOpt("appendToName")
  result.prependToName = pNode.getChildTextOpt("prependToName")
  result.headerStructName = pNode.getChildTextOpt("headerStructName")
  result.registerProperties = pNode.parseRegisterProperties

  for intNode in pNode.findAllDirect("interrupt"):
    result.interrupts.add SvdInterrupt(
      name: intNode.child("name").innerText,
      description: intNode.getChildTextOpt("description"),
      value: intNode.child("value").innerText.parseHexOrDecInt
    )

  let registersNode = pNode.child("registers")
  if not isNil(registersNode):
    for clusterNode in registersNode.findAllDirect("cluster"):
      result.clusters.add clusterNode.parseCluster()
    for registerNode in registersNode.findAllDirect("register"):
      result.registers.add registerNode.parseRegister()

  result.dimGroup = pNode.parseDimElementGroup()
  result.setAllTypeNames()

###############################################################################
# Public Procedures
###############################################################################
proc readSVD*(path: string): SvdDevice =
  result = SvdDevice.new()
  let
    xml = path.loadXml()
    deviceName = xml.child("name").getText()
    deviceDescription = xml.child("description").getText().strip()

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

  result.registerProperties = xml.parseRegisterProperties()

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
    result.peripherals.add pNode.parsePeripheral()

  # Expand derivedFrom entities in peripherals and their children
  expandDerives result.peripherals

export options

when isMainModule:
  #let device = readSVD("./tests/ARM_Example.svd")
  let device = readSVD("./tests/ATSAMD21G18A.svd")
