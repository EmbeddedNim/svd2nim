import std/strformat
import std/strutils
import std/sequtils
import std/algorithm
import std/tables
import std/sets
import std/options
import std/bitops
import std/os

import regex

import ./basetypes
import ./utils
import ./cpuirq

func nimIdentKey*(s: string): string =
  ## Normalize an identifier for Nim's case/underscore-insensitive equality.
  s.toLowerAscii.replace("_", "")

const
  Indent = "  "
  TypeSuffix = "_Type"

type TypeDefField = object
  name*: string
  public*: bool
  typeName*: string

type CodeGenTypeDef = object # Nim object type definition
  name*: string
  public*: bool
  members*: seq[TypeDefField]

type CodeGenEnumDef = object # Nin enum type definition
  name*: string
  public*: bool
  fields*: seq[tuple[key: string, val: int]]
  pragma*: string

type CodeGenDistinctDef = object # Nin enum type definition
  name*: string
  public*: bool
  baseType*: string

type CodeGenProcDefArg = object
  name: string
  typ: string
  defaultVal: Option[string]

type CodeGenProcDef = object
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

converter toCodeGenProcDefArg(t: (string, string)): CodeGenProcDefArg =
  result = CodeGenProcDefArg(name: t[0], typ: t[1], defaultVal: string.none)

converter toCodeGenProcDefArg(tseq: seq[(string, string)]): seq[CodeGenProcDefArg] =
  for t in tseq:
    result.add CodeGenProcDefArg(name: t[0], typ: t[1], defaultVal: string.none)

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

func getDimArrayTypeExpr[T: SomeSvdDimable](ctx: CodeGenContext, e: T): string =
  let typeName = ctx.typeMap[e.id]
  if e.isDimArray:
    let dim = e.dimGroup.dim.get
    fmt"array[{dim}, {typeName}]"
  else:
    typeName

func getRegisterPrefixSuffix(ctx: CodeGenContext, p: SvdPeripheral): (string, string) =
  let
    regPrefix =
      if not ctx.ignorePrepend:
        p.prependToName.get("")
      else:
        ""
    regSuffix =
      if not ctx.ignoreAppend:
        p.appendToName.get("")
      else:
        ""
  return (regPrefix, regSuffix)

func getObjectMemberName(ctx: CodeGenContext, n: SvdRegisterTreeNode): string =
  case n.kind
  of rnkRegister:
    let
      parentPeriph = ctx.dev.peripherals[parentPeripheral(n.id)]
      (regPrefix, regSuffix) = ctx.getRegisterPrefixSuffix(parentPeriph)
    result = regPrefix & n.name & regSuffix
  of rnkCluster:
    # SVD spec says that appendToName/prependToName applies to "registers"
    # TODO: Check what SVDCONV does and ensure that they don't apply to clusters
    result = n.name
  result = result.stripPlaceHolder.sanitizeIdent

func getObjectMembers[T: SvdRegisterParent](
    ctx: CodeGenContext, e: T
): seq[TypeDefField] =
  let children = block:
    var c = toSeq e.iterRegisters
    c.sort cmpAddrOffset
    c

  for c in children:
    let
      memberName = ctx.getObjectMemberName(c)
      memberType = ctx.getDimArrayTypeExpr(c)
      def = TypeDefField(name: memberName, typeName: memberType, public: true)
    result.add def

func createRegisterType(name: string): CodeGenTypeDef =
  result.name = name
  result.public = true
  result.members.add TypeDefField(name: "loc", public: false, typeName: "uint")

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

## Assign type names for all SVD ids
func buildTypeMap(ctx: var CodeGenContext) =
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

func createTypeDefs(ctx: CodeGenContext): seq[CodeGenTypeDef] =
  var knownTypeDefs: Hashset[string]

  for periph in ctx.dev.peripherals.values:
    let periphTypeName = ctx.typeMap[periph.id]
    if periphTypeName in knownTypeDefs:
      continue
    else:
      knownTypeDefs.incl periphTypeName

    var pdefs: seq[CodeGenTypeDef]
    pdefs.add CodeGenTypeDef(
      name: periphTypeName, public: true, members: ctx.getObjectMembers(periph)
    )

    # Can't use walkRegisters here in order to preserve correct ordering
    # Use DFS then reverse so that type dependency order is correct.
    var regstack = toSeq(periph.iterRegisters)
    while regstack.len > 0:
      let
        regNode = regstack.pop
        tname = ctx.typeMap[regNode.id]

      if tname in knownTypeDefs:
        continue
      else:
        knownTypeDefs.incl tname

      case regNode.kind
      of rnkCluster:
        pdefs.add CodeGenTypeDef(
          name: tname, public: true, members: ctx.getObjectMembers(regNode)
        )
        for child in regNode.iterRegisters:
          regstack.add child
      of rnkRegister:
        pdefs.add createRegisterType(tname)

    for td in pdefs.ritems:
      result.add td

