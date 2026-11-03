# M6a — Slim 96x96 model end-to-end on the existing NPU (ModelSim, bit-exact)

> Task: task-16 (agent npu-spec). Date: 2026-11-04 (Asia/Shanghai).
> Goal: run the slim bottlecap model (96x96, 71 ops) end-to-end on the **current**
> CPU+NPU SoC in ModelSim - **zero RTL changes**, pure on-chip, per-op bit-exact.
> Status: **PASS**. `SLIM_TB: PASS`; real-image FNV 71/71; pattern FNV 71/71;
> MODE_AUTO head FNV match; `npu_cycles = 799,520` (== exact v3 cycle formula).
> All text in this report is ASCII-only (task discipline).

## 0. Status snapshot

| Item | Result | Evidence |
|---|---|---|
| New SoC-level TB | `sim/tb_sw_nn_slim.sv` (core+mmio+nn, 50 MHz, NN_EN) | TB, `SLIM_TB: PASS` |
| New firmware | `sw/slim_demo.c` (3,228 B text / 4,552 B data; imem 754 words) | `sim/prog/slim_demo.hex` |
| Real-image input 0349 | preloaded to A[0] (27,648 B PACKED3), input FNV `0xbb23c676` OK | `[slim] real_input_csum` |
| Real-image per-op FNV | **71/71 ops match** `slim/opvec/0349/checksums.txt` (incl. 3 heads) | `real_hw_bad=0` |
| Pattern_v1 full-plan FNV | **71/71 ops match** `slim_plan.h` csum (pattern golden) | `pattern_hw_bad=0` |
| MODE_AUTO (slim ROM) | done, head FNV `0xd93e3569` match, cycles == MODE_CPU sum | `auto_bad=0` |
| NPU cycles | **799,520** (MODE_CPU sum == MODE_AUTO == v3 formula, 0 delta) | Sec. 6 |
| Sim time / wall | 11,765,470 cycles (50 MHz) / 58-66 s wall | log |
| Regression | `verify --force` = **PASS 20** (old 19 unchanged, +tb_sw_nn_slim 62.5 s) | Sec. 9 |
| RTL changes | **NONE** | Sec. 10 |

## 1. Wiring

```
 +imem/+dmem --> core (rv32im) -- nn_* data window (A/B) ---+
                    |  ext bus 0xA000_0100..0x0184          |
                    v                                      v
              mmio_subsys -- ext_rdata mux ----------> nn_subsys
                                                       |- desc regs/CTRL/STATUS (MODE_CPU)
                                                       |- job regs + 2 KB mailbox (M5-S1, re-used)
                                                       |- nn_seq  (imports rtl/nn_rom_pkg;
                                                       |           slim ROM variant in this TB)
                                                       |- nn_mem  (W/Q loader: +nnw= +nnq=)
                                                       +- nn_conv_engine v3 (128 MAC/cyc)
```

Differences vs `tb_sw_nn_job.sv` (M5-S1 TB):
1. `imem/dmem = sim/prog/slim_demo.hex / .dmem.hex` (firmware `sw/slim_demo.c`).
2. W/Q image = `results/bottlecap/plan/slim/{w,q}.hex` via `+nnw= +nnq=`
   (nn_mem simulation loader reads until EOF: confirmed W 16,306/40,960 x64b,
   Q 2,848/6,144 x64b; unused tail stays zero). The legacy `+nnwq=` channel is
   NOT usable: it splits a fixed YOLO layout (W 81,920 lines then Q 12,288).
3. Real-image input 0349: TB loads `opvec/0349/input.hex` (6,912 lines of
   u32-LE = 27,648 B) and writes it **byte-for-byte** into NN window A region
   offset 0 (`plan.input.act_off = 0`, no de-quantization) **before reset is
   released**. `nn_mem` act_rd_idx drops the A_OFF high bits, so A[0] maps to
   `act_mem[0]` (TB `A_ACT_IDX = 0`; verified by the input FNV check passing).
4. Slim ROM: the workflow slim-test RTL list replaces `nn_rom_pkg.sv` with
   `results/bottlecap/plan/slim/nn_rom_pkg_slim_as_nn_rom_pkg.sv` (identical
   content to `nn_rom_pkg_slim.sv`; package name is still `nn_rom_pkg`, so
   `nn_seq` imports it unchanged). All other tests keep the YOLO ROM package.
   This copy is regenerated from the frozen `nn_rom_pkg_slim.sv`
   (sha256 beee6738076289c6...).

## 2. Firmware self-check flow (`sw/slim_demo.c`)

Three phases in one run; the TB only checks `tohost==1` and the
`SLIM_TB: PASS` marker (all numeric gates are machine-checked in firmware).

* **Phase R (real image 0349)** - input already preloaded by the TB:
  check input FNV == `0xbb23c676`, then issue all **71 ops** through the 14 MMIO
  descriptor registers (MODE_CPU, order from `slim_plan.h`), sum CYCLES; after
  each op compute the output-tensor FNV and compare against `REAL_CSUM[i]`
  (71 entries, `opvec/0349/checksums.txt`).
