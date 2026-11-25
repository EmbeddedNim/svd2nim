import std/tables
import std/strutils

import ../basetypes
import ../utils
import ./model

const TypeSuffix = "_Type"

func intname*(size: Natural): string =
  "uint" & $size

func appendTypeName(parentName: string, name: string): string =
  if parentName.endsWith(TypeSuffix):
    result = parentName[0 .. ^(TypeSuffix.len + 1)]
  else:
    result = parentName
  result = result & "_" & name

func buildTypeName(p: SvdPeripheral): string =
  if p.dimGroup.dimName.isSome:
    result = p.dimGroup.dimName.get
  elif p.headerStructName.isSome:
    result = p.headerStructName.get
  else:
    result = p.baseName
  result = result.sanitizeIdent & TypeSuffix

func buildTypeName(c: SvdRegisterTreeNode, parentTypeName: string): string =
  if c.kind == rnkCluster and c.headerStructName.isSome:
    result = c.headerStructName.get
  else:
    result = appendTypeName(parentTypeName, c.baseName)
  result = result.sanitizeIdent & TypeSuffix

func hasOwnType(ctx: CodeGenContext, periph: SvdPeripheral): bool =
  var basePeriph: SvdPeripheral = nil
  if periph.typeBase.isSome:
    basePeriph = ctx.dev.peripherals[periph.typeBase.get]

  result =
    periph.typeBase.isNone or (
      (
        periph.prependToName.isSome and periph.prependToName != basePeriph.prependToName and
        not ctx.ignorePrepend
      ) or (
        periph.appendToName.isSome and periph.appendToName != basePeriph.appendToName and
        not ctx.ignoreAppend
      )
    )

func getEnumTypeName*(enm: SvdFieldEnum, fieldName: string, regType: string): string =
  if enm.headerEnumName.isSome:
    enm.headerEnumName.get
  else:
    appendTypeName(regType, fieldName)

func getRegValueType*(reg: SvdRegisterTreeNode, typeName: string): string =
  assert reg.kind == rnkRegister
  if reg.hasFields:
    typeName.appendTypeName("Fields")
  elif reg.hasSingletonField and reg.fields[0].enumValues.isSome:
    getEnumTypeName(reg.fields[0].enumValues.get, reg.fields[0].name, typeName)
  else:
    intname reg.resolvedProperties.size

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