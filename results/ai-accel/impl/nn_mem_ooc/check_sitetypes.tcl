set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem_noclk.dcp"]
set types [dict create]
foreach s [get_sites -quiet] {
    set ty [get_property SITE_TYPE $s]
    if {![dict exists $types $ty]} { dict set types $ty 0 }
    dict set types $ty [expr {[dict get $types $ty] + 1}]
}
puts "SITETYPES $types"
puts "SITETYPES_DONE"
