import strformat

type GCLK_CLKCTRL_Fields = object
  ID* {.bitsize:6.}: uint16
  RESERVED {.bitsize:2.}: uint16
  GEN* {.bitsize:4.}: uint16
  RESERVED1 {.bitsize:2.}: uint16
  CLKEN {.bitsize:1.}: uint16
  WRTLOCK {.bitsize:1.}: uint16

var clkctrl = GCLK_CLKCTRL_Fields(
  ID: 0x07,
  GEN: 0x4,
  CLKEN: 0,
  WRTLOCK: 1
)

echo clkctrl
echo fmt"{cast[uint16](clkctrl):#b}"

const
  id_pos = 0
  id_len = 6
  id_msk = ((1 shl id_len) - 1) shl id_pos

  gen_pos = 8
  gen_len = 4
  gen_msk = ((1 shl gen_len) - 1) shl gen_pos

  clken_pos = 14
  clken_len = 1
  clken_msk = ((1 shl clken_len) - 1) shl clken_pos

  wrtlock_pos = 15
  wrtlock_len = 1
  wrtlock_msk = ((1 shl wrtlock_len) - 1) shl wrtlock_pos

let clkctrl_val = cast[uint16](clkctrl)
doAssert (clkctrl_val and id_msk) shr id_pos == 7
doAssert (clkctrl_val and gen_msk) shr gen_pos == 4
doAssert (clkctrl_val and clken_msk) shr clken_pos == 0
doAssert (clkctrl_val and wrtlock_msk) shr wrtlock_pos == 1

echo "OK"

clkctrl.GEN = 0x2
doAssert (cast[uint16](clkctrl) and gen_msk) shr gen_pos == 2

echo "OK"

let clk2 = cast[GCLK_CLKCTRL_Fields](clkctrl_val)
doAssert clk2.ID == 7
doAssert clk2.GEN == 4
doAssert clk2.CLKEN == 0
doAssert clk2.WRTLOCK == 1
echo "OK"

type GCLK_CLKCTRL_ID* {.pure.} = enum
  DFLL48 = 0x0,
  FDPLL = 0x1,
  FDPLL32K = 0x2,
  WDT = 0x3,
  RTC = 0x4,
  EIC = 0x5,
  USB = 0x6,
  EVSYS_0 = 0x7,
  EVSYS_1 = 0x8,
  EVSYS_2 = 0x9,
  EVSYS_3 = 0xa,
  EVSYS_4 = 0xb,
  EVSYS_5 = 0xc,
  EVSYS_6 = 0xd,
  EVSYS_7 = 0xe,
  EVSYS_8 = 0xf,
  EVSYS_9 = 0x10,
  EVSYS_10 = 0x11,
  EVSYS_11 = 0x12,
  SERCOMX_SLOW = 0x13,
  SERCOM0_CORE = 0x14,
  SERCOM1_CORE = 0x15,
  SERCOM2_CORE = 0x16,
  SERCOM3_CORE = 0x17,
  SERCOM4_CORE = 0x18,
  SERCOM5_CORE = 0x19,
  TCC0_TCC1 = 0x1a,
  TCC2_TC3 = 0x1b,
  TC4_TC5 = 0x1c,
  TC6_TC7 = 0x1d,
  ADC = 0x1e,
  AC_DIG = 0x1f,
  AC_ANA = 0x20,
  DAC = 0x21,
  I2S_0 = 0x23,
  I2S_1 = 0x24,

type GCLK_CLKCTRL_Fields_en = object
  ID* {.bitsize:6.}: GCLK_CLKCTRL_ID
  RESERVED {.bitsize:2.}: uint16
  GEN* {.bitsize:4.}: uint16
  RESERVED1 {.bitsize:2.}: uint16
  CLKEN {.bitsize:1.}: bool
  WRTLOCK {.bitsize:1.}: bool

let clk3 = GCLK_CLKCTRL_Fields_en(
  ID: GCLK_CLKCTRL_ID.EVSYS_0,
  GEN: 4,
  CLKEN: false,
  WRTLOCK: true,
)

doAssert cast[uint16](clk3) == clkctrl_val
echo "enum OK"

# Cast invalid int to GCLK_CLKCTRL_ID
var a = 0x24
a.inc
#echo a in (GCLK_CLKCTRL_ID.low .. GCLK_CLKCTRL_ID.high)
echo GCLK_CLKCTRL_ID(a)