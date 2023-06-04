import std/strutils
import std/xmlparser
import std/xmltree
import std/options
import std/strtabs
import std/tables
import std/strformat

import regex

import ./basetypes
import ./utils


func parseHexOrDecInt(s: string) : int64 =
  # Parse string to integer. According to CMSIS spec, if the string
  # starts with 0X or 0x it is to be interpreted as hexadecimal.
  # TODO: Implementing parsing binary if string starts with #
  if s.toLower().startsWith("0x"):
    result = fromHex[int64](s)
  elif s[0] == '#':
    raise newException(NotImplementedError, "binary value parsing not yet implemented")
  else:
    result = parseBiggestInt s

func getChildTextDefault(pNode: XmlNode, tag: string, default=""): string =
  # Get text of child tag, or none if tag not found.
  let c = pNode.child(tag)
  result =
    if c.isNil:
      default
    elif c.kind notin {xnText, xnCData, xnElement}:
      default
    else:
      c.innerText

func getChildTextOpt(pNode: XmlNode, tag: string): Option[string] =
  # Get text of child tag, or none if tag not found.
  let c = pNode.child(tag)
  if c.isNil:
    return none(string)
  elif c.kind notin {xnText, xnCData, xnElement}:
    return none(string)
  else:
    return some(c.innerText)


func getChildIntOpt(pNode: XmlNode, tag: string): Option[int64] =
    # Get text of child tag as int, or none if tag not found.
    let text = pNode.getChildTextOpt(tag)
    if text.isNone:
      return none int64
    else:
      return some text.get().parseHexOrDecInt


func getChildNaturalOpt(pNode: XmlNode, tag: string): Option[Natural] =
    # Get text of child tag as Natural, or none if tag not found.
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


func parseFieldEnum(eNode: XmlNode, parentId: SvdId): SvdFieldEnum =
  assert eNode.tag == "enumeratedValues"
  new result
  result.name = eNode.getChildTextOpt("name")
  result.derivedFrom = eNode.attrOpt("derivedFrom")
  result.headerEnumName = eNode.getChildTextOpt("headerEnumName")

  let usage = eNode.child("usage")
  if not isNil(usage) and usage.innerText != "read-write":
    raise newException(NotImplementedError, "Separate read/write enums not implemented")

  result.id =
    if isSome(result.name) and result.name.get.len > 0:
      parentId / result.name.get
    else:
      let defaultName =
        if usage.isNil:
          "enum"
        else:
          case usage.innerText.toLower.strip:
          of "read":
            "readEnum"
          of "write":
            "writeEnum"
          else:
            "enum"
      parentId / defaultName

  for enumValueNode in eNode.findAllDirect("enumeratedValue"):
    let valueNode = enumValueNode.child("value")
    if isNil(valueNode):
      # Support for isDefault not implementented, ignore
      continue
    let
      name = enumValueNode.getChildTextExc("name")
      val = valueNode.innerText.parseHexOrDecInt
    result.values.add (name: name, val: val.int)

func parseDimElementGroup(n: XmlNode): SvdDimElementGroup =
  result.dim = n.getChildNaturalOpt("dim")
  result.dimIncrement = n.getChildNaturalOpt("dimIncrement")
  #result.dimIndex = n.getChildTextOpt("dimIndex")
  result.dimName = n.getChildTextOpt("dimName")
  #result.dimIndex = n.getChildTextOpt("dimArrayIndex")

  if result.dim.isSome and result.dimIncrement.isNone:
    raise newException(SVDError, "Node has dim but no dimIncrement")


func parseAccess(node: XmlNode): Option[SvdRegisterAccess] =
  let access = node.getChildTextOpt("access")
  if access.isSome:
    result = some(case access.get:
      of "read-write": raReadWrite
      of "read-only": raReadOnly
      of "write-only": raWriteOnly
      of "writeOnce": raWriteOnce
      of "read-writeOnce": raReadWriteOnce
      else: raise newException(SVDError, "Unknown access value: " & access.get)
    )


