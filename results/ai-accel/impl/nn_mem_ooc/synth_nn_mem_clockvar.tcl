# ============================================================================
# synth_nn_mem_clockvar.tcl -- nn_mem OOC synthesis, clock-period variant DCP
# ----------------------------------------------------------------------------
# ASCII only. 用法:
#   vivado -mode batch -source synth_nn_mem_clockvar.tcl -tclargs <period_ns> <tag>
# 例: -tclargs 10.000 10p000  ->  nn_mem_10p000.dcp (+ util/timing/paths reports)
#
# 同一 RTL / 同一初始化镜像 (W/Q split) / 仅 create_clock -period 不同;
# 供整机黑盒流程按频点选 DCP (Lead 2026-11-01 19:2x: 125MHz 全实现 post-place
# 预估 WNS -1.86 -> 降频保交付, 需 100/105/95.45/131.25/142.86MHz DCP)。
#
# 说明:
#   - 不覆盖 canonical nn_mem.dcp (8.0ns) —— 输出按 tag 命名;
#   - DCP 只含 create_clock, 不含 I/O delay (黑盒链接友好);
#     util/timing 报告为"报告用"临时加 0.5ns 虚拟 I/O, 不写入 DCP。
# ============================================================================
set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize [file join $script_dir ".." ".." ".." ".."]]
set split      [file normalize [file join $repo ".fpga-cache" "nn_wq_split"]]
set part       "xc7a100tfgg484-2"
set top        "nn_mem"

set period [lindex $argv 0]
set tag    [lindex $argv 1]
if {$period eq "" || $tag eq ""} {
    puts "CLKVAR ERROR: usage -tclargs <period_ns> <tag>"
    exit 1
}
set dcp [file join $script_dir "nn_mem_${tag}.dcp"]
puts "CLKVAR_CFG period=$period tag=$tag dcp=$dcp"

read_verilog -sv [file join $repo "nn_pkg.sv"]
read_verilog -sv [file join $repo "nn_mem.sv"]

set wqdefs [list \
    [format {NN_W_INIT_A="%s"} [file join $split "w_A.hex"]] \
    [format {NN_W_INIT_B="%s"} [file join $split "w_B.hex"]] \
    [format {NN_W_INIT_C="%s"} [file join $split "w_C.hex"]] \
    [format {NN_W_INIT_D="%s"} [file join $split "w_D.hex"]] \
    [format {NN_Q_INIT_LO="%s"} [file join $split "q_lo.hex"]] \
    [format {NN_Q_INIT_HI="%s"} [file join $split "q_hi.hex"]] ]

synth_design -top $top -part $part -mode out_of_context -directive Default -verilog_define $wqdefs
create_clock -name clk -period $period [get_ports clk]
write_checkpoint -force $dcp

# 报告用虚拟 I/O (不写入 DCP)
set_input_delay  -clock clk 0.500 [all_inputs]
set_output_delay -clock clk 0.500 [all_outputs]
report_utilization -file [file join $script_dir "nn_mem_${tag}_util.rpt"]
report_timing_summary -file [file join $script_dir "nn_mem_${tag}_timing.rpt"] -max_paths 10 -delay_type max
report_timing -max_paths 20 -file [file join $script_dir "nn_mem_${tag}_paths.rpt"]

set n36   [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set n18   [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]
set nfdre [llength [get_cells -hier -filter {REF_NAME == FDRE}]]
set clkp  [get_property PERIOD [get_clocks clk]]
puts "CLKVAR tag=$tag period=$clkp RAMB36=$n36 RAMB18=$n18 FDRE=$nfdre"
puts "CLKVAR_DONE_${tag}"
