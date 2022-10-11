import std/strutils
import regex
import ./basetypes

const nimKeywords : seq[string] = """
addr and as asm
bind block break
case cast concept const continue converter
defer discard distinct div do
elif else end enum except export
finally for from func
if import in include interface is isnot iterator
let
macro method mixin mod
nil not notin
object of or out
proc ptr
raise ref return
shl shr static
template try tuple type
using
var
when while
xor
yield
""".splitWhitespace()


func sanitizeIdent*(ident: string): string =
  ## Sanitize identifier so that it conforms to nim's rules

  # Strip out characters that can't be used in idents
  # Allow unicode stuff (valid according to Nim 1.6.8 manual)
  for chr in ident:
    if chr in IdentChars or chr.ord > 127:
      result &= chr

  # Identifiers must start with a letter, otherwise prepend "x"
  if result[0] notin IdentStartChars:
    result = "x" & result

  # Underscores
  const reptab = [
    (re"_(_)+", "_"),      # Subsequent underscores
    (re"_$", ""),          # Trailing underscore
  ]
  for (reg, repl) in reptab:
    result = result.replace(reg, repl)

  # Language keywords: append "x" suffix
  if result.toLowerAscii.replace("_", "") in nimKeywords:
    result &= 'x'


func stripPlaceHolder*(s: string): string =
  # Strip %s and [%s] placeholders associated with dimElementGroup
  # elements from strings.
  # https://arm-software.github.io/CMSIS_5/SVD/html/elem_special.html#dimElementGroup_gr
  const pat = re"(%s|_%s$|_?\[%s\]$)"
  s.replace(pat, "")

func getPeriphByName*(dev: SvdDevice, name: string): SvdPeripheral =
  for per in dev.peripherals:
    if per.name == name: return per
  raise newException(ValueError, name & " not found")

func findRegisterByName*(p: SvdPeripheral, name: string): SvdRegister =
  for reg in p.registers:
    if reg.name == name: return reg

  var clusterStack: seq[SvdCluster]
  for cls in p.clusters:
    clusterStack.add cls
  while clusterStack.len > 0:
    let cls = clusterStack.pop
    for reg in cls.registers:
      if reg.name == name: return reg
    for cc in cls.clusters:
      clusterStack.add cc

  raise newException(ValueError, name & " not found")
