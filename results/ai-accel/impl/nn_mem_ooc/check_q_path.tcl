set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem.dcp"]
set_input_delay  -clock clk 0.500 [all_inputs]
set_output_delay -clock clk 0.500 [all_outputs]
report_timing -to [get_ports {q_rdata[*]}] -max_paths 5 -delay_type max -file [file join $script_dir "q_path.rpt"]
set worst [get_timing_paths -to [get_ports {q_rdata[*]}] -max_paths 1 -delay_type max -quiet]
if {[llength $worst] > 0} {
    puts "QPATH slack=[get_property SLACK $worst] src=[get_property STARTPOINT_PIN $worst] dst=[get_property ENDPOINT_PIN $worst] logic=[get_property LOGIC_LEVELS $worst]"
}
puts "QPATH_DONE"
