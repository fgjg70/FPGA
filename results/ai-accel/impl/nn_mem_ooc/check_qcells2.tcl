set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem.dcp"]
set all [get_cells -hier -filter {REF_NAME == RAMB36E1}]
set group_lo [get_cells -hier -filter {REF_NAME == RAMB36E1 && NAME =~ *q_rd_lo_*}]
set group_hi [get_cells -hier -filter {REF_NAME == RAMB36E1 && NAME =~ *q_rd_hi_*}]
set group_w  [get_cells -hier -filter {REF_NAME == RAMB36E1 && NAME =~ *w_cur_*}]
set group_ab [get_cells -hier -filter {REF_NAME == RAMB36E1 && NAME =~ *act_mem_*}]
puts "QGROUP lo=[llength $group_lo] hi=[llength $group_hi] w=[llength $group_w] ab=[llength $group_ab] total=[llength $all]"
puts "LUT_TOTAL [llength [get_cells -hier -filter {REF_NAME =~ LUT* }]]"
puts "QCHECK2_DONE"
