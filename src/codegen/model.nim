import std/tables
import std/sets
import std/options
import std/streams

import ../basetypes

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
  output*: Stream

proc initCodeGenContext*(
    dev: SvdDevice,
    ignoreAppend: bool = false,
    ignorePrepend: bool = false,
    output: Stream = nil,
): CodeGenContext =
  CodeGenContext(
    dev: dev, ignoreAppend: ignoreAppend, ignorePrepend: ignorePrepend, output: output
  )

converter toCodeGenProcDefArg*(t: (string, string)): CodeGenProcDefArg =
  result = CodeGenProcDefArg(name: t[0], typ: t[1], defaultVal: string.none)

converter toCodeGenProcDefArg*(tseq: seq[(string, string)]): seq[CodeGenProcDefArg] =
  for t in tseq:
    result.add CodeGenProcDefArg(name: t[0], typ: t[1], defaultVal: string.none)
