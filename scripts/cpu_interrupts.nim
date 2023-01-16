import regex
import std/strutils
import std/sequtils
import std/algorithm
import std/tables
import std/strformat


# The following strings are from SVDConv source code
# https://github.com/Open-CMSIS-Pack/devtools/blob/259aa1f6755bd96497acdf403a008a4ba4cb2d66/tools/svdconv/SVDModel/src/SvdTypes.cpp#L103
#
# SVDConv is Copyright 2020-2021 Arm Limited. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.
#//                                                                          IRQ 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15     *R *U *U *P *E *E *M *M *U *P *U *E *P   *N
const cpuDataString = """
  { SvdTypes::CpuType::CM0      , {"CM0"                , "ARM Cortex-M0"     ,  0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1,     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  32 } },
  { SvdTypes::CpuType::CM0PLUS  , {"CM0PLUS"            , "ARM Cortex-M0+"    ,  0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1,     1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  32 } },
  { SvdTypes::CpuType::CM0P     , {"CM0PLUS"            , "ARM Cortex-M0+"    ,  0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1,     1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  32 } },
  { SvdTypes::CpuType::CM1      , {"CM1"                , "ARM Cortex-M1"     ,  0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1,     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  32 } },
  { SvdTypes::CpuType::SC000    , {"SC000"              , "Secure Core SC000" ,  0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1,     1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  32 } },
  { SvdTypes::CpuType::CM3      , {"CM3"                , "ARM Cortex-M3"     ,  0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1,     0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 240 } },
  { SvdTypes::CpuType::SC300    , {"SC300"              , "Secure Core SC300" ,  0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1,     0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 240 } },
  { SvdTypes::CpuType::CM4      , {"CM4"                , "ARM Cortex-M4"     ,  0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1,     0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 240 } },
  { SvdTypes::CpuType::CM7      , {"CM7"                , "ARM Cortex-M7"     ,  0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1,     0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 240 } },
  { SvdTypes::CpuType::CM33     , {"CM33"               , "ARM Cortex-M33"    ,  0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 1, 1,     1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 480 } },
  { SvdTypes::CpuType::CM23     , {"CM23"               , "ARM Cortex-M23"    ,  0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1,     1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 240 } },
  { SvdTypes::CpuType::CM35     , {"CM35"               , "ARM Cortex-M35"    ,  0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 1, 1,     1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 480 } },
  { SvdTypes::CpuType::CM35P    , {"CM35P"              , "ARM Cortex-M35P"   ,  0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 1, 1,     1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 480 } },
  { SvdTypes::CpuType::V8MML    , {"ARMV8MML"           , "ARM ARMV8MML"      ,  0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 1, 1,     1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 480 } },
  { SvdTypes::CpuType::V8MBL    , {"ARMV8MBL"           , "ARM ARMV8MBL"      ,  0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1,     1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 240 } },
  { SvdTypes::CpuType::V81MML   , {"ARMV81MML"          , "ARM ARMV81MML"     ,  0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 1, 1,     1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 480 } },
  { SvdTypes::CpuType::CM55     , {"CM55"               , "ARM Cortex-M55"    ,  0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 1, 1,     1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 480 } }, // MVE: 0, not generated atm
  { SvdTypes::CpuType::CM85     , {"CM85"               , "ARM Cortex-M85"    ,  0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 1, 1,     1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 480 } }, // MVE: 0, not generated atm
"""

