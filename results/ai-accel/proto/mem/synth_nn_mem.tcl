# ============================================================================
# synth_nn_mem.tcl -- nn_mem v0.7 resource/mapping proof (Vivado 2018.3)
# ----------------------------------------------------------------------------
# ASCII only (project rule).
# Usage:
#   vivado -mode batch -source synth_nn_mem.tcl \
#          -tclargs <top> <w_a> <w_b> <w_c> <w_d> <q_packed> <out_prefix>
#   <top>       : proto_nn_mem_v07 (verilog top in nn_mem_synth_top.sv)
#   <w_a..w_d>  : W 4 ??? 128-bit/??? hex (8192/4096/4096/4096 ???), ??? NN_W_INIT_A..D
#   <q_packed>  : Q 64-bit/??? hex (6144 ???), ??? NN_Q_INIT_FILE
#   <out_prefix>: output report prefix (in the current working directory)
# ============================================================================

set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize [file join $script_dir ".." ".." ".." ".."]]
set top        [lindex $argv 0]
set wq_a       [string map {\\ /} [lindex $argv 1]]
set wq_b       [string map {\\ /} [lindex $argv 2]]
set wq_c       [string map {\\ /} [lindex $argv 3]]
set wq_d       [string map {\\ /} [lindex $argv 4]]
set q_packed   [string map {\\ /} [lindex $argv 5]]
set out_prefix [string map {\\ /} [lindex $argv 6]]
set part       "xc7a100tfgg484-2"

puts "SYNTH_CFG top=$top part=$part"
puts "SYNTH_CFG w_a=$wq_a"
puts "SYNTH_CFG w_b=$wq_b"
puts "SYNTH_CFG w_c=$wq_c"
puts "SYNTH_CFG w_d=$wq_d"
puts "SYNTH_CFG q=$q_packed"
puts "SYNTH_CFG out=$out_prefix repo=$repo"

read_verilog -sv [file join $repo "nn_pkg.sv"]
read_verilog -sv [file join $repo "nn_mem.sv"]
read_verilog -sv [file join $script_dir "nn_mem_synth_top.sv"]

set set_defs [list \
    [format {NN_W_INIT_A="%s"} $wq_a] \
    [format {NN_W_INIT_B="%s"} $wq_b] \
    [format {NN_W_INIT_C="%s"} $wq_c] \
    [format {NN_W_INIT_D="%s"} $wq_d] \
    [format {NN_Q_INIT_FILE="%s"} $q_packed] ]
synth_design -top $top -part $part -verilog_define $set_defs

# 100 MHz (v0.7 ???????????????; AI ?????????????????????) -- ??????????????????????????????
create_clock -name sys_clk -period 10.000 [get_ports clk]

report_utilization -file "${out_prefix}_util.rpt"
if {[catch {report_utilization -hierarchical -file "${out_prefix}_util_hier.rpt"} hier_err]} {
    puts "SYNTH_WARN hierarchical utilization failed: $hier_err"
}
report_timing_summary -file "${out_prefix}_timing.rpt"
report_timing -max_paths 20 -input_pins -file "${out_prefix}_paths.rpt"

# ---- ??????????????? BRAM36 / BRAM18 ----
set b36 [get_cells -hierarchical -filter {REF_NAME =~ "RAMB36E1*"}]
set b18 [get_cells -hierarchical -filter {REF_NAME =~ "RAMB18E1*"}]
puts "SYNTH_BRAM36_TOTAL=[llength $b36]"
puts "SYNTH_BRAM18_TOTAL=[llength $b18]"

set n_w  0
set n_act 0
set n_other 0
foreach c $b36 {
    set nm [get_property NAME $c]
    # W ??? 4 ?????? A/B ?????????????????? nn_mem ???; ??? gen ?????????: ?????????????????????,
    # ?????????????????? report_utilization -hierarchical + RTL ?????????.
    if {[string match "*u_w*" $nm]} {
        incr n_w
    } elseif {[string match "*act_mem*" $nm]} {
        incr n_act
    } else {
        incr n_other
        puts "SYNTH_BRAM36_OTHER $nm"
    }
}
puts "SYNTH_BRAM36_ROUGH w_like=$n_w act_like=$n_act other=$n_other"

set lut [get_cells -hierarchical -filter {REF_NAME =~ "LUT*"}]
puts "SYNTH_LUT_CELLS=[llength $lut]"
set ff [get_cells -hierarchical -filter {REF_NAME =~ "FD*"}]
puts "SYNTH_FF_CELLS=[llength $ff]"

puts "SYNTH_DONE top=$top"