proc renderNimImportExports(ctx: CodeGenContext, outf: File) =
  outf.write(
    "# Peripheral access API for $# microcontrollers (generated using svd2nim)\n\n" %
      ctx.dev.metadata.name.toUpper()
  )
  outf.writeLine("import std/volatile")
  outf.writeLine("import std/bitops")
  outf.writeLine("import uncheckedenums")
  outf.write("\n")
  outf.writeLine("export volatile")
  outf.writeLine("export uncheckedenums")
  outf.write("\n")

  # Supress name hints
  outf.write("{.hint[name]: off.}\n\n")

  # Enable overloadable enums for nim v1.x
  outf.write:
    """
    when NimMajor < 2:
      {.experimental: "overloadableEnums".}
    """.dedent.strip
  outf.write "\n\n"

proc renderType(typ: CodeGenTypeDef, tg: File) =
  let
    star = if typ.public: "*" else: ""
    typName = typ.name.sanitizeIdent
  tg.writeLine(fmt"type {typName}{star} = object")
  for f in typ.members:
    let
      fstar = if f.public: "*" else: ""
      fname = f.name.stripPlaceHolder.sanitizeIdent
    tg.writeLine(Indent & fmt"{fName}{fstar}: {f.typeName}")

func hasFields(r: SvdRegisterTreeNode): bool =
  # If defines a single field of the same size as the register, then
  # consider that there is no field.
  assert r.kind == rnkRegister
  result =
    r.fields.len > 0 and
    not (r.fields.len == 1 and r.fields[0].bitsize == r.resolvedProperties.size)

func getEnumTypeName(enm: SvdFieldEnum, fieldName: string, regType: string): string =
  if enm.headerEnumName.isSome:
    enm.headerEnumName.get
  else:
    appendTypeName(regType, fieldName)

func getEnumPrefix(enmDef: CodeGenEnumDef): string =
  var lastPart = enmDef.name.split("_")[^1]
  while lastPart.len > 0 and lastPart[0] notin Letters:
    lastPart = lastPart[1 .. lastPart.high]

  result =
    if lastPart.len > 0:
      lastPart[0 .. min(lastPart.high, 2)].toLowerAscii
    else:
      "x"

func createEnum(
    ctx: CodeGenContext, field: SvdField, regType: string, size: Natural = 0
): CodeGenEnumDef =
  let svdEnum = field.enumValues.get

  var needsPrefix = false
  result.public = true
  result.name = getEnumTypeName(svdEnum, field.name, regType)
  for (k, v) in svdEnum.values:
    let cgKey = k.sanitizeIdent
    result.fields.add (cgKey, v)

    if cgKey[0] notin Letters or nimIdentKey(cgKey) in ctx.symbols:
      needsPrefix = true

  if needsPrefix:
    let prefix = getEnumPrefix(result)
    for entry in result.fields.mitems:
      entry.key = prefix & entry.key

  # Sort enumerated values by their numeric value so the generated enum
  # lists them in increasing order.
  result.fields.sort(
    proc(a, b: tuple[key: string, val: int]): int =
      cmp(a.val, b.val)
  )

  # Size pragma is used for register accessors which use an enum value type.
  # This happens when the register defines a "singleton" field, that is, a
  # single field whose size is equal to the register, and this singleton field
  # defines enumeratedValues.  Not required in other cases, but it is simpler to
  # just always generate it.
  if size > 0:
    result.pragma = fmt"size: {size}"

func hasSingletonField(reg: SvdRegisterTreeNode): bool =
  ## Check if register has single field that is the same size as
  ## the register.
  if reg.kind != rnkRegister:
    return false
  result = reg.fields.len == 1 and reg.fields[0].bitsize == reg.resolvedProperties.size

