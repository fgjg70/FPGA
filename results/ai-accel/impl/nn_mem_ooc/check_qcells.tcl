set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem.dcp"]
set all [get_cells -hier -filter {REF_NAME == RAMB36E1}]
set groups [dict create]
foreach c $all {
    set nm [get_property NAME $c]
    if {[string match "*w_cur_*" $nm]} { dict incr groups w_cur } elseif {[string match "*act_mem_*" $nm]} { dict incr groups act_mem } elseif {[string match "*q_mem_lo_*" $nm]} { dict incr groups q_lo } elseif {[string match "*q_mem_hi_*" $nm]} { dict incr groups q_hi } else { dict incr groups other }
}
puts "QGROUP $groups"
set ntot [llength $all]
puts "QGROUP_TOTAL RAMB36=$ntot"
foreach c $all {
    set nm [get_property NAME $c]
    if {![string match "*w_cur_*" $nm] && ![string match "*act_mem_*" $nm] && ![string match "*q_mem_lo_*" $nm] && ![string match "*q_mem_hi_*" $nm]} { puts "QCELL_OTHER $nm" }
}
puts "QCHECK_DONE"
