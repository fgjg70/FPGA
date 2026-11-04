set session_dir [file dirname [file normalize [info script]]]
cfg_set_tcl_break -flag true
cfg_gen_sfc -sbit [file join $session_dir top_pg2l100h_vision.sbit] -sfc [file join $session_dir flash_image.sfc] -device_name W25Q128Q -opcode 11
cfg_close
