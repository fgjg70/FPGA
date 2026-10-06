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

read_verilog -sv [list "D:/USER/Desktop/FPGA/FPGA/rv32_pkg.sv" "D:/USER/Desktop/FPGA/FPGA/alu.sv" "D:/USER/Desktop/FPGA/FPGA/branch_unit.sv" "D:/USER/Desktop/FPGA/FPGA/control_unit.sv" "D:/USER/Desktop/FPGA/FPGA/imm_gen.sv" "D:/USER/Desktop/FPGA/FPGA/pc.sv" "D:/USER/Desktop/FPGA/FPGA/regfile.sv" "D:/USER/Desktop/FPGA/FPGA/if_id_reg.sv" "D:/USER/Desktop/FPGA/FPGA/id_ex_reg.sv" "D:/USER/Desktop/FPGA/FPGA/ex_mem_reg.sv" "D:/USER/Desktop/FPGA/FPGA/mem_wb_reg.sv" "D:/USER/Desktop/FPGA/FPGA/hazard_unit.sv" "D:/USER/Desktop/FPGA/FPGA/load_store_unit.sv" "D:/USER/Desktop/FPGA/FPGA/imem.sv" "D:/USER/Desktop/FPGA/FPGA/dmem.sv" "D:/USER/Desktop/FPGA/FPGA/btb.sv" "D:/USER/Desktop/FPGA/FPGA/ras.sv" "D:/USER/Desktop/FPGA/FPGA/muldiv.sv" "D:/USER/Desktop/FPGA/FPGA/csr_file.sv" "D:/USER/Desktop/FPGA/FPGA/core.sv" "D:/USER/Desktop/FPGA/FPGA/gemm_accel.sv" "D:/USER/Desktop/FPGA/FPGA/fpga/mmio_subsys.sv" "D:/USER/Desktop/FPGA/FPGA/fpga/top_a100t.sv"]
read_xdc "D:/USER/Desktop/FPGA/FPGA/fpga/daVinciPro.xdc"

# ===========================================================================
# 可选架构宏 —— 【三个默认全部关闭】
# ---------------------------------------------------------------------------
# 这三个曾被我默认打开过, 那是基于**无效实验**的判断, 现已推翻 (PITFALLS R17):
#   ModelSim 侧的宏传递写错了 (`vlog +FOO` 而非 `+define+FOO`), 所以
#   **这些宏在仿真里从来没生效过**; 而 Tcl 侧 (-verilog_define) 是生效的。
#   于是"综合开了宏、仿真没开宏", 两边跑的不是同一份设计 —— 综合出的数字是真的,
#   但"仿真 ticks 不变、零代价"是假的, 因为仿真跑的一直是**没开宏**的版本。
#
# 修好宏传递后实测 (verify --only tb_sw_coremark):
#   LOAD_RESULT_REG 单独开 -> 仿真 timeout (已否决, 见 results/p4-macro-failure.md 5.2)
#   BTB_GSHARE      单独开 -> 能跑, 但 ticks 449317, 比基线 423527 **慢 6%**
#   IMEM_REG_READ   2026-10-06 **已打通**: 全量回归 PASS 10 | XFAIL 1,
#                   且 CoreMark ticks 与组合读**逐位一致** (423527)
#
# 上板验证过的配置是**四个宏全关** (ILA 版 bitstream, 2026-10-05 16:43):
#   PASS, CRC 判定=1, tick=508,155,404, 10.16 s。
#
# 想再试验时: set IMEM_REG_READ=1 / set LOAD_REG=1 / set BTB_GSHARE=1
# **但必须先跑 `python tools/fpga_workflow.py verify` 确认仿真通过** 再综合。
# ===========================================================================
set IMEM_DEFS ""
if {[info exists ::env(IMEM_REG_READ)] && $::env(IMEM_REG_READ) ne ""} {
  # Registered read -> imem becomes inferable as RAMB36, freeing the ~1228 LUTs
  # (31% of the core) that the combinational LUT-ROM used to occupy.
  # [WORKING since 2026-10-06] The key is to drive the fetch address with the
  # COMBINATIONAL next-PC (pc_next): then imem_rdata(N) == mem[pc(N)], i.e. the
  # exact same pairing as the combinational read, so IF/ID needs no change and
  # the redirect penalty stays 2 cycles. Also freeze fetch for one cycle after
  # reset so IMEM gets a chance to latch PC_RESET.
  # See results/p4-macro-failure.md 5.1 and the pc_next comment in core.sv.
  append IMEM_DEFS " IMEM_REG_READ=1"
  puts "BUILD_IMEM_REG_READ=1"
} else {
  puts "BUILD_IMEM_COMB_READ=1"
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
#   而 CoreMark 不含原子指令 -> 收益为零。且多周期读写还没实现, 所以
#   即使打开也**执行不了** A 指令 (会按普通 load/store 走, 静默出错)。
#   要启用必须先完成多周期控制 (results/p6-a-extension.md 第 5 节)。
if {[info exists ::env(A_EN)] && $::env(A_EN) ne ""} {
  append IMEM_DEFS " A_EN=1"
  puts "BUILD_A_EN=1"
} else {
  puts "BUILD_A_OFF=1"
}

synth_design -top top_a100t -part $part -verilog_define "IMEM_INIT_FILE=\"$imem\" DMEM_INIT_FILE=\"$dmem\" $IMEM_DEFS"
puts "BUILD_PROG=$PROG"
opt_design
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore
report_timing_summary -file timing.rpt
report_utilization -file util.rpt
write_bitstream -force cpu_a100t.bit
puts "BUILD_OK"
