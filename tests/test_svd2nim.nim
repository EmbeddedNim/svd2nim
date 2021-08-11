import unittest
import svd2nim

suite "general tests":

  test "sanitize identifiers":
    check:
      sanitizeIdent("PM_AHBMASK_DSU__Pos") == "PM_AHBMASK_DSU_Pos"
      sanitizeIdent("PM_AHBMASK_DSU_Pos_") == "PM_AHBMASK_DSU_Pos"
      sanitizeIdent("CORTEX_M0+") == "CORTEX_M0"