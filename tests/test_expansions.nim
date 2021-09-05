import unittest
import svdparser
import expansions
import basetypes
import utils

func derived(dev: SvdDevice): SvdDevice =
  result = dev.deepCopy
  result.peripherals.expandDerives

suite "Derivations":
  setup:
    let
      device {.used.} = readSVD("./tests/ARM_Example.svd").derived
      samd21 {.used.} = readSVD("./tests/ATSAMD21G18A.svd").derived

  test "Peripheral derived":
    let
      timer0 = device.getPeriphByName("TIMER0")
      timer1 = device.getPeriphByName("TIMER1")
      timer2 = device.getPeriphByName("TIMER2")
      port_iobus = samd21.getPeriphByName("PORT_IOBUS")

    check:
      timer1.baseAddress == 0x40010100
      timer1.interrupts.len == 1
      timer1.interrupts[0].name == "TIMER1"
      timer1.registers.len == timer0.registers.len
      timer1.nimTypeName == timer0.nimTypeName

      timer2.baseAddress == 0x40010200
      timer2.interrupts.len == 1
      timer2.interrupts[0].name == "TIMER2"
      timer2.registers.len == timer0.registers.len
      timer2.nimTypeName == timer0.nimTypeName

      port_iobus.prependToName.get == "PORT_IOBUS_"

  test "Register derived":
    let
      port = samd21.getPeriphByName("PORT")
      pmux1 = port.findRegisterByName("PMUX1_%s")
      pmux0 = port.findRegisterByName("PMUX0_%s")

    check:
      pmux1.fields.len == pmux0.fields.len
      pmux1.nimTypeName == pmux0.nimTypeName
      pmux1.addressOffset == 0xb0

      pmux1.properties.size == pmux0.properties.size
      pmux1.properties.access == pmux0.properties.access