func createFieldEnums(
    ctx: CodeGenContext, periph: SvdPeripheral
): OrderedTable[string, CodeGenEnumDef] =
  var regset: HashSet[string]
  for reg in periph.walkRegistersOnly:
    let typeName = ctx.typeMap[reg.id]
    if typeName in regset:
      continue
    else:
      regset.incl typeName

    for field in reg.fields:
      if field.enumValues.isSome:
        let
          props = reg.resolvedProperties
          en = ctx.createEnum(field, typeName, (props.size div 8))
        result[en.name] = en

func intname(size: Natural): string =
  "uint" & $size

func getRegValueType(reg: SvdRegisterTreeNode, typeName: string): string =
  assert reg.kind == rnkRegister
  if reg.hasFields:
    typeName.appendTypeName("Fields")
  elif reg.hasSingletonField and reg.fields[0].enumValues.isSome:
    getEnumTypeName(reg.fields[0].enumValues.get, reg.fields[0].name, typeName)
  else:
    intname reg.resolvedProperties.size

func createBitfieldTypes(
    ctx: CodeGenContext, periph: SvdPeripheral
): OrderedTable[string, CodeGenDistinctDef] =
  for reg in periph.walkRegistersOnly:
    let
      props = reg.resolvedProperties
      regTypeName = ctx.typeMap[reg.id]

    if not reg.hasFields:
      continue

    for field in reg.fields:
      let fieldTypeName = getRegValueType(reg, regTypeName)
      if fieldTypeName notin result:
        result[fieldTypeName] = CodeGenDistinctDef(
          name: fieldTypeName, public: true, basetype: intname props.size
        )

func getFieldType(field: SvdField, regTypeName, implType: string): string =
  # Type of a field is either a bool (if 1-bit length), an Enum type if
  # one is defined, otherwise a plain uint.
  if field.enumValues.isSome:
    getEnumTypeName(field.enumValues.get, field.name, regTypeName)
  elif field.bitsize == 1:
    "bool"
  else:
    implType

func createBitfieldAccessors(
    ctx: CodeGenContext, periph: SvdPeripheral
): OrderedTable[string, CodeGenProcDef] =
  for reg in periph.walkRegistersOnly:
    let
      props = reg.resolvedProperties
      regTypeName = ctx.typeMap[reg.id]
      implType = intname props.size
      regValueType = getRegValueType(reg, regTypeName)

    if not reg.hasFields:
      continue

    for field in reg.fields:
      let
        hasEnum = field.enumValues.isSome
        access = field.access.get(props.access)
        lsb = field.lsb
        msb = field.msb
        valType = getFieldType(field, regTypeName, implType)
        getterValType =
          if hasEnum:
            fmt"UncheckedEnum[{valType}]"
          else:
            valType

      let getterName = block:
        var n = field.name.sanitizeIdent
        # Proc name may conflict with, eg, const instances.
        # In this case, attempt to generate a unique proc name by appending
        # "Field" suffix.
        if nimIdentKey(n) in ctx.symbols:
          n = n & "Field"
          assert nimIdentKey(n) notin ctx.symbols
        n

      if access.isReadable:
        var getter = CodeGenProcDef(
          keyword: "func",
          name: getterName,
          public: true,
          args: @[("r", regValueType)],
          retType: getterValType,
          pragma: @["inline"],
          body: fmt"r.{implType}.bitsliced({lsb} .. {msb})",
        )
        if hasEnum:
          getter.body = fmt"toUncheckedEnum[{valType}]({getter.body}.int)"
        elif valType != implType:
          getter.body &= ("." & getterValType)

        result[fmt"{getter.name}[{regValueType}]"] = getter

      if access.isWritable:
        var setter = CodeGenProcDef(
          keyword: "proc",
          name: fmt"`{getterName}=`",
          public: true,
          args: @[("r", "var " & regValueType), ("val", valType)],
          pragma: @["inline"],
          body: fmt"r.{implType}.bitsliced({lsb} .. {msb})",
        )
        let valconv =
          if valType != implType:
            "." & implType
          else:
            ""
        setter.body = fmt"""
        var tmp = r.{implType}
        tmp.clearMask({lsb} .. {msb})
        tmp.setMask((val{valconv} shl {lsb}).masked({lsb} .. {msb}))
        r = tmp.{regValueType}
        """
          .dedent()
          .strip(leading = false)
        result[fmt"{setter.name}[{regValueType}, {valType}]"] = setter

