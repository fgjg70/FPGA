set project_dir [file dirname [file normalize [info script]]]
cd $project_dir

set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484

set source_path [file join $project_dir generated riscv_pds.v]
if {![file isfile $source_path]} {
    error "Missing generated RTL: $source_path. Run create_project.bat first."
}
add_design $source_path
set constraint_path [file join $project_dir generated profile_constraints.fdc]
if {![file isfile $constraint_path]} {
    set constraint_path [file join $project_dir mes50hp.fdc]
}
add_constraint $constraint_path
if {![llength [info commands open_project]]} {
    compile -top_module top_mes50hp -compiler_directives {SYNTHESIS} -loop_limit 10000
}
