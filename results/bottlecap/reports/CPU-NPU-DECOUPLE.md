# CPU-NPU 解耦架构设计（盘古式：双时钟域 + Job 接口 + 帧流水线）

> 任务：task-10。作者：npu-spec。日期：2026-11-03（Asia/Shanghai）。状态：**设计（不改 RTL）**。
> 输入/必读：`work/pango_bl/vision/{ARCHITECTURE,CLOCK_SPLIT,MODES,BOARD_VALIDATION}.md` + `rtl/{vision_mmio_bridge,vision_soc,vision_snapshot,vision_npu,vision_cpu_clock,vision_video_bridge}.v` + `firmware/numeric_main.c`；
> 本仓 `fpga/top_a100t.sv`、`core.sv`、`load_store_unit.sv`、`hazard_unit.sv`、`nn_subsys.sv`、`nn_seq.sv`、`nn_mem.sv`、`nn_pkg.sv`、`rv32_pkg.sv`、`csr_file.sv`、`fpga/{build.tcl,daVinciPro.xdc}`、`results/ai-accel/{CONTRACT,DELIVERY}.md`、`results/bottlecap/reports/PLAN-V1.md`、`results/bottlecap/ddr3/{DDR3-FEASIBILITY,WEIGHT-STREAMING-DESIGN,ROM-V1}.md`。
> 纪律：本文件只写**设计**；每条结论带 `文件:行号` 证据；不改 RTL/顶层/约束。机器可读版：[`cpu_npu_interface.json`](cpu_npu_interface.json)。

---

## 0. 结论速览（TL;DR）

| 问题 | 结论 | 关键数字/证据 |
|---|---|---|
| CPU 150MHz + NPU 独立 100MHz（MMCM 双输出）可行吗？ | **可行**，VCO 1050MHz 下 CPU=1050/7、NPU=1050/10.5 都精确；XDC 生成时钟用整数比 `-multiply_by 2 -divide_by 1` | `fpga/top_a100t.sv:107-142`、`fpga/daVinciPro.xdc:28-31`、`fpga/build.tcl:159-199,305-326`；§3.1 |
| 122.22MHz 能同源吗？ | **不能精确**（1050/122.22=8.591，MMCM 小数分频步进 0.125）；可选 **121.74MHz**（8.625，−0.4%）或换 VCO 1200 得 **120MHz** | 频率表见 §3.1；`results/ai-accel/DELIVERY.md:233-244`（122.22 为已验证最高） |
| CDC 有多少项？ | **10 项**：CPU→NPU 4（job payload/toggle/ack 回程/复位）、NPU→CPU 4（busy/done+payload/result mailbox/可选 IRQ）、共享存储 1（结果邮箱 TDP BRAM）、DDR 侧 1 组（M3 已有 nn_wload 异步 FIFO） | §3.2 |
| Job 接口多大？ | **20 个 32-bit MMIO 寄存器 + 2KB 结果邮箱**（CPU 1 拍读）；CPU 只写 5 个字段 + 1 个 doorbell，NPU 自主跑完整个 ROM | §4；寄存器表 §4.2 |
| 要不要改 core / LSU？ | **分两条路**：**Option P（推荐第一版）= 0 改动**（job/status 全放 CPU 域，posted 写 + 镜像读）；**Option W（盘古同款相干 MMIO）= 改 core 3 处 + LSU 1 个输入**（逐行见 §3.4），两者都保留 | §3.3/§3.4 |
| 最小第一步 | **S1 单时钟 job 接口（不动 core/时钟）→ S2 双时钟+CDC → S3 帧流水线**；S1 完成后 `verify --force` 从 PASS 16 变 PASS 17，旧 16 项逐项不变 | §9 |
| 解耦能提高帧率吗？ | **解耦本身不增加 NPU 算力**（2.27GMAC → 40.06M 拍≈2.5fps@100MHz）；它买到的是 **CPU 不再被逐 op 拖住 + NPU 可独立提频/独立复位 + 可与 task-11 阵列加宽并行**。122MHz+256MAC 组合可到 ~6fps 量级 | §8；`results/bottlecap/reports/PLAN-V1.md:98-102` |
| 最大风险 | ① MIG/DDR3 未接入（仓库零证据，需用户 6 项输入）；② CDC 约束/复位隔离做错会"偶发错一帧"；③ 结果一致性（torn payload）；④ BRAM 只剩 3 tiles，tile cache 必须靠 W 银行缩容腾 | §10；`results/bottlecap/ddr3/DDR3-FEASIBILITY.md:16-27,49-73` |

**一句话**：把"CPU 逐 op 写 46 个寄存器 + 轮询"换成"CPU 写 1 个 job（输入/输出/模型/帧号）→ doorbell → NPU 自主跑 ROM → done/err + 结果邮箱 → ack"，并把 NPU 放进独立 100MHz 时钟域（CPU 保持交付档 150MHz），核心新增只有 **1 个 job 壳 + 1 个结果邮箱 + 可选 1 个 CDC 桥**；**第一版不需要改 core**，第二版（相干 MMIO 读）再按盘古的 `ext_ready`/`stall_external` 做最小改动。

---

## 1. 参考架构提取（盘古 vision，本机可读）

### 1.1 盘古做了什么（逐条事实）

| # | 盘古事实 | 证据（`work/pango_bl/vision/`） | 对本设计的映射 |
|---|---|---|---|
| P1 | **CPU/IMEM/DMEM 独立 125MHz 域；NPU+相机+MMIO 50MHz**，跨域"带等待的请求/应答握手" | `ARCHITECTURE.md:5`；`CLOCK_SPLIT.md:5,13-22` | 我们改 CPU 150 / NPU 100（交付档 CPU 频率不降） |
| P2 | MMIO 桥：**一个未完成事务**的 req/ack 翻转位握手；CPU 锁存方向/地址/数据/字节选通，等待外设域处理后返回；每事务只在外设域产生 1 拍读/写；翻转位两级同步；**只对同步器首级和复位异步端放宽约束** | `rtl/vision_mmio_bridge.v:22-92`；`CLOCK_SPLIT.md:26` | `nn_cdc_bridge`（§3.3）1:1 对应 |
| P3 | CPU 新增 `ext_ready` 等待：**只有访问 MMIO 时停顿流水线**，IMEM/DMEM 仍直连；等待期间**保持 LSU 访问状态、读数据选择、上一条写回数据** | `CLOCK_SPLIT.md:28`；`rtl/cpu/core.v:172-173,470,512,540-554,595`；`rtl/cpu/load_store_unit.v:6,30,127` | §3.4 的 core/LSU 最小改法（本仓对应行号） |
| P4 | NPU 自主推理：`start` 只在 `!done` 时受理；`acknowledge` 清 done；busy/done/cycles + 结果 RAM 按索引读（写索引后插 2 个 NOP 再读） | `rtl/vision_npu.v:3-17,64,116-123`；`firmware/numeric_main.c:32-36,197-213` | Job 接口 = doorbell/done/ack + 结果邮箱；本仓读延迟用 1 拍寄存读（比 2 NOP 更省） |
| P5 | 推理期间**不暂停摄像头/LCD**；卷积忙或结果待 CPU 确认时**丢弃后续识别快照** | `ARCHITECTURE.md:20,45`；`rtl/vision_snapshot.v:50-71`（PAD/WAIT_FRAME/CAPTURE/WAIT_NPU；`!busy && !done` 才捕获/启动） | 输入双缓冲 + 忙时丢帧 + 结果 ack 前不启动新 job（§5） |
| P6 | 显示提交在 **LCD 帧边界**整包更新（防撕裂）；其它模块各自双缓冲交换 | `ARCHITECTURE.md:20,89`；`rtl/vision_soc.v:269-280`（`commit_pending && frame_tick`） | 输出三缓冲 + 帧边界/seq 提交（§5.2） |
| P7 | **NPU 私有存储**：双模型 ROM 64KiB + 激活双区 16KiB + **结果 2KB** + 偏置 2KiB；与 CPU 的 16KiB IMEM/DMEM 分离；CPU **不直接访问 NPU RAM** | `ARCHITECTURE.md:53`（资源表）；`ARCHITECTURE.md:12-18`（数据通路） | 结果邮箱 2KB；权重/Q/arena 进 DDR3（§6） |
| P8 | MMIO 基址 `0xA1000000`，状态寄存器含：图像有效/NPU 忙/NPU 完成/请求启用推理/冻结/彩条/无模型 | `ARCHITECTURE.md:61,64-88` | Job STATUS 位定义（§4.2） |
| P9 | 跨域多 bit 载荷用"**payload 保持 + toggle/ack**"（视频桥在帧边界交接 272-bit 包） | `rtl/vision_video_bridge.v:15-82`；`rtl/vision_snapshot.v` | Job payload（~112 bit）与结果 payload（~96 bit）用同一模式 |
| P10 | 时钟域复位：两个 PLL 都锁定后才释放；锁定丢失则保持复位 | `CLOCK_SPLIT.md:7`；`vision_cpu_clock.v:3-31` | 两个域各自"锁定+软件复位"同步释放（§7） |
| P11 | 盘古 NPU 单次推理 **1,769,238 周期 @50MHz ≈ 35.38ms**；CPU 提频**不会缩短该计算** | `ARCHITECTURE.md:45`；`CLOCK_SPLIT.md:46` | 明确"解耦≠提速"（§8） |

