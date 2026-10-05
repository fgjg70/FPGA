# ============================================================================
# ila_cap_done.tcl  read back CRC verdict + tick count after the 10 s run
# ----------------------------------------------------------------------------
# probe2 bit map: [0]=fail [1]=pass [2]=illegal [3]=stall [4]=redirect [5]=mark [6]=done
# probe3 = score_result = (crc_ok << 31) | ticks
#
# done is sticky, so this trigger fires as soon as the ILA is armed after the
# benchmark finished. Wait long enough for the 10.16 s run.
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

# let CoreMark finish (ITERATIONS=1200 -> ~508M cycles -> 10.16 s @50MHz)
after 14000
puts "WAITED"

set ila [lindex [get_hw_ilas] 0]
if {$ila eq ""} { error "NO_ILA_FOUND" }
reset_hw_ila $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
set_property TRIGGER_COMPARE_VALUE 8'h40 [get_hw_probes probe2 -of_objects $ila]
run_hw_ila $ila
puts "ARMED"
wait_on_hw_ila -timeout 60 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file {D:/USER/Desktop/FPGA/FPGA/results/ila_done.csv} hw_ila_data_1
puts "CAPTURE_OK"
