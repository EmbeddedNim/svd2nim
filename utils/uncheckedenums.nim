import std/macros


type UncheckedEnum*[T: enum] = object
  v: uint


func toUncheckedEnum*[T: enum](x: uint): UncheckedEnum[T] {.inline.} =
  UncheckedEnum[T](v: x)


func ord*(e: UncheckedEnum): uint {.inline.} =
  ## Return uint value without check
  e.v


func getUnchecked*[T](x: UncheckedEnum[T]): T {.inline.} =
  ## Return value as Enum type, may be invalid
  cast[T](x.v)


macro enumAsIntSet(E: typedesc[enum]): untyped =
  ## Add the ord value of each enum member to a set literal. A subrange type
  ## (`range[E.low.ord .. E.high.ord`]) is used for the set in order to
  ## minimize the memory footprint of the set.
  result = newTree nnkCurly
  let rangeTyp = nnkBracketExpr.newTree(
    ident"range",
    infix(
      newDotExpr(newDotExpr(E, ident"low"), ident"ord"),
      "..",
      newDotExpr(newDotExpr(E, ident"high"), ident"ord"),
    )
  )
  let enmMembers = E.getType[1][1..^1]
  result.add newCall(rangeTyp, newDotExpr(enmMembers[0], ident"ord"))
  for mem in enmMembers[1..^1]:
    result.add newDotExpr(mem, ident"ord")


func isValid*[T: enum](x: UncheckedEnum[T]): bool =
  ## Check if the numerical value of `x` is a valid value for enum type `T`.
  let enumRange = range[T.low.uint .. T.high.uint]
  if x.v notin enumRange:
    return false
  when T is Ordinal:
    return true
  else:
    const fullIntSet = enumAsIntSet T
    return x.v in fullIntSet


func get*[T](x: UncheckedEnum[T]): T {.inline.} =
  ## Convert to base enum type, but will panic if the value is invalid. It is
  ## recommended to check `isValid` before calling this.
  T(x.v)


func `==`*[T](a: UncheckedEnum[T], b: T): bool {.inline.} =
  ## Safe equality check between an enum `T` and `UncheckedEnum[T]`. No cast
  ## or type conversion is performed, only the numeric (ord) values are directly
  ## compared.
  a.ord == uint(b.ord)


func `==`*[T](b: T, a: UncheckedEnum[T]): bool {.inline.} =
  ## Safe equality check between an enum `T` and `UncheckedEnum[T]`. No cast
  ## or type conversion is performed, only the numeric (ord) values are directly
  ## compared.
  a.ord == uint(b.ord)
