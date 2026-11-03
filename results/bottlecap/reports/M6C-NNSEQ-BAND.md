# M6c - nn_seq band loop + streaming prefetch control (task-17)

> Owner: npu-spec. Date: 2026-11-04. Scope: `nn_seq.sv` + `sim/tb_nn_seq.sv` + this report.
> Design basis: M4-TILECACHE.md appendix A (tile/band formulas), M3-WSTREAM.md section 2
> (pre_* interface), band_plan.json (2,391 bands, two IBUF classes), M5 job path (kept).
> Result: **PASS**. `tb_nn_seq` PASS with split-path stats; full `verify --force` PASS 20
> (old suite unchanged). Zero changes to engine/mem/tilecache/wload.
> All text in this report is ASCII-only.

## 0. Status snapshot

| Item | Result | Evidence |
|---|---|---|
| nn_seq band loop (per-op -> per-band engine starts) | implemented | nn_seq.sv state machine + Sec. 2 |
| Streaming prefetch (pre_*), W/Q pointer accumulate, bank flip | implemented | nn_seq.sv ports + Sec. 2 |
| tile[1]=band_en semantics (Lead 2026-11-04 revision) | implemented | nn_seq.sv:182, M4 appendix A note |
| zp_in from rom.aux0[7:0] (conv/dwconv) | implemented | nn_seq.sv:244 |
| nn_subsys u_seq tie-off of band ports | done (only that block) | nn_subsys.sv u_seq instantiation |
| tb_nn_seq: legacy strict assertions unchanged | PASS starts=112 cycles=336 | `.fpga-cache/logs/tb_nn_seq.log` |
| tb_nn_seq: synthetic band ROM + stub pre/tile/engine | PASS bands=4242 pre=112 eng=4242 cycles=72114 | same log |
| Error injection (wlen>128KiB, pre_err) -> E6 | PASS x2 | same log |
| 106-op n_bands reconciliation vs band_plan.json | 104/106 exact; 2 upsample (even-B rule) | Sec. 4 |
| Full regression | **PASS 20** (old 19 + slim unchanged) | `.fpga-cache/verify_full_m6c_final2.log` |

## 1. Changes

### 1.1 nn_seq.sv (band/streaming extension; legacy path untouched)
* New states (5-bit enum): `S_PRE0`, `S_PRE0_WAIT`, `S_BAND_INIT`, `S_BAND_FILL`,
  `S_BAND_ENG`, `S_BAND_DRAIN`, `S_BAND_FLUSH`, `S_OP_END`, `S_PRE_END`. Legacy
  `S_ISSUE/S_WAIT/S_NEXT` behavior is unchanged; a legacy op in a mixed ROM still issues
  exactly one engine start and accumulates cycles as before.
* Per-op mode select: `oband = rom.tile[1]` (band_en). `tile==0` = whole/direct path
  (YOLO ROM and bottlecap op0). `band_rows = tile[7:4]+1` (1..16).
* Per-band geometry implemented per appendix A:
  ```
  out_r0 = b*band_rows; br = min(band_rows, oh-out_r0)
  conv/dwconv: in_rows=(br-1)*stride+k; band_row0=out_r0*stride-pad
  add/copy   : k=1, stride=1, pad=0  (in_rows=br)
  upsample   : band_rows forced even; in_rows=br/2+1; band_row0=0
  rd0=max(band_row0,0); rd1=min(band_row0+in_rows, ih)
  in_rows/in_pad_top(rd0-band_row0)/in_rd_rows(rd1-rd0)
  in_base=arena_base+src+rd0*in_stride, out_base=arena_base+dst+out_r0*out_row_bytes
  in_row_bytes=(iw+2*pad)*ic_pad   (path A; PACKED3 exception uses iw*3)
  ```
* Engine descriptor in band mode (path A, zero engine changes): `pad=0`,
  `iw=iw+2*pad`, `ih=in_rows`, `src=dst=0`, `woff=qoff=0`, `ic/oc/ks/stride/flags`
  preserved; PACKED3 keeps `rom.pad/iw` (known limitation, Sec. 6).
