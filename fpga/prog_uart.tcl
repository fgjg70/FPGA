# ===========================================================================
# prog_uart.tcl -- program the SCORING bitstream (no ILA) for the UART channel.
#
# Why: at 150 MHz the design closes in the **scoring flow** (build.tcl, no ILA)
# but NOT in the **ILA flow** (debug core steals routing). So verify the image we
# actually ship, and read the CoreMark verdict back over the **UART** instead.
#
# [!] Use `open_hw`, NOT `open_hw_manager`:
#   the latter is not a command in this batch context ->
#   `invalid command name "open_hw_manager"` (measured 2026-10-17).
#   jtag_probe.tcl / ila_cap_done.tcl both use `open_hw`.
# Keep this file PURE ASCII (Vivado Tcl requirement).
# ===========================================================================
set root [file normalize [file join [file dirname [info script]] ..]]

set BIT_FILE "$root/fpga/cpu_a100t.bit"
if {[info exists ::env(UART_BIT)] && $::env(UART_BIT) ne ""} {
  set BIT_FILE $::env(UART_BIT)
}
puts "PROG_BIT=$BIT_FILE"
if {![file exists $BIT_FILE]} {
  puts "PROG_ERROR: bitstream not found: $BIT_FILE"
  error "PROG_ERROR: bitstream not found"
}

open_hw
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
puts "PROG_DEVICE=[current_hw_device]"
set_property PROGRAM.FILE $BIT_FILE [current_hw_device]
program_hw_devices [current_hw_device]
puts "PROGRAMMED"
