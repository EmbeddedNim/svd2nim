import std/options
import basetypes

func findRegister*(n: SvdRegisterParent, name: string): SvdRegisterTreeNode =
  for c in n.registers.get:
    if c.name == name:
      return c


func findRegister*(p: SvdPeripheral, id: SvdId): SvdRegisterTreeNode =
  let idParts = id.split()
  var
    partIndex = 1 # 0 is the peripheral
    curPart = idParts[partIndex]
    curNode = p.findRegister(curPart)

  while partIndex < idParts.high:
    inc partIndex
    curPart = idParts[partIndex]
    curNode = curNode.findRegister(curPart)

  result = curNode


func findRegister*(dev: SvdDevice, id: SvdId): SvdRegisterTreeNode =
  let periph = dev.peripherals[id.split()[0].toSvdId]
  result = periph.findRegister(id)


func findField*(n: SvdRegisterTreeNode, name: string): SvdField =
  assert n.kind == rnkRegister
  for c in n.fields:
    if c.name == name:
      return c


func findField*(p: SvdPeripheral, id: SvdId): SvdField =
  result = p.findRegister(id.parent).findField(id.name)


func findField*(dev: SvdDevice, id: SvdId): SvdField =
  result = dev.findRegister(id.parent).findField(id.name)
