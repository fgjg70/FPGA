# M5-S1：单时钟 Job 接口实施报告（CPU-NPU 解耦第一版）

> 任务：task-13（承接 task-10 设计 `CPU-NPU-DECOUPLE.md` §4/§9 S1）。作者：npu-spec。
> 日期：2026-11-03（Asia/Shanghai）。状态：**已完成**（`verify --force` PASS 19）。
> 纪律：新逻辑全部 `NN_EN` 内；无 `NN_EN` 网表逐位等价；旧 16 项回归不许回退；BRAM 增量 0。

---

## 0. 状态摘要（一眼看板）

| 项 | 状态 | 证据/实测 |
|---|---|---|
| `nn_seq.sv` job 路径（job 看门狗 + 排空 + `done_ops` 输出） | ✅ 落地 | `nn_seq.sv:45-46,62,72-75,147-168,178-220,207-219` |
| `nn_subsys.sv` Job 寄存器组（14 个）+ 2KB 结果邮箱 + copy FSM | ✅ 落地 | `nn_subsys.sv:148-370,351-362` |
| `fpga/top_a100t.sv` 接线 | ✅ **零改动**（job 寄存器走既有 `ext_*` 0xA000_01xx 段；邮箱走既有 `nn_*` 窗口） | `top_a100t.sv:265,270-295` 未改 |
| `sw/nn_job_demo.c` + 镜像 | ✅ 编译通过（imem 2,844 B / dmem 760 B） | `sim/prog/nn_job_demo.hex/.dmem.hex` |
| `sim/tb_sw_nn_job.sv`（新 SoC 级 TB） | ✅ **PASS 29.0 s** | 见 §8/§10 |
| **`verify --force`** | ✅ **PASS 19**（旧 16 项 + `tb_nn_wstream` + `tb_sw_nn_job` + `tb_nn_tilecache`，逐项 PASS，无 FAIL/SKIP） | 本报告 §10 |
| YOLO E2E 不回退 | ✅ `auto_bad=0`、`auto_npu_cycles=1,191,020`、`RESULT : PASS`（84.1s） | `.fpga-cache/logs/tb_sw_nn_yolo.log:56-57` |
| 资源增量 | BRAM **+0**（邮箱 2KB = distributed RAM）；FF ≈ +430；LUT ≈ +290~350（估算；未跑综合，见 §9） | — |
| Job 实测 | jobA/jobB 均 `status=0x0070_0092`、`cycles=1,191,020`、`err=0`、`done_ops=112`；邮箱 payload 1024B 与 A/B 逐字节一致；两个检测头 FNV == golden；busy 时 doorbell 丢弃计数=1 | 见 §7/§8 |

**一句话**：CPU 现在只写 `IN/OUT/MODEL/FRAME/LEN + DOORBELL`，NPU 用 `nn_seq` 自主跑完 112 op（`cycles=1,191,020` 与 MODE_AUTO 完全一致），完成后自动把结果拷进 2KB 邮箱并置 done；CPU 读邮箱 + ACK 后可起下一 job。**未改 core / 时钟域 / 引擎 / top**。

---

## 1. 设计 → 实现映射（S1 范围）

`CPU-NPU-DECOUPLE.md` §4.2 给 20 个寄存器；S1（单时钟、单模型、无 DDR）实装 **14 个**：

| 设计寄存器 | S1 | 偏移 | 实现位置（nn_subsys.sv） |
|---|---|---|---|
| `NN_JOB_ID` | ✅ | `0x150` | 组合读 `:407`（常量 `0x4E503101`） |
| `NN_JOB_STATUS` | ✅ | `0x154` | 组合读 `:408-411`（busy/done/err/pending/ready/timeout/mbox_valid/err_code/done_ops） |
| `NN_JOB_FRAME_NO` | ✅ | `0x158` | `:412`（seq_done 锁存 `j_frame_no`） |
| `NN_JOB_CYCLES` | ✅ | `0x15C` | `:413`（`j_cycles = seq_cycles`） |
| `NN_JOB_IN_ADDR` | ✅ | `0x160` | 写 `:233`；S1 记录不消费（S3 用） |
| `NN_JOB_OUT_ADDR` | ✅ | `0x164` | 写 `:234`；S1 = 邮箱 payload 拷贝源窗口偏移 |
| `NN_JOB_MODEL` | ✅ | `0x168` | 写 `:235`；S1 只接受 0（其它 → err E7） |
| `NN_JOB_FRAME` | ✅ | `0x16C` | 写 `:236` |
| `NN_JOB_DOORBELL` | ✅ | `0x170` | 写 `:238-269`；busy/未 ACK 时丢弃 + `DROP_CNT++` |
| `NN_JOB_ACK` | ✅ | `0x174` | 写 `:270-275`（清 done/err/timeout） |
| `NN_JOB_ERR_CODE` | ✅ | `0x178` | 组合读 `:416` |
| `NN_JOB_LEN` | ✅ | `0x17C` | 写 `:237`（≤2016、4B 对齐，否则 E1） |
| `NN_JOB_DONE_CNT` | ✅ | `0x180` | `:417` |
| `NN_JOB_DROP_CNT` | ✅ | `0x184` | `:418` |
| `NN_TIMEOUT` | ⏳ S2 | — | S1 用 `nn_seq` 内部 `JOB_GUARD_MAX=64M` 固定值 |
| `NN_CTRL2`/`NN_NPU_STATE`/帧流水线 4 个 | ⏳ S2/S3 | — | 设计 §4.2 |