### 1.2 盘古 vs 本仓现状差距（一句话每条）

| # | 维度 | 盘古 | 本仓现状（证据） | 差距 |
|---|---|---|---|---|
| F1 | 时钟 | CPU 125 / NPU+MMIO 50 双域 | **全部同域 `sys_clk_core`**：core/mmio_subsys/nn_subsys 同钟（`fpga/top_a100t.sv:192,228-256,270-295`）；MMCM 只有 CLKOUT0（`:107-142`） | 需第二路时钟 + BUFG + 复位隔离 |
| F2 | CPU 参与推理 | 只写使能 + 读结果 | **逐 op 写 14 个描述符寄存器并轮询**（`nn_subsys.sv:307-350`；`sw/yolo_demo.c` hw_run）或 MODE_AUTO 写一次 start（`nn_subsys.sv:314-318`）但**无 job 参数、无帧号、无结果邮箱** | 需 job 级接口（§4） |
| F3 | NPU 私有内存 | 结果 RAM 2KB，CPU 不碰 NPU RAM | **CPU 通过 NN 窗口直接读写 A/B**（`core.sv:1541-1546`；`nn_subsys.sv:147-149`），busy 时返回 `0xDEADBEEF` | 解耦模式关闭 CPU A/B 窗口，改结果邮箱（§6.3） |
| F4 | 频率 | 已分离（125/50） | AI 档为凑时序把 **CPU 也降到 100MHz**（`DELIVERY.md:223-230,241`） | 解耦后 CPU 回 150（交付档），NPU 独立 100/121.74 |
| F5 | 输入/输出流水 | 相机双缓冲，忙时丢帧，帧边界提交 | **输入由 CPU 软件逐字节生成到 A**（`sw/yolo_demo.c:111-125`）；输出由 CPU 读 A/B | 需帧双缓冲/三缓冲 + 丢帧策略 |
| F6 | 异常/中断 | 状态轮询 + 1 秒无结果判故障（`firmware/numeric_main.c:200-206`） | done/err 粘滞（`nn_subsys.sv:352-381`），**无 job 超时、无 IRQ 到 CPU**（core `irq_ext` 恒 0：`core.sv:1039`） | 需 job 看门狗 + 可选 IRQ |

---

## 2. 目标架构

### 2.1 时钟域与模块归属（图）

```
                    sys_clk 50MHz
                          │
                 ┌────────┴─────────┐
                 │  MMCME2_BASE     │  VCO=1050MHz (MULT=21, DIVCLK=1)
                 │  CLKOUT0 /7      │  CLKOUT1 /10.5
                 └───┬──────────┬───┘
              ┌──────▼───┐  ┌───▼──────────┐
              │ u_bufg_sys│  │ u_bufg_npu   │
              └──────┬───┘  └───┬──────────┘
   ┌─────────────────▼──CPU域──────────────┐   ┌─────────▼──NPU域────────────────┐
   │ core (RV32IM, 150MHz)                  │   │ nn_subsys (100/121.74MHz)        │
   │ imem/dmem (16KB each)                  │   │  ├ nn_seq (ROM 微码自主)          │
   │ mmio_subsys (UART/timer/cycle, 150MHz) │   │  ├ nn_conv_engine v3/v4          │
   │ nn_job_if（job 寄存器 + 状态镜像）      │   │  ├ nn_mem (W 双银行/Q 影子/A,B)   │
   │ nn_result_mailbox 读口（2KB, 1 拍）    │   │  ├ nn_wload (→DDR ui_clk FIFO)   │
   │ ext_* 总线（CPU 域外设 0 等待）         │   │  └ nn_tilecache (M4)             │
   └───────┬───────────────────┬───────────┘   └───────┬──────────────────────────┘
           │  job payload/toggle │  done/result        │ DDR 读写（128b burst）
           └──── nn_cdc_bridge / nn_job_cdc ────────────┘
                                                       ▼
                                              beh_ddr3 / MIG（DDR 域，ui_clk）
```

### 2.2 设计原则（与盘古一致的三条 + 我们的一条）

1. **CPU 只做"提交 job / 收结果 / 非 NPU 工作"**：推理期间 CPU 不暂停、不轮询每个 op（对齐 P4/P5）。
2. **每个时钟域各自复位、各自约束同步器**：跨域只走三类结构（2FF、toggle+稳定 payload、TDP BRAM）（P2/P9）。
3. **忙时丢帧、结果 ack 前不起新 job**：流控在硬件，不在软件轮询（P5）。
4. **（我们额外）双模兼容**：新增全部挂在 `NN_EN` + 参数默认关闭下；`w_mode=0`/单时钟时行为与当前**逐位一致**，`verify --force` 的 16 项不许回退（`results/bottlecap/reports/PLAN-V1.md:65-71`）。

---

## 3. 双时钟域方案

### 3.1 MMCM 双输出可行性与频率表

当前：板载 50MHz → `MMCME2_BASE`（VCO = 50×21 = **1050MHz**），`CLKOUT0_DIVIDE_F=NN_CLK_DIV`（默认 7 → **150MHz**）→ `BUFG` → `sys_clk_core`，**CLKOUT1..6 悬空**（`fpga/top_a100t.sv:107-142,151-154`；`fpga/build.tcl:305-326`；XDC 生成钟 `-multiply_by 21 -divide_by 7`，`fpga/daVinciPro.xdc:28-31`）。

| CPU | NPU | VCO | CLKOUT0_DIV | CLKOUT1_DIV | XDC 生成钟（对 sys_clk 的整数比） | 备注 |
|---:|---:|---:|---:|---:|---|---|
| **150** | **100** | 1050 | 7.0 | **10.5** | `-multiply_by 2 -divide_by 1` | **推荐第一版**（NPU 已在此频点 WNS +0.136 全实现通过，`DELIVERY.md:223-230`） |
| 150 | 105 | 1050 | 7.0 | 10.0 | `-multiply_by 21 -divide_by 10` | 历史已验证档（`DELIVERY.md:128`） |
| 150 | **121.74** | 1050 | 7.0 | **8.625** | `-multiply_by 56 -divide_by 23` | 比 122.22 低 0.4%；需要重新全实现确认（NPU 域余量未知） |
| 150 | 120 | 1200 | 8.0 | 10.0 | `-multiply_by 12 -divide_by 5` | 换 VCO=1200（MULT=24）；MMCM VCO 上限边界，需重验 |
| 150 | 122.22 | — | — | — | **不可精确**（1050/122.22=8.591，非 0.125 倍数） | `DELIVERY.md:241` 的 122.22 是 VCO=1100（MULT=22）/9 得到，与 CPU150 不能同 VCO |

**结论**：可行；推荐 `CPU 150 / NPU 100` 起步（两域都精确、NPU 时序已验证），121.74 作为第二档（+21.7% 算力，但需重跑全实现）。

**落地要点**（实现时 Lead 负责）：
1. `top_a100t.sv` 的 MMCM 增加 `CLKOUT1_DIVIDE_F` 参数与 `.CLKOUT1(clk_npu_raw)` 连接；**参数/端口只在 `ifdef NN_EN`（或新宏 `NN_DUAL_CLK`）下存在**，交付档（无 `NN_EN`）MMCM 例化逐字不变（`top_a100t.sv:107-115` 已有 ifdef 分支的范式）。
2. 新增 `BUFG u_bufg_npu`，输出网名 `nn_clk`（与 XDC 生成钟同名，`top_a100t.sv:144-150` 的命名纪律）。
3. XDC 增加 `create_generated_clock -name nn_clk -source [get_ports sys_clk] -multiply_by <整数> -divide_by <整数> [get_pins u_bufg_npu/O]`（XDC 只接受整数乘除，所以用等价比；`fpga/daVinciPro.xdc:28-31` 同一写法）。
4. 构建脚本：`tools/fpga_workflow.py`/`build.tcl` 增加 `NN_NPU_CLK_DIV_F` 注入（与 `NN_CLK_*` 同源，`build.tcl:159-199,305-326`），日志自证 `BUILD_NPU_CLK=...`。
5. 约束：`set_clock_groups -asynchronous -group [get_clocks sys_clk_core] -group [get_clocks nn_clk]`；跨域载荷加 `set_max_delay -datapath_only`（±半个目标周期）；同步器用 `(* ASYNC_REG="TRUE" *)`（对齐盘古"只放宽同步器首级和复位异步端"，`CLOCK_SPLIT.md:26`）。

### 3.2 CDC 清单（10 项）

> 方向记法：C→N = CPU 域→NPU 域；N→C 反之。所有单 bit 控制用 2FF（`ASYNC_REG`），多 bit 用"稳定 payload + toggle"或 TDP BRAM。

