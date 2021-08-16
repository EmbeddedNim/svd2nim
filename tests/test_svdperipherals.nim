
import unittest
import svdperipherals
import svdparser
import strformat

# Some utility functions

func getPeriphByName(dev: SvdDevice, name: string): SvdPeripheral =
  for per in dev.peripherals:
    if per.name == name: return per

proc echoTypeDefs(td: seq[PeripheralTreeNode]) =
  discard

# Test suites

suite "Ordering tests":
  setup:
    let
      device {.used.} = readSVD("./tests/ARM_Example.svd")
      samd21 {.used.} = readSVD("./tests/ATSAMD21G18A.svd")

  test "Peripheral with registers and a union":
    let
      timer0 = device.getPeriphByName("TIMER0")
      typeDefOrder = timer0.getSortedObjectDefs

    check:
      typeDefOrder.len == 2
      typeDefOrder[0].kind == ptUnion
      typeDefOrder[1].kind == ptPeripheral

  test "Struct with single union":
    let
      tc3 = samd21.getPeriphByName("TC3")
      tdo = tc3.getSortedObjectDefs()

    