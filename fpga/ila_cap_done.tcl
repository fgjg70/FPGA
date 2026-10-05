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
# ITERATIONS=1200 -> ~508M cycles -> 10.16 s @50MHz; wait 16 s for margin
after 16000
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
write_hw_ila_data -csv_file {D:/USER/Desktop/FPGA/FPGA/results/ila_done.csv} hw_ila_data_1
puts "CAPTURE_OK"