func getFieldDefaultVal(
    ctx: CodeGenContext,
    field: SvdField,
    regTypeName: string,
    regProps: ResolvedRegProperties,
): string =
  let
    fslice = field.lsb.int .. field.msb.int
    numVal = regProps.resetValue.bitsliced(fslice)
  result =
    if field.enumValues.isSome:
      let enumObj = ctx.createEnum(field, regTypeName)
      var val = enumObj.fields[0].key
      for (k, v) in enumObj.fields:
        if v == numVal:
          val = k
      val
    elif field.bitsize == 1:
      $(numVal > 0)
    else:
      if numVal > (1 shl (regProps.size - 1) - 1):
        $numVal & "." & intname(regProps.size)
      else:
        $numVal

func createFieldsWriter(
    ctx: CodeGenContext, reg: SvdRegisterTreeNode, regTypeName, valType: string
): CodeGenProcDef =
  ## Create a `write` method that takes fields values as arguments for
  ## registers with fields.
  assert reg.kind == rnkRegister
  let implType = intname reg.resolvedProperties.size
  result = CodeGenProcDef(keyword: "proc", name: "write", public: true)
  result.args.add ("reg", regTypeName)
  result.body.add fmt"var x: {implType}" & "\n"

  for field in reg.fields:
    # TODO: prevent duplication of arguments?
    let
      argName = field.name.sanitizeIdent
      argValType = getFieldType(field, regTypeName, implType)
      valconv =
        if argValType != implType:
          "." & implType
        else:
          ""
      defValStr = ctx.getFieldDefaultVal(field, regTypeName, reg.resolvedProperties)

    if field.access.get(raReadWrite).isWritable:
      result.args.add CodeGenProcDefArg(
        name: argName, typ: argValType, defaultVal: some defValStr
      )
      result.body.add fmt"x.setMask(({argName}{valconv} shl {field.lsb}).masked({field.lsb} .. {field.msb}))" &
        "\n"

  result.body.add fmt"reg.write x.{valType}"

func createAccessors(
    ctx: CodeGenContext, periph: SvdPeripheral
): OrderedTable[string, CodeGenProcDef] =
  for reg in periph.walkRegistersOnly:
    let
      props = reg.resolvedProperties
      regTypeName = ctx.typeMap[reg.id]
      valType = getRegValueType(reg, regTypeName)

    if props.access.isReadable:
      # Create regular read accessor
      result[fmt"read[{regTypeName}]"] = CodeGenProcDef(
        keyword: "proc",
        name: "read",
        public: true,
        args: @[("reg", regTypeName)],
        retType: valType,
        pragma: @["inline"],
        body: fmt"volatileLoad(cast[ptr {valType}](reg.loc))",
      )

      # Create static read accessor, generates more efficient code when possible
      # See https://github.com/dwhall/nimbed/wiki/svd2nim-analysis#item-3-static-register-parameters
      result[fmt"read[static {regTypeName}]"] = CodeGenProcDef(
        keyword: "proc",
        name: "read",
        public: true,
        args: @[("reg", fmt"static {regTypeName}")],
        retType: valType,
        pragma: @["inline"],
        body: fmt"volatileLoad(cast[ptr {valType}](reg.loc))",
      )

    if props.access.isWritable:
      var writer = CodeGenProcDef(
        keyword: "proc",
        name: "write",
        public: true,
        args: @[("reg", regTypeName), ("val", valType)],
        pragma: @["inline"],
      )
      writer.body = fmt"volatileStore(cast[ptr {valType}](reg.loc), val)"
      result[fmt"write[{regTypeName}]"] = writer

      if reg.hasFields:
        let fw = ctx.createFieldsWriter(reg, regTypeName, valType)
        # fields writer proc would have exactly one argument if all fields are read-only
        # Only generate the fields writer if at least one field is writable
        if fw.args.len > 1:
          result[fmt"write_fields[{regTypeName}]"] = fw

    if props.access.isReadable and props.access.isWritable:
      var modTpl = CodeGenProcDef(
        keyword: "template",
        name: "modifyIt",
        public: true,
        args: @[("reg", regTypeName), ("op", "untyped")],
        retType: "untyped",
      )
      modTpl.body = """
      block:
        var it {.inject.} = reg.read()
        op
        reg.write(it)
      """
        .dedent()
        .strip(leading = false)
      result[fmt"modifyIt[{regTypeName}]"] = modTpl

