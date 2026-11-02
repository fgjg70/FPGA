# ============================================================================
# synth_nn_mem_wpipe_noclk_root.tcl -- ROOT nn_mem.sv (wpipe landed) -> no-clock DCP
# ----------------------------------------------------------------------------
# ASCII only. ??????: vivado -mode batch -source synth_nn_mem_wpipe_noclk_root.tcl
# ??????: ????????? nn_mem.sv (module nn_mem; W ????????? 1->2; Q lo BRAM + hi ?????????)
# ??????: results/ai-accel/impl/nn_mem_ooc/nn_mem_wpipe_noclk.dcp (+ util rpt)
# ??????: -mode out_of_context, **??? create_clock / ??? read_xdc / ?????? I/O delay**;
#       ??????????????????????????? sys_clk_core ???????????? (??? nn_mem_noclk.dcp ?????????)???
# ============================================================================
set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize [file join $script_dir ".." ".." ".." ".."]]
set split      [file normalize [file join $repo ".fpga-cache" "nn_wq_split"]]
set part       "xc7a100tfgg484-2"
set top        "nn_mem"

puts "WPIPE_ROOT_CFG top=$top part=$part"
read_verilog -sv [file join $repo "nn_pkg.sv"]
read_verilog -sv [file join $repo "nn_mem.sv"]

set wqdefs [list \
    [format {NN_W_INIT_A="%s"} [file join $split "w_A.hex"]] \
    [format {NN_W_INIT_B="%s"} [file join $split "w_B.hex"]] \
    [format {NN_W_INIT_C="%s"} [file join $split "w_C.hex"]] \
    [format {NN_W_INIT_D="%s"} [file join $split "w_D.hex"]] \
    [format {NN_Q_INIT_LO="%s"} [file join $split "q_lo.hex"]] \
    [format {NN_Q_INIT_HI="%s"} [file join $split "q_hi.hex"]] ]

synth_design -top $top -part $part -mode out_of_context -directive Default -verilog_define $wqdefs
write_checkpoint -force [file join $script_dir "nn_mem_wpipe_noclk.dcp"]
report_utilization -file [file join $script_dir "nn_mem_wpipe_noclk_util.rpt"]

set n36  [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set n18  [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]
set nfdre [llength [get_cells -hier -filter {REF_NAME == FDRE}]]
set nlut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set nclk [llength [get_clocks -quiet]]
puts "WPIPE_ROOT_CELLS RAMB36=$n36 RAMB18=$n18 FDRE=$nfdre LUTCELLS=$nlut CLOCKS=$nclk"
puts "WPIPE_ROOT_DONE"
