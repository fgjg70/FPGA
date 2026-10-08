# ============================================================================
# ref5/build_ref5.tcl — ref5 参照核 (普通五级 RV32I) 的**独立**非工程模式构建
# ----------------------------------------------------------------------------
# 与 fpga/build.tcl 同风格但极简, 只做"综合 -> 优化 -> 布局 -> 布线 -> STA"。
# 与主核**同口径**: 同一器件、同一 20 ns 周期约束、同一条
#     fmax = 1000 / (20 - WNS)
# 唯一的硬目标就是 fmax。
#
# 跑法 (Vivado 不在 PATH, 需要 PROCESSOR_ARCHITECTURE):
#   $env:PROCESSOR_ARCHITECTURE="AMD64"
#   & "D:\software\Learn\Xilinx\Vivado\2018.3\bin\vivado.bat" -mode batch
#       -nojournal -nolog -source ref5\build_ref5.tcl
#
# 可选环境变量 (只用于做对照实验, 全部有安全默认值):
#   REF5_TAG         报告存放子目录名 (ref5/runs/<TAG>/...), 默认 ref5
#   REF5_PBLOCK      Pblock 区域, 默认 CLOCKREGION_X1Y0:CLOCKREGION_X1Y3
#                    (实测最佳; 传 "off" 关掉 = 无物理约束基线)
#   REF5_PBLOCK_CELLS 进 Pblock 的单元, 默认 "u_core u_imem u_dmem"
#   REF5_PLACE_DIR   place_design -directive, 默认 WLDrivenBlockPlacement
#   REF5_ROUTE_DIR   route_design -directive, 默认 Default
#   REF5_PHYS_OPT    非空 -> 布线前后各做一次 phys_opt_design AggressiveExplore
#   REF5_BIG_MEM     非空 -> imem/dmem 各 16KB (RAMB36 x4, 主核同档);
#                    默认各 4KB (RAMB36 x1, 实测快约 7%)
# ============================================================================

set part xc7a100tfgg484-2
set root "D:/USER/Desktop/FPGA/FPGA"
set dir  "$root/ref5"

set tag "ref5"
if {[info exists ::env(REF5_TAG)] && $::env(REF5_TAG) ne ""} { set tag $::env(REF5_TAG) }
set rdir "$dir/runs/$tag"
file mkdir $rdir
puts "REF5_TAG=$tag"

read_verilog -sv [list "$dir/ref5_core.sv" "$dir/ref5_top.sv"]
# 约束必须在 synth_design **之前** 读入 (非工程模式: 这样综合才是时序驱动的,
# 与 fpga/build.tcl 读 daVinciPro.xdc 的位置一致)。时钟定义在 ref5.xdc:
#   create_clock -period 20.000  =>  fmax = 1000/(20 - WNS)
read_xdc "$dir/ref5.xdc"

set vdefs ""
if {[info exists ::env(REF5_BIG_MEM)] && $::env(REF5_BIG_MEM) ne ""} {
  append vdefs " REF5_BIG_MEM=1"
}
puts "REF5_VDEFS=$vdefs"

set synth_args [list -top ref5_top -part $part]
# -resource_sharing off: 综合器默认会把"跳转目标加法器"和 ALU 的加法器**共享**
# 成一个 (实测综合日志 HDL ADVISOR 明确报过), 于是在两条路径上都插进了 mux。
# 参照核面积富余, 直接关掉共享 (主核 P3 实验 A 的独立加法器就是这样赢的)。
lappend synth_args -resource_sharing off
if {$vdefs ne ""} { lappend synth_args -verilog_define $vdefs }
synth_design {*}$synth_args

