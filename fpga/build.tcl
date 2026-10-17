# Da Vinci Pro board build (non-project mode).
# Timing notes: the critical path is rs/rd -> hazard/forward -> ALU -> target
#   select -> pc. ExtraTimingOpt + AggressiveExplore is required (phys_opt
#   alone was measured to be ineffective).
# This file MUST stay PURE ASCII (PITFALLS R21: a non-ASCII byte in a Vivado
# .tcl can split a comment line into code and raise "invalid command name").
set part xc7a100tfgg484-2
# PROG = basename of the program image to bake into imem/dmem (no .hex).
# Default cm_hw = the benchmark build (what the score is measured on). The tool
# switches programs by rewriting this "set PROG <name>" line.
# This core is Harvard: .data/.rodata initial values are loaded by dmem's own
# image (see sw/link.ld), so <PROG>.hex and <PROG>.dmem.hex MUST exist as a pair.
# Note: changing ITERATIONS only changes the dmem image; imem stays byte-identical
# (PITFALLS R14) -- so to confirm the image is right, compare the .dmem.hex.
# PROG defaults to cm_hw; the workflow overrides it via an ENVIRONMENT VARIABLE
# (this file is never rewritten any more).
# Why the old patch/restore scheme was removed -- it caused a real incident:
#   the old code rewrote this one line with a regex and then wrote the WHOLE
#   original file back when the build finished. On 2026-10-11 build-repo added
#   `bht.sv` to the read_verilog list *during* a build, and that edit was
#   silently overwritten => the next synthesis failed with
#       ERROR: [Synth 8-439] module 'bht' not found
#   One ERROR line in a long log is easy to dismiss as a flake. Reading PROG
#   from the env keeps this file READ-ONLY during a build, so that whole class
#   of overwrite is structurally impossible.
# Self-check: build.tcl prints BUILD_PROG=$PROG and the workflow lists it in
# `expect`, so a missing env (or a build.tcl that ignores it) fails LOUDLY
# instead of silently building the wrong program.
# NOTE: this file must stay PURE ASCII (see the header rule above) -- keep new
#       comments ASCII. The 2026-10-11 style audit caught 8 non-ASCII lines here.
set PROG cm_hw
if {[info exists ::env(PROG)] && $::env(PROG) ne ""} { set PROG $::env(PROG) }
# ---- E-02: no hardcoded absolute paths -------------------------------------
# The repo root is derived from this script's own location, so the build works
# on another machine / directory / user name, and "$root" is the SINGLE source
# for every source and report path below (the old file repeated the literal
# path in both `set root` and `read_verilog`).
set root [file normalize [file join [file dirname [info script]] ..]]
puts "BUILD_ROOT=$root"
set imem "$root/sim/prog/$PROG.hex"
set dmem "$root/sim/prog/$PROG.dmem.hex"
# Fallback: if the requested program has no dmem image, fall back to the
# benchmark program instead of letting a bare `build.bat` fail.
if {![file exists $dmem] && [file exists "$root/sim/prog/cm_hw.dmem.hex"]} {
  puts "BUILD_WARN: $PROG.dmem.hex not found -> falling back to cm_hw"
  set PROG cm_hw
  set imem "$root/sim/prog/$PROG.hex"
  set dmem "$root/sim/prog/$PROG.dmem.hex"
}
# Continue only if BOTH images exist. A missing dmem MUST be a hard error, not a
# silent continue: .data/.rodata would then be all zero, the program would hang,
# but the bitstream would still be produced -- exactly the "silent failure"
# shape this project keeps hitting (PITFALLS R1).
if {![file exists $imem]} {
  puts "BUILD_ERROR: missing imem image $imem"
  exit 1
}
if {![file exists $dmem]} {
  puts "BUILD_ERROR: missing dmem image $dmem"
  puts "BUILD_HINT: this program has no .data/.rodata initial values (pure asm?) or was never built."
  puts "BUILD_HINT: for the benchmark image run: python tools/mk_cm_hw.py 3000  (writes $PROG.hex + $PROG.dmem.hex)"
  exit 1
}
puts "BUILD_IMEM=$imem"
puts "BUILD_DMEM=$dmem"

