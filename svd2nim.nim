#[
  Convert SVD file to nim register memory mappings
]#
import std/tables
import std/strutils
import std/strformat
import docopt
import basetypes
import svdparser
import codegen
import expansions

proc warnNotImplemented(dev: SvdDevice) =
  for p in dev.peripherals:
    if p.dimGroup.dim.isSome and p.name.contains("[%s]"):
      stderr.writeLine(fmt"WARNING: Peripheral {p.name} is a dim array, not implemented.")

    for reg in p.allRegisters:
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

  # Expand derivedFrom entities in peripherals and their children
  expandDerives result.peripherals

  # Expand dim lists
  # Note: dim arrays are expanded at codegen time
  result.peripherals = expandAllDimLists(result.peripherals)

###############################################################################
# Main
###############################################################################

proc getVersion(): string {.compileTime.} =
  let
    baseVersion = "0.3.0"
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
    svd2nim (-v | --version)

  Options:
    -h --help           Show this screen.
    -v --version        Show version.
    -o FILE             Specify output file. (default: ./<device_name>.nim)
    --ignorePrepend     Ignore peripheral <prependToName>
    --ignoreAppend      Ignore peripheral <appendToName>
  """
  let args = docopt(help, version=getVersion())
  #for (k, v) in args.pairs: echo fmt"{k}: {v}" # Dump args for debugging
  # Get Parameters
  if args.contains("<SvdFile>"):
    let
      dev = processSvd($args["<SvdFile>"])
      outFileName = if args["-o"]: $args["-o"] else: dev.metadata.name.toLower() & ".nim"
      outf = open(outFileName, fmWrite)

    let cgopts = CodeGenOptions(
      ignoreAppend: args["--ignoreAppend"],
      ignorePrepend: args["--ignorePrepend"]
    )

    setOptions cgopts
    renderDevice(dev, outf)
  else:
    echo "Try: svd2nim -h"

when isMainModule:
  main()
