import std/unittest
import std/tables
import std/options
import std/tables
import std/sequtils
import std/strutils

import svdparser
import transformations
import basetypes
import utils_for_tests

proc readAndTransformSvd(fname: string, derive, expand: bool = false): SvdDevice =
  result = readSVD fname
  if derive:
    deriveAll result
  if expand:
    expandAll result

suite "SVD transformation tests":
  setup:
    let
      device {.used.} = readAndTransformSvd("./tests/ARM_Example.svd", derive = true)
      samd21 {.used.} = readAndTransformSvd("./tests/ATSAMD21G18A.svd", derive = true)
      esp32 {.used.} = readAndTransformSvd("./tests/esp32.svd", derive = true)

  test "Peripheral derived":
    let
      timer0 = device.peripherals["TIMER0".toSvdId]
      timer1 = device.peripherals["TIMER1".toSvdId]
      timer2 = device.peripherals["TIMER2".toSvdId]
      port_iobus = samd21.peripherals["PORT_IOBUS".toSvdId]

    check:
      timer1.baseAddress == 0x40010100
      timer1.interrupts.len == 1
      timer1.interrupts[0].name == "TIMER1"
      timer1.registers.get().len == timer0.registers.get().len

      timer2.baseAddress == 0x40010200
      timer2.interrupts.len == 1
      timer2.interrupts[0].name == "TIMER2"
      timer2.registers.get().len == timer0.registers.get().len

      port_iobus.prependToName.get == "PORT_IOBUS_"

  test "Register derived":
    let
      port = samd21.peripherals["PORT".toSvdId]
      pmux1 = port.findRegister("PMUX1_%s")
      pmux0 = port.findRegister("PMUX0_%s")

    check:
      pmux1.fields.len == pmux0.fields.len
      pmux1.addressOffset == 0xb0

      pmux1.properties.size == pmux0.properties.size
      pmux1.properties.access == pmux0.properties.access

  test "Enum derived":
    let
      timg0 = esp32.peripherals["TIMG0".toSvdId]
      wdtcfg0 = timg0.findRegister("WDTCONFIG0")
      wdtstg2 = wdtcfg0.findField("WDT_STG2")

    check:
      wdtstg2.enumValues.isSome
      wdtstg2.enumValues.get.name.get == "WDT_STG3"
      wdtstg2.enumValues.get.values.len == 4

suite "Dim Lists":
  setup:
    let
      samd21Periphs {.used.} =
        readAndTransformSvd("./tests/ATSAMD21G18A.svd", true, true).peripherals

      esp32 {.used.} = readAndTransformSvd("./tests/esp32.svd", true, true)

  test "Register dim list expanded":
    let
      ac = samd21Periphs["AC".toSvdId]
      compctrl = ac.registers.get().filterIt(it.name.contains("COMPCTRL"))

    check:
      compctrl.len == 2
      compctrl[0].name == "COMPCTRL0"
      compctrl[1].name == "COMPCTRL1"
      compctrl[1].addressOffset - compctrl[0].addressOffset == 4
      compctrl[0].description == compctrl[1].description
      compctrl[0].fields.len == compctrl[1].fields.len
      compctrl[0].properties.size == compctrl[1].properties.size
      compctrl[0].properties.access == compctrl[1].properties.access

  test "Register field dim list expanded":
    let int_ena = esp32.findRegister("RMT.INT_ENA".toSvdId)

    check:
      int_ena.fields.len == 32

      int_ena.findField("CH0_TX_END_INT_ENA").access.get == raReadWrite
      int_ena.findField("CH0_TX_END_INT_ENA").lsb == 0
      int_ena.findField("CH0_TX_END_INT_ENA").bitsize == 1

      int_ena.findField("CH7_TX_END_INT_ENA").access.get == raReadWrite
      int_ena.findField("CH7_TX_END_INT_ENA").lsb == 21
      int_ena.findField("CH7_TX_END_INT_ENA").bitsize == 1
