#[
  Convert SVD file to nim register memory mappings
]#
import std/tables
import std/strutils
import std/strformat
import std/strscans
import std/options
import std/os

import docopt

import ./basetypes
import ./svdparser
import ./transformations
import ./codegen

proc warnNotImplemented(dev: SvdDevice) =
  for p in dev.peripherals.values:
    if p.dimGroup.dim.isSome and p.name.contains("[%s]"):
      stderr.writeLine(fmt"WARNING: Peripheral {p.name} is a dim array, not implemented.")

    for reg in p.walkRegistersOnly:
      for field in reg.fields:
        if field.derivedFrom.isSome:
          stderr.writeLine(fmt"WARNING: Register field {reg.name}.{field.name} of peripheral {p.name} is derived, not implemented.")

        if field.dimGroup.dim.isSome:
          stderr.writeLine(fmt"WARNING: Register field {reg.name}.{field.name} of peripheral {p.name} contains dimGroup, not implemented.")

        if field.enumValues.isSome and field.enumValues.get.derivedFrom.isSome:
          stderr.writeLine(fmt"WARNING: Register field {reg.name}.{field.name} of peripheral {p.name} contains a derived enumeration, not implemented.")

proc processSvd*(path: string): SvdDevice =
  # Parse SVD file and apply some post-processing
  result = readSVD(path)
  warnNotImplemented result
  result.deriveAll
  result.expandAll
  result.resolveAllProperties


###############################################################################
# Main
###############################################################################


proc getNimbleVersion(): string {.compileTime.} =
  let dump = staticExec "nimble dump .."
  for ln in dump.splitLines:
    if scanf(ln, "version: \"$*\"", result): return


proc getVersion(): string {.compileTime.} =
  let
    baseVersion = getNimbleVersion()
    gitTags: seq[string] = staticExec("git tag -l --points-at HEAD").split()
    prerelease = gitTags.find(baseVersion) < 0

  result =
    if prerelease:
      let shortHash = staticExec "git rev-parse --short HEAD"
      baseVersion & "-dev-" & shortHash
    else:
      baseVersion


proc main() =
  let help = """
  svd2nim - Generate Nim peripheral register APIs for ARM using CMSIS-SVD files.

  Usage:
    svd2nim [options] <SvdFile>
    svd2nim (-h | --help)
    svd2nim --version

  Options:
    -h --help           Show this screen.
    -v --version        Show version.
    -o DIR              Specify output directory for generated files. (default: ./)
    --ignore-prepend    Ignore peripheral <prependToName>
    --ignore-append     Ignore peripheral <appendToName>
  """
  let args = docopt(help, version=getVersion())
  for (k, v) in args.pairs: echo fmt"{k}: {v}" # Dump args for debugging
  # Get Parameters
  if args.contains("<SvdFile>"):
    let
      dev = processSvd($args["<SvdFile>"])
      outDirName = if args["-o"]: $args["-o"] else: getCurrentDir()

    if not dirExists(outDirName):
      stderr.writeLine "ERROR: Output directory does not exist."
      quit(1)

    let cgopts = CodeGenOptions(
      ignoreAppend: args["--ignore-append"],
      ignorePrepend: args["--ignore-prepend"],
    )

    setOptions cgopts
    renderDevice(dev, outDirName)
  else:
    stderr.writeLine "Try: svd2nim -h"
    quit(1)


when isMainModule:
  main()
