# ============================================================================
# synth_nn_mem_ooc.tcl -- nn_mem OOC synthesis -> DCP for "black-box + OOC DCP"
# ----------------------------------------------------------------------------
# ASCII only (project rule). Run from any dir:
#   vivado -mode batch -source synth_nn_mem_ooc.tcl
#
# Purpose (Lead 2026-11-01 18:4x): in-context synthesis of the whole machine was
# stuck ~2.5h in Cross-Boundary/XDC/Timing-Opt because nn_mem W 320KB ROM was
# expanded to 5.2M unmapped registers. nn_mem maps cleanly in OOC (W80/Q12/AB32),
# so the whole-machine flow will link this DCP as a black box.
#
# Contract with whole-machine flow:
#   - top = nn_mem (single module, OOC)
#   - port list must stay EXACTLY as root nn_mem.sv (see nn_mem_ports.txt)
#   - W/Q init macros are the CURRENT root names:
#       NN_W_INIT_A..D (64-bit/line: 16384/8192/8192/8192 lines)
#       NN_Q_INIT_LO (64-bit/line: 4096 lines) + NN_Q_INIT_HI (64-bit/line: 2048 lines)
#       [Q synth = 2 ? BRAM ROM (4096+2048), ? 12 tiles; ? mem-report ?3.7]
#   - clock: create_clock -name clk -period 8.000 (125MHz); no I/O delays
#     (in-context timing is closed by the top-level flow; this DCP reports
#      internal reg-to-reg WNS only)
# Outputs (same dir):
#   nn_mem.dcp / util.rpt / timing.rpt / synth.log
# ============================================================================
set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize [file join $script_dir ".." ".." ".." ".."]]
set split      [file normalize [file join $repo ".fpga-cache" "nn_wq_split"]]
set part       "xc7a100tfgg484-2"
set period     8.000
set top        "nn_mem"

puts "OOC_CFG top=$top part=$part period=$period"
puts "OOC_CFG repo=$repo"
puts "OOC_CFG split=$split"

read_verilog -sv [file join $repo "nn_pkg.sv"]
read_verilog -sv [file join $repo "nn_mem.sv"]

set wqdefs [list \
    [format {NN_W_INIT_A="%s"} [file join $split "w_A.hex"]] \
    [format {NN_W_INIT_B="%s"} [file join $split "w_B.hex"]] \
    [format {NN_W_INIT_C="%s"} [file join $split "w_C.hex"]] \
    [format {NN_W_INIT_D="%s"} [file join $split "w_D.hex"]] \
    [format {NN_Q_INIT_LO="%s"} [file join $split "q_lo.hex"]] \
    [format {NN_Q_INIT_HI="%s"} [file join $split "q_hi.hex"]] ]
puts "OOC_DEFS $wqdefs"

synth_design -top $top -part $part -mode out_of_context -directive Default -verilog_define $wqdefs

create_clock -name clk -period $period [get_ports clk]

# DCP ?? (?? clk ??, ?? I/O delay -> ???????; ??????????)
write_checkpoint -force [file join $script_dir "nn_mem.dcp"]

# ???: ??? I/O delay (0.5ns) ???????? timing ?? (??? DCP)?
# ?????? @8ns ? OOC WNS ??; ??????????? I/O?
set_input_delay  -clock clk 0.500 [all_inputs]
set_output_delay -clock clk 0.500 [all_outputs]
report_utilization -file [file join $script_dir "util.rpt"]
report_timing_summary -file [file join $script_dir "timing.rpt"] -max_paths 10 -delay_type max
report_timing -max_paths 20 -file [file join $script_dir "paths.rpt"]

set n36  [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set n18  [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]
set nfdre [llength [get_cells -hier -filter {REF_NAME == FDRE}]]
set ndsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
puts "OOC_CELLS RAMB36=$n36 RAMB18=$n18 FDRE=$nfdre DSP=$ndsp"
puts "OOC_DONE"
