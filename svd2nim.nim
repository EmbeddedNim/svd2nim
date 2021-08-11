#[
  Convert SVD file to nim register memory mappings
]#
import os
import algorithm
import strutils, strtabs, sequtils
import httpclient, htmlparser, xmltree
import tables
import docopt
import zip/zipfiles
import regex
import json

import svdparser
import svdjson

###############################################################################
# Register generation from SVD
###############################################################################
func sanitizeIdent*(ident: string): string =
  # Sanitize identifier so that it conforms to nim's rules
  # Exported (*) for testing purposes
  const reptab: array[4, (Regex, string)] = [
    (re"[!$%&*+-./:<=>?@\\^|~]", ""),         # Operators
    (re"[\[\]\(\)`\{\},;\.:]", ""),           # Other tokens
    (re"_(_)+", "_"),                         # Subsequent underscores
    (re"_$", ""),                             # Trailing underscore
  ]

  result = ident
  for (reg, repl) in reptab:
    result = result.replace(reg, repl)

proc sanitizeRegister(reg: var svdRegister) =
  # Recursively sanitize register
  reg.name = reg.name.sanitizeIdent
  for sreg in reg.registers.mitems:
    sanitizeRegister(sreg)

  for f in reg.bitfields.mitems:
    f.name = f.name.sanitizeIdent

proc sanitizePeriph(periph: var svdPeripheral) =
  # Recursively sanitize peripheral
  periph.name = periph.name.sanitizeIdent
  periph.typeName = periph.name.sanitizeIdent
  periph.groupName = periph.name.sanitizeIdent
  periph.clusterName = periph.name.sanitizeIdent

  for reg in periph.registers.mitems:
    reg.sanitizeRegister

  for speriph in periph.subtypes.mitems:
    speriph.sanitizePeriph

func sanitizeAllNames*(dev: svdDevice): svdDevice =
  deepCopy(result, dev)

  for periph in result.peripherals.mitems:
    periph.sanitizePeriph

  for ipt in result.interrupts:
    ipt.name = ipt.name.sanitizeIdent

proc renderHeader(text: string, outf: File) =
  outf.write("\n")
  outf.write(repeat("#",80))
  outf.write("\n")
  outf.write(text)
  outf.write("\n")
  outf.write(repeat("#",80))
  outf.write("\n")

proc renderCortexMExceptionNumbers(cpu: svdCpu, outf: File) =
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

proc renderInterrupt(interrupts: seq[svdInterrupt], outf: File) =
  var maxIrq = 0
  # Find all interrupts
  for iter in interrupts:
    if maxIrq < iter.index:
      maxIrq = iter.index
    if iter.index <= 1:
      continue
    var itername = format("  $#_IRQn = $#, " % [iter.name.toUpper, iter.index.intToStr()])
    outf.write(itername)
    outf.write(repeat(" ", 40-len(itername)))
    outf.write("# $#\n" % iter.description)

proc renderRegisterBitfields(register: svdRegister, name: string, outf: File) =
  var sortedBitfields = register.bitfields
  sortedBitfields.sort(proc (x,y: svdField): int = cmp(x.name, y.name))
  outf.write("  # $#" % name)
  if register.description != "":
    outf.write(": $#" % register.description)
  outf.write("\n")
  for bitfield in sortedBitfields:
    var value: string
    if bitfield.value == 0:
      value = "0"
    else:
      value = uint32(bitfield.value).toHex().strip(leading=true, trailing=false, {'0'})
    outf.write("  $#* = 0x$#\n" % [bitfield.name, value])


proc renderPeripheralObjects(peripherals: seq[svdPeripheral], fpu: bool, outf: File) =
  var periphTypes: seq[string]
  var sortedPeripherals: seq[svdPeripheral]
  var distinctRegs: seq[svdRegister]
  # Filter
  sortedPeripherals = peripherals
  sortedPeripherals.sort(proc (x,y: svdPeripheral): int = cmp(x.name, y.name))

  # Render
  renderHeader("# Peripheral Register Objects", outf)

  for periph in sortedPeripherals:
    if periphTypes.contains(periph.typeName) or periph.derivedFrom != "":
      continue
    periphTypes.add(periph.typeName)

  for ptype in periphTypes:
    outf.write("type $#_Registers = object\n" % ptype)

    var grpPeriphs = sortedPeripherals
    grpPeriphs.keepItIf(it.typeName == ptype)

    distinctRegs = @[]
    for grpPeriph in grpPeriphs:
      for reg in grpPeriph.registers:
        if distinctRegs.anyIt(it.name == reg.name):
          continue
        else:
          distinctRegs.add(reg)
    for reg in distinctRegs:
      var regDef = "  $#*: uint32" % [reg.name]
      outf.write(regDef)
      outf.write(repeat(" ", 40-len(regDef)))
      outf.write("# $#\n" % reg.description)

    outf.write("\n")

  renderHeader("# Peripherals", outf)
  outf.write("const\n")
  for periph in sortedPeripherals:
    outf.write("  p$# = cast[pointer](0x$#)\n" % [periph.name, periph.baseAddress.toHex()])
  outf.write("\n")
  outf.write("const\n")
  for periph in sortedPeripherals:
    outf.write("  $#* = cast[ptr $#_Registers](p$#)\n" % [periph.name, periph.typeName, periph.name])

  for ptype in periphTypes:
    renderHeader("# Bitfields for $#" % [ptype], outf)

    var grpPeriphs = sortedPeripherals
    grpPeriphs.keepItIf(it.typeName == ptype)

    distinctRegs = @[]
    for grpPeriph in grpPeriphs:
      for reg in grpPeriph.registers:
        if distinctRegs.anyIt(it.name == reg.name):
          continue
        else:
          distinctRegs.add(reg)

    outf.write("const\n")
    for register in distinctRegs:
      if register.bitfields.len() > 0:
        renderRegisterBitfields(register, register.name, outf)
      for subregister in register.registers:
        renderRegisterBitfields(subregister, register.name & "." & subregister.name, outf)
    outf.write("\n")

