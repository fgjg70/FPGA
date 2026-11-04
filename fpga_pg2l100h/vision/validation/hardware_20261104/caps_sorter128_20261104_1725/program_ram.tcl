set session_dir [file dirname [file normalize [info script]]]
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65432
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_assign_file -file [file join $session_dir top_pg2l100h_vision.sbit] -device_index 0
cfg_set_device_property -device_index 0 -program 1
cfg_program -device_index 0
after 5000
cfg_read_device_property -mode 3 -device_index 0
after 3000
cfg_read_device_property -mode 3 -device_index 0
cfg_disconnect
cfg_close
