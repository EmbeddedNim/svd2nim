import std/unittest
import std/options
import std/tables

import svdparser
import basetypes
import utils_for_tests

# Test suites

suite "Parser Tests":
  setup:
    let
      device {.used.} = readSVD("./tests/ARM_Example.svd")
      samd21 {.used.} = readSVD("./tests/ATSAMD21G18A.svd")

  test "Parse peripheral data":
    let
      timer0 = device.peripherals["TIMER0".toSvdId]
      timer1 = device.peripherals["TIMER1".toSvdId]
      adc0 = device.peripherals["ADC0".toSvdId]

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
    let rtc = samd21.peripherals["RTC".toSvdId]

    check rtc.registers.get().len == 3
    let mode0 = rtc.registers.get()[0]
    check:
      mode0.name == "MODE0"
      mode0.description.get == "32-bit Counter with Single 32-bit Compare"
      mode0.headerStructName.get == "RtcMode0"
      mode0.addressOffset == 0
      mode0.registers.get().len == 11
      mode0.derivedFrom.isNone

  test "Parse register data":
    let
      timer0 = device.peripherals["TIMER0".toSvdId]
      regCR = timer0.registers.get()[0]

    check:
      regCR.name == "CR"
      regCR.description.get == "Control Register"
      regCR.addressOffset == 0
      regCR.derivedFrom.isNone
      regCR.fields.len == 12

  test "Parse field enum":
    let
      timer0 = device.peripherals["TIMER0".toSvdId]
      cr = timer0.registers.get()[0]
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
      timer0 = device.peripherals["TIMER0".toSvdId]
      cr = timer0.registers.get()[0]
      cnt = cr.fields[2]

    let
      ac = samd21.peripherals["AC".toSvdId]
      statusa = ac.registers.get()[6]
      wstate0 = statusa.fields[2]
      gclk = samd21.peripherals["GCLK".toSvdId]
      clkctrl = gclk.registers.get()[2]

      id = clkctrl.fields[0]
      gen = clkctrl.fields[1]
      clken = clkctrl.fields[2]
      wrtlock = clkctrl.fields[3]

    check:
      cnt.name == "CNT"
      cnt.lsb == 2
      cnt.msb == 3

      wstate0.name == "WSTATE0"
      wstate0.description.get == "Window 0 Current State"
      wstate0.derivedFrom.isNone
      wstate0.lsb == 4
      wstate0.msb == 5

      id.name == "ID"
      id.lsb == 0
      id.msb == 5

      gen.name == "GEN"
      gen.lsb == 8
      gen.msb == 11

      clken.name == "CLKEN"
      clken.lsb == 14
      clken.msb == 14

  test "Parse interrupts":
    let
      timer0 = device.peripherals["TIMER0".toSvdId]
      timer1 = device.peripherals["TIMER1".toSvdId]
      timer2 = device.peripherals["TIMER2".toSvdId]

    check:
      timer0.interrupts.len == 1
      timer1.interrupts.len == 1
      timer2.interrupts.len == 1

      timer0.interrupts[0].name == "TIMER0"
      timer0.interrupts[0].description == "Timer 0 interrupt"
      timer0.interrupts[0].value == 0

      timer1.interrupts[0].name == "TIMER1"
      timer1.interrupts[0].description == "Timer 1 interrupt"
      timer1.interrupts[0].value == 4

      timer2.interrupts[0].name == "TIMER2"
      timer2.interrupts[0].description == "Timer 2 interrupt"
      timer2.interrupts[0].value == 6

  test "Parse dimElementGroup":
    let
      timer0 = device.peripherals["TIMER0".toSvdId]
      reload = timer0.findRegister("RELOAD[%s]")

      ac = samd21.peripherals["AC".toSvdId]
      compctrl = ac.findRegister("COMPCTRL%s")

      port = samd21.peripherals["PORT".toSvdId]
      pmux1 = port.findRegister("PMUX1_%s")

    check:
      reload.dimGroup.dim.get == 4
      reload.dimGroup.dimIncrement.get == 4

      compctrl.dimGroup.dim.get == 2
      compctrl.dimGroup.dimIncrement.get == 0x4

      pmux1.dimGroup.dim.get == 16
      pmux1.dimGroup.dimIncrement.get == 0x1
