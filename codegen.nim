import typedefs
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
      fname = f.name.sanitizeIdent
      fieldTypeName = f.typeName.sanitizeIdent
    tg.writeLine(Indent & fmt"{fName}{fstar}: {fieldTypeName}")