proc renderRegister(
    reg: SvdRegisterTreeNode,
    typeName: string,
    numIndent: Natural,
    baseAddress: Natural,
    tg: File,
) =
  assert reg.kind == rnkRegister

  if reg.isDimArray:
    tg.write("[\n")
    for arrIndex in 0 ..< (reg.dimGroup.dim.get):
      let address =
        baseAddress + reg.addressOffset + arrIndex * (reg.dimGroup.dimIncrement.get)
      let locIndent = repeat(Indent, numIndent + 1)
      tg.write(fmt"{locIndent}{typeName}(loc: {address:#x})," & "\n")
    tg.write(repeat(Indent, numIndent) & "],\n")
  else:
    let address = baseAddress + reg.addressOffset
    tg.write(fmt"{typeName}(loc: {address:#x}'u)," & "\n")

proc renderCluster(
  ctx: CodeGenContext,
  cluster: SvdRegisterTreeNode,
  numIndent: Natural,
  baseAddress: Natural,
  tg: File,
)

proc renderObjectMembers(
    ctx: CodeGenContext,
    e: SvdRegisterParent,
    baseAddress: Natural,
    numIndent: Natural,
    tg: File,
) =
  when typeof(e) is SvdRegisterTreeNode:
    assert e.kind == rnkCluster

  let children = block:
    var c = toSeq e.iterRegisters
    c.sort cmpAddrOffset
    c

  let locIndent = repeat(Indent, numIndent)

  for c in children:
    let
      fName = ctx.getObjectMemberName(c)
      typeName = ctx.typeMap[c.id]
    tg.write(fmt"{locIndent}{fName}: ")

    case c.kind
    of rnkRegister:
      renderRegister(c, typeName, numIndent, baseAddress, tg)
    of rnkCluster:
      ctx.renderCluster(c, numIndent, baseAddress, tg)

proc renderCluster(
    ctx: CodeGenContext,
    cluster: SvdRegisterTreeNode,
    numIndent: Natural,
    baseAddress: Natural,
    tg: File,
) =
  assert cluster.kind == rnkCluster
  let typeName = ctx.typeMap[cluster.id]

  if cluster.isDimArray:
    # TODO: dim array of clusters has not been tested. Find or create SVD snippet
    # using this codepath to test.
    let locIndent = repeat(Indent, numIndent + 1)
    tg.write("[\n")
    for arrIndex in 0 ..< (cluster.dimGroup.dim.get):
      let address =
        baseAddress + cluster.addressOffset +
        arrIndex * (cluster.dimGroup.dimIncrement.get)
      tg.write(fmt"{locIndent}{typeName}(" & "\n")
      ctx.renderObjectMembers(cluster, address, numIndent + 2, tg)
      tg.write(locIndent & "),\n")
    tg.write(repeat(Indent, numIndent) & "],\n")
  else:
    let address = baseAddress + cluster.addressOffset
    tg.write(fmt"{typeName}(" & "\n")
    ctx.renderObjectMembers(cluster, address, numIndent + 1, tg)
    tg.write(repeat(Indent, numIndent) & "),\n")

proc renderPeripheral(ctx: CodeGenContext, periph: SvdPeripheral, tg: File): string =
  let
    insName = periph.name.stripPlaceHolder.sanitizeIdent
    pTypeName = ctx.typeMap[periph.id]

  if periph.isDimArray:
    # TODO: dim array of peripherals has not been tested. Find or create SVD snippet
    # using this codepath to test.
    tg.writeLine(fmt"const {insName}* = [")
    for arrIndex in 0 ..< (periph.dimGroup.dim.get):
      let address = periph.baseAddress + arrIndex * periph.dimGroup.dimIncrement.get
      tg.write(fmt"{Indent}{pTypeName}(" & "\n")
      ctx.renderObjectMembers(periph, address, 2, tg)
      tg.write(Indent & "),\n")
    tg.write(Indent & "],\n\n")
  else:
    tg.writeLine(fmt"const {insName}* = {pTypeName}(")
    ctx.renderObjectMembers(periph, periph.baseAddress, 1, tg)
    tg.write(")\n\n")

  result = insname

proc renderEnum(en: CodeGenEnumDef, tg: File) =
  let
    star = if en.public: "*" else: ""
    pragmaStr =
      if en.pragma.len > 0:
        fmt" {{.{en.pragma}.}}"
      else:
        ""
  tg.writeLine(fmt"type {en.name}{star}{pragmaStr} = enum")
  for (k, v) in en.fields:
    tg.writeLine(fmt"{Indent}{k} = {v:#x},")
  tg.write "\n"

