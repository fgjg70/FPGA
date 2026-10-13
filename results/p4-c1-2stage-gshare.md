# C-1 · 两级流水 gshare 方向预测器（BTB 512 + PHT 8192）

**日期**：2026-10-11  **状态**：RTL 已落盘并实测通过，**接线待 `rtl-bypass` 实施**（`core.sv:358-372`）
**交付文件**：`btb.sv`（192 行，重写）、`bht.sv`（148 行，新增）、`ras.sv`（未改）

---

## 0. 一句话

把预测器从「当拍组合查表 → 直接进 PC mux」改成论文 RVCoreP-32IM 的
**两级流水 gshare**（`p2_pc = pc_next` 提前一拍查表，`q_*` 全是寄存器输出）：

| | 现状（同一份 RTL 快照） | 本设计 | 变化 |
|---|---:|---:|---:|
| CoreMark ticks | 460,311 | **453,942** | **−1.38%**（判据 ≤ +1%） |
| 预测误判 | 11,530 | **8,020** | **−30.4%** |
| 精度（exact） | 88.43% | **91.95%** | +3.5 pt（判据 ≥ 88.8%） |
| PHT 读写索引对齐自检 | — | **0 错** | 见 §5 |
| 功能 | PASS + CRC 一致 | PASS + CRC 一致 | — |

---

## 1. [文件:行] 结构与改动

| 文件 | 行 | 改动 |
|---|---:|---|
| `btb.sv` | 192 | 64 项 → **512 项**；`pred_*` 组合口保留但恒"不预测"（见 §2）；新增 `p2_pc` + `q_*` 两级流水口；表项新增 `is_cond` 位 |
| `bht.sv` | 148 | **新增**：PHT 8192 项 × 2 位饱和计数器；索引 = `PC[13:1] ^ (GHR & mask)`；写回索引随流水带 2 拍 |
| `ras.sv` | 87 | **未改**：`RAS_EN` 默认关，语义不变（见 §7） |

### 1.1 结构（文字图）

```
                 T 拍 (查表/地址)                      T+1 拍 (判定/接线)
  pc_next ──┬──► BTB 索引 pc[10:2] ─┐
            │    tag      pc[13:11] ─┴─► 组合读 ──► [q_vld/q_tag/q_tgt/is_ret/is_cond] ┐
            │                                                                          ├─► q_hit/q_target/q_is_ret
            └──► bht 索引 PC[13:1]^GHR ─► BRAM 寄存读 ──► [q_ctr] ─────────────────────┘
                                                                                       │
                                          q_taken = q_hit & (q_is_cond ? q_ctr[1] : 1) ◄┘   ← 只多 1~2 级 LUT
                                                                                       │
  core.sv:924/925  pc_src = q_taken ; pc_target = q_target   ← 全是寄存器(+1 级 LUT)
```

- **零气泡**：`p2_pc(T) = pc_next(T) = pc(T+1)`，所以 T+1 拍的 `q_*` 正好是当拍 `pc` 那条指令的预测。
  BRAM 的 1 拍读延迟被"提前一拍给地址"完全吸收 —— 这正是 RVCoreP `proc.v:426
  r_btb <= w_btb` / `:425 r_btkn_t <= ...` 的机制。
- **唯一取舍**：`q_taken` **不寄存**。若把方向也打一拍，预测就晚于它对应的 PC，
  每个 taken 分支多 1 拍气泡（ticks 必崩）。它只依赖寄存器（`q_vld/q_tag/q_ctr`），
  与 `p2_pc` 没有组合路径 ⇒ `pc_next → p2_pc → q_*` 不构成组合环。
- **512 项容量**：索引 9 位 + tag 3 位 = `pc[13:2]`，覆盖整个 16 KB imem 窗口；
  老 64 项（6+6）把 4096 条指令挤进 64 个槽，冲突是主因之一（实测条件分支误判
  6061 → 4172）。

---

## 2. [接口] `btb.sv`（新增口 + 旧口语义）