* Prefetch/streaming: `w_ptr/q_ptr` accumulate `wlen/qlen` per op (ROM fields); per-op
  first prefetch through `S_PRE0`; next-op prefetch is issued at the current op's first
  band (`S_BAND_INIT`, b==0) and overlaps band compute; `pre_done` is latched (`pre_seen`)
  because it can arrive while the op is still running; bank flips only after `pre_done`.
  `pre_wlen<=131072`, `pre_qlen<=8192` are checked (violation -> err E6; note
  PRE_QLEN_MAX needs 14 bit because 8192 = 2^13).
* add_mode (tile[3]): tilecache fills aux(dst) band, `d_add_mode=1`, `d_aux_*` for the
  add accumulator; zp_in = sign-extended `rom.aux0[7:0]` for conv/dwconv, 0 for add/copy.
* Error codes: E6 for prefetch/length/tile error; E3 for wait-state guard timeouts;
  E4 job timeout unchanged. `done_ops` counts ops (not bands) in both paths.
* Two ROM read ports (current + look-ahead) for overlapped prefetch; `rom_mem` array name
  retained for TB hierarchical injection.

### 1.2 nn_subsys.sv (only the u_seq instantiation, Lead-approved)
`u_seq` band inputs tie-off: `pre_busy=0, pre_done=1, pre_err=0, band_ready=1,
band_done=1, tile_err=0, w_ddr_base/q_ddr_base/arena_ddr_base=0`; band outputs left
unconnected (M6 integration will re-wire). Legacy behavior unchanged (YOLO tile=0).

### 1.3 sim/tb_nn_seq.sv
Rewritten: DUT1 = real YOLO ROM legacy tests (strict assertions unchanged, engine err
injection kept); DUT2 = synthetic band ROM (112 entries = 8-case pattern x14, injected
via `dut_b.rom_mem[i]` after reset) with stub nn_wload (pre_*), stub nn_tilecache
(band_*), stub engine. Band tests assert per-band geometry vs an independent reference
model, engine desc fields, prefetch count/address/len/bank sequence, pointer
accumulation, Sigma n_bands engine starts, cycle accumulation, done/done_ops, and two
error injections. Stub timing: `pre_done` after 5 cycles (overlaps band compute),
`band_ready` 3 cycles after `band_start`, `band_done` 3 cycles after `engine_done`
(strict ordering), engine 4 cycles/band. TB clock is a 10 ns period (the old
`#5000` with 1 ns timescale was actually 10 us and is corrected; legacy cycle numbers
are unchanged because they count engine cycles, not wall time).

### 1.4 M4-TILECACHE.md appendix A
Added tile[1]=band_en revision note and an M6c implementation note (Lead request; only
that appendix paragraph touched).

## 2. Appendix A pseudocode -> RTL state mapping

| appendix A step | RTL state(s) | Notes |
|---|---|---|
| `wait pre_done` (layer weights ready) | S_PRE0 -> S_PRE0_WAIT | only when current op not prefetched yet; bank flip + pointer += after done |
| per band: compute tile fields | S_BAND_INIT (combinational) | d_* stable during band_start cycle |
| `tile_start(); wait band_ready` | S_BAND_INIT pulse -> S_BAND_FILL | tile_err -> E6 |
| `engine_desc = {pad=0, iw=iw+2pad, ih=in_rows, src=dst=0...}` | S_BAND_ENG | desc combinational from ROM + band index |
| `wait engine_done` | S_BAND_DRAIN | cycles += eng_cycles |
| `wait band_done` | S_BAND_FLUSH | tile_err checked; band index++ or op end |
| `w_ptr += w_len; pre_start(next)` | first band S_BAND_INIT (overlap) + S_OP_END/S_PRE_END | pre_start issued once per op while previous op runs |

## 3. Unit test evidence

```
[legacy] PASS starts=112 cycles=336 done_ops=112 rom_len=112
[legacy] err-inject PASS
[band] PASS ops=112 bands=4242 pre=112 eng=4242 cycles=72114
[band] err-inject wlen>128K -> E6 PASS
[band] err-inject pre_err -> E6 PASS
NN_SEQ_TB: PASS (legacy starts=112 cycles=336 | band ops=112 bands=4242 pre=112 eng=4242)
```
* legacy numbers are the original TB criteria (exactly NN_ROM_LEN starts, cycles == stub
  engine sum) evaluated BEFORE the second (err-injection) run, so the old final-line
  counters (113/0) no longer confuse the report.
