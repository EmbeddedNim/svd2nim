import std/unittest
import std/macros
import std/genasts
import std/tables
import std/strutils
import std/sequtils
import std/os
import std/osproc
import std/strformat
import regex

import ./utils

include atsamd21g18a

const allSvdFiles = [
  "ATSAMD21G18A.svd",
  "STM32F103.svd",
]


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

  let cAddrTable = parseAddrsFile "./addrs.txt"
  assert cAddrTable.len == 1258
  for (regName, regAddr) in cAddrTable.pairs:
    let
      regNameParts = regName.split('.').map(sanitizeIdent)
      dotNode = parseStmt(regNameParts.join(".") & ".loc")
      eqNode = infix(dotNode, "==", newIntLitNode(regAddr))
    result.add newCall("doAssert", eqNode)

    # print out the asserts at runtime for debugging
    #result.add newCall("echo", eqNode.toStrLit)


when defined windows:
  const svd2nimExec = "svd2nim.exe"
else:
  const svd2nimExec = "svd2nim"


macro genTestSvdFiles: untyped =
  result = newStmtList()
  for svdFile in allSvdFiles:
    result.add:
      genAst(svdFile):
        test ("convert file " & svdFile) :
          # Run svd2nim on SVD file
          let (_, svd2nimExitcode) = execCmdEx join(
            [fmt"../build/{svd2nimExec}", svdFile, "-o ../tmp"], " "
          )
          assert svd2nimExitcode == 0

          # Run nim check on generated nim file
          let
            modname = splitFile(svdFile)[1]
            gendFile = ".." / "tmp" / (modname.toLowerAscii & ".nim")
            nimCheckCmd = "nim check " & gendFile
            nimCheckExitcode = execCmdEx(nimCheckCmd)[1]
          echo nimCheckCmd
          echo nimCheckExitcode
          assert nimCheckExitcode == 0


suite "Integration tests":

  test "Check register addresses":
    genAddressAsserts()

suite "Convert SVD files":
  genTestSvdFiles()
