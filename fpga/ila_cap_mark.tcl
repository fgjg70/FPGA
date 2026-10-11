# Capture a pipeline-efficiency waveform slice from INSIDE the measured region.
#
# Strategy: program, wait 3 s (the measured region lasts ~17.7 s per
# sim/prog/cm_hw.build.json, so 3 s lands well inside it), then arm with NO
# trigger (probe default eq8'hXX = always true). The 2048-sample
# window is 41 us of real CoreMark execution -- exactly what the analysis report
# needs (pc advancing, stalls, redirects).
#
# Bit-level exact-match triggers are fragile here: eq8'h08 requires stall=1 AND
# every other ila_ctrl bit = 0 simultaneously.
# Keep this file PURE ASCII (Vivado Tcl requirement, PITFALLS R21).
# Paths are derived from this script's location (E-02): no absolute paths.
set root [file normalize [file join [file dirname [info script]] ..]]
set BIT_FILE "$root/fpga/ila_proj.runs/impl_1/top_a100t.bit"
set LTX_FILE "$root/fpga/ila_proj.runs/impl_1/top_a100t.ltx"
set CSV_FILE "$root/results/ila_pipeline.csv"
if {![file exists $BIT_FILE]} {
  puts "MARK_ERROR: ILA bitstream not found: $BIT_FILE (run fpga/build_ila.bat first)"
  error "MARK_ERROR: no ILA bitstream"
}
open_hw
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE $BIT_FILE [current_hw_device]
set_property PROBES.FILE $LTX_FILE [current_hw_device]
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
write_hw_ila_data -force -csv_file $CSV_FILE hw_ila_data_1
puts "CAPTURE_OK"