| 口 | 方向 | 说明 |
|---|---|---|
| `pred_pc / pred_hit / pred_taken / pred_target / pred_is_ret` | in/out | **兼容口，保留**。两级流水后"当拍查表当拍出结果"物理上不存在（8192 项 PHT 不可能组合读），所以这 4 个输出**恒为 0/不预测** —— 不悄悄改旧口的时序语义；core 不接线时功能仍然完全正确，只是所有 taken 分支退回 EX 重定向 |
| `p2_pc` | in | **新**。= core 的 `pc_next`（下一拍要取的 PC）。T 拍给，T+1 拍 `q_*` 有效 |
| `q_hit / q_taken / q_target / q_is_ret` | out | **新**。对应 T+1 拍 `pc` 的预测；`q_target` 直接是寄存器输出 |
| `upd_en/upd_pc/upd_taken/upd_target/upd_is_ret/upd_is_cond` | in | **逐位不变** |
| `align_err_cnt[15:0]` | out | **新**，自证：PHT 读写索引对齐错次数，必须恒 0（可悬空） |

参数默认（**实测选定，core 例化时不要传，改参数只动 btb.sv**）：
`IDX_BITS=9`（512 项）、`PC_TOP=14`、`PHT_BITS=13`（8192 项）、`GH_BITS=13`、`HIST_ALL_CTRL=1`。

`ras.sv` 接口**未动**。

---

## 3. [接线清单]（`core.sv` 由 `rtl-bypass` 单写）

### 3.1 `core.sv:358-372` 整块替换（**必须原子改完**）

```systemverilog
  btb #(.IDX_BITS(9), .PC_TOP(14), .PC_BASE(IMEM_BASE)) u_btb (
    .clk (clk),
    .rst (rst),
    // [A] 兼容口: 两级流水后"当拍查表"不存在 -> 恒不预测 (保留端口只为编译不破)
    .pred_pc (32'd0), .pred_hit (), .pred_taken (), .pred_target (), .pred_is_ret (),
    // [B] 两级流水口: T 拍 p2_pc = pc_next, T+1 拍 q_* 对应当拍 pc
    .p2_pc   (pc_next),
    .q_hit   (pred_hit), .q_taken (pred_taken),
    .q_target(btb_pred_target), .q_is_ret (pred_is_ret),
    // [C] 更新口逐位不变
    .upd_en (btb_upd_en), .upd_pc (id_ex_pc), .upd_taken (actual_taken),
    .upd_target (ex_pc_target), .upd_is_ret (ex_is_ret), .upd_is_cond (ex_is_cond),
    .align_err_cnt ()
  );
```

- `pc_next` 在 `core.sv:314`（含 C-11 的 `pc_flush` 项）已声明，可直接用。
- **core 内部信号名一个都不用改**：`pc_src`(:924) / `pc_target`(:925) / `if_pred_*` 别名 /
  RAS 分支(:420/:424) 全部不动 —— 只换例化块。
- `.p2_pc` **必须同一次改完**：漏接 → 输入悬空 → `q_taken` = X → `pc_src` = X。
  旧输出悬空（`.pred_hit()` 空连接）是合法的。

### 3.2 其它必须同步的位置（文件清单/观测口径，都不在 `btb.sv`/`bht.sv` 范围）

| 位置 | 状态 | 改成 | 为什么 |
|---|---|---|---|
| `fpga/build.tcl:123` | ✅ build-repo 已改 | RTL 列表加 `"$root/bht.sv"` | **显式列表，没有 glob 兜底；不加综合直接报找不到模块 `bht`** |
| `fpga/build_ila.tcl:242` | ✅ build-repo 已改 | `add_files -norecurse [list ...]` 也加 `bht.sv` | 我最初以为"I LA 只算 `*.sv` 哈希、glob 会自动带上" —— **只对哈希成立**：`add_files` 同样是显式列表，不补会在 add_files/elaborate 报 `module bht not found`。build-repo 用 xtclsh 沙箱桩实测两列表各 23 项 == canonical 23 |
| `tools/fpga_workflow.py:144` | ✅ Lead 已改 | `CORE_SV_ORDER` 加 `"bht.sv"` | drift-check 口径 |
| `sim/tb_sw.sv:301-312`、`:576` | ✅ verify-sw 已改（比建议更好） | 几何**从 `u_btb` 实例参数推导**（`IDX_BITS`/`PC_TOP`）而不是再硬编码一次；`bi<64` → `1<<IDX_BITS`；并新增"`btb_has_entry(pc_next)` 打一拍 == `pred_hit`"的 `$fatal` 自证 | 统计从 1036 (1%) 修正为 **70225 (99%)**；那条自证顺带成了 C-1 相位契约的**第二个独立守门人**（45 万拍 0 次不一致） |
| `tools/run_coremark.py:24`、`tools/hier_util.tcl:30`、`CODE-MAP.md:94` | ⏳ 待 owner | 补 `bht.sv` / 文件数与行数口径 | build-repo 已点名（ModelSim CoreMark 路会 elaborate 失败） |

