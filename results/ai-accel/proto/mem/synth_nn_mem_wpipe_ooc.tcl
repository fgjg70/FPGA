# ============================================================================
# synth_nn_mem_wpipe_ooc.tcl -- OOC synth of proto/mem/nn_mem_wpipe.sv @8ns
# ----------------------------------------------------------------------------
# ASCII only. ??????: vivado -mode batch -source synth_nn_mem_wpipe_ooc.tcl
# ??????: ??? W ???????????????????????????????????? (FF/LUT/BRAM) ??? OOC @8ns WNS???
# ?????? (proto/mem/):
#   nn_mem_wpipe.dcp / nn_mem_wpipe_util.rpt / nn_mem_wpipe_timing.rpt
#   nn_mem_wpipe_paths.rpt
# ???????????? nn_mem ??? OOC ??????: ??? W/Q ???????????????, create_clock 8.000,
#   DCP ?????? clk (?????????????????? 0.5ns ?????? I/O, ????????? DCP)???
# ============================================================================
set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize [file join $script_dir ".." ".." ".." ".."]]
set split      [file normalize [file join $repo ".fpga-cache" "nn_wq_split"]]
set part       "xc7a100tfgg484-2"
set period     8.000
set top        "nn_mem_wpipe"

puts "WPIPE_CFG top=$top part=$part period=$period"
read_verilog -sv [file join $repo "nn_pkg.sv"]
read_verilog -sv [file join $script_dir "nn_mem_wpipe.sv"]

set wqdefs [list \
    [format {NN_W_INIT_A="%s"} [file join $split "w_A.hex"]] \
    [format {NN_W_INIT_B="%s"} [file join $split "w_B.hex"]] \
    [format {NN_W_INIT_C="%s"} [file join $split "w_C.hex"]] \
    [format {NN_W_INIT_D="%s"} [file join $split "w_D.hex"]] \
    [format {NN_Q_INIT_LO="%s"} [file join $split "q_lo.hex"]] \
    [format {NN_Q_INIT_HI="%s"} [file join $split "q_hi.hex"]] ]

synth_design -top $top -part $part -mode out_of_context -directive Default -verilog_define $wqdefs
create_clock -name clk -period $period [get_ports clk]
write_checkpoint -force [file join $script_dir "nn_mem_wpipe.dcp"]

set_input_delay  -clock clk 0.500 [all_inputs]
set_output_delay -clock clk 0.500 [all_outputs]
report_utilization -file [file join $script_dir "nn_mem_wpipe_util.rpt"]
report_timing_summary -file [file join $script_dir "nn_mem_wpipe_timing.rpt"] -max_paths 10 -delay_type max
report_timing -max_paths 20 -file [file join $script_dir "nn_mem_wpipe_paths.rpt"]

set n36   [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set n18   [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]
set nfdre [llength [get_cells -hier -filter {REF_NAME == FDRE}]]
set nlut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
puts "WPIPE_CELLS RAMB36=$n36 RAMB18=$n18 FDRE=$nfdre LUTCELLS=$nlut"
puts "WPIPE_DONE"
