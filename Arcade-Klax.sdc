derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# fx68k (68000, clk_sys domain, clock enables at clk_sys/8): the microcode
# and nanocode ROM addresses are decoded from IR but not consumed until the
# next CPU phase, so these paths get two clk_sys cycles (upstream fx68k.txt).
set fx68k_ir [get_keepers {*fx68k:u_fx68k|Ir[*]}]
set_multicycle_path -start -setup -from $fx68k_ir -to [get_keepers {*fx68k:u_fx68k|microAddr[*]}] 2
set_multicycle_path -start -hold  -from $fx68k_ir -to [get_keepers {*fx68k:u_fx68k|microAddr[*]}] 1
set_multicycle_path -start -setup -from $fx68k_ir -to [get_keepers {*fx68k:u_fx68k|nanoAddr[*]}] 2
set_multicycle_path -start -hold  -from $fx68k_ir -to [get_keepers {*fx68k:u_fx68k|nanoAddr[*]}] 1
