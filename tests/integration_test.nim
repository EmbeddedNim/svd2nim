import std/unittest
import std/macros
import std/tables
import std/strutils
import regex

# Include the generated file so we can have direct access to the register
# pointers. Need to compile and run
# `svd2nim --ignorePrepend tests/ATSAMD21G18A.svd` prior to compiling this
# file. See nimble task "intTest".
include atsamd21g18a

proc parseAddrsFile(fname: static[string]): Table[string, int] =
  var mt: RegexMatch
  for line in staticRead(fname).strip.splitLines:
    if not line.match(re"([._0-9A-Za-z]+):(0[xX][0-9A-Fa-f]+)", mt): continue
    let
      regname = mt.group(0, line)[0]
      regAddr = mt.group(1, line)[0].parseHexInt
    doAssert regName notin result
    result[regName] = regAddr

macro genAddressAsserts(): untyped =
  result = nnkStmtList.newTree()

  let cAddrTable = parseAddrsFile "./tests/addrs.txt"
  assert cAddrTable.len == 1258
  for (regName, regAddr) in cAddrTable.pairs:
    let
      dotNode = parseStmt(regName & ".p")
      castNode = nnkCast.newTree(newIdentNode("int"), dotNode)
      eqNode = infix(castNode, "==", newIntLitNode(regAddr))
    result.add newCall("doAssert", eqNode)
    #result.add newCall("echo", eqNode.toStrLit) # print out the asserts at runtime for debugging

suite "Integration tests":

  test "Check register addresses":
    genAddressAsserts()