---

## 4. [精度与 ticks 对照]

判据行（本次构建/仿真的成功标记，取自各自日志）：
`RESULT : PASS` + `Correct operation validated` + `Total ticks` + `--- predictor accuracy ---`。

### 4.1 最终配置 vs 现状（**2026-10-11 15:36 版 core.sv，含 C-11**）

| | ticks | cycles | ctrl-flow | 误判 | 精度 | cond | JALR | align |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 现状（64 项 Smith，组合查表） | 460,311 | 510,179 | 99,616 | 11,530 | 88.43% | 6,061 | 4,367 | — |
| **本设计** | **453,942** | 503,160 | 99,616 | **8,020** | **91.95%** | 4,172 | 3,650 | **0** |

证据：`.fpga-cache/pred-eval/log_base.txt`（现状）、`log_g13a.txt`（本设计）。

**误判代价口径（回答 verify-sw 的疑问：1.00 → 2.00 拍/次是谁带来的）**：
同一份 core、换预测器前后**都是 2.00 拍/次** —— 现状 11,530 次 → 23,060 冲刷拍，
本设计 8,020 次 → 16,040 冲刷拍。所以这是 **C-11 的寄存式重定向 + 2 拍冲刷窗口**
（`redir_flush = br_redir_eff || br_redir_r`，`core.sv:913`）的性质，**与 C-1 无关**；
C-1 只把重定向*次数*砍了 30%，从而放大了 ticks 收益（2 拍 × 3,510 次 ≈ 7,020 拍，
这也解释了为什么 C-11 之后收益从 −0.70% 变成 −1.38%）。

**独立相位验证（verify-sw 加的守门人）**：`sim/tb_sw.sv` 现在把
`btb_has_entry(pc_next)` 打一拍后与 `pred_hit`(= `q_hit`) 逐拍比对，不一致即 `$fatal`；
完整 CoreMark（45 万拍）**0 次不一致** ⇒ "T 拍查 `pc_next` / T+1 拍出结果"的相位契约
有了第二个独立守门人。若以后把预测口改成三级，那个延迟拍数必须同步改（别删这条自证）。

### 4.2 参数扫描（同一快照，相对比较；**都在 `is_cond` 标记版之后**）

| 变体 | GH | 历史记什么 | ticks | 误判 | 精度 | cond 误判 |
|---|---:|---|---:|---:|---:|---:|
| 现状 | — | 局部 Smith 64 项 | 449,854 | 11,530 | 88.43% | 6,061 |
| 纯局部 | 0 | — | 447,583 | 8,916 | 91.05% | 5,067 |
| 只记条件分支 | 8 | cond only | 449,197 | 10,560 | 89.40% | 6,711 |
| 只记条件分支 | 13 | cond only | 447,112 | 8,525 | 91.44% | 4,676 |
| 记全部控制流 | 8 | all ctrl | 448,564 | 9,874 | 90.09% | 6,025 |
| **记全部控制流** | **13** | all ctrl | **446,687** | **8,025** | **91.94%** | **4,176** |

`is_cond` 标记之前的长历史扫描（同一快照）用于说明"短历史更差"这个反直觉结论：

| GH（只记条件分支） | 0 | 4 | 6 | 8 | 10 | 13 |
|---|---:|---:|---:|---:|---:|---:|
| 误判 | 8,916 | 10,758 | **12,307** | 11,405 | 10,172 | 9,599 |

**结论**：在本核的**陈旧 GHR**（见 §6）下，短历史几乎是纯噪声（GH=6 比不用历史还差
3,391 次误判），长历史反而捕捉到循环状态；13 位 + 记全部控制流最好。
这与 P4 那次"6 位历史把 64 项表摊薄"的失败是同一类现象，只是这次表足够大。

### 4.3 中间态（**新 `btb.sv` 已落盘、`core.sv` 还没接线**）—— 给协作者的兜底预期

