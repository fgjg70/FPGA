set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem_noclk.dcp"]
set rambs [get_sites -quiet -filter {SITE_TYPE == RAMBFIFO36E1}]
set hist [dict create]
foreach s $rambs {
    set nm [get_property NAME $s]
    if {[regexp {X(\d+)Y(\d+)} $nm -> x y]} {
        if {![dict exists $hist $x]} { dict set hist $x 0 }
        dict set hist $x [expr {[dict get $hist $x] + 1}]
    }
}
puts "RAMB36_COLUMNS total=[llength $rambs] by_column=$hist"
set slices [get_sites -quiet -filter {SITE_TYPE == SLICEL}]
set shist [dict create]
foreach s $slices {
    set nm [get_property NAME $s]
    if {[regexp {X(\d+)Y(\d+)} $nm -> x y]} {
        if {![dict exists $shist $x]} { dict set shist $x 0 }
        dict set shist $x [expr {[dict get $shist $x] + 1}]
    }
}
puts "SLICE_COLUMNS=[dict size $shist] by_column=$shist"
puts "RAMB_COLCHECK_DONE"