proc renderDistinctTypes(typedefs: seq[CodeGenDistinctDef], tg: File) =
  if typedefs.len == 0:
    return
  tg.writeLine "type"
  for def in typedefs:
    let star = if def.public: "*" else: ""
    tg.writeLine fmt"{Indent}{def.name}{star} = distinct {def.basetype}"
  tg.write("\n")

proc renderProcDef(prd: CodeGenProcDef, tg: File) =
  let
    retString =
      if prd.retType.len > 0:
        ": " & prd.retType
      else:
        ""
    star = if prd.public: "*" else: ""
    pragmaStr =
      if prd.pragma.len > 0:
        " {." & prd.pragma.join(", ") & ".}"
      else:
        ""

  var argStringSeq: seq[string]
  for argObj in prd.args:
    let defValStr =
      if argObj.defaultVal.isNone:
        ""
      else:
        " = " & argObj.defaultVal.get
    argStringSeq.add fmt"{argObj.name}: {argObj.typ}{defValStr}"
  let argString = argStringSeq.join ", "

  tg.writeLine(fmt"{prd.keyword} {prd.name}{star}({argString}){retString}{pragmaStr} =")
  for line in prd.body.splitLines:
    tg.writeLine Indent & line
  tg.write "\n"

func asSingleLine(s: string): string =
  s.splitLines.mapIt(it.strip).join(" ")

proc renderHeader(text: string, outf: File) =
  outf.write("\n")
  outf.write(repeat("#", 80))
  outf.write("\n")
  outf.write(text)
  outf.write("\n")
  outf.write(repeat("#", 80))
  outf.write("\n")

proc renderInterrupts(ctx: CodeGenContext, outf: File) =
  renderHeader("# Interrupt Number Definition", outf)
  outf.writeLine("type IRQn* = enum")
  let
    cmExcHdr = "# #### CPU Core Exception Numbers "
    devIrqHdr = "# #### Device Peripheral Interrupts "
  template irqHeader(s: string) {.dirty.} =
    outf.writeLine(s & repeat("#", 80 - len(s)))

  # CPU core interupts
  irqHeader cmExcHdr
  let cpuKey = ctx.dev.cpu.name.replace("+", "PLUS")
  if cpuKey in CpuIrqTable:
    let coreInterrupts = CpuIrqTable[cpuKey]
    for cIrq in coreInterrupts:
      let desc = CpuIrqArray[cIrq].description
      outf.writeLine fmt"  {$cIrq:20} = {cIrq.int:4} # {desc}"
  else:
    # Unknown CPU and CPU-specific exceptions
    outf.writeLine "# Unknown CPU, svd2nim could not generate CPU exception numbers\n"

  # Peripheral interrupts
  irqHeader devIrqHdr
  let interrupts = toSeq(ctx.dev.peripherals.values)
    .mapIt(it.interrupts)
    .foldl(a & b)
    .sortedByIt(it.value)
  for (i, iter) in interrupts.pairs:
    if i > 0 and iter.value == interrupts[i - 1].value:
      # Skip duplicated interrupts
      continue
    outf.writeLine fmt"  irq{iter.name:17} = {iter.value:4} # {iter.description.asSingleLine}"

func convertCpuRevision(text: string): uint =
  # Based on:
  # https://github.com/Open-CMSIS-Pack/devtools/blob/259aa1f6755bd96497acdf403a008a4ba4cb2d66/tools/svdconv/SVDModel/src/SvdUtils.cpp#L246
  let pat = re2"r(\d+)p(\d+)"
  let revText = text.toLowerAscii
  var m: RegexMatch2
  doAssert revText.match(pat, m)
  let
    major = revText[m.group(0)].parseUInt
    minor = revText[m.group(1)].parseUInt
  result = (major shl 8) or (minor)

func quoted(s: string): string =
  '"' & s & '"'

