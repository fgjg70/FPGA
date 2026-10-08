# ref5 · E1 实验报告 —— 试掉取指环最后那条地址 mux（+ ALU 扇出）

**日期**：2026-10-08　**分支**：`ref5-yardstick`（未 commit / 未切分支 / 未上板）
**器件与口径**：与 `REPORT.md` **完全一致** —— `xc7a100tfgg484-2`、非工程模式、
`create_clock -period 20.000`、`fmax = 1000/(20 − WNS)`、
`synth_design -resource_sharing off` → `opt_design` → `place_design -directive WLDrivenBlockPlacement`
→ `route_design`（Default）→ 报告。**对标基线 = V7 最终版 137.25 MHz。**

> 一句话：**取指环那条地址 mux 确实被干掉了**（环本身 6.760 → 6.379 ns，slack +0.484 ns），
> 但**光靠它只值 +1.41 MHz** —— 因为瓶颈当场转移到了 ALU 那条路，而 ALU 那条路的病根是
> **`ex_b[3]` 一根网驱动 115 个负载（布线 3.0 ns）**。把那个扇出治了以后，
> **最终 152.114 MHz（+14.86 MHz / +10.8%）**，瓶颈再次转移（这次到 ID 段的操作数选择）。

---

## (a) 改了什么

全部改动都在 `ref5/` 内，且**每一处都被 `ifdef` / env 开关挡住，默认路径与 V7 逐字相同**
（已用两次基线实测证明，见 (b)）。

| 文件:行 | 一句话 |
|---|---|
| `ref5/ref5_top.sv:22-25` | `ref5_imem` 增加**条件编译**的 `rd_en` 读使能口（`ifdef REF5_ENARDEN` 才存在） |
| `ref5/ref5_top.sv:40-52` | imem 同步读改成 `if (rd_en) rdata <= mem[addr[...]]` —— 推断成 RAMB36 的 **ENARDEN**，停顿拍**冻结输出寄存器**（而不是摁住地址） |
| `ref5/ref5_top.sv:109-111, 120-122, 135-137` | 顶层 `imem_rd_en` 连线与例化 |
| `ref5/ref5_core.sv:47-49` | `ref5_core` 增加条件编译的输出 `imem_rd_en` |
| `ref5/ref5_core.sv:326-352` | E1 分支：`imem_addr` 只由**已寄存的 pc**（+EX 的 redirect）决定，`pipe_stall` 彻底离开地址脚；`imem_rd_en = !pipe_stall \| redirect \| !boot_done` |
| `ref5/ref5_core.sv:129-138` | （E5）`ifdef REF5_ALU_MFOUT` 给 `id_ex_a/id_ex_b` 加 `(* max_fanout = \`REF5_ALU_MF *)` |
| `ref5/build_ref5.tcl:51-66, 76-92, 133-145` | 新增 env 开关 `REF5_ENARDEN` / `REF5_ALU_MFOUT` / `REF5_ALU_MF` / `REF5_TOP_N` + **自证打印**（`REF5_ENARDEN=`、`REF5_ALU_MFOUT=… VALUE=…`）；新增每 tag 一份 `runs/<tag>/timing_paths.rpt` 全展开路径 |

跑法（A/B 各一条命令，**默认行为完全不变**）：

```powershell
$env:PROCESSOR_ARCHITECTURE="AMD64"
$viv = "D:\software\Learn\Xilinx\Vivado\2018.3\bin\vivado.bat"
# 基线（= V7，逐位复现 137.25）
& $viv -mode batch -nojournal -nolog -source ref5\build_ref5.tcl
# E1 主实验
$env:REF5_ENARDEN="1"        ; & $viv ... -source ref5\build_ref5.tcl
# 最佳配置 = E1 + ALU 扇出
$env:REF5_ALU_MFOUT="1"      ; & $viv ... -source ref5\build_ref5.tcl     # (REF5_ALU_MF 默认 16)
```

证据位置：`ref5/runs/<tag>/{timing,util,timing_paths}.rpt`（被 `ref5/.gitignore` 忽略），
完整 stdout 在 `D:\USER\Desktop\FPGA\.ref5_scratch\<tag>.log`。
**`ref5/timing.rpt` / `ref5/util.rpt` 已还原成 V7 原件**（未改动仓库存档文件）。

