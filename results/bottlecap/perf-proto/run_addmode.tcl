# ASCII only. OOC for Step A add-mode probe (task-14 pre-green-light).
# usage: vivado -mode batch -source run_addmode.tcl -tclargs <tag> <period_ns> <top_module>
set out "D:/USER/Desktop/FPGA/FPGA/results/bottlecap/perf-proto"
set tag    [lindex $argv 0]
set period [lindex $argv 1]
set top    [lindex $argv 2]
puts "ADDMODE_RUN tag=$tag period=$period top=$top"
read_verilog -sv "$out/addmode_probe.sv"
synth_design -top $top -part xc7a100tfgg484-2 -mode out_of_context
create_clock -period $period -name clk [get_ports clk]
set_false_path -from [get_ports rst]
report_utilization -file "$out/addmode_${tag}_util.rpt"
report_timing -max_paths 5 -file "$out/addmode_${tag}_paths.rpt"
puts "ADDMODE_DONE tag=$tag"
