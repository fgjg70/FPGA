set project_dir [file dirname [file normalize [info script]]]
cd $project_dir

set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
foreach source_file {debug_keys.v debug_uart.v debug_console.v debug_i2c_write.v debug_ms7210.v debug_video.v top_io_debug.v} {
    add_design [file join $project_dir rtl $source_file]
}
add_constraint [file join $project_dir mes50hp_io_debug.fdc]
if {![llength [info commands open_project]]} {
    compile -top_module top_io_debug -compiler_directives {SYNTHESIS}
}