* **Phase P (pattern_v1)** - generate input
  `q = (x*13 + y*7 + c*29 + 12345) & 0xFF` PACKED3; check input FNV
  `0xe40efcc5`; issue all 71 ops; compare every op output FNV against
  `YOLO_OPS[i].csum` from `slim_plan.h` (71/71).
* **Phase A (MODE_AUTO)** - regenerate pattern input, single CTRL.auto start,
  the slim ROM (71 entries) runs autonomously; check done/err, read CYCLES
  (must equal the MODE_CPU sum) and check the last head FNV `0xd93e3569`.

FNV definition (converter-confirmed, identical to `opvec/*/checksums.txt`):
```
h = 2166136261
for y in range(H): for x in range(W): for c in range(real_C):
    h ^= tensor[y, x, c8*c]; h = (h * 16777619) & 0xFFFFFFFF
```
Only real channels, NHWC y,x,c logical order, pixel stride = pad8(C); input
image FNV walks the PACKED3 stream (3 B/pixel) byte by byte.

## 3. Golden sources (all frozen, converter-provided)

| Golden | File | Content |
|---|---|---|
| Real-image input FNV + 71 op FNV | `slim/opvec/0349/checksums.txt` | input 0xbb23c676 + 71 ops |
| Pattern input FNV + 71 op FNV | `slim/checksums.txt` + `slim_plan.h` (`YOLO_OPS[i].csum`) | input 0xe40efcc5 + 71 ops |
| Final heads (pattern) | `slim_plan.h` `YOLO_FINALS[]` | 3 heads at B@0x78000 |
| Byte-level op tensors | `slim/opvec/{0349,pattern_v1}/op*.hex` | all 71 ops exported (offline reference) |
| Cycle golden | `E2E-HANDOFF.md` Sec. 4 (updated) | 799,520, exact v3 formula |

## 4. Accuracy claim

