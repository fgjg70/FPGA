# ASCII only. Synthesize nn_conv_engine alone for resource estimation.
set repo "D:/USER/Desktop/FPGA/FPGA"
set out  "D:/USER/Desktop/FPGA/FPGA/results/ai-accel/proto/engine"

read_verilog [list "$repo/nn_pkg.sv" "$repo/nn_conv_engine.sv"]
synth_design -top nn_conv_engine -part xc7a100tfgg484-2 -mode out_of_context
report_utilization -file "$out/synth_engine_util.rpt"
report_timing_summary -file "$out/synth_engine_timing.rpt" -max_paths 5
puts "SYNTH_ENGINE_DONE"