* band cycles = 4242 x 17 (stub engine fixed 17 cycles) = 72,114 exactly.

## 4. 106-op n_bands reconciliation vs band_plan.json

Summary: Sigma n_bands RTL = **2,409**; band_plan = **2,391**; exact per-op match 104/106.
Differences:
* op 81 and op 87 (upsample, band_rows=3): RTL forces band_rows even -> 2 (band-relative
  origin requirement of the unmodified engine), so n_bands = 28 instead of 19 each
  (+9 x2 = +18 total, matching the 2,409 vs 2,391 gap). Numerically equivalent for even
  out_r0; documented in integration notes.
* First-band `in_base` and `pad_top` match band_plan for all non-upsample ops.
* 3 ops (64/65/66, oh=7 with band_rows=16 -> n_bands=1) have RTL first-band in_rows
  7/9/9 (appendix clamps br=min(band_rows,oh)) vs band_plan 16/18/18 (unclamped
  over-allocation). RTL follows appendix A; no functional impact.
* Note: band_plan `in_row_bytes` uses `iw*ic_pad` (no horizontal pad) for capacity
  accounting; M6c path A materializes horizontal pad (`(iw+2*pad)*ic_pad`), so buffer
  width differs by up to 2*ic_pad bytes/row. n_bands/in_rows/pad_top/in_base/out_base are
  independent of that choice.

Table (op | kind | band_plan B | RTL B | band_plan n_bands | RTL n_bands | match):

