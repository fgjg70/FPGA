set session_dir [file dirname [file normalize [info script]]]
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65432
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -file [file join $session_dir flash_image.sfc] -device_index 0
cfg_jtag_flash_readback -device_index 0 -file [file join $session_dir flash_before_program.sfc]
cfg_jtag_flash_erase -device_index 0
cfg_jtag_flash_program -device_index 0
cfg_jtag_flash_verify -device_index 0
cfg_jtag_flash_readback -device_index 0 -file [file join $session_dir flash_after_program.sfc]
cfg_reset_fpga -device_index 0
after 15000
cfg_read_device_property -mode 3 -device_index 0
after 5000
cfg_read_device_property -mode 3 -device_index 0
cfg_disconnect
cfg_close
