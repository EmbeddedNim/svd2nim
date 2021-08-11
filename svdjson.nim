import json

import svdparser

func toJson(cpu: svdCpu): JsonNode =
  %* {
    "name": cpu.name,
    "revision": cpu.revision,
    "endian": cpu.endian,
    "mpuPresent": cpu.mpuPresent,
    "fpuPresent": cpu.fpuPresent,
    "nvicPrioBit": cpu.nvicPrioBits,
    "vendorSystickConfig": cpu.vendorSystickConfig
  }

func toJson(md: svdDeviceMetadata): JsonNode =
  %* {
    "file": md.file,
    "name": md.name,
    "nameLower": md.nameLower,
    "description": md.description,
    "licenseBlock": md.licenseBlock
  }

func toJson(f: svdField): JsonNode =
  %* {
    "name": f.name,
    "description": f.description,
    "value": f.value,
  }

func toJson(fseq: openArray[svdField]): JsonNode =
  result = newJArray()
  for f in fseq:
    result.add f.toJson

func toJson(regSeq: openArray[svdRegister]): JsonNode

func toJson(reg: svdRegister): JsonNode =
  %* {
    "name": reg.name,
    "address": reg.address,
    "description": reg.description,
    "bitfields": reg.bitfields.toJson,
    "registers": reg.registers.toJson,
    "dim": reg.dim,
    "elementSize": reg.elementSize,
  }

func toJson(regSeq: openArray[svdRegister]): JsonNode =
  result = newJArray()
  for f in regSeq:
    result.add f.toJson

func toJson(periphSeq: openArray[svdPeripheral]): JsonNode

func toJson(p: svdPeripheral): JsonNode =
  %* {
    "name": p.name,
    "groupName": p.groupName,
    "typeName": p.typeName,
    "description": p.description,
    "clusterName": p.clusterName,
    "baseAddress": p.baseAddress,
    "address": p.address,
    "derivedFrom": p.derivedFrom,
    "registers": p.registers.toJson,
    "subtypes": p.subtypes.toJson,
    "dim": p.dim,
    "elementSize": p.elementSize,
  }

func toJson(periphSeq: openArray[svdPeripheral]): JsonNode =
  result = newJArray()
  for f in periphSeq:
    result.add f.toJson

func toJson(ipt: svdInterrupt): JsonNode =
  %* {
    "name": ipt.name,
    "index": ipt.index,
    "description": ipt.description,
  }

func toJson(iptSeq: openArray[svdInterrupt]): JsonNode =
  result = newJArray()
  for f in iptSeq:
    result.add f.toJson

func toJson*(dev: svdDevice): JsonNode =
  %* {
    "peripherals": toJson(dev.peripherals),
    "interrupts": toJson(dev.interrupts),
    "metadata": toJson(dev.metadata),
    "cpu": toJson(dev.cpu),
  }
