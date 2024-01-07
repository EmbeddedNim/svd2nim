import std/unittest
import ../utils/uncheckedenums

# A holey enum
type
  ADC_INPUTCTRL_MUXPOS* {.size: 4.} = enum
    muxPIN0 = 0x0
    muxPIN1 = 0x1
    muxPIN2 = 0x2
    muxPIN3 = 0x3
    muxPIN4 = 0x4
    muxPIN5 = 0x5
    muxPIN6 = 0x6
    muxPIN7 = 0x7
    muxPIN8 = 0x8
    muxPIN9 = 0x9
    muxPIN10 = 0xa
    muxPIN11 = 0xb
    muxPIN12 = 0xc
    muxPIN13 = 0xd
    muxPIN14 = 0xe
    muxPIN15 = 0xf
    muxPIN16 = 0x10
    muxPIN17 = 0x11
    muxPIN18 = 0x12
    muxPIN19 = 0x13
    muxTEMP = 0x18
    muxBANDGAP = 0x19
    muxSCALEDCOREVCC = 0x1a
    muxSCALEDIOVCC = 0x1b
    muxDAC = 0x1c

# Ordinal enum
type
  ADC_CTRLB_PRESCALER* {.size: 2.} = enum
    DIV4 = 0x0
    DIV8 = 0x1
    DIV16 = 0x2
    DIV32 = 0x3
    DIV64 = 0x4
    DIV128 = 0x5
    DIV256 = 0x6
    DIV512 = 0x7

let
  muxposInvalid = toUncheckedEnum[ADC_INPUTCTRL_MUXPOS](0x22)
  muxposValid = toUncheckedEnum[ADC_INPUTCTRL_MUXPOS](0x1a)
  prescInvalid = toUncheckedEnum[ADC_CTRLB_PRESCALER](0x10)
  prescValid = toUncheckedEnum[ADC_CTRLB_PRESCALER](0x2)

suite "Unchecked Enums":
  test "isValid":
    check:
      not muxposInvalid.isValid
      muxposValid.isValid
      not prescInvalid.isValid
      prescValid.isValid

  test "ord":
    check:
      muxposInvalid.ord == 0x22
      muxposValid.ord == 0x1a
      prescInvalid.ord == 0x10
      prescValid.ord == 0x2

  test "getUnchecked":
    check:
      typeof(muxposInvalid.getUnchecked) is ADC_INPUTCTRL_MUXPOS
      typeof(muxposValid.getUnchecked) is ADC_INPUTCTRL_MUXPOS
      muxposInvalid.getUnchecked.ord == 0x22
      muxposValid.getUnchecked.ord == 0x1a
      typeof(prescInvalid.getUnchecked) is ADC_CTRLB_PRESCALER
      typeof(prescValid.getUnchecked) is ADC_CTRLB_PRESCALER
      prescInvalid.getUnchecked.ord == 0x10
      prescValid.getUnchecked.ord == 0x2

  test "get":
    check:
      typeof(muxposValid.get) is ADC_INPUTCTRL_MUXPOS
      muxposValid.get.ord == 0x1a
      typeof(prescValid.get) is ADC_CTRLB_PRESCALER
      prescValid.get.ord == 0x2
      # Get for invalid values will raise a Defect

  test "equality":
    check:
      muxposValid == muxSCALEDCOREVCC
      muxposValid != muxPIN0
      prescValid == DIV16
      prescValid != DIV32
      muxposInvalid != muxSCALEDCOREVCC
      prescInvalid != DIV16
