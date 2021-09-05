import strutils

let fields = """
    name*: string
    groupName*: string
    typeName*: string
    description*: string
    clusterName*: string
    baseAddress*: uint32
    address*: uint32
    derivedFrom*: string
    registers*: seq[svdRegister]
    subtypes*: seq[svdPeripheral]
    dim*: int
    elementSize*: int
"""

let arg = "reg"

for line in fields.strip.splitLines:
  let parts = line.split(":")

  var name = parts[0].strip
  if name.endsWith("*"):
    name = name[0..(name.high-1)]

  echo "\"" & name & "\"" & ": " & arg & "." & name & ","
