# M1 引擎里程碑 — ReLU / ADD 后置 ReLU / IC 上限审查

> 角色：rtl-engine（task-6）。日期：2026-11-03（Asia/Shanghai）。状态：**完成**。
> 写作用域：`nn_conv_engine.sv`、`sim/tb_nn_engine.sv`、本报告。未改其它 RTL/契约/工具；未跑 Vivado。
> 判据（PLAN-V1 §2 M1）：`tb_nn_engine` 新旧 case 全 PASS（mismatch=0）且旧 case 逐位/逐周期不变；
> C128 YOLO E2E `hw_bad=0/auto_bad=0` 且 `npu_cycles` 不变（=1,191,020）。

---

## 0. 结论（TL;DR）

| # | 结论 | 证据 |
|---|---|---|
| 1 | **`ENGINE_TB: PASS (56 cases, mismatch=0)`**：旧 47 个 manifest case + 新增 9 个 M1 case 全 PASS，`Errors=0`，仅剩 1 条与基线相同的端口类型提示 | `.fpga-cache/logs/tb_nn_engine.log` |
| 2 | **旧 47 case 逐位/逐周期完全不变**：旧 case 的 `CASE ... cyc= misA= misB= err= PASS` 行与改动前基线**逐字节相同**（两边 SHA256 同为 `a1cbc91d…`），非法描述符 case 也相同（`err=11, cyc=2`） | 基线 `scratch/m1/baseline_tb_nn_engine.log` vs 最终 `.fpga-cache/logs/tb_nn_engine.log`，§4.1 |
| 3 | **C128 YOLO 112-op E2E 零回退**：`hw_bad=0`、`auto_bad=0`、`npu_cycles=1,191,020`（红线值不变），PASS 84.8s | `.fpga-cache/logs/tb_sw_nn_yolo.log`，§4.3 |
| 4 | 新能力实现：`NN_F_RELU`（conv 的 requant 负支 M_neg=0；ADD/ADD_R 后置 `max(q,zp_d)`）。默认 flags=0 时全部路径逐位等价 | §1/§2 |
| 5 | **前提勘误**：任务书说"`nn_conv_engine.sv:102` 的 `icb_n` 只取 6 bit ⇒ IC 受限"——实测该 wire **是死代码（全文件无引用）**，活跃计数是 16-bit 的 `icb_n_r`。负向对照：**HEAD(未改) 引擎跑 IC=864 的 conv/dw/add/copy 全部 PASS**。因此引擎侧原本就没有 IC 截断，IC 的真实上限只在 `nn_subsys.sv` 的 256 检查（rtl-integ 已放宽到 1023）。仍把死 wire 改成 8-bit 与 ROM 10-bit 字段对齐并注释说明 | §3、§5 |
| 6 | 发现并修复一个**跨 op 状态泄漏**：plain ADD 的 Δ 原为 `(q_s - zp_s_r)`，而 `zp_s_r` 只在 ADD_R 时装载 ⇒ 先跑 ADD_R 再跑 plain ADD 会用上一 op 的 zp_s。改为 Δ= q_s（旧 case 逐位不变；新 case 按 "ADD_R+RELU → plain ADD" 顺序钉死；负向对照旧引擎 mis=2642） | §1 改动 7、§3 |
| 7 | 过程中遇到并已排除的仓库级阻塞（与本任务无关）：`rv32_pkg.sv` 一度被写成 UTF-8 with BOM，`vlog` 报 `rv32_pkg.sv(1:0) unexpected non-printable character 0xef/0xbb/0xbf`，令全 RTL 集编译失败约 3 分钟（`tb_nn_mem` 当时失败）。BOM 已由 owner 清除；最终在**当前仓库状态**下 `tb_nn_engine`（56 cases）与 `tb_nn_mem`（checks=815）均 PASS | §4.4 |

---

## 1. 改动清单（文件 + 行号 + 语义）

### 1.1 依赖（Lead 已落，本任务只引用，不改）

