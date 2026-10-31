# ASCII only. Debug: nn_mem alone with WQ init macros -> must show ~124 BRAM.
set repo "D:/USER/Desktop/FPGA/FPGA"
set out  "D:/USER/Desktop/FPGA/FPGA/results/ai-accel/proto/engine"
set wq   "D:/USER/Desktop/FPGA/FPGA/.fpga-cache/nn_wq_split"
read_verilog [list "$repo/nn_pkg.sv" "$repo/nn_mem.sv" "$out/wrap_mem.sv"]
set wqdefs "NN_WQ_INIT_A=\"$wq/wq_A.hex\" NN_WQ_INIT_B=\"$wq/wq_B.hex\" NN_WQ_INIT_C=\"$wq/wq_C.hex\" NN_WQ_INIT_D=\"$wq/wq_D.hex\""
synth_design -top nn_mem_only_wrap -part xc7a100tfgg484-2 -mode out_of_context \
  -verilog_define $wqdefs
create_clock -period 6.667 -name clk [get_ports clk]
report_utilization -file "$out/mem_only_util.rpt"
puts "DBG_MEM_FDRE=[llength [get_cells -hier -filter {REF_NAME == FDRE}]]"
puts "DBG_MEM_RAMB36=[llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]"
puts "DBG_MEM_RAMB18=[llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]"
puts "MEM_ONLY_DONE"
