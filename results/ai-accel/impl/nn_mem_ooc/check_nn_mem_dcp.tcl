# ============================================================================
# check_nn_mem_dcp.tcl -- re-open nn_mem OOC DCP and verify mapping (Lead check)
# ----------------------------------------------------------------------------
# ASCII only. Run: vivado -mode batch -source check_nn_mem_dcp.tcl
# Verifies from the DCP itself (not from the synth log):
#   - Block RAM Tile count (expect W80 + Q12 + A/B32 = 124)
#   - RAMB36/RAMB18 cell counts
#   - WNS @8ns clock (create_clock is already inside the DCP)
# Writes nn_mem_check.rpt (util) + nn_mem_check_timing.rpt.
# ============================================================================
set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem.dcp"]

# ????? I/O (??? DCP): DCP ???? clk ??
set_input_delay  -clock clk 0.500 [all_inputs]
set_output_delay -clock clk 0.500 [all_outputs]
report_utilization -file [file join $script_dir "nn_mem_check.rpt"]
report_timing_summary -file [file join $script_dir "nn_mem_check_timing.rpt"] -max_paths 10 -delay_type max

set n_wc  [llength [get_cells -hier -filter {REF_NAME == RAMB36E1 && NAME =~ *w_cur_*}]]
set n_wn  [llength [get_cells -hier -filter {REF_NAME == RAMB36E1 && NAME =~ *w_nxt_*}]]
set n_qq  [llength [get_cells -hier -filter {REF_NAME == RAMB36E1 && NAME =~ *q_mem_*}]]
set n_aa  [llength [get_cells -hier -filter {REF_NAME == RAMB36E1 && NAME =~ *act_mem_*}]]
puts "DCP_CHECK_SPLIT w_cur=$n_wc w_nxt=$n_wn q_mem=$n_qq act_mem=$n_aa"
set n_w   [llength [get_cells -hier -filter {NAME =~ *w_mem_*}]]
set n_q   [llength [get_cells -hier -filter {NAME =~ *q_mem_*}]]
set n_act [llength [get_cells -hier -filter {NAME =~ *act_mem_*}]]
puts "DCP_CHECK_RAM_GROUPS w_mem=$n_w q_mem=$n_q act_mem=$n_act"

set n36  [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set n18  [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]
set nfdre [llength [get_cells -hier -filter {REF_NAME == FDRE}]]
puts "DCP_CHECK RAMB36=$n36 RAMB18=$n18 FDRE=$nfdre"
set worst [get_timing_paths -max_paths 1 -delay_type max -quiet]
if {[llength $worst] > 0} {
    set slack [get_property SLACK $worst]
    set src   [get_property STARTPOINT_PIN $worst]
    set dst   [get_property ENDPOINT_PIN $worst]
    puts "DCP_CHECK WNS=$slack SRC=$src DST=$dst"
} else {
    puts "DCP_CHECK WNS=NA"
}
puts "DCP_CHECK_DONE"