# ===========================================================================
# Shared helpers (pure Tcl 8.5 -- Vivado 2018.3 ships Tcl 8.5.14).
# ===========================================================================
# Flat-JSON reader: {"key": scalar, ...} with no nesting and no escapes.
# Returns a dict; a missing/unreadable file returns an empty dict so callers
# can fall back to their constants and warn (never a silent wrong number).
proc br_read_flat_json {path} {
  set d [dict create]
  if {![file exists $path]} { return $d }
  if {[catch {set fh [open $path r]} e]} {
    puts "BR_JSON_WARN: cannot open $path : $e"
    return $d
  }
  set txt [read $fh]
  close $fh
  foreach {_full k v} [regexp -all -inline {"([A-Za-z_][A-Za-z0-9_]*)"\s*:\s*("[^"]*"|-?[0-9]+(?:\.[0-9]+)?)} $txt] {
    dict set d $k [string trim $v "\""]
  }
  return $d
}

# ---- X-06 / X-09: hard timing-closure gate --------------------------------
# Returns 1 when the implementation is closed, 0 otherwise. NEVER silent: it
# always prints <TAG>_TIMING_* lines. The verdict is Vivado's own summary line
# ("All user specified timing constraints are met." / "... are not met.")
# cross-checked against the numeric worst setup/hold slack reported by
# get_timing_paths. An unparseable report FAILS CLOSED (PITFALLS R1: a
# "looks normal" number is worse than a failed build).
proc br_timing_gate {rpt tag} {
  set met "NA"
  if {[file exists $rpt]} {
    if {[catch {set fh [open $rpt r]} e]} {
      puts "${tag}_TIMING_WARN=open_failed:$e"
    } else {
      set txt [read $fh]
      close $fh
      if {[string first "All user specified timing constraints are met." $txt] >= 0} {
        set met 1
      } elseif {[string first "Timing constraints are not met." $txt] >= 0} {
        set met 0
      }
    }
  } else {
    puts "${tag}_TIMING_WARN=report_missing:$rpt"
  }
  set wns "NA"
  set whs "NA"
  if {[catch {
    set p [get_timing_paths -setup -max_paths 1 -nworst 1 -quiet]
    if {[llength $p] > 0} { set wns [get_property SLACK [lindex $p 0]] }
  } e]} { puts "${tag}_TIMING_WARN=wns_query_failed:$e" }
  if {[catch {
    set p [get_timing_paths -hold -max_paths 1 -nworst 1 -quiet]
    if {[llength $p] > 0} { set whs [get_property SLACK [lindex $p 0]] }
  } e]} { puts "${tag}_TIMING_WARN=whs_query_failed:$e" }
  puts "${tag}_TIMING_CONSTRAINTS_MET=$met"
  puts "${tag}_TIMING_WNS=$wns"
  puts "${tag}_TIMING_WHS=$whs"
  set ok 1
  if {$met ne "1"} { set ok 0 }
  if {$wns ne "NA"} {
    if {[catch {set wv [expr {double($wns)}]} e]} {
      puts "${tag}_TIMING_WARN=wns_unparsed:$wns"
    } elseif {$wv < 0.0} { set ok 0 }
  }
  if {$whs ne "NA"} {
    if {[catch {set hv [expr {double($whs)}]} e]} {
      puts "${tag}_TIMING_WARN=whs_unparsed:$whs"
    } elseif {$hv < 0.0} { set ok 0 }
  }
  return $ok
}

read_verilog -sv [list "$root/rv32_pkg.sv" "$root/alu.sv" "$root/branch_unit.sv" "$root/control_unit.sv" "$root/imm_gen.sv" "$root/pc.sv" "$root/regfile.sv" "$root/id_ex_reg.sv" "$root/ex_mem_reg.sv" "$root/mem_wb_reg.sv" "$root/hazard_unit.sv" "$root/load_store_unit.sv" "$root/imem.sv" "$root/dmem.sv" "$root/btb.sv" "$root/bht.sv" "$root/ras.sv" "$root/muldiv.sv" "$root/csr_file.sv" "$root/core.sv" "$root/gemm_accel.sv" "$root/fpga/mmio_subsys.sv" "$root/fpga/top_a100t.sv"]
read_xdc "$root/fpga/daVinciPro.xdc"

# ===========================================================================
# Architecture macros
# ---------------------------------------------------------------------------
# [imem/dmem both use BRAM -- this is the default configuration, not an option]
#   imem: registered read by default -> RAMB36 x4 (a combinational read spreads
#         into 1228 LUTs = 31% of the whole core, see below)
#   dmem: `always @(posedge clk) rdata <= mem[...]` -> RAMB36 x4
#   i.e. RAMB36 x4 + x4 = **8 blocks**: this is the shipped configuration.
#
# [History: three macros used to default ON based on an invalid experiment,
#  since disproved (PITFALLS R17)]
#   The ModelSim-side macro passing was wrong (`vlog +FOO` instead of
#   `+define+FOO`), so **those macros never took effect in simulation**; the Tcl
#   side (-verilog_define) did take effect. So "macros on in synth, off in sim"
#   meant the two flows were not building the same design.
#
# Measured after fixing macro passing:
#   IMEM_REG_READ   2026-10-06 **proven and made the default**: full regression
#                   PASS 11, CoreMark ticks **bit-identical** to the
#                   combinational read (423527), board-verified
#   LOAD_RESULT_REG alone -> simulation timeout (rejected, see
#                   results/p4-macro-failure.md 5.2)
#   BTB_GSHARE      alone -> runs, but ticks 449317, i.e. **6% slower** than the
#                   423527 baseline
#
# Board-verified default configuration (2026-10-06 18:05):
#   PASS, CRC verdict=1, tick=508,155,404, 10.16 s.
#
# To experiment again: set LOAD_REG=1 / set BTB_GSHARE=1 / set A_EN=1 /
# set GEMM_EN=1 -- **but first run `python tools/fpga_workflow.py verify`**.
# ===========================================================================
set IMEM_DEFS ""
# IMEM read style. **DEFAULT = REGISTERED READ (inferable as RAMB36)**.
# Both imem and dmem are block RAM in the shipped configuration.
#   (unset)           -> registered read -> RAMB36 x4, frees ~1228 LUTs (31%)
#   IMEM_COMB_READ=1  -> combinational read -> LUT ROM (fallback / A-B compare)
# The registered read costs ZERO cycles: core.sv drives the fetch address with the
# COMBINATIONAL next-PC (pc_next), so imem_rdata(N) == mem[pc(N)] -- the exact same
# pairing as the combinational read. IF/ID needs no change, the redirect penalty
# stays 2 cycles, and CoreMark ticks are bit-identical (423527). The only extra is
# freezing fetch for one cycle after reset so IMEM can latch PC_RESET.
# See results/p4-macro-failure.md 5.1 and the pc_next comment in core.sv.
if {[info exists ::env(IMEM_COMB_READ)] && $::env(IMEM_COMB_READ) ne ""} {
  append IMEM_DEFS " IMEM_COMB_READ=1"
  puts "BUILD_IMEM_COMB_READ=1"
} else {
  puts "BUILD_IMEM_BRAM=1"
}
if {[info exists ::env(LOAD_REG)] && $::env(LOAD_REG) ne ""} {
  append IMEM_DEFS " LOAD_RESULT_REG=1"
  puts "BUILD_LOAD_RESULT_REG=1"
} else {
  puts "BUILD_LOAD_COMB=1"
}
if {[info exists ::env(BTB_GSHARE)] && $::env(BTB_GSHARE) ne ""} {
  append IMEM_DEFS " BTB_GSHARE=1"
  puts "BUILD_BTB_GSHARE=1"
} else {
  puts "BUILD_BTB_SMITH=1"
}
# RAS_EN: return-address stack. [OFF by default] Measured to work but not worth
#   it: CoreMark/MHz +0.38% (JALR mispredicts 4378->3558), but fmax -2.8% (the
#   stack-top mux lands on the already tightest pc_target path), absolute
#   throughput -2.3%. See results/p4-ras.md
if {[info exists ::env(RAS_EN)] && $::env(RAS_EN) ne ""} {
  append IMEM_DEFS " RAS_EN=1"
  puts "BUILD_RAS_EN=1"
} else {
  puts "BUILD_RAS_OFF=1"
}
# A_EN: RV32A atomic-instruction decode. [OFF by default] Measured to be pure
#   cost: fmax 61.7 -> 58.8 MHz (-4.7%), LUT +26, absolute throughput
#   145.6 -> 138.9 (-4.6%); CoreMark contains no atomics -> zero gain.
#   [2026-10-06] The multi-cycle read-modify-write is now WORKING (tb_core_amo
#   flipped from XFAIL to PASS), so A instructions really execute when enabled.
#   The three scoring metrics still gain nothing, so it stays OFF by default.
#   See results/p6-a-extension.md 5.13.
if {[info exists ::env(A_EN)] && $::env(A_EN) ne ""} {
  append IMEM_DEFS " A_EN=1"
  puts "BUILD_A_EN=1"
} else {
  puts "BUILD_A_OFF=1"
}
# GEMM_EN: NEURAL-NET ACCELERATOR. Default OFF -- the buffers infer as FLOP
# arrays (FF 1387 -> 14097, +916%) and the C read-back is unfinished.
# See results/p5-ai-accelerator.md.
if {[info exists ::env(GEMM_EN)] && $::env(GEMM_EN) ne ""} {
  append IMEM_DEFS " GEMM_EN=1"
  puts "BUILD_GEMM_EN=1"
} else {
  puts "BUILD_GEMM_OFF=1"
}

# ---- X-09: single source of truth for the run parameters ------------------
# tools/mk_cm_hw.py writes sim/prog/<PROG>.build.json with the ITERATIONS baked
# into the image, the expected hardware tick count, the capture wait time and
# the real clock frequency. Synthesis itself does not need those numbers, but
# printing them puts "which image / how many iterations is in this bitstream"
# into the build log (the evidence R41 asks for). Missing manifest -> warn and
# continue with the values unknown (NEVER guess).
set BUILD_JSON "$root/sim/prog/$PROG.build.json"
set JINFO [br_read_flat_json $BUILD_JSON]
if {[dict size $JINFO] == 0} {
  puts "BUILD_WARN: no build manifest $BUILD_JSON (regenerate with tools/mk_cm_hw.py) -> iterations/expect_tick unknown"
  puts "BUILD_JSON=absent"
} else {
  foreach k {prog iterations expect_tick wait_seconds clk_hz} {
    if {[dict exists $JINFO $k]} {
      puts "BUILD_JSON_[string toupper $k]=[dict get $JINFO $k]"
    }
  }
  if {[dict exists $JINFO prog] && [dict get $JINFO prog] ne $PROG} {
    puts "BUILD_JSON_WARN=manifest prog=[dict get $JINFO prog] but PROG=$PROG"
  }
  puts "BUILD_JSON=present"
}

# ---------------------------------------------------------------- retiming --
# Vivado register retiming: automatically MOVES flip-flops across combinational
# logic to balance stages. It is a formal equivalence transform, so cycle
# behaviour -- and therefore CoreMark ticks -- must NOT change; if ticks move,
# treat that as a red flag and drop it.
# Note: it cannot move logic across a BRAM's internal DO register, so it will not
# by itself decouple the dmem->EX chain; it can only rebalance the EX/branch/
# redirect tail. RETIMING=1 enables it. OFF by default (not yet a measured win).
set RETIM_OPT ""
if {[info exists ::env(RETIMING)] && $::env(RETIMING) ne ""} {
  set RETIM_OPT "-retiming"
  puts "BUILD_RETIMING=1"
} else {
  puts "BUILD_RETIMING_OFF=1"
}

# ---- synthesis directive + resource_sharing (first swept 2026-10-11) ---------
# RVCoreP-32IM (arXiv 2010.16171 sec. IV.A) ships the synthesis strategy
# "Flow_PerfOptimized_high". I first assumed that meant -directive
# PerformanceOptimized -- **WRONG for Vivado 2018.3**. `synth_design -help`
# lists exactly these values (verified 2026-10-11 by running it):
#     default, RuntimeOptimized, AreaOptimized_high, AreaOptimized_medium,
#     AlternateRoutability, AreaMapLargeShiftRegToBRAM, AreaMultThresholdDSP,
#     FewerCarryChains
# `PerformanceOptimized` is NOT among them -> Vivado aborts immediately with
#   ERROR: [Common 17-161] Invalid option value 'performanceoptimized'
# (and the workflow then reported the PREVIOUS build's numbers for 4 s -- see
#  the build-failure hole that was also fixed that day).
# Their main.xpr stores `<Option Id="Directive">7</Option>` for synth_1; by the
# enumeration above index 7 is **FewerCarryChains** -- physically plausible for a
# ROUTE-bound design (67% route) whose critical path contains CARRY4s, because
# FPGA carry chains force long horizontal routing.
# Also newly exposed here: -resource_sharing. ref5's V4 used
# `-resource_sharing off` as part of a +9.16 MHz batch, but this core never had
# the knob at all (it was not in any build script).
# ---- DEFAULT = AlternateRoutability (measured 2026-10-11, post-C11 netlist) ----
# Why this is the default rather than Vivado's "default":
#   post-C11 netlist (fmax 92.6, route-dominated F->F wall):
#     Vivado default          92.6
#     AlternateRoutability    97.2   <-- +5.0%, chosen
#     FewerCarryChains        89.8   <-- worse
#     phys_opt Explore        92.6   <-- no change on this netlist (was +1.7 on the old one)
#   NOTE: a directive that wins on one netlist can invert on another (C-12a measured
#   +0.76% under the default directive but -5.3% under AlternateRoutability), so this
#   default must be re-measured after every structural RTL change.
set SYNTH_DIR "AlternateRoutability"
if {[info exists ::env(SYNTH_DIRECTIVE)] && $::env(SYNTH_DIRECTIVE) ne ""} {
  set SYNTH_DIR $::env(SYNTH_DIRECTIVE)
}
lappend SYNTH_OPT -directive $SYNTH_DIR
puts "BUILD_SYNTH_DIRECTIVE=$SYNTH_DIR"
if {[info exists ::env(RESOURCE_SHARING)] && $::env(RESOURCE_SHARING) ne ""} {
  lappend SYNTH_OPT -resource_sharing $::env(RESOURCE_SHARING)
  puts "BUILD_RESOURCE_SHARING=$::env(RESOURCE_SHARING)"
} else {
  puts "BUILD_RESOURCE_SHARING_OFF=1"
}
# ---- 【RVCoreP 的生产配方: Flow_PerfOptimized_high, 整套搬到非工程流】 --------
# 2026-10-13 从他们的 main.xpr 里抄出**完整选项组** —— 此前我们只搬了 `-directive`
# (AlternateRoutability), 这一整套**从未测过**, 是"我们为什么慢"的头号待验证假设。
#   synth_1 的 Run Description 原文:
#     "Higher performance designs, resource sharing is turned off, the global fanout
#      guide is set to a lower number, FSM extraction forced to one-hot, LUT combining
#      is disabled, equivalent registers are preserved, SRL are inferred with a larger
#      threshold"
#   XPR Strategy 选项: ResourceSharing=2(off) / RepFanoutThreshold=400 /
#     FsmExtraction=one_hot / NoCombineLuts=1 / KeepEquivalentRegisters=1 / ShregMinSize=5
#   逐条对应 synth_design 的参数:
#     -resource_sharing off -fanout_limit 400 -fsm_extraction one_hot
#     -no_lc -keep_equivalent_registers -shreg_min_size 5
# 注意: `-fanout_limit` 就是我们反复看到的 fo=93/128/252 那些网的"全局扇出指导"。
if {[info exists ::env(SYNTH_RECIPE)] && $::env(SYNTH_RECIPE) eq "perf_high"} {
  lappend SYNTH_OPT -resource_sharing off -fanout_limit 400 \
                    -fsm_extraction one_hot -no_lc -keep_equivalent_registers \
                    -shreg_min_size 5
  puts "BUILD_SYNTH_RECIPE=perf_high"
} else {
  puts "BUILD_SYNTH_RECIPE_OFF=1"
}
# ---- 【单选项实验: -no_lc / -fanout_limit (2026-10-13 150 战役)】 --------------------
# step1 逐跳: top-1 的两跳高扇出布线(fo=121/122)占 2.147ns, 且 hop2/hop3 落在 C-10 的
# `fwd_b_pre` => 怀疑综合器把"译码 LUT"与"前递预选 LUT"**合并**(LUT combining)了, 使本该
# 是"寄存器->寄存器"的短路径变成"从 imem 指令字出发的 5 级锥"。
# 对症药两条: `-no_lc`(禁 LUT 合并) 与 `-fanout_limit`(降全局扇出指导, 让工具复制高扇出驱动器)。
# ⚠ 我们只测过**整套** Flow_PerfOptimized_high(=-1.621 更差); 这两个**单独**从未测过。
if {[info exists ::env(SYNTH_NO_LC)] && $::env(SYNTH_NO_LC) eq "1"} {
  lappend SYNTH_OPT -no_lc
  puts "BUILD_SYNTH_NO_LC=1"
} else {
  puts "BUILD_SYNTH_NO_LC_OFF=1"
}
if {[info exists ::env(SYNTH_FANOUT_LIMIT)] && $::env(SYNTH_FANOUT_LIMIT) ne ""} {
  lappend SYNTH_OPT -fanout_limit $::env(SYNTH_FANOUT_LIMIT)
  puts "BUILD_SYNTH_FANOUT_LIMIT=$::env(SYNTH_FANOUT_LIMIT)"
} else {
  puts "BUILD_SYNTH_FANOUT_LIMIT_OFF=1"
}
synth_design -top top_a100t -part $part {*}$RETIM_OPT {*}$SYNTH_OPT -verilog_define "IMEM_INIT_FILE=\"$imem\" DMEM_INIT_FILE=\"$dmem\" $IMEM_DEFS"
puts "BUILD_PROG=$PROG"

# ---- Pblock (physical optimization) -- ON BY DEFAULT for this part ---------
# Measured motivation: the datapath gets placed in CLOCKREGION_X1Y0 while the
# memory BRAMs land in CLOCKREGION_X0Y0 -- crossing that boundary made the last
# hop into u_imem/ADDRARDADDR cost 1.93ns by itself.
#
# [2026-10-11 RR2 round] The critical path is a dmem->LSU->forward->branch->PC->
# imem WALL: all 50 worst setup paths share one source (u_dmem/mem_reg_*/CLKBWRCLK)
# and one destination family (u_imem/rdata_reg_*/ADDRARDADDR), and it is 60-70%
# ROUTE. A read-only placement probe (reproduced by .rr2_scratch/rr2_probe.tcl)
# showed WHY: dmem's 4 BRAMs sit at column X1, while ALL the logic (lsu X52..64,
# mem_wb X52..67, id_ex X52..81) parks ~50 columns to the right -- the placer
# minimises total HPWL and does not care about the one net that matters. The two
# worst hops (dmem->LSU 0.81ns, and a shifter-intermediate hop 1.04ns) are PURE
# WIRE at fo 3~4, i.e. pure physical length.
#
# Measured at the 70MHz constraint (compile fmax = 1000/(14.285714 - WNS)):
#   CLOCKREGION_X1Y0:CLOCKREGION_X1Y3  WLDrivenBlockPlacement -> WNS +0.694  (73.57) [old default]
#   CLOCKREGION_X0Y1:CLOCKREGION_X2Y4  WLDrivenBlockPlacement -> WNS +0.669  (73.44)
#   CLOCKREGION_X0Y1:CLOCKREGION_X3Y6  WLDrivenBlockPlacement -> WNS +0.669  (73.44)
#   CLOCKREGION_X0Y2:CLOCKREGION_X2Y5  WLDrivenBlockPlacement -> WNS +0.797  (74.14)
#   CLOCKREGION_X0Y3:CLOCKREGION_X2Y6  WLDrivenBlockPlacement -> WNS +0.774  (74.01)
#   CLOCKREGION_X0Y2:CLOCKREGION_X2Y4  ExtraTimingOpt          -> WNS +0.797  (74.14)
#   CLOCKREGION_X0Y1:CLOCKREGION_X3Y4  ExtraTimingOpt          -> WNS +0.819  (74.26)
#   CLOCKREGION_X0Y2:CLOCKREGION_X4Y4  ExtraTimingOpt          -> WNS +0.819  (74.26)
#   CLOCKREGION_X0Y1:CLOCKREGION_X2Y4  ExtraTimingOpt          -> WNS +0.888  (74.64) BEST, 3/3 bit-identical
#   (stacking the byte-lane load mux of load_store_unit.sv on top: with the OLD
#    barrel shifter the same best cell only reaches +0.852 -- the two changes are
#    super-additive: -0.311ns logic from the byte-lane mux, -0.209ns route from
#    the region, net +0.194ns / +1.07MHz.)
#
# [2026-10-11 RE-SWEEP ON THE NEW NETLIST] The table above was measured BEFORE the
# R-01 / R48 / R-02 / W-04 fixes (+69 LUT / +17 FF), so it was re-measured: same flow,
# 11 points (results/coremark.csv rows pb3-*, status=measure). Verdict: THE OPTIMUM
# DID NOT MOVE -- this pairing is still co-optimal.
#   ExtraTimingOpt + X0Y1:X2Y4 / X2Y5 / X3Y4 / X3Y5 -> WNS +0.854 (74.45)  4-WAY TIE
#   ExtraTimingOpt + X0Y2:X4Y4 or X0Y2:X3Y5         -> WNS +0.616 (73.2)
#   ExtraTimingOpt + X0Y3:X3Y6                      -> WNS +0.326 (71.6)
#   WLDrivenBlockPlacement (3 ranges)               -> WNS +0.698..+0.716 (73.6..73.7)
#   off (no Pblock) + ExtraTimingOpt                -> WNS +0.484 (72.5)
#     ^ control: Pblock+ExtraTimingOpt is worth +1.9 MHz over no Pblock, so the knob
#       matters -- it is simply already at its optimum.
#   WHY (measured, not assumed): the four tying ranges give IDENTICAL WNS, and ALL 50
#   worst setup paths share ONE source (u_core/u_dmem/mem_reg_3/CLKBWRCLK), are ~67%
#   route, with delta(top1, top2) = 0.024 ns => the wall is intrinsic to the netlist
#   topology (dmem BRAM -> LSU -> forward -> branch -> PC -> imem address), NOT to the
#   placed region. THIS AXIS IS EXHAUSTED; do not re-sweep it (PITFALLS R47).
#   Rank bottlenecks with `python tools/path_hotspot.py fpga/timing_paths.rpt --top N`
#   -- note fpga/timing.rpt holds only the single worst path (50 paths live in
#   fpga/timing_paths.rpt, which is now archived per build too).
#
# [IMPORTANT INTERACTION] ExtraTimingOpt is only good TOGETHER WITH this region.
# Without a Pblock it is measurably worse (58.4 vs 58.9 MHz) and with the OLD
# region it was much worse (63.3 vs 69.2). Both knobs moved together here; the
# isolation runs are recorded in results/coremark.csv (tags rr2-*).
# Also note: ExtraTimingOpt COSTS logic depth (15 -> 18 levels, CARRY4=7) and buys
# route (9.013 -> 7.596ns). It also creates a 1-level near-critical path
# (u_id_ex/pc_reg[7] -> u_csr/mepc_reg[7], slack +0.084) -- still MET, but that is
# the endpoint to watch if the design grows.
#   UPDATE 2026-10-11 (design DID grow, +69 LUT): re-checked -- "mepc" and "u_csr"
#   now appear ZERO times in the top-50 setup paths (all >= +0.854 slack, so that path
#   is now > +1.08 ns). This endpoint is RESOLVED; do not spend effort on it.
#
# Tighter is NOT better: lost placement freedom outweighs the shorter spans.
# NOTE: the range is part-specific. For another device (or the migration target)
# pass PBLOCK_RANGE=off, or a valid range for that device.
set PB_RANGE "CLOCKREGION_X0Y1:CLOCKREGION_X2Y2"
set PB_CELLS "u_core"
set PB_ON    1
if {[info exists ::env(PBLOCK_RANGE)] && $::env(PBLOCK_RANGE) ne ""} {
  if {$::env(PBLOCK_RANGE) eq "off"} { set PB_ON 0 } else { set PB_RANGE $::env(PBLOCK_RANGE) }
}
if {[info exists ::env(PBLOCK_CELLS)] && $::env(PBLOCK_CELLS) ne ""} {
  set PB_CELLS $::env(PBLOCK_CELLS)
}
if {$PB_ON} {
  create_pblock p_opt
  add_cells_to_pblock p_opt [get_cells -quiet $PB_CELLS]
  resize_pblock p_opt -add $PB_RANGE
  puts "BUILD_PBLOCK=$PB_CELLS @ $PB_RANGE"
  # CONTAIN_ROUTING: force the Pblock's nets to route INSIDE the region.
  # Purely physical (no RTL/functional effect). Try it when route dominates the
  # critical path but the region is still roomy.
  if {[info exists ::env(CONTAIN_ROUTING)] && $::env(CONTAIN_ROUTING) ne ""} {
    set_property CONTAIN_ROUTING 1 [get_pblocks p_opt]
    puts "BUILD_CONTAIN_ROUTING=1"
  } else {
    puts "BUILD_CONTAIN_ROUTING_OFF=1"
  }
} else {
  puts "BUILD_PBLOCK_OFF=1"
}

# ---- 【opt_design directive】2026-10-17: 150 档留余量 -----------------------
# 剩下的"软件侧重构"杠杆里唯一没用过的一个。
#   ExploreWithRemap : 重映射 LUT 网表(可能改变关键路径的 LUT 层级)
#   NoLUTCombining   : 关 LUT 合并(与 synth 的 -no_lc 呼应)
#   AggressiveExplore/Explore(运行时多重策略)
set OPT_DIR ""
if {[info exists ::env(OPT_DIRECTIVE)] && $::env(OPT_DIRECTIVE) ne ""} {
  set OPT_DIR $::env(OPT_DIRECTIVE)
}
if {$OPT_DIR eq ""} {
  opt_design
  puts "BUILD_OPT_DIRECTIVE_OFF=1"
} else {
  opt_design -directive $OPT_DIR
  puts "BUILD_OPT_DIRECTIVE=$OPT_DIR"
}
# Place directive is overridable so physical-optimization experiments are
# reproducible from the workflow instead of hand-run Vivado.
# DEFAULT = ExtraTimingOpt, CHOSEN TOGETHER WITH the Pblock above.
#   History: with the old Pblock X1Y0:X1Y3, WLDrivenBlockPlacement was better
#   (69.2 vs 63.3 for ExtraTimingOpt). With the RR2 region X0Y1:X2Y4 the verdict
#   FLIPS: ExtraTimingOpt buys a much shorter route on the dmem->imem wall
#   (9.013 -> 7.596ns) at the cost of logic depth (15 -> 18 levels), net
#   WNS +0.852 -> +0.888 (74.44 -> 74.64 MHz), 3/3 bit-identical.
#   => place directive and Pblock MUST be selected as a pair, never independently.
#   Pass PLACE_DIRECTIVE=WLDrivenBlockPlacement to get the earlier point back.
set PLACE_DIR "ExtraTimingOpt"
if {[info exists ::env(PLACE_DIRECTIVE)] && $::env(PLACE_DIRECTIVE) ne ""} {
  set PLACE_DIR $::env(PLACE_DIRECTIVE)
}
puts "BUILD_PLACE_DIRECTIVE=$PLACE_DIR"
# Route directive is overridable too. AggressiveExplore is the default;
# NoTimingRelaxation makes the router refuse to relax failed paths (worth trying
# when route dominates the critical path -- measured ~64-80% here).
set ROUTE_DIR "AggressiveExplore"
if {[info exists ::env(ROUTE_DIRECTIVE)] && $::env(ROUTE_DIRECTIVE) ne ""} {
  set ROUTE_DIR $::env(ROUTE_DIRECTIVE)
}
puts "BUILD_ROUTE_DIRECTIVE=$ROUTE_DIR"
# ---- phys_opt directive: was hardcoded AggressiveExplore twice. --------------
# Made overridable 2026-10-11 because RVCoreP-32IM's shipped project (arXiv
# 2010.16171 sec. IV.A) uses "Performance_ExplorePostRoutePhysOpt" for impl and
# "Flow_PerfOptimized_high" for synthesis, and we had never swept either knob.
# Both calls use the SAME directive on purpose (pre-place and post-route).
set PHYS_OPT_DIR "AggressiveExplore"
if {[info exists ::env(PHYS_OPT_DIRECTIVE)] && $::env(PHYS_OPT_DIRECTIVE) ne ""} {
  set PHYS_OPT_DIR $::env(PHYS_OPT_DIRECTIVE)
}
puts "BUILD_PHYS_OPT_DIRECTIVE=$PHYS_OPT_DIR"
place_design -directive $PLACE_DIR
phys_opt_design -directive $PHYS_OPT_DIR
route_design -directive $ROUTE_DIR
phys_opt_design -directive $PHYS_OPT_DIR
# Reports go to $root/fpga explicitly (NOT the current directory): the workflow
# reads fpga/timing.rpt and fpga/util.rpt, so the script must land there no
# matter where it was started from.
report_timing_summary -file $root/fpga/timing.rpt
# ---- EVIDENCE: fully expanded critical paths (per-hop net fanout) -----------
# report_timing_summary gives no per-hop `net (fo=NN)` detail, but this core is
# ROUTE-bound (PITFALLS R36) -> optimization targets must be picked by FANOUT,
# not by signal name (R37: max_fanout gains are position-specific; the same
# name did not replicate on this core). This line does NOT change the
# implementation; it only adds fpga/timing_paths.rpt for path analysis.
# Placed before write_bitstream so it reports the exact same netlist as
# timing.rpt. NOTE: keep this file pure ASCII (Vivado + check both care).
# `-nworst 50` was tried first and is WRONG here: with no -from/-to it made
# Vivado print the SAME worst path 50 times (measured 2026-10-08: 50 identical
# blocks) instead of 50 distinct paths. Dropping -nworst yields 50 distinct
# worst-slack paths, each fully expanded with per-hop `net (fo=NN)`.
report_timing -max_paths 50 -input_pins -file $root/fpga/timing_paths.rpt
report_utilization -file $root/fpga/util.rpt

# ===========================================================================
# X-06: TIMING-CLOSURE GATE -- must run BEFORE write_bitstream.
# ---------------------------------------------------------------------------
# Before this gate existed the flow only *reported* timing and then wrote a
# bitstream anyway: a build with WNS < 0 produced a "normal looking" fmax, got
# recorded as `keep`, and could even be programmed onto the board. A violating
# build is now a FAILED build: no bitstream is written, Vivado exits non-zero,
# and the harness sees BUILD_TIMING=FAIL.
# ===========================================================================
set TIMING_OK [br_timing_gate $root/fpga/timing.rpt BUILD]
if {!$TIMING_OK} {
  puts "BUILD_TIMING=FAIL"
  error "BUILD_TIMING=FAIL: timing constraints are NOT met -> refusing to write a bitstream"
}
puts "BUILD_TIMING=PASS"

# ===========================================================================
# QSPI BOOT IMAGE SUPPORT  (2026-10-09, flash programming)
# ---------------------------------------------------------------------------
# Everything up to here builds a JTAG-loadable bitstream. A bitstream that the
# FPGA can also read back OUT OF THE QSPI FLASH AT POWER-UP additionally needs
# its configuration header to describe the flash interface, and that header is
# written by write_bitstream -- so the properties must be set BEFORE it.
#
# DEFAULT = NOTHING CHANGES (empty list -> no set_property, same output file).
# Set SPI_BOOT_X4=1 for the vendor-recommended x4 image. These are the exact
# primitives the board vendor documents in the Da Vinci Pro FPGA development
# guide V2.2 section 5.3.13 "programming the flash" (book p.239), quoted
# verbatim:
#     set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
#     set_property CONFIG_MODE SPIx4 [current_design]
#     set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
#     set_property CFGBVS VCCO [current_design]
#     set_property CONFIG_VOLTAGE 3.3 [current_design]
#     set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
# Their stated reason: the converted image must suit a 4-bit-wide SPI flash.
#
# SPIBUSWIDTH is mandatory for the x4 image: write_cfgmem refuses to build an
# SPIx4 image from a bitstream whose header says 1 --
#   [Writecfgmem 68-20] SPI_BUSWIDTH property is set to "1" ... has to be "4".
# Each set_property is inside catch() so a name this Vivado build does not know
# can never break the normal build; the verify lines below print what stuck, and
# those lines are the evidence that the header really changed.
#
# BIT_NAME keeps the default artifact identical; variants go to their own file
# so the scoring bitstream is never silently overwritten.
# ===========================================================================
set SPI_BOOT_PROPS {}
if {[info exists ::env(SPI_BOOT_X4)] && $::env(SPI_BOOT_X4) ne ""} {
  set SPI_BOOT_PROPS [list \
    BITSTREAM.CONFIG.SPI_BUSWIDTH 4 \
    CONFIG_MODE                   SPIx4 \
    BITSTREAM.CONFIG.CONFIGRATE   50 \
    CFGBVS                        VCCO \
    CONFIG_VOLTAGE                3.3 \
    BITSTREAM.CONFIG.UNUSEDPIN    PULLUP ]
} elseif {[info exists ::env(SPI_BOOT)] && $::env(SPI_BOOT) ne ""} {
  set SPI_BOOT_PROPS [list BITSTREAM.CONFIG.SPI_BUSWIDTH $::env(SPI_BOOT)]
}
foreach {p v} $SPI_BOOT_PROPS {
  if {[catch {set_property $p $v [current_design]} e]} {
    puts "BUILD_SPIBOOT_FAIL: $p=$v -> $e"
  } else {
    puts "BUILD_SPIBOOT_SET: $p=$v"
  }
}
foreach p {BITSTREAM.CONFIG.SPI_BUSWIDTH BITSTREAM.CONFIG.CONFIGRATE \
           BITSTREAM.CONFIG.UNUSEDPIN CONFIG_MODE} {
  if {[catch {set x [get_property $p [current_design]]} e]} { set x "<n/a>" }
  puts "BUILD_SPIBOOT_VERIFY: $p=$x"
}
set BIT_NAME "cpu_a100t.bit"
if {[info exists ::env(BIT_NAME)] && $::env(BIT_NAME) ne ""} { set BIT_NAME $::env(BIT_NAME) }
# Keep BIT_NAME's meaning as a *name* (the harness records fpga/cpu_a100t.bit):
# only an explicitly absolute BIT_NAME is used verbatim.
if {[file pathtype $BIT_NAME] eq "absolute"} {
  set BIT_PATH $BIT_NAME
} else {
  set BIT_PATH "$root/fpga/$BIT_NAME"
}
puts "BUILD_BIT_NAME=$BIT_NAME"
puts "BUILD_BIT_PATH=$BIT_PATH"
write_bitstream -force $BIT_PATH
puts "BUILD_OK"
