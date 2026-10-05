# hier_util.tcl — 按层次报告资源, 定位"某个模块被实现成了什么"
#
# 用途: 综合级的资源报告只给总数, 看不出某个数组是被推断成 BRAM、LUTRAM
#       还是纯 LUT 逻辑。这个脚本跑一遍综合 + report_utilization -hierarchical,
#       直接给出每个子模块的 LUT / FF / LUTRAM / BRAM / DSP。
#
# 典型用法(本项目实测过的问题):
#   imem.sv 是组合读, 结果被综合成 **1228 个纯 LUT 的 ROM**(既不进 BRAM 也不进
#   LUTRAM), 占全核 LUT 的 31%。只跑普通 report_utilization 完全看不出来 ——
#   Block RAM 表里只有 dmem, Distributed RAM 表里只有 btb/regfile, imem 在哪都没有,
#   必须按层次看才发现它是 1228 个 LUT。
#
# 跑法:
#   vivado -mode batch -nojournal -log hier_util.log -source tools/hier_util.tcl
#   注意: vivado 未加入 PATH, 需先 call settings64.bat; 且在会话 env 被剥离时
#   要显式 set PROCESSOR_ARCHITECTURE=AMD64, 否则报 "32-bit platform is not supported"
#
# 输出: fpga/hier_util.rpt

set root "D:/USER/Desktop/FPGA/FPGA"
read_verilog -sv [list "$root/rv32_pkg.sv" "$root/alu.sv" "$root/branch_unit.sv" "$root/control_unit.sv" "$root/imm_gen.sv" "$root/pc.sv" "$root/regfile.sv" "$root/if_id_reg.sv" "$root/id_ex_reg.sv" "$root/ex_mem_reg.sv" "$root/mem_wb_reg.sv" "$root/hazard_unit.sv" "$root/load_store_unit.sv" "$root/imem.sv" "$root/dmem.sv" "$root/btb.sv" "$root/muldiv.sv" "$root/csr_file.sv" "$root/core.sv" "$root/fpga/mmio_subsys.sv" "$root/fpga/top_a100t.sv"]
# 必须同时定义两个镜像, 否则整个数据通路会被常量折叠成几个 LUT
# (PITFALLS: "综合出 25 个 LUT" —— 实测把 imem 换成常量 NOP 后全核只剩 3 个 LUT)
synth_design -top top_a100t -part xc7a100tfgg484-2 -verilog_define "IMEM_INIT_FILE=\"$root/sim/prog/cm_hw.hex\" DMEM_INIT_FILE=\"$root/sim/prog/cm_hw.dmem.hex\""
report_utilization -hierarchical -hierarchical_depth 3 -file hier_util.rpt
puts "HIER_OK"