|   0 | conv   |  6 |  6 |  19 |  19 | Y |
|   1 | conv   |  1 |  1 | 112 | 112 | Y |
|   2 | dwconv |  1 |  1 | 112 | 112 | Y |
|   3 | conv   |  2 |  2 |  56 |  56 | Y |
|   4 | add    |  6 |  6 |  19 |  19 | Y |
|   5 | conv   |  1 |  1 | 112 | 112 | Y |
|   6 | dwconv |  1 |  1 | 112 | 112 | Y |
|   7 | conv   |  2 |  2 |  56 |  56 | Y |
|   8 | add    |  6 |  6 |  19 |  19 | Y |
|   9 | conv   |  1 |  1 | 112 | 112 | Y |
|  10 | dwconv |  1 |  1 |  56 |  56 | Y |
|  11 | conv   |  3 |  3 |  19 |  19 | Y |
|  12 | conv   |  1 |  1 |  56 |  56 | Y |
|  13 | dwconv |  1 |  1 |  56 |  56 | Y |
|  14 | conv   |  2 |  2 |  28 |  28 | Y |
|  15 | add    |  9 |  9 |   7 |   7 | Y |
|  16 | conv   |  1 |  1 |  56 |  56 | Y |
|  17 | dwconv |  1 |  1 |  56 |  56 | Y |
|  18 | conv   |  2 |  2 |  28 |  28 | Y |
|  19 | add    |  9 |  9 |   7 |   7 | Y |
|  20 | conv   |  1 |  1 |  56 |  56 | Y |
|  21 | dwconv |  1 |  1 |  28 |  28 | Y |
|  22 | conv   |  4 |  4 |   7 |   7 | Y |
|  23 | conv   |  1 |  1 |  28 |  28 | Y |
|  24 | dwconv |  1 |  1 |  28 |  28 | Y |
|  25 | conv   |  2 |  2 |  14 |  14 | Y |
|  26 | add    |  9 |  9 |   4 |   4 | Y |
|  27 | conv   |  1 |  1 |  28 |  28 | Y |
|  28 | dwconv |  1 |  1 |  28 |  28 | Y |
|  29 | conv   |  2 |  2 |  14 |  14 | Y |
|  30 | add    |  9 |  9 |   4 |   4 | Y |
|  31 | conv   |  1 |  1 |  28 |  28 | Y |
|  32 | dwconv |  1 |  1 |  28 |  28 | Y |
|  33 | conv   |  2 |  2 |  14 |  14 | Y |
|  34 | add    |  9 |  9 |   4 |   4 | Y |
|  35 | conv   |  1 |  1 |  28 |  28 | Y |
|  36 | dwconv |  1 |  1 |  14 |  14 | Y |
|  37 | conv   |  4 |  4 |   4 |   4 | Y |
|  38 | conv   |  2 |  2 |   7 |   7 | Y |
|  39 | dwconv |  2 |  2 |   7 |   7 | Y |
|  40 | conv   |  2 |  2 |   7 |   7 | Y |
|  41 | add    | 12 | 12 |   2 |   2 | Y |
|  42 | conv   |  2 |  2 |   7 |   7 | Y |
|  43 | dwconv |  2 |  2 |   7 |   7 | Y |
|  44 | conv   |  2 |  2 |   7 |   7 | Y |
|  45 | conv   |  1 |  1 |  14 |  14 | Y |
|  46 | dwconv |  1 |  1 |  14 |  14 | Y |
|  47 | conv   |  2 |  2 |   7 |   7 | Y |
|  48 | add    |  9 |  9 |   2 |   2 | Y |
|  49 | conv   |  1 |  1 |  14 |  14 | Y |
|  50 | dwconv |  1 |  1 |  14 |  14 | Y |
|  51 | conv   |  2 |  2 |   7 |   7 | Y |
|  52 | add    |  9 |  9 |   2 |   2 | Y |
|  53 | conv   |  1 |  1 |  14 |  14 | Y |
|  54 | dwconv |  1 |  1 |   7 |   7 | Y |
|  55 | conv   |  4 |  4 |   2 |   2 | Y |
|  56 | conv   |  2 |  2 |   4 |   4 | Y |
|  57 | dwconv |  2 |  2 |   4 |   4 | Y |
|  58 | conv   |  2 |  2 |   4 |   4 | Y |
|  59 | add    | 12 | 12 |   1 |   1 | Y |
|  60 | conv   |  2 |  2 |   4 |   4 | Y |
|  61 | dwconv |  2 |  2 |   4 |   4 | Y |
|  62 | conv   |  2 |  2 |   4 |   4 | Y |
|  63 | add    | 12 | 12 |   1 |   1 | Y |
|  64 | conv   | 16 | 16 |   1 |   1 | Y |
|  65 | conv   | 16 | 16 |   1 |   1 | Y |
|  66 | conv   | 16 | 16 |   1 |   1 | Y |
|  67 | add    | 16 | 16 |   1 |   1 | Y |
|  68 | conv   | 12 | 12 |   2 |   2 | Y |
|  69 | upsample | 12 | 12 |   2 |   2 | Y |
|  70 | add    | 12 | 12 |   2 |   2 | Y |
|  71 | conv   | 12 | 12 |   2 |   2 | Y |
|  72 | conv   | 12 | 12 |   2 |   2 | Y |
|  73 | add    | 12 | 12 |   2 |   2 | Y |
|  74 | conv   |  6 |  6 |   5 |   5 | Y |
|  75 | upsample |  6 |  6 |   5 |   5 | Y |
|  76 | add    |  6 |  6 |   5 |   5 | Y |
|  77 | conv   |  6 |  6 |   5 |   5 | Y |
|  78 | conv   |  6 |  6 |   5 |   5 | Y |
|  79 | add    |  6 |  6 |   5 |   5 | Y |
|  80 | conv   |  3 |  3 |  19 |  19 | Y |
|  81 | upsample |  3 |  2 |  19 |  28 | N |
|  82 | add    |  3 |  3 |  19 |  19 | Y |
|  83 | conv   |  2 |  2 |  28 |  28 | Y |
|  84 | conv   |  2 |  2 |  28 |  28 | Y |
|  85 | add    |  3 |  3 |  19 |  19 | Y |
|  86 | upsample |  6 |  6 |   5 |   5 | Y |
|  87 | upsample |  3 |  2 |  19 |  28 | N |
|  88 | copy   |  1 |  1 |  56 |  56 | Y |
|  89 | copy   |  1 |  1 |  56 |  56 | Y |
|  90 | copy   |  1 |  1 |  56 |  56 | Y |
|  91 | conv   |  1 |  1 |  56 |  56 | Y |
|  92 | conv   |  2 |  2 |  28 |  28 | Y |
|  93 | conv   |  2 |  2 |  28 |  28 | Y |
|  94 | add    |  3 |  3 |  19 |  19 | Y |
|  95 | conv   |  2 |  2 |  28 |  28 | Y |
|  96 | conv   |  2 |  2 |  28 |  28 | Y |
|  97 | conv   |  2 |  2 |  28 |  28 | Y |
|  98 | conv   |  4 |  4 |  14 |  14 | Y |
|  99 | conv   |  2 |  2 |  28 |  28 | Y |
| 100 | conv   |  2 |  2 |  28 |  28 | Y |
| 101 | conv   |  2 |  2 |  28 |  28 | Y |
| 102 | conv   |  4 |  4 |  14 |  14 | Y |
| 103 | conv   |  2 |  2 |  28 |  28 | Y |
| 104 | conv   |  2 |  2 |  28 |  28 | Y |
| 105 | conv   |  4 |  4 |  14 |  14 | Y |

