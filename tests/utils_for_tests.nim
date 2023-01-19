import basetypes

func findRegister*(n: SvdRegisterParent, name: string): SvdRegisterTreeNode =
  for c in n.registers.get:
    if c.name == name:
      return c