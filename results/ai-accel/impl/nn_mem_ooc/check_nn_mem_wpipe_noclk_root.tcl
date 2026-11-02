set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem_wpipe_noclk.dcp"]
set clks [get_clocks -quiet]
set gclks [get_generated_clocks -quiet]
set n36 [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set n18 [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]
set nfdre [llength [get_cells -hier -filter {REF_NAME == FDRE}]]
puts "ROOT_DCP_CHECK clocks=[llength $clks] generated=[llength $gclks] RAMB36=$n36 RAMB18=$n18 FDRE=$nfdre"
puts "ROOT_DCP_CHECK_DONE"