| | ticks | 误判 | 精度 | 结果 |
|---|---:|---:|---:|---|
| 兼容口恒不预测 | 563,779 | 71,059 | 28.71% | **`RESULT : PASS` + CRC 正确** |

⇒ 落盘期间工作区**只会变慢，不会出错**（预测错误一律由 EX 重定向纠正）。

### 4.4 宏矩阵（`IMEM_COMB_READ` / `RAS_EN`，接线后同一快照）

| 宏 | ticks | 误判 | 精度 | cond | JALR | align | 结论 |
|---|---:|---:|---:|---:|---:|---:|---|
| 默认（imem 寄存读） | 453,942 | 8,020 | 91.95% | 4,172 | 3,650 | 0 | 交付配置 |
| `IMEM_COMB_READ` | 453,942 | 8,020 | 91.95% | 4,172 | 3,650 | 0 | **逐位相同**：两种取指口径下 `imem_rdata(N)=mem[pc(N)]` 的配对不变 ⇒ 预测相位与 2 拍索引链都不受影响（预期如此，现在有实测） |
| `RAS_EN` | **452,288** | **7,167** | **92.81%** | 4,173 | **2,796** | 0 | 见 §8 —— 两级流水把栈顶 mux 从"BTB 读 + mux"里解放出来，当年否掉 RAS 的 fmax 理由不再成立 |

### 4.5 口径提示（重要）

`.fpga-cache/logs/tb_sw_coremark.log` 的 **413,070 ticks / 88.8%** 是 10-11 12:29 的
旧快照；**现状树已经跑不出它**：同一程序在 15:36 的 `core.sv` 上是 **460,311 ticks**
（stall 从 45,208 → 84,407，load-use 从 30,793 → 70,982 —— C-2/C-11 在飞），
且 `ctrl-flow` 分母从 102,656 变成 99,616（`verify-sw` 改了统计口径）。
因此本报告的对照一律是"**同一份快照的现状**"，而不是那个缓存数字。

---

## 5. [证据] 对齐自证（`align_err_cnt`）

PHT 写回的索引必须与预测时读的**逐位同一个**（否则学习永远对不上，
这正是 P4 那次 gshare 看起来无用的另一个原因：它用**当前** GHR 重算写回索引）。
本实现把读索引随流水带 2 拍：

```
T   拍: rd_idx = PC[13:1]^GHR(T)      ; 地址 = p2_pc(T) = pc(T+1)
T+1 拍: 读数据 ctr_q 有效             ; idx_d1 = rd_idx
T+2 拍: 该指令在 EX 解析出真实方向    ; 写 mem[idx_d2]，idx_d2 = rd_idx
```

为什么是 2 拍：`idx_d2(t) ≡ rd_idx(t-2) ≡ index(p2_pc(t-2)) ≡ index(pc(t-1)) ≡ index(id_ex_pc(t))`。
自证：`pcw_d2 != upd_pc[PC_TOP-1:2]` 时计数并退回"当前 GHR 重算"。

**实测 `align_err_cnt = 0`**（全部变体、全部运行，包括 C-11 前后的两版 core；
对应的 ctrl-flow ≈ 99,616 ⇒ 检查执行了约 10 万次）。tb_sw 的层次化探针
`[probe] align_err_cnt = 0` 打在 `--- predictor accuracy ---` 之前。

---

## 6. [结构] 两个关键实现细节

1. **PHT 必须 BRAM、必须寄存读**（PITFALLS 三.11：组合读推不出 BRAM）。
   8192×2 = 16 Kb = **1 块 RAMB18**（8K×2 是它的原生形状）；
   若用分布式 RAM 约 500 LUT。寄存读正好与"提前一拍给地址"契合。
2. **陈旧 GHR 是已知的精度上限**：GHR 在 EX 段（提交）更新，比取指晚约 2~3 条
   控制流指令，所以预测时看到的是"稍旧的"历史。这是本设计为"零气泡 + 简单"
   付的代价；论文的 RVCoreP 用**投机 GHR**（`r_bhr` + `r_bhr_d`，误判时回滚）
   换更好的相关性。要再进一步需要新增一个 `pred_instr` 输入（取指段译码）＋回滚，
   本轮**未做**（收益未测，且会动接口）。

---

## 7. [资源估算]（要 Lead 的 synth 实测确认）

