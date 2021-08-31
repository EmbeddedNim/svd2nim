import regex
import basetypes

func sanitizeIdent*(ident: string): string =
  # Sanitize identifier so that it conforms to nim's rules
  # Exported (*) for testing purposes
  const reptab = [
    (re"[!$%&*+-./:<=>?@\\^|~]", ""),         # Operators
    (re"[\[\]\(\)`\{\},;\.:]", ""),           # Other tokens
    (re"_(_)+", "_"),                         # Subsequent underscores
    (re"_$", ""),                             # Trailing underscore
  ]

  result = ident
  for (reg, repl) in reptab:
    result = result.replace(reg, repl)

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