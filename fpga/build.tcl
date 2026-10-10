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
# [IMPORTANT INTERACTION] ExtraTimingOpt is only good TOGETHER WITH this region.
# Without a Pblock it is measurably worse (58.4 vs 58.9 MHz) and with the OLD
# region it was much worse (63.3 vs 69.2). Both knobs moved together here; the
# isolation runs are recorded in results/coremark.csv (tags rr2-*).
# Also note: ExtraTimingOpt COSTS logic depth (15 -> 18 levels, CARRY4=7) and buys
# route (9.013 -> 7.596ns). It also creates a 1-level near-critical path
# (u_id_ex/pc_reg[7] -> u_csr/mepc_reg[7], slack +0.084) -- still MET, but that is
# the endpoint to watch if the design grows.
#
# Tighter is NOT better: lost placement freedom outweighs the shorter spans.
# NOTE: the range is part-specific. For another device (or the migration target)
# pass PBLOCK_RANGE=off, or a valid range for that device.
set PB_RANGE "CLOCKREGION_X0Y1:CLOCKREGION_X2Y4"
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
place_design -directive $PLACE_DIR
phys_opt_design -directive AggressiveExplore
route_design -directive $ROUTE_DIR
phys_opt_design -directive AggressiveExplore
report_timing_summary -file timing.rpt
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
report_utilization -file util.rpt
# ===========================================================================
# QSPI BOOT IMAGE SUPPORT  (2026-10-09, flash 固化)
# ---------------------------------------------------------------------------
# Everything up to here builds a JTAG-loadable bitstream. A bitstream that the
# FPGA can also read back OUT OF THE QSPI FLASH AT POWER-UP additionally needs
# its configuration header to describe the flash interface, and that header is
# written by write_bitstream -- so the properties must be set BEFORE it.
#
# DEFAULT = NOTHING CHANGES (empty list -> no set_property, same output file).
# Set SPI_BOOT_X4=1 for the vendor-recommended x4 image. These are the exact
# primitives 正点原子 documents for this board in 《达芬奇Pro之FPGA开发指南 V2.2》
# §5.3.13 程序固化 (book p.239), quoted verbatim:
#     set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
#     set_property CONFIG_MODE SPIx4 [current_design]
#     set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
#     set_property CFGBVS VCCO [current_design]
#     set_property CONFIG_VOLTAGE 3.3 [current_design]
#     set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
# Their stated reason: "为了生成的bit流文件转换成固化文件后能够适用于4bit位宽
# SPI通信的Flash器件" (so the converted image suits a 4-bit-wide SPI flash).
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
puts "BUILD_BIT_NAME=$BIT_NAME"
write_bitstream -force $BIT_NAME
puts "BUILD_OK"