Representative first-band values (from the appendix-A formula used in RTL):

| op | kind | B | n_bands | in_rows | pad_top | in_base | out_base |
|---|---|---|---|---|---|---|---|
| 0 | conv (PACKED3) | 6 | 19 | 13 | 1 | 0 | 1,605,632 |
| 1 | conv | 1 | 112 | 1 | 0 | 1,605,632 | 0 |
| 2 | dwconv | 1 | 112 | 3 | 1 | 0 | 802,816 |
| 3 | conv | 2 | 56 | 2 | 0 | 802,816 | 1,806,336 |
| 4 | add | 6 | 19 | 6 | 0 | 1,605,632 | 1,806,336 |
| 10 | dwconv | 1 | 56 | 3 | 1 | 0 | 1,204,224 |
| 50 | dwconv | 1 | 14 | 3 | 1 | 0 | 103,488 |
| 68 | conv | 12 | 2 | 12 | 0 | 206,976 | 489,216 |
| 81 | upsample | 2 (forced) | 28 | 2 | 0 | 0 | 903,168 |
| 88 | copy | 1 | 56 | 1 | 0 | 677,376 | 0 |

## 5. Integration interface for rtl-stream / M6 wrapper (one page)

Direct connection of nn_seq ports to the M6 wrapper:

| nn_seq port | connect to | notes |
|---|---|---|
| pre_start, pre_src_addr, pre_wlen, pre_qsrc_addr, pre_qlen, pre_bank | nn_wload pre_* | pre_start is 1 cycle; pre_done/pre_err come back |
| w_bank_sel, q_bank_sel | nn_mem w_bank_sel/q_bank_sel (w_mode=1) | both equal (Q shadow follows W) |
| band_start | nn_tilecache band_start | d_* must be latched on this cycle |
| d_in_base,d_in_rows,d_in_row_bytes,d_in_stride,d_in_pad_top,d_in_rd_rows,d_zp_in | nn_tilecache d_* | path A: d_in_row_bytes=(iw+2pad)*ic_pad, d_in_stride=iw*ic_pad |
| d_add_mode,d_aux_base,d_aux_stride,d_aux_pad_top,d_aux_rd_rows | nn_tilecache d_aux* | add_mode=1 for ADD/ADD_R |
| d_out_base,d_out_rows,d_out_row_bytes,d_out_stride | nn_tilecache d_out* | |
| band_ready, band_done, tile_err | from nn_tilecache | band_done after engine_done+flush |
| eng_desc, eng_start, eng_busy, eng_done, eng_cycles, eng_err_code | nn_conv_engine | band desc: pad=0, iw=iw+2pad, ih=in_rows, src=dst=0 |
| w_ddr_base, q_ddr_base, arena_ddr_base (inputs) | constants | W=0x0140_0000, Q=0x0140_0000+2,020,960 (combined stream image q_stream_base), arena=0x0100_0000 (plan.arena_base) |
| engine_done to tilecache | direct wire from engine | nn_seq does not drive it (wrapper connects engine_done -> tilecache.engine_done) |

Ordering rules enforced by nn_seq: bank flip only after pre_done; engine start only after
band_ready; next band only after band_done; d_* stable one cycle before band_start;
pre_start for op N+1 issued while op N is running (overlap). `a_sel`/`b_sel` mux between
legacy A/B and tile ports stays in the wrapper/nn_subsys (Lead item).

