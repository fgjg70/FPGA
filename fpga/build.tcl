# 达芬奇Pro 上板构建 (非工程模式)
# 时序要点: 关键路径 = rs/rd -> hazard/前递 -> ALU -> 目标选择 -> pc
#   必须用 ExtraTimingOpt + AggressiveExplore (单靠 phys_opt 无效, 实测)。
set part xc7a100tfgg484-2
# PROG = 要综合进 imem/dmem 的程序镜像基名 (不含 .hex)。
# 默认 cm_hw = 跑分版 (评分要的就是它)。工具通过改写 "set PROG <name>" 换程序。
# 本核是哈佛结构, .data/.rodata 的初值靠 dmem 自己的镜像装入 (见 sw/link.ld),
# 所以**必须成对存在** <PROG>.hex 与 <PROG>.dmem.hex。
# 注意: 换 ITERATIONS 只改 dmem 镜像, imem 会逐字节相同 (见 PITFALLS R14) ——
# 所以要确认镜像对不对, **比对 .dmem.hex**。
set PROG cm_hw
set root "D:/USER/Desktop/FPGA/FPGA"
set imem "$root/sim/prog/$PROG.hex"
set dmem "$root/sim/prog/$PROG.dmem.hex"
# 兜底: 指定的程序没有 dmem 镜像时退回跑分程序, 而不是让一个裸 `build.bat` 直接失败。
if {![file exists $dmem] && [file exists "$root/sim/prog/cm_hw.dmem.hex"]} {
  puts "BUILD_WARN: $PROG.dmem.hex not found -> falling back to cm_hw"
  set PROG cm_hw
  set imem "$root/sim/prog/$PROG.hex"
  set dmem "$root/sim/prog/$PROG.dmem.hex"
}
# 两个镜像都存在才继续。缺 dmem 时**必须报错退出**, 不能静默继续:
# 那样 .data/.rodata 会全是 0, 程序跑挂但 bitstream 照样生成 —— 正是本项目
# 反复踩的"静默失败"形态 (PITFALLS R1)。
if {![file exists $imem]} {
  puts "BUILD_ERROR: missing imem image $imem"
  exit 1
}
if {![file exists $dmem]} {
  puts "BUILD_ERROR: missing dmem image $dmem"
  puts "BUILD_HINT: 该程序没有 .data/.rodata 初值 (纯汇编?) 或还没构建。"
  puts "BUILD_HINT: 跑分版请先 python tools/build_sw.py ... 生成 $PROG.dmem.hex"
  exit 1
}
puts "BUILD_IMEM=$imem"
puts "BUILD_DMEM=$dmem"

read_verilog -sv [list "D:/USER/Desktop/FPGA/FPGA/rv32_pkg.sv" "D:/USER/Desktop/FPGA/FPGA/alu.sv" "D:/USER/Desktop/FPGA/FPGA/branch_unit.sv" "D:/USER/Desktop/FPGA/FPGA/control_unit.sv" "D:/USER/Desktop/FPGA/FPGA/imm_gen.sv" "D:/USER/Desktop/FPGA/FPGA/pc.sv" "D:/USER/Desktop/FPGA/FPGA/regfile.sv" "D:/USER/Desktop/FPGA/FPGA/id_ex_reg.sv" "D:/USER/Desktop/FPGA/FPGA/ex_mem_reg.sv" "D:/USER/Desktop/FPGA/FPGA/mem_wb_reg.sv" "D:/USER/Desktop/FPGA/FPGA/hazard_unit.sv" "D:/USER/Desktop/FPGA/FPGA/load_store_unit.sv" "D:/USER/Desktop/FPGA/FPGA/imem.sv" "D:/USER/Desktop/FPGA/FPGA/dmem.sv" "D:/USER/Desktop/FPGA/FPGA/btb.sv" "D:/USER/Desktop/FPGA/FPGA/ras.sv" "D:/USER/Desktop/FPGA/FPGA/muldiv.sv" "D:/USER/Desktop/FPGA/FPGA/csr_file.sv" "D:/USER/Desktop/FPGA/FPGA/core.sv" "D:/USER/Desktop/FPGA/FPGA/gemm_accel.sv" "D:/USER/Desktop/FPGA/FPGA/fpga/mmio_subsys.sv" "D:/USER/Desktop/FPGA/FPGA/fpga/top_a100t.sv"]
read_xdc "D:/USER/Desktop/FPGA/FPGA/fpga/daVinciPro.xdc"

