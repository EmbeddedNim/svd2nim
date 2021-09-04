import typedefs
import basetypes
import strformat
import strutils
import sequtils
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
      prag = if f.bitsize.isSome: fmt" {{.bitsize:{f.bitsize.get}.}}" else: ""
    tg.writeLine(Indent & fmt"{fName}{fstar}{prag}: {f.typeName}")

proc renderRegister(
  r: SvdRegister,
  numIndent: Natural,
  baseAddress: Natural,
  tg: File) =

  let intName = "uint" & $r.properties.size

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

proc renderCluster(
  cluster: SvdCluster,
  numIndent: Natural,
  baseAddress: Natural,
  tg: File)

proc renderFields[T: SvdCluster | SvdPeripheral](
  p: T,
  baseAddress: Natural,
  numIndent: Natural,
  tg: File) =

  let fields = block:
    var fields: seq[SvdEntity]
    for c in p.clusters: fields.add c.toEntity(p.name)
    for r in p.registers: fields.add r.toEntity(p.name)
    fields.sort(cmpAddrOffset)
    fields

  let locIndent = repeat(Indent, numIndent)

  for f in fields:
    let fName = f.getName.stripPlaceHolder.sanitizeIdent
    tg.write(fmt"{locIndent}{fName}: ")

    case f.kind:
    of seRegister:
      renderRegister(f.register, numIndent, baseAddress, tg)
    of seCluster:
      renderCluster(f.cluster, numIndent, baseAddress, tg)
    of sePeripheral:
      doAssert false

proc renderCluster(
  cluster: SvdCluster,
  numIndent: Natural,
  baseAddress: Natural,
  tg: File) =

  if cluster.isDimArray:
    # TODO: dim array of clusters has not been tested. Find or create SVD snippet
    # using this codepath to test.
    let locIndent = repeat(Indent, numIndent + 1)
    tg.write("[\n")
    for arrIndex in 0 ..< (cluster.dimGroup.dim.get):
      let address = baseAddress +
                    cluster.addressOffset +
                    arrIndex * (cluster.dimGroup.dimIncrement.get)
      tg.write(fmt"{locIndent}{cluster.nimTypeName}(" & "\n")
      renderFields(cluster, address, numIndent+2, tg)
      tg.write(locIndent & "),\n")
    tg.write(repeat(Indent, numIndent) & "]\n")
  else:
    let
      address = baseAddress + cluster.addressOffset
    tg.write(fmt"{cluster.nimTypeName}(" & "\n")
    renderFields(cluster, address, numIndent+1, tg)
    tg.write(repeat(Indent, numIndent) & "),\n")

proc renderPeripheral*(p: SvdPeripheral, tg: File) =
  let insName = p.name.stripPlaceHolder.sanitizeIdent

  if p.isDimArray:
    # TODO: dim array of peripherals has not been tested. Find or create SVD snippet
    # using this codepath to test.
    tg.writeLine(fmt"let {insName}* = [")
    for arrIndex in 0 ..< (p.dimGroup.dim.get):
      let address = p.baseAddress + arrIndex * p.dimGroup.dimIncrement.get
      tg.write(fmt"{Indent}{p.nimTypeName}(" & "\n")
      renderFields(p, address, 2, tg)
      tg.write(Indent & "),\n")
    tg.write(Indent & "]\n\n")
  else:
    tg.writeLine(fmt"let {insName}* = {p.nimTypeName}(")
    renderFields(p, p.baseAddress, 1, tg)
    tg.write(")\n\n")

proc renderEnum*(en: CodeGenEnumDef, tg: File) =
  let star = if en.public: "*" else: ""
  tg.writeLine(fmt"type {en.name}{star} {{.pure.}} = enum")
  for (k, v) in en.fields:
    tg.writeLine(fmt"{Indent}{k} = {v:#x},")
  tg.write "\n"

proc renderProcDef*(prd: CodeGenProcDef, tg: File) =
  let
    argString = prd.args.mapIt(it.name & ": " & it.typ).join(", ")
    retString = if prd.retType.isSome: ": " & prd.retType.get else: ""
    star = if prd.public: "*" else: ""
  tg.writeLine(fmt"{prd.keyword} {prd.name}{star}({argString}){retString} = ")
  for line in prd.body.splitLines:
    tg.writeLine Indent & line
  tg.write "\n"
