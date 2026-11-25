#[
  check_golden - Golden-master regression checker for svd2nim.

  Builds svd2nim, generates a Nim module for every SVD under tests/, and
  compares the result byte-for-byte against the committed golden masters in
  golden/. Use this after refactoring to ensure generated output is unchanged.

  Usage:
    check_golden              Compare generated output to golden masters.
    check_golden --update     Regenerate golden masters from the current code.
    check_golden --update R   Check out refspec R, build, regenerate masters,
                              then return to the original branch/commit.

  Golden masters are intentionally gitignored; regenerate them locally with
  --update when establishing a new baseline.
]#
import std/os
import std/osproc
import std/strutils

import docopt

const Svds = [
  ("tests/ARM_Example.svd", @[]),
  ("tests/ATSAMD21G18A.svd", @["--ignore-prepend"]),
  ("tests/esp32.svd", @[]),
  ("tests/RP2040.svd", @[]),
  ("tests/STM32F103.svd", @[]),
  ("tests/stm32f429.svd", @[]),
]

let help = """
  check_golden - Compare generated SVD output against golden masters.

  Usage:
    check_golden [options]
    check_golden --update [<refspec>]
    check_golden (-h | --help)

  Options:
    -h --help           Show this screen.
    --update            Regenerate golden masters instead of comparing.
                        If <refspec> is given, check out that refspec first,
                        build, generate, then return to the original commit.
"""

proc moduleName(svdPath: string): string =
  svdPath.splitFile.name.toLowerAscii & ".nim"

proc buildSvd2nim(): bool =
  let (outp, code) = execCmdEx("nimble build")
  if code != 0:
    echo outp
    return false
  true

proc main() =
  let args = docopt(help)
  let refspecRaw = $(args["<refspec>"])
  let refspec = if refspecRaw == "nil": "" else: refspecRaw
  let update = bool(args["--update"]) or refspec != ""

  var origRev = ""
  var origRef = ""
  var stashed = false
  var checkedOut = false

  proc restore() =
    if checkedOut:
      discard execCmdEx("git checkout " & origRef)
      checkedOut = false
    if stashed:
      discard execCmdEx("git stash pop")
      stashed = false

  let outDir = "tmp" / "golden_check"
  if dirExists(outDir):
    removeDir(outDir)
  createDir(outDir)

  try:
    if refspec != "":
      let (o, oc) = execCmdEx("git rev-parse HEAD")
      if oc != 0:
        echo "Could not determine current commit."
        quit(1)
      origRev = o.strip()

      let (b, bc) = execCmdEx("git symbolic-ref --short HEAD")
      origRef =
        if bc == 0:
          b.strip()
        else:
          origRev

      let (status, _) = execCmdEx("git status --porcelain")
      if status.strip() != "":
        let (_, sc) = execCmdEx("git stash push -m \"check_golden\"")
        if sc != 0:
          echo "Failed to stash local changes."
          quit(1)
        stashed = true

      let (_, cc) = execCmdEx("git checkout " & refspec)
      if cc != 0:
        echo "Failed to check out refspec: ", refspec
        quit(1)
      checkedOut = true

    if not buildSvd2nim():
      quit(1)

    var failed = false
    for (svd, flags) in Svds:
      let modName = moduleName(svd)
      let cmd = @["./build/svd2nim"] & flags & @[svd, "-o", outDir]
      let (outp, code) = execCmdEx(cmd.join(" "))
      if code != 0:
        echo "BUILD FAILED: ", svd
        echo outp
        failed = true
        continue
      let generated = outDir / modName
      let golden = "golden" / modName
      if update:
        if not dirExists("golden"):
          createDir("golden")
        copyFile(generated, golden)
        echo "UPDATED: ", golden
        continue
      if not fileExists(golden):
        echo "MISSING GOLDEN: ", golden
        failed = true
        continue
      if readFile(generated) != readFile(golden):
        echo "DIFF: ", modName
        let (diffOut, _) = execCmdEx("diff -u " & golden & " " & generated)
        echo diffOut
        failed = true
      else:
        echo "OK: ", modName

    if failed:
      quit(1)
    echo "All golden checks passed."
  finally:
    restore()

main()