| # | 通道 | 方向 | 信号/位宽 | 方法 | 约束/备注 | 证据/参考 |
|---|---|---|---|---|---|---|
| C1 | **job payload** | C→N | `job_in[31:0] job_out[31:0] job_model[7:0] job_flags[7:0] job_frame[31:0]` ≈ 112 bit | CPU 侧寄存器组 + **保持到 ack**；toggle 触发 NPU 侧锁存 | `set_max_delay -datapath_only`；payload 在 ack 前不变 | `vision_video_bridge.v:15-82` 同构 |
| C2 | **doorbell toggle** | C→N | 1 bit | 2FF `ASYNC_REG` | toggle 翻转即"有新 job"；NPU 侧 `req_sync != req_seen` 受理 | `vision_mmio_bridge.v:79-91` |
| C3 | **job ack toggle** | N→C | 1 bit | 2FF | NPU 受理/完成后回翻；CPU 清 pending | 同上 |
| C4 | **NPU 软复位** | C→N | 1 bit level（W1P） | 异步置位 / 同步释放（每域复位同步器） | 复位异步端 false-path；释放路径按同步器约束 | `CLOCK_SPLIT.md:7,26`；`top_a100t.sv:159-167` 同构 |
| C5 | **busy 电平** | N→C | 1 bit | 2FF（可 3FF 取稳定） | 仅用于展示/丢帧判断，允许滞后 2-3 CPU 拍 | 同 P8 状态位 |
| C6 | **done toggle** | N→C | 1 bit | 2FF | 与 C7 配对；CPU 见翻转才采样 C7 | `vision_mmio_bridge.v:43-63` 反向 |
| C7 | **result payload** | N→C | `frame_no[31:0] cycles[31:0] err[7:0] status[7:0]` ≈ 80 bit | NPU 锁存后置 done toggle；CPU 侧采样并转存 | payload 在下次 job 启动前不变 | 同 C1 |
| C8 | **ack 回程** | C→N | 复用 C3 + `ack` 脉冲 | toggle 回翻即 ack | — | 同 P4 |
| C9 | **结果邮箱数据** | N→C | 2KB（512×32b） | **TDP BRAM**（写口 NPU 时钟、读口 CPU 时钟；无同步器） | 写完成 → 置 done（C6）；读侧只看 done 后数据 | Xilinx RAMB36 双独立时钟；pangu "结果 2KB" `ARCHITECTURE.md:53` |
| C10 | **DDR ui_clk ↔ NPU** | N↔DDR | 权重/Q/tile 128b 流 | `nn_wload` 内异步 FIFO（M3 已有） | FIFO 两级同步 + `set_max_delay` | `nn_wload.sv:23-30,58-100`；`sim/beh_ddr3.sv:25-44` |
| C11（可选） | **NPU IRQ** | N→C | 1 bit level | 2FF → core `irq_ext`（MEIP） | 交付档 core 无 `NN_EN` 时 tie 0 | `csr_file.sv:62-63,137-144`；`core.sv:1039` 现 tie 1'b0；`rv32_pkg.sv:434-435` |

**合计 11 条通道（其中 C11 可选）→ 记 10 项必做 + 1 可选。**

### 3.3 `nn_cdc_bridge` 模块接口（盘古 1:1 对应，用于"相干 MMIO 读"）

```systemverilog
module nn_cdc_bridge #(
  parameter int unsigned TIMEOUT_CYCLES = 1024     // CPU 域超时（≈6.8us @150MHz）
)(
  // ---- CPU 时钟域 ----
  input  logic        cpu_clk, cpu_rst,
  input  logic        cpu_req,          // 电平：有访问（= ext_we||ext_re 且命中 NPU 段）
  input  logic        cpu_we,
  input  logic [31:0] cpu_addr,
  input  logic [31:0] cpu_wdata,
  input  logic [3:0]  cpu_wstrb,
  output logic        cpu_ready,        // 1 = 本拍返回（core 的 ext_ready）
  output logic [31:0] cpu_rdata,
  output logic        cpu_timeout,      // 事务超时（sticky，软件可清）
  // ---- NPU 时钟域 ----
  input  logic        npu_clk, npu_rst,
  output logic        npu_re, npu_we,
  output logic [31:0] npu_addr, npu_wdata,
  output logic [3:0]  npu_wstrb,
  input  logic [31:0] npu_rdata
);
```

内部结构（与 `vision_mmio_bridge.v` 一致，`:22-92`）：
- CPU 侧 `IDLE → WAIT_RESPONSE → RETURN_RESPONSE`，锁存 70-bit 请求 `{we,re,addr[31:0],wdata[31:0],wstrb[3:0]}`，`cpu_ready = (state==RETURN_RESPONSE)`；
- 双向 toggle（request/response）+ 各 2FF；NPU 侧 `execute_request` 单拍脉冲、回送 `{response_toggle, held_response}`；
- **超时**：CPU 侧等待计数器 > `TIMEOUT_CYCLES` → 强制回 IDLE、`cpu_timeout=1`（粘滞），由软件写清；NPU 侧另设"stale toggle"看门狗（> 4×超时未见端到端变化则自清）。
- 约束：所有 toggle 首级 `ASYNC_REG`；payload 路径 `set_max_delay -datapath_only` ≤ min(T_cpu, T_npu) 的 1 个周期。

**用途**：解耦模式下仅用于"NPU 私有调试寄存器/ID/性能计数器"的相干读；**job/status/结果不经过它**（走 §4 的 posted 通道），因此**第一版可不实现本模块**，仅预留代码位置（`nn_job_if` 的 debug 旁路）。

### 3.4 "带等待"的 MMIO wait-state 协议与 core/LSU 最小改法（Option W）

**问题**：本核当前 MMIO 是**组合读**（外设同拍给 `ext_rdata`，core 再寄存一拍），**没有任何 `ext_ready`/wait 机制**（`core.sv:74-80` 只有 `ext_we/ext_re/ext_addr/ext_wdata/ext_wstrb/ext_rdata`；`results/ai-accel/CONTRACT.md:43` 明确"本核 ext 通路没有 wait-state 机制"）。若 NPU 寄存器在另一个时钟域，必须让 CPU 等待。

**结论：LSU 要改（1 个输入 + 状态机门控），core 要改（3 处）。** 这是盘古做过的同一套改动，逐行对照如下（本仓行号 ↔ 盘古行号）：

| # | 改动 | 本仓位置（现状） | 改法 | 盘古对照 |
|---|---|---|---|---|
| W1 | core 增加 `ext_ready` 输入（`NN_EN` 内） | `core.sv:74-80` 端口区 | `input logic ext_ready;` | `core.v:48`（`input wire ext_ready`） |
| W2 | 产生 `external_wait` | core.sv 内新增 wire（建议紧随 ext 端口声明） | `wire external_wait = NN_EN_WAIT && (ext_we \|\| ext_re) && !ext_ready;`（`ext_we/ext_re` 在 `:1576-1582` 生成，见 W4 顺序说明） | `core.v:172-173` |
| W3 | 把 wait 并入流水线停顿 | **`core.sv:1281`**（hazard_unit 例化处：`.lsu_stall(lsu_stall)`） | `.lsu_stall(lsu_stall \|\| external_wait)`（一行） | `core.v:470` |
| W4 | 让 LSU 冻结 | `load_store_unit.sv:285-309`（状态机无 stall 输入，每拍无条件推进）；`:335,372-377`（头字/规格捕获） | 新增 `input logic stall_external`；状态机与捕获整体用 `if (!stall_external)` 门控（盘古做法：`load_store_unit.v:6,30,127` 的 `else if (!stall_external) begin ... end`） | 同左 |
| W5 | 读数据/选择信号在等待期间保持 | `core.sv:1548-1560`（`ext_rdata_r <= ext_rdata; sel_dmem_r <= sel_dmem;` 每拍无条件） | 改成 `if (!external_wait) begin ext_rdata_r <= ext_rdata; sel_dmem_r <= sel_dmem; sel_nn_r <= sel_nn; end` | `core.v:540-545` |
| W6 | WB 数据保持 | 本核默认（未开 `LOAD_RESULT_REG`）`wb_data` 取 `mem_load_data`（LSU 组合输出，`core.sv:1633-1647`）；W5 之后其输入（`ext_rdata_r`）稳定，故**可省**盘古的 `wait_wb_data` | 可选：若开 `LOAD_RESULT_REG` 也不需要改；若将来改成 MEM/WB 直连组合读，则按盘古 `core.v:171,546-554,595` 加 `wait_wb_data` | `core.v:517-554,595` |
| W7 | `ext_ready` 来源 | 顶层 `fpga/top_a100t.sv:263-266`（`nn_mmio_sel`/`ext_rdata` 回选） | `ext_ready = nn_mmio_sel ? nn_ready : 1'b1;`；`nn_ready` 来自 `nn_cdc_bridge`；非 NPU 外设（mmio_subsys）恒 ready，保持 1 拍 | 盘古所有 MMIO 都在慢域，恒走 wait；我们只对 NPU 段 wait |
| W8 | 交付档隔离 | `top_a100t.sv:263-299`（`ifdef NN_EN` 回选） | `ext_ready` 端口与 wait 逻辑**全部在 `ifdef NN_EN` 内**；无 `NN_EN` 时 core/mmio 逐字不变 | `PLAN-V1:65-71` 红线 |

