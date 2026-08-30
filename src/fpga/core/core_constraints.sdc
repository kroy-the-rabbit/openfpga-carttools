#
# openFPGA-CartTools core constraints
#
# What the emulator's version of this file constrained is mostly gone: there
# is no SDRAM, no audio PLL and no save state bus left to constrain. What
# remains is the clock grouping and the cartridge connector.
#

# ============================================================
# Clock groups
#
# clk_sys (general[0]) and its 270 degree copy (general[1]) come from the same
# VCO and stay in one group. general[1] currently has no load, but it is still
# a PLL output and leaving it ungrouped would make it its own related domain.
#
# The two video clocks reach clk_sys only through video_adapter's framebuffer,
# which is a dual-clock RAM, so they are asynchronous to it and to each other
# for timing purposes.
# ============================================================

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase_inst|sys_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|mf_pllbase_inst|sys_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|sys_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|sys_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk }

derive_clock_uncertainty

# ============================================================
# Cartridge connector
#
# The cartridge bus is not a source-synchronous interface. gba_cart_bus holds
# each phase of a transaction for a counted number of clk_sys cycles, and the
# shortest of those counts is 2 cycles (ADDR_HOLD_CYCLES), with reads waiting
# 14 cycles before sampling. At 9.934 ns per cycle that is 139 ns of settling
# before data is captured, against a pin-to-register delay measured in single
# nanoseconds.
#
# So these paths are cut. That is a deliberate statement that timing closure
# on them is meaningless, not an admission that they fail: the margin comes
# from the wait states, and the wait states are the thing to change if a
# cartridge ever proves marginal. If the wait counts are ever reduced to the
# point where a few nanoseconds of pin delay matters, this cut becomes wrong
# and must be replaced with real input and output delays.
# ============================================================

set_false_path -from [get_ports {cart_tran_bank0[*] cart_tran_bank1[*] \
                                 cart_tran_bank2[*] cart_tran_bank3[*] \
                                 cart_tran_pin30 cart_tran_pin31}]
set_false_path -to   [get_ports {cart_tran_bank0[*] cart_tran_bank1[*] \
                                 cart_tran_bank2[*] cart_tran_bank3[*] \
                                 cart_tran_pin30 cart_tran_pin31 \
                                 cart_tran_bank0_dir cart_tran_bank1_dir \
                                 cart_tran_bank2_dir cart_tran_bank3_dir \
                                 cart_tran_pin30_dir cart_tran_pin31_dir \
                                 cart_pin30_pwroff_reset}]
