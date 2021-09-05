#[
  Convert SVD file to nim register memory mappings
]#
import strutils
import tables
import docopt
import basetypes
import svdparser
import codegen
import expansions
import strformat

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

proc processSvd(path: string): SvdDevice =
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

proc main() =
  let help = """
  svd2nim - Generate Nim peripheral register APIs for ARM using CMSIS-SVD files.

  Usage:
    svd2nim [-o FILE] <SvdFile>
    svd2nim (-h | --help)
    svd2nim (-v | --version)

  Options:
    -h --help           Show this screen.
    -v --version        Show version.
    -o FILE             Specify output file. (default: ./<device_name>.nim)
  """

  let args = docopt(help, version = "0.2.0")
  #for (k, v) in args.pairs: echo fmt"{k}: {v}"
  # Get Parameters
  if args.contains("<SvdFile>"):
    let
      dev = processSvd($args["<SvdFile>"])
      outFileName = if args["-o"]: $args["-o"] else: dev.metadata.name.toLower() & ".nim"
      outf = open(outFileName, fmWrite)

    renderDevice(dev, outf)
  else:
    echo "Try: svd2nim -h"

when isMainModule:
  main()
