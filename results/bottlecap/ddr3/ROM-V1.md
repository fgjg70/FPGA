# 微码 ROM 表格式 v1（草案）+ 地址位宽与代价核算

> 作者：`ddr3-feas`。日期：2026-11-03。任务：task-2 交付物。
> 目的：给"2.05M 参数模型 + DDR3 流式"的微码 ROM 一个**可直接实现的字段表**，并算出位宽/深度/BRAM 代价。
> 纪律：**本文只是草案**，未改 `nn_pkg.sv` / `nn_rom_pkg.sv` / `tools/nn_gen_rom.py`。

---

## 0. 结论摘要

| 问题 | 结论 | 关键数字 |
|---|---|---|
| ROM 深度 128 够吗？ | **够**。本模型 NPU op = **105**（103 原语 + 2 copy），余 23 项 | `bandwidth_budget.json.main.npu_ops = 105` |
| Lead 说的"约 150 op > 128"成立吗？ | **不成立**（按原语口径 105）。**只有**在不改 `nn_subsys` 的 `ic/oc>256` 检查、被迫按 248 通道切分时才变 **213** | `nn_subsys.sv:252-253`；`nn_pkg.sv:117-118`（ic/oc 10 bit）；`nn_conv_engine.sv:83,182`（16 bit） |
| src/dst 要多少位？ | **22 bit**（建议）/ **21 bit（P3 口径）也够但擦边**：arena 峰值 **1,806,336 B**，2^21 = 2,097,152 B ⇒ 余量仅 1.16× | arena 见 `DDR3-FEASIBILITY §4.2` |
| woff 要多少位？ | **17 bit**（层内相对，≤131,072 ≥ 最大层 124,416）；若存扁平 2.02MB 权重镜像则 **21 bit** | 最大层权重 124,416 B |
| qoff 要多少位？ | **13 bit**（层内相对 ≤8,192 ≥ 最大层 Q 5,200） | Q 单层 6×864+16 = 5,200 B |
| ROM 宽度？ | **v1 = 236~240 bit**（现有 200 bit），深度 128 ⇒ **30 Kb**；若走 LUTROM（现状实现）约 **+70 LUT**，若落 BRAM 则 **1 BRAM36** | `nn_pkg.sv:129`（现 200 bit）；`nn_rom_pkg.sv:10-12` |
| 需要改引擎吗？ | **不需要**（ROM 只是喂 `nn_desc_t`；引擎字段已够）。需要改的是 `nn_subsys`（上限检查）与 `nn_seq`（预取/银行） | — |
| ReLU 怎么表达？ | **必须新增 1 个 flags 位**（`NN_F_RELU` → 负支输出 0）；现有 leaky/linear 两种模式无法表达 ReLU | `model.py:8-30`；`CONTRACT §5` |

---

## 1. 现状盘点

| 项 | 现状 | 证据 |
|---|---|---|
| ROM 深度 | `NN_ROM_DEPTH = 128` | `nn_pkg.sv:103` |
| ROM 条目结构 | `nn_rom_t` = **200 bit**（kind 4 + flags 7 + ks 4 + pad 3 + stride 2 + ic 10 + oc 10 + ih 9 + iw 9 + src 19 + dst 19 + woff 19 + qoff 16 + aux0 16 + aux1 16 + csum 32 + rsvd 5） | `nn_pkg.sv:111-129` |
| 实现方式 | `localparam nn_rom_t NN_ROM [0:NN_ROM_DEPTH-1]` 常量数组（综合成 LUTROM/LUTRAM，**不占 BRAM**） | `nn_rom_pkg.sv:12`；`SPEC-SPECIALIZED.md §1`（"~1.7KB LUTRAM, 108 entries"） |
| 现有条目数 | `NN_ROM_LEN = 112` | `nn_rom_pkg.sv:10` |
| 描述符 | `nn_desc_t` 32-bit 字段（src/dst/woff/qoff 都是 32 bit）→ **ROM 加宽不触碰引擎接口** | `nn_pkg.sv:78-92` |
| 引擎实际容量 | `d_ic/d_oc` 16 bit；循环计数器 16 bit；`nn_rom_t.ic/oc` 10 bit（≤1023） | `nn_conv_engine.sv:83,182`；`nn_pkg.sv:117-118` |
| **子系统合法性检查** | `if (desc_next.ic == 0 || desc_next.ic > 256) desc_ok = 0;`（oc 同）→ 超限 err=0xE1 | **`nn_subsys.sv:252-253`** |
| ROM→desc 映射 | `nn_rom_to_desc()` 逐字段赋值 | `nn_pkg.sv:134-150` |