**代价与判据**：
- 每次 NPU 寄存器访问 CPU 停顿 ≈ `2×(同步 2FF) + 1 执行 + 2 回程同步 ≈ 6~9 CPU 拍`（150/100 比 1.5）；job 提交 5 次写 + 1 次 doorbell ≈ 60 拍，可忽略；**状态轮询不要走 wait 桥**（用 §4 的 CPU 域镜像，1 拍）。
- 判据：`tb_sw` 既有 MMIO 用例逐拍不变（无 `NN_EN` 或 `NN_EN_WAIT=0` 时 `external_wait` 恒 0）；新增 `tb_nn_cdc` 验证 wait 下读/写字节正确、无重复副作用（写只执行一次）。
- **注**：W4 会改 `load_store_unit.sv`，它被**所有**测试编译；必须保证 `stall_external=0` 时逐拍不变（生成一个 `if (!stall_external)` 外层即可，综合可折叠）。

**Option P（推荐第一版，0 改动）如何替代**：
- job 寄存器与状态镜像**全部放在 CPU 时钟域**（`nn_job_if` 内）；CPU 写 job 是普通寄存器写（1 拍），读 STATUS 是 CPU 域镜像（1 拍）；
- 只有 "job payload + toggle" 与 "done + payload" 跨界，它们用稳定 payload + toggle（C1/C6），**不需要 CPU 等待**；
- 结果邮箱是 TDP BRAM（C9），CPU 侧就是 1 拍寄存读（与现有 nn 窗口同口径，见 `core.sv:1548-1560`）；
- 好处：**core/LSU/tb_sw 全不动**，第一版风险最低；代价：NPU 私有调试寄存器若要从 CPU 读，要么加 wait 桥（Option W），要么放弃（用 ILA/UART 读）——对当前需求无影响。

### 3.5 复位与时钟使能

| 域 | 复位源 | 释放条件 | 证据 |
|---|---|---|---|
| CPU 域 | `sys_rst_n` 异步置位 | `sys_rst_n` 释放 **且** `mmcm_locked`，3 级同步释放 | `top_a100t.sv:156-167`（现有实现，保留） |
| NPU 域 | `~sys_rst_n` **或** `~mmcm_locked` **或** CPU 写的 `npu_reset`（W1P） | 同上 + `npu_reset` 清零；NPU 域内 3 级同步释放 | 新增；范式同 `top_a100t.sv:159-167` |
| DDR 域 | MIG 自己的 `ui_clk_sync_rst`（未来） | MIG 输出 | 待 MIG 接入（`DDR3-FEASIBILITY.md:49-73`） |

- NPU 复位**不影响 CPU**：CPU 可继续跑（写 job 之外的代码、UART、timer），符合"解耦"；NPU 复位时 `job_if` 清 pending、结果邮箱保留（由 CPU 显式清）。
- 时钟使能：两域都自由运行；**不做门控**（避免 MMCM 输出门控带来的相位/时序风险）。
- 复位隔离判据：`npu_reset` 期间 CPU 读写 NPU 段：写被丢弃并置 `NN_STATUS.rst=1`；读返回 0（不是 `0xDEADBEEF`，因为那是"忙"的语义）。

---

## 4. Job 级接口

### 4.1 设计原则

- **盘古等价物**：`status`（busy/done/请求启用）+ `result RAM` + `start`/`acknowledge`（`vision_soc.v:143-170,232-240`；`vision_npu.v:116-123`）。
- **我们的 job**（比盘古多两个字段，因为 NPU 要从 DDR 取输入/存输出）：输入 arena 地址、输出 arena 地址、模型号、帧号；**一个 doorbell 启动整个 ROM**（`nn_seq` 已有自主执行，`nn_seq.sv:122-139`）。
- **寄存器放 CPU 域**（Option P）：CPU 写 job 不进 CDC；doorbell 时把 5 个字段一次性捕获进"posted payload"（稳定到 ack），只跨一个 toggle（C1/C2）。
- **状态镜像**：NPU 侧 `busy/done/err/cycles/frame_no` 在 job 完成时锁存，随 done toggle 送 CPU 域（C5/C6/C7）。
- **流控**：`done` 未被 ack 前 NPU 不接新 job（盘古 `start && !done`，`vision_npu.v:118`）；busy 期间 doorbell 写入 → 丢弃并计数（盘古"忙时丢弃新快照"，`ARCHITECTURE.md:20`）。可选 1 深 pending 队列（doorbell 在忙时可暂存 1 个，当前 job 完成 + ack 后自动启动）——默认关闭（`CTRL2.pending_en=0`）。

### 4.2 寄存器表（20 个 32-bit 寄存器；基址沿用 NPU MMIO 段 `0xA000_0150` 起）

> 地址空间：`top_a100t.sv:265` 的 `nn_mmio_sel = (ext_addr[31:8]==24'hA00001)` 已覆盖 `0xA000_0100..0x01FF`；现有寄存器止于 `DBG2=0xA000_0148`（`rv32_pkg.sv:385-403`），`0x150..0x1FF` 空闲，可容纳 44 个新寄存器（本设计用 20 个）。

| 偏移 | 名字 | R/W | 复位 | 语义（位定义） |
|---|---|---|---|---|
| `0x150` | `NN_ID` | R | `0x4E50_3101` | 签名 `"NP"` + 版本 v1；NPC 版本：bit[7:0]=0x01, bit[31:8]=0x4E5031 |
| `0x154` | `NN_STATUS` | R | 0 | bit0=busy（镜像），bit1=done（粘滞，ACK 清），bit2=err，bit3=irq，bit4=job_pending（已受理未完成），bit5=model_ready，bit6=npu_rst，bit7=timeout；[15:8]=err_code；[31:16]=npu_state（调试） |
| `0x158` | `NN_FRAME_NO` | R | 0 | 最近完成 job 的帧号（与 done 一起锁存） |
| `0x15C` | `NN_CYCLES` | R | 0 | 最近 job 的 NPU 域周期数（来自 `nn_seq.cycles`，`nn_seq.sv:118`；YOLO 口径 1,191,020） |
| `0x160` | `NN_JOB_IN` | W/R | 0 | 输入 arena 字节地址：bit31=0 → DDR3 arena 偏移（M4 路径）；bit31=1 → 片上 A 偏移（legacy 路径） |
| `0x164` | `NN_JOB_OUT` | W/R | 0 | 输出 arena 字节地址（DDR3 偏移 / 片上 B 偏移，同 bit31） |
| `0x168` | `NN_JOB_MODEL` | W/R | 0 | [7:0]=model_id（0=YOLO-C128,1=Bottlecap-224,2=Slim-160,3=YOLO-C320）；[15:8]=ROM 表起始 idx（v1 多模型时用）；bit16=irq_en，bit17=debug_csum，bit18=onchip_io，bit19=auto_start（帧到即启动） |
| `0x16C` | `NN_JOB_FRAME` | W/R | 0 | 本 job 的帧号（回显到 `NN_FRAME_NO`） |
| `0x170` | `NN_DOORBELL` | W/R | 0 | 写 1 = 提交 job；读：0=无 pending，1=已受理/运行中；busy 时写 1 → 丢弃并 `NN_DROP_CNT+1` |
| `0x174` | `NN_ACK` | W | 0 | 写 1 = 清 done/err/irq、释放结果邮箱（盘古 `acknowledge`，`vision_npu.v:116`） |
| `0x178` | `NN_DROP_CNT` | R | 0 | 被丢弃的 doorbell/帧计数（丢帧诊断，盘古无但需要） |
| `0x17C` | `NN_TIMEOUT` | W/R | `0x05F5E100`（100M NPU 拍） | job 看门狗阈值（0=关闭）；超时 → err_code=0xE4 |
| `0x180` | `NN_ERR_CODE` | R | 0 | 粘滞错误码（0=OK；0xE1 描述符/ROM 非法，0xE2 CPU 窗口越权，0xE3 单 op 超时，0xE4 job 超时，0xE5 ROM 跑飞，0xE6 DDR/预取错，0xE7 模型号不支持；高 8 位 = 出错 op idx） |
| `0x184` | `NN_CTRL2` | W/R | 0 | bit0=npu_reset（W1P，自清），bit1=irq_en，bit2=debug_mode（逐 op csum），bit3=pending_en（1 深队列），[7:4]=保留，[15:8]=drop_policy（0=drop new，1=overwrite oldest） |
| `0x188` | `NN_JOBS_DONE` | R | 0 | 完成 job 累计计数（CPU 域计数，用于软件对账） |
| `0x18C` | `NN_NPU_STATE` | R | 0 | NPU 域调试：{seq_state[3:0], op_idx[7:0], pre_busy, tile_busy} |
| `0x190` | `NN_FRAME_IN` | W/R | 0 | 输入帧槽基址（双缓冲 slot0/slot1 的 DDR 偏移，或片上 A） |
| `0x194` | `NN_FRAME_STATUS` | R | 0 | bit0=frame_ready（新帧已提交），bit1=frame_lost；[15:8]=slot，[31:16]=最新帧号低 16 位 |
| `0x198` | `NN_RESULT_PTR` | R | 0 | 当前结果槽：{slot[1:0], addr[29:0]}（输出三缓冲之一） |
| `0x19C` | `NN_RESULT_CSUM` | R | 0 | 结果头 FNV-1a（防撕裂/对账；盘古 dump 用 CRC32，`ARCHITECTURE.md:95`） |

