import json
import xmlparser
import xmltree
import os
import streams

iterator findAllDirect(n: XmlNode, tag: string): XmlNode =
  for cld in n.items:
    if cld.kind != xnElement: # Only xnElement allows tag access
      continue
    if cld.tag == tag:
      yield cld

type Writer = object
  indentLevel: Natural

proc writeLine(w: Writer, line: string) =
  for i in 0 ..< w.indentLevel:
    stdout.write("  ")
  stdout.write(line)
  stdout.write("\n")

proc indent(w: var Writer) = w.indentLevel.inc
proc dedent(w: var Writer) =
  if w.indentLevel > 0:
    w.indentLevel.dec

proc dumpRegister(n: XmlNode, w: var Writer) =
  let name = n.child("name").innerText
  w.writeLine("Register: " & name)

proc dumpCluster(n: XmlNode, w: var Writer) =
  let name = n.child("name").innerText
  w.writeLine("Cluster: " & name)
  w.indent
  for cld in n.items:
    if cld.tag == "register":
      dumpRegister(cld, w)
    elif cld.tag == "cluster":
      dumpCluster(cld, w)
  w.dedent

proc dumpPeripheral(n: XmlNode, w: var Writer) =
  discard
  let name = n.child("name").innerText
  w.writeLine("Peripheral: " & name)

  let registers = n.child("registers")
  if not isNil(registers):
    w.indent
    for cluster in registers.findAllDirect("cluster"):
      dumpCluster(cluster, w)
    for reg in registers.findAllDirect("register"):
      dumpRegister(reg, w)
    w.dedent

proc main() =
  let
    fname = commandLineParams()[0]
    xmlRoot = loadXml(fname)
    peripherals = xmlRoot.child("peripherals")

  var writer = Writer(indentLevel:0)

  for periph in peripherals.findAllDirect("peripheral"):
    periph.dumpPeripheral(writer)

when isMainModule: main()