---

## 2. 新模型 op 数核算（决定深度）

| 口径 | op 数 | 说明 |
|---|---:|---|
| 原语（conv/dw/add/copy/upsample） | **103** | conv 61 + dwconv 17 + add 20 + upsample 5（pool 0） |
| + concat 的 2 次 copy | **105** | 216ch = 3×72；p2 原位，另 2 路 up 结果 copy 进去 |
| （若按 248 通道切分） | **213** | 33 层 ic 或 oc >256（最大 864）触发切分 |
| （若把每层 tile/band 也编进 ROM） | 1,325 | **不可行**（P3 已否决：tile 摊平 1,854 > 128，见 `P3-320-ARENA §4`） |

**⇒ 深度结论**：
- **路线 A（推荐）**：改 `nn_subsys.sv:252-253` 两行（256→1024），op 数保持 **105**，**深度 128 不变**，ROM 零深度代价。
- **路线 B（保守）**：不动检查，切分到 213 op ⇒ 深度 **256**（`NN_ROM_DEPTH` 改）⇒ 宽度 240×256 = 61,440 bit = 60Kb ⇒ **2 BRAM36** 或 LUTROM 约 +1,300 LUT（现整机 LUT 余量 26,415，可承受但浪费）。
- **推荐 A**：改 2 行 + 保持 128；同时把 tile 循环（band/OC 块）留给引擎内部计数器（与 P3 一致）。

---

## 3. 地址位宽核算（决定 src/dst/woff/qoff 宽度）

### 3.1 arena（src/dst）

| 口径 | 字节 | 需要的位宽 | 余量 |
|---|---:|---|---|
| 本模型生命周期峰值 arena（实测打包） | **1,806,336 B（1.72 MB）** | 21 bit（2,097,152） | **1.16×**（擦边） |
| 建议窗口（含 band 双缓冲/对齐/未来扩展） | 4 MB | **22 bit**（4,194,304） | 2.3× |
| 唯一张量总和（不复用） | 15,212,344 B | 24 bit | 不采用（浪费） |

**建议**：src/dst = **22 bit + 硬件 arena 基址寄存器**（基址 0x0100_0000，与 P3 一致，`P3-ARENA §0`）。P3 的 21-bit 决定在数据上"刚好够"，但只剩 16% 余量，任何 band 双缓冲/对齐补洞都会爆；**22 bit 只多 3 bit/字段，128 项多 96 B，代价可忽略**。

### 3.2 权重（woff）

| 方案 | 宽度 | 说明 |
|---|---|---|
| **层内相对偏移（推荐）** | **17 bit**（131,072） | 最大层 124,416 B；硬件 `w_addr = bank_base + woff + 层内偏移`。预取时整层搬到银行基址，所以层内偏移从 0 开始 |
| 扁平镜像绝对偏移 | 21 bit（2,020,960 B） | 需要硬件维护"当前层基址"并做减/加；不推荐 |
| P3 原口径 | 19 bit（320KB） | 对 2.02MB 不够 |

### 3.3 Q（qoff）

| 方案 | 宽度 | 说明 |
|---|---|---|
| **层内相对（推荐）** | **13 bit**（8,192） | 最大层 Q = 6×864+16 = 5,200 B；Q 随层流式到 2×8KB 影子缓冲 |
| 扁平 Q 镜像 | 17 bit（90,048 B） | 若 Q 整体常驻（需 22 tiles，不推荐） |

---

## 4. `nn_rom_t` v1 字段表（草案）

