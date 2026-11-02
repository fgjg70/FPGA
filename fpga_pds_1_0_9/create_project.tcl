set project_dir [file dirname [file normalize [info script]]]
cd $project_dir

set_arch -family Logos -device PGL22G -speedgrade -6 -package FBG256

set source_path [file join $project_dir generated riscv_pds.v]
if {![file isfile $source_path]} {
    error "Missing generated RTL: $source_path. Run create_project.bat first."
}
add_design $source_path

add_constraint [file join $project_dir riscv.fdc]
if {![llength [info commands open_project]]} {
    compile -top_module top_pgl22g -compiler_directives {SYNTHESIS} -loop_limit 10000
}
