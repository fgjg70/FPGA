set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem_noclk.dcp"]
puts "PART=[get_property PART [current_design]]"
puts "SITES_ALL=[llength [get_sites -quiet]]"
puts "SITES_RAMB36A=[llength [get_sites -quiet -filter {SITE_TYPE =~ *RAMB36*}]]"
puts "SITES_FILTER2=[llength [get_sites -quiet -filter {SITE_TYPE == RAMB36E1}]]"
set tps [get_property SITE_TYPES [get_parts [get_property PART [current_design]]]]
puts "SITE_TYPES_DONE"
set rambs [get_sites -quiet -filter {SITE_TYPE == RAMB36E1}]
if {[llength $rambs] > 0} {
    set hist [dict create]
    foreach s $rambs { set x [get_property COLUMN $s]; if {![dict exists $hist $x]} { dict set hist $x 0 }; dict set hist $x [expr {[dict get $hist $x] + 1}] }
    puts "NOCLK_SITES total=[llength $rambs] by_column=$hist"
}
puts "SITEDBG_DONE"