| 文件 | 项 | 值 | 用途 |
|---|---|---|---|
| `nn_pkg.sv` | `NN_F_RELU` | 7（bit7） | 引擎门控新能力 |
| `nn_pkg.sv` | `nn_desc_t.flags` | 7→**8 bit** | 不截断 bit7 |
| `nn_pkg.sv` | `nn_rom_t.flags` | 8 bit（ROM v1） | MODE_AUTO 透传 bit7 |

### 1.2 `nn_conv_engine.sv`（端口/状态数/周期公式均不变）

| # | 行号 | 改动 | 语义 | 默认(flags=0)影响 |
|---|---|---|---|---|
| 1 | 99 | `logic [6:0] d_flags` → `logic [7:0] d_flags` | 描述符 flags 8 位整宽锁存 | 无（低 7 位不变） |
| 2 | 107 | 新增 `logic f_relu` | RELU 模式寄存器（S_IDLE 锁存） | 恒 0 |
| 3 | 622 / 833 | reset 清零 / `f_relu <= desc.flags[NN_F_RELU]` | — | 恒 0 |
| 4 | **1019** | S_QLOAD 的 M_neg 三态：`mneg_q[l] <= f_relu ? 0 : (leaky_q ? (M_pos*3277+16384)>>15 : M_pos)` | **ReLU 模式**：负 acc ⇒ `y=(acc*0)>>SHIFT=0` ⇒ `out=clamp(0+zp_out)=zp_out`（int8 域下界是 zp_out，不是数值 0）；`RELU` 与 `LEAKY` 同时置位时 **RELU 优先** | 与 v0.7 三态完全相同 |
| 5 | **440** | `ad_pack2` 加 `if (f_relu && ($signed(bb) < zp_d_r)) bb = zp_d_r;` | **ADD/ADD_R 后置 ReLU**：`out = max(q_out, zp_d)`（先饱和后取 max，等价） | 分支不生效，逐位不变 |
| 6 | 971 / **1363** | `S_CPREP` 的 add 入口条件 `f_add_r` → `(f_add_r \|\| f_relu)`；S_AD_R2 的 Q 装载条件同步，且非 ADD_R 时**只装 `zp_d_r`**（不装 zp_s/R/KADD） | ADD+RELU 需要 Q 块的 `byte[1]=zp_d` 作下界；plain ADD 的 `Δ=q_s` 语义不受影响 | 旧 ADD 不进 S_AD_Q，完全不变 |
| 7 | **1385–1390** | `ad_qq[l] <= {qs[7], qs};`（原 `(qs - zp_s_r)`） | **plain ADD 的 Δ 显式取 q_s**，消除对"上一个 op 的 zp_s_r"的依赖（跨 op 状态泄漏修复）；ADD_R 路径仍走 `ad_mul`，公式不变 | 旧 case 里 `zp_s_r` 恒 0 ⇒ 与 v0.7 逐位相同 |
| 8 | 113–126 | `icb_n = {8'd0, ic8[8:3]}`（6 bit 有效）→ `{8'd0, ic8[10:3]}`（8 bit，覆盖 IC≤1024），并加注释说明它**当前无引用** | 与 `nn_rom_t.ic`(10-bit) / `nn_subsys` 1023 上限对齐；防止将来误用 | 对 IC≤256（ic8≤511）数值与旧式相同 ⇒ 无影响 |

> 行号对应交付版本；`git diff nn_conv_engine.sv` 可复核。
> 备注：ADD+RELU 比 plain ADD 多 1 拍（S_AD_Q 读 Q 块）；这是唯一的新增周期，只作用于显式置 RELU 的 ADD op（实测 218→219、88→89，见 §4.2）。

### 1.3 `sim/tb_nn_engine.sv`

