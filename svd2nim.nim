#[
  Convert SVD file to nim register memory mappings
]#
import strutils
import algorithm
import sequtils
import tables
import docopt
import regex
import basetypes
import svdparser
import codegen
import expansions
import sets
import strformat

###############################################################################
# Register generation from SVD
###############################################################################

proc renderHeader(text: string, outf: File) =
  outf.write("\n")
  outf.write(repeat("#",80))
  outf.write("\n")
  outf.write(text)
  outf.write("\n")
  outf.write(repeat("#",80))
  outf.write("\n")

proc renderCortexMExceptionNumbers(cpu: SvdCpu, outf: File) =
  type exception = object
    name: string
    value: int
    description: string

  let exceptions: seq[exception] = @[
    exception(name: "NonMaskableInt", value: -14, description: "Exception 2: Non Maskable Interrupt"),
    exception(name: "HardFault", value: -13, description: "Exception 3: Hard fault Interrupt"),
    exception(name: "MemoryManagement", value: -12, description: "Exception 4: Memory Management Interrupt [Not on Cortex M0 variants]"),
    exception(name: "BusFault", value: -11, description: "Exception 5: Bus Fault Interrupt [Not on Cortex M0 variants]"),
    exception(name: "UsageFault", value: -10, description: "Exception 6: Usage Fault Interrupt [Not on Cortex M0 variants]"),
    exception(name: "SecureFault", value: -9, description: "Exception 7: Secure Fault Interrupt [Only on Armv8-M]"),
    exception(name: "SVCall", value: -5, description: "Exception 11: SV Call Interrupt"),
    exception(name: "DebugMonitor", value: -4, description: "Exception 12: Debug Monitor Interrupt [Not on Cortex M0 variants]"),
    exception(name: "PendSV", value: -2, description: "Exception 14: Pend SV Interrupt [Not on Cortex M0 variants]"),
    exception(name: "SysTick", value: -1, description: "Exception 15: System Tick Interrupt"),
    exception(name: "WWDG", value: 0, description: "Window WatchDog Interrupt"),
    exception(name: "PVD", value: 1, description: "PVD through EXTI Line detection Interrupt")
  ]
  # Render
  renderHeader("# Interrupt Number Definition", outf)
  outf.write("type IRQn* = enum\n")
  var hdr = "# #### Cortex-M Processor Exception Numbers "
  outf.write(hdr & repeat("#", 80-len(hdr)) & "\n")
  for excep in exceptions:
    if cpu.name.toUpper() in ["CM0","CM0+"]:
      if excep.value in [-12,-11,-10,-9,-4]:
        continue
    else:
      if excep.value in [-9]:
        continue
    if excep.value == 0:
      hdr = "# #### Device specific Interrupt numbers "
      outf.write(hdr & repeat("#", 80-len(hdr)) & "\n")
    var itername = "  $#_IRQn = $#," % [excep.name, excep.value.intToStr()]
    outf.write(itername)
    outf.write(repeat(" ", 40-len(itername)))
    outf.write("# $#\n" % excep.description)

func getInterrupts(dev: SvdDevice): seq[SvdInterrupt] =
  # Get interrupts from all periphs
  dev.peripherals
    .mapIt(it.interrupts)
    .foldl(a & b)
    .sortedByIt(it.value)

proc renderInterrupts(dev: SvdDevice, outf: File) =
  var maxIrq = 0
  # Find all interrupts
  for iter in dev.getInterrupts:
    if maxIrq < iter.value:
      maxIrq = iter.value
    if iter.value <= 1:
      continue
    var itername = format("  $#_IRQn = $#, " % [iter.name.toUpper, iter.value.intToStr()])
    outf.write(itername)
    outf.write(repeat(" ", 60-len(itername)))
    if iter.description.isSome:
      outf.write("# $#" % iter.description.get)
    outf.write("\n")

proc renderTemplates(outf: File) =
  renderHeader("# Templates", outf)
  outf.write("\n")
  outf.write("""template enableIRQ*(irq: IRQn) =
  NVIC.ISER[cast[int](irq) shr 5].st 1 shl (cast[int](irq) and 0x1F)
""")
  outf.write("\n")
  outf.write("""template disableIRQ*(irq: IRQn) =
  NVIC.ISCR[cast[int](irq) shr 5].st 1 shl (cast[int](irq) and 0x1F)
""")
  outf.write("\n")
  outf.write("""template setPriority*[T: SomeInteger](irq: IRQn, pri: T) =
  if cast[int](irq) >= 0: # TODO: implement for IRQn < 0
    NVIC.IP[cast[uint](irq)].st (cast[int](pri) shl 4) and 0xFF
""")

proc renderDevice(d: SvdDevice, outf: File) =
  outf.write("# Peripheral access API for $# microcontrollers (generated using svd2nim)\n\n" % d.metadata.name.toUpper())
  outf.write("import volatile\n\n")

  if not d.cpu.isNil():
    outf.write("# Some information about this device.\n")
    outf.write("const DEVICE* = \"$#\"\n" % d.metadata.name)
  # CPU
    let cpuNameSan = d.cpu.name.replace(re"(M\d+)\+", "$1PLUS")
    outf.write("const $#_REV* = 0x0001\n" % cpuNameSan)
    outf.write("const MPU_PRESENT* = $#\n" % d.cpu.mpuPresent.intToStr())
    outf.write("const FPU_PRESENT* = $#\n" % d.cpu.fpuPresent.intToStr())
    outf.write("const NVIC_PRIO_BITS* = $#\n" % d.cpu.nvicPrioBits.intToStr())
    outf.write("const Vendor_SysTickConfig* = $#\n" % d.cpu.vendorSystickConfig.intToStr())

  renderCortexMExceptionNumbers(d.cpu, outf)
  renderInterrupts(d, outf)

  renderHeader("# Type definitions for peripheral registers", outf)
  let typeDefs = d.createTypeDefs()
  for t in toSeq(typeDefs.values).reversed:
    t.renderType(outf)
    outf.writeLine("")

  renderHeader("# Peripheral object instances", outf)
  for periph in d.peripherals:
    renderPeripheral(periph, outf)

  renderHeader("# Accessors for peripheral registers", outf)
  # Create hash sets so we don't duplicate typedefs or accessor templates
  # They are already deduplicated within a periph by the create* procs, but
  # duplicates can still be created from another periph, eg when perriphs
  # are derivedFrom or dimlists.
  var
    fieldStructTypes: HashSet[string]
    fieldEnumTypes: HashSet[string]
    accessors: HashSet[string]

  for periph in d.peripherals:
    for (k, objDef) in periph.createBitFieldStructs.pairs:
      if k notin fieldStructTypes:
        fieldStructTypes.incl k
        renderType(objDef, outf)
        outf.write("\n")
    for (k, en) in periph.createFieldEnums.pairs:
      if k notin fieldEnumTypes:
        fieldEnumTypes.incl k
        renderEnum(en, outf)
    for (k, acc) in periph.createAccessors.pairs:
      if k notin accessors:
        accessors.incl k
        renderProcDef(acc, outf)

  renderTemplates(outf)

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
