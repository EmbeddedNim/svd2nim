#[ Bindings for core_cm0plus.h

The header files in the CMSIS Core/Include directory needs to be available to
the C compiler as an include path, eg. via `--passC:-I./lib/CMSIS/Core/Include`

These files are not distributed here, rather they should be obtained from the
CMSIS_5 repository: https://github.com/ARM-software/CMSIS_5/tree/develop/CMSIS/Core/Include

For full documentation on the procs defined in this file, see the corresponding
functions in the core_cm0plus.h file:

https://github.com/ARM-software/CMSIS_5/blob/develop/CMSIS/Core/Include/core_cm0plus.h

Or in the CMSIS online docs:

https://arm-software.github.io/CMSIS_5/Core/html/modules.html

]#

import std/strformat

const headerStr = fmt"""
#define __CM0PLUS_REV              {CM0PLUS_REV:#06x}U
#define __NVIC_PRIO_BITS           {NVIC_PRIO_BITS}
#define __Vendor_SysTickConfig     {Vendor_SysTickConfig.int}
#define __VTOR_PRESENT             {VTOR_PRESENT.int}
#define __MPU_PRESENT              {MPU_PRESENT.int}

typedef enum {{
  Reset_IRQn             =  -15, // Reset Vector, invoked on Power up and warm reset
  NonMaskableInt_IRQn    =  -14, // Non maskable Interrupt, cannot be stopped or preempted
  HardFault_IRQn         =  -13, // Hard Fault, all classes of Fault
  SVCall_IRQn            =   -5, // System Service Call via SVC instruction
  PendSV_IRQn            =   -2, // Pendable request for system service
  SysTick_IRQn           =   -1 // System Tick Timer
}} IRQn_Type;

#include "core_cm0plus.h"
"""

# Nim bindings for core_cm0plus.h HAL functions

proc NVIC_EnableIRQ*(irqn: IRQn)
  {.importc: "__NVIC_EnableIRQ", header: headerStr.}

proc NVIC_GetEnableIRQ*(irqn: IRQn): uint32
  {.importc: "__NVIC_GetEnableIRQ", header: headerStr.}

proc NVIC_DisableIRQ*(irqn: IRQn)
  {.importc: "__NVIC_DisableIRQ", header: headerStr.}

proc NVIC_GetPendingIRQ*(irqn: IRQn): uint32
  {.importc: "__NVIC_GetPendingIRQ", header: headerStr.}

proc NVIC_SetPendingIRQ*(irqn: IRQn)
  {.importc: "__NVIC_SetPendingIRQ", header: headerStr.}

proc NVIC_ClearPendingIRQ*(irqn: IRQn)
  {.importc: "__NVIC_ClearPendingIRQ", header: headerStr.}

proc NVIC_SetPriority*(irqn: IRQn, priority: uint32)
  {.importc: "__NVIC_SetPriority", header: headerStr.}

proc NVIC_GetPriority*(irqn: IRQn): uint32
  {.importc: "__NVIC_GetPriority", header: headerStr.}

proc NVIC_EncodePriority*(priorityGroup, preemptPriority, subPriority: uint32): uint32
  {.importc: "NVIC_EncodePriority", header: headerStr.}

proc NVIC_DecodePriority_impl(priority, priorityGroup: uint32, pPremptPriority, pSubPriority: ptr uint32)
  {.importc: "NVIC_DecodePriority", header: headerStr.}

func NVIC_DecodePriority*(priority, priorityGroup: uint32): tuple[preemptPriority, subPriority: uint32] =
  ## Friendly wrapper around NVIC_DecodePriority that returns a tuple
  ## instead of taking pointers as arguments.
  NVIC_DecodePriority_impl(priority, priorityGroup, result.preemptPriority.addr, result.subPriority.addr)

proc NVIC_SetVector*(irqn: IRQn, vector: uint32)
  {.importc: "__NVIC_SetVector", header: headerStr.}

proc NVIC_GetVector*(irqn: IRQn): uint32
  {.importc: "__NVIC_GetVector", header: headerStr.}

proc NVIC_SystemReset*()
  {.importc: "__NVIC_SystemReset", header: headerStr.}

when not Vendor_SysTickConfig:
  proc SysTick_Config_impl(ticks: uint32): uint32
    # Note: returns 1 when failed, 0 when succeeded
    {.importc: "SysTick_Config", header: headerStr.}

  proc SysTick_Config*(ticks: 0..0x1000000): bool =
    not SysTick_Config_impl(uint32(ticks)).bool