| 资源 | 增量估算 | 说明 |
|---|---|---|
| BRAM | **+1 RAMB18**（16 Kb，`ram_style="block"`） | PHT。若综合把它塞进 RAMB36，报 +0.5 |
| LUT | **+200 ~ 250**（估算） | BTB 512×20 bit 分布式 RAM（存储 ~160 + 读 mux ~60）+ 索引/比较；**保留具名数组 `vld/tag/tgt/is_ret` 是因为 `tb_sw` 层次化读它们，打包成 BRAM 会让 tb_sw 编译失败** |
| LUT（BTB 改 BRAM 的替代方案） | ≈ +20 | 需要同时改 `sim/tb_sw.sv:182-190` 的观测函数（读打包字），这会让 tb_sw 在该改动落地前**编译失败** |
| FF | +~60 | 一级流水寄存（vld/tag/tagexp/tgt/is_ret/is_cond）+ bht 的索引/PC/计数器链 |
| DSP | 0 | — |

> 150 MHz 的关键不是面积而是**路径**：查表整条链（索引 → 表读 → tag 比较 →
> 方向判定 → 目标 mux）已从 `pc` 的 D 端移到"寄存器的 D 端"，PC 路径上只剩
> `q_* → (C-11 的 pc_src/pc_target 2:1 mux) → pc`。

---

## 8. [其他] 与 `RAS_EN` / 宏的关系

- `ras.sv` **未改**，`RAS_EN` 默认关、语义不变。core 的 `pred_target = pred_is_ret ?
  ras_top : btb_pred_target` 一行也不用动（`pred_is_ret` 现在是 `q_is_ret`，仍是寄存器）。
- **建议（本轮未做结构改动，但已实测收益）**：两级流水结构恰好消除了当年否掉 RAS 的理由 ——
  栈顶 8:1 mux 可以**提前一拍**读、跟 BTB 一起寄存，"返回目标晚一拍"不再影响 pc 路径。
  剩余误判里 JALR 占 3,650/8,020 = **45.5%**，是下一个最值钱的杠杆。
  **实测（`RAS_EN`，`ras.sv` 一字未改，栈顶仍是组合读）**：ticks 453,942 → **452,288**、
  误判 8,020 → **7,167**（92.81%）、JALR 3,650 → **2,796**、`align_err=0`、`RESULT : PASS`。
  与 P4 那次"RAS 赢 0.38% 周期却输 2.8% fmax"不同：现在 BTB 读已经不在 pc 路径上，
  加进来的只有一个 8:1 栈顶 mux。**要不要默认打开取决于 `--ras` 的 fmax 实测**（Lead 串行排队），
  这是本轮唯一"结构红利已经付过、只需决定是否取用"的项。
- `BTB_GSHARE` 宏：本设计默认就是 gshare（论文配置），旧的"未定义宏 = 纯局部 Smith"
  回退路径不再存在；旧文件已备份在 `.fpga-cache/pred-eval/btb.r1-backup.sv`。

---

## 9. 复现

```powershell
# 仓库外评测（不碰仓库根、不进 RTL-SHA）。base 会自动把仓库里已接线的 core.sv
# 退回 R1 兼容接线, 所以接线落盘之后基线依然可复现。
python .fpga-cache\pred-eval\run.py base g13a comb ras
# 仓库回归（接线后, 干净全量）:
python tools\fpga_workflow.py verify --force
```

**验收证据（接线后的干净全量跑）**：`verify --force` → **PASS 12**；
`.fpga-cache/logs/tb_sw_coremark.log`：
```
[btb] 2-STAGE gshare ACTIVE: BTB=512 (IDX=9 TAG=3) PHT=8192 GH=13 HIST_ALL=1
Total ticks      : 453942
Correct operation validated. See README.md for run and reporting rules.
ctrl-flow  = 99616   mispredict = 8020   accuracy = 92%
RESULT : PASS
```

### 冻结版本锚点（本报告全部数字对应的 RTL）

| 文件 | mtime | SHA256（前 32 位十六进制） |
|---|---|---|
| `btb.sv` | 2026-10-11 15:42:41 | `689B2495E7A6B087DDF5B7C208391625` |
| `bht.sv` | 2026-10-11 15:42:47 | `82B63F706B8E227B59E318849E6F0D6A` |
| `core.sv`（接线后） | 2026-10-11 15:44:36 | `F5BE60C5401DB5E9BD2B3DC352AE4E56` |
| `ras.sv`（未改） | 2026-10-09 20:20:15 | `352CCBD061ECB62FA3A522FA63D7E306` |

