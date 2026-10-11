# Read back the packed CRC verdict + tick count after the CoreMark run.
# ila_ctrl[7:0]: 7=mmcm_locked 6=done 5=mark 4=redirect 3=stall 2=illegal 1=pass 0=fail
# (bit7 was constant 0, now = mmcm_locked: 0 => MMCM not locked / reset never released;
#  1 => locked. Expected value once locked and finished = 0xC2 = locked|done|pass.
#  The software bits are unchanged: 0x42 still means done=1,pass=1,fail=0.)
#
# NO TRIGGER IS SET ON PURPOSE. The probe default is eq8'hXX (don't care) which
# means "always true", so the capture starts as soon as it is armed.
# An exact-match trigger such as eq8'h40 does NOT work here: when the program
# finishes, pass_r is also 1 (crt0 wrote tohost), so ila_ctrl is 0x42, not 0x40.
#
# TRIGGER_COMPARE_VALUE format notes (Vivado 2018.3):
#   needs the comparison prefix and must match the probe width:
#     eq8'h40        OK
#     8'h40          -> Invalid logic operator '8'
#     01000000       -> No apostrophe specified
#     eq16'h0040     -> wrong bit count
#
# ---------------------------------------------------------------------------
# X-09: the wait time is no longer a magic constant. It is read from
#   sim/prog/<prog>.build.json  (fields: prog, iterations, expect_tick,
#   wait_seconds, clk_hz) written by tools/mk_cm_hw.py -- the SAME file the
#   harness reads. If it is missing we fall back to the old constant and say so
#   loudly (CAPTURE_MANIFEST_FALLBACK=1).
# X-02: after the CSV is written we also write results/ila_done.capture.json --
#   the "this capture really happened" witness, stamped with the CSV's sha256,
#   the bitstream's sha256 and the RTL digest. mtime alone could be forged by a
#   plain `git checkout` of the tracked CSV.
# Keep this file PURE ASCII (Vivado Tcl requirement, PITFALLS R21).
# ---------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
puts "CAP_ROOT=$root"

# ===========================================================================
# Shared helpers (pure Tcl 8.5 -- Vivado 2018.3 ships Tcl 8.5.14).
# ===========================================================================
proc br_tmpdir {} {
  if {[info exists ::env(TEMP)] && $::env(TEMP) ne ""} { return $::env(TEMP) }
  return [pwd]
}

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
# Returns lowercase hex, or "" when it cannot be computed -> written as null.
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

# Same file set and same algorithm as ILA_RTL_SHA in fpga/build_ila.tcl, so the
# two digests are directly comparable (X-10 cross-check).
proc br_rtl_sv_files {root} {
  set out {}
  foreach d [list $root $root/fpga] {
    foreach f [lsort [glob -nocomplain -directory $d *.sv]] {
      lappend out [file normalize $f]
    }
  }
  return [lsort $out]
}

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

proc br_relpath {root path} {
  set rootn [string map {\\ /} [file normalize $root]]
  set pn [string map {\\ /} [file normalize $path]]
  if {[string first "$rootn/" $pn] == 0} {
    return [string range $pn [expr {[string length $rootn] + 1}] end]
  }
  return $pn
}

# ---- strict JSON output helpers -------------------------------------------
proc br_json_escape {s} {
  return [string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $s]
}
proc br_json_str {s} { return "\"[br_json_escape $s]\"" }
proc br_json_num {v} {
  if {[regexp {^-?[0-9]+(\.[0-9]+)?$} $v]} { return $v }
  return null
}
proc br_json_sha {v} {
  if {$v eq ""} { return null }
  return "\"[br_json_escape $v]\""
}