| 字段 | 位宽 | 语义 | 相对现版变化 |
|---|---:|---|---|
| `kind` | 4 | 0=conv 1=dwconv 2=pool 3=up2x 4=add 5=copy；6/7 预留（barrier/load） | 不变 |
| `flags` | **8** | bit0 DEPTHWISE，bit1 LEAKY，bit2 ADD，bit3 UP2X，bit4 POOLMAX，bit5 PACKED3，bit6 ADD_R，**bit7 RELU（新）** | **7→8（+1）** |
| `ks` | 4 | 卷积核 1/3/5；pool 核 2/3/5/9 | 不变 |
| `pad` | 3 | 0..4 | 不变 |
| `stride` | 2 | 1/2 | 不变 |
| `ic` | 10 | 真实输入通道（≤1023；本模型 864 ✓） | 不变 |
| `oc` | 10 | 真实输出通道 | 不变 |
| `ih` | 9 | 输入高（≤511；本模型 224 ✓） | 不变 |
| `iw` | 9 | 输入宽 | 不变 |
| **`src`** | **22** | DDR3 arena 内字节偏移 | **19→22（+3）** |
| **`dst`** | **22** | 同上 | **19→22（+3）** |
| **`woff`** | **17** | 权重银行内层内偏移（16B 对齐） | **19→17（−2）** 语义改为层内相对 |
| **`qoff`** | **13** | Q 影子缓冲内偏移（8B 对齐） | **16→13（−3）** 语义改为层内相对 |
| **`wlen`** | **18** | 本层权重字节数（预取用，≤262,144；最大 124,416） | **新增（+18）** |
| **`qlen`** | **13** | 本层 Q 字节数（≤8,192） | **新增（+13）** |
| **`tile`** | **8** | tile 控制：`band_rows[3:0]`（1..16 输出行/带）+ `oc_tile_hint[1:0]` + `last_band_pad[1:0]` 或无 | **新增（+8）** |
| `aux0` | 16 | add：R；copy：源通道偏移 | 不变 |
| `aux1` | 16 | add：KADD | 不变 |
| `csum` | 32 | golden FNV（debug 模式逐 op 比对；demo 模式可置 0/裁掉） | 不变 |
| `rsvd` | 6 | 对齐到 240 | — |
| **合计** | **240 bit** | 4+8+4+3+2+10+10+9+9+22+22+17+13+18+13+8+16+16+32+6 = 240 | **+40 bit** |

> 可裁剪版（若 LUT 紧张）：去掉 `csum` 32 bit → **208 bit**；demo 模式不需要逐 op FNV（`SPEC §4`："demo 模式关闭 checksum"）。

---

## 5. ReLU 模式（必须新增，否则逐层数值全错）

| 事实 | 证据 |
|---|---|
| 模型激活是 `nn.ReLU`（负半轴=0），不是 leaky | `tools/bottlecap/model_src/nut_detector/model.py:8-30`（`ConvBNReLU` = conv→BN→**ReLU**）；`enhanced_anchor_free.py:17-27`（`ResidualConvBlock` 末尾 `F.relu`） |
| 现引擎只支持 leaky（`M_neg=(M_pos*3277+16384)>>15`，斜率≈0.1）或 linear（`M_neg=M_pos`） | `CONTRACT.md §5`；`engine-report.md §0.6`（requant 语义） |
| ReLU 无法用现有 flags 表达 | 负支输出必须是 0，而两种模式都给非 0（leaky 0.1×，linear 1×） |

**最小改法**：新增 `NN_F_RELU`（bit7）。
- `nn_pkg.sv`：`flags` 7→8 bit（`nn_desc_t` 同步 +1 位），新增 `localparam int unsigned NN_F_RELU = 7;`
- `nn_conv_engine.sv`：requant 负支选择由 `f_leaky ? M_neg : M_pos` 改成三态 `f_relu ? 0 : (f_leaky ? M_neg : M_pos)`（约 5~10 行；M_neg 现算逻辑保留）
- `nn_subsys.sv`：desc 组装处透传（flags 已透传则不改编）
- 生成器：`nn_gen_rom.py` / PTQ 脚本按层写 flags bit7
- 影响面：**只对 flags=RELU 的层生效**，旧模型（leaky/linear）**逐位不变**（回归门槛同 `DELIVERY §9.5.1`）

