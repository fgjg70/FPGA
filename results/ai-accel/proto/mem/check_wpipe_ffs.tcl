set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem_wpipe.dcp"]
set ffs [get_cells -hier -filter {REF_NAME == FDRE}]
set hist [dict create]
foreach c $ffs {
    set nm [get_property NAME $c]
    regsub {_reg_[0-9]+$} $nm "" base
    regsub {\[[0-9]+\]$} $base "" base2
    if {![dict exists $hist $base2]} { dict set hist $base2 0 }
    dict set hist $base2 [expr {[dict get $hist $base2] + 1}]
}
puts "WPIPE_FFGROUPS $hist"
puts "WPIPE_FF_DONE"
