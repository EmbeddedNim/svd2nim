import strutils
import xmlparser
import xmltree
import re
import tables
import strtabs
import algorithm
import sequtils

###############################################################################
# Models
###############################################################################

type
  svdField* = ref object of RootObj
    name*: string
    description*: string
    value*: int

type
  svdRegister* = ref object of RootObj
    name*: string
    address*: uint32
    description*: string
    bitfields*: seq[svdField]
    registers*: seq[svdRegister]
    dim*: int
    elementSize*: int

type
  svdPeripheral* = ref object of RootObj
    name*: string
    groupName*: string
    typeName*: string
    description*: string
    clusterName*: string
    baseAddress*: uint32
    address*: uint32
    derivedFrom*: string
    registers*: seq[svdRegister]
    subtypes*: seq[svdPeripheral]
    dim*: int
    elementSize*: int

type
  svdDeviceMetadata* = ref object of RootObj
    file*: string
    descriptorSource*: string
    name*: string
    nameLower*: string
    description*: string
    licenseBlock*: string

type
  svdInterrupt* = ref object of RootObj
    name*: string
    index*: int
    description*: string

type
  svdCpu* = ref object of RootObj
    name*: string
    revision*: string
    endian*: string
    mpuPresent*: int
    fpuPresent*: int
    nvicPrioBits*: int
    vendorSystickConfig*: int

type
  svdDevice* = ref object of RootObj
    peripherals*: seq[svdPeripheral]
    interrupts*: seq[svdInterrupt]
    metadata*: svdDeviceMetadata
    cpu*: svdCpu


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

proc addInterrupt(interrupts: var Table[string, svdInterrupt], intrName: string, intrIndex: int, description: string) =
  if interrupts.hasKey(intrName):
    if interrupts[intrName].index != intrIndex:
      raise newException(ValueError, "Interrupt with the same name has different indexes: $# ($¤ vs $#)" % [intrName, interrupts[intrName].index.intToStr(), intrIndex.intToStr()])
    if not (description in interrupts[intrName].description.split(" # ")):
      interrupts[intrName].description &= " # " & description
  else:
    interrupts[intrName] = svdInterrupt(
      name: intrName,
      index: intrIndex,
      description: description
    )

proc parseBitfields(groupName: string, regName: string, fieldsNodes: seq[XmlNode], bitFieldPrefix: string): seq[svdField] =
  var fields: seq[svdField]
  if fieldsNodes.len() > 0:
    for fieldsNode in fieldsNodes:
      for fieldNode in fieldsNode.findAll("field"):
        var fieldName = fieldNode.child("name").getText().replace("__","_")
        var lsbTags = fieldNode.findAll("lsb")
        var lsb: int
        if lsbTags.len() == 1:
          lsb = lsbTags[0].getText.parseInt()
        else: # stm32 pos
          lsb = fieldNode.child("bitOffset").getText().parseInt()
        var msbTags = fieldNode.findAll("msb")
        var msb: int
        if msbTags.len() == 1:
          msb = msbTags[0].getText().parseInt()
        else: # stm32 msk
          msb = fieldNode.child("bitWidth").getText().parseInt()
        # bitOffset == Pos
        # bitWidth == Msk
        fields.add(
          svdField(
            name: "$#_$#$#_$#_Pos" % [groupName, bitFieldPrefix, regName, fieldName],
            description: "Position of $# field." % fieldName,
            value: lsb
          )
        )
        fields.add(
          svdField(
            name: "$#_$#$#_$#_Msk" % [groupName, bitFieldPrefix, regName, fieldName],
            description: "Bit mask of $# field." % fieldName,
            value: msb shl lsb#int((0xffffffff shr (31 - (msb - lsb))) shl lsb)
          )
        )
        #if lsb == msb: # single bit
        fields.add(
          svdField(
            name: "$#_$#$#_$#" % [groupName, bitFieldPrefix, regName, fieldName],
            description: "Bit $#." % fieldName,
            value: msb shl lsb
          )
        )
        for enumNode in fieldNode.findAll("enumeratedValue"):
          var enumName = enumNode.child("name").getText()
          var enumDescription = enumNode.child("description").getText()
          var enumValue = enumNode.child("value").getText().parseInt()
          fields.add(
            svdField(
              name: "$#_$#$#_$#_$#" % [groupName, bitFieldPrefix, regName, fieldName, enumName],
              description: enumDescription,
              value: enumValue
            )
          )
  return fields

