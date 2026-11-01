# ============================================================================
# check_noclk.tcl -- verify nn_mem_noclk.dcp: no clocks, 120 BRAM, netlist intact
# ----------------------------------------------------------------------------
# ASCII only. 跑法: vivado -mode batch -source check_noclk.tcl
# 检查项:
#   1) get_clocks 为空 (DCP 无时钟约束); get_generated_clocks 也应为空
#   2) RAMB36=120 / RAMB18=0 / FDRE=90 / LUT 约 2,456
#   3) 给出 RAMB36 site 的列分布 (X 坐标 -> 数量), 供 Lead 做 u_nn pblock/floorplan
# 不修改 DCP。
# ============================================================================
set script_dir [file normalize [file dirname [info script]]]
open_checkpoint [file join $script_dir "nn_mem_noclk.dcp"]

set clks [get_clocks -quiet]
set gclks [get_generated_clocks -quiet]
puts "NOCLK_CHECK clocks=[llength $clks] generated=[llength $gclks]"
if {[llength $clks] > 0} { puts "NOCLK_CHECK WARN clock objects: $clks" }

set n36  [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set n18  [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]
set nfdre [llength [get_cells -hier -filter {REF_NAME == FDRE}]]
set nlut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
puts "NOCLK_CHECK RAMB36=$n36 RAMB18=$n18 FDRE=$nfdre LUTCELLS=$nlut"

set sites [get_sites -quiet -filter {SITE_TYPE == RAMB36E1}]
set hist [dict create]
foreach s $sites {
    set x [get_property COLUMN $s]
    if {![dict exists $hist $x]} { dict set hist $x 0 }
    dict set hist $x [expr {[dict get $hist $x] + 1}]
}
puts "NOCLK_SITES total=[llength $sites] by_column=$hist"
puts "NOCLK_CHECK_DONE"
