# Quick JTAG liveness probe - does NOT program the device.
# Verifies: hw_server reachable, target openable, device + ILA visible.
# Keep this file PURE ASCII.
open_hw
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
puts "DEVICE = $dev"
current_hw_device $dev
# NOTE: REGISTER.IDCODE is not a valid property here -> use IDCODE
if {[catch {set idc [get_property IDCODE $dev]} e]} { set idc "n/a ($e)" }
puts "IDCODE = $idc"
if {[catch {set pt [get_property PART $dev]} e]} { set pt "n/a ($e)" }
puts "PART   = $pt"
set ilas [get_hw_ilas -of_objects $dev]
puts "ILA_COUNT = [llength $ilas]"
foreach i $ilas {
  puts "ILA = $i"
  foreach p [get_hw_probes -of_objects $i] {
    puts "   PROBE $p  width=[get_property WIDTH $p]"
  }
}
puts "JTAG_PROBE_OK"