> 综合出的 LUT/BRAM/fmax 只有对齐到这一组哈希才可与本报告的仿真数字同口径比较
> （纪律：任何"我测到 X"都要能指回这一次构建/仿真）。之后的 RTL 只允许改
> `core.sv:496-498` 那条**纯注释**（rtl-bypass 已排进下一个窗口）—— 它会改 RTL-SHA，
> 但不改网表，也不应改任何本报告的数字。

自证行（宏/结构生效的分辨手段，PITFALLS R17 的教训）：
```
[btb] 2-STAGE gshare ACTIVE: BTB=512 (IDX=9 TAG=3) PHT=8192 GH=13 HIST_ALL=1
[btb] legacy pred_* ports tied to NO-PREDICTION; wire p2_pc/q_* instead
```
> 第二行是 C-1 当时的原样输出；候选 A 之后实际接线是
> `.p2_pc(p2_pc_ns) / .p2_hold(p2_hold) / .p2_pc_pht(pc_next) / .q_*`（见附录 A.3）。

---

# 附：候选 A —— BTB 查表地址去掉停顿项（2026-10-13 落盘）

## A.1 动机（来自 ILA 流 timing 报告）
交付档受 **ILA 流**限制：同样的 RTL，ILA 流比评分流差 ~0.5~0.9 ns，失败侧最大的族是
`u_core/u_btb/q_vld_reg/D`（另有同族 `q_cond_r_reg/D`）。逐跳拆解（评分流 `timing_paths.rpt`
第 8/第 28 条，两条同源）：

| 段 | 内容 | 耗时 | 占比 |
|---|---|---:|---:|
| A | imem BRAM `rdata_reg_2` clk→DO（指令 bit18 = `rs1[3]`） | 2.125 ns | 26.7% |
| B | **译码/冒险/PC 选择锥** 5 级 LUT + 6 段布线（网名 `load_use_ex`/`done_r`/`valid`/`pc_flush`） | 3.721 ns | **46.7%** |
| C | 地址线 → `vld_reg_*/DPRA1` | 0.943 ns | 11.8% |
| D | 分布式 RAM 读 + MUXF7 | 0.246 ns | 3.1% |
| E | 末级 LUT（`q_vld_i_1`） | 0.894 ns | 11.2% |

⇒ 这是**查表读 → 打拍**，不是更新口写（更新口全场只以 +0.097 的 hold 检查出现）。
但**真正的大头是 B 段**：C-1 把 `p2_pc = pc_next`（含 `fetch_hold`）当查表地址，
于是"指令译码 + load-use 冒险"整锥（其中布线占 83%）被拉进了 `q_*` 的 D 端。

## A.2 一个"看起来等价、其实改了行为"的实测（本轮最值钱的一条）
第一版按建议把**整条相位链**（含 bht 的 `ctr_q/idx_d1/idx_d2/pcw_d1/pcw_d2/ctr_d1`）
用 CE 一起冻结。**实测不是逐位等价**：

| | ticks | cycles | 误判 | 精度 |
|---|---:|---:|---:|---:|
| 参考（老实现） | 453,942 | 503,160 | 8,020 | 91.95% |
| 整链冻结 | **454,996** | 504,234 | **8,557** | 91.41% |

二分：**"只冻结、地址不改" = 同样 454,996** ⇒ 与地址无关，是冻结本身。
逐拍 trace diff 定位到**首个分歧：cycle 8283，停顿中冻结的 PC = `0x80000e6c`**：
```
8282  pc=0x80000e6c  pred_taken=1  pred_target=0x80000eec   两边相同
8283  参考 = 0                                              |  整链冻结 = 1
```
**根因**：停顿期 **GHR 仍被 EX 里刚解析的控制流推动**（更新口不受停顿影响），
而老实现的查表地址 = 冻结 PC，于是 **PHT 索引 = 冻结PC ^ 当前GHR** ⇒ 同一个 PC 的方向
预测会被用**漂移后的 GHR 重算并刷新一次**。这条"停顿期刷新"**是现有 ticks 的组成部分**。

