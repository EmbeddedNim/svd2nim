import typedefs
import basetypes
import strformat
import strutils
import algorithm
import utils
import entities

const Indent = "  "

proc renderType*(typ: CodeGenTypeDef, tg: File) =
  let
    star = if typ.public: "*" else: ""
    typName = typ.name.sanitizeIdent
  tg.writeLine(fmt"type {typName}{star} = object")
  for f in typ.fields:
    let
      fstar = if f.public: "*" else: ""
      fname = f.name.stripPlaceHolder.sanitizeIdent
    tg.writeLine(Indent & fmt"{fName}{fstar}: {f.typeName}")

proc renderRegister(
  r: SvdRegister,
  numIndent: Natural,
  baseAddress: Natural,
  baseProps: SvdRegisterProperties,
  tg: File) =

  let
    rp = updateProperties(baseProps, r.properties)
    intName = "uint" & $rp.size.get

  discard
  if r.isDimArray:
    tg.write("[\n")
    for arrIndex in 0 ..< (r.dimGroup.dim.get):
      let address = baseAddress +
                    r.addressOffset +
                    arrIndex * (r.dimGroup.dimIncrement.get)
      let locIndent = repeat(Indent, numIndent + 1)
      tg.write(fmt"{locIndent}{r.nimTypeName}(p: cast[ptr {intName}]({address:#x}))," & "\n")
    tg.write(repeat(Indent, numIndent) & "]\n")
  else:
    let address = baseAddress + r.addressOffset
    tg.write(fmt"{r.nimTypeName}(p: cast[ptr {intName}]({address:#x}))," & "\n")

proc renderPeripheral*(p: SvdPeripheral, tg: File) =
  let insName = p.name.stripPlaceHolder.sanitizeIdent
  tg.writeLine(fmt"let {insName}* = {p.nimTypeName}(")

  let fields = block:
    var fields: seq[SvdEntity]
    for c in p.clusters: fields.add c.toEntity(p.name)
    for r in p.registers: fields.add r.toEntity(p.name)
    fields.sort(cmpAddrOffset)
    fields

  for f in fields:
    let fName = f.getName.stripPlaceHolder.sanitizeIdent
    tg.write(fmt"{Indent}{fName}: ")

    case f.kind:
    of seRegister:
      renderRegister(f.register, 1, p.baseAddress, p.registerProperties, tg)

    of seCluster:
      tg.write("\n")
    of sePeripheral:
      doAssert false
  tg.write(")\n\n")