---

## (b) A/B 对照表（每一格都是实测；"逐位相同"= WNS/路径/LUT/FF 全部一致）

| # | 配置 | fmax (MHz) | WNS (ns) | Slice LUT | FF | BRAM | 关键路径一句话 | 跑了几次 / 可复现 |
|---|---|---|---|---|---|---|---|---|
| V7 | **基线**（= 改动后的默认路径，所有开关关） | **137.250** | +12.714 | 852 | 458 | 2 | `imem DOADO → hit → pipe_stall → 地址 mux → ADDRARDADDR[11]` 6.760ns L=4 | 历史 3 次 + 本次 5 次，**逐位相同** |
| E1 | 只开 `REF5_ENARDEN` | 138.658 | +12.788 | 863 | 458 | 2 | **换到 ALU**：`id_ex_b[3] → 移位/结果 mux → ex_mem_alu_out[5]` 7.200ns L=5（route 6.127 = 85%） | 3 次，逐位相同 |
| E5 | 只开 `REF5_ALU_MFOUT`（=16） | 145.751 | +13.139 | 960 | 554 | 2 | 仍是取指环，但**变短**：`DOADO → 地址 mux → ADDRARDADDR[10]` 6.336ns L=4 | 2 次，逐位相同 |
| **E1+E5** | **`REF5_ENARDEN=1 REF5_ALU_MFOUT=1`（最佳）** | **152.114** | **+13.426** | **971** | **554** | **2** | **换到 ID 段**：`imem DOADO → 操作数 A 选择/副本合并 → id_ex_a_reg[31]_rep__0/D` 6.498ns **L=2** | **5 次，逐位相同** |
| E3 | E1 + `place -directive ExtraTimingOpt` | 143.308 | +13.022 | 863 | 458 | 2 | ALU：`id_ex_b[3] → … → ex_mem_alu_out[10]` 6.857ns L=5 | 2 次，逐位相同 |
| E4 | E1 + `phys_opt_design AggressiveExplore`（前后各一次） | 138.658 | +12.788 | 863 | 458 | 2 | **与 E1 逐位相同 —— phys_opt 又是空转** | 2 次 |
| E5b | E1 + 网表级 `set_property MAX_FANOUT`（64 根网） | 143.308 | +13.022 | 863 | 458 | 2 | **与 E3 逐位相同**；FF 仍 458 ⇒ **属性被接受但一个寄存器都没复制** | 2 次 |
| E1+E5+E3 | E1+E5+ExtraTimingOpt | 125.471 | +12.030 | 970 | 554 | 2 | `imem DOADO → id_ex_b_reg[1]_rep__0/D` 7.889ns L=3 | 2 次（**强负交互**） |
| E5c | E1 + `max_fanout=32`（副本更少） | 146.242 | +13.162 | 948 | 473 | 2 | 又回到 `imem DOADO → pc_reg[25]/CE` 6.560ns L=4 | 2 次 |

> **基线可复现性**：`e1-base-a` / `e1-base-b` / `e1-base-top25` / `e1-final-base-a` /
> `e1-final-base-b` **五次**都是 `WNS 12.714 / 6.760ns / L=4 / 852 LUT / 458 FF / 2 BRAM`，
> 与历史 `v7`、`final` 逐位相同 —— 其中最后两次是**在最终文件状态下、所有开关全关**跑的，
> ⇒ 新增的 `ifdef` 对默认网表**零影响**（A/B 是同一个文件、只差开关，可比）。
> 最佳配置 5 次（`e1-en-amf-a/-b/-c`、`e1-en-amf16-macro`、`e1-en-amf-top25`）全部
> `13.426 / 1029 LUT cell / 554 FF / 同一条路`。

---

## (c) 新版（E1+E5，152.114 MHz）关键路径完整分解

