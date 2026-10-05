# ============================================================================
# ila_cap_mark.tcl  capture pipeline-efficiency waveform (for the report)
# ----------------------------------------------------------------------------
# probe2 bit map: [0]=fail [1]=pass [2]=illegal [3]=stall [4]=redirect [5]=mark [6]=done
# probe3 = score_result (packed CRC verdict + tick count)
#
# WHY NOT TRIGGER ON mark:
#   mark is written in start_time(), which happens only ~0.16 ms after reset
#   release (CoreMark's pre-measurement init is short). The JTAG sequence
#   program -> refresh -> arm takes seconds, so the mark pulse is long gone.
#   Triggering on stall instead fires within microseconds - stalls occur
#   constantly during the benchmark - and the captured window is a genuine
#   slice of the measured region (the run lasts 10 s, arming happens a few
#   seconds in).
# ============================================================================
open_hw
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes false [current_hw_device]
set_property PROGRAM.FILE {D:/USER/Desktop/FPGA/FPGA/fpga/ila_proj.runs/impl_1/top_a100t.bit} [current_hw_device]
program_hw_devices [current_hw_device]
refresh_hw_device [current_hw_device]
puts "PROGRAMMED"

set ila [lindex [get_hw_ilas] 0]
if {$ila eq ""} { error "NO_ILA_FOUND" }
reset_hw_ila $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
# trigger on probe2[3] = pipeline stall
set_property TRIGGER_COMPARE_VALUE 8'h08 [get_hw_probes probe2 -of_objects $ila]
run_hw_ila $ila
puts "ARMED"
wait_on_hw_ila -timeout 60 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file {D:/USER/Desktop/FPGA/FPGA/results/ila_pipeline.csv} hw_ila_data_1
puts "CAPTURE_OK"