---

## 2. 寄存器行为要点

- **busy/done/err**：`busy_o = (auto_r ? seq_busy : eng_busy) | j_pending | j_copy`（`nn_subsys.sv:352`）；`j_done/j_err/j_timeout` 粘滞，只有 `NN_JOB_ACK` 清（`:270-275`）。
- **流控**：`busy_o || j_done || j_pending || j_copy` 时 doorbell 被丢弃并计数（`:240-242`）——即"**结果未 ACK 前不接新 job**"（盘古 `start && !done` 语义）。
- **模型号**：S1 只允许 0（当前 ROM = YOLO-C128）；其它 → 立即 done+err=0xE7，不启动 seq（`:251-256`）。
- **邮箱长度**：`> 2016` 或非 4 字节对齐 → done+err=0xE1（`:257-262`）。
- **done_ops**：`NN_JOB_STATUS[23:16]` 暴露 `nn_seq.done_ops`（本次实测 112，可直接对账 op 数）。
- **legacy 不动**：MODE_CPU/MODE_AUTO 的 14 个描述符寄存器、CTRL/STATUS/CYCLES 语义、`desc_ok`（已由 rtl-mem 放宽到 ic/oc≤1023、dst<4MB）**均未改动**。

---

## 3. 结果邮箱（2KB，distributed RAM，**BRAM +0**）

| 项 | 实现 | 位置 |
|---|---|---|
| 存储 | `(* ram_style="distributed" *) logic [31:0] j_mb [0:511]`（512×32 = 16 Kb ≈ 256 LUT6，**0 BRAM**） | `nn_subsys.sv:173` |
| 读口 | 1 拍寄存读：`j_mb_rdata <= j_mb[cpu_off[10:2]]` + **`j_mb_sel_r <= j_mb_sel`** | `:197-206` |
| CPU 映射 | `j_mb_sel = j_ever && (cpu_off < 0x800)`；`cpu_rdata = busy ? 0xDEADBEEF : (j_mb_sel_r ? j_mb_rdata : mem_cpu_rdata)` | `:353-358` |
| 写口 | 仅 copy FSM 写（payload 1 字/拍、header 8 字各 1 拍，**互斥单写口**） | `:313-346` |
| Header 布局 | `+0x00 magic=0x4E505552`、`+0x04 frame`、`+0x08 model`、`+0x0C cycles`、`+0x10 err_code`、`+0x14 copy_src`、`+0x18 len`、`+0x1C rsvd`、`+0x20..` payload | `:326-343` |
| 防撕裂 | payload 先写 → header 最后写（magic 在 header 阶段）→ 才置 `j_done` | `:326-346` |
| copy 源 | `JOB_OUT_ADDR` 起逐字读（经 nn_mem CPU 读口：`mem_cpu_re/mem_cpu_addr` 在 `MC_REQ/MC_RD` 两态由 FSM 占用） | `:187-190` |

**FSM**：`MC_IDLE →(seq_done) MC_REQ → MC_RD(×(len/4)) → MC_HDR(×8) → MC_DONE(done=1)`；`len==0` 直接 `MC_HDR`。
（`nn_subsys.sv:176-183,279-346`）

---

## 4. `nn_seq.sv` job 路径（已落地，最小改动、只增输出）

