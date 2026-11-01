# ============================================================================
# check_clockvars.tcl -- ?????????????????????????????? DCP (open_checkpoint, ????????????)
# ----------------------------------------------------------------------------
# ASCII only. ??????: vivado -mode batch -source check_clockvars.tcl
# ??? canonical nn_mem.dcp (8.0ns) + 5 ?????????????????????:
#   - open_checkpoint -> ??? DCP ??? clk ??????
#   - Block RAM Tile / RAMB36 ??? (?????? 120)
#   - @????????? WNS (????????? 0.5ns ?????? I/O, ?????? DCP)
# ?????? check_clockvars.rpt + ?????????????????? CLKVAR_CHECK*???
# ============================================================================
set script_dir [file normalize [file dirname [info script]]]
set out [open [file join $script_dir "check_clockvars.rpt"] "w"]
puts $out "tag,period_ns,ramb36,wns_ns"
foreach tag {nn_mem nn_mem_10p000 nn_mem_9p524 nn_mem_10p500 nn_mem_7p619 nn_mem_7p000 nn_mem_12p500 nn_mem_11p428} {
    set dcp [file join $script_dir "${tag}.dcp"]
    if {![file exists $dcp]} { continue }
    open_checkpoint $dcp
    set clk  [get_clocks -quiet clk]
    set per  [expr {[llength $clk] ? [get_property PERIOD $clk] : -1.0}]
    set n36  [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
    set_input_delay  -clock clk 0.500 [all_inputs]
    set_output_delay -clock clk 0.500 [all_outputs]
    set worst [get_timing_paths -max_paths 1 -delay_type max -quiet]
    set wns "NA"
    if {[llength $worst] > 0} { set wns [get_property SLACK $worst] }
    puts "CLKVAR_CHECK tag=$tag period=$per RAMB36=$n36 WNS=$wns"
    puts $out "$tag,$per,$n36,$wns"
    close_design
}
close $out
puts "CLKVAR_CHECK_DONE"