> 合计 **20 个寄存器**（`0x150..0x19C`），其中 CPU 写 6 个（JOB_IN/OUT/MODEL/FRAME/DOORBELL/ACK），其余读。

### 4.3 结果邮箱（2KB，CPU 1 拍读）

| 项 | 设计 | 依据 |
|---|---|---|
| 容量 | **2KB = 512×32b**（盘古结果 RAM 也是 2KB，`ARCHITECTURE.md:53`） | 1 个 BRAM36（现余 3 tiles，`DDR3-FEASIBILITY.md:84-94`） |
| 实现 | **TDP BRAM**：写口 = NPU 时钟（`nn_subsys` 在 job 完成时写入）；读口 = CPU 时钟 | RAMB36 两独立时钟；无 CDC 逻辑（C9） |
| 映射 | CPU **数据窗口**（`nn_*` 端口，1 拍寄存读，`core.sv:1548-1560`）：解耦模式下窗口偏移 `0x00000..0x007FF` = 邮箱；`0x00800+` = legacy A/B（可选保留） | 复用现有 nn 窗口通路，**core 零改动** |
| 布局 | `+0x00` magic `0x4E505552`（"NPUR"）；`+0x04` frame_no；`+0x08` err_code/status；`+0x0C` cycles；`+0x10` model_id/flags；`+0x14` 结果槽 DDDR 地址；`+0x18` csum；`+0x1C` num_heads；`+0x20..0x7FF` 预留给标量/小结果（大张量在 DDR 输出 arena） | 防撕裂：magic+frame_no 最后写 |
| 读时序 | CPU 读 = 1 拍寄存读（与 dmem 同口径）；**不经过 wait** | 现有 nn 窗口语义 |

### 4.4 Job 时序（一次完整流程，NPU 100MHz / CPU 150MHz）

```
CPU:  写 IN/OUT/MODEL/FRAME ──┐                                    ┌─ 读 STATUS/邮箱
                              └─ 写 DOORBELL ──(C1/C2)──▶ NPU ─────┘
NPU:  latch desc → [M3] 预取 layer0 → [M4] 逐 band 取输入 → RUN op0..opN
      → 写结果邮箱(magic/frame/cycles/...) → (C6/C7) done toggle
CPU:  见 done → 采样 FRAME_NO/CYCLES/邮箱 → 业务(NMS/显示) → 写 ACK
NPU:  见 ACK → 清 done → 可接下一 job
```

- 门铃→NPU 开始：≈ 4~6 NPU 拍（2FF + 锁存）；job 完成→CPU 可见 done：≈ 4~6 CPU 拍；
- 整个 job **CPU 只读写 6~8 次寄存器**（对比现状 MODE_CPU 的 14×op + 轮询；MODE_AUTO 虽只写 1 次但无 job 参数/帧号/结果邮箱）。

### 4.5 `nn_seq` 状态机改动（与 M3/M4/M5 衔接）

现状：`IDLE→FETCH→ISSUE→WAIT→NEXT`（`nn_seq.sv:47-66,122-139`）；每项 4 拍；`start` 单次（`:126`）；`GUARD_MAX=4M` 单 op 看门狗（`:44-45,165-170`）。

目标（job 模式，新增 `job_start` / `job_desc` / `job_abort` / `pre_*`（M3）/`tile_*`（M4））：

| 状态 | 动作 | 衔接 |
|---|---|---|
| `S_IDLE` | 等 `job_start`；锁存 `model_id/表起始 idx/in/out/frame_no`；清 cycles/err | §4.2 |
| `S_WAIT_PREFETCH`（新） | 发 `pre_start`（layer0 权重/Q）→ 等 `pre_done`；`pre_err` → `S_ERR(0xE6)` | **M3** `nn_wload`（`nn_wload.sv:58-100`） |
| `S_FETCH` | 按全局 `op_idx` 取 ROM；多模型时 `op_idx = 表起始 + 模型内序号`（见 §4.6） | ROM v1（`nn_pkg.sv:126-148`，256 bit） |
| `S_ISSUE` | 发引擎 start；**tile 模式下按 ROM `tile.band_rows` 拆多次 start**（引擎 loop 由 seq 驱动） | **M4** `nn_tilecache`（P3 §4；task-9） |
| `S_RUN`（原 WAIT） | 等 `eng_done`；累加 cycles；检查 `eng_err`；每 op 结束翻 `w_bank_sel` 并触发**下一层预取** | M2/M3 `w_bank_sel/pre_start` |
| `S_DONE` | 写结果邮箱头（magic/frame/cycles/err/csum）→ 置 job done；等 ACK 前不回 IDLE（可选） | §4.3 |
| `S_ERR` | 锁存 err_code（含出错 op idx），置 done+err；等 ACK | §7 |

**job 超时**：`S_IDLE` 起算的 job 计数器（`NN_TIMEOUT`）在 `S_RUN/S_WAIT_PREFETCH` 累计，到期 → `err=0xE4`、广播 `eng_abort=1`（引擎需新增 abort 输入，或 n/t 强制 `eng_start=0` + 复位引擎；建议引擎 abort 由 M1/M2 协作，见 §10 风险）。**单 op 看门狗保留**（`nn_seq.sv:44-45`，err 0xE3）。

### 4.6 多模型与 ROM（重要依赖，需 Lead 决策）

- 现状 ROM 128 项（`nn_pkg.sv:118`），YOLO=112 项；瓶盖 105 项；slim 71 项。**YOLO+瓶盖=217 > 128**，所以"运行期切模型"要求 **ROM 深度 256**（`NN_ROM_DEPTH=256`，256×256b=64Kb=**2 BRAM36**，现余 3 tiles，可承受）或**每模型一个 bitstream**。
- 建议：**本设计把 `job_model` 定义为"ROM 表项区间 + 结果解码口径"**；若只交一个模型则 ROM 深度保持 128、`model_id` 仅校验；若要求多模型热切换，按 `ROM-V1.md:146-156` 路线 B 扩到 256 并在 job 模式里用 `NN_JOB_MODEL[15:8]` 作为起始 idx（表头另存 `model_table`：`{model_id → first_idx, len, arena_base, out_base}`，2 项 × 4 字 = 32B，放 `nn_pkg` localparam 或 ROM 前 8 项保留区）。

---

## 5. 帧流水线

### 5.1 输入：双缓冲 + 丢帧（盘古语义）

| 项 | 设计 | 证据 |
|---|---|---|
| 生产者 | 相机 DVP 采集（未来）/ CPU 软件填充（bring-up）/ DDR DMA 预处理（未来） | 盘古 `vision_snapshot.v:50-71`；本仓现为 CPU 生成（`sw/yolo_demo.c:111-125`） |
| 缓冲区 | **双缓冲**：slot0/slot1，位于 DDR3 输入区（224 模型：150,528 B/槽；slim-160：76,800 B/槽；YOLO-128：49,152 B/槽）或片上 A（slim/legacy） | 地址表 §6.1 |
| 提交 | 生产者写完最后一字节 → `frame_commit`（脉冲）+ `frame_no` + slot；`NN_FRAME_STATUS.frame_ready=1`；同步字/FNV 在校验后置位 | 盘古 `frame_done`→ snapshot start，`vision_snapshot.v:61` |
| 启动 | 两种：**CPU doorbell**（默认）或 `CTRL2.auto_start=1`（新帧提交即启动，盘古式） | `ARCHITECTURE.md:20` |
| 丢帧 | NPU `busy` 或 `done 未 ack` → **丢弃新帧**（`NN_DROP_CNT+1`、`FRAME_STATUS.frame_lost=1`），不覆盖正在使用/待确认的缓冲；**不暂停生产者**（盘古：推理不暂停摄像头/LCD） | `ARCHITECTURE.md:20`；`vision_snapshot.v:51,58`（`!busy && !done` 才捕获） |
| 一致性 | NPU 只在 `frame_ready` 且 slot 未被生产者写入时取帧；生产者只写"非 NPU 占用"的 slot（2 槽足够：NPU 用 slot N，生产者写 slot N+1；NPU busy 时长 < 2 帧时间时不会打架） | 盘古双缓冲交换同理 |

### 5.2 输出：三缓冲 + 帧边界/seq 提交（防撕裂）

| 项 | 设计 |
|---|---|
| 缓冲数 | **3 个结果槽**（输出 arena 内，槽大小 = max(模型原始输出) = 瓶盖 3 头 56×56×(1+4+4)=28,224 B；YOLO-C128 20,400 B → 槽按 32KB 对齐，共 96KB） |
| 写入 | NPU 只写"当前写槽"，**最后写头部**（magic `0x4E505552`、frame_no、model、flags、csum、槽长）；写完置 `NN_RESULT_PTR` + done |
| 消费 | CPU（或显示端）只读"已 done 且未 ack"的槽；读完 ack 释放；**上一槽未 ack 不覆盖**（3 槽 + 流控保证至少 1 槽可写） |
| 防撕裂 | ① 头部最后写；② 消费者读头 magic+frame_no+`NN_FRAME_NO` 一致；③ 可选 csum（FNV/CRC）校验；④ 显示端按"帧边界提交"（盘古 272-bit 包在 `frame_tick` 更新，`vision_soc.v:269-280`）——本仓无显示线，留给视频/显示同学按此语义接 |
| 帧号 | 32-bit 递增（回绕由软件按无符号差处理，同盘古计时器约定 `ARCHITECTURE.md:93`） |

