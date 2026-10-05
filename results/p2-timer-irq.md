> 数据口径提醒（2026-10-05 修正）: 本文里 **fmax 75.0 / 70.9 MHz、LUT 2526、
> 通吐 167.5** 等数字来自已被推翻的配置 —— 三个架构宏当时**在仿真侧从未生效**
> (PITFALLS R17), 而它们单独开启都会仿真 timeout。详见 results/p4-macro-failure.md。
> 本文的**功能结论与 bug 记录仍然有效** (mcause 位布局、csrsi 5 位立即数、
> 定时器中断实现与回归), 只有那些性能数字不可采用。
> **当前真实指标**: CoreMark/MHz 2.3611 / fmax 61.6 MHz / LUT 4019 / 绝对吞吐 145.4

---

# P2 · mtimecmp 定时器中断（补齐"完整异常/中断")

**日期**：2026-10-05  **tag**：`p2-timer-irq`  **结论：保留（赛题必需），代价已量化**

## 改动

**`fpga/mmio_subsys.sv`**
- 64 位 `mtimecmp` 寄存器，**复位值全 1**（`0xFFFF_FFFF_FFFF_FFFF`）→ 上电不会立刻中断
- `mtime` **复用**已有的 64 位自由运行周期计数器 —— 这样 `MMIO_MTIME_*` 与
  `MMIO_CYCLE_*` 读出来必然一致，软件不必关心有两个时间源
- `irq_timer = (mtime >= mtimecmp)` 电平输出

**`core.sv`**：新增 `irq_timer` 端口 → `csr_file.irq_timer`（→ `mip.MTIP`），不再硬接 `1'b0`
**`top_a100t.sv` / `tb_soc.sv` / `tb_sw.sv`**：接线（`tb_core` 保持恒 0 —— 它不接外设，这是正确设计）

**新测试**：`sim/prog/timer_irq.S` + 测试矩阵里的 `tb_soc_timer_irq`，覆盖：
中断触发 / `mcause` 判定 / handler 推进 mtimecmp 清电平 / `mret` 返回 /
**handler 用 mscratch 保存-恢复现场** / 中断之后 UART+GPIO 仍正常（SoC 集成）。

## 过程中修掉的两个真 bug

### R6 · `mcause` 位布局写错（RISC-V 合规性 bug）

```systemverilog
// 错: trap_cause 是紧凑的 5 位 {is_interrupt, code[3:0]}
mcause <= {27'b0, trap_cause};        // -> 中断位落到 bit4
// 对:
mcause <= {trap_cause[4], 27'b0, trap_cause[3:0]};   // bit31 = 中断, 规范要求
```

**症状**：中断确实进了（`mstatus.MIE` 被清、handler 也跑了），但 `mcause` 读回
`0x00000017` 而不是 `0x80000007`，于是 handler 里"检查 `mcause[31]` 判断是中断"的
分支全部走错 —— 中断处理程序把中断当成异常处理，直接跳去失败路径。

**为什么长期没暴露**：之前只测同步异常，而**异常的 bit31 本来就是 0**，
`{27'b0, cause}` 与正确布局恰好一致。只有中断才有 bit31=1。

> 这个 bug 靠"RTL 看起来对"是查不出来的，只有真的读一次 `mcause` 才发现。

### R7 · `csrsi` 的立即数只有 5 位，且截断是**静默**的

想置 MTIE（`mie` 的 bit7 = `0x80`）写了 `csrsi mie, 0x80`。规范规定 CSRRSI/CSRRCI
的立即数取自 `instr[19:15]`，**只有 5 位（上限 31）**，`0x80 & 0x1F = 0` ——
于是它等价于 `csrsi mie, 0`，**中断永远使能不上，且不报任何错**。

**修法**：任何 bit ≥ 5 的 CSR 位都用寄存器形式（`li t0, 0x80` + `csrw mie, t0`）。
对照：`csrsi mstatus, 8` 没问题，因为 MIE 是 bit3 —— 这个坑很容易漏。

### 另两个过程性教训（已进 PITFALLS）

- **R8**：具名端口连接 `.irq_timer (irq_timer)` 里未声明的标识符会被**隐式声明**成 net，
  之后那句 `logic irq_timer;` 就报 `vlog-2388 already declared`。**声明必须写在例化之前**。
- **R9**：把需要外设的测试挂到 `tb_core` 上 —— 它 `ext_rdata`/`irq_timer` 恒 0，
  症状是"MMIO 读回 0、中断永远不来"，而 RTL 完全没问题。涉及 MMIO 的测试要用 `tb_soc`/`tb_sw`。

## 实测代价

| 指标 | P2 之前 | **P2 之后** | 变化 |
|---|---|---|---|
| CoreMark/MHz | 2.3611 | **2.3611** | 0（ticks 逐位相同 423,527）|
| **fmax** | 75.0 MHz | **70.9 MHz** | **−5.5%** |
| **绝对吞吐** | 177.1 | **167.5** | **−5.5%** |
| CoreMark/LUTs | 9.662e-04 | 9.347e-04 | −3.3% |
| LUT | 2444 | 2526 | +82 |
| FF | 1313 | 1377 | +64 |

回归 **8 PASS**（新增 `tb_soc_timer_irq`）。

### 判定：保留，但要说清这是一笔"功能换频率"的交易

绝对吞吐 **−5.5%**，按纪律本该回退。**但保留**，理由：

1. 「完整异常/中断」是赛题**明确的加分项**，而 P1 只做了**异常**（同步陷阱）；
   没有定时器中断就不算"完整中断" —— `irq_timer` 之前是硬接 `1'b0` 的**死线**。
2. 它是**功能完成度**，不是性能优化：−5.5% 换来一个从"未做"变"已完成"的高阶任务。
3. 与 P1 同类（P1 也是用 −4.1% fmax 换异常）。两者合计约 −10% fmax，
   换来"完整异常 + 中断"这一整个加分项。

> 纪律说明：这是"绝对吞吐下降但因功能必需而保留"的取舍，必须留痕 ——
> 否则下一个会话看到吞吐下降会以为是回归而回退掉。

## 新关键路径（说明 P2 的代价来自**布线**而非逻辑）

```
Slack 5.902ns (fmax 70.9)   Source: u_core/u_ex_mem/rd_addr_reg[0]/C
Destination: u_core/u_id_ex/rs1_data_reg[8]/D
Data Path: 14.089ns  (logic 26.7% | route 73.3%),  17 级
路径归属: u_id_ex 26 | u_muldiv 10 | u_ex_mem 10 | u_mem_wb 8 | u_dmem 1
```

对比 P2 之前（`u_id_ex 30 | 12.7ns` 级别）：**逻辑级数从 19 降到 17，但布线占比升到 73.3%**。

**结论：这个设计已经进入"布线受限"区间** —— 加逻辑本身不再是主要代价，
重布局带来的长走线才是。这也解释了为什么 +82 LUT 的小改动会吃掉 5.5% fmax。
**后续想再提 fmax，靠改 RTL 的收益已经很小，需要物理手段**（floorplan / 位置约束 /
congestion 分析），或减少寄存器数量与总线扇出。