```
Slack (MET) 13.426 ns      Data Path 6.498 ns (logic 2.335 = 35.9% | route 4.163 = 64.1%)
Logic Levels 2 (LUT4=1 LUT6=1)      Source u_imem/rdata_reg/CLKARDCLK  ->  Dest u_core/id_ex_a_reg[31]_rep__0/D

RAMB36_X2Y10  CLKARDCLK -> DOADO[3]        2.125   6.604   imem 输出寄存器 clk-to-out（固定硅延迟）
net (fo=15)                                1.506   8.110   u_core/DOADO[3]
SLICE_X78Y51  LUT6 id_ex_a[31]_i_2         0.105   8.215   操作数 A 的 3:1 选择（AS_PC/AS_ZERO/rs1）的"选择边"
net (fo=97)                                2.657  10.873   u_core/id_ex_a[31]_i_2_n_0   ← 复制副本的 D 侧公共选择项
SLICE_X87Y62  LUT4 id_ex_a[31]_rep__0_i_1  0.105  10.978   复制副本的 D 合并
SLICE_X87Y62  FDCE id_ex_a_reg[31]_rep__0/D
required 24.403  /  arrival 10.978  /  slack 13.426
```

**瓶颈已经三次转移**（这就是本次实验最有价值的一条信息）：

| 阶段 | 限制路径 | 数据延迟 | 端点类型 |
|---|---|---|---|
| V7 基线 | 取指环：`imem DOADO → hit → pipe_stall → 地址 mux` | 6.760 ns | **BRAM 地址脚**（setup −0.490） |
| 只开 E1 | ALU：`id_ex_b[3] → 移位器/结果 mux` | 7.200 ns（route 85%） | 普通 FF |
| **E1+E5** | **ID 段：`imem DOADO → 操作数选择 → id_ex_a`** | **6.498 ns** | **复制后的 FF（D 侧 fo=97）** |

**取指环在最佳配置里已经跌出前 25 条**（第 25 条 slack 13.686 ⇒ 环 < 6.30 ns），
不再是任何意义上的瓶颈。

### E1 对取指环本身做了什么（同一个环，改前 / 改后）

```
[V7]  BRAM CLKARDCLK → DOADO[15] 2.125 → net(fo=41) 1.515
      → LUT6(hit) 0.105 → net 0.510 → LUT6(hit) 0.105 → net 0.497
      → LUT6(6项OR=pipe_stall) 0.105 → net(fo=16) 0.973
      → LUT6(地址 mux) 0.105 → net(fo=2) 0.722 → ADDRARDADDR[11]   (setup −0.490)
      Data Path 6.760ns  L=4   →  Slack 12.714

[E1]  BRAM CLKARDCLK → DOADO[21] 2.125 → net(fo=44) 2.120
      → LUT6(hit) 0.105 → net 0.485 → LUT6(hit) 0.105 → net 0.353
      → LUT6(6项OR=pipe_stall) 0.105 → net(fo=3) 0.395
      → LUT3(!pipe_stall|redirect|!boot_done = imem_rd_en) 0.105 → net 0.480 → ENARDEN  (setup −0.387)
      Data Path 6.379ns  L=4   →  Slack 13.198
```

**省下来的 0.484 ns slack = 0.381 ns（路径本身：最后一跳从 12 根地址脚换成 1 根 CE 脚）
+ 0.103 ns（ENARDEN 的 setup 比 ADDRARDADDR 松）**。
注意：**逻辑级数没变（还是 4 级）** —— 因为 CE 也需要一个 LUT 把 `redirect`/`boot_done`
或进去；E1 的真实收益是**端点变便宜 + 地址脚不再是组合环的一部分**，
所以它的价值主要不在自己这 0.38 ns，而在**把后续优化的天花板打开了**。

### ⚠ 配对正确性（任务点名要求）—— 为什么 `imem_rdata(N) == mem[pc(N)]` 仍然成立

E1 的地址/使能/PC 三条式子（`N` 为周期号）：

```
addr(N-1)  = redirect(N-1) ? T : (boot_done ? pc(N-1)+4 : pc(N-1))
pc(N)      = redirect(N-1) ? T : (fetch_hold ? pc(N-1) : pc(N-1)+4)     // fetch_hold 里的停顿冻结照旧
rd_en(N-1) = !pipe_stall | redirect | !boot_done
```

分四种情况归纳（`rdata(N)` 由边沿 `N-1→N` 装载）：