func parseField(fNode: XmlNode, parentId: SvdId): SvdField =
  assert fNode.tag == "field"
  new result
  result.name = fNode.getChildTextExc("name")
  result.derivedFrom = fNode.attrOpt("derivedFrom")
  result.description = fNode.getChildTextOpt("description")
  result.access = fNode.parseAccess
  result.id = parentId / result.name

  # Get list of child tag names
  var childTags = newSeq[string]()
  for elem in fNode:
    if elem.kind == xnElement: childTags.add elem.tag

  # SVD spec allows three ways to specify the location and size of bitfields
  # Here we check for th three possibilities and parse them to (lsb, msb) pairs.
  if childTags.contains("bitOffset") and childTags.contains("bitWidth"):
    # bitRangeOffsetWidthStyle
    let
      bitOffset: Natural = fNode.child("bitOffset").innerText.parseHexOrDecInt
      bitWidth: Natural = fNode.child("bitWidth").innerText.parseHexOrDecInt
    result.lsb = bitOffset
    result.msb = (bitOffset + bitWidth - 1).Natural
  elif childTags.contains("lsb") and childTags.contains("msb"):
    # bitRangeOffsetWidthStyle
    result.lsb = fNode.child("lsb").innerText.parseHexOrDecInt
    result.msb = fNode.child("msb").innerText.parseHexOrDecInt
  elif childTags.contains("bitRange"):
    # bitRangePattern
    let
      pat = re"\[([[:alnum:]]+):([[:alnum:]]+)\]"
      text = fNode.child("bitRange").innerText
    var m: RegexMatch
    doAssert text.match(pat, m)
    result.msb = m.group(0, text)[0].parseHexOrDecInt
    result.lsb = m.group(1, text)[0].parseHexOrDecInt
  else:
    raise newException(SVDError, fmt"Invalid bit range specification in field '{result.name}'")

  let enumVals = fNode.child("enumeratedValues")
  if not isNil(enumVals):
    result.enumValues = some enumVals.parseFieldEnum(result.id)
  else:
    result.enumValues = none(SvdFieldEnum)

  result.dimGroup = fNode.parseDimElementGroup()


func parseProperties(node: XmlNode): SvdRegisterProperties =
  result.size = node.getChildNaturalOpt("size")
  result.access = node.parseAccess
  result.resetValue = node.getChildIntOpt("resetValue")


# Forward declaration for mutually recursive procs
func parseRegisterTreeNode(xml: XmlNode, parent: SvdId): SvdRegisterTreeNode


func parseChildRegisters(xml: XmlNode, parent: SvdId): Option[seq[SvdRegisterTreeNode]] =
  var regNodes: seq[SvdRegisterTreeNode]
  for xmlChild in xml:
    if xmlChild.kind == xnElement and xmlChild.tag in ["register", "cluster"]:
      regNodes.add parseRegisterTreeNode(xmlChild, parent)
  if regNodes.len > 0:
    result = some regNodes


func parseRegisterTreeNode(xml: XmlNode, parent: SvdId): SvdRegisterTreeNode =
  case xml.tag:
  of "register":
    result = SvdRegisterTreeNode(kind: rnkRegister)
  of "cluster":
    result = SvdRegisterTreeNode(kind: rnkCluster)
  else:
    raise newException(ValueError, "Unknown tag " & xml.tag & " for register tree.")

  result.name = xml.getChildTextExc("name")
  result.baseName = stripPlaceHolder result.name
  result.id = parent / result.name
  result.derivedFrom = xml.attrOpt("derivedFrom")
  result.addressOffset = xml.getChildTextExc("addressOffset").parseHexOrDecInt.Natural
  result.description = xml.getChildTextOpt("description")
  result.properties = xml.parseProperties()
  result.dimGroup = xml.parseDimElementGroup()

  case result.kind:
  of rnkRegister:
    let fieldsTag = xml.child("fields")
    if not isNil(fieldsTag):
      for fieldNode in fieldsTag.findAllDirect("field"):
        result.fields.add fieldNode.parseField(result.id)
  of rnkCluster:
    result.headerStructName = xml.getChildTextOpt("headerStructName")
    result.registers = xml.parseChildRegisters(result.id)


func parsePeripheral(pNode: XmlNode): SvdPeripheral =
  assert pNode.tag == "peripheral"

  new result
  result.name = pNode.getChildTextExc("name")
  result.baseName = stripPlaceHolder result.name
  result.id = result.name.toSvdId
  result.derivedFrom = pNode.attrOpt("derivedFrom")
  result.description = pNode.getChildTextOpt("description")
  result.baseAddress = pNode.getChildTextExc("baseAddress").parseHexOrDecInt.Natural
  result.appendToName = pNode.getChildTextOpt("appendToName")
  result.prependToName = pNode.getChildTextOpt("prependToName")
  result.headerStructName = pNode.getChildTextOpt("headerStructName")
  result.properties = parseProperties(pNode)

  for intNode in pNode.findAllDirect("interrupt"):
    result.interrupts.add SvdInterrupt(
      name: intNode.getChildTextExc("name"),
      description: intNode.getChildTextDefault("description", ""),
      value: intNode.getChildTextExc("value").parseHexOrDecInt.int
    )

  result.dimGroup = pNode.parseDimElementGroup()

  let registersNode = pNode.child("registers")
  if registersNode.isNil:
    result.registers = none seq[SvdRegisterTreeNode]
  else:
    result.registers = registersNode.parseChildRegisters(result.id)


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
    nvicPrioBits: cpuNode.getChildTextExc("nvicPrioBits").parseHexOrDecInt.int,
    vendorSystickConfig: cpuNode.getChildTextExc("vendorSystickConfig").parseBool,
    vtorPresent: cpuNode.getChildBoolOrDefault("vtorPresent", true)
  )

  result.properties = parseProperties(xml)
  for pNode in xml.getChildOrError("peripherals").findAllDirect("peripheral"):
    let periph =  pNode.parsePeripheral
    result.peripherals[periph.id] = periph
