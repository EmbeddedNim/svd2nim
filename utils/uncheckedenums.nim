import std/enumutils

type
  UncheckedEnum*[T: enum] = object
    v: int

func toUncheckedEnum*[T: enum](x: int): UncheckedEnum[T] {.inline.} =
  UncheckedEnum[T](v: x)

func ord*(e: UncheckedEnum): int {.inline.} =
  ## Return int value without check
  e.v

func getUnchecked*[T](x: UncheckedEnum[T]): T {.inline.} =
  ## Return value as Enum type, may be invalid
  cast[T](x.v)

func isValid*[T: enum](x: UncheckedEnum[T]): bool =
  ## Check if the numerical value of `x` is a valid value for enum type `T`.
  let enumRange = T.low.ord..T.high.ord
  if x.v notin enumRange:
    return false
  when T is Ordinal:
    return true
  else:
    # For holey enums we have to check every value
    {.push warning[HoleEnumConv]: off.}
    for entry in items(T):
      if entry.int == x.v:
        return true
    {.pop.}
    return false

func get*[T](x: UncheckedEnum[T]): T {.inline.} =
  ## Convert to base enum type, but will panic if the value is invalid. It is
  ## recommended to check `isValid` before calling this.
  T(x.v)

func `==`*[T](a: UncheckedEnum[T], b: T): bool {.inline.} =
  ## Safe equality check between an enum `T` and `UncheckedEnum[T]`. No cast
  ## or type conversion is performed, only the numeric (ord) values are directly
  ## compared.
  a.ord == b.ord

func `==`*[T](b: T, a: UncheckedEnum[T]): bool {.inline.} =
  ## Safe equality check between an enum `T` and `UncheckedEnum[T]`. No cast
  ## or type conversion is performed, only the numeric (ord) values are directly
  ## compared.
  a.ord == b.ord