proc parseRegister(groupName: string, regNode: XmlNode, baseAddress: int, bitFieldPrefix: string): seq[svdRegister] =
  var regName = regNode.child("name").getText()
  var regDescription = regNode.child("description").getText().formatText()
  var offsetNodes = regNode.findAll("offset")
  if offsetNodes.len() == 0:
    offsetNodes = regNode.findAll("addressOffset")
  var address = baseAddress + offsetNodes[0].getText().parseHexInt()

  var size = 4
  var nodeSizes = regNode.findAll("size")
  if nodeSizes.len() > 0:
    size = nodeSizes[0].getText().parseHexInt() # 8

  var dimNodes = regNode.findAll("dim")
  var fieldsNodes = regNode.findAll("fields")

  var dim: int
  if dimNodes.len() > 0:
    dim = dimNodes[0].getText().parseInt()
    var dimIncrement = regNode.child("dimIncrement").getText().parseHexInt()
    if "[%s]" in regName:
      # just a normal array of registers
      regName = regName.replace("[%s]", "")
    elif "%s" in regName:
      # a "spaced array" of registers, special processing required
      # we need to generate a separate register for each "element"
      var results: seq[svdRegister]
      for i in 0..dim:
        var regAddress = address + (i * dimIncrement)
        results.add(
          svdRegister(
            name: regName.replace("%s", i.intToStr()),
            address: uint32(regAddress),
            description: regDescription.replace("\n", " "),
            dim: dim,
            elementSize: size
          )
        )
      # Set first result bitfield
      var shortName = regName.replace("_%s", "").replace("%s","")
      results[0].bitfields = parseBitfields(groupName, shortName, fieldsNodes, bitFieldPrefix)
      return results
  # Dim empty
  var reg: seq[svdRegister] = @[svdRegister(
    name: regName,
    address: uint32(address),
    description: regDescription.replace("\n", " "),
    bitfields: parseBitFields(groupName, regName, fieldsNodes, bitFieldPrefix),
    dim: dim,
    elementSize: size
  )]
  return reg

proc updatePeripheralType(peripherals: seq[svdPeripheral]): seq[svdPeripheral] =
  # Updates the peripheral type
  # Initial peripheralType == groupName
  var sortedPeripherals = peripherals
  sortedPeripherals.sort(proc (x,y: svdPeripheral): int = cmp(x.name, y.name))

  for peripheral in sortedPeripherals:
    if peripheral.derivedFrom != "":
      continue
    var groupPeriphs = sortedPeripherals
    groupPeriphs.keepItIf(it.groupName == peripheral.groupName)

    if groupPeriphs.len() > 1:
      for grpPeriph in groupPeriphs:
        for i in 0..grpPeriph.registers.len()-1:
          if peripheral.typeName != "":
            break
          if not peripheral.registers.anyIt(it.name == grpPeriph.registers[i].name):
            peripheral.typeName = peripheral.name
            break
          else:
            peripheral.typeName = peripheral.groupName

    if peripheral.typeName == "":
      peripheral.typeName = peripheral.groupName

  for dperiph in sortedPeripherals:
    if dperiph.derivedFrom == "":
      continue
    var parentPeriph = sortedPeripherals
    parentPeriph.keepItIf(it.name == dperiph.derivedFrom)
    dperiph.typeName = parentPeriph[0].typeName

  return sortedPeripherals
