import std/strutils
import std/tables
import std/sets
import std/options

import ../basetypes

func nimIdentKey*(s: string): string =
  ## Normalize an identifier for Nim's case/underscore-insensitive equality.
  s.toLowerAscii.replace("_", "")

const
  Indent = "  "
  TypeSuffix = "_Type"

type TypeDefField* = object
  name*: string
  public*: bool
  typeName*: string

type CodeGenTypeDef* = object # Nim object type definition
  name*: string
  public*: bool
  members*: seq[TypeDefField]

type CodeGenEnumDef* = object # Nin enum type definition
  name*: string
  public*: bool
  fields*: seq[tuple[key: string, val: int]]
  pragma*: string

type CodeGenDistinctDef* = object # Nin enum type definition
  name*: string
  public*: bool
  baseType*: string

type CodeGenProcDefArg* = object
  name*: string
  typ*: string
  defaultVal*: Option[string]

type CodeGenProcDef* = object
  keyword*: string
  name*: string
  public*: bool
  args*: seq[CodeGenProcDefArg]
  retType*: string
  pragma*: seq[string]
  body*: string

type CodeGenContext* = object
  ignoreAppend*: bool
  ignorePrepend*: bool
  symbols*: HashSet[string]
  typeMap*: Table[SvdId, string]
  dev*: SvdDevice

proc initCodeGenContext*(
    dev: SvdDevice, ignoreAppend: bool = false, ignorePrepend: bool = false
): CodeGenContext =
  CodeGenContext(dev: dev, ignoreAppend: ignoreAppend, ignorePrepend: ignorePrepend)

## Assign type names for all SVD ids
func buildTypeMap*(ctx: var CodeGenContext) =
  var tm: Table[SvdId, string]
  # Pass 1: Assign type names for all "base" types, those that are not derived
  # or dim lists.
  for periph in ctx.dev.peripherals.values:
    if ctx.hasOwnType(periph):
      tm[periph.id] = buildTypeName periph
    for regNode in periph.walkRegisters:
      if regNode.typeBase.isNone:
        tm[regNode.id] = buildTypeName(regNode, tm[regNode.id.parent])

  # Pass 2: Assign existing type names to entities which share existing types.
  for periph in ctx.dev.peripherals.values:
    if periph.id notin tm:
      assert periph.typeBase.isSome
      if periph.typeBase.get in tm:
        tm[periph.id] = tm[periph.typeBase.get]
      else:
        let tname = buildTypeName periph
        tm[periph.id] = tname
        tm[periph.typeBase.get] = tname

    for regNode in periph.walkRegisters:
      if regNode.id notin tm:
        assert regNode.typeBase.isSome
        if regNode.typeBase.get in tm:
          tm[regNode.id] = tm[regNode.typeBase.get]
        else:
          let tname = buildTypeName(regNode, tm[regNode.id.parent])
          tm[regNode.id] = tname
          tm[regNode.typeBase.get] = tname

  ctx.typeMap = tm

converter toCodeGenProcDefArg*(t: (string, string)): CodeGenProcDefArg =
  result = CodeGenProcDefArg(name: t[0], typ: t[1], defaultVal: string.none)

converter toCodeGenProcDefArg*(tseq: seq[(string, string)]): seq[CodeGenProcDefArg] =
  for t in tseq:
    result.add CodeGenProcDefArg(name: t[0], typ: t[1], defaultVal: string.none)