* Real image 0349: input FNV exact; **71/71 op output tensors bit-identical to
  golden** (FNV-1a over the same bytes is exact; 23 of them were also checked
  byte-for-byte by TCP earlier; converter's independent golden has mismatch=0).
* Pattern_v1: **71/71 ops bit-exact** (full-plan gate).
* MODE_AUTO: same op sequence via the slim ROM gives done, 0 errors, identical
  cycles and matching final head -> sequencer path is bit-identical to MODE_CPU.

## 5. Per-op statistics

| Phase | ops issued | FNV compared | byte-tensor compared | result |
|---|---|---|---|---|
| R (real 0349) | 71 | 71 | 71 available offline (opvec/0349/op*.hex) | 0 bad |
| P (pattern_v1) | 71 | 71 | 71 available offline (opvec/pattern_v1/op*.hex) | 0 bad |
| A (MODE_AUTO) | 71 (ROM) | final head FNV only | - | 0 bad |

All 71 ops have both an FNV golden and a byte-level tensor golden in opvec;
the firmware compares FNV (byte tensors are too large for the 16 KB dmem; they
are used offline by the converter). FNV-1a-32 over the exact byte stream is a
strong bit-exact signature: a one-bit change fails it with probability ~1-2^-32.

## 6. NPU cycles

Measured `npu_cycles = 799,520`, identical for:
* sum of the 71 per-op `MMIO_NN_CYCLES` values (MODE_CPU), and
* the `MMIO_NN_CYCLES` after one MODE_AUTO run (slim ROM).

Per kind (exact v3 formula, now also the updated `E2E-HANDOFF.md` Sec. 4 value):

| kind | cycles |
|---|---|
| conv (39 ops) | 447,935 |
| dwconv (18 ops) | 294,042 |
| add (11 ops) | 49,959 |
| upsample (3 ops) | 7,584 |
| **total** | **799,520** |

The v3 formula implemented in `results/ai-accel/proto/engine/calc_cycles_v3.py`
(BASE=8, W_RD_LAT=2 -> DRN=4, NEXT=2, REQP=6, QPER8=11) reproduces the ModelSim
value exactly (0 delta), same as it reproduces the YOLO E2E value (1,191,020).
The earlier `E2E-HANDOFF.md` estimate 504,895 was the converter's rough
`+40 cycles/block` approximation; converter has already corrected HANDOFF
Sec. 4 and FINAL.json to 799,520 (this report references the corrected version).
100 MHz: 7.995 ms/frame; 150 MHz: 5.330 ms/frame.

## 7. Pitfall found (firmware only, no RTL impact)

GCC 15 (-O2) mis-folded the plain `o->csum` read when two `static const` csum
tables were in scope: in the pattern phase the compiler compared against
`REAL_CSUM[i]` instead of `YOLO_OPS[i].csum`, producing 57 false mismatches
(hardware outputs were correct all along: they equaled the pattern golden).
Fix: read the expected value through a volatile pointer
(`*(volatile const u32 *)&o->csum`); documented in the code. This is a toolchain
codegen issue, not an RTL or model issue. Real-image phase was unaffected
because it uses REAL_CSUM (a single table).

## 8. How to re-run

Build firmware:
```
python tools/build_sw.py sw/slim_demo.c sw/portme.c -I sw -I results/bottlecap/plan/slim ^
       --march rv32im --opt=-O2 -o sim/prog/slim_demo.hex
```
Manual ModelSim (compile the canonical RTL list with `nn_rom_pkg.sv` replaced by
`results/bottlecap/plan/slim/nn_rom_pkg_slim_as_nn_rom_pkg.sv`, `+define+NN_EN`):
```
vsim -c -do "run -all; quit -f" work.tb_sw_nn_slim ^
  "+imem=<repo>/sim/prog/slim_demo.hex" "+dmem=<repo>/sim/prog/slim_demo.dmem.hex" ^
  "+nnw=<repo>/results/bottlecap/plan/slim/w.hex" ^
  "+nnq=<repo>/results/bottlecap/plan/slim/q.hex" ^
  "+slim_input=<repo>/results/bottlecap/plan/slim/opvec/0349/input.hex" ^
  "+max_cycles=60000000" "+watchdog_ms=12000"
```
Workflow (Lead-registered, gated by env var or TB_READY sentinel):
```
$env:DSH_SLIM_E2E='1'
python tools/fpga_workflow.py verify --only tb_sw_nn_slim --force
# TB_READY exists -> the test is in the default --force matrix:
python tools/fpga_workflow.py verify --force
```
Measured: 58-66 s wall (11,765,470 sim cycles @ 50 MHz).

## 9. Regression status (final)

`python tools/fpga_workflow.py verify --force` -> **PASS 20** (0 FAIL / 0 SKIP),
log `.fpga-cache/verify_full_m6a2.log`:

```
PASS tb_units 2.8s | tb_core_basic 2.9s | tb_core_trap 2.3s | tb_soc_timer_irq 3.4s
PASS tb_core_m_ext 2.2s | tb_core_amo 2.9s | tb_core_amo_diag 2.2s | tb_soc 2.2s
PASS tb_sw_lu_bench 2.9s | tb_sw_hello 2.3s | tb_sw_coremark 13.3s | tb_sw_nn_demo 6.0s
PASS tb_sw_nn_yolo 82.5s (hw_bad=0 / auto_bad=0 / auto_npu_cycles=1,191,020)
PASS tb_nn_mem 2.9s | tb_nn_engine 4.3s | tb_nn_seq 2.8s | tb_nn_wstream 2.7s
PASS tb_sw_nn_job 27.2s | tb_nn_tilecache 2.0s
PASS tb_sw_nn_slim 62.5s   <- this task
```

`results/bottlecap/plan/slim/TB_READY` enables the slim test in the default
matrix; the old 19 tests are unchanged (YOLO `npu_cycles=1,191,020` intact).

## 10. Files changed by M6a (RTL untouched)

| File | Type | Note |
|---|---|---|
| `sim/tb_sw_nn_slim.sv` | new | SoC E2E TB, pass_marker `SLIM_TB: PASS` |
| `sw/slim_demo.c` | new | 3-phase self-check firmware |
| `sim/prog/slim_demo.hex/.dmem.hex` | generated | from build_sw (regenerable) |
| `results/bottlecap/plan/slim/nn_rom_pkg_slim_as_nn_rom_pkg.sv` | copied | slim ROM package under original `nn_rom_pkg` name |
| `results/bottlecap/plan/slim/TB_READY` | created | enables the test in the default matrix |
| `sim/prog/slim/input_96.hex` | copied | real-image input (same bytes as opvec/0349/input.hex) |
| `results/bottlecap/reports/M6A-SLIM-E2E.md` | new | this report |
| `nn_*.sv` / `nn_pkg.sv` / `rv32_pkg.sv` / `top_a100t.sv` | **not modified** | zero RTL changes |

## 11. Differences vs `tb_sw_nn_yolo`

| Aspect | tb_sw_nn_yolo (YOLO) | tb_sw_nn_slim (this) |
|---|---|---|
| model / ops | YOLO-Fastest 128x128, 112 ops | slim bottlecap 96x96, 71 ops |
| ROM package | rtl/nn_rom_pkg.sv (112 entries) | slim ROM copy (71 entries), file swapped in test RTL list |
| input | firmware pattern_v1 only | real image 0349 (TB preload) + pattern_v1 |
| per-op golden | firmware table in yolo_plan.h (pattern) | `slim_plan.h` (pattern) + `opvec/0349/checksums.txt` (real, 71 ops) |
| W/Q load | single `+nnwq=` merged image | separate `+nnw= +nnq=` (adaptive sizes) |
| cycle golden | measured 1,191,020 | 799,520 (exact v3 formula) |
| A/B mode | fixed A/B | real allocation, peak A 92,160 / B 23,040 |
| MMIO | same 14 desc regs (MODE_CPU) + CTRL.auto | identical |

## 12. Next steps

* M6b: run the other 7 golden images of `slim/opvec/` (only the TB preload file
  changes) - real-image robustness.
* M6c: frame pipeline (camera/DDR input -> job doorbell -> mailbox -> CPU post);
  dual-clock CDC (S2) stays deferred (see `M5-S2-PREP.md`).
