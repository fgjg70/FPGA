# P8 · 4 级流水线（issue #5）：删掉 `if_id_reg`，IMEM 输出寄存器直接充当 IF/ID

**日期**：2026-10-08 **状态**：✅ 已实施并实测 **来源**：GitHub issue #5（含 2 条复审评论）

---

## 1. 结果（全部指标同时改善 —— 罕见）

| 指标 | 基线 | **4 级流水** | 变化 |
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

**回归**：`PASS 11`（含 `tb_sw_coremark` 的 CoreMark CRC 自校验）。
**累计**（相对最初的 imem 组合读基线 139.1）：吞吐 **+21.1%**。

> 与 issue #5 预测的对照：预测 ticks 412,026（−11,501）；实测 **413,070（−10,457）**。
> 差 1,044 拍（0.25%），因为并非每次误判都恰好省 1 拍。
> **issue 的"load-use 停顿中性"论断被实测证实**：`load-use = 30,645`，**与改动前逐位相同** ✓。

---

## 2. 为什么成立（两条不变量）

去掉 `if_id_reg` 的前提是"IF 段没有两个寄存器装同一条指令"。实测两条不变量：

```
① imem.sv 的价值: 取指地址接的是**组合的** pc_next
   ⇒  imem_rdata(N) == mem[pc(N)]            (imem.sv:11-14, core.sv:203-208)
② BTB 用**当前 pc** 查询:  u_btb(.pred_pc(pc))   (core.sv:267)
   ⇒  第 N 拍的 [指令 / pc / 预测] 三者天然对应同一条指令
```

于是 `if_id_reg` 只是把同一份信息再打一拍。去掉后：

```
4 级:  IMEM 输出寄存器(=IF/ID) -> ID/EX -> EX/MEM -> MEM/WB
收益:  重定向发生在 cycle T 时, 正确路径指令进 EX 由 T+4 提前到 T+3
       ⇒ 每次误判省 1 拍。 赛题要求 ≥3 级, 4 级合格。
```

## 3. 改动（`core.sv` 两处 + 删一个文件）

1. **`u_if_id` 实例 → 组合别名**（关键取舍）：
   ```systemverilog
   assign if_pc = pc;  assign if_pc_plus4 = pc_plus4;  assign if_instr = imem_rdata;
   assign if_pred_taken = pred_taken;  assign if_pred_target = pred_target;
   ```
   **为什么保留 `if_*` 这几个名字**：`tb_core` 的逐拍 trace 与 `tb_sw` 的
   **取指对齐自检**都直接引用 `u_dut.if_pc` / `if_instr`。做成别名 ⇒
   **两个 testbench 一行都不用改**，而且自检的不变量（`imem_rdata == mem[pc]`）
   完全不变、继续有效。
2. **ID 门控**（唯一代价）：`id_ctrl = id_en ? id_ctrl_raw : ctrl_s'(0);`
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
- **启动期必须门控** —— 原来靠 `if_id_reg` 的 `stall(fetch_hold)` 把 IF/ID 冻在复位值 (NOP)，去掉 IF/ID 后只能在这里补，否则第一条指令会在 boot 期间就流进 EX。

修完 fmax **67.5 → 69.5**（反超基线 69.2）✓。

> **通用教训**：把"寄存器输出"改成"组合别名"时，要重新检查**这个信号原来是否
> 恰好切断了某条反馈/长路径**。`if_id_reg` 在这里同时充当了
> ①流水级 ②反馈环的切点 ③晚间信号的屏障 —— 去掉它等于同时撤掉这三个作用。

---

## 5. 交付口径已同步

`README.md` / `CODE-MAP.md` / `HANDOFF.md` / `results/gap-analysis.md` /
`results/analysis-report.md` 的"5 级流水"表述已改为 4 级（≥3 级要求仍满足）。