| 行号 | 改动 |
|---|---|
| 279 / 587 | `desc.flags = flags[6:0]` → `flags[7:0]`（旧 manifest 路径的 flags 输入也支持 bit7） |
| 67–80 | `u_mem` 显式 tie-off `nn_mem` 新增 M2 流式端口（`w_mode=0, w_bank_sel=0, wfill_*=0, q_bank_sel=0, qfill_*=0`）：保持 v0.7 ROM 路径语义，同时消除 10 条 unconnected-port 警告 |
| 319–736 | **M1 自检基础设施**（新段）：`m1_h8`（固定公式 int8 伪随机）、`m1_wr_words`/`m1_cmp_words`（A/B 写读比较）、`m1_load_w`/`m1_load_q_conv`/`m1_load_q_add`（W/Q 装载）、`m1_golden_conv`（整数金标）、`m1_run_conv`/`m1_run_add`/`m1_run_copy` |
| 839–869 | 9 个新 case 的调用（见 §3） |
| 878–891 | 汇总新增 `M1SUMMARY`，PASS 判据加入 `m1_npass==m1_ncase`；总 case 数 47→56 |

> 旧 47 case 仍**完全走原 manifest/向量文件路径**，新 case 的向量与期望全部由 TB 内整数金标现场生成（种子固定，不落文件），两条路径互不影响 —— 这是"旧 case 逐位不变"能机器核对的结构保证。

---

## 2. 新 flags 语义（`NN_F_RELU = bit7`）

| op | `flags.LEAKY=0` | `flags.LEAKY=1` | `flags.RELU=1`（**优先于 LEAKY**） |
|---|---|---|---|
| CONV/DWCONV requant | `M_neg = M_pos`（linear） | `M_neg = (M_pos*3277+16384)>>15` | `M_neg = 0` ⇒ 负 acc 输出 = `zp_out`（int8 域 ReLU） |
| ADD（plain） | `out = clamp(q_d + q_s)` | 无效（LEAKY 只对 conv 生效） | `out = max(clamp(q_d+q_s), zp_d)`；需 Q 块 `byte[1]=zp_d`，**多 1 拍** |
| ADD_R | `out = clamp(q_d + ((q_s-zp_s)*R>>KADD))` | 无效 | 上式再 `max(·, zp_d)`；Q 块 `[0]=zp_s [1]=zp_d [2:3]=R [4]=KADD` |
| POOL / COPY / UP2X | 忽略 RELU/LEAKY 位（无行为变化） | 同左 | 同左 |

**约束/注意**
1. `zp_d` = 该 ADD op 目标张量的 zero-point，取 Q 块 **byte[1]**（CONTRACT §12.3 已有该字节；原文注明"仅 debug/记录，公式不加"，现在 **RELU=1 时作为输出下界参与运算**，契约文字需 Lead 更新，见 §6）。
2. ADD+RELU 的 Q 块必须存在且 `qoff` 8 字节对齐（引擎在 S_AD_Q 读一次 64b 字）；plain ADD（无 RELU/ADD_R）仍不需要 Q 块。
3. 数值边界：`max(clamp(y+zp_out,-128,127), zp_d)` 与先 max 后 clamp 等价（`zp_d∈[-128,127]`）。
4. 与 `LEAKY` 同时置位时 RELU 优先（`nn_pkg.sv:74-75` 注释语义）；`nn_gen_rom.py` 在 RELU 时已清除 LEAKY 位（Lead 2026-11-03 落地）。
5. 引擎**不改端口**：ReLU 只由 `desc.flags[7]` 触发，MODE_CPU/MODE_AUTO 同源。

---

## 3. TB 新增 case（自产生向量 + SV 整数金标）

金标口径 = CONTRACT §5/§6/§8/§12.3，与 `results/ai-accel/proto/engine/gen_vectors.py` 同一套整数运算：
`acc=bias+Σa·w`(int32) → `M_neg`（三态）→ `y=(acc·M)>>SHIFT`(int64, floor) → `q=clamp(y+zp_out)`；
ADD：`q=clamp(q_d+Δ)`，`Δ=q_s`（plain）或 `(q_s-zp_s)*R>>KADD`（ADD_R），RELU 再 `max(q,zp_d)`。

