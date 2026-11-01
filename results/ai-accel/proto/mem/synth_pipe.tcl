# ASCII only. OOC synthesis of engine v3 + nn_mem variant for ??????A (act write pipeline) proof.
#
# usage: vivado -mode batch -source synth_pipe.tcl -tclargs <variant> <period_ns> <out_prefix>
#   <variant>   : base | pipe   (base = root nn_mem.sv; pipe = proto/mem/nn_mem_pipe.sv)
#   <period_ns> : clock period, e.g. 10.000 / 8.000 / 6.667
#   <out_prefix>: report prefix (written to proto/mem/reports/)
#
# Traps (from T-accel R2/R33):
#   1) W/Q init macros REQUIRED, else nn_mem constant-folds the arrays (BRAM 0).
#      Macro values are QUOTED strings; all defines in ONE space-separated Tcl string.
#   2) Wrapper must expose datapath probes as output ports (see timing_wrap_*.sv).
set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize [file join $script_dir ".." ".." ".." ".."]]
set outdir     [file join $script_dir "reports"]
file mkdir $outdir

set variant    [lindex $argv 0]
set period     [lindex $argv 1]
set out_prefix [string map {\\ /} [lindex $argv 2]]
set wqdir      [string map {\\ /} [file join $script_dir "wq_init"]]

set mem_file ""
set top      ""
set wrap     ""
if {$variant eq "base"} {
    set mem_file [file join $repo "nn_mem.sv"]
    set top      "nn_base_timing_wrap"
    set wrap     [file join $script_dir "timing_wrap_base.sv"]
} elseif {$variant eq "pipe"} {
    set mem_file [file join $script_dir "nn_mem_pipe.sv"]
    set top      "nn_pipe_timing_wrap"
    set wrap     [file join $script_dir "timing_wrap_pipe.sv"]
} elseif {$variant eq "piperd"} {
    set mem_file [file join $script_dir "nn_mem_piperd.sv"]
    set top      "nn_piperd_timing_wrap"
    set wrap     [file join $script_dir "timing_wrap_piperd.sv"]
} elseif {$variant eq "pipeab"} {
    set mem_file [file join $script_dir "nn_mem_pipeab.sv"]
    set top      "nn_pipeab_timing_wrap"
    set wrap     [file join $script_dir "timing_wrap_pipeab.sv"]
} else {
    puts "SYNTH_CFG ERROR: unknown variant $variant"
    exit 1
}

puts "SYNTH_CFG variant=$variant period=$period top=$top"
puts "SYNTH_CFG mem=$mem_file"
puts "SYNTH_CFG wqdir=$wqdir"

read_verilog [list \
  "$repo/nn_pkg.sv" \
  "$mem_file" \
  "$repo/nn_conv_engine.sv" \
  "$wrap"]

set wqdefs "NN_W_INIT_A=\"$wqdir/w_A.hex\" NN_W_INIT_B=\"$wqdir/w_B.hex\" NN_W_INIT_C=\"$wqdir/w_C.hex\" NN_W_INIT_D=\"$wqdir/w_D.hex\" NN_Q_INIT_FILE=\"$wqdir/q_packed.hex\""

synth_design -top $top -part xc7a100tfgg484-2 -mode out_of_context \
  -verilog_define $wqdefs

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
puts "SYNTH_VARIANT=$variant PERIOD=$period DTYPE_FDRE=$nfdre RAMB36=$nramb DSP=$ndsp"
puts "SYNTH_DONE_${out_prefix}"