# ===========================================================================
# Run parameters: single source of truth (X-09).
# ===========================================================================
set PROG         cm_hw
set ITERATIONS   3000
set EXPECT_TICK  1239100117
set WAIT_SECONDS 22
set CLK_HZ       70000000
set FALLBACK     0
set BUILD_JSON "$root/sim/prog/$PROG.build.json"
set JINFO [br_read_flat_json $BUILD_JSON]
if {[dict size $JINFO] == 0} {
  set FALLBACK 1
  puts "CAPTURE_JSON=absent ($BUILD_JSON)"
  puts "CAPTURE_MANIFEST_FALLBACK=1 iterations=$ITERATIONS expect_tick=$EXPECT_TICK wait_seconds=$WAIT_SECONDS clk_hz=$CLK_HZ"
} else {
  if {[dict exists $JINFO prog]} { set PROG [dict get $JINFO prog] }
  foreach k {iterations expect_tick wait_seconds clk_hz} {
    if {[dict exists $JINFO $k]} { set [string toupper $k] [dict get $JINFO $k] }
  }
  puts "CAPTURE_JSON=present prog=$PROG iterations=$ITERATIONS expect_tick=$EXPECT_TICK wait_seconds=$WAIT_SECONDS clk_hz=$CLK_HZ"
}
if {![regexp {^-?[0-9]+(\.[0-9]+)?$} $WAIT_SECONDS]} {
  puts "CAPTURE_WARN: wait_seconds='$WAIT_SECONDS' is not numeric -> using 22 s"
  set WAIT_SECONDS 22
}
set WAIT_MS [expr {int(round($WAIT_SECONDS * 1000.0))}]
puts "CAPTURE_WAIT_MS=$WAIT_MS"
if {$WAIT_MS < 10000} {
  puts "CAPTURE_WARN: wait_seconds=$WAIT_SECONDS is too short for a >=10 s CoreMark run"
}

set BIT_FILE  "$root/fpga/ila_proj.runs/impl_1/top_a100t.bit"
set LTX_FILE  "$root/fpga/ila_proj.runs/impl_1/top_a100t.ltx"
set CSV_FILE  "$root/results/ila_done.csv"
if {![file exists $BIT_FILE]} {
  puts "CAPTURE_ERROR: ILA bitstream not found: $BIT_FILE"
  puts "CAPTURE_HINT: run fpga/build_ila.bat first (a timing violation deletes this file on purpose)."
  error "CAPTURE_ERROR: no ILA bitstream"
}

open_hw
connect_hw_server
open_hw_target
set TGT_STR [current_hw_target]
puts "CAPTURE_TARGET=$TGT_STR"
current_hw_device [lindex [get_hw_devices] 0]
set DEV_STR [lindex [get_hw_devices] 0]
set IDCODE "unknown"
if {[catch {set IDCODE [get_property IDCODE [current_hw_device]]} e]} {
  if {[catch {set IDCODE [get_property REGISTER.IDCODE [current_hw_device]]} e2]} {
    set IDCODE "unknown"
  }
}
puts "CAPTURE_DEVICE=$DEV_STR IDCODE=$IDCODE"
set_property PROGRAM.FILE $BIT_FILE [current_hw_device]
set_property PROBES.FILE $LTX_FILE [current_hw_device]
program_hw_devices [current_hw_device]
puts "PROGRAMMED"
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes true [current_hw_device]
# Wait until the CoreMark run has finished. The value comes from the manifest:
#   ITERATIONS=3000 -> ~1.239e9 cycles -> 17.70 s @70MHz, wait 22 s (4.3 s margin).
after $WAIT_MS
puts "WAITED"
set ila [lindex [get_hw_ilas -of_objects [current_hw_device]] 0]
if {$ila eq ""} { error "NO_ILA_FOUND" }
puts "ILA = $ila"
reset_hw_ila $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
run_hw_ila $ila
puts "ARMED"
wait_on_hw_ila -timeout 60 $ila
upload_hw_ila_data $ila
# -force: results/ila_done.csv must be explicitly overwritten when it exists,
# otherwise Labtoolstcl 44-54 errors out.
write_hw_ila_data -force -csv_file $CSV_FILE hw_ila_data_1

# Self-check: confirm the file was really refreshed by THIS capture.
# Printing CAPTURE_OK alone is not enough -- if the write silently failed the script
# can still look successful, and the downstream `hw` subcommand would then parse an
# OLD file and report the PREVIOUS run's result (measured: after the board dropped
# off, it still printed "hardware verify PASS"). Checking mtime makes
# "did the file actually refresh" a hard criterion.
if {![file exists $CSV_FILE]} { error "CAPTURE_NO_FILE: $CSV_FILE not found" }
set mt  [file mtime $CSV_FILE]
set age [expr {[clock seconds] - $mt}]
puts "CSV_MTIME=[clock format $mt -format {%Y-%m-%d %H:%M:%S}] AGE_SEC=$age"
if {$age > 120} { error "CAPTURE_STALE: csv is $age s old -> this capture did not land" }