| # | case | op | flags | shape (ih×iw×ic→oc) | k/s/p | 判据 | 实测 cyc | 结果 |
|---|---|---|---|---|---|---|---|---|
| 1 | `m1_relu_conv` | conv | `0x80` RELU | 9×10×8→8 | 3/1/1 | 整数金标逐字节 + **输出全部 ≥ zp_out=7** + 负 acc 命中 361 次 | 2,377 | PASS |
| 2 | `m1_relu_prio` | conv | `0x82` RELU+LEAKY | 5×5×8→8 | 1/1/0 | 证明 **RELU 优先**（金标按 M_neg=0；LEAKY 尾字节=1），负 acc 命中 124 | 219 | PASS |
| 3 | `m1_ic864_conv1x1` | conv | `0x00` | 8×8×**864**→144 | 1/1/0 | 大 IC dense 金标（W=124,416B，IC8/8=108 > 63） | 134,009 | PASS |
| 4 | `m1_ic864_dw3x3` | dwconv | `0x01` DW | 6×6×**864**→864 | 3/1/1 | 大 IC depthwise 金标（icb=108；A 96KB 内双张量） | 45,260 | PASS |
| 5 | `m1_add_relu_mix` | add | `0x80` RELU | 6×7×8 | — | 金标 `max(clamp(qd+qs),zp_d)`，RELU 截断命中 185/336 | 219 | PASS |
| 6 | `m1_add_relu_allneg` | add | `0x80` RELU | 4×4×8 | — | **全负输入**：判据 = 100% 输出 == zp_d（128/128） | 89 | PASS |
| 7 | `m1_addr_relu` | add | `0xC0` ADD_R+RELU | 6×6×8 | — | `clamp(qd+((qs-zp_s)*R>>KADD))` 再 max(zp_d)，R=32768/KADD=15/zp_s=-10/zp_d=5；RELU 命中 139/288 | 189 | PASS |
| 8 | `m1_add_ic864` | add | `0x00` | 2×2×**864** | — | 大 IC add（同时验证 §1.2 改动 7：本 case 紧跟在 `m1_addr_relu` 之后） | 2,168 | PASS |
| 9 | `m1_copy_ic864` | copy | `0x00` | 1×1×**864**→864 | — | 大 IC copy（icb=108） | 224 | PASS |

**负向对照（证明新 case 有牙齿）**：用 `git show HEAD:nn_conv_engine.sv`（M1 前的 v0.7 引擎）编译**同一份新 TB**：

| case | v0.7 引擎结果 | 说明 |
|---|---|---|
| m1_relu_conv | **FAIL** mis=361, below=361 | 旧引擎无 ReLU ⇒ 负 acc 输出 < zp_out（below=361 恰等于 RELU 应命中数） |
| m1_relu_prio | **FAIL** mis=124 | 同上（旧引擎只做 linear） |
| m1_ic864_conv1x1 | **PASS** | **证明引擎原本没有 IC 截断**（前提勘误，见 §5） |
| m1_ic864_dw3x3 | **PASS** | 同上 |
| m1_add_relu_mix | **FAIL** mis=185 | 旧引擎 bit7 被截断，不做后置 ReLU |
| m1_add_relu_allneg | **FAIL** mis=128 | 同上 |
| m1_addr_relu | **FAIL** mis=139 | 同上（ADD_R 数值正确、缺后置 ReLU） |
| m1_add_ic864 | **FAIL** mis=2642 | 旧引擎 plain ADD 用了上一 op（m1_addr_relu）残留的 zp_s ⇒ 跨 op 泄漏被测出 |
| m1_copy_ic864 | **PASS** | 与 IC 无截断一致 |
| **合计** | **3/9 PASS**（旧引擎）/ **9/9 PASS**（新引擎） | |

---

## 4. 回归证据

### 4.1 `tb_nn_engine`（机器判据：`ENGINE_TB: PASS`）

