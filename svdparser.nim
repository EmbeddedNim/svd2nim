import strutils
import xmlparser
import xmltree
import options
import strtabs
import regex
import basetypes
import strformat
import utils
import codegen

###############################################################################
# Private Procedures
###############################################################################

func parseHexOrDecInt(s: string) : int =
  # Parse string to integer. According to CMSIS spec, if the string
  # starts with 0X or 0x it is to be interpreted as hexadecimal.
  # TODO: Implementing parsing binary if string starts with #
  if s.toLower().startsWith("0x"):
    result = fromHex[int](s)
  else:
    result = parseInt(s)

func getChildTextOpt(pNode: XmlNode, tag: string): Option[string] =
  # Get text of child tag, or none if tag not found.
  let c = pNode.child(tag)
  if c.isNil:
    return none(string)
  elif c.kind notin {xnText, xnCData, xnElement}:
    return none(string)
  else:
    return some(c.innerText)

func getChildNaturalOpt(pNode: XmlNode, tag: string): Option[Natural] =
    # Get text of child tag cas as Natural, or none if tag not found.
    let text = pNode.getChildTextOpt(tag)
    if text.isNone:
      return none(Natural)
    else:
      return some(text.get().parseHexOrDecInt.Natural)

func getChildTextExc(pNode: XmlNode, tag: string): string =
  let c = pNode.child(tag)
  if c.isNil or (c.kind notin {xnText, xnCData, xnElement}):
    let fline = splitLines($pNode)[0]
    raise newException(SVDError, fmt"Missing tag '{tag}' in element {fline}")
  result = c.innerText

func getChildOrError(pNode: XmlNode, tag: string): XmlNode =
  result = pNode.child(tag)
  if result.isNil:
    let fline = splitLines($pNode)[0]
    raise newException(SVDError, fmt"Missing tag '{tag}' in element {fline}" )

func getChildBoolOrDefault(n: XmlNode, tag: string, default: bool): bool =
  let cld = n.child(tag)
  if cld.isNil:
    return default
  else:
    return cld.innerText.parseBool

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
      name = enumValueNode.getChildTextExc("name")
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
  result.name = fNode.getChildTextExc("name")
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

func updateProperties(parent: SvdRegisterProperties, node: XmlNode): SvdRegisterProperties =
  # Create a new RegisterProperties instance by update parent fields with child
  # fields if they are some.
  result = parent

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
      else: raise newException(SVDError, "Unknown access value: " & access.get)

func parseRegister(rNode: XmlNode, parentRp: SvdRegisterProperties): SvdRegister =
  assert rNode.tag == "register"
  result = new(SvdRegister)

  result.name = rNode.getChildTextExc("name")
  result.derivedFrom = rNode.attrOpt("derivedFrom")
  result.addressOffset = rNode.getChildTextExc("addressOffset").parseHexOrDecInt.Natural
  result.description = rNode.getChildTextOpt("description")
  result.properties = updateProperties(parentRp, rNode)

  if result.derivedFrom.isSome and (not rNode.child("size").isNil or not rNode.child("access").isNil):
    raise newException(SVDError, "Not supported: derived register '" & result.name & "' redefines size or access.")

  let fieldsTag = rnode.child("fields")
  if not isNil(fieldsTag):
    for fieldNode in fieldsTag.findAllDirect("field"):
      result.fields.add fieldNode.parseField

  result.dimGroup = rNode.parseDimElementGroup()

func parseCluster(cNode: XmlNode, parentRp: SvdRegisterProperties): SvdCluster =
  assert cNode.tag == "cluster"
  result = new(SvdCluster)

  result.name = cNode.getChildTextExc("name")
  result.derivedFrom = cNode.attrOpt("derivedFrom")
  result.description = cNode.getChildTextOpt("description")
  result.headerStructName = cNode.getChildTextOpt("headerStructName")
  result.addressOffset = cNode.getChildTextExc("addressOffset").parseHexOrDecInt.Natural
  let rp = updateProperties(parentRp, cNode)

  for childClusterNode in cNode.findAllDirect("cluster"):
    result.clusters.add childClusterNode.parseCluster(rp)
  for registerNode in cNode.findAllDirect("register"):
    result.registers.add registerNode.parseRegister(rp)

  result.dimGroup = cNode.parseDimElementGroup()

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

func parsePeripheral(pNode: XmlNode, parentRp: SvdRegisterProperties): SvdPeripheral =
  assert pNode.tag == "peripheral"
  result = new(SvdPeripheral)

  result.name = pNode.getChildTextExc("name")
  result.derivedFrom = pNode.attrOpt("derivedFrom")
  result.description = pNode.getChildTextOpt("description")
  result.baseAddress = pNode.getChildTextExc("baseAddress").parseHexOrDecInt.Natural
  result.appendToName = pNode.getChildTextOpt("appendToName")
  result.prependToName = pNode.getChildTextOpt("prependToName")
  result.headerStructName = pNode.getChildTextOpt("headerStructName")

  let rp = updateProperties(parentRp, pNode)

  for intNode in pNode.findAllDirect("interrupt"):
    result.interrupts.add SvdInterrupt(
      name: intNode.getChildTextExc("name"),
      description: intNode.getChildTextOpt("description"),
      value: intNode.getChildTextExc("value").parseHexOrDecInt
    )

  let registersNode = pNode.child("registers")
  if not isNil(registersNode):
    for clusterNode in registersNode.findAllDirect("cluster"):
      result.clusters.add clusterNode.parseCluster(rp)
    for registerNode in registersNode.findAllDirect("register"):
      result.registers.add registerNode.parseRegister(rp)

  result.dimGroup = pNode.parseDimElementGroup()
  result.setAllTypeNames()

###############################################################################
# Public Procedures
###############################################################################
proc readSVD*(path: string): SvdDevice =
  result = SvdDevice.new()
  let
    xml = path.loadXml()
    deviceName = xml.getChildTextExc("name")
    deviceDescription = xml.getChildTextExc("description").strip()

  result.metadata = SvdDeviceMetadata(
    file: path,
    name: deviceName,
    description: deviceDescription,
    licenseBlock: xml.getChildTextOpt("licenseText")
  )

  let cpuNode = xml.getChildOrError("cpu")
  result.cpu = SvdCpu(
    name: cpuNode.getChildTextExc("name"),
    revision: cpuNode.getChildTextExc("revision"),
    endian: cpuNode.getChildTextExc("endian"),
    mpuPresent: cpuNode.getChildTextExc("mpuPresent").parseBool,
    fpuPresent: cpuNode.getChildTextExc("fpuPresent").parseBool(),
    nvicPrioBits: cpuNode.getChildTextExc("nvicPrioBits").parseHexOrDecInt(),
    vendorSystickConfig: cpuNode.getChildTextExc("vendorSystickConfig").parseBool,
    vtorPresent: cpuNode.getChildBoolOrDefault("vtorPresent", true)
  )

  let deviceRp = SvdRegisterProperties(size: 32, access: raReadWrite).updateProperties(xml)
  for pNode in xml.getChildOrError("peripherals").findAllDirect("peripheral"):
    result.peripherals.add pNode.parsePeripheral(deviceRp)

export options
