# Discover ILA probes; try explicit PROBES.FILE association.
open_hw
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
puts "device = [current_hw_device]"
set_property PROGRAM.FILE {D:/USER/Desktop/FPGA/FPGA/fpga/ila_proj.runs/impl_1/top_a100t.bit} [current_hw_device]
puts "program file set"
set_property PROBES.FILE {D:/USER/Desktop/FPGA/FPGA/fpga/ila_proj.runs/impl_1/top_a100t.ltx} [current_hw_device]
puts "probes file set"
program_hw_devices [current_hw_device]
puts "PROGRAMMED"
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes true [current_hw_device]
puts "refreshed"
puts "PROBES.FILE now = [get_property PROBES.FILE [current_hw_device]]"
puts "=== ILAS ==="
set n 0
foreach il [get_hw_ilas -of_objects [current_hw_device]] {
    incr n
    puts "  ILA $n : $il"
    set pl [get_hw_probes -of_objects $il]
    puts "    probe count = [llength $pl]"
    foreach pr $pl { puts "    PROBE: [get_property NAME $pr]  WIDTH=[get_property WIDTH $pr]" }
}
puts "ILA_INFO_DONE"