- 命令：`python tools/fpga_workflow.py verify --only tb_nn_engine --force`（当前仓库状态复跑两次）
- 结果：`PASS tb_nn_engine 4.6~4.9s rc=0`；日志 `.fpga-cache/logs/tb_nn_engine.log`
  - `# SUMMARY cases=47 pass=47 fail=0 total_mismatch=0`
  - `# M1SUMMARY cases=9 pass=9 fail=0 mismatch=0`
  - `# ENGINE_TB: PASS (56 cases, mismatch=0)`
  - `# Errors: 0, Warnings: 1` —— 唯一警告是 `nn_conv_engine.sv:53` 的 `desc` port-kind 提示，
    **与改动前基线完全相同**（非新增；此前 `nn_mem` 新增 M2 流式口带来的 10 条 unconnected-port 警告已在 TB 里用显式 tie-off 消除）
- **旧 case 逐 case 周期/mismatch 不变**：把改动前基线日志与最终日志里的 `# CASE ...` 行做集合比较：
  - 基线 47 行、最终 47 行，`Compare-Object` 为空；
  - 两边 47 行拼接后的 SHA256 **完全相同**：`a1cbc91d0b3b538c87f5cbc55a6a230896d23ab01f929550a518acc7aeabcad8`；
  - 非法描述符 case 也相同：`# ERRCASE invalid-desc : PASS (err=11, cyc=2)`。
- 任务描述里的 "46+4" 按现 TB 实况核对为：**47 个 manifest case**（`gen_vectors.py` 生成 46 个 + `replay_l0_conv0` 1 个，即 conv/dw 29、pool 9、copy/ups 5、add 4）+ **1 个非法描述符 case** → 48 个判定点全部一致。
- 旧 case 全表（实测 cyc，与基线逐字节相同）：

| case | cyc | case | cyc | case | cyc |
|---|---|---|---|---|---|
| conv1x1_s1 | 659 | conv3x3_i13o13 | 3849 | pool5_s1p2 | 1704 |
| conv1x1_s1_i3o5 | 259 | conv5x5_s1p2 | 2656 | pool9_s1p4 | 6104 |
| conv1x1_s2 | 259 | conv5x5_s2p2 | 2315 | pool9_c13 | 10168 |
| conv1x1_oc24 | 1356 | conv5x5_i16o16 | 4529 | pool2_s2_c24 | 620 |
| conv1x1_i13o13 | 367 | conv1x1_bigM | 219 | pool3_srcB | 400 |
| conv3x3_s1p1 | 2377 | conv1x1_mixM | 259 | copy | 92 |
| conv3x3_s1p0 | 674 | conv3x3_shift10 | 936 | copy_c16 | 128 |
| conv3x3_s2p1 | 1089 | conv1x1_srcoff8 | 219 | copy_oc16 | 48 |
| conv3x3_s2p0 | 1424 | conv1x1_srcB | 259 | ups2x | 108 |
| dw3x3_c8 | 1243 | conv3x3_srcB | 1931 | ups2x_c16 | 208 |
| dw3x3_c16 | 1118 | conv1x1_bigbias | 219 | add | 218 |
| dw3x3_c24 | 1265 | dw3x3_c13 | 710 | add_c24 | 383 |
| dw3x3_s2 | 553 | dw5x5_c8 | 1081 | add_srcB | 188 |
| dw5x5_c16 | 3806 | dw5x5_s2 | 1090 | add_same_buf | 308 |
| pool2_s2p0 | 212 | pool2_s2p1 | 263 | replay_l0_conv0 | 130067 |
| pool3_s1p1 | 792 | pool3_s2p1 | 470 | | |

### 4.2 周期代价（只在新模式）

