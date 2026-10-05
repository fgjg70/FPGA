# 达芬奇Pro 上板构建 (非工程模式)
# 时序要点: 关键路径 = rs/rd -> hazard/前递 -> ALU -> 目标选择 -> pc
#   必须用 ExtraTimingOpt + AggressiveExplore (单靠 phys_opt 无效, 实测)。
set part xc7a100tfgg484-2
# PROG = 要综合进 imem/dmem 的程序镜像基名 (不含 .hex)。
# 默认 cm_hw = 跑分版 (评分要的就是它)。工具通过改写 "set PROG <name>" 换程序。
# 本核是哈佛结构, .data/.rodata 的初值靠 dmem 自己的镜像装入 (见 sw/link.ld),
# 所以**必须成对存在** <PROG>.hex 与 <PROG>.dmem.hex。
set PROG cm_hw
set root "D:/USER/Desktop/FPGA/FPGA"
set imem "$root/sim/prog/$PROG.hex"
set dmem "$root/sim/prog/$PROG.dmem.hex"
# 兜底: 指定的程序没有 dmem 镜像时退回跑分程序, 而不是让一个裸 `build.bat` 直接失败。
# (纯汇编程序如 basic.S 没有 .data/.rodata, 自然没有 .dmem.hex。)
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
read_verilog -sv [list "D:/USER/Desktop/FPGA/FPGA/rv32_pkg.sv" "D:/USER/Desktop/FPGA/FPGA/alu.sv" "D:/USER/Desktop/FPGA/FPGA/branch_unit.sv" "D:/USER/Desktop/FPGA/FPGA/control_unit.sv" "D:/USER/Desktop/FPGA/FPGA/imm_gen.sv" "D:/USER/Desktop/FPGA/FPGA/pc.sv" "D:/USER/Desktop/FPGA/FPGA/regfile.sv" "D:/USER/Desktop/FPGA/FPGA/if_id_reg.sv" "D:/USER/Desktop/FPGA/FPGA/id_ex_reg.sv" "D:/USER/Desktop/FPGA/FPGA/ex_mem_reg.sv" "D:/USER/Desktop/FPGA/FPGA/mem_wb_reg.sv" "D:/USER/Desktop/FPGA/FPGA/hazard_unit.sv" "D:/USER/Desktop/FPGA/FPGA/load_store_unit.sv" "D:/USER/Desktop/FPGA/FPGA/imem.sv" "D:/USER/Desktop/FPGA/FPGA/dmem.sv" "D:/USER/Desktop/FPGA/FPGA/btb.sv" "D:/USER/Desktop/FPGA/FPGA/muldiv.sv" "D:/USER/Desktop/FPGA/FPGA/csr_file.sv" "D:/USER/Desktop/FPGA/FPGA/core.sv" "D:/USER/Desktop/FPGA/FPGA/fpga/mmio_subsys.sv" "D:/USER/Desktop/FPGA/FPGA/fpga/top_a100t.sv"]
read_xdc "D:/USER/Desktop/FPGA/FPGA/fpga/daVinciPro.xdc"
# 路径一定要带引号, 否则宏展开成裸路径会在 '/' 上报 syntax error (Synth 8-2715),
# 而且报错行号会落在 $readmemh 那一行, 极具误导性。
# DMEM_INIT_FILE 必须给: 只给 IMEM 的话 .data/.rodata 全是 0。
synth_design -top top_a100t -part $part -verilog_define "IMEM_INIT_FILE=\"$imem\" DMEM_INIT_FILE=\"$dmem\""
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