# ===========================================================================
# 架构宏
# ---------------------------------------------------------------------------
# 【imem/dmem 都用 BRAM —— 这是默认配置, 不是可选项】
#   imem: 默认寄存读 -> RAMB36 x4 (组合读会摊成 1228 LUT = 全核 31%, 见下)
#   dmem: `always @(posedge clk) rdata <= mem[...]` -> RAMB36 x4
#   即上述 RAMB36 x4 + x4 = **8 块**, 这是当前交付配置。
#
# 【历史: 三个宏曾默认打开是基于无效实验, 已推翻 (PITFALLS R17)】
#   ModelSim 侧的宏传递写错了 (`vlog +FOO` 而非 `+define+FOO`), 所以
#   **那些宏在仿真里从来没生效过**; 而 Tcl 侧 (-verilog_define) 是生效的。
#   于是"综合开了宏、仿真没开宏", 两边跑的不是同一份设计。
#
# 修好宏传递后实测:
#   IMEM_REG_READ   2026-10-06 **已打通并转为默认**: 全量回归 PASS 11,
#                   CoreMark ticks 与组合读**逐位一致** (423527), 已上板验证
#   LOAD_RESULT_REG 单独开 -> 仿真 timeout (已否决, 见 results/p4-macro-failure.md 5.2)
#   BTB_GSHARE      单独开 -> 能跑, 但 ticks 449317, 比基线 423527 **慢 6%**
#
# 上板验证过的默认配置 (2026-10-06 18:05):
#   PASS, CRC 判定=1, tick=508,155,404, 10.16 s。
#
# 想再试验时: set LOAD_REG=1 / set BTB_GSHARE=1 / set A_EN=1 / set GEMM_EN=1
# **但必须先跑 `python tools/fpga_workflow.py verify` 确认仿真通过** 再综合。
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
# RAS_EN: 返回地址栈。【默认关闭】实测有效但不划算:
#   CoreMark/MHz +0.38% (JALR 误判 4378->3558), 但 fmax -2.8%
#   (栈顶 mux 落在已经最紧的 pc_target 路径上), 绝对吞吐 -2.3%。
#   见 results/p4-ras.md
if {[info exists ::env(RAS_EN)] && $::env(RAS_EN) ne ""} {
  append IMEM_DEFS " RAS_EN=1"
  puts "BUILD_RAS_EN=1"
} else {
  puts "BUILD_RAS_OFF=1"
}
# A_EN: RV32A 原子指令译码。【默认关闭】实测它是**纯代价**:
#   fmax 61.7 -> 58.8 MHz (-4.7%), LUT +26, 绝对吞吐 145.6 -> 138.9 (-4.6%);
#   而 CoreMark 不含原子指令 -> 收益为零。
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

synth_design -top top_a100t -part $part {*}$RETIM_OPT -verilog_define "IMEM_INIT_FILE=\"$imem\" DMEM_INIT_FILE=\"$dmem\" $IMEM_DEFS"
puts "BUILD_PROG=$PROG"

# ---- Pblock (physical optimization) -- ON BY DEFAULT for this part ---------
# Measured motivation: the datapath gets placed in CLOCKREGION_X1Y0 while the
# memory BRAMs land in CLOCKREGION_X0Y0 -- crossing that boundary made the last
# hop into u_imem/ADDRARDADDR cost 1.93ns by itself.
# Measured (xc7a100tfgg484-2, same RTL, same WLDrivenBlockPlacement):
#   no Pblock                          -> 62.8 MHz, path 15.276ns (route 10.898)
#   CLOCKREGION_X1Y0:CLOCKREGION_X1Y3  -> 69.2 MHz, path 13.971ns (route  8.926) BEST
#   CLOCKREGION_X1Y0:CLOCKREGION_X1Y2  -> 66.9 MHz
#   CLOCKREGION_X1Y0:CLOCKREGION_X1Y1  -> 64.2 MHz
#   (X1Y0:X1Y3) + ExtraTimingOpt       -> 63.3 MHz
#   (X1Y0:X1Y3) + AltSpreadLogic_high  -> 63.3 MHz
# Tighter is NOT better: lost placement freedom outweighs the shorter spans.
# NOTE: the range is part-specific. For another device (or the 紫光同创 migration
# target) pass PBLOCK_RANGE=off, or a valid range for that device.
set PB_RANGE "CLOCKREGION_X1Y0:CLOCKREGION_X1Y3"
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

opt_design
# Place directive is overridable so physical-optimization experiments are
# reproducible from the workflow instead of hand-run Vivado.
# DEFAULT = WLDrivenBlockPlacement: measured better for the SHIPPED config
# (imem/dmem both block RAM) -- 58.9 MHz vs 58.4 for ExtraTimingOpt, same LUTs.
# ExtraTimingOpt is better for the combinational-ROM fallback, so pass
# PLACE_DIRECTIVE=ExtraTimingOpt when building that variant.
set PLACE_DIR "WLDrivenBlockPlacement"
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
place_design -directive $PLACE_DIR
phys_opt_design -directive AggressiveExplore
route_design -directive $ROUTE_DIR
phys_opt_design -directive AggressiveExplore
report_timing_summary -file timing.rpt
report_utilization -file util.rpt
write_bitstream -force cpu_a100t.bit
puts "BUILD_OK"