| 对比 | v0.7 引擎 | M1 引擎 | 差 |
|---|---|---|---|
| plain ADD（6×7×8）`add` 型 | 218 | （旧 case）218 | 0 |
| ADD+RELU（6×7×8，`m1_add_relu_mix`） | 218（按同 shape 旧 add） | 219 | **+1 拍**（S_AD_Q 读 zp_d） |
| ADD+RELU 全负（4×4×8） | 88 | 89 | +1 拍 |
| ADD_R+RELU | 189 | 189 | 0（本来就经 S_AD_Q） |
| relu conv（3×3, 9×10×8） | 2377 | 2377 | 0（只改 M_neg 值） |

### 4.3 C128 YOLO-112 E2E（红线段）

- 命令：`python tools/fpga_workflow.py verify --only tb_sw_nn_yolo --force`；结果 `PASS tb_sw_nn_yolo 84.8s`（最终复跑；此前两次 83.7s / 87.8s 亦 PASS）。
- 日志 `.fpga-cache/logs/tb_sw_nn_yolo.log` 关键行：
  - `# [yolo] hw_bad=0 hw_cycles=10469260 npu_cycles=1191020`
  - `# [yolo] auto_bad=0 auto_cycles=1191620 auto_npu_cycles=1191020`
  - `# [yolo] RESULT : PASS`
- **`npu_cycles=1,191,020` 与红线值完全一致**（hw/auto 两种模式一致），无回退。
- 说明：YOLO 计划里没有置 `NN_F_RELU` 的 op，所以本改动对它是纯旁路（旧行为逐位不变）。

### 4.4 `tb_nn_mem`（旁证）

- 最终（当前仓库状态）命令 `python tools/fpga_workflow.py verify --only tb_nn_mem --force` ⇒ `PASS tb_nn_mem 3.3s`；
  日志 `.fpga-cache/logs/tb_nn_mem.log` 末段：
  - `# [MEM_TB] SUMMARY_LEGACY(ROM)=42 + STREAM(w_mode=1)=773`
  - `# MEM_TB: PASS (checks=815, mismatch=0, xerr=0)`
  - 说明：该 TB 属于 rtl-mem 的 M2 写作用域，此处只作"本引擎改动没有破坏 nn_mem 子系统"的旁证；
    M2 的判据以 rtl-mem 的 `M2-NNMEM.md` 为准。
- 过程记录：M1 改动期间 `rv32_pkg.sv` 一度被写成 UTF-8 with BOM（全仓唯一带 BOM 的 `.sv`），
  `vlog` 报 `rv32_pkg.sv(1:0): Syntax error, unexpected non-printable character with the hex value '0xef'`（后随 0xbb/0xbf），
  并级联 80+ 条 `Could not find the package (rv32_pkg)` ⇒ 当时 `tb_nn_mem` 0.3s 编译失败。
  BOM 随后被 owner 清除（当前文件首字节 `0x60 0x74 0x69` = "`ti"），上述最终 PASS 即修复后的结果。
  **建议**：工作流加一条 BOM 检查（`vlog` 对 BOM 是硬错误，且级联报错很像 RTL 问题）。

---

## 5. 截断审查（全文，回应任务 3）