### 5.3 坑清单（每条给规避设计）

| # | 坑 | 现象 | 规避 |
|---|---|---|---|
| K1 | **丢帧**策略不一致 | 生产者覆盖 NPU 正在读的 slot → 结果错 | 双缓冲 + `busy/done` 门控；丢新帧而非覆盖；`drop_cnt` 可观测 |
| K2 | **撕裂**（输入） | NPU 读到半帧 | 生产者"最后一字节后提交"；NPU 只在 `frame_ready` 取；`frame_no` 校验 |
| K3 | **撕裂**（输出/显示） | 显示端看到半新半旧 | 三缓冲 + 头部最后写 + 帧边界提交（盘古 P6） |
| K4 | **超时** | NPU 卡死 → 整机假死 | job 看门狗（§7）+ 单 op 看门狗 + `err_code` + `NN_JOBS_DONE` 对账；CPU 侧 1 秒无新结果判故障（盘古 `numeric_main.c:200-206`） |
| K5 | **复位隔离** | 复位 NPU 把 CPU/结果一起清 → 丢帧/死锁 | 独立复位（§3.5）；复位只清 NPU 域 + pending；结果邮箱/CPU 计数由软件显式清 |
| K6 | **CDC 握手卡死** | toggle 丢/极性错 → CPU 永远等 | 双侧超时自清（§3.3）；单事务 + 回翻 ack；`cpu_timeout` 粘滞可观测 |
| K7 | **payload 撕裂（跨域）** | 采到新旧混合 32-bit | 稳定 payload + toggle（C1/C6/C7）；ack 前 payload 不变；`set_max_delay` |
| K8 | **优先级反转** | CPU 轮询占满导致 NPU 饿死 | job/status 全 CPU 域 mirror（0 等待）；NPU 私有寄存器才走 wait 桥 |
| K9 | **帧号回绕** | 32-bit 帧号回绕后比较错 | 软件按 `now - last` 无符号差（盘古同口径，`ARCHITECTURE.md:71,93`） |
| K10 | **DDR 写未完成就置 done** | 结果读回旧数据 | NPU 侧等 `ddr_wr_done`（beh_ddr3 `ddr_wr_done` 脉冲，`beh_ddr3.sv:42`）后才写邮箱头/置 done；或对 DDR 用写屏障 |

---

## 6. NPU-private 内存

### 6.1 DDR3 地址表（32-bit；`2 片 DDR3` 容量/位宽待用户确认，`DDR3-FEASIBILITY.md:49-73`）

| 区间 | 大小 | 用途 | 证据/来源 |
|---|---|---|---|
| `0x0000_0000..0x00FF_FFFF` | 16 MB | 视频/摄像头帧缓冲（P3 预留） | `P3-320-ARENA.md:11-13`；`WEIGHT-STREAMING-DESIGN.md:108-118` |
| `0x0100_0000..0x013F_FFFF` | 4 MB | **激活 arena**（峰值 1,806,336 B，含 tile 双缓冲余量） | `DDR3-FEASIBILITY.md:167-183`；`WEIGHT-STREAMING-DESIGN.md:113` |
| `0x0140_0000..0x015F_FFFF` | 2 MB | **权重镜像**（2,020,960 B，按 op 顺序连续排布，16B 对齐） | `WEIGHT-STREAMING-DESIGN.md:114,117` |
| `0x0160_0000..0x0161_FFFF` | 128 KB | **Q 镜像**（90,048 B） | `WEIGHT-STREAMING-DESIGN.md:115` |
| `0x0162_0000..0x0163_FFFF` | 128 KB | **输出/结果 arena**：3 槽 × 32KB（防撕裂；YOLO 20.4KB / 瓶盖 28.2KB） | 本设计 §5.2（新增） |
| `0x0164_0000..0x0167_FFFF` | 256 KB | **输入帧双缓冲**：2×128KB（224 packed=150,528B > 128KB 时用 2×160KB，见备注） | 本设计 §5.1（新增） |
| `0x0168_0000..0x016F_FFFF` | 512 KB | 保留（模型表/邮箱持久化/DDR 自检镜像/未来 batch） | — |
| `0x0170_0000..` | — | 扩展 | — |

> 备注：224 输入（packed3）单帧 150,528 B，双缓冲需 301,056 B ⇒ 输入区实际占 `0x0164_0000..0x0168_FFFF`（320KB，跨过保留区前 64KB），或把输入槽放进视频区（P3 已留 16MB）。建议：**输入双缓冲放视频区低 1MB**（`0x0000_0000` 起），把 `0x0164` 起留给模型表/调试，避免与保留区冲突。最终以 MIG 容量/用户输入为准。

### 6.2 片上 NPU-private 资产与 BRAM 预算

| 资产 | 现状 | 解耦后 | 预算 |
|---|---|---|---|
| W（权重 L2） | 320KB ROM，80 tiles（v0.7；M2 已改 2×160KiB 可写双银行，tiles 不变） | 2 银行 × **128KiB**（=64 tiles）即可覆盖最大层 124,416 B；**释放 16 tiles** | `nn_pkg.sv:50-60`；`nn_mem.sv:91-144`；`nn_wload.sv:48-55`（`MAX_PRE_WLEN=128KiB` 已按此约束实现） |
| Q（量化参数） | 48KB（lo 8 tiles BRAM + hi LUTRAM，`mem-report.md:104`） | 2×8KiB 影子银行（M2 已实现，`nn_mem.sv:139-143`） | 同上 |
| A/B 激活 | 96KB + 32KB（32 tiles），CPU 窗口可读写 | 解耦模式：作为 **IBUF/OBUF tile cache**（M4，IBUF 2×16KB + OBUF 2×12KB=56KB=12.4 tiles） | `nn_pkg.sv:45-46`；P3 §4；task-9 |
| ROM | 128×256b（v1，`nn_pkg.sv:126-148`），1-2 tiles | 多模型时 256 项（2 tiles） | `ROM-V1.md:133-156` |
| **结果邮箱** | 无 | **2KB TDP BRAM = 1 tile** | §4.3 |
| **BRAM 合计** | 132/135（余 3） | W 64 + Q 8 + A/B 32 + ROM 2 + 邮箱 1 + job 少量 LUTRAM ≈ **107** ⇒ 余 ~28 tiles（够 tile cache 12.4 + 余量） | `SPEC-SPECIALIZED.md:71-77`；`DDR3-FEASIBILITY.md:84-94` |

> **关键推论**：把 W 银行从 160KiB 缩到 **128KiB**（没有层超过 124,416 B，且 `nn_wload` 已限 128KiB）即可**释放 16 tiles**，让 M4 tile cache（~12.4 tiles）与结果邮箱（1 tile）全部落地，而不用动 Q/A/B。这是解耦 + tiling 同时成立的必要条件，建议 Lead 在 M2 落地时把 `NN_W_BANK_BYTES` 定为 128KiB（`nn_pkg.sv:52-55`）。

### 6.3 CPU 窗口保留/删除建议

| 模式 | CPU 窗口（`0x9004_0000` + `NN_BYTES`） | 理由 |
|---|---|---|
| **legacy 单时钟（现状 / 回归）** | **原样保留** A/B 映射 + busy 门控（`nn_subsys.sv:147-149`；`nn_mem.sv:415-417`） | C128 YOLO E2E / `tb_nn_mem` / `tb_sw_nn_yolo` 依赖它；`verify` 16 项不改（`PLAN-V1:65-71`） |
| **解耦模式（NN_DECOUPLE=1）** | **关闭 A/B**（读 0、写忽略+err），窗口偏移 `0x00000..0x007FF` 改映射**结果邮箱**；CPU 不再搬 A/B | 盘古"CPU 不碰 NPU RAM"（`ARCHITECTURE.md:53` 数据通路）；避免 512KB 窗口跨时钟域（若保留需整窗 CDC 桥，代价大且时序差） |
| 调试旁路 | 可选：`nn_cdc_bridge` 提供 NPU 私有寄存器相干读（Option W） | §3.3/§3.4 |

---

## 7. 异常 / 超时 / 复位

