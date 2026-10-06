# ============================================================================
# fpga/build_ila.tcl — 带 ILA 的"上板自主读回"构建 (工程模式)
# ----------------------------------------------------------------------------
# 为什么用工程模式: ila IP 需要 Vivado 的 IP 生成流程, 工程模式最稳。
# 为什么需要 ILA: 本板串口收不到数据 (FT2232H 只有 D2XX, 无 COM 口), 只能靠
#   ILA over JTAG 把"是否跑完 + 跑了多少周期"读回来, 实现无人值守验证。
# 触发: 软件在 CoreMark 测量区间起点写 MMIO_MARK -> probe2[5] 上升沿。
# 注意: 正式评分构建 (build.tcl) 不带 ILA, CPU core 本身不含任何厂商 IP。
# ============================================================================
set part xc7a100tfgg484-2
set root "D:/USER/Desktop/FPGA/FPGA/"

create_project -force -part $part $root/fpga/ila_proj

# 文件列表必须写在一行: Tcl 的 backslash 续行在这里会被拆成多条命令
add_files -norecurse [list "D:/USER/Desktop/FPGA/FPGA/rv32_pkg.sv" "D:/USER/Desktop/FPGA/FPGA/alu.sv" "D:/USER/Desktop/FPGA/FPGA/branch_unit.sv" "D:/USER/Desktop/FPGA/FPGA/control_unit.sv" "D:/USER/Desktop/FPGA/FPGA/imm_gen.sv" "D:/USER/Desktop/FPGA/FPGA/pc.sv" "D:/USER/Desktop/FPGA/FPGA/regfile.sv" "D:/USER/Desktop/FPGA/FPGA/if_id_reg.sv" "D:/USER/Desktop/FPGA/FPGA/id_ex_reg.sv" "D:/USER/Desktop/FPGA/FPGA/ex_mem_reg.sv" "D:/USER/Desktop/FPGA/FPGA/mem_wb_reg.sv" "D:/USER/Desktop/FPGA/FPGA/hazard_unit.sv" "D:/USER/Desktop/FPGA/FPGA/load_store_unit.sv" "D:/USER/Desktop/FPGA/FPGA/imem.sv" "D:/USER/Desktop/FPGA/FPGA/dmem.sv" "D:/USER/Desktop/FPGA/FPGA/btb.sv" "D:/USER/Desktop/FPGA/FPGA/ras.sv" "D:/USER/Desktop/FPGA/FPGA/muldiv.sv" "D:/USER/Desktop/FPGA/FPGA/csr_file.sv" "D:/USER/Desktop/FPGA/FPGA/core.sv" "D:/USER/Desktop/FPGA/FPGA/gemm_accel.sv" "D:/USER/Desktop/FPGA/FPGA/fpga/mmio_subsys.sv" "D:/USER/Desktop/FPGA/FPGA/fpga/top_a100t.sv"]
add_files -fileset constrs_1 -norecurse [list "$root/fpga/daVinciPro.xdc"]

# dmem 必须带初值镜像: 本核是哈佛结构, .data/.rodata 无法靠 crt0 从 imem 搬
# 【必须给路径加引号】verilog_define 的值会原样展开成宏。不加引号的话
# `IMEM_INIT_FILE 会展开成裸路径, Vivado 在路径里的 '/' 上报
# "syntax error near /", 而且报的行号指向 $readmemh 那行, 极难联想去。
# Architecture macro pass-through. imem/dmem both use block RAM in the shipped
# configuration, so the DEFAULT here (no macro) is already the BRAM build.
# `IMEM_COMB_READ=1` is the fallback (combinational LUT ROM) for A-B compares.
# Without this gate "board-verified" could silently mean "verified WITHOUT the
# macro" (PITFALLS R18 -- that already produced a false PASS once).
set ARCH_DEFS ""
if {[info exists ::env(IMEM_COMB_READ)] && $::env(IMEM_COMB_READ) ne ""} {
  append ARCH_DEFS " IMEM_COMB_READ=1"
  puts "ILA_BUILD_IMEM_COMB_READ=1"
} else {
  puts "ILA_BUILD_IMEM_BRAM=1"
}
set_property verilog_define "USE_ILA=1 IMEM_INIT_FILE=\"$root/sim/prog/cm_hw.hex\" DMEM_INIT_FILE=\"$root/sim/prog/cm_hw.dmem.hex\"$ARCH_DEFS" [current_fileset]

create_ip -name ila -vendor xilinx.com -library ip -module_name ila_0
set_property -dict [list CONFIG.C_NUM_OF_PROBES {4} CONFIG.C_PROBE0_WIDTH {32} CONFIG.C_PROBE1_WIDTH {32} CONFIG.C_PROBE2_WIDTH {8} CONFIG.C_PROBE3_WIDTH {32} CONFIG.C_DATA_DEPTH {2048} CONFIG.C_INPUT_PIPE_STAGES {2}] [get_ips ila_0]

update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "SYNTH FAILED" }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} { error "IMPL FAILED" }
open_run impl_1
report_timing_summary -file $root/fpga/timing_ila.rpt
report_utilization   -file $root/fpga/util_ila.rpt
puts "ILA_BUILD_OK"
