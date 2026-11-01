# ASCII only. FINAL OOC: engine v3 (pre/post E1) + nn_mem v0.7 @8ns/7ns (125/142.86MHz).
#
# usage: vivado -mode batch -source synth_final.tcl -tclargs <engine_sel> <period_ns> <out_prefix>
#   <engine_sel> : pre  -> proto/mem/engine_pre_e1.sv  (E1 ?????????, ????????? 2026-11-01 14:33 hash 820AA34E...)
#                  post -> repo root nn_conv_engine.sv (E1 ????????????????????????, ??? T-accel/Lead ??????)
#   <period_ns>  : 8.000 (125MHz) / 7.000 (142.86MHz) / 7.619 (131.25MHz)
#   <out_prefix> : report prefix (written to proto/mem/reports_final/)
#
# Notes:
#  - Traps (T-accel R2/R33): W/Q init macros REQUIRED; wrapper must expose datapath probes.
#  - Engine selection via file (both files define module nn_conv_engine; only ONE is read).
#  - nn_mem is root v0.7 (?????? B ?????????, ??? E1 ???????????????????????????).
set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize [file join $script_dir ".." ".." ".." ".."]]
set outdir     [file join $script_dir "reports_final"]
file mkdir $outdir

set engine_sel [lindex $argv 0]
set period     [lindex $argv 1]
set out_prefix [string map {\\ /} [lindex $argv 2]]
set mem_sel    "base"
if {[llength $argv] >= 4} { set mem_sel [lindex $argv 3] }
set wqdir      [string map {\\ /} [file join $script_dir "wq_init"]]

if {$engine_sel eq "pre"} {
    set engine_file [file join $script_dir "engine_pre_e1.sv"]
} elseif {$engine_sel eq "post"} {
    set engine_file [file join $repo "nn_conv_engine.sv"]
} else {
    puts "SYNTH_CFG ERROR: unknown engine_sel $engine_sel (pre|post)"
    exit 1
}
if {$mem_sel eq "base"} {
    set mem_file [file join $repo "nn_mem.sv"]
    set top      "nn_base_timing_wrap"
    set wrap     [file join $script_dir "timing_wrap_base.sv"]
} elseif {$mem_sel eq "B"} {
    set mem_file [file join $script_dir "nn_mem_piperd.sv"]
    set top      "nn_piperd_timing_wrap"
    set wrap     [file join $script_dir "timing_wrap_piperd.sv"]
} else {
    puts "SYNTH_CFG ERROR: unknown mem_sel $mem_sel (base|B)"
    exit 1
}
set wqdefs "NN_W_INIT_A=\"$wqdir/w_A.hex\" NN_W_INIT_B=\"$wqdir/w_B.hex\" NN_W_INIT_C=\"$wqdir/w_C.hex\" NN_W_INIT_D=\"$wqdir/w_D.hex\" NN_Q_INIT_FILE=\"$wqdir/q_packed.hex\""

puts "SYNTH_CFG engine=$engine_sel mem=$mem_sel period=$period out=$out_prefix"
read_verilog [list "$repo/nn_pkg.sv" "$mem_file" "$engine_file" "$wrap"]

synth_design -top $top -part xc7a100tfgg484-2 -mode out_of_context -verilog_define $wqdefs

create_clock -period $period -name clk [get_ports clk]
set_input_delay  -clock clk 0.500 [all_inputs]
set_output_delay -clock clk 0.500 [all_outputs]
set_false_path -from [get_ports rst]
set_false_path -to   [get_ports busy]
set_false_path -to   [get_ports done]
set_false_path -to   [get_ports {cycles[*]}]
set_false_path -to   [get_ports {err_code[*]}]

report_utilization -file "${outdir}/${out_prefix}_util.rpt"
report_timing_summary -file "${outdir}/${out_prefix}_timing.rpt" -max_paths 10 -delay_type max
report_timing -max_paths 20 -file "${outdir}/${out_prefix}_paths.rpt"
set nfdre  [llength [get_cells -hier -filter {REF_NAME == FDRE}]]
set nramb  [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set ndsp   [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
puts "SYNTH_FINAL engine=$engine_sel mem=$mem_sel PERIOD=$period FDRE=$nfdre RAMB36=$nramb DSP=$ndsp"
puts "SYNTH_FINAL_DONE_${out_prefix}"
