# M5-S2 prep — dual-clock CDC readiness (design only, NOT implemented)

> Task: Lead request during M6a. Author: npu-spec. Date: 2026-11-04.
> Scope: what must be done before S2 (CPU/NPU dual clock) can start, and why it
> waits until the M6 full chain is green. Design reference:
> `results/bottlecap/reports/CPU-NPU-DECOUPLE.md` Sec. 3 / Sec. 9-S2;
> machine-readable: `results/bottlecap/reports/cpu_npu_interface.json`.

## 1. Three prerequisites (each is a separate, testable step)

| # | Change | Files | Acceptance |
|---|---|---|---|
| P1 | Add NPU clock domain: MMCM `CLKOUT1` at 100 MHz (VCO 1050, `CLKOUT1_DIVIDE_F=10.5`), `BUFG` for `nn_clk`, NPU-domain reset synchronizer (2FF). Keep CPU 150 MHz on `CLKOUT0`. All of it inside `ifdef NN_EN`; delivery build (no NN_EN) must keep the current MMCM instantiation byte-identical. | `fpga/top_a100t.sv` | existing 19 tests still PASS on single-clock path; NPU clock only observable via `nn_busy` toggling in a new CDC TB |
| P2 | Move job registers + 2 KB result mailbox to the CPU domain and add CDC: request/data toggle or 2FF per bit for job payload, ack, npu reset, busy, done+result words; mailbox becomes a true dual-port (TDP) 2 KB BRAM read by CPU domain and written by NPU domain (replaces the current LUTRAM copy so no CDC data race). | `nn_subsys.sv` (or new `nn_job_if.sv`), `nn_mem.sv` fill-port use | `tb_sw_nn_job` and `tb_sw_nn_slim` still PASS in single-clock mode (S2 default off); new `tb_nn_cdc` PASS with randomized 150/100 MHz job stress, no torn payload |
| P3 | Timing constraints: `create_generated_clock -name nn_clk` on the NPU MMCM output; `set_clock_groups -asynchronous -group sys_clk -group nn_clk`; `max_delay`/`datapath_only` on the CDC bundle; keep per-domain `set_false_path` on synchronizers only. | `fpga/daVinciPro.xdc`, `fpga/build.tcl` (generated NN clock section) | `report_timing` shows 0 unconstrained CDC paths; WNS >= 0 at 150/100; `verify --force` unchanged |

Optional (only if we later want coherent debug reads or IRQ): `nn_cdc_bridge.sv`
(Pango-style req/ack with timeout) and the `core.sv`/`load_store_unit.sv`
`ext_ready`/`stall_external` Option-W patch (8 sites, see DECOUPLE.md Sec. 3.4).
**Not needed for S2 v1.**

## 2. Why S2 must wait for M6 green

1. **One variable at a time.** M6a already proved a bit-exact model path with a
   single clock. Adding CDC changes every handshake; if a bug appears, there is
   no way to tell whether it is the model link or the clock crossing. M6a/b/c
   (real images, frame pipeline) must be frozen first.
2. **Interface stability.** S2 moves the job registers/mailbox across domains;
   the M6 firmware/TB currently rely on the single-clock mailbox semantics
   (1-cycle registered read with registered select). M6b (8 images) only changes
   the input file - do it before touching the interface.
3. **Risk of touching RTL late.** `nn_mem`/`nn_subsys` are now shared by
   M2/M3/M4/M5 tests. The P2 mailbox change is the only place S2 touches them;
   doing it while the matrix is green lets us bisect cleanly (single commit,
   `ifdef NN_EN` + S2 enable switch).
4. **No performance need yet.** NPU at 100 MHz / CPU 150 MHz is a throughput
   optimization; the M6 E2E already runs at 5.3 ms (150 MHz equivalent) per
   frame on the 96x96 model, which is sufficient for the milestone.

## 3. Readiness checklist (all currently satisfied)

- [x] Job interface semantics frozen: 14 registers at 0xA000_0150..0x0184, ACK
      protocol, drop-on-busy counter (`M5-JOB-IF.md`).
- [x] Result mailbox layout frozen: 2 KB, header 0x00..0x1F, payload at 0x20
      (`M5-JOB-IF.md` Sec. 3).
- [x] Design + CDC item list available (`CPU-NPU-DECOUPLE.md` Sec. 3, 10 items;
      `cpu_npu_interface.json` `cdc_list`).
- [x] S1 done and accepted (PASS with `tb_sw_nn_job`, M6a uses the same path).
- [x] Clock plan fixed: VCO 1050, CPU 150 MHz (/7), NPU 100 MHz (/10.5); XDC
      numbers already derived (`CPU-NPU-DECOUPLE.md` Sec. 3.1).
- [ ] S2 start decided by Lead after M6 full-chain green (this doc is the gate).

## 4. Estimated diff surface (for scheduling)

| Area | Files | Size |
|---|---|---|
| clock/reset | `fpga/top_a100t.sv` (MMCM + BUFG + sync) | ~40 lines, NN_EN only |
| job/CDC | `nn_subsys.sv` split into CPU-domain job block + CDC sync registers, mailbox TDP BRAM | ~150-200 lines |
| constraints | `daVinciPro.xdc` + generated clock block in `build.tcl` | ~15 lines |
| verification | new `sim/tb_nn_cdc.sv` dual-clock 150/100 stress | ~250 lines |
| optional | `nn_cdc_bridge.sv`, core/LSU Option-W | ~60 lines + 8 sites |

S2 is **not scheduled**; nothing here is implemented. Do not start P2 before
P1 lands and the dual-clock test is wired, and do not touch the mailbox until
M6b (8-image real-image run) is green.