1. `redirect=1`：`addr=T=pc(N)`，且 `rd_en=1` ⇒ `rdata(N)=mem[T]=mem[pc(N)]` ✔
2. 无 redirect、`boot_done=1`、`!pipe_stall`：`addr=pc(N-1)+4=pc(N)`，`rd_en=1` ✔
3. 无 redirect、`boot_done=1`、`pipe_stall`：`pc(N)=pc(N-1)` 且 `rd_en=0`
   ⇒ `rdata(N)=rdata(N-1)=mem[pc(N-1)]=mem[pc(N)]`（归纳）✔
4. `boot_done=0`：`addr=pc(N-1)=pc(N)`（PC 复位后冻结一拍），`rd_en=1` ⇒ `rdata(N)=mem[pc(N)]` ✔

要点三条：
* **停顿拍 `pc` 仍然冻结**（`pc_next` 里的 `fetch_hold` 一个字没动）。这是配对的必要条件：
  如果让 pc 自由前进而只冻结输出，会**丢掉 4×(停顿拍数) 条指令** —— 这条我明确排除了。
  变化只是"冻结 pc"的终点从 **BRAM 地址脚** 变成了 **pc 这个普通 FF（CE 脚）**。
* 停顿拍地址**确实自由跑**（`addr = pc+4`），但那拍输出被 ENARDEN 冻住，读出什么都不影响；
  解冻那一拍 `addr = pc+4 = 下一拍 pc`，正好接上，所以位序/相位没有偏移。
* `redirect` 必须或进 `rd_en`：否则"停顿+重定向"同拍时输出会被冻住，而 pc 已经跳到 T，
  下一拍 ID 里就是错路指令。`!boot_done` 也必须或进去，否则复位后第一个字可能因
  `pipe_stall` 偶然为 1 而读不进来。
* **逐拍行为与 V7 完全等价**：PC 轨迹、停顿拍数、重定向/冲刷时序、每条指令进 ID 的时刻都一样，
  唯一区别是停顿拍 imem 地址线上的值（被冻结的输出吞掉了）。
  因此这次改动**不需要功能仿真背书也不会改变指令流**（当然，按任务要求没跑仿真）。

---

## (d) 有效：提升了多少、瓶颈转移到哪

* **E1 单独**：137.250 → **138.658 MHz（+1.41 MHz）**。
  它把取指环从 6.760/12.714 改善到 6.379/13.198（**+0.484 ns slack ≈ +2.06 MHz 的环内余量**）。
* **E1 + ALU 扇出（推荐配置）**：137.250 → **152.114 MHz（+14.86 MHz，+10.8%）**。
  5 次逐位相同。代价：Slice LUT 852 → 971（+119）、FF 458 → 554（+96，全是复制副本）、BRAM 不变。
  单独开 E5 也有 **145.751（+8.50 MHz）**，两者**超加性**（1.41 + 8.50 ≪ 14.86）。
* **瓶颈三次转移**：`BRAM 地址脚（取指环）→ 普通 FF（ALU 移位/结果 mux）→ ID 段操作数选择（L=2）`。
  现在**头两名按 slack 只差 0.12 ns**（TOP1 `imem DOADO → id_ex_a` 6.498ns/slack 13.426；
  第二名 `id_ex_rs1_data → pc_reg[30]/D` 6.434ns/**L=8**/slack 13.547，即 JALR/分支目标加法器那条路），
  设计已经**接近"两条路并列"**。
* 天花板提示：当前限制项（6.498）里有 **2.657 ns 是复制副本的 D 侧公共选择网（fo=97）**
  和 1.506 ns 的 imem 输出网。再往下要压，得动 ID 段操作数选择/寄存器堆读的组织方式，
  而不是取指环。**顺带一条负面预警**：`REPORT.md` 建议的 ①"分支/JALR 目标在 ID 预算并寄存"
  会和现在这条 ID 限制路径**抢同一段逻辑**（也要从 imem 输出/imm 出发），
  建议先做扇出/选择树侧，再做 ①。

---

## (e) 负结果（"没用"也是信息）