###############################################################################
# Public Procedures
###############################################################################
proc readSVD*(path: string, sourceUrl: string): svdDevice =
  echo("Parsing SVD file: $#" % path)
  var device = svdDevice.new()
  var xml = path.loadXml()
  var deviceName = xml.child("name").getText()
  var deviceDescription = xml.child("description").getText().strip()
  var licenseTexts = xml.findAll("licenseText")
  var licenseText: string
  if licenseTexts.len() == 0:
    licenseText = ""
  elif licenseTexts.len() == 1:
    licenseText = licenseTexts[0].getText().formatText()
  else:
    raise newException(ValueError, "multiple <licenseText> elements")

  device.peripherals = @[]
  var peripheralDict = initTable[string, svdPeripheral]()
  var groups = initTable[string, svdPeripheral]()

  var interrupts = initTable[string, svdInterrupt]()

  for periphNode in xml.findAll("peripheral"):
    var peripheral: svdPeripheral
    var name = periphNode.child("name").getText()
    if name == "C_ADC":
      name = "ADC_Common"
    var descriptionTags = periphNode.findAll("description")
    var description = ""
    if descriptionTags.len() > 0:
      description = descriptionTags[0].getText().formatText()
    var baseAddress = periphNode.child("baseAddress").getText().parseHexInt()
    var groupNameTags = periphNode.findAll("groupName")
    var groupName = ""
    if groupNameTags.len() > 0:
      groupName = groupNameTags[0].getText()

    var interruptsNodes = periphNode.findAll("interrupt")
    for interrupt in interruptsNodes:
      var intrName =interrupt.child("name").getText()
      var intrIndex = interrupt.child("value").getText().parseInt()
      addInterrupt(interrupts, intrName, intrIndex, description)

    if (not periphNode.attrs().isNil() and periphNode.attrs().hasKey("derivedFrom")):# or (groupName in groups):
      var derivedFrom: svdPeripheral
      if not periphNode.attrs().isNil() and periphNode.attrs().hasKey("derivedFrom"):
        var derivedFromName = periphNode.attrs()["derivedFrom"]
        derivedFrom = peripheralDict[derivedFromName]
      else:
        derivedFrom = groups[groupName]

      peripheral = svdPeripheral(
        name: name,
        groupName: derivedFrom.groupName,
        description: if description != "": description else: derivedFrom.description,
        baseAddress: uint32(baseAddress),
        derivedFrom: periphNode.attrs()["derivedFrom"]
      )
      device.peripherals.add(peripheral)
      peripheralDict[name] = peripheral

      if derivedFrom.subtypes.len() > 0:
        for subtype in derivedFrom.subtypes:
          var subp = svdPeripheral(
            name: name & "_" & subtype.clusterName,
            groupName: subtype.groupName,
            description: subtype.description,
            baseAddress: uint32(baseAddress)
          )
          device.peripherals.add(subp)
      continue

    peripheral = svdPeripheral(
      name: name,
      groupName: if groupName != "": groupName else: name,
      description: description,
      baseAddress: uint32(baseAddress)
    )

    device.peripherals.add(peripheral)
    peripheralDict[name] = peripheral

    if not (groupName in groups) and (groupName != ""):
      groups[groupName] = peripheral

    var regsNodes = periphNode.findAll("registers")

    if regsNodes.len() > 0:
      if regsNodes.len() != 1:
        raise newException(ValueError, "expected just one <registers> in a <peripheral>")
      for register in regsNodes[0].findAll("register"):
        peripheral.registers.add(parseRegister((if groupName != "": groupName else: name), register, baseAddress,""))

      for cluster in regsNodes[0].findAll("cluster"):
        var clusterName = cluster.child("name").getText().replace("[%s]","")
        var clusterDescription = cluster.child("description").getText()
        var clusterPrefix = clusterName & "_"
        var clusterOffset = cluster.child("addressOffset").getText().parseHexInt()
        var dim: int
        var dimIncrement: int
        if cluster.child("dim").isNil():
          if clusterOffset == 0:
            # make this a seperate peripheral
            var cpRegisters: seq[svdRegister] = @[]
            for regNode in cluster.findAll("register"):
              cpRegisters.add(parseRegister(groupName, regNode, baseAddress, clusterPrefix))
            cpRegisters = cpRegisters.sortedbyIt(it.address)
            var clusterPeripheral = svdPeripheral(
              name: name & "_" & clusterName,
              groupName: groupName & "_" & clusterName,
              description: description & " - " & clusterName,
              clusterName: clusterName,
              baseAddress: uint32(baseAddress),
              registers: cpRegisters
            )
            device.peripherals.add(clusterPeripheral)
            peripheral.subtypes.add(clusterPeripheral)
            continue

        else:
          dim = cluster.child("dim").getText().parseInt()
          dimIncrement = cluster.child("dimIncrement").getText().parseHexInt()
        var clusterRegisters: seq[svdRegister] = @[]
        for regNode in cluster.findAll("register"):
          clusterRegisters.add(parseRegister((if groupName != "": groupName else: name), regNode, baseAddress + clusterOffset, clusterPrefix))
        clusterRegisters = clusterRegisters.sortedByIt(it.address)
        if dimIncrement == 0:
          var lastReg = clusterRegisters[^1]
          var lastAddress = lastReg.address
          if lastReg.dim > 0:
            lastAddress = uint32(int(lastReg.address) + lastReg.dim * lastReg.elementSize)
          var firstAddress = clusterRegisters[0].address
          dimIncrement = int(lastAddress - firstAddress)
        peripheral.registers.add(svdRegister(
          name: clusterName,
          address: uint32(baseAddress + clusterOffset),
          description: clusterDescription,
          registers: clusterRegisters,
          dim: dim,
          elementSize: dimIncrement
        ))
    peripheral.registers.sort(proc (x,y: svdRegister): int =
      result = cmp(x.address, y.address))

  device.peripherals = updatePeripheralType(device.peripherals)

  device.peripherals.sort(proc (x,y: svdPeripheral): int =
    result = cmp(x.name, y.name))

  for key in interrupts.keys:
    device.interrupts.add(interrupts[key])
  device.interrupts.sort(proc (x,y: svdInterrupt): int =
    result = cmp(x.index, y.index))

  var licenseBlock = ""
  if licenseText != "":
    licenseBlock = "//    " & licenseText.replace("\n","\n//    ")
    licenseBlock = "\n" & licenseBlock
  device.metadata = svdDeviceMetadata(
    file: path,
    descriptorSource: sourceUrl,
    name: deviceName,
    nameLower: deviceName.toLower(),
    description: deviceDescription,
    licenseBlock: licenseBlock
  )
  var cpuNode = xml.child("cpu")
  device.cpu = svdCpu(
    name: cpuNode.child("name").getText(),
    revision: cpuNode.child("revision").getText(),
    endian: cpuNode.child("endian").getText(),
    mpuPresent: int(cpuNode.child("mpuPresent").getText().parseBool()),
    fpuPresent: int(cpuNode.child("fpuPresent").getText().parseBool()),
    nvicPrioBits: cpuNode.child("nvicPrioBits").getText().parseInt(),
    vendorSystickConfig: int(cpuNode.child("vendorSystickConfig").getText().parseBool())
  )
  return device