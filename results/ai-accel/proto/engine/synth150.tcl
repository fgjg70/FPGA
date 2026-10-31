# ASCII only. OOC synthesis of nn_conv_engine + nn_mem at 150 MHz (6.667 ns).
#
# IMPORTANT (two traps found in T-accel-R2):
#   1) NN_WQ_INIT_A..D macros are REQUIRED. Without them nn_mem's initial loop
#      zeroes the 368KB WQ array and Vivado constant-folds the whole datapath
#      (~500 LUT, BRAM 0, FF 0). Macro values must be QUOTED strings and all
#      defines go in ONE space-separated string (a Tcl list would add braces).
#   2) The wrapper must expose datapath probes as output ports, otherwise the
#      "write back to nn_mem, no observable output" datapath is dead-code
#      eliminated (same collapse).
#
# Result files: synth150_util.rpt / synth150_timing.rpt / synth150_paths.rpt / synth150.log
set repo "D:/USER/Desktop/FPGA/FPGA"
set out  "D:/USER/Desktop/FPGA/FPGA/results/ai-accel/proto/engine"
set wq   "D:/USER/Desktop/FPGA/FPGA/.fpga-cache/nn_wq_split"

read_verilog [list \
  "$repo/nn_pkg.sv" \
  "$repo/nn_mem.sv" \
  "$repo/nn_conv_engine.sv" \
  "$out/timing_wrap.sv"]

set wqdefs "NN_WQ_INIT_A=\"$wq/wq_A.hex\" NN_WQ_INIT_B=\"$wq/wq_B.hex\" NN_WQ_INIT_C=\"$wq/wq_C.hex\" NN_WQ_INIT_D=\"$wq/wq_D.hex\""

synth_design -top nn_eng_timing_wrap -part xc7a100tfgg484-2 -mode out_of_context \
  -verilog_define $wqdefs

create_clock -period 6.667 -name clk [get_ports clk]
# desc/start come from nn_subsys registers -> 0.5ns input delay; judged paths are reg->reg
set_input_delay  -clock clk 0.500 [all_inputs]
set_output_delay -clock clk 0.500 [all_outputs]
set_false_path -from [get_ports rst]
set_false_path -to   [get_ports busy]
set_false_path -to   [get_ports done]
set_false_path -to   [get_ports {cycles[*]}]
set_false_path -to   [get_ports {err_code[*]}]

report_utilization -file "$out/synth150_util.rpt"
report_timing_summary -file "$out/synth150_timing.rpt" -max_paths 10 -delay_type max
report_timing -max_paths 20 -file "$out/synth150_paths.rpt"
puts "DBG_CELLS_FDRE=[llength [get_cells -hier -filter {REF_NAME == FDRE}]]"
puts "DBG_CELLS_RAMB36=[llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]"
puts "DBG_CELLS_DSP=[llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]"
puts "SYNTH150_DONE"
