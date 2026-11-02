set project_dir [file dirname [file normalize [info script]]]
cd $project_dir
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
foreach source_file {
    debug_keys.v debug_uart.v camera_sccb.v camera_config.v camera_fifo_capture.v
    camera_framebuffer.v camera_console.v lcd_debug_video.v top_camera_lcd_debug.v
    pg2l100h_clock.v top_pg2l100h_camera_lcd.v
} {
    add_design [file join $project_dir rtl $source_file]
}
add_constraint [file join $project_dir pg2l100h_camera_lcd.fdc]
if {![llength [info commands open_project]]} {
    compile -top_module top_pg2l100h_camera_lcd -compiler_directives {SYNTHESIS}
}
