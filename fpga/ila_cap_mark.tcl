# Capture a pipeline-efficiency waveform slice from INSIDE the measured region.
#
# Strategy: program, wait 3 s (the run lasts 10.16 s, so we are mid-benchmark),
# then arm with NO trigger (probe default eq8'hXX = always true). The 2048-sample
# window is 41 us of real CoreMark execution -- exactly what the analysis report
# needs (pc advancing, stalls, redirects).
#
# Bit-level exact-match triggers are fragile here: eq8'h08 requires stall=1 AND
# every other ila_ctrl bit = 0 simultaneously.
# Keep this file PURE ASCII.
open_hw
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE {D:/USER/Desktop/FPGA/FPGA/fpga/ila_proj.runs/impl_1/top_a100t.bit} [current_hw_device]
set_property PROBES.FILE {D:/USER/Desktop/FPGA/FPGA/fpga/ila_proj.runs/impl_1/top_a100t.ltx} [current_hw_device]
program_hw_devices [current_hw_device]
puts "PROGRAMMED"
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes true [current_hw_device]
after 3000
puts "MID_RUN"
set ila [lindex [get_hw_ilas -of_objects [current_hw_device]] 0]
if {$ila eq ""} { error "NO_ILA_FOUND" }
reset_hw_ila $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
run_hw_ila $ila
puts "ARMED"
wait_on_hw_ila -timeout 60 $ila
upload_hw_ila_data $ila
# -force: results/ila_pipeline.csv must be explicitly overwritten when it exists,
# otherwise Labtoolstcl 44-54 errors out.
write_hw_ila_data -force -csv_file {D:/USER/Desktop/FPGA/FPGA/results/ila_pipeline.csv} hw_ila_data_1
puts "CAPTURE_OK"
