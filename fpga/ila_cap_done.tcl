# Read back the packed CRC verdict + tick count after the 10 s CoreMark run.
# ila_ctrl[7:0]: 7=unused 6=done 5=mark 4=redirect 3=stall 2=illegal 1=pass 0=fail
#
# NO TRIGGER IS SET ON PURPOSE. The probe default is eq8'hXX (don't care) which
# means "always true", so the capture starts as soon as it is armed.
# An exact-match trigger such as eq8'h40 does NOT work here: when the program
# finishes, pass_r is also 1 (crt0 wrote tohost), so ila_ctrl is 0x42, not 0x40.
#
# TRIGGER_COMPARE_VALUE format notes (Vivado 2018.3):
#   needs the comparison prefix and must match the probe width:
#     eq8'h40        OK
#     8'h40          -> Invalid logic operator '8'
#     01000000       -> No apostrophe specified
#     eq16'h0040     -> wrong bit count
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
# ITERATIONS=3000 -> ~1.239e9 cycles -> 17.70 s @70MHz (was 508M / 10.16 s @50MHz);
# wait 22 s (= 17.70 s + 4.3 s margin) for the CoreMark run to finish.
after 22000
puts "WAITED"
set ila [lindex [get_hw_ilas -of_objects [current_hw_device]] 0]
if {$ila eq ""} { error "NO_ILA_FOUND" }
puts "ILA = $ila"
reset_hw_ila $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
run_hw_ila $ila
puts "ARMED"
wait_on_hw_ila -timeout 60 $ila
upload_hw_ila_data $ila
# -force: results/ila_done.csv must be explicitly overwritten when it exists,
# otherwise Labtoolstcl 44-54 errors out.
set csv {D:/USER/Desktop/FPGA/FPGA/results/ila_done.csv}
write_hw_ila_data -force -csv_file $csv hw_ila_data_1

# Self-check: confirm the file was really refreshed by THIS capture.
# Printing CAPTURE_OK alone is not enough -- if the write silently failed the script
# can still look successful, and the downstream `hw` subcommand would then parse an
# OLD file and report the PREVIOUS run's result (measured: after the board dropped
# off, it still printed "hardware verify PASS"). Checking mtime makes
# "did the file actually refresh" a hard criterion.
# Keep this file PURE ASCII (Vivado Tcl requirement).
if {![file exists $csv]} { error "CAPTURE_NO_FILE: $csv not found" }
set mt  [file mtime $csv]
set age [expr {[clock seconds] - $mt}]
puts "CSV_MTIME=[clock format $mt -format {%Y-%m-%d %H:%M:%S}] AGE_SEC=$age"
if {$age > 120} { error "CAPTURE_STALE: csv is $age s old -> this capture did not land" }
puts "CAPTURE_OK"