| 机制 | 设计 | 判据/证据 |
|---|---|---|
| **job 看门狗** | NPU 域计数器（`NN_TIMEOUT`，默认 100M 拍 ≈1s @100MHz）；`S_WAIT_PREFETCH/S_RUN` 累计；到期 → `err=E4`、停 seq、置 done+err、`busy=0`；CPU 可 `reset` 恢复 | 盘古"1 秒无新结果判故障"（`numeric_main.c:200-206`） |
| **单 op 看门狗** | 保留现有 `GUARD_MAX=4M`（`nn_seq.sv:44-45,165-170`，err 0xE3） | 已有 |
| **ROM 跑飞** | ① `op_idx` 只由 `NN_ROM_LEN` 有界自增（`nn_seq.sv:66,171-173`）；② 多模型表越界 → err E5；③ `kind` 非法 → err E5（现 default 当 conv，`nn_seq.sv:108-110`，需加非法判定）；④ job 完成前必须走到 `S_DONE`，否则超时 | `ROM-V1.md:164`（生成器断言①⑦） |
| **DDR/预取错误** | `nn_wload.pre_err`（长度/FIFO/DDR 错，`nn_wload.sv:36-43`）→ err E6；`beh_ddr3.ddr_err`（`sim/beh_ddr3.sv:47-48`）可注入 | — |
| **错误传播** | NPU 侧 `err_code+op_idx` 锁存 → 随 done payload 送 CPU 域 → `NN_ERR_CODE` 粘滞，ACK 清 | 盘古状态/结果分离（`ARCHITECTURE.md:57-89`） |
| **复位隔离** | 三源复位：`sys_rst_n`、`mmcm_locked`、CPU 写 `CTRL2.npu_reset`；NPU 域异步置位/同步释放；**NPU 复位不重启 CPU**；复位中 CPU 写 NPU 段被丢弃并置 `STATUS.rst` | §3.5；`CLOCK_SPLIT.md:7,26` |
| **交付档隔离** | 所有新增 RTL 在 `ifdef NN_EN` + 新宏 `NN_DECOUPLE`（默认 0）内；`core.sv` 新端口在 `ifdef NN_EN` 内（与现有 `nn_*` 端口同法，`top_a100t.sv:177-187,213-221`）；无 `NN_EN` 时交付网表逐位不变 | `DELIVERY.md:273-284`（parity 判据）；`PLAN-V1:65-71` |

---

## 8. 与 M1–M5 / 性能升级（task-11）的关系

| 工作流 | 与本设计的关系 | 可否并行 |
|---|---|---|
| **M1 引擎 ReLU/IC 上限**（task-6） | 与本设计**零耦合**（引擎端口不变） | ✅ 完全并行 |
| **M2 nn_mem W 双银行**（task-7） | 提供 `w_mode/w_bank_sel/wfill_*`（已落地，`nn_mem.sv:133-143`）；解耦只需 `nn_seq` 用它 | ✅ 并行（建议同批把 W 银行改 128KiB，§6.2） |
| **M3 权重流式**（task-8） | job 接口的 `S_WAIT_PREFETCH` 直接调 `nn_wload`；`job_model`/`NN_JOB_IN` 就是 DDR 地址来源 | ✅ 并行；集成点 = `nn_seq` 新状态（§4.5） |
| **M4 激活 tiling**（task-9） | job 里的 `NN_JOB_IN/OUT` 是 arena 地址；tile 循环由 `nn_seq` 驱动、`nn_tilecache` 实现；本设计只定接口 | ✅ 并行（task-9 未开始，可先按本设计的 job 字段对齐） |
| **M5 序列器/子系统** | **本设计就是 M5 的输入规格**：寄存器表 + `nn_seq` FSM + CDC + 结果邮箱 | ⬅ 本设计交付 |
| **task-11 性能升级** | 解耦后 NPU 可独立提频（100→121.74/120/150），是 task-11 的"提频"杠杆前置条件；阵列加宽（128→256/512 MAC）不改本接口 | 两条正交，可并行；见下 |

**组合路线（与 task-11 联合）**：

| 组合 | NPU 频 | 有效算力 | 瓶盖 224 帧率（40.06M 拍基准，2.27GMAC） | 备注 |
|---|---|---|---|---|
| 现状（同频 100） | 100 | 128 MAC/拍，56.8 MAC/拍实测 | **2.50 fps** | `DDR3-FEASIBILITY.md:141-153` |
| 解耦后（独立 100） | 100 | 同上 | 2.50 fps（**CPU 不再被拖住**，端到端更稳） | 本设计 |
| + 独立 121.74 | 121.74 | 同上 | **3.05 fps** | 需重跑全实现（NPU 域） |
| + 256 MAC/拍（task-11） @121.74 | 121.74 | ~2× 峰值、效率提升 | **~5.5~6 fps**（纸面） | 与 task-11 联合评估 |
| + 512 MAC/拍 @121.74 | 121.74 | — | **~9~10 fps**（纸面，资源/时序待 task-11） | 同上 |

> **必须诚实说明**：解耦**不改变** NPU 计算量（盘古同样强调"CPU 提频不缩短 NPU 计算"，`CLOCK_SPLIT.md:46`）。它带来的是：CPU 并行做业务/显示、NPU 独立频点与复位、为 tile/权重流式提供 job 容器、以及端到端帧率不再受 CPU 轮询抖动影响。

---

## 9. 最小可行第一步（必须落在 `verify --force PASS 16` 纪律内）

> 现状基线：`verify --force` **PASS 16**（`DELIVERY.md:266-271`；`.fpga-cache/verify-state.json`）；YOLO E2E `npu_cycles=1,191,020`、`hw_bad=0/auto_bad=0`（`.fpga-cache/logs/tb_sw_nn_yolo.log:42-43`）。新测试按现有"条件登记"范式加入矩阵（`tools/fpga_workflow.py:1125-1143,1147-1179`），**只增不减**。

### S1（建议先做）：单时钟 Job 接口（不动 core / 不动时钟 / 不动引擎）

| 改动 | 文件（未来实施） | 判据 |
|---|---|---|
| 新 `nn_job_if.sv`（单时钟模式：job 寄存器 + doorbell/ack + 状态镜像 + 结果邮箱；CDC 部分旁路） | 新文件；Lead 注册（`build.tcl:149` read_verilog、`fpga_workflow.py:133-160` CORE_SV_ORDER） | 编译 0 error |
| `nn_subsys.sv` 增加 job 端口（`job_start/job_desc/job_done/job_cycles/job_err/result_wr_*`）与 job 模式（复用现有 `nn_seq` MODE_AUTO 路径，`nn_subsys.sv:300-305`） | `nn_subsys.sv` | 现有 MODE_CPU/AUTO 行为不变 |
| `rv32_pkg.sv` 新增 20 个 MMIO 常量（`0xA000_0150..0x19C`） | `rv32_pkg.sv:385-403` 旁 | 地址表与 §4.2 一致 |
| 新 `sw/nn_job_demo.c`：写 job→doorbell→轮询 done→读邮箱→对账（用现有 YOLO plan/权重） | `sw/` | `RESULT : PASS` |
| 新 `sim/tb_nn_job.sv`（SoC 级，`+nnwq=...`） | `sim/` | `NN_JOB_TB: PASS`；`npu_cycles==1,191,020`；邮箱 csum == golden |
| 回归 | — | `verify --force` **PASS 17**（旧 16 项逐项 PASS 且 `npu_cycles` 不变） |

**S1 风险**：低（不碰 core/LSU/时钟；`nn_seq` 只加一个入口）；工作量：**4 个文件 + 1 个 TB + 1 个固件**（~2-3 天量级）。

### S2：双时钟 + CDC（Option P，仍不动 core）

| 改动 | 文件 | 判据 |
|---|---|---|
| MMCM `CLKOUT1` + `u_bufg_npu` + NPU 复位同步器（`NN_EN` 内） | `fpga/top_a100t.sv:107-167` 旁 | 单时钟构建逐位不变；双时钟构建通过 |
| `nn_subsys` 整体移到 `nn_clk`；`nn_job_if` 启用 CDC 模式（C1-C9） | `top_a100t.sv:270-295`、新 `nn_job_if.sv` | — |
| 新 `nn_cdc_bridge.sv`（仅调试寄存器/可选 IRQ） | 新文件 | — |
| XDC：`create_generated_clock nn_clk` + `set_clock_groups -asynchronous` + `max_delay`；build.tcl 注入 NPU 频点 | `fpga/daVinciPro.xdc`、`fpga/build.tcl` | 双时钟综合 WNS ≥0（两域） |
| 新 `sim/tb_nn_cdc.sv`（150/100 两时钟）：1000 个随机 job 跨域、done/ack、payload 无撕裂、超时、复位隔离 | `sim/` | `NN_CDC_TB: PASS`（0 lost/torn）；`report_cdc` 无未约束跨域 |
| 回归 | — | 单时钟构建 `verify --force` **PASS 17**；交付档（无 NN_EN）不变 |

**S2 风险**：中（CDC 约束/复位是"偶发错帧"高发区）；工作量：**2 个新文件 + 3 个改动 + 2 个 TB + 1 套约束**（~4-6 天量级）。

### S3（依赖 M3/M4）：帧流水线 + 自动启动 + 私有 DDR 内存

