# ============================================================================
# synth_nn_mem_noclk.tcl -- nn_mem OOC synthesis, NO clock / NO XDC constraints
# ----------------------------------------------------------------------------
# ASCII only. 用法: vivado -mode batch -source synth_nn_mem_noclk.tcl
# 输出: results/ai-accel/impl/nn_mem_ooc/nn_mem_noclk.dcp
#
# 背景 (Lead 2026-11-01 20:0x): 80MHz 全实现 worst path = engine wa_r -> mem BRAM
# 地址 (7.972ns, route 7.539ns)。其中 Clock Path Skew = -3.526ns 来自 DCP 里
# `create_clock -name clk` 把 clk 定义成独立时钟, 链接后 STA 按 sys_clk_core -> clk
# 跨时钟分析。若 DCP 不带任何时钟约束, 整机用顶层 sys_clk_core 统一分析 ->
# 这 3.5ns 直接省掉 (预计 fmax 84.6 -> 115MHz+)。
#
# 要求: 同 RTL / 同 W/Q 初始化镜像 / 同参数 / -directive Default, **只去掉 create_clock**。
# 网表与带时钟版本等价; 整机时序由顶层重算, 不再需要周期变体 DCP。
# 本脚本不写周期/时序报告 (OOC 无时钟即未约束), 只报资源计数。
# ============================================================================
set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize [file join $script_dir ".." ".." ".." ".."]]
set split      [file normalize [file join $repo ".fpga-cache" "nn_wq_split"]]
set part       "xc7a100tfgg484-2"
set top        "nn_mem"

puts "NOCLK_CFG top=$top part=$part"
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

# 关键: 不 create_clock / 不 read_xdc / 不 set_input_delay / 不 set_output_delay
write_checkpoint -force [file join $script_dir "nn_mem_noclk.dcp"]
report_utilization -file [file join $script_dir "nn_mem_noclk_util.rpt"]

set n36   [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set n18   [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]
set nfdre [llength [get_cells -hier -filter {REF_NAME == FDRE}]]
set nclk  [llength [get_clocks -quiet]]
puts "NOCLK_CELLS RAMB36=$n36 RAMB18=$n18 FDRE=$nfdre CLOCKS=$nclk"
puts "NOCLK_DONE"
