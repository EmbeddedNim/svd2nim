import typedefs
import basetypes
import strformat
import utils

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

proc renderPeripheral*(p: SvdPeripheral, tg: File) =
  discard
