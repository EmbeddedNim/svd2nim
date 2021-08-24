
import unittest
import svdperipherals
import svdparser
import strformat

# Some utility functions

func getPeriphByName(dev: SvdDevice, name: string): SvdPeripheral =
  for per in dev.peripherals:
    if per.name == name: return per

proc dumpInstances(nodes: seq[InstanceNode]) =
  for n in nodes:
    case n.kind:
    of inPeripheral:
      echo fmt"Peripheral: {n.periph.name} (typeName: {n.typeName})"
    of inCluster:
      echo fmt"Cluster: {n.cluster.name} (typeName: {n.typeName})"
    of inRegister:
      echo fmt"Register: {n.register.name} (typeName: {n.typeName}, addr: {n.absAddr})"

# Test suites

suite "Instance creation":
  setup:
    let
      device {.used.} = readSVD("./tests/ARM_Example.svd")
      samd21 {.used.} = readSVD("./tests/ATSAMD21G18A.svd")

  test "Create correct instances":
    let
      timer0 = device.getPeriphByName("TIMER0")
      timer0Instances = timer0.getSortedInstances()

    #dumpInstances timer0Instances
    for periph in samd21.peripherals:
      periph.getSortedInstances.dumpInstances
    check:
      timer0Instances.len == 9
      # Peripheral should be last, after instances
      timer0Instances[^1].kind == inPeripheral
