# P8 · 去掉冗余的 `if_id_reg`（issue #5）：让 IF/ID 落在 IMEM 的输出寄存器上

> ⚠️ **历史记录（2026-10-08）**：本文里的 `PASS 11` 是**当时**的回归基线；现在是 **PASS 12**
> （新增 `tb_sw_lu_bench`）。另：本轮的 **C-1** 之后 `btb.sv` 已重写为两级流水并新增 `bht.sv`，
> 本文提到的"预测器"细节可能已过时。正文不改，引用时注意口径。

**日期**：2026-10-08 **状态**：✅ 已实施 · 已上板验证 **来源**：GitHub issue #5（含 2 条复审评论）

> **文件名说明**：本文件最初叫 `p8-4stage-pipeline.md`，**那个标题是错的** ——
> 实施者（我）把"流水寄存器个数"当成了"流水级数"，差一。见 §1 的口径更正。
> 本核**始终是 5 级流水线**；这次改动去掉的是一个**冗余寄存器**，不是一级流水。

---

## 1. 口径更正：本核是 **5 级**，改之前反而是 **6 级**

教科书 5 级流水线（IF/ID/EX/MEM/WB）在 `pc` 之后只有 **4 个**流水寄存器：
IF/ID、ID/EX、EX/MEM、MEM/WB。（**4 个寄存器 ⇒ 5 级**，因为 IF 级的工作发生在
IF/ID 之前 —— 这是最容易差一的地方。）

| | `pc` 之后的指令寄存器 | 级数 |
|---|---|---|
| 教科书 5 级（imem 用**组合读**）| IF/ID、ID/EX、EX/MEM、MEM/WB = **4** | **5 级** ✅ |
| **本核改动前**（imem 是 BRAM ⇒ **同步读**）| **IMEM 输出寄存器** ＋ `if_id_reg`、ID/EX、EX/MEM、MEM/WB = **5** | **6 级** ❌ |
| **本核改动后**（本文件）| IMEM 输出寄存器**充当 IF/ID**、ID/EX、EX/MEM、MEM/WB = **4** | **5 级** ✅ |

**为什么 `if_id_reg` 是冗余的**：它前面**没有任何组合逻辑** —— 只是把
`imem_rdata` / `pc` 原样再打一拍（纯搬运）。它**消耗一个周期却不做任何工作**，
等价于给每次重定向白加一个气泡。

**所以收益的准确表述是**：
> ❌「少了一级流水，所以更快」—— 错。少一级本身不提高吞吐。
> ✅「**去掉一个纯搬运寄存器 ⇒ 每次重定向少穿一个气泡**」—— 这才是全部收益来源。

### 顺带更正 `imem.sv:11-14` 的说法

原文写「读延迟 1 拍本身**不产生气泡、也不增加流水线级数**」。**只说对了一半**：
配对口径（`imem_rdata(N) == mem[pc(N)]`）确实没变、常用路径也确实没变慢；
但它**确实多插了一个寄存器**，代价是每次重定向多一个气泡。
（这一次实测把账算清了：11,535 次重定向 ⇒ 10,457 拍的代价。）

---

## 2. 结果（全部指标同时改善）

| 指标 | 基线 | **本次** | 变化 |
|---|---:|---:|---:|
| **CoreMark/MHz** | 2.3611 | **2.4209** | **+2.53%** |
| CoreMark ticks | 423,527 | **413,070** | −10,457（−2.47%）|
| **fmax** | 69.2 MHz | **69.5 MHz** | **+0.43%** |
| WNS @20ns | 5.543 | **5.620** | +0.077 |
| **LUT** | 2820 | **2769** | **−51** |
| **FF** | 1345 | **1234** | **−111** |
| BRAM / DSP | 8 / 8 | 8 / 8 | — |
| **CoreMark/LUTs** | 8.373e-4 | **8.743e-4** | **+4.42%** |
| **绝对吞吐** | **163.3** | **168.4** | **+3.12%** |

**回归**：`PASS 11`（含 CoreMark CRC 自校验）。
**上板**：`ila_ctrl=0x42`（done/pass=1）、CRC bit31=1 匹配官方参考值、
tick **536,943,384**、CoreMark/MHz **2.4211**（硬件）、**10.74 s @50MHz** ✓

> 与 issue #5 预测的对照：预测 ticks 412,026（−11,501）；实测 **413,070（−10,457）**。
> 差 1,044 拍（0.25%），因为并非每次误判都恰好省 1 拍。
> **issue 里"load-use 停顿中性"的论断被实测证实**：`load-use = 30,645`，与改动前**逐位相同** ✓。

---

## 3. 实现（`core.sv` 两处 + 删一个文件）

