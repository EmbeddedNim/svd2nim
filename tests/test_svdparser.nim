import std/unittest
import std/sequtils
import std/strutils
import std/options
import ../svdparser
import ../expansions {.all.}
import ../basetypes
import ../utils

# Test suites

suite "Parser Tests":
  setup:
    let
      device {.used.} = readSVD("./tests/ARM_Example.svd")
      samd21 {.used.} = readSVD("./tests/ATSAMD21G18A.svd")

  test "Parse peripheral data":
    let
      timer0 = device.getPeriphByName("TIMER0")
      timer1 = device.getPeriphByName("TIMER1")
      adc0 = device.getPeriphByName("ADC0")

    check:
      timer0.description.get() == "32 Timer / Counter, counting up or down from different sources"
      timer0.baseAddress == 0x40010000
      timer0.derivedFrom.isNone
      timer0.prependToName.isNone
      timer0.appendToName.isNone
      timer0.headerStructName.isNone

      timer1.derivedFrom.isSome()
      timer1.derivedFrom.get() == "TIMER0"

      adc0.prependToName.get == "prefix"
      adc0.appendToName.get == "suffix"
      adc0.headerStructName.get == "ADC0_Struct_Type"

  test "Parse cluster data":
    let rtc = samd21.getPeriphByName("RTC")

    check(rtc.clusters.len == 3)
    let mode0 = rtc.clusters[0]
    check:
      mode0.name == "MODE0"
      mode0.description.get == "32-bit Counter with Single 32-bit Compare"
      mode0.headerStructName.get == "RtcMode0"
      mode0.addressOffset == 0
      mode0.registers.len == 11
      mode0.derivedFrom.isNone

  test "Parse register data":
    let
      timer0 = device.getPeriphByName("TIMER0")
      regCR = timer0.registers[0]

    check:
      regCR.name == "CR"
      regCR.description.get == "Control Register"
      regCR.addressOffset == 0
      regCR.derivedFrom.isNone
      regCR.fields.len == 12

  test "Parse field enum":
    let
      timer0 = device.getPeriphByName("TIMER0")
      cr = timer0.registers[0]
      mode = cr.fields[3]
      mode_enum: SvdFieldEnum = mode.enumValues.get

    check:
      mode.name == "MODE"
      mode_enum.name.isNone
      mode_enum.headerEnumName.isNone
      mode_enum.values.len == 5
      mode_enum.values[0] == (name: "Continous", val: 0)
      mode_enum.values[1] == (name: "Single_ZERO_MAX", val: 1)
      mode_enum.values[2] == (name: "Single_MATCH", val: 2)
      mode_enum.values[3] == (name: "Reload_ZERO_MAX", val: 3)
      mode_enum.values[4] == (name: "Reload_MATCH", val: 4)

  test "Parse field data":
    let
      timer0 = device.getPeriphByName("TIMER0")
      cr = timer0.registers[0]
      cnt = cr.fields[2]

    let
      ac = samd21.getPeriphByName("AC")
      statusa = ac.registers[6]
      wstate0 = statusa.fields[2]
      gclk = samd21.getPeriphByName("GCLK")
      clkctrl = gclk.registers[2]

      id = clkctrl.fields[0]
      gen = clkctrl.fields[1]
      clken = clkctrl.fields[2]
      wrtlock = clkctrl.fields[3]

    check:
      cnt.name == "CNT"
      cnt.bitRange == (lsb: 2.Natural, msb: 3.Natural)

      wstate0.name == "WSTATE0"
      wstate0.description.get == "Window 0 Current State"
      wstate0.derivedFrom.isNone
      wstate0.bitRange == (lsb: 4.Natural, msb: 5.Natural)

      id.name == "ID"
      id.bitRange == (lsb: 0.Natural, msb: 5.Natural)

      gen.name == "GEN"
      gen.bitRange == (lsb: 8.Natural, msb: 11.Natural)

      clken.name == "CLKEN"
      clken.bitRange == (lsb: 14.Natural, msb: 14.Natural)

  test "Parse interrupts":
    let
      timer0 = device.getPeriphByName("TIMER0")
      timer1 = device.getPeriphByName("TIMER1")
      timer2 = device.getPeriphByName("TIMER2")

    check:
      timer0.interrupts.len == 1
      timer1.interrupts.len == 1
      timer2.interrupts.len == 1

      timer0.interrupts[0].name == "TIMER0"
      timer0.interrupts[0].description.get == "Timer 0 interrupt"
      timer0.interrupts[0].value == 0

      timer1.interrupts[0].name == "TIMER1"
      timer1.interrupts[0].description.get == "Timer 1 interrupt"
      timer1.interrupts[0].value == 4

      timer2.interrupts[0].name == "TIMER2"
      timer2.interrupts[0].description.get == "Timer 2 interrupt"
      timer2.interrupts[0].value == 6


  test "Parse dimElementGroup":
    let
      timer0 = device.getPeriphByName("TIMER0")
      reload = timer0.findRegisterByName("RELOAD[%s]")

      ac = samd21.getPeriphByName("AC")
      compctrl = ac.findRegisterByName("COMPCTRL%s")

      port = samd21.getPeriphByName("PORT")
      pmux1 = port.findRegisterByName("PMUX1_%s")

    check:
      reload.dimGroup.dim.get == 4
      reload.dimGroup.dimIncrement.get == 4

      compctrl.dimGroup.dim.get == 2
      compctrl.dimGroup.dimIncrement.get == 0x4

      pmux1.dimGroup.dim.get == 16
      pmux1.dimGroup.dimIncrement.get == 0x1


func derived(dev: SvdDevice): SvdDevice =
  result = dev.deepCopy
  result.peripherals.expandDerives

suite "Derivations and expansions":
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

suite "Dim Lists":
  setup:
    let
      samd21Periphs {.used.} =
        readSVD("./tests/ATSAMD21G18A.svd").peripherals.expandAllDimLists

  test "Register dim list expanded":
    let
      ac = samd21Periphs.filterIt(it.name == "AC")[0]
      compctrl = ac.registers.filterIt(it.name.contains("COMPCTRL"))

    check:
      compctrl.len == 2
      compctrl[0].name == "COMPCTRL0"
      compctrl[1].name == "COMPCTRL1"
      compctrl[1].addressOffset - compctrl[0].addressOffset == 4
      compctrl[0].description == compctrl[1].description
      compctrl[0].fields.len == compctrl[1].fields.len
      compctrl[0].nimTypeName == compctrl[1].nimTypeName
      compctrl[0].properties.size == compctrl[1].properties.size
      compctrl[0].properties.access == compctrl[1].properties.access
