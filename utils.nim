import regex

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