const interruptDataString = """
  { SvdTypes::CpuIrqNum::IRQ0         , { "Reserved0"         , "Stack Top is loaded from first entry of vector Table on Reset"                  } },
  { SvdTypes::CpuIrqNum::IRQ1         , { "Reset"             , "Reset Vector, invoked on Power up and warm reset"                               } },
  { SvdTypes::CpuIrqNum::IRQ2         , { "NonMaskableInt"    , "Non maskable Interrupt, cannot be stopped or preempted"                         } },
  { SvdTypes::CpuIrqNum::IRQ3         , { "HardFault"         , "Hard Fault, all classes of Fault"                                               } },
  { SvdTypes::CpuIrqNum::IRQ4         , { "MemoryManagement"  , "Memory Management, MPU mismatch, including Access Violation and No Match"       } },
  { SvdTypes::CpuIrqNum::IRQ5         , { "BusFault"          , "Bus Fault, Pre-Fetch-, Memory Access Fault, other address/memory related Fault" } },
  { SvdTypes::CpuIrqNum::IRQ6         , { "UsageFault"        , "Usage Fault, i.e. Undef Instruction, Illegal State Transition"                  } },
  { SvdTypes::CpuIrqNum::IRQ7         , { "SecureFault"       , "Secure Fault Handler"                                                           } },
  { SvdTypes::CpuIrqNum::IRQ8         , { "Reserved8"         , "Reserved - do not use"                                                          } },
  { SvdTypes::CpuIrqNum::IRQ9         , { "Reserved9"         , "Reserved - do not use"                                                          } },
  { SvdTypes::CpuIrqNum::IRQ10        , { "Reserved10"        , "Reserved - do not use"                                                          } },
  { SvdTypes::CpuIrqNum::IRQ11        , { "SVCall"            , "System Service Call via SVC instruction"                                        } },
  { SvdTypes::CpuIrqNum::IRQ12        , { "DebugMonitor"      , "Debug Monitor"                                                                  } },
  { SvdTypes::CpuIrqNum::IRQ13        , { "Reserved11"        , "Reserved - do not use"                                                          } },
  { SvdTypes::CpuIrqNum::IRQ14        , { "PendSV"            , "Pendable request for system service"                                            } },
  { SvdTypes::CpuIrqNum::IRQ15        , { "SysTick"           , "System Tick Timer"                                                              } },
  { SvdTypes::CpuIrqNum::IRQ_RESERVED , { "Reserved"          , "Reserved - do not use"                                                          } },
"""


const
  patCpuFeatures = re"""SvdTypes::CpuType::(\w+)\s*,\s*\{"(\w+)"\s*,\s*"([^"]+)"(?:\s*,\s*(\d+))*\s*\}"""
  patIrqData = re"""SvdTypes::CpuIrqNum::IRQ(\d+)\s*,\s*\{\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\}"""

type
  CpuIrq = object
    id: int
    name: string
    description: string

  CpuFeatures = object
    name: string
    description: string
    featureFlags: array[28, bool]


proc parseCpus: seq[CpuFeatures] =
  var
    m: RegexMatch
    cpuf: CpuFeatures
  for ln in cpuDataString.strip.splitLines:
    doAssert ln.find(patCpuFeatures, m)
    cpuf.name = m.group(0, ln)[0]
    cpuf.description = m.group(2, ln)[0]
    for i in cpuf.featureFlags.low .. cpuf.featureFlags.high:
      cpuf.featureFlags[i] = m.group(3, ln)[i].parseInt > 0
    result.add cpuf

proc parseIrqs: Table[int, CpuIrq] =
  var
    m: RegexMatch
    irq: CpuIrq
  for ln in interruptDataString.strip.splitLines:
    if ln.find(patIrqData, m):
      irq.id = m.group(0, ln)[0].parseInt
      irq.name = m.group(1, ln)[0]
      irq.description = m.group(2, ln)[0]
      result[irq.id] = irq

let
  allIrqs = parseIrqs()
  allCpus = parseCpus()

echo """ # This module was auto-generated by cpu_interrupts.nim
import std/tables

type
  CpuIrq* = object
    id: int
    name: string
    description: string

"""

echo "type CpuIrqN* = enum"
for irqId in toSeq(allIrqs.keys).sorted:
  let irq = allIrqs[irqId]
  echo fmt"  irq{irq.name} = {irq.id - 16}"

echo "\nconst CpuIrqTable*: Table[string, set[CpuIrqN]] = {"
for cpuf in allCpus:
  var cpuIrqs: seq[string]
  for (i, flag) in cpuf.featureFlags.pairs:
    if flag and i <= 15:
      cpuIrqs.add "irq" & allIrqs[i].name

  echo fmt"""  "{cpuf.name}": {{{cpuIrqs.join(", ")}}},"""
echo "}.toTable"

echo "\nconst CpuIrqArray*: array[CpuIrqN, CpuIrq] = ["
for irqId in toSeq(allIrqs.keys).sorted:
  let irq = allIrqs[irqId]
  echo fmt"""  irq{irq.name}: CpuIrq(id: {16 - irq.id}, name: "{irq.name}", description: "{irq.description}"),"""
echo "]"
echo ""
