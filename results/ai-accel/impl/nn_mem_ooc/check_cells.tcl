set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem.dcp"]
foreach p {RAM64X1 RAM32X1 RAM128X1 RAM256X1 LUT1 LUT2 LUT3 LUT4 LUT5 LUT6 FDRE RAMB36E1} {
  set n [llength [get_cells -hier -filter "REF_NAME =~ $p*"]]
  puts "CELL $p=$n"
}
puts "CELLCHECK_DONE"