proc renderTemplates(outf: File) =
  renderHeader("# Templates", outf)
  outf.write("""template store*[T: SomeInteger, U: SomeInteger](reg: T, val: U) =
  volatileStore(reg.addr, cast[T](val))
""")
  outf.write("\n")
  outf.write("""template load*[T: SomeInteger](reg: T) =
  volatileLoad(reg.addr)
""")
  outf.write("\n")
  outf.write("""template bit*[T: SomeInteger](n: varargs[T]): T =
  var ret: T = 0;
  for i in n:
    ret = ret or (1 shl i)
  ret
""")
  outf.write("\n")
  outf.write("""template shift*[T, U: SomeInteger](reg: T, n: U): T =
  reg shl n
""")
  outf.write("\n")
  outf.write("""template bitSet*[T, U: SomeInteger](reg: T, n :varargs[U]) =
  reg.st reg.ld or cast[T](bit(n))
""")
  outf.write("\n")
  outf.write("""template bitClr*[T, U: SomeInteger](reg: T, n :varargs[U]) =
  reg.st reg.ld and not cast[T](bit(n))
""")
  outf.write("\n")
  outf.write("""template bitIsSet*[T, U: SomeInteger](reg: T, n: U): bool =
  (reg.ld and cast[T](bit(n))) != 0
""")
  outf.write("\n")
  outf.write("""template bitIsClr*[T, U: SomeInteger](reg: T, n: U): bool =
  not bitIsSet(reg, n)
""")
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


proc renderDevice(d: svdDevice, outf: File) =
  echo("Generating nim register mapping for $#" % d.metadata.name)
  outf.write("# Peripheral access API for $# microcontrollers (generated using svd2nim)\n" % d.metadata.name.toUpper())
  outf.write("# You can find an overview of the API here.\n\n")

  var fpuPresent = true

  if not d.cpu.isNil():
    outf.write("# Some information about this device.\n")
    outf.write("const DEVICE* = \"$#\"\n" % d.metadata.name)
  # CPU
    let cpuNameSan = d.cpu.name.replace(re"(M\d+)\+", "$1plus")
    outf.write("const $#_REV* = 0x0001\n" % cpuNameSan)
    outf.write("const MPU_PRESENT* = $#\n" % d.cpu.mpuPresent.intToStr())
    outf.write("const FPU_PRESENT* = $#\n" % d.cpu.fpuPresent.intToStr())
    outf.write("const NVIC_PRIO_BITS* = $#\n" % d.cpu.nvicPrioBits.intToStr())
    outf.write("const Vendor_SysTickConfig* = $#\n" % d.cpu.vendorSystickConfig.intToStr())

  renderCortexMExceptionNumbers(d.cpu, outf)
  renderInterrupt(d.interrupts, outf)
  renderPeripheralObjects(d.peripherals, fpuPresent, outf)
  renderTemplates(outf)
  echo("Done")

proc renderStartup(d: svdDevice, outf: File) =
  echo("Generating startup file for $#" % d.metadata.name)
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

  var num = 0
  for intr in d.interrupts:
    if intr.index == num - 1:
        continue
    if intr.index < num:
        raise newException(ValueError,"interrupt numbers are not sorted")
    while intr.index > num:
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
  for intr in d.interrupts:
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

###############################################################################
# Main
###############################################################################

proc main() =
  let help = """
  svd2nim - A SVD to Register memory maps generator for STM32.

  Usage:
    svd2nim [--json] <svdFile>
    svd2nim [-u | --update]
    svd2nim [-p | --updatePatched]
    svd2nim (-h | --help)
    svd2nim (-v | --version)

  Options:
    -u --update         # Get the latest version of the SVD files from https://github.com/posborne/cmsis-svd/
    -p --updatePatched  # Get the latest version of the SVD files from https://stm32.agg.io/rs/
    -h --help           # Show this screen.
    -v --version        # Show version.
    --json              # Dump json output of parsed SVD (useful for debugging)
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
    let dev = readSVD($args["<svdFile>"])

    var outf = open(dev.metadata.name.toLower() & ".nim",fmWrite)
    renderDevice(dev.sanitizeAllNames, outf)

    outf = open(dev.metadata.name.toLower() & ".s", fmwrite)
    renderStartup(dev, outf)

    if args.contains("--json"):
      outf = open(dev.metadata.name.toLower() & ".json", fmWrite)
      outf.write(dev.toJson.pretty(2))
      outf.close

  else:
    echo "Try: svd2nim -h"

when isMainModule:
  main()