# ---- Pblock (默认开 = 实测最佳; 主核经验: 收得更紧不一定更好, 必须实测) ----
set pb_range "CLOCKREGION_X1Y0:CLOCKREGION_X1Y3"
if {[info exists ::env(REF5_PBLOCK)] && $::env(REF5_PBLOCK) ne ""} {
  set pb_range $::env(REF5_PBLOCK)
}
if {$pb_range ne "off"} {
  set pb_cells "u_core u_imem u_dmem"
  if {[info exists ::env(REF5_PBLOCK_CELLS)] && $::env(REF5_PBLOCK_CELLS) ne ""} {
    set pb_cells $::env(REF5_PBLOCK_CELLS)
  }
  create_pblock p_ref5
  add_cells_to_pblock p_ref5 [get_cells -quiet $pb_cells]
  resize_pblock p_ref5 -add $pb_range
  puts "REF5_PBLOCK=$pb_range CELLS=$pb_cells"
} else {
  puts "REF5_PBLOCK=off"
}

opt_design

set place_dir "WLDrivenBlockPlacement"
if {[info exists ::env(REF5_PLACE_DIR)] && $::env(REF5_PLACE_DIR) ne ""} {
  set place_dir $::env(REF5_PLACE_DIR)
}
set route_dir "Default"
if {[info exists ::env(REF5_ROUTE_DIR)] && $::env(REF5_ROUTE_DIR) ne ""} {
  set route_dir $::env(REF5_ROUTE_DIR)
}
set do_phys 0
if {[info exists ::env(REF5_PHYS_OPT)] && $::env(REF5_PHYS_OPT) ne ""} { set do_phys 1 }
puts "REF5_PLACE_DIR=$place_dir"
puts "REF5_ROUTE_DIR=$route_dir"
puts "REF5_PHYS_OPT=$do_phys"

place_design -directive $place_dir
if {$do_phys} { phys_opt_design -directive AggressiveExplore }
route_design -directive $route_dir
if {$do_phys} { phys_opt_design -directive AggressiveExplore }

# ---- 报告 (规范位置 ref5/timing.rpt + util.rpt, 另存一份带 tag 的) ----
report_timing_summary -file "$dir/timing.rpt"
report_utilization   -file "$dir/util.rpt"
report_timing_summary -file "$rdir/timing.rpt"
report_utilization   -file "$rdir/util.rpt"

# ============================================================================
# 关键数字直接打到 stdout (省得每次手工翻报告)
# ============================================================================
set path [get_timing_paths -delay_type max -max_paths 1 -quiet]
if {[llength $path] > 0} {
  set wns [get_property SLACK $path]
  puts "REF5_WNS=$wns"
  puts "REF5_FMAX_MHZ=[format %.3f [expr {1000.0 / (20.0 - $wns)}]]"
  puts "REF5_PATH_DELAY=[get_property DATAPATH_DELAY $path]"
  puts "REF5_PATH_LOGIC=[get_property DATAPATH_LOGIC_DELAY $path]"
  puts "REF5_PATH_ROUTE=[get_property DATAPATH_NET_DELAY $path]"
  puts "REF5_PATH_LEVELS=[get_property LOGIC_LEVELS $path]"
  puts "REF5_PATH_SRC=[get_property STARTPOINT_PIN $path]"
  puts "REF5_PATH_DST=[get_property ENDPOINT_PIN $path]"
} else {
  puts "REF5_WNS=NOPATH"
}

# 前 8 条路径一览 (看关键路径是不是换位置了 —— 判断改动是否真的生效)
set n 0
foreach p [get_timing_paths -delay_type max -max_paths 8 -quiet] {
  incr n
  puts "REF5_TOP$n=[format %.3f [get_property SLACK $p]]ns L=[get_property LOGIC_LEVELS $p] [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
}

set luts   [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == LUT}]]
set ffs    [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set brams  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB*}]]
set lutram [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAM32* || REF_NAME =~ RAM64*}]]
puts "REF5_LUT_CELLS=$luts"
puts "REF5_FF_CELLS=$ffs"
puts "REF5_RAMB_CELLS=$brams"
puts "REF5_LUTRAM_CELLS=$lutram"
puts "REF5_OK"