| 改动 | 内容 | 行号 |
|---|---|---|
| 新增输出 | `done_ops[7:0]`、`job_timeout`（粘滞到下次 start） | `nn_seq.sv:45-46` |
| job 级看门狗 | `JOB_GUARD_MAX = 64_000_000` 拍（YOLO 1.19M / 瓶盖 40.06M 都覆盖） | `:62` |
| 新状态 `S_TIMEOUT` | 超时后停发新 op，等当前 op `eng_busy` 落下再走 `S_DONE`（避免引擎在途与新 job 混叠） | `:72-75,160-168` |
| 错误码 | job 超时 → `err_code=0xE4` + `job_timeout=1`；单 op 看门狗仍 `0xE3`（语义不变） | `:207-219` |
| `done_ops` | 每个 `S_ISSUE` +1（不影响周期/op 语义） | `:203-205` |
| 兼容 | 新增端口全是 **output**；`u_seq` 未接线也不引入 X；旧 MODE_CPU/MODE_AUTO 行为逐位不变 | 文件头 `:22-30` |

**未做（S2/S3）**：超时阈值软件可配（`NN_TIMEOUT`）、`eng_abort` 端口、`WAIT_PREFETCH`（M3）、tile 循环（M4）。
**job 启动 mux 在 nn_subsys**：`seq_start_all = seq_start | job_start_pulse`（`nn_subsys.sv:185`），doorbell 单拍脉冲，`u_seq.start` 接 `seq_start_all`。

---

## 5. `nn_subsys.sv` 改动清单（已实施）

| # | 改动 | 位置 |
|---|---|---|
| J1 | 14 个 Job 寄存器写/读译码 | 写 `:230-277`；组合读 `:404-420` |
| J2 | doorbell → `seq_start` mux（`seq_start_all`） | `:184-190,185` |
| J3 | job 完成/错误握手（seq_done/seq_err/job_timeout） | `:279-310` |
| J4 | 2KB 邮箱 LUTRAM + copy FSM | `:160-211,312-348` |
| J5 | 邮箱读口寄存器（含 **select 也要寄存**） | `:197-206,353-358` |
| J6 | copy 期间占用 nn_mem CPU 读口（`mem_cpu_re/mem_cpu_addr` mux） | `:187-190`；u_mem 连接 `:398-402` |
| J7 | `busy_o` 扩展 + seq 通路选择 | `:351-362` |
| J8 | `u_seq` 接 `done_ops/job_timeout` | `:453-465` |

**保留**：u_mem 的 M2 新端口 tie-off（`w_mode=0/w_bank_sel=0/wfill_we=0/qfill_we=0`，`:480-495`）原样；rtl-mem 的 `desc_ok` 放宽（ic/oc≤1023、dst<4MB，`:269-289`）原样。

---

## 6. 实施中踩到的坑（值得留档）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| P1 | job 模式能跑、`cycles=1,191,020`、两个检测头 FNV 全对，但 **邮箱 `rd32` 连读正确、`rd8` 逐字节读全 0** | core 的 nn_* 窗口是"地址第 N 拍、数据 N+1 拍"；WB 拍 `cpu_off` 已是**下一条指令**的地址。邮箱用**组合** `j_mb_sel` 回选，在 mailbox↔A/B 交替访问（逐字节比对）时 WB 拍选错源：mailbox 读拿到 nn_mem 的 0、A/B 读拿到邮箱字 | **select 必须与数据一起寄存**：`j_mb_sel_r <= j_mb_sel`（`nn_subsys.sv:197-206`）。与 nn_mem 的 `cpu_sel_r/cpu_lane_r` 同因同治 |
| P2 | 首次实现里 job 模式误走 MODE_CPU 分支，`done_r` 不看 seq_done | `auto_r` 只在 CTRL 写时置位；job 不改 auto_r（避免多驱动） | 改为 `(auto_r \|\| j_pending)` 选择 seq 通路 + `if (!auto_r && !j_pending)` 分支（`nn_subsys.sv:359-362`） |
| P3 | copy FSM 读 nn_mem 与 CPU 访问冲突 | copy 期间 CPU 若访问 A/B 会抢读口 | copy 只在 `busy_o=1` 期间发生（CPU 写被挡、读得 DEADBEEF），固件协议不并发访问；`busy_o` 已含 `j_copy` |

---

## 7. 固件 `sw/nn_job_demo.c`（已编译 + 实测）

流程与判据（全机器判定）：
1. 读 `JOB_ID/STATUS`（实测 `id=0x4e503101`、`status0=0x10` = model_ready）；
2. `gen_input()` 生成 pattern_v1 输入（与 `yolo_demo.c` 逐字节同式），`input_csum` == golden `0xcfd271c5`；
3. **job A**：写 IN/OUT/MODEL/FRAME/LEN → doorbell → 等 busy → **重复 doorbell**（期望丢弃）→ 轮询 done；
4. 校验 status（done、无 err、done_ops=112）、`err_code=0`、`cycles=1,191,020`、frame 回显；
5. 校验邮箱 header（magic/frame/model/cycles/src/len）+ **payload 1024 B 与 `YOLO_FINALS[0].abs` 处逐字节一致**；
6. 校验两个检测头张量 FNV == `YOLO_FINALS[].csum`（golden，与 MODE_CPU/MODE_AUTO 逐位一致的同一组数）；
7. ACK → **job B**（重新生成输入、len=0）→ done/cycles 校验 → ACK；
8. `RESULT : PASS` + `report_done()`（tohost=1）。

