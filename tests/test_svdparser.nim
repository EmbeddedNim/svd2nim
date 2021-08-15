import unittest
import svdparser

# Some utility functions

func getPeriphByName(dev: SvdDevice, name: string): SvdPeripheral =
  for per in dev.peripherals:
    if per.name == name: return per

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

  test "Register properties inherited":
    let
      timer0 = device.getPeriphByName("TIMER0")
      cr = timer0.registers[0]
      sr = timer0.registers[1]
      regInt = timer0.registers[2]
      count = timer0.registers[3]
      match = timer0.registers[4]
      prescale_rd = timer0.registers[5]
      prescale_wr = timer0.registers[6]
      reload = timer0.registers[7]

    check:
      cr.properties.size == 32
      cr.properties.access == raReadWrite

      sr.properties.size == 16
      sr.properties.access == raReadWrite

      regInt.properties.size == 16
      regInt.properties.access == raReadWrite

      count.properties.size == 32
      count.properties.access == raReadWrite

      match.properties.size == 32
      match.properties.access == raReadWrite

      prescale_rd.properties.size == 32
      prescale_rd.properties.access == raReadOnly

      prescale_wr.properties.size == 32
      prescale_wr.properties.access == raWriteOnly

      reload.properties.size == 32
      reload.properties.access == raReadWrite

  test "Parse field data":
    let
      timer0 = device.getPeriphByName("TIMER0")
      cr = timer0.registers[0]
      cnt = cr.fields[2]

    let
      ac = samd21.getPeriphByName("AC")
      statusa = ac.registers[6]
      wstate0 = statusa.fields[2]

    check:
      cnt.name == "CNT"
      cnt.bitRange == (lsb: 2.Natural, msb: 3.Natural)

      wstate0.name == "WSTATE0"
      wstate0.description.get == "Window 0 Current State"
      wstate0.derivedFrom.isNone
      wstate0.bitRange == (lsb: 4.Natural, msb: 5.Natural)

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