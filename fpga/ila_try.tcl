# Try several TRIGGER_COMPARE_VALUE formats to find the one Vivado 2018.3 accepts.
open_hw
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE {D:/USER/Desktop/FPGA/FPGA/fpga/ila_proj.runs/impl_1/top_a100t.bit} [current_hw_device]
set_property PROBES.FILE {D:/USER/Desktop/FPGA/FPGA/fpga/ila_proj.runs/impl_1/top_a100t.ltx} [current_hw_device]
program_hw_devices [current_hw_device]
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes true [current_hw_device]
set ila [lindex [get_hw_ilas -of_objects [current_hw_device]] 0]
set pr [get_hw_probes ila_ctrl -of_objects $ila]
puts "PROBE=$pr WIDTH=[get_property WIDTH $pr]"
puts "DEFAULT=[get_property TRIGGER_COMPARE_VALUE $pr]"
foreach v {eq8\'h40 eq8\'b01000000 8\'b01000000 eq16\'h0040} {
    if {[catch {set_property TRIGGER_COMPARE_VALUE $v $pr} err]} {
        puts "TRY $v -> FAIL: $err"
    } else {
        puts "TRY $v -> OK  now=[get_property TRIGGER_COMPARE_VALUE $pr]"
    }
}
puts "TRY_DONE"