| 改动 | 文件 | 判据 |
|---|---|---|
| 输入帧双缓冲提交/丢帧、输出三缓冲 seq、`auto_start` | `nn_job_if.sv` + 新 `nn_frame_if.sv`（或并入） | `tb_nn_framepipe`：30fps 生产者 vs 2.5fps NPU，丢帧计数正确、无撕裂（csum/magic） |
| job 超时/错误码/job 状态寄存器 | `nn_subsys.sv`/`nn_job_if.sv` | 注入超时/ROM 错 → err 码正确、CPU 可恢复 |
| DDR 地址表（§6.1）与 M3/M4 接线 | `nn_seq.sv`、`nn_wload.sv`、`nn_tilecache.sv` | E2E：job 模式逐 op FNV == converter golden（`results/bottlecap/plan/`） |

**S3 风险**：中高（依赖 DDR/MIG 与 M4）；工作量：**2 个新文件 + 3 个改动 + 2 个 TB + MIG 集成**。

---

## 10. 风险登记

| # | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R1 | **MIG/DDR3 未接入**：仓库零证据（无引脚/无 IP/无参考钟），用户 6 项输入未到 | 高 | S3 阻塞 | 先用 `sim/beh_ddr3.sv`（M3 已交付，`beh_ddr3.sv:58-65`）做全链路仿真；S1/S2 不依赖 DDR |
| R2 | **CDC 约束/复位错误** | 中 | 偶发错帧、难复现 | 按 §3.2 三类结构；`tb_nn_cdc` 随机 job 压力；`report_cdc` 门；所有同步器 `ASYNC_REG` |
| R3 | **payload 撕裂** | 中 | 地址/帧号错乱 | 稳定 payload + toggle + ack 前不变 + `max_delay`；双写校验（可选 csum） |
| R4 | **NPU 域时序余量**：100MHz 全实现 WNS +0.136（`DELIVERY.md:227`），加 job/DMA/tile 逻辑后可能不足 | 中 | 提频计划受阻 | 解耦后 NPU 域独立约束；先 100MHz 交付，121.74 作为目标需 OOC+全实现 |
| R5 | **BRAM 只剩 3 tiles** | 高 | tile cache 放不下 | 把 W 银行缩到 128KiB 释放 16 tiles（§6.2，`nn_wload` 已限 128KiB） |
| R6 | **core/LSU 改动回归风险**（仅 Option W） | 中 | 所有测试受影响 | Option P 第一版不改；Option W 用 `ifdef NN_EN` + `stall_external=0` 时逐拍不变 + `verify --force` 门 |
| R7 | **多模型 ROM 深度**（YOLO 112 + 瓶盖 105 > 128） | 中 | 运行期切模型不可行 | 单模型/bitstream（默认）；要热切换则 ROM 256（2 tiles）并在 `job_model` 定表区间（§4.6） |
| R8 | **单 op abort 未实现**：现有引擎/seq 无 abort 端口（`nn_conv_engine.sv` 无 abort；`nn_seq.sv:129-133` 只靠 eng_done） | 中 | job 超时无法立刻停 | job 超时先置 err/清 busy，引擎侧由"停止发 start + 等当前 op 的 4M 看门狗"兜底；后续 M1/M2 加 `eng_abort`（风险低） |
| R9 | **结果邮箱读与 NPU 写并发** | 低 | CPU 读到半新 | 协议上 done 后才读；TDP BRAM 双口不冲突；ACK 前 NPU 不写下一份 |
| R10 | **IRQ 到 CPU 需要 core 新端口**（`irq_ext` 现 tie 0，`core.sv:1039`） | 低 | 无法用中断 | 第一版轮询（盘古同）；IRQ 作为 Option W 之后的小改动（core 端口 + csr 已支持，`csr_file.sv:62-63,137-144`） |

---

## 11. 验证方法（实施后应加的 TB）

| TB | 时钟 | 判据 | 对齐盘古 |
|---|---|---|---|
| `tb_nn_job`（S1） | 单时钟 50MHz（现有 tb_sw 风格，`sim/tb_sw.sv:54,65`） | `NN_JOB_TB: PASS`；`npu_cycles==1,191,020`；邮箱 csum/FNV == golden；`verify --force` PASS 17 | `vision_npu.v` 单测式 |
| `tb_nn_cdc`（S2） | **双时钟 150/100**（新） | 1000 随机 job：0 lost / 0 torn payload / done-ack 一一对应；超时注入回 `cpu_timeout`；NPU 复位不影响 CPU 计数 | `sim/tb_cdc.v`（pango）用两时钟 + 帧/tick 断言的做法：`tb_cdc.v:5-7,43-77,100-120` |
| `tb_nn_framepipe`（S3） | 双时钟 + 行为 DDR | 30fps 生产者 vs 2.5fps NPU：丢帧/丢 doorbell 计数精确；三缓冲无撕裂（magic/frame/csum）；复位隔离 | `vision_snapshot.v` + `vision_soc.v` 提交逻辑 |
| `tb_nn_decouple_e2e`（S3） | 双时钟 + `+nnwq`/DDR 镜像 | YOLO 112-op 经 job 模式跑通，逐 op FNV == golden（调试模式），`npu_cycles` 不变 | pangu SoC 级 `tb_soc.v` |
| 回归门 | — | 交付档（无 `NN_EN`）资源/时序逐项不变（`DELIVERY.md:273-284`）；`verify --force` 只增不减 | `PLAN-V1:65-71` |

---

## 附录 A：证据索引（本文件引用的关键 file:line）

| 主题 | 证据 |
|---|---|
| 盘古双时钟/握手/丢帧/私有内存 | `work/pango_bl/vision/ARCHITECTURE.md:5,20,45,53,57-89`；`CLOCK_SPLIT.md:5,13-30,46`；`rtl/vision_mmio_bridge.v:22-92`；`rtl/vision_soc.v:99-121,130-170,269-280`；`rtl/vision_snapshot.v:50-71`；`rtl/vision_npu.v:3-17,64,116-123`；`rtl/vision_video_bridge.v:15-82`；`firmware/numeric_main.c:32-36,197-213`；`rtl/cpu/core.v:4,172-173,470,512,540-554,595`；`rtl/cpu/load_store_unit.v:6,30,127`；`sim/tb_cdc.v:5-7,43-77,100-120` |
| 本仓时钟/顶层 | `fpga/top_a100t.sv:107-167,177-187,192-222,228-256,263-299`；`fpga/daVinciPro.xdc:5,28-31,34-49`；`fpga/build.tcl:149,159-199,305-326` |
| 本仓 core/LSU/irq | `core.sv:74-80,1039,1264-1290,1367-1386,1400-1425,1535-1560,1576-1585,1602-1647`；`load_store_unit.sv:85-92,285-309,335,372-377`；`csr_file.sv:62-63,89-91,137-144,197`；`rv32_pkg.sv:434-435` |
| NPU 现状 | `nn_subsys.sv:32-66,71-96,147-153,210-257,262-282,287-383,388-412`；`nn_seq.sv:44-66,114-139,141-184`；`nn_mem.sv:91-144,156-185`；`nn_pkg.sv:35-60,65-107,118-148`；`rv32_pkg.sv:326-327,385-403` |
| 契约/交付 | `results/ai-accel/CONTRACT.md:43,73-100,446-459,477-491`；`results/ai-accel/DELIVERY.md:128,223-244,266-284`；`.fpga-cache/verify-state.json`；`.fpga-cache/logs/tb_sw_nn_yolo.log:42-43` |
| v1/DDR3/流式 | `results/bottlecap/reports/PLAN-V1.md:16-45,65-71,83-109`；`results/bottlecap/ddr3/DDR3-FEASIBILITY.md:16-27,49-94,141-153,167-183`；`results/bottlecap/ddr3/WEIGHT-STREAMING-DESIGN.md:38-148`；`results/bottlecap/ddr3/ROM-V1.md:84-108,133-156`；`nn_wload.sv:23-100`；`sim/beh_ddr3.sv:25-65` |
| 验证入口 | `tools/fpga_workflow.py:1125-1143,1147-1179,3333-3335`；`sim/tb_sw.sv:54,65,83-160` |

## 附录 B：未来实施的文件清单（本任务只出设计，下列由 Lead 排期分配）

| 类别 | 文件 | 类型 |
|---|---|---|
| 新 RTL | `nn_job_if.sv`、`nn_cdc_bridge.sv`、（可选）`nn_frame_if.sv` | 新增 |
| 改 RTL | `fpga/top_a100t.sv`（时钟/复位/接线）、`nn_subsys.sv`（job 端口+邮箱写口+err）、`nn_seq.sv`（job FSM/abort/prefetch/tile）、`core.sv`（**仅 Option W**：ext_ready/irq_ext）、`load_store_unit.sv`（**仅 Option W**：stall_external） | 改 |
| 包/常量 | `nn_pkg.sv`（job desc/err code/参数）、`rv32_pkg.sv`（20 个 MMIO 地址） | 改（Lead） |
| 约束/构建 | `fpga/daVinciPro.xdc`（nn_clk/clock_groups/max_delay）、`fpga/build.tcl`（NPU 频点注入）、`tools/fpga_workflow.py`（注册 + 新测试） | 改（Lead） |
| TB | `sim/tb_nn_job.sv`、`sim/tb_nn_cdc.sv`、`sim/tb_nn_framepipe.sv`、`sim/tb_nn_decouple_e2e.sv` | 新增 |
| 软件 | `sw/nn_job_demo.c`（bring-up 固件） | 新增 |
