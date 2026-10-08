# ============================================================================
# ref5/probe_regions.tcl — 只查器件资源分布, 不综合/不实现 (秒级)
#   目的: 为 Pblock 选地形 —— 需要同时装得下 SLICE 和 RAMB36 的时钟区域。
# ============================================================================
link_design -part xc7a100tfgg484-2
foreach r [get_clock_regions] {
  set sites  [get_sites -quiet -of_objects [get_clock_regions $r]]
  set nsl    [llength [filter $sites {SITE_TYPE =~ SLICE*}]]
  set nram   [llength [filter $sites {SITE_TYPE =~ RAMB36*}]]
  set ndsp   [llength [filter $sites {SITE_TYPE =~ DSP48*}]]
  puts "REGION $r SLICE=$nsl RAMB36=$nram DSP=$ndsp"
}
puts "PROBE_OK"