## A.3 落盘设计（实测逐位不变）
```
p2_pc      = pc_flush ? pc_flush_pc : (pc_src ? pc_target : pc_plus4)   // 快地址, 去 fetch_hold
p2_hold    = fetch_hold && !pc_flush                                    // 只冻结 6 个 BTB 输出寄存器
p2_pc_pht  = pc_next                                                    // 老地址, 只喂 PHT 读口
bht        : 一律不冻结 (ctr_q/idx_d1/idx_d2/pcw_d1/pcw_d2/ctr_d1 照常走)
imem_addr  : 仍用带 fetch_hold 的老 pc_next —— 一行未改
```
- BTB 表项在停顿期不会变 ⇒ "输出 CE 冻结" ≡ 老实现"重读同址"（见 A.4）。
- 晚到的 `fetch_hold` 锥只剩 **CE pin** 与 **PHT 的 BRAM 地址建立**，不再穿过
  `LUTRAM 读 + MUXF7 + 末级 LUT → q_vld_reg/D`。

## A.4 可审计的等价性边界（不是"trace 没差所以等价"）
依据 `core.sv:486 btb_upd_en = is_ctrl_flow && !hold_mem && !rst && !redir_kill` 与
`hazard_unit.sv:97-99`（`pipe_stall = load_use||lsu_stall||ex_busy`，`hold_mem = lsu_stall||ex_busy`）：

| 停顿来源 | 门控 | 停顿拍会写表吗 |
|---|---|---|
| `load_use_ex`（EX 是 load） | `is_ctrl_flow=0` | 不会 ✅ |
| `lsu_stall` | `hold_mem=1` | 不会 ✅ |
| `ex_busy` | `hold_mem=1` | 不会 ✅ |
| `load_use_mem`（EX 是真指令） | `hold_mem=0` | **若 EX 是控制流 ⇒ 会** ⚠ |

**残余窗口** = `load_use_mem ∧ EX 是控制流 ∧ uidx==pidx`（IDX=9 ⇒ `upd_pc[10:2]==pc[10:2]`，
同一 2 KB 窗别名）。此时老实现下一拍读到的是**被别名写覆盖**的表项（tag 变 ⇒ `q_hit` 掉 0），
冻结版保持旧预测 ⇒ **只影响预测，不影响正确性**（误判由 EX 重定向兜底），且冻结版在别名情形下
其实更"对"。**绝不**为了"可证逐位等价"去门控更新口：`load_use_mem` 那拍 EX 会前进，
丢一次写就**永久少写一个表项**，那才是真会改 ticks 的做法。

## A.5 验收证据（落盘后，同一份 RTL）
| 判据 | 结果 |
|---|---|
| `verify --force` | **PASS 12** |
| CoreMark ticks | **453,942**（逐位等于改前）/ cycles 503,160 |
| 误判 / 精度 | 8,020 / 91.95% |
| `align_err_cnt` | **0**（10 万次更新的索引/PC 对齐自证） |
| PHT_SUM / BTB_SUM | **10019 / 1461117 —— 与改前逐位相同** |
| 四配置（默认 / `IMEM_COMB_READ` / `RAS_EN` / `A_EN`） | 改前改后**逐位一致**（RAS 档 452,288 / 7,167 / 92.81%） |
| 逐拍 trace（改前的整链冻结版 vs 本版） | 503,161 行 0 差异（本版 vs 参考） |

## A.6 复现
```powershell
python .fpga-cache\pred-eval\run.py frozen hold    # 本版 vs 参考: 0 差异
python .fpga-cache\pred-eval\run.py holdka         # 被否掉的"整链冻结": +537 误判
python .fpga-cache\pred-eval\run.py comb hcomb ras hras fa_ext ha_ext   # 宏矩阵
```
落盘物（最终指纹，2026-10-13）：

| 文件 | SHA256（前 16 位 … 后 8 位） | 说明 |
|---|---|---|
| `btb.sv` | `7373CCD3C19622D5…7963B50B6B` | 229 行；**落盘后再把 A.2 的 8283 教训补进文件头（纯注释，不改行为/不改网表）** ⇒ 与 `rtl-bypass` 那轮四配置实测（其运行早于该注释编辑）数字不受影响 |
| `bht.sv` | `71137FFE95FE10D2…7EBF88CB3` | 148 行；未再改动 |
| `core.sv` | `1C94157937FB9DE0…83DDD75AF` | `rtl-bypass` 的 5 行接线（2 wire + 3 连接） |

