import basetypes

func findRegister*(n: SvdRegisterParent, name: string): SvdRegisterTreeNode =
  for c in n.registers.get:
    if c.name == name:
      return c

func findField*(n: SvdRegisterTreeNode, name: string): SvdField =
  assert n.kind == rnkRegister
  for c in n.fields:
    if c.name == name:
      return c
