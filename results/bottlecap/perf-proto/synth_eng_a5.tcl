# ASCII only. OOC synth of the real engine AFTER Step A (A1/A2/A4/A5), task-14.
# usage: vivado -mode batch -source synth_eng_a5.tcl -tclargs <period_ns> <tag>
set repo "D:/USER/Desktop/FPGA/FPGA"
set out  "D:/USER/Desktop/FPGA/FPGA/results/bottlecap/perf-proto"
set period [lindex $argv 0]
set tag    [lindex $argv 1]
puts "ENG_A5_SYNTH period=$period tag=$tag"
read_verilog -sv [list "$repo/nn_pkg.sv" "$repo/nn_rom_pkg.sv" "$repo/nn_conv_engine.sv"]
synth_design -top nn_conv_engine -part xc7a100tfgg484-2 -mode out_of_context
create_clock -period $period -name clk [get_ports clk]
set_false_path -from [get_ports rst]
report_utilization -file "$out/eng_a5_${tag}_util.rpt"
report_timing -max_paths 5 -file "$out/eng_a5_${tag}_paths.rpt"
puts "ENG_A5_DONE tag=$tag"
