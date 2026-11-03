# ============================================================================
# fpga/build_ila.tcl -- build the ILA ("read the result back yourself") image
# in PROJECT mode.
# ----------------------------------------------------------------------------
# Why project mode: the ILA IP needs Vivado's IP generation flow, which is most
# reliable as a project.
# Why an ILA at all: this board's UART is unreachable (the FT2232H only exposes
# D2XX, no COM port), so the only way to read "did it finish + how many cycles"
# back is ILA over JTAG. That is what makes unattended verification possible.
# Trigger: the software writes MMIO_MARK at the start of the CoreMark measured
# region -> rising edge on probe2[5].
# Benchmark image: see sim/prog/cm_hw.build.json (X-09). ITERATIONS=3000 ->
# about 1.239e9 cycles -> 17.70 s at 70 MHz. The capture script
# fpga/ila_cap_done.tcl READS wait_seconds FROM THAT SAME FILE, so the wait time
# is no longer a magic constant manually kept in sync in three places.
# Note: the scoring build (build.tcl) carries no ILA; the CPU core itself
# contains no vendor IP.
# This file MUST stay PURE ASCII (PITFALLS R21).
# ============================================================================
set part xc7a100tfgg484-2
# ---- E-02: no hardcoded absolute paths -------------------------------------
# Derive the repo root from this script's own location; every path below is
# built from $root, so the flow survives a move to another machine/directory
# (the old file repeated "D:/USER/Desktop/FPGA/FPGA" in five places).
set root [file normalize [file join [file dirname [info script]] ..]]
puts "ILA_BUILD_ROOT=$root"

# ===========================================================================
# Shared helpers (pure Tcl 8.5 -- Vivado 2018.3 ships Tcl 8.5.14).
# ===========================================================================
proc br_tmpdir {} {
  if {[info exists ::env(TEMP)] && $::env(TEMP) ne ""} { return $::env(TEMP) }
  return [pwd]
}

