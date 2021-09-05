#[
  Convert SVD file to nim register memory mappings
]#
import os
import strutils
import strtabs
import tables
import algorithm
import sequtils
import httpclient, htmlparser, xmltree
import tables
import docopt
import zip/zipfiles
import regex
import json
import basetypes
import svdparser
import codegen
import expansions
import sets

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
    outf.write(repeat(" ", 40-len(itername)))
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

proc renderStartup(d: SvdDevice, outf: File) =
  outf.write("""# Automatically generated file. DO NOT EDIT.
// Generated by gen-device-svd.py from $#
//
//
// $#
.syntax unified
// This is the default handler for interrupts, if triggered but not defined.
.section .text.Default_Handler
.global  Default_Handler
.type    Default_Handler, %function
Default_Handler:
  wfe
  b    Default_Handler
# Avoid the need for repeated .weak and .set instructions.
.macro IRQ handler
  .weak  \\handler
  .set   \\handler, Default_Handler
.endm
// Must set the "a" flag on the section:\n
// https://svnweb.freebsd.org/base/stable/11/sys/arm/arm/locore-v4.S?r1=321049&r2=321048&pathrev=321049
// https://sourceware.org/binutils/docs/as/Section.html#ELF-Version
.section .isr_vector, "a", %progbits
.global  __isr_vector
  // Interrupt vector as defined by Cortex-M, starting with the stack top.
  // On reset, SP is initialized with *0x0 and PC is loaded with *0x4, loading
  // _stack_top and Reset_Handler.
  .long _stack_top\n
  .long Reset_Handler\n
  .long NMI_Handler\n
  .long HardFault_Handler\n
  .long MemoryManagement_Handler\n
  .long BusFault_Handler\n
  .long UsageFault_Handler
  .long 0
  .long 0
  .long 0
  .long 0
  .long SVC_Handler
  .long DebugMon_Handler
  .long 0
  .long PendSV_Handler
  .long SysTick_Handler
  // Extra interrupts for peripherals defined by the hardware vendor.
""" % [d.metadata.name, d.metadata.description, d.metadata.licenseBlock])

  let interrupts = d.getInterrupts
  var num = 0
  for intr in interrupts:
    if intr.value == num - 1:
        continue
    if intr.value < num:
        raise newException(ValueError,"interrupt numbers are not sorted")
    while intr.value > num:
        outf.write("  .long 0\n")
        num += 1
    num += 1
    outf.write("  .long $#_IRQHandler\n" % [intr.name])

  outf.write("""  // Define default implementations for interrupts, redirecting to
  // Default_Handler when not implemented.
  IRQ NMI_Handler
  IRQ HardFault_Handler
  IRQ MemoryManagement_Handler
  IRQ BusFault_Handler
  IRQ UsageFault_Handler
  IRQ SVC_Handler
  IRQ DebugMon_Handler
  IRQ PendSV_Handler
  IRQ SysTick_Handler
""")
  for intr in interrupts:
    outf.write("  IRQ $#_IRQHandler\n" % [intr.name])

###############################################################################
# SVD Parser and SVD Updating
###############################################################################

# Gets the patched SVD's from https://stm32.agg.io/rs/
proc updatePatchedSVD() =
  var url = "https://stm32.agg.io/rs/"

  var client = newHttpClient()
  let html = client.getContent(url).parseHtml()

  if not dirExists("./svd/stm32-patched"):
    createDir("./svd/stm32-patched")
  echo("Fetching SVD files")
  for a in html.findAll("a"):
    if a.attrs.hasKey("href"):
      if a.attrs["href"].contains("svd"):
        var svdUrl = url & a.attrs["href"]
        try:
          let svd = client.getContent(svdUrl)
          var file = "svd/stm32-patched/" & a.attrs["href"].replace(".patched","")
          var output = open(file, fmWrite)
          output.write(svd)
          output.close()
        except:
          echo("$# not found" % svdUrl)
  discard

proc updateSVD() =
  if not dirExists("./svd"):
    createDir("./svd/")
    # Download the SVD files
  if not fileExists("svd/cmsis-svd.zip"):
    let svdUrl = "https://github.com/posborne/cmsis-svd/archive/master.zip"

    var client = newHttpClient()
    echo "Downloading from ", svdUrl
    client.downloadFile(svdUrl,"svd/cmsis-svd.zip")

  var z = ZipArchive()
  let dest = "./svd"
  if not z.open("svd/cmsis-svd.zip"):
    echo "Couldn't open file"
  echo("Extracting SVD files")
  z.extractAll(dest)
  z.close()

proc processSvd(path: string): SvdDevice =
  # Parse SVD file and apply some post-processing
  result = readSVD(path)

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
  svd2nim - A SVD to Register memory maps generator for STM32.

  Usage:
    svd2nim <svdFile>
    svd2nim [-u | --update]
    svd2nim [-p | --updatePatched]
    svd2nim (-h | --help)
    svd2nim (-v | --version)

  Options:
    -u --update         # Get the latest version of the SVD files from https://github.com/posborne/cmsis-svd/
    -p --updatePatched  # Get the latest version of the SVD files from https://stm32.agg.io/rs/
    -h --help           # Show this screen.
    -v --version        # Show version.
  """

  let args = docopt(help, version = "0.1.0")
  # Get Parameters
  if args.contains("-u") or args.contains("--update"):
    if args["--update"]:
      updateSVD()
  if args.contains("-p") or args.contains("--updatePatched"):
    if args["--updatePatched"]:
      updatePatchedSVD()
  if args.contains("<svdFile>"):
    let dev = processSvd($args["<svdFile>"])

    var outf = open(dev.metadata.name.toLower() & ".nim",fmWrite)
    renderDevice(dev, outf)

    outf = open(dev.metadata.name.toLower() & ".s", fmwrite)
    renderStartup(dev, outf)

  else:
    echo "Try: svd2nim -h"

when isMainModule:
  main()