| 信号 | 位宽 | 物理/契约上界 | 结论 |
|---|---|---|---|
| `icb_n`（`ic8[8:3]`，原 6b 有效） | 16b 声明 | — | **死代码**（全文件 grep 只有声明与注释，无引用）；已改 `ic8[10:3]`（8b，IC≤1024）仅作对齐/防误用 |
| `icb_n_r`（**活跃**计数，`ic8_r>>3`） | 16b | ic8≤1024 ⇒ ≤128 | **无需改**；负向对照证明 IC=864 在原引擎已工作 |
| `c_icb`/`c_cb` 通道块计数 | 16b | ≤128 | OK |
| `oc_limit_r`（OC tile 数） | 16b | dense (oc8+15)/16 ≤64；其它 oc8/8 ≤128 | OK |
| `c_ocb` / `rem_ch` / `oc_base_w` / `act_l` | 16b | OC_pad≤1024 | OK |
| `p1 = ic8*oc8`；`p1_2/3/4` | 24b | k=1 时受 W 320KB 约束 ic8*oc8≤327,680；p1_4≤1.31M | OK（24b 上限 16.7M） |
| `w_sub`/`w_dgrp`/`w_p2` 及 24-bit 模运算 | 24b | 负偏移靠 2^24 回绕 | OK（IC=864 dwconv 实测通过） |
| `d_woff[23:0]` | 24b 截断自 32b | W 区 ≤320KB | OK |
| `w_addr[23:0]` | 24b | 320KB 窗口；M2 双银行内偏移 ≤163,840（18b）；ROM-v1 单层 `wlen≤128KiB` ⇒ 124,416B 的大层刚好在界内 | **不需要改位宽**；M2/M3 只改 woff 语义（银行内偏移），不动端口 |
| `q_addr[12:0]`（64b 字索引） | 13b | Q 48KB=6,144 字；64KB 地址空间 | OK |
| `q_bias_w/q_mpos_w/q_tail_w` | 13b | OC_pad=1024 时层 Q=6,160B ⇒ tail 字索引 (qoff+6*oc8)/8 ≤ 6,142 < 8,192 | OK |
| `q_iss`/`q_tot_r` | 5b | 逐 16-lane tile 装载 ⇒ q_tot ≤13 | OK |
| `a_addr`/`b_addr` | 24b | 片上窗口 512KB；未来 4MB DDR3 arena 需要 22b `src/dst`（ROM v1 已把 `nn_rom_t.src/dst` 改 22b，由 M4/M5 处理窗口语义） | M1 无影响；**后续里程碑依赖** |
| `row_step_a`/`oy_step_a`/`ox_step_a`/`band_*` | 24b | 片上 A ≤96KB | OK |
| `ih/iw/oh/ow`、`ks/st/pad` | 16b / 4b / 2b / 3b | 片上单张量限制 | OK |
| Q 区容量 vs M2 影子银行 | — | 单层 Q 6*OC_pad+16；OC=864 ⇒ 5,200B ≤ 8KiB 影子银行 ✓ | OK（M2 的 8KiB 设计对瓶盖模型最大通道够用） |

> 结论：**引擎侧没有需要为"IC=864/OC=864"再改的位宽**；任务书点名的 `icb_n` 是死代码。真正需要放宽的是 `nn_subsys` 的 256 检查（rtl-integ 已改为 1023，见 `nn_subsys.sv:272-273`）与未来 4MB arena 的 `src/dst` 语义（M4/M5）。

---

## 6. 需要的 `nn_pkg` / 集成支持清单（给 Lead）

1. **已就绪（Lead/rtl-integ 已落，本任务已用上）**：`NN_F_RELU=7`；`nn_desc_t.flags` 8b；`nn_rom_t.flags` 8b；`nn_subsys.sv` 描述符检查 `ic>1023 / oc>1023`（`:272-273`）。
2. **契约文字待更新（Lead 拥有 CONTRACT.md）**：
   - §4 flags 位表补 bit7 `RELU` 语义（conv：M_neg=0、下界 zp_out；ADD/ADD_R：`max(out, zp_d)`；与 LEAKY 互斥且优先）。
   - §12.3 ADD_R Q 块注释 "byte[1]=zp_d 仅 debug/记录；公式不加" → 追加："`flags.RELU=1` 时作为输出下界参与 `max()`"。
   - §11 支持范围补 "ADD 后置 ReLU" 一行（含 plain ADD 与 ADD_R 两种路径）。
