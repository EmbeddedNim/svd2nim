import std/strutils

import ../basetypes
import ../utils
import ./model

const TypeSuffix = "_Type"

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

func buildEnumTypeName*(ctx: CodeGenContext, enm: SvdFieldEnum, regType: string): string =
  if enm.headerEnumName.isSome:
    result = enm.headerEnumName.get
  else:
    # Derived enums reuse their base enum object, whose id still points at the
    # base field. Use that field name so the derived field shares the base
    # enum type name.
    let idParts = enm.id.split
    assert idParts.len >= 2 # Enum should always have a parent field at least
    result = appendTypeName(regType, idParts[^2])
    if enm.usage == euWrite and result in ctx.symbols:
      result = result & "Write"

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

proc addType(ctx: var CodeGenContext, id: SvdId, typeName: string) =
  ctx.typeMap[id] = typeName
  ctx.symbols.incl typeName

## Assign type names for all SVD ids
proc buildTypeMap*(ctx: var CodeGenContext) =
  # Pass 1: Assign type names for all "base" types, those that are not derived
  # or dim lists.
  for periph in ctx.dev.peripherals.values:
    if ctx.hasOwnType(periph):
      ctx.addType(periph.id, buildTypeName(periph))
    for regNode in periph.walkRegisters:
      if regNode.typeBase.isNone:
        ctx.addType(regNode.id, buildTypeName(regNode, ctx.typeMap[regNode.id.parent]))

  # Pass 2: Assign existing type names to entities which share existing types.
  for periph in ctx.dev.peripherals.values:
    if periph.id notin ctx.typeMap:
      assert periph.typeBase.isSome
      if periph.typeBase.get in ctx.typeMap:
        ctx.addType(periph.id, ctx.typeMap[periph.typeBase.get])
      else:
        let tname = buildTypeName periph
        ctx.addType(periph.id, tname)
        ctx.addType(periph.typeBase.get, tname)

    for regNode in periph.walkRegisters:
      if regNode.id notin ctx.typeMap:
        assert regNode.typeBase.isSome
        if regNode.typeBase.get in ctx.typeMap:
          ctx.addType(regNode.id, ctx.typeMap[regNode.typeBase.get])
        else:
          let tname = buildTypeName(regNode, ctx.typeMap[regNode.id.parent])
          ctx.addType(regNode.id, tname)
          ctx.addType(regNode.typeBase.get, tname)

  # Assign enum type names
  for reg in ctx.dev.walkRegistersOnly:
    let regtype = ctx.typeMap[reg.id]

    for field in reg.fields:
      for enumOpt in [field.enumValues, field.writeEnumValues]:
        if not enumOpt.isSome:
          continue
        let svdEnum = enumOpt.get
        if svdEnum.id in ctx.typeMap:
          # We share enum object refs between mutlitple registers, so the type
          # may already have been defined.
          continue
        ctx.addType(svdEnum.id, ctx.buildEnumTypeName(svdEnum, regtype))

func intname*(size: Natural): string =
  "uint" & $size

func getRegValueType*(ctx: CodeGenContext, reg: SvdRegisterTreeNode): string =
  assert reg.kind == rnkRegister
  let regType = ctx.typeMap[reg.id]
  if reg.hasFields:
    regType.appendTypeName("Fields")
  elif reg.hasSingletonField and reg.fields[0].enumValues.isSome:
    # TODO: Need to handle read/write enums here
    ctx.typeMap[reg.fields[0].enumValues.get.id]
  else:
    intname reg.resolvedProperties.size