1. **`u_if_id` 实例 → 组合别名**（关键取舍）：
   ```systemverilog
   assign if_pc = pc;  assign if_pc_plus4 = pc_plus4;  assign if_instr = imem_rdata;
   assign if_pred_taken = pred_taken;  assign if_pred_target = pred_target;
   ```
   **为什么保留 `if_*` 这几个名字**：`tb_core` 的逐拍 trace 与 `tb_sw` 的
   **取指对齐自检**都直接引用 `u_dut.if_pc` / `if_instr`。做成别名 ⇒
   **两个 testbench 一行都不用改**，而且自检的不变量（`imem_rdata == mem[pc]`）
   完全不变、继续有效。
2. **ID 门控**：`id_ctrl = id_en ? id_ctrl_raw : ctrl_s'(0);`（`id_en = boot_done`）
   —— 门控挂在**译码输出**上，**绝不能**做成 32 位指令 mux（那会插进关键路径）。
3. 删除 `if_id_reg.sv` 并同步 7 处文件清单。

---

## 4. ⚠ 实施中踩到的两个坑（都已修，值得记进 PITFALLS）

### 4.1 组合环：`if_id_flush → id_valid → id_rs* → load_use → pipe_stall → redirect`

第一版把 `id_rs1/id_rs2/id_rd` 也用 `id_valid = !if_id_flush && boot_done` 门控。
Vivado 综合直接报：

```
CRITICAL WARNING: [Synth 8-295] found timing loop.
ERROR: [DRC LUTLP-1] Combinatorial Loop Alert: 17 LUT cells form a combinatorial loop.
One net in the loop is u_core/u_id_ex/if_id_flush
```

**原设计没有这个环**，因为 `if_id_rs*` 来自 `if_id_reg` 的**输出寄存器**；
改成组合别名后这条反馈路径暴露出来。

**修法：三个寄存器号不加门控**（直接用指令字段）。安全性论证：
重定向只可能由 EX 里的控制流指令产生（`pred_ok` 只对 `pc_sel != PC_NEXT` 有意义），
而 branch/jal/jalr 的 `mem_read = 0` ⇒ `load_use` 恒为 0 ⇒ 无影响；
三个号的消费者（regfile 读口 / ID-EX 入口）在冲刷那拍都被 ID/EX 的 `flush` 拦住。

### 4.2 `if_id_flush` 串进 ID 控制路径 —— fmax 掉 2.5%

第二版把 `id_ctrl` 用 `id_valid`（含 `if_id_flush`）门控。综合后 fmax **69.2 → 67.5**，
关键路径终点变成 `u_id_ex/imm_reg[11]/D`：

```
... → redirect_raw → pc[31]_i_13 → imm_out_i_5 → if_id_flush (fo=125) → u_imem/imm_reg → ID/EX
```

**`if_id_flush` 是全核最晚、扇出最大的信号之一（实测 fo=125）**，一旦串进
`id_ctrl → imm_gen → ID/EX` 的 D 端就立刻变成关键路径。

**修法：只用 `boot_done` 门控**（早期寄存器）：
- **冲刷期不需要在这里门控** —— `id_ex_reg` 的 `flush` 接的就是 `any_redir`，同一拍已把 ID/EX 清成气泡，D 端是什么值都无所谓；
- **启动期必须门控** —— 原来靠 `if_id_reg` 的 `stall(fetch_hold)` 把 IF/ID 冻在复位值 (NOP)，去掉它后只能在这里补，否则第一条指令会在 boot 期间就流进 EX。

修完 fmax **67.5 → 69.5**（反超基线 69.2）✓

> **通用教训**：把一个"寄存器输出"改成"组合别名"时，要重新检查**这个寄存器
> 原来是否恰好切断了某条反馈环或长路径**。`if_id_reg` 在这里同时充当了
> ①一级流水 ②反馈环的切点 ③晚间信号的屏障 —— 去掉它等于同时撤掉这三个作用。

---

## 5. ⚠ 另一个评分阻断问题：ITERATIONS 必须跟着重算

设计变快后，固定的 1200 次迭代只跑 **9.91 s**，**不满足 CoreMark 的 ≥10 秒要求（成绩无效）**。

- 新增 `tools/mk_cm_hw.py`：用 subprocess **列表**传参重建 `cm_hw.hex`，
  同时解决 (a) 工作流印的配方缺 `FLAGS_STR`、照抄会编译失败；
  (b) PowerShell 会吃掉 `FLAGS_STR` 的引号 —— 两个问题。
- 重建为 `ITERATIONS=1300` → **10.74 s**（留 7% 余量），CRC 仍匹配 ✓

> **纪律**：**每次性能提升都要重算 ITERATIONS**：
> `ITER_new = ceil(ITER_old × 10.0 / 实测秒数 × 1.05)`

---

## 6. 交付口径已同步

`README.md` / `CODE-MAP.md` / `HANDOFF.md` / `results/gap-analysis.md` /
`results/analysis-report.md` 均已按"**仍是 5 级，去掉的是冗余 IF 寄存器**"的口径改写
（≥3 级要求不受影响）。