3. **converter / 工具链（task-4/task-5，converter 需知）**：
   - conv/dwconv 层 `act='relu'` ⇒ plan flags 置 bit7 且清 bit1（Lead 已在 `nn_gen_rom.py` 做映射）；**不能留 LEAKY 位**（引擎虽 RELU 优先，但工具链口径应干净）。
   - 残差块 `out = relu(x + conv2(...))` ⇒ add op 置 `ADD_R|RELU`，Q 块 16B：`[0]=zp_s, [1]=zp_d, [2:3]=R(u16 LE), [4]=KADD`，`qoff` 8B 对齐；若用 plain ADD+RELU 则必须提供 Q 块（`[1]=zp_d`）。
   - 注意 `zp_d` 是**目标张量**的 zero-point（ADD_R 时公式本身不加 zp_d，只作 RELU 下界）。
   - 注意单层 Q ≤ 8KiB（M2 影子银行）/ Q 区 48KB（扁平模式）：OC=864 层 Q=5,200B，最大支持 OC=1024 ⇒ 6,160B。
   - 注意 ROM-v1 `wlen≤128KiB` 约束：瓶盖模型最大权重层 124,416B（IC=864/OC=144 1×1）刚好在界内；更大的 dense 层需要 tiling/M4。
4. **TB 依赖 M2 端口名**：`sim/tb_nn_engine.sv` 显式 tie-off `nn_mem` 的 9 个 M2 流式口（`w_mode/w_bank_sel/wfill_*/q_bank_sel/qfill_*`）。若 M2 最终改名，请 rtl-mem 同步本 TB 的实例化（或告知我改；本任务已按 task-7 端口表落地）。
5. **仓库级提醒**：`rv32_pkg.sv` 曾带 UTF-8 BOM（见 §4.4），令 `vlog` 全仓级联报错；BOM 已清除（当前首字节 `0x60 0x74 0x69`）。建议在 `tools/fpga_workflow.py` 的 check 里加一条"仓库内 `.sv/.tcl/.bat` 不得以 UTF-8 BOM 开头"的检查（`vlog` 对 BOM 是硬错误，且报错形态很像 RTL bug）。

---

## 7. 证据文件与复跑命令

| 证据 | 路径 |
|---|---|
| 最终 `tb_nn_engine` 日志（56 cases PASS） | `.fpga-cache/logs/tb_nn_engine.log`（副本 `D:\USER\Desktop\FPGA\scratch\m1\wf_tb_nn_engine_final.log`） |
| 改动前基线日志（47 cases 行 SHA256 对比基准） | `D:\USER\Desktop\FPGA\scratch\m1\baseline_tb_nn_engine.log`（原 `.fpga-cache/logs/tb_nn_engine.log` 于 23:16:46 抓取） |
| 最终 YOLO E2E 日志 | `.fpga-cache/logs/tb_sw_nn_yolo.log`（副本 `…\scratch\m1\wf_tb_sw_nn_yolo_final.log`） |
| 负向对照（v0.7 引擎 + 新 TB） | `D:\USER\Desktop\FPGA\scratch\m1\neg\neg.log`（`M1SUMMARY cases=9 pass=3 fail=6`） |
| 引擎 diff | `git diff nn_conv_engine.sv` |

复跑命令（ModelSim SE-64 2020.4，统一工作流）：

```bat
python tools\fpga_workflow.py verify --only tb_nn_engine --force
python tools\fpga_workflow.py verify --only tb_sw_nn_yolo --force
```

迭代期使用的直接 ModelSim 命令（在 `D:\USER\Desktop\FPGA\scratch\m1`，独立 work 库，避免与工作流共享库冲突；工具路径同 `tools/fpga_workflow.py` 的 `MSIM`）：

```bat
set LM_LICENSE_FILE=D:/software/tools/Modelsim/win64/LICENSE.TXT
D:/software/tools/Modelsim/win64/vlib.exe work
D:/software/tools/Modelsim/win64/vlog.exe -sv nn_pkg.sv nn_mem.sv nn_conv_engine.sv sim/tb_nn_engine.sv
D:/software/tools/Modelsim/win64/vsim.exe -c -do "run -all; quit -f" work.tb_nn_engine ^
    "+vec=<repo>/results/ai-accel/proto/engine/vec"
```

> 未跑 Vivado（按任务纪律）。全量 `verify --force` PASS 数由 M2/M6 阶段复核（本任务只对 tb_nn_engine / tb_sw_nn_yolo 负责）。