# Flat-JSON reader: {"key": scalar, ...}, no nesting and no escapes.
# A missing/unreadable file returns an empty dict so callers fall back to their
# constants AND warn -- never a silently wrong number.
proc br_read_flat_json {path} {
  set d [dict create]
  if {![file exists $path]} { return $d }
  if {[catch {set fh [open $path r]} e]} {
    puts "BR_JSON_WARN: cannot open $path : $e"
    return $d
  }
  set txt [read $fh]
  close $fh
  foreach {_full k v} [regexp -all -inline {"([A-Za-z_][A-Za-z0-9_]*)"\s*:\s*("[^"]*"|-?[0-9]+(?:\.[0-9]+)?)} $txt] {
    dict set d $k [string trim $v "\""]
  }
  return $d
}

# SHA256 of one file via certutil (Tcl 8.5 has no built-in digest command).
# Returns lowercase hex, or "" when it cannot be computed -- callers must
# record the failure instead of pretending the hash exists.
proc br_sha256_file {path} {
  if {![file exists $path]} { return "" }
  if {[catch {set out [exec certutil -hashfile $path SHA256]} e]} { return "" }
  foreach l [split $out "\n"] {
    set l [string trim $l]
    set c [string map {" " ""} $l]
    if {[string length $c] == 64 && [regexp {^[0-9a-fA-F]{64}$} $c]} {
      return [string tolower $c]
    }
  }
  return ""
}

# The files whose content defines "which RTL version this is": every .sv that
# gets synthesised, i.e. repo-root *.sv + fpga/*.sv. Sorted, absolute.
proc br_rtl_sv_files {root} {
  set out {}
  foreach d [list $root $root/fpga] {
    foreach f [lsort [glob -nocomplain -directory $d *.sv]] {
      lappend out [file normalize $f]
    }
  }
  return [lsort $out]
}

# ---- X-10 / R41: combined RTL hash -----------------------------------------
# SHA256 over "V1 header + (relpath + bytes) for every file", so ONE digest
# covers both the contents and the file set. Returned as {hex n rels}; hex is
# "" when no digest tool is available (recorded, not hidden). The SAME
# algorithm is used by ila_cap_done.tcl when it writes the capture manifest, so
# the harness can prove which RTL produced a given board result.
proc br_rtl_sha {root files} {
  set body "FPGA-RTL-SHA-V1\n"
  set rels {}
  set n 0
  set rootn [string map {\\ /} [file normalize $root]]
  foreach f $files {
    if {![file exists $f]} {
      puts "BR_RTL_SHA_WARN=missing:$f"
      continue
    }
    set fn [string map {\\ /} [file normalize $f]]
    set rel $fn
    if {[string first "$rootn/" $fn] == 0} {
      set rel [string range $fn [expr {[string length $rootn] + 1}] end]
    }
    if {[catch {
      set fh [open $f rb]
      fconfigure $fh -translation binary
      append body "$rel\n"
      append body [read $fh]
      close $fh
    } e]} {
      puts "BR_RTL_SHA_WARN=read_failed:$rel:$e"
      continue
    }
    lappend rels $rel
    incr n
  }
  set tmp [file join [br_tmpdir] "fpga_rtl_sha_[pid].bin"]
  set hex ""
  if {[catch {
    set fh [open $tmp wb]
    fconfigure $fh -translation binary
    puts -nonewline $fh $body
    close $fh
    set out [exec certutil -hashfile $tmp SHA256]
    foreach l [split $out "\n"] {
      set l [string trim $l]
      set c [string map {" " ""} $l]
      if {[string length $c] == 64 && [regexp {^[0-9a-fA-F]{64}$} $c]} {
        set hex [string tolower $c]
        break
      }
    }
  } e]} {
    puts "BR_RTL_SHA_WARN=hash_failed:$e"
  }
  catch {file delete -force $tmp}
  return [list $hex $n $rels]
}

# ---- X-06 / X-09: hard timing-closure gate (see build.tcl for the rationale)
proc br_timing_gate {rpt tag} {
  set met "NA"
  if {[file exists $rpt]} {
    if {[catch {set fh [open $rpt r]} e]} {
      puts "${tag}_TIMING_WARN=open_failed:$e"
    } else {
      set txt [read $fh]
      close $fh
      if {[string first "All user specified timing constraints are met." $txt] >= 0} {
        set met 1
      } elseif {[string first "Timing constraints are not met." $txt] >= 0} {
        set met 0
      }
    }
  } else {
    puts "${tag}_TIMING_WARN=report_missing:$rpt"
  }
  set wns "NA"
  set whs "NA"
  if {[catch {
    set p [get_timing_paths -setup -max_paths 1 -nworst 1 -quiet]
    if {[llength $p] > 0} { set wns [get_property SLACK [lindex $p 0]] }
  } e]} { puts "${tag}_TIMING_WARN=wns_query_failed:$e" }
  if {[catch {
    set p [get_timing_paths -hold -max_paths 1 -nworst 1 -quiet]
    if {[llength $p] > 0} { set whs [get_property SLACK [lindex $p 0]] }
  } e]} { puts "${tag}_TIMING_WARN=whs_query_failed:$e" }
  puts "${tag}_TIMING_CONSTRAINTS_MET=$met"
  puts "${tag}_TIMING_WNS=$wns"
  puts "${tag}_TIMING_WHS=$whs"
  set ok 1
  if {$met ne "1"} { set ok 0 }
  if {$wns ne "NA"} {
    if {[catch {set wv [expr {double($wns)}]} e]} {
      puts "${tag}_TIMING_WARN=wns_unparsed:$wns"
    } elseif {$wv < 0.0} { set ok 0 }
  }
  if {$whs ne "NA"} {
    if {[catch {set hv [expr {double($whs)}]} e]} {
      puts "${tag}_TIMING_WARN=whs_unparsed:$whs"
    } elseif {$hv < 0.0} { set ok 0 }
  }
  return $ok
}

# ===========================================================================
# X-09: run parameters from sim/prog/cm_hw.build.json (written by
# tools/mk_cm_hw.py). Fallback = the constants this file used to hardcode, with
# an explicit warning so nobody mistakes a stale fallback for a measured value.
# ===========================================================================
set ILA_PROG       cm_hw
set ITERATIONS     3000
set EXPECT_TICK    1239100117
set WAIT_SECONDS   22
set CLK_HZ         70000000
set BUILD_JSON     "$root/sim/prog/$ILA_PROG.build.json"
set JINFO [br_read_flat_json $BUILD_JSON]
if {[dict size $JINFO] == 0} {
  puts "ILA_JSON=absent ($BUILD_JSON)"
  puts "ILA_JSON_FALLBACK=1 iterations=$ITERATIONS expect_tick=$EXPECT_TICK wait_seconds=$WAIT_SECONDS clk_hz=$CLK_HZ"
} else {
  if {[dict exists $JINFO prog]} { set ILA_PROG [dict get $JINFO prog] }
  foreach k {iterations expect_tick wait_seconds clk_hz} {
    if {[dict exists $JINFO $k]} { set [string toupper $k] [dict get $JINFO $k] }
  }
  puts "ILA_JSON=present prog=$ILA_PROG iterations=$ITERATIONS expect_tick=$EXPECT_TICK wait_seconds=$WAIT_SECONDS clk_hz=$CLK_HZ"
}
set ILA_IMEM "$root/sim/prog/$ILA_PROG.hex"
set ILA_DMEM "$root/sim/prog/$ILA_PROG.dmem.hex"
if {![file exists $ILA_IMEM]} {
  puts "ILA_BUILD_ERROR: missing imem image $ILA_IMEM"
  error "missing imem image $ILA_IMEM (run tools/mk_cm_hw.py)"
}
if {![file exists $ILA_DMEM]} {
  puts "ILA_BUILD_ERROR: missing dmem image $ILA_DMEM (the image would bake in all-zero .data)"
  error "missing dmem image $ILA_DMEM (run tools/mk_cm_hw.py)"
}

# ===========================================================================
# X-10 / R33: PURGE A DAMAGED PROJECT TREE BEFORE create_project.
# ---------------------------------------------------------------------------
# `create_project -force` only overwrites the .xpr. After a failed IP
# generation the tree stays broken (ip/ila_0 half-generated, stale .runs/.cache/
# .hw/.ip_user_files) and EVERY later build then fails in the same place with a
# misleading "couldn't read file .../msgcat-1.5.1.tm: no such file or
# directory" -- which looks like a broken Vivado install but is not. This has
# already cost two full build cycles (PITFALLS R33), so it is no longer a manual
# step. The .bit/.ltx of the previous build are removed with the run directory:
# a stale ILA image must never be left around as "the" artifact (R28).
# ===========================================================================
foreach d {ila_proj.srcs ila_proj.runs ila_proj.cache ila_proj.hw ila_proj.ip_user_files} {
  set p "$root/fpga/$d"
  if {[file exists $p]} {
    puts "ILA_PURGE=$d"
    file delete -force $p
  }
}

create_project -force -part $part $root/fpga/ila_proj

# File list must be on one line: Tcl backslash continuation gets split into
# separate commands here.
add_files -norecurse [list "$root/rv32_pkg.sv" "$root/nn_pkg.sv" "$root/nn_rom_pkg.sv" "$root/alu.sv" "$root/branch_unit.sv" "$root/control_unit.sv" "$root/imm_gen.sv" "$root/pc.sv" "$root/regfile.sv" "$root/id_ex_reg.sv" "$root/ex_mem_reg.sv" "$root/mem_wb_reg.sv" "$root/hazard_unit.sv" "$root/load_store_unit.sv" "$root/imem.sv" "$root/dmem.sv" "$root/btb.sv" "$root/bht.sv" "$root/ras.sv" "$root/muldiv.sv" "$root/csr_file.sv" "$root/core.sv" "$root/gemm_accel.sv" "$root/nn_mem.sv" "$root/nn_conv_engine.sv" "$root/nn_seq.sv" "$root/nn_subsys.sv" "$root/nn_wload.sv" "$root/nn_tilecache.sv" "$root/fpga/mmio_subsys.sv" "$root/fpga/top_a100t.sv"]
add_files -fileset constrs_1 -norecurse [list "$root/fpga/daVinciPro.xdc"]

# ---- X-10 / R41: record WHICH RTL went into this bitstream ------------------
# A combined SHA256 over (relative path + bytes) of the synthesised .sv set,
# printed into the build log. The harness compares the value recorded before the
# build with the one after it and refuses to program a bitstream produced from a
# tree that was edited mid-build (R41: parallel writers already caused one
# "which version was that?" near-miss). The same algorithm is used by
# ila_cap_done.tcl, which stamps the digest into results/ila_done.capture.json.
set HASHED [br_rtl_sv_files $root]
set HS [br_rtl_sha $root $HASHED]
set ILA_RTL_SHA [lindex $HS 0]
if {$ILA_RTL_SHA eq ""} { set ILA_RTL_SHA "UNAVAILABLE" }
puts "ILA_RTL_SHA=$ILA_RTL_SHA"
puts "ILA_RTL_SHA_FILES=[lindex $HS 1]"
puts "ILA_RTL_SHA_LIST=[lindex $HS 2]"
# Drift check: the hashed set must be the set that was actually added.
set n_added 0
if {![catch {
  foreach f [get_files -quiet -of_objects [get_filesets sources_1]] {
    if {[string match "*.sv" $f]} { incr n_added }
  }
} e]} {
  puts "ILA_RTL_ADDED_SV=$n_added"
  if {$n_added != [lindex $HS 1]} {
    puts "ILA_RTL_SHA_WARN=add_files_vs_hashed_set_drift added=$n_added hashed=[lindex $HS 1]"
  }
} else {
  puts "ILA_RTL_SHA_WARN=add_files_query_failed:$e"
}

# dmem must carry the initial-value image: this core is Harvard, so .data/rodata
# cannot be copied out of imem by crt0.
# [The path MUST be quoted] verilog_define expands the value verbatim into a
# macro; without quotes `IMEM_INIT_FILE expands to a bare path and Vivado reports
# "syntax error near /" at the $readmemh line, which is very hard to trace back.
# Architecture macro pass-through. imem/dmem both use block RAM in the shipped
# configuration, so the DEFAULT here (no macro) is already the BRAM build.
# `IMEM_COMB_READ=1` is the fallback (combinational LUT ROM) for A-B compares.
# Without this gate "board-verified" could silently mean "verified WITHOUT the
# macro" (PITFALLS R18 -- that already produced a false PASS once).
set ARCH_DEFS ""
if {[info exists ::env(IMEM_COMB_READ)] && $::env(IMEM_COMB_READ) ne ""} {
  append ARCH_DEFS " IMEM_COMB_READ=1"
  puts "ILA_BUILD_IMEM_COMB_READ=1"
} else {
  puts "ILA_BUILD_IMEM_BRAM=1"
}
set_property verilog_define "USE_ILA=1 IMEM_INIT_FILE=\"$ILA_IMEM\" DMEM_INIT_FILE=\"$ILA_DMEM\"$ARCH_DEFS" [current_fileset]

create_ip -name ila -vendor xilinx.com -library ip -module_name ila_0
# 【采集深度 2048 -> 1024, 2026-10-16】判读只看**最后一行**(程序停在结尾 `j .`,
# 全部行都是同一个终态), 深度对证据几乎没有贡献, 却要 2048x104bit ~= 6 块 RAMB36 的
# 布线/拥塞。150 档实测: **评分流 +0.018 而 ILA 流 -0.293**(差 0.311ns, 而 138.75 档
# 只差 0.023) => 调试核在高频下开始竞争布线。
#   [!] IP 只接受 C_DATA_DEPTH 属于 {1024,2048,4096,...} —— 我第一版写 512, IP 报
#       `IP_Flow 19-3461 Value '512' is out of the range` (有效值从 1024 起)。
# 同时把 C_INPUT_PIPE_STAGES 2 -> 4: 让调试核的输入再深两级流水, 进一步把它对被观测
# 信号的影响隔离出去(计数/判读都不依赖 ILA 的采样延迟 —— 我们读的是终态快照)。
set_property -dict [list CONFIG.C_NUM_OF_PROBES {4} CONFIG.C_PROBE0_WIDTH {32} CONFIG.C_PROBE1_WIDTH {32} CONFIG.C_PROBE2_WIDTH {8} CONFIG.C_PROBE3_WIDTH {32} CONFIG.C_DATA_DEPTH {1024} CONFIG.C_INPUT_PIPE_STAGES {4}] [get_ips ila_0]

update_compile_order -fileset sources_1

# ===========================================================================
# Run strategy + floorplan: align the ILA project flow with the SCORING flow
# ---------------------------------------------------------------------------
# Measured 2026-10-11: this project flow had NO strategy set at all (synth_1 and
# impl_1 both ran Vivado defaults). That was enough at 105 MHz (ILA_TIMING=PASS,
# WNS +0.505) but FAILED at 128.125 MHz: WNS -0.659 / TNS -40.646 / 234 failing
# endpoints, so the gate correctly removed the bitstream and refused to program.
# The scoring flow (build.tcl) uses: synth -directive AlternateRoutability, a
# floorplan on `u_core` at CLOCKREGION_X0Y1:X2Y2, and explicit place/phys_opt/
# route directives. Without porting them here, "the netlist verified on the
# board" is NOT the same netlist as "the one we score" -- that is its own kind
# of evidence corruption (the whole point of the on-board loop is to verify the
# delivered configuration).
# NOTE: keep this file PURE ASCII (same convention as build.tcl).
# ===========================================================================
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE AlternateRoutability [get_runs synth_1]
# ---- 【把评分流的综合选项同步到工程流】 ---------------------------------------------
# 2026-10-16: 评分流靠 `-no_lc` + `-fanout_limit N` 在 150 档拿到关键余量。
# 若上板流不带同样的选项 => **上板验证的网表 != 评分的网表**, 证据链失真
# (这正是 306-310 行立的规矩)。
#
# 【真名是查出来的, 不是猜的】先试 `STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS` 失败
# (两种拼写都报 Common 17-170)。最后用 list_property 把 synth_1 的属性全打出来,
# 发现这两个选项**本来就是一等属性**:
#     STEPS.SYNTH_DESIGN.ARGS.NO_LC        (0/1)      <- synth_design -no_lc
#     STEPS.SYNTH_DESIGN.ARGS.FANOUT_LIMIT (默认 10000) <- synth_design -fanout_limit
# => 根本不需要 MORE OPTIONS。教训: 属性名不要猜, 用 list_property 打出来。
if {[info exists ::env(ILA_NO_LC)] && $::env(ILA_NO_LC) eq "1"} {
  set_property STEPS.SYNTH_DESIGN.ARGS.NO_LC 1 [get_runs synth_1]
  puts "ILA_NO_LC=1"
}
if {[info exists ::env(ILA_FANOUT_LIMIT)] && $::env(ILA_FANOUT_LIMIT) ne ""} {
  set_property STEPS.SYNTH_DESIGN.ARGS.FANOUT_LIMIT $::env(ILA_FANOUT_LIMIT) [get_runs synth_1]
  puts "ILA_FANOUT_LIMIT=$::env(ILA_FANOUT_LIMIT)"
}
if {[info exists ::env(ILA_PLACE_DIR)] && $::env(ILA_PLACE_DIR) ne ""} {
  set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE $::env(ILA_PLACE_DIR) [get_runs impl_1]
  puts "ILA_PLACE_DIR=$::env(ILA_PLACE_DIR)"
} else {
  set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt [get_runs impl_1]
}
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED 1 [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
# The scoring flow calls phys_opt_design a SECOND time AFTER route_design
# (build.tcl: `place -> phys_opt -> route -> phys_opt`). Project mode does NOT
# enable post-route phys_opt by default, and that step is very likely the bulk of
# the gap: porting only the synth/place/route directives recovered just 0.029 ns
# of the 0.659 ns shortfall. RVCoreP's implementation strategy is literally named
# Performance_ExplorePostRoutePhysOpt for this reason.
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED 1 [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
puts "ILA_RUN_STRATEGY=synth:AlternateRoutability place:ExtraTimingOpt phys_opt:AggressiveExplore route:AggressiveExplore post_route_phys_opt:AggressiveExplore"

# Floorplan: ILA project only. The constraint is generated into .fpga-cache/
# (gitignored) so it neither touches the scoring flow's daVinciPro.xdc nor adds
# a file to the repo. Same region as build.tcl's `create_pblock p_opt`.
file mkdir "$root/.fpga-cache"
set ILA_PB_XDC "$root/.fpga-cache/ila_pblock.xdc"
set fpb [open $ILA_PB_XDC w]
puts $fpb "# generated by fpga/build_ila.tcl -- same region as build.tcl's p_opt"
puts $fpb "create_pblock p_opt"
puts $fpb "add_cells_to_pblock \[get_pblocks p_opt\] \[get_cells -quiet u_core\]"
puts $fpb "resize_pblock \[get_pblocks p_opt\] -add {CLOCKREGION_X0Y1:CLOCKREGION_X2Y2}"
close $fpb
add_files -fileset constrs_1 -norecurse $ILA_PB_XDC
puts "ILA_PBLOCK=u_core @ CLOCKREGION_X0Y1:CLOCKREGION_X2Y2"

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "SYNTH FAILED" }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} { error "IMPL FAILED" }
open_run impl_1
report_timing_summary -file $root/fpga/timing_ila.rpt
# Per-hop detail for the worst paths. `report_timing_summary` only carries a handful
# of paths, so when this flow FAILS the gate we cannot tell WHICH family is short --
# that is exactly the evidence needed to decide "step the clock down" vs "fix RTL".
# 2026-10-11: at 128.125 MHz the ILA flow reported 210 failing endpoints but the
# summary kept only ~10 paths and no per-hop detail, so the failure families were
# unknowable after the run (the report gets overwritten by the next build).
# Mirrors build.tcl's own `timing_paths.rpt`/`timing_cells.rpt` diagnostics.
report_timing -max_paths 100 -nworst 2 -input_pins -nets -file $root/fpga/timing_ila_paths.rpt
puts "ILA_REPORT=timing_ila.rpt+timing_ila_paths.rpt"
report_utilization   -file $root/fpga/util_ila.rpt

# ===========================================================================
# X-09: TIMING GATE for the ILA image.
# ---------------------------------------------------------------------------
# The run above already wrote the bitstream (this is the proven 10-minute flow,
# and R33 shows how expensive it is to deviate from it), so the gate runs right
# after it and, when timing is NOT closed, DELETES the .bit/.ltx that
# ila_cap_done.tcl programs. A violating image can therefore never produce a
# "board-verified" result -- which was exactly the hole: the old script only
# asserted PROGRESS == 100%.
# ===========================================================================
set TIMING_OK [br_timing_gate $root/fpga/timing_ila.rpt ILA]
if {!$TIMING_OK} {
  puts "ILA_TIMING=FAIL"
  foreach f {top_a100t.bit top_a100t.ltx} {
    set p "$root/fpga/ila_proj.runs/impl_1/$f"
    if {[file exists $p]} {
      file delete -force $p
      puts "ILA_TIMING_PURGED=$f"
    }
  }
  error "ILA_TIMING=FAIL: timing constraints are NOT met -> ILA bitstream removed, do not program"
}
puts "ILA_TIMING=PASS"
puts "ILA_BUILD_OK"
