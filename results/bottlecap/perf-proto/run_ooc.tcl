# ASCII only. OOC synthesis for NPU MAC widening probe (task-12 item 5).
# usage: vivado -mode batch -source run_ooc.tcl -tclargs <tag> <period_ns> <PX> <LANE> <DSP_PX> <REQ_LANES>
set repo "D:/USER/Desktop/FPGA/FPGA"
set out  "$repo/results/bottlecap/perf-proto"
set tag     [lindex $argv 0]
set period  [lindex $argv 1]
set px      [lindex $argv 2]
set lane    [lindex $argv 3]
set dsp_px  [lindex $argv 4]
set reql    [lindex $argv 5]

puts "PROBE_RUN tag=$tag period=$period px=$px lane=$lane dsp_px=$dsp_px req_lanes=$reql"
puts "PROBE_SRC perf_probe.sv + probe_top.sv (results/bottlecap/perf-proto); clock script run_ooc.tcl"

read_verilog -sv [list "$out/perf_probe.sv" "$out/probe_top.sv"]
synth_design -top probe_top -part xc7a100tfgg484-2 -mode out_of_context \
  -verilog_define "PROBE_PX=$px PROBE_LANE=$lane PROBE_DSP_PX=$dsp_px PROBE_REQ_LANES=$reql"
create_clock -period $period -name clk [get_ports clk]
set_false_path -from [get_ports rst]

report_utilization -file "$out/ooc_${tag}_util.rpt"
report_timing -max_paths 5 -file "$out/ooc_${tag}_paths.rpt"
puts "PROBE_DONE tag=$tag"