proc renderDeviceConsts(ctx: var CodeGenContext, outf: File) =
  if not ctx.dev.cpu.isNil:
    outf.write("# Some information about this device.\n")

    let
      cpuNameSan = ctx.dev.cpu.name.replace(re2"(M\\d+)\\+", "$1PLUS").sanitizeIdent
      cpuConsts = {
        "DEVICE": quoted(ctx.dev.metadata.name),
        fmt"{cpuNameSan}_REV": fmt"{convertCpuRevision(ctx.dev.cpu.revision):#06x}",
        "MPU_PRESENT": $ctx.dev.cpu.mpuPresent,
        "FPU_PRESENT": $ctx.dev.cpu.fpuPresent,
        "VTOR_PRESENT": $ctx.dev.cpu.vtorPresent,
        "NVIC_PRIO_BITS": $ctx.dev.cpu.nvicPrioBits,
        "Vendor_SysTickConfig": $ctx.dev.cpu.vendorSystickConfig,
      }

    for (k, v) in cpuConsts:
      outf.writeLine fmt"const {k}* = {v}"
      ctx.symbols.incl nimIdentKey(k)

proc renderCoreModule(ctx: CodeGenContext, devFileName: string) =
  const coreBindings = {"core_cm0plus": staticRead("../core/core_cm0plus.nim")}
  # TODO: core module for other CPUs
    .toTable

  let coreFile =
    case ctx.dev.cpu.name
    of "CM0+": "core_cm0plus"
    of "CM0P": "core_cm0plus"
    of "CM0PLUS": "core_cm0plus"
    else: ""

  if coreFile.len == 0:
    warn fmt"Core header bindings not implemented for CPU ""{ctx.dev.cpu.name}""."
    return

  let (dirPath, devModule, _) = splitFile devFileName

  # Import the generated device module in the core module
  let templated = coreBindings[coreFile].replace("{{DEVICE_MODULE}}", devModule)

  writeFile(joinPath(dirPath, coreFile & ".nim"), templated)

proc renderUncheckedenums(outFileName: string) =
  const
    modname = "uncheckedenums.nim"
    contents = staticRead ".." / "utils" / modname
  writeFile(joinPath(outFileName.parentDir, modname), contents)

proc renderPeripheralRegTypeDefs(ctx: var CodeGenContext, outf: File) =
  renderHeader("# Type definitions for peripheral registers", outf)
  let typeDefs = ctx.createTypeDefs()
  for t in typeDefs:
    ctx.symbols.incl nimIdentKey(t.name)
    t.renderType(outf)
    outf.writeLine("")

proc renderPeripheralInstances(ctx: var CodeGenContext, outf: File) =
  renderHeader("# Peripheral object instances", outf)
  for periph in ctx.dev.peripherals.values:
    let constName = ctx.renderPeripheral(periph, outf)
    ctx.symbols.incl nimIdentKey(constName)

proc renderPeripheralRegAccessors(ctx: var CodeGenContext, outf: File) =
  ## Use sets to deduplicate generated code types and procs
  renderHeader("# Accessors for peripheral registers", outf)
  var
    fieldDistinctDefs: HashSet[string]
    enumDefs: HashSet[string]
    accDefs: HashSet[string]

  for p in ctx.dev.peripherals.values:
    var typedefs: seq[CodeGenDistinctDef]
    for (name, def) in ctx.createBitfieldTypes(p).pairs:
      if name in fieldDistinctDefs:
        continue
      fieldDistinctDefs.incl name
      ctx.symbols.incl nimIdentKey(name)
      typedefs.add def
    renderDistinctTypes(typedefs, outf)

    for (name, en) in ctx.createFieldEnums(p).pairs:
      if name in enumDefs:
        continue
      enumDefs.incl name
      ctx.symbols.incl nimIdentKey(en.name)
      renderEnum(en, outf)

    for (name, acc) in ctx.createAccessors(p).pairs:
      if name in accDefs:
        continue
      accDefs.incl name
      renderProcDef(acc, outf)

    for (name, bfacc) in ctx.createBitfieldAccessors(p).pairs:
      if name in accDefs:
        continue
      accDefs.incl name
      renderProcDef(bfacc, outf)

proc renderDevice*(ctx: var CodeGenContext, dirpath: string) =
  let outFileName = dirPath / ctx.dev.metadata.name.toLower() & ".nim"
  var outf = open(outFileName, fmWrite)
  defer:
    outf.close()

  renderNimImportExports(ctx, outf)

  ctx.renderDeviceConsts(outf)
  renderInterrupts(ctx, outf)
  renderCoreModule(ctx, outFileName)
  renderUncheckedenums(outFileName)

  ctx.buildTypeMap()

  ctx.renderPeripheralRegTypeDefs(outf)
  ctx.renderPeripheralInstances(outf)
  ctx.renderPeripheralRegAccessors(outf)