**验证判据**：单 case 位精确 —— 输入含负值，`out = leaky` 与 `out = relu` 的差异在负半轴；ReLU 层输出下界为 `zp_out`（`-128`）而不是 0.1×。

---

## 6. 深度/代价核算

### 6.1 路线 A（推荐：深度 128 + 改 2 行上限）

| 项 | 数值 |
|---|---|
| 条目宽度 | 240 bit（含 csum）/ 208 bit（去 csum） |
| 深度 | 128 |
| 总容量 | 30,720 bit（3.84 KB）/ 26,624 bit（3.25 KB） |
| 落 LUTROM（现实现） | ≈ 480 / 416 LUT6（1 LUT6 = 64 bit RAM 或 ~1 bit 常量 ROM 的等效）→ **相对现状 200×128=25,600 bit（约 400 LUT）增加 ~80 LUT** |
| 落 BRAM | **1 BRAM36**（36 Kb ≥ 30.7 Kb）→ 吃 1 tile（现余 3） |
| 建议 | **保持 LUTROM**（LUT 余量 26,415，BRAM 余量 3 tiles 更宝贵） |

### 6.2 路线 B（不改上限，切分到 213 op）

| 项 | 数值 |
|---|---|
| 深度 | 256 |
| 总容量 | 61,440 bit（7.5 KB） |
| 落 LUTROM | ≈ 960 LUT6（+560 vs 现状） |
| 落 BRAM | **2 BRAM36**（+2 tiles，现只余 3） |
| 额外代价 | 切分带来 33 层 × (额外 op 固定开销 ~100 拍 + dst 读改写流量)；且要多生成/维护一套切分逻辑 |
| 结论 | **不推荐**（为了省 2 行 RTL 改动，付出 +2 tiles + 复杂工具链） |

---

## 7. 生成器与验证

| 项 | 内容 |
|---|---|
| 生成器 | `tools/nn_gen_rom.py` 扩展：新 plan 格式（含 `wlen/wlen_q/tile.band_rows`）+ `nn_rom_pkg.sv` 输出（`NN_ROM_LEN=105`、`NN_ROM_DEPTH=128`） |
| 断言清单（生成器内置） | ① op 数 ≤ 128；② `src/dst < 2^22` 且落在 arena 窗口内；③ `woff+wlen ≤ 131,072`（银行容量）；④ `qoff+qlen ≤ 8,192`；⑤ `ic/oc ≤ 1023`；⑥ PACKED3 层必须 `ic≤8 && ks==3`；⑦ add 层 `oc==ic`；⑧ 每层 `wlen == OC_pad*IC_pad*K²`（稠密）/`OC_pad*K²`（dw） |
| 验证 | ① 重生成 **C128 旧模型 ROM** 后 E2E 仍 PASS（`tb_sw_nn_yolo`，`DELIVERY §8.1` 判据）；② 新模型 ROM 长度/字段断言；③ `nn_rom_to_desc` 单测（每字段透传） |
| 回归门槛 | `python tools/fpga_workflow.py verify --force` PASS 数不降（现 PASS 16，`DELIVERY §9.5`） |

---

## 8. 与 P3 结论的衔接

| P3 决定 | v1 是否沿用 | 说明 |
|---|---|---|
| src/dst 21-bit byte（arena 相对） | **升级到 22-bit** | arena 1.72MB（21-bit 只余 1.16×） |
| ROM 200→208 bit（P3 的 19→21） | **改为 240 bit（含 csum）/208（去 csum）** | 新增 wlen/qlen/tile/flags 位 |
| tile 摊平进 ROM 不可行（1,854 > 128） | ✅ **沿用**（新模型 1,325 个 band 同样不可摊平） | tile 循环在引擎内部 |
| 只要 1 个 BRAM36（128 项） | ✅ 沿用（30.7 Kb < 36 Kb） | 但推荐 LUTROM（BRAM 更宝贵） |
| C128 旧地址值不受影响 | ✅ | 21-bit 值在 22-bit 内无符号扩展即可 |
