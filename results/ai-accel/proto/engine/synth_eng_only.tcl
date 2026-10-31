# ASCII only. Debug: synth engine ONLY at 150MHz (no nn_mem) -> check it is not collapsed.
set repo "D:/USER/Desktop/FPGA/FPGA"
set out  "D:/USER/Desktop/FPGA/FPGA/results/ai-accel/proto/engine"
read_verilog [list "$repo/nn_pkg.sv" "$repo/nn_conv_engine.sv"]
synth_design -top nn_conv_engine -part xc7a100tfgg484-2 -mode out_of_context
create_clock -period 6.667 -name clk [get_ports clk]
set_false_path -from [get_ports rst]
report_utilization -file "$out/synth_eng_only_util.rpt"
report_timing -max_paths 10 -file "$out/synth_eng_only_paths.rpt"
puts "ENG_ONLY_DONE"
