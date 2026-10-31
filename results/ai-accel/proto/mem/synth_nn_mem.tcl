# ============================================================================
# synth_nn_mem.tcl -- nn_mem BRAM inference proof (Vivado 2018.3, non-project)
# ----------------------------------------------------------------------------
# ASCII only (project rule).
# Usage:
#   vivado -mode batch -source synth_nn_mem.tcl \
#          -tclargs <top> <wq_a> <wq_b> <wq_c> <wq_d|none> <out_prefix>
#   <top>       : proto_nn_mem_v03 | proto_nn_mem_v02
#   <wq_a.._d>  : split 32-bit-word hex images for nn_mem_wq's 4 sub-arrays
#                 (65536 / 16384 / 8192 / remainder lines; "none" skips D)
#   <out_prefix>: output report prefix (in the current working directory)
# ============================================================================

set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize [file join $script_dir ".." ".." ".." ".."]]
set top        [lindex $argv 0]
set wq_a       [string map {\\ /} [lindex $argv 1]]
set wq_b       [string map {\\ /} [lindex $argv 2]]
set wq_c       [string map {\\ /} [lindex $argv 3]]
set wq_d       [string map {\\ /} [lindex $argv 4]]
set out_prefix [string map {\\ /} [lindex $argv 5]]
set part       "xc7a100tfgg484-2"

puts "SYNTH_CFG top=$top part=$part"
puts "SYNTH_CFG wq_a=$wq_a"
puts "SYNTH_CFG wq_b=$wq_b"
puts "SYNTH_CFG wq_c=$wq_c"
puts "SYNTH_CFG wq_d=$wq_d"
puts "SYNTH_CFG out=$out_prefix repo=$repo"

read_verilog -sv [file join $repo "nn_pkg.sv"]
read_verilog -sv [file join $repo "nn_mem.sv"]
read_verilog -sv [file join $script_dir "nn_mem_synth_top.sv"]

set set_defs [list \
    [format {NN_WQ_INIT_A="%s"} $wq_a] \
    [format {NN_WQ_INIT_B="%s"} $wq_b] \
    [format {NN_WQ_INIT_C="%s"} $wq_c] ]
if {$wq_d ne "none"} {
    lappend set_defs [format {NN_WQ_INIT_D="%s"} $wq_d]
}
synth_design -top $top -part $part -verilog_define $set_defs

# 131.25 MHz (本仓库 AI 档目标频率) -- 仅综合后粗略时序估计, 无布局布线
create_clock -name sys_clk -period 7.619 [get_ports clk]

report_utilization -file "${out_prefix}_util.rpt"
if {[catch {report_utilization -hierarchical -file "${out_prefix}_util_hier.rpt"} hier_err]} {
    puts "SYNTH_WARN hierarchical utilization failed: $hier_err"
}
report_timing_summary -file "${out_prefix}_timing.rpt"
report_timing -max_paths 20 -input_pins -file "${out_prefix}_paths.rpt"

# ---- 逐单元统计 BRAM36 / BRAM18 并按层次归属 (nn_mem 的子模块名) ----
set b36 [get_cells -hierarchical -filter {REF_NAME =~ "RAMB36E1*"}]
set b18 [get_cells -hierarchical -filter {REF_NAME =~ "RAMB18E1*"}]
puts "SYNTH_BRAM36_TOTAL=[llength $b36]"
puts "SYNTH_BRAM18_TOTAL=[llength $b18]"

set n_wq 0
set n_a  0
set n_other 0
foreach c $b36 {
    set nm [get_property NAME $c]
    if {[string match "*u_wq*" $nm]} {
        incr n_wq
    } elseif {[string match "*u_act*" $nm]} {
        incr n_a
    } else {
        incr n_other
        puts "SYNTH_BRAM36_OTHER $nm"
    }
}
puts "SYNTH_BRAM36_BREAKDOWN WQ=$n_wq ACT=$n_a OTHER=$n_other"

set lut [get_cells -hierarchical -filter {REF_NAME =~ "LUT*"}]
puts "SYNTH_LUT_CELLS=[llength $lut]"
set ff [get_cells -hierarchical -filter {REF_NAME =~ "FD*"}]
puts "SYNTH_FF_CELLS=[llength $ff]"

puts "SYNTH_DONE top=$top"
