import std/strformat
import std/strutils
import std/sequtils
import std/algorithm
import std/tables
import std/sets
import std/options
import std/bitops

import ../basetypes
import ../utils
import ./model
import ./typemap

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

func getObjectMemberName*(ctx: CodeGenContext, n: SvdRegisterTreeNode): string =
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

func createTypeDefs*(ctx: CodeGenContext): seq[CodeGenTypeDef] =
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

func getEnumPrefix(enmDef: CodeGenEnumDef): string =
  var lastPart = enmDef.name.split("_")[^1]
  while lastPart.len > 0 and lastPart[0] notin Letters:
    lastPart = lastPart[1 .. lastPart.high]

  result =
    if lastPart.len > 0:
      lastPart[0 .. min(lastPart.high, 2)].toLowerAscii
    else:
      "x"

func createEnum*(
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

func createFieldEnums*(
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

func createBitfieldTypes*(
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

func createBitfieldAccessors*(
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

func createAccessors*(
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