# ===========================================================================
# X-02 / X-09 / M-03: capture manifest next to the CSV.
# ---------------------------------------------------------------------------
# results/ila_done.capture.json is the "this run really happened" witness: it is
# written by the same Vivado invocation that wrote the CSV, it is NOT tracked by
# git (so a `git checkout` cannot create one), and it carries the CSV sha256 plus
# the exact run parameters (iterations / clk_hz / expect_tick / wait_seconds) and
# the RTL digest. The harness refuses to conclude "board verified" from a CSV
# whose witness is missing or whose hashes do not match.
# Strict JSON, UTF-8, no BOM, LF only.
# ===========================================================================
set CSV_SHA [br_sha256_file $CSV_FILE]
set BIT_SHA [br_sha256_file $BIT_FILE]
set HS [br_rtl_sha $root [br_rtl_sv_files $root]]
set RTL_SHA [lindex $HS 0]
set RTL_N   [lindex $HS 1]
set RTL_SHA_SHOW $RTL_SHA
if {$RTL_SHA_SHOW eq ""} { set RTL_SHA_SHOW "UNAVAILABLE" }
puts "CAPTURE_CSV_SHA=$CSV_SHA"
puts "CAPTURE_BIT_SHA=$BIT_SHA"
puts "CAPTURE_RTL_SHA=$RTL_SHA_SHOW"
puts "CAPTURE_RTL_SHA_FILES=$RTL_N"

set MAN_FILE "$root/results/ila_done.capture.json"
set fh [open $MAN_FILE w]
fconfigure $fh -translation lf -encoding utf-8
puts $fh "{"
puts $fh "  \"schema\": 1,"
puts $fh "  \"captured_at_epoch\": [clock seconds],"
puts $fh "  \"captured_at_local\": [br_json_str [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]],"
puts $fh "  \"csv\": [br_json_str [br_relpath $root $CSV_FILE]],"
puts $fh "  \"csv_sha256\": [br_json_sha $CSV_SHA],"
puts $fh "  \"prog\": [br_json_str $PROG],"
puts $fh "  \"iterations\": [br_json_num $ITERATIONS],"
puts $fh "  \"clk_hz\": [br_json_num $CLK_HZ],"
puts $fh "  \"expect_tick\": [br_json_num $EXPECT_TICK],"
puts $fh "  \"wait_seconds\": [br_json_num $WAIT_SECONDS],"
puts $fh "  \"jtag_target\": [br_json_str $TGT_STR],"
puts $fh "  \"device\": [br_json_str $DEV_STR],"
puts $fh "  \"idcode\": [br_json_str $IDCODE],"
puts $fh "  \"bit\": [br_json_str [br_relpath $root $BIT_FILE]],"
puts $fh "  \"bit_sha256\": [br_json_sha $BIT_SHA],"
puts $fh "  \"rtl_sha256\": [br_json_sha $RTL_SHA],"
puts $fh "  \"rtl_sha256_files\": $RTL_N,"
puts $fh "  \"fallback_constants\": $FALLBACK,"
puts $fh "  \"tool\": \"ila_cap_done.tcl\""
puts $fh "}"
close $fh

# Self-check the manifest we just wrote: it must exist and re-parse into the
# expected keys, otherwise the witness is worthless (R1: no silent failures).
# csv_sha256 / rtl_sha256 may be null when no digest tool is available -- that is
# recorded and accepted, but a PRESENT hash must match.
set back [br_read_flat_json $MAN_FILE]
foreach k {schema captured_at_epoch csv prog iterations clk_hz expect_tick wait_seconds} {
  if {![dict exists $back $k]} {
    puts "CAPTURE_MANIFEST_ERROR=missing_key:$k"
    error "capture manifest incomplete: missing $k"
  }
}
if {$CSV_SHA ne ""} {
  if {![dict exists $back csv_sha256] || [dict get $back csv_sha256] ne $CSV_SHA} {
    puts "CAPTURE_MANIFEST_ERROR=csv_sha256_mismatch"
    error "capture manifest csv_sha256 does not match the CSV"
  }
} else {
  puts "CAPTURE_MANIFEST_WARN=csv_sha256_null (no sha256 tool available)"
}
if {$RTL_SHA ne "" && ![dict exists $back rtl_sha256]} {
  puts "CAPTURE_MANIFEST_ERROR=rtl_sha256_missing"
  error "capture manifest lost the RTL digest"
}
puts "CAPTURE_MANIFEST=$MAN_FILE"
puts "CAPTURE_MANIFEST_OK"
puts "CAPTURE_OK"