**实测输出（节选）**：
```
[nnjob] id=0x4e503101 status0=0x00000010
[nnjob] input_csum=0xcfd271c5 exp=0xcfd271c5
[nnjob] drop_cnt=1
[nnjob] jobA status=0x00700092 cycles=1191020 err_code=0x00000000
[nnjob] final0 fnv=0x3cba6a95 exp=0x3cba6a95
[nnjob] final1 fnv=0x9e0c00d4 exp=0x9e0c00d4
[nnjob] mailbox magic=0x4e505552 frame=0x00001234 model=0 cycles=1191020 len=1024
[nnjob] jobB status=0x00700092 cycles=1191020
[nnjob] jobs_done=2 bad=0
[nnjob] RESULT : PASS
```
> `0x92` = bit1 done + bit4 model_ready + bit7 mbox_valid；`0x0070_xxxx` 中 `[23:16]=0x70=112` = done_ops。

**构建（Lead 已在 `tools/build_sw.py` 注册）**：`python tools/build_sw.py --all` 生成；
手工等价：`python tools/build_sw.py sw/nn_job_demo.c sw/portme.c -I sw --march rv32im --opt=-O2 -o sim/prog/nn_job_demo.hex`。

---

## 8. TB `sim/tb_sw_nn_job.sv`

- **独立新 TB**（未改 `tb_sw.sv`）：复刻 `tb_sw.sv:99-144` 的 core+mmio+nn 接线，50MHz 单时钟，NN_EN 编译；
- 判据：`tohost==1` → dump 程序日志 + **`NN_JOB_TB: PASS`**；tohost=2/非法指令/超时 → FAIL；
- plusargs：`+imem/+dmem`、`+nnwq=`、`+max_cycles`（默认 30M）、`+watchdog_ms`；
- Lead 已在 `tools/fpga_workflow.py:test_matrix()` 注册（defines=NN_EN、pass_marker="NN_JOB_TB: PASS"、max_cycles=1e8、timeout 3600）。

**实测**：`verify --only tb_sw_nn_job` → **PASS 29.0 s**。

---

## 9. 资源增量（估算，未跑综合）

| 资源 | 增量 | 依据 |
|---|---|---|
| BRAM36 | **+0** | 邮箱声明 `(* ram_style="distributed" *)` 512×32 → LUTRAM；不占 BRAM（现余 3 tiles 不动） |
| LUT | **≈ +290~350** | 邮箱 512×32 distributed RAM ≈ 256 LUT6 + Job 寄存器译码/FSM/mux ≈ 40~90 |
| FF | **≈ +430** | job 寄存器 ~14×32=448 中实际 9 个 32-bit 量 ≈288 + 计数器/状态 ≈140 |
| DSP | 0 | — |
| 时序风险 | 低 | 全部在 nn_subsys（非引擎关键路径）；copy FSM 在 job 完成后运行 |

> 精确 LUT/FF 以 Lead 的全实现综合报告为准；**BRAM 必须为 0 增量**（若有意外 BRAM 推断，需检查 `ram_style` 是否被覆盖）。

---

## 10. 回归结果（全量 `verify --force`）

**PASS 19**（0 FAIL / 0 SKIP），本次实测（旧 16 项 + 3 项新增全部 PASS）：

| # | 测试 | 耗时 | 结果 |
|---|---|---|---|
| 1–12 | `tb_units`/`tb_core_*`/`tb_soc*`/`tb_sw_hello`/`tb_sw_coremark`/`tb_sw_nn_demo` 等 | 2.5–14.9s | PASS |
| 13 | `tb_sw_nn_yolo`（YOLO E2E 不回退） | **84.1s** | **PASS**：`auto_bad=0`、`auto_npu_cycles=1,191,020`、`RESULT : PASS`（`.fpga-cache/logs/tb_sw_nn_yolo.log:56-57`） |
| 14 | `tb_nn_mem` | 3.1s | PASS（M2 47k checks 不回退） |
| 15 | `tb_nn_engine` | 5.5s | PASS |
| 16 | `tb_nn_seq` | 3.0s | PASS（含 job 看门狗输出改动后） |
| 17 | `tb_nn_wstream`（M3） | 3.3s | PASS |
| **18** | **`tb_sw_nn_job`（本任务）** | **29.0s** | **PASS（`NN_JOB_TB: PASS`）** |
| 19 | `tb_nn_tilecache`（M4） | 3.0s | PASS |

