# ASCII only. OOC synthesis of engine v3 (128 MAC) + REAL nn_mem v0.7 @125 MHz (8.0 ns).
#
# Two traps from T-accel-R2 still apply:
#   1) W/Q init macros required, or nn_mem constant-folds the 368KB arrays (BRAM 0, ~500 LUT).
#      Macro values are QUOTED strings; all defines in ONE space-separated Tcl string.
#   2) Wrapper must expose datapath probes as output ports (see timing_wrap_v3.sv).
set repo "D:/USER/Desktop/FPGA/FPGA"
set out  "D:/USER/Desktop/FPGA/FPGA/results/ai-accel/proto/engine"
set wq   "$out/wq_init"

read_verilog [list \
  "$repo/nn_pkg.sv" \
  "$repo/nn_mem.sv" \
  "$out/nn_conv_engine_v3.sv" \
  "$out/timing_wrap_v3.sv"]

set wqdefs "NN_W_INIT_A=\"$wq/w_A.hex\" NN_W_INIT_B=\"$wq/w_B.hex\" NN_W_INIT_C=\"$wq/w_C.hex\" NN_W_INIT_D=\"$wq/w_D.hex\" NN_Q_INIT_FILE=\"$wq/q_packed.hex\""

synth_design -top nn_eng_timing_wrap_v3 -part xc7a100tfgg484-2 -mode out_of_context \
  -verilog_define $wqdefs

create_clock -period 8.000 -name clk [get_ports clk]
set_input_delay  -clock clk 0.500 [all_inputs]
set_output_delay -clock clk 0.500 [all_outputs]
set_false_path -from [get_ports rst]
set_false_path -to   [get_ports busy]
set_false_path -to   [get_ports done]
set_false_path -to   [get_ports {cycles[*]}]
set_false_path -to   [get_ports {err_code[*]}]

report_utilization -file "$out/synth125_util.rpt"
report_timing_summary -file "$out/synth125_timing.rpt" -max_paths 10 -delay_type max
report_timing -max_paths 20 -file "$out/synth125_paths.rpt"
puts "DBG_CELLS_FDRE=[llength [get_cells -hier -filter {REF_NAME == FDRE}]]"
puts "DBG_CELLS_RAMB36=[llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]"
puts "DBG_CELLS_DSP=[llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]"
puts "SYNTH125_V3_DONE"