**DDR read arbiter is integration-side (Lead decision 2026-11-04)**: nn_seq only issues
`pre_start` (a 1-cycle command) and waits for `pre_done`; it does NOT arbitrate between
nn_wload and nn_tilecache. The M6 wrapper must implement the read-channel arbiter
(nn_wload priority, tilecache fill next, round-robin with credit). nn_seq tolerates a
stretched prefetch: `pre_done`/`pre_err` are latched (`pre_seen`) and the command can be
held/served arbitrarily late, as long as it completes within the wait-state guard
(4M cycles; job guard 64M cycles). On the board version the arbiter moves to the
nn_subsys/MIG layer (S3 item).

## 6. Known limitations / open items for M6

1. **PACKED3 op0**: cannot use path A (3 B/pixel -> 678 B/row, not 16B aligned; interior
   band halo needs an engine band-row origin). Lead decision: op0 runs as whole-tensor
   single "band" with wide buffers in M6 simulation (ROM tile=0 keeps the legacy path
   here); on-board variant pre-converts op0 input to NHWC ic_pad=8 by CPU. M6c unit test
   only checks the packed3 descriptor branch (tile[2]=1, row bytes=iw*3, engine keeps
   rom.pad/iw).
2. **Upsample**: band_rows forced even (engine has no band-in-row0 field). n_bands differs
   from band_plan for odd B (ops 81/87); band_rows must be >=2 for upsample.
3. **DDR read arbitration (resolved by Lead 2026-11-04)**: prefetch of op N+1 overlaps
   band fills of op N, so the DDR read channel needs an arbiter. M6 wrapper implements it
   (nn_wload priority, tilecache fill next, round-robin with credit); nn_seq tolerates
   stretched `pre_done` (Sec. 5). Board version: arbiter moves to nn_subsys/MIG layer.
4. **Job timeout during band mode** drains the engine only; tilecache/nn_wload may still be
   busy when the job ends -> integration reset/finish handling needed (M6).
5. **IBUF capacity vs path A horizontal pad (resolved by Lead 2026-11-04)**: the 32 KiB
   class worst case is 112x112x96 dwconv B=1: in_rows=3, row bytes=(112+2)*96=10,944 ->
   3*10,944 = 32,832 B > 32,768 B by 64 B. Decision: **IBUF 2 x 40 KiB per bank + OBUF
   2 x 12 KiB**; whole-chip tiles: W 80 + Q 4 + IBUF 20 + OBUF 6 + core 12 = 122/135.
   rtl-stream parameterizes nn_tilecache per-bank IBUF_BYTES (M4 default 16 KiB,
   bottlecap config 40 KiB). Converter capacity rule stays `iw*ic_pad`; the horizontal
   pad is absorbed by the bigger tilecache buffers (no converter change).
6. ROM `aux0[7:0]` zp_in requires `nn_gen_rom.py`/converter to write plan `tile_zp_in`
   (Lead-side change, already announced).

## 7. Regression

`python tools/fpga_workflow.py verify --force` -> **PASS 20** (0 FAIL/SKIP); old 19 tests
unchanged (YOLO `hw_bad=0 / auto_bad=0 / npu_cycles=1,191,020`; tb_sw_nn_job,
tb_nn_wstream, tb_nn_tilecache PASS). Log: `.fpga-cache/verify_full_m6c_final2.log`.
tb_nn_seq runtime 3.0-3.3 s with zero vopt port warnings for the legacy DUT.
Note: an intermediate full run at 01:05 was red only because rtl-stream was editing
`nn_tilecache.sv`/`tb_nn_tilecache.sv` at that moment (X outputs); after their edit
landed the test passed again and the final full run above is clean.

## 8. Files changed (task-17 scope + Lead-approved nn_subsys block)

| File | Type | Note |
|---|---|---|
| `nn_seq.sv` | modified | band/streaming extension, legacy path preserved |
| `sim/tb_nn_seq.sv` | rewritten | dual-DUT: legacy strict + synthetic band ROM with stubs |
| `nn_subsys.sv` | modified | only u_seq instantiation: band inputs tie-off, outputs unconnected |
| `results/bottlecap/reports/M4-TILECACHE.md` | modified | appendix A: tile[1]=band_en note (Lead request) |
| `results/bottlecap/reports/M6C-NNSEQ-BAND.md` | new | this report |