> 交付档（无 `NN_EN`）未动：所有新逻辑在 `NN_EN` 内/独立文件，无 `NN_EN` 时网表路径不变（本任务未改 `core.sv`/`top_a100t.sv`）。

---

## 11. 文件清单（本次实际改动）

| 文件 | 类型 | 说明 |
|---|---|---|
| `nn_subsys.sv` | 改 | Job 寄存器组 + 2KB 邮箱 + copy FSM + busy/CPU 窗口/seq 通路扩展 |
| `nn_seq.sv` | 改 | job 看门狗（64M/E4）+ `S_TIMEOUT` 排空 + `done_ops`/`job_timeout` 只读输出 |
| `sw/nn_job_demo.c` | 新增 | job 模式 demo 固件（判据见 §7） |
| `sim/tb_sw_nn_job.sv` | 新增 | SoC 级 job TB（pass_marker `NN_JOB_TB: PASS`） |
| `sim/prog/nn_job_demo.hex`、`.dmem.hex` | 生成 | 固件镜像（供 verify 条件登记） |
| `results/bottlecap/reports/M5-JOB-IF.md` | 新增 | 本报告 |
| `fpga/top_a100t.sv` | **未改** | job 接口复用已有 ext_*/nn_* 通路，无需接线 |
| `fpga/build.tcl`/`xdc`/`nn_pkg.sv`/`rv32_pkg.sv` | **未改**（Lead 已加常量/注册） | — |

---

## 12. S2（双时钟 CDC）交接清单

S2 按 `CPU-NPU-DECOUPLE.md` §3 执行（Lead 决策：S2 单独做；第一版 NPU 仍与 CPU 同域 100MHz）。需要改的文件：

| 文件 | S2 改动 |
|---|---|
| `fpga/top_a100t.sv` | MMCM `CLKOUT1_DIVIDE_F=10.5`（VCO1050，NPU=100MHz）+ `u_bufg_npu` + NPU 域复位同步器（全部 `ifdef NN_EN`；交付档 MMCM 例化逐字不变） |
| `nn_subsys.sv`（或抽出 `nn_job_if.sv`） | job 寄存器/结果邮箱迁到 CPU 域；新增 C1~C9：job payload+toggle（2FF）、ack、NPU reset、busy、done+result payload、2KB TDP BRAM 邮箱、DDR FIFO 对接 |
| 新 `nn_cdc_bridge.sv` | 仅调试寄存器相干读（Option W，盘古式 req/ack + 超时） |
| `core.sv` + `load_store_unit.sv` | **仅当启用 Option W**（`ext_ready`/`stall_external` 八处，`CPU-NPU-DECOUPLE.md` §3.4） |
| `fpga/daVinciPro.xdc` / `fpga/build.tcl` / `tools/fpga_workflow.py` | `create_generated_clock nn_clk`、`set_clock_groups -asynchronous`、`max_delay`、NPU 频点注入 |
| 新 `sim/tb_nn_cdc.sv` | 双时钟 150/100 随机 job 压力（payload 无撕裂/超时/复位隔离） |
| `nn_seq.sv` | S2/S3：`WAIT_PREFETCH`（M3）、tile 循环（M4）、`eng_abort`、软件可配超时 |

**S2 与 S1 的接口保持不变**：job 寄存器表（14 个）与邮箱布局不用改，只是把它们搬进 CPU 域 + 加 CDC；`nn_seq` 的 `start/done/cycles/err/job_timeout` 语义不变。

---

## 13. 与后续里程碑的衔接

- **M3 权重流式**：`nn_seq` 在 `S_FETCH` 前插 `WAIT_PREFETCH`（`nn_wload` 已交付，`tb_nn_wstream` PASS 3.3s）；job 的 `NN_JOB_IN/OUT` 地址就是 DDR arena 偏移。
- **M4 激活 tiling**：`nn_tilecache` 已交付（`tb_nn_tilecache` PASS 3.0s）；job 模式下 tile 循环由 `nn_seq` 驱动、对 job 接口透明。
- **M6 瓶盖 E2E**：job 模式已能跑完整个 ROM（本报告 112 op/1,191,020 拍为证），换 ROM/权重即可跑瓶盖模型；逐 op FNV 判据沿用 converter 的 `results/bottlecap/plan/` golden。
- **S2 双时钟**：可与 M3/M4 并行（接口不变）。