| 手段 | 结果 | 原因 / 证据 |
|---|---|---|
| **E1 单独只有 +1.41 MHz** | 远小于预期 +5~10 MHz | 取指环确实短了 0.38 ns，但 E1 的布局扰动把 **ALU 那条路从 ≤6.58 ns 顶到 7.200 ns**（基线前 25 条全是取指族、ALU 族不在其中；E1 的 TOP1/TOP2 就是它）⇒ 净收益被吃掉。**这说明"砍掉环里最后一级"本身不等于提速，必须同时看第二名。** |
| E1 的逻辑级数**没减少** | 仍是 4 级 | CE 前还需要一个 LUT3 把 `redirect`/`!boot_done` 或进 `rd_en`；省的是"最后一跳到 BRAM 12 根地址脚"的布线 + setup |
| `phys_opt_design AggressiveExplore`（place 后 + route 后） | **0（与 E1 逐位相同）** | 与 V8 的结论一致；phys_opt 对这类"扇出型"布线问题不动手 |
| **网表级** `set_property MAX_FANOUT`（64 根 `ex_a/ex_b` 网） | **0（与 E3 逐位相同）** | 属性被接受（打印 NETS=64）但 **FF 仍是 458 ⇒ 一个副本都没复制**。**结论：后综合网表属性不触发复制，只有 RTL `(* max_fanout *)` 才有效**（`pipe_stall` 的 fo=16 同理） |
| `place -directive ExtraTimingOpt`（无复制时） | +4.65 MHz（143.308） | 单独配 E1 有用；但**与 E5 复制组合反而 −26.6 MHz**（125.471，TOP1 换到 `id_ex_b_reg[1]_rep__0/D` 7.889ns）⇒ 复制与 ExtraTimingOpt 的布局策略互斥，**不能叠** |
| `max_fanout=32`（副本更少） | 146.242（比 16 差 5.9 MHz） | 副本少 ⇒ ALU 侧扇出治不干净；16 是探到的甜点（只探了 16/32 两点） |

---

## (f) 值不值得移植回主核？

**值得，而且建议分两步、按性价比排：**

1. **先移植 E5（ALU 操作数扇出限制）—— 零功能风险、独立 +8.50 MHz。**
   纯综合属性（`(* max_fanout = 16 *)` 加在 ID/EX 操作数寄存器上），
   不改任何时序语义；ref5 上 Slice LUT +108 / FF +96（0.36% → 0.44%），面积富余。
   主核的 ALU/前递网络比 ref5 宽得多，这类"一根网驱动上百负载"的
   `id_ex_*` 广播线只会更多 —— 预期收益只会更大，**建议在**主核**上先做这个**。
2. **再移植 E1（停顿改用 imem 读使能冻结输出）—— ref5 上再叠加 +6.36 MHz。**
   主核取指结构与 ref5 同源（`imem_addr = pc_next` + 停顿摁住地址），所以 trick 直接适用；
   但移植时必须照抄三条：① **停顿拍 pc 仍要冻结**（否则丢指令）；
   ② `rd_en` 要把 `redirect`（以及任何"必须立刻改地址"的事件，主核还有 BTB 命中/例外）**或进去**；
   ③ 主核 imem 若已有自己的 CE/ENARDEN 语义（多块 RAMB、byte-write、或读口流水），
   要先确认 `ENARDEN` 真的冻结输出寄存器而不是只关地址寄存器。
   **不要和 place 的 ExtraTimingOpt 一起上**（(e) 里的负交互）。

**一句话**：E1 是"对的方向、但单独不值钱"（+1.41 MHz）；它真正的价值是把取指环从地址脚上摘下来，
让设计暴露出一根 115 负载的 ALU 广播网 —— 把网也治了，才拿到 **+14.86 MHz（137.25 → 152.11）**。
两处改动都保留在 `ref5/` 里、都由 env 开关控制，可以按上面 1→2 的顺序在主核上复现。

---

### 附：本次没有做的事（诚实边界）

* 仍**没有功能仿真、没有上板、没有 ILA、没有 commit / 切分支**（任务要求）。
  配对正确性是上面 (c) 的分情况归纳，不是仿真结论；逐拍等价性论证见 (c)。
* 没有扫完 place/route directive 空间（只试了 ExtraTimingOpt 与新 Baseline 的 Default），
  也没有扫 `max_fanout` 的全参数空间（只探了 16 / 32）。
* `ref5/timing.rpt`、`ref5/util.rpt` 仍是 **V7 原件**（已还原）；本次所有证据在
  `ref5/runs/e1-*/`（gitignored）与 `D:\USER\Desktop\FPGA\.ref5_scratch\e1-*.log`。
