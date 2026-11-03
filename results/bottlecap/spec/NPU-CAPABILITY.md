# NPU 能力 / 硬限制矩阵（contract v0.7 实况）

> 用途：判定「四色瓶盖检测模型（MobileNetV2(0.55)+FPN(72)+anchor-free 解耦头，224×224，2,048,721 参数）能否迁移到本 NPU」，并作为 DDR3 + 流式加载主线的 RTL 任务来源。
> 纪律：本文件只写**可复核的事实**；每条结论后跟 `文件:行号` 或报告章节。没有证据的写「未找到证据」。不修改任何 RTL/契约/交付文件。
> 生成时间：2026-11-03（Asia/Shanghai）。机器可读版：[`npu_capability.json`](npu_capability.json)。

---

## 0. 结论速览（TL;DR）

### 0.1 最硬的 8 个数字（现状）

| # | 指标 | 现状值 | 出处 |
|---|---|---|---|
| 1 | 权重区 W | **320 KB（327,680 B）**，综合期烧成 ROM，CPU 不可访问 | `nn_pkg.sv:43`、`results/ai-accel/CONTRACT.md:449`、`nn_mem.sv:12` |
| 2 | 量化参数区 Q | **48 KB（49,152 B）**，LUTRAM/BRAM 混合 ROM，CPU 不可访问 | `nn_pkg.sv:44`、`results/ai-accel/CONTRACT.md:450` |
| 3 | 激活 A / B | **A 96 KB（98,304 B）/ B 32 KB（32,768 B）**；单张量必须整体放在一个 buffer | `nn_pkg.sv:45-46`、`results/ai-accel/CONTRACT.md:451`、`nn_mem.sv:141-143` |
| 4 | 微码 ROM 深度 | **128 项 × 200 bit**（当前用 112 项）；`nn_seq` 的 idx 是 8 位 | `nn_pkg.sv:103,111-129`、`nn_seq.sv:58,79` |
| 5 | 通道上限 | **IC/OC ≤ 256**（契约 + `nn_subsys` start 拍检查）；ROM 字段 10 bit | `results/ai-accel/CONTRACT.md:100`、`nn_subsys.sv:252-253`、`nn_pkg.sv:117-118` |
| 6 | 激活函数集合 | **只有 {linear, leaky(斜率 0.1)}**，无 ReLU / ReLU6 / sigmoid / tanh | `results/ai-accel/CONTRACT.md:92`、`nn_conv_engine.sv:976-989`、`tools/yolo/quant_lib.py:252-263` |
| 7 | 计算吞吐 | 峰值 **128 MAC/拍**（16 OC lane × 8 px）；全模型实测效率 **16.85 MAC/拍** | `nn_subsys.sv:197-199`、`results/ai-accel/engine-report.md:826`、`results/ai-accel/proto/engine/full_model_estimate_v3.md:13` |
| 8 | 片上余量 | 整机 BRAM **132/135 tiles，仅余 3 tiles**；100 MHz 全实现 WNS **+0.136 ns**，最高已验证 **122.22 MHz** | `results/ai-accel/SPEC-SPECIALIZED.md:75-77`、`results/ai-accel/DELIVERY.md:227,241` |

### 0.2 目标模型（按源码实测，非估算）

| 指标 | 实测值 | 方法/出处 |
|---|---|---|
| 参数 | **2,048,721** | `tools/bottlecap/model_src/nut_detector/enhanced_anchor_free.py:84-116` 构造后 `sum(p.numel())`；训练文档 `results/bottlecap/reports/四色瓶盖模型训练过程.md:125` |
| int8 权重（§6 布局含 padding） | **2,020,960 B（≈1.93 MiB / 2.02 MB）** | 逐 Conv2d 按 `k*k*IC_pad*OC_pad`（dw 为 `k*k*OC_pad`）求和 |
| Q 区 payload（`6*OC_pad+16`/conv + 16B/add） | **90,368 B（88.2 KiB）** | 同上；与 lead 任务口径「约2.05MB 权重」同一量级（W+Q=2,111,328 B） |
| **单张量激活峰值** | **1,204,224 B**（112×112×96，`backbone.stage2.0.block.0.0` 输出） | 实际 forward hook + NPU int8 NHWC 紧凑布局（`pad8(96)=96`）。**注意：lead 任务书里的「约225KB」只对应深层张量（288ch@28×28=225,792 B 或 FPN 72ch@56×56=225,792 B），漏掉 early-layer expansion conv，实测峰值为其 5.3 倍** |
| NPU 折算 op 数 | **106**（conv 61 / dwconv 17 / add 20 / upsample 6 / copy 2） | FX graph trace + NPU op 映射（×4 上采样拆成 2 个 UP2X；concat 拆成 2 个 copy）。与 lead 口径「约150」不同：150 更像按 PyTorch 模块（含 BN/ReLU）计数；**若真按 150 op 部署，ROM 深度必须 128→256** |
| 超过 IC/OC≤256 的 op | **33 个**（最大 **864** 通道，见 §13.4） | 同上（`make_divisible(x,8)` 保证所有通道是 8 的倍数：`enhanced_anchor_free.py:13-14`） |
| ReLU 层数 | **58 层**（ConvBNReLU 53 + 残差块后 5） | `model.py:8-30`（`nn.ReLU`）、`enhanced_anchor_free.py:27`；FX trace 统计 |
| MACs | **2.272 GMAC**（另一独立统计 2.2735 GMAC，差 0.07%） | 逐层 `oh*ow*ic*oc*k*k`（dw 同式） |
| 输入张量 | 224×224×3 packed3 = **150,528 B** | `enhanced_anchor_free.py:128-148`；输入预处理 `四色瓶盖模型训练过程.md:111-119` |

### 0.3 判定（一句话）

> **现状 NPU 不能直接跑该模型。** 4 个「结构性」硬 blocker（W 容量 6.2×、单张量激活 12.3×、通道上限 3.4×、激活函数缺 ReLU）+ 2 个「容量」blocker（Q 1.84×、输入/中间张量超 A）。ROM 深度（106<128）、8 通道对齐、FPN 通道（72=9×8）、add/upsample 语义都**不是** blocker。
> 按现行 v3 周期公式外推，计算时间 ≈ **3,987 万拍 ≈ 0.40 s/帧 @100MHz（2.5 fps，不计 DDR 等待）**，即 **瓶颈是存储容量/带宽而不是算力**；详见 §13.5。
> 可行路线只有「DDR3 + 权重流式 + 激活 arena + tile cache」，见 §11/§13。

---

## 1. 证据基线（版本与口径）

| 项 | 事实 | 出处 |
|---|---|---|
| 契约版本 | `CONTRACT.md` 标题写 v0.1，但正文已迭代到 **v0.7 特化契约**（§12，2026-11-01） | `results/ai-accel/CONTRACT.md:1,441-506` |
| 冻结模型 | `model-yolofastest-v1.1-coco-int8`：int8 权重 319,792 B，Q 44,544 B，112 op | `results/ai-accel/MODEL-FREEZE.md:19-29`、`results/ai-accel/model-report.md:14-29` |
| 器件 | XC7A100T-FGG484-2：LUT 63,400 / FF 126,800 / BRAM36 135（607.5 KB）/ DSP48E1 240 | `results/ai-accel/PLAN.md:18` |
| AI 档全实现（100 MHz） | `BUILD_TIMING=PASS`，WNS **+0.136 ns**，fmax **101.4 MHz**，LUT 36,985 / FF 16,381 / BRAM **132** / DSP 168 | `results/ai-accel/DELIVERY.md:223-230` |
| 最高已验证频点 | **122.22 MHz**（WNS +0.058）；125 MHz 差 −0.077 失败 | `results/ai-accel/DELIVERY.md:233-244` |
| E2E 现状（最新） | 112 op，**`hw_bad=0 / auto_bad=0`**，MODE_CPU 与 MODE_AUTO 的 `npu_cycles=1,191,020` @100 MHz = 11.91 ms/帧 | `.fpga-cache/logs/tb_sw_nn_yolo.log:40-44`（2026-11-03 19:12） |
| E2E 历史值 | 1,177,320 拍 = **wpipe（W 读 1→2 拍）之前**的数；wpipe 后公式 +1.16% → 1,191,020 | `results/ai-accel/DELIVERY.md:269`（旧）、`results/engine-report.md:23`、`results/ai-accel/mem-report.md:274` |
| 回归基线 | `verify --force` **PASS 16**；`tb_sw_nn_yolo` 70.5 s、`tb_nn_engine` 3.8 s、`tb_nn_mem` 3.85 s、`tb_nn_seq` 3.1 s | `.fpga-cache/verify-state.json`；`results/ai-accel/DELIVERY.md:268` |

> **口径提醒**：本仓库有两个 `engine-report.md`。`results/ai-accel/engine-report.md` 是 v2/v3 主报告（848 行）；`results/engine-report.md` 是 R5 wpipe 补丁（35 行）。本矩阵的周期公式以 **`results/ai-accel/proto/engine/calc_cycles_v3.py`（代码级，含 W_RD_LAT=2）** 为准，因为它与最新 E2E 实测 1,191,020 逐 op 相等。

---

## 2. 支持的 op 与参数域

### 2.1 op 总表（引擎 v3，128 MAC/拍）

| 引擎 op | MMIO `NN_OP` 码 | ROM `kind` | 参数域（硬限制） | 精确语义 | 出处 |
|---|---|---|---|---|---|
| conv（dense） | 0 | 0 | `k∈{1,3,5}`、`stride∈{1,2}`、`pad≤k/2`(0..2)、`IC,OC≥1`、`IC/OC≤256`（契约）、OC 按 16 lane 分块 | `acc=Σ a_q·w_q + bias_adj`，requant 见 §4 | `nn_conv_engine.sv:116-137`、`results/ai-accel/CONTRACT.md:379` |
| depthwise | 0 + `flags.bit0` | 1 | 同上且 **`OC==IC`**；OC 按 8 lane 分块 | 每通道独立 3×3/5×5 | `nn_conv_engine.sv:122`、`results/ai-accel/CONTRACT.md:379` |
| maxpool | 1 | 2 | `k∈{2,3,5,9}`、`stride∈{1,2}`、`pad≤k/2`(≤4)、只做 max、**不做 requant** | 窗口越界填 `-128` | `nn_conv_engine.sv:124-126`、`results/ai-accel/CONTRACT.md:382` |
| copy | 2 | 5 | 8 通道（64 bit）粒度；`ceil8(ic)≤ceil8(oc)`；源/目标通道偏移必须 **8 的倍数** | 按 64b 字逐字搬，写口带 `b_wstrb` 半字掩码 | `results/ai-accel/CONTRACT.md:383`、`nn_conv_engine.sv:130` |
| upsample 2× | 2 + `flags.bit3` | 3 | **只支持 2× 最近邻**；1 个源字写 4 份 | `x2=2x+dx, y2=2y+dy` | `results/ai-accel/CONTRACT.md:383`、`nn_conv_engine.sv:1284-1286` |
| add（原始） | 3 | 4 | `OC==IC`；`dst=clamp(dst+src)` int8 饱和 | 读 src、读 dst、写 dst | `nn_conv_engine.sv:131-133`、`results/ai-accel/CONTRACT.md:384` |
| **ADD_R** | 3 + `flags.bit6` | 4 | `R:u16 (0<R≤65535)`、`KADD:u8`（契约 ≤15）；Q 块 16 B | `out=clamp(q_d+(((q_s-zp_s)*R)>>KADD),-128,127)`，floor | `results/ai-accel/CONTRACT.md:460-475`、`nn_conv_engine.sv:371-379` |
| **PACKED3** | 0 + `flags.bit5` | 0 | **仅 conv0**：`ic≤8`、`k=3`、非 depthwise | 输入 3 B/像素 `addr=y*iw*3+x*3+c`，c≥3 的 lane 填 `zp_in` | `nn_conv_engine.sv:123`、`results/ai-accel/SPEC-SPECIALIZED.md:58` |

补充硬约束：

- **band 寄存器组 24 字**：`count = 7*stride+k ≤ 24` ⇒ conv/dw k≤5,s≤2（19）；pool k=9,s=1（16）/k=9,s=2（23）全部可用；**k=7 之类不存在**。出处 `nn_conv_engine.sv:62,103-104`、`results/ai-accel/engine-report.md:693-697`。
- **dense conv 的 `IC≤504` 结构上限**：`icb_n = ic8[8:3]` 只有 6 bit（`nn_conv_engine.sv:102`）；契约的 256 更严，本报告按 256 记。
- **pool 输出 padding 通道写 0；conv/dw 写 `zp_out`**（`results/ai-accel/engine-report.md:685`）。
- **conv 的 add-mode（`NN_F_ADD`）未实现**（v1 起后置，`results/ai-accel/engine-report.md:687-688`）；shortcut 走独立 ADD_R op。
- **错误码**：conv `0x11..0x18`、pool `0x21..0x25`、copy `0x31..0x33`、add `0x41..0x44`（`nn_conv_engine.sv:144-174`）。

### 2.2 验证覆盖（位精确）

- 引擎 TB：**47/47 + 4/4 PASS, mismatch=0**（v3，含 PACKED3/ADD_R/全尺寸 conv0 replay），`results/ai-accel/engine-report.md:842-848`、`results/engine-report.md:20-24`。
- 46 case 周期表 vs 公式**逐 case 相等**（v2），`results/ai-accel/engine-report.md:176-228`。
- 代表层 replay（conv/dw/pool/upsample）全部 mismatch=0，`results/ai-accel/engine-report.md:750-763`。

---

## 3. 周期公式与吞吐（v3，W_RD_LAT=2）

以 **`results/ai-accel/proto/engine/calc_cycles_v3.py:12-103`** 为准（代码即契约；与 E2E 1,191,020 逐 op 相等）。常量：

```
BASE=8（S_INIT 1 + S_VCHK 1 + S_CPREP 6）; W_RD_LAT=2; DRN=W_RD_LAT+2=4; NEXT=2
QPER8=11（dw 每 OC 块）; REQP=6; q_tot(act)=act/2+act/4+1; q_cycles(act)=q_tot+4
REQ(act)=6+beats+2, beats= 8 if act==16 & oc8%16==0 & dst16B对齐 else 16 (act16)；act8 → 8
ICB=ceil(IC/8); OCB8=ceil(OC/8); OCB16=ceil(OC/16); NB=OH*ceil(OW/8)
```

| op | 周期公式（逐项） |
|---|---|
| conv（dense） | `cyc = BASE + Σ_{t=0..OCB16-1}[ q_cycles(act_t) + NB*(1 + sub*per + DRN + REQ(act_t) + NEXT) ]`，其中 `act_t=min(16, oc8-16t)`；`k=1: count=8, wi=0, sub=ICB, load=count+1`；`k>1: count=7*stride+k, wi=1, sub=k*ICB, load=count+1`；`per = load + wi + 8k`；PACKED3 时 `load = 3*count+1` |
| depthwise | `cyc = BASE + OCB8*QPER8 + OCB8*NB*(1 + k*per + DRN + REQ(8) + NEXT)`，`per=count+2+k`，`count=7*stride+k` |
| maxpool | `cyc = BASE + NB_pool*(1 + k*per + 8 + NEXT)`，`NB_pool=ICB*OH*ceil(OW/8)`，`per=count+2+k` |
| copy | `cyc = BASE + IH*IW*ICB*2` |
| upsample 2× | `cyc = BASE + IH*IW*ICB*5` |
| add（含 ADD_R） | `cyc = BASE + (ADD_R?1:0) + IH*IW*ICB*5` |

> 注：`results/ai-accel/engine-report.md:820-830` 的 §0.6.2 是 **wpipe 之前**的写法（add 写 `words*4`、`DRN3`）；以 `calc_cycles_v3.py` 的 `DRN=4 / words*5` 为准（否则对不上 1,191,020）。

### 3.1 每拍 MAC 数与实测效率

| op | 峰值 MAC/拍 | 实测/标定效率 | 出处 |
|---|---|---|---|
| dense conv | **128**（16 OC lane × 8 px） | YOLO 全模型 conv 类：16,279,552 MAC / 665,284 拍 ≈ **24.5 MAC/拍** | `nn_subsys.sv:197-199`；`results/ai-accel/engine-report.md:826`；`results/ai-accel/proto/engine/full_model_estimate_v3.md:7`；MACs 见 `results/ai-accel/engine-report.md:639` |
| depthwise | 64 lane 但受激活带宽限制 | 3,701,376 MAC / 462,102 拍 ≈ **8.0 MAC/拍** | `results/ai-accel/proto/engine/full_model_estimate_v3.md:8`、`results/ai-accel/engine-report.md:834` |
| pool/copy/add | 0（无 MAC） | — | — |
| **全模型（YOLO-Fastest C128）** | 128 | 20,070,016 MAC / 1,191,020 拍 = **16.85 MAC/拍**（13.2% 峰值） | `results/ai-accel/model-report.md:17`；`.fpga-cache/logs/tb_sw_nn_yolo.log:42` |

**为什么有效利用率低**：① OC block 是**最外层**循环（`nn_conv_engine.sv:1198-1226`），每个 OC tile 都要重读输入；② 每个输出块固定开销 `BASE + DRN + REQ + NEXT ≈ 8+4+16+2` 拍；③ dwconv 只有 8 lane。

---

## 4. 量化契约

| 项 | 规则 | 出处 |
|---|---|---|
| 权重 | int8 **per-OC 对称**：`s_w[oc]=max|W[oc]|/127`，`w_q=clamp(round(W/s_w),-127,127)`；BN 先折叠 | `results/ai-accel/CONTRACT.md:106-107,114-115` |
| 激活 | int8 **per-tensor 非对称**：`s_a=(max-min)/255`，`zp_a=-128-round(min/s_a)`；`a_q=clamp(round(a/s_a)+zp_a,-128,127)` | `results/ai-accel/CONTRACT.md:109-112` |
| bias | `bias_adj[oc]=round(b'/(s_a_in*s_w)) - zp_in*Σw_q`（zero-point 折进 bias） | `results/ai-accel/CONTRACT.md:117-121` |
| requant | `M_pos[oc]=int16(round(s_a_in*s_w/s_a_out*2^SHIFT))`；`M_neg=(M_pos*3277+16384)>>15`（≈0.100006 斜率）；`y=((acc≥0)?acc*M_pos:acc*M_neg)>>SHIFT`；**floor（算术右移）**；`out=clamp(y+zp_out,-128,127)` | `results/ai-accel/CONTRACT.md:123-139`、`nn_conv_engine.sv:769-777` |
| M_neg / leaky | M_neg **不存**，引擎在 OC tile 装载时现算：`leaky_en` ? `(M_pos*3277+16384)>>>15` : `M_pos` | `nn_conv_engine.sv:976-989`、`tools/yolo/quant_lib.py:252-263` |
| Q 尾字节 | `[0]=zp_out(int8) [1]=zp_in(int8) [2]=leaky_en(0/1) [3]=SHIFT [4..15]=0` | `results/ai-accel/CONTRACT.md:169-174` |
| SHIFT 范围 | 契约 1..30；RTL 实际支持 0..31（`shift_q≥16` 时两段移位：`(prod64>>>16)>>>shift_q[3:0]`） | `results/ai-accel/CONTRACT.md:126`、`nn_conv_engine.sv:769-775` |
| 乘法位宽 | 乘积 `acc*M` 需 40~43 位精度，**必须 64 位或两段 32 位**；RTL 用 48 位中间（`prod64[47:0]`） | `results/ai-accel/CONTRACT.md:137-138`、`nn_conv_engine.sv:758-767` |
| ADD_R | `out=clamp(q_d+(((q_s-zp_s)*R)>>KADD))`；Q 块 16 B：`[0]=zp_s [1]=zp_d [2:3]=R(u16 LE) [4]=KADD`；R per-tensor | `results/ai-accel/CONTRACT.md:466-475`、`nn_conv_engine.sv:371-379` |
| 层内激活 | **只由 `flags.bit1 (LEAKY)` 决定**：1=leaky 0.1，0=linear。**没有第三种** | `nn_pkg.sv:65-72`、`nn_conv_engine.sv:799` |
| 边界填充 | conv 边界外像素填 **`zp_in`**（不是 0）；padding 通道权重 0 | `results/ai-accel/CONTRACT.md:379`、`nn_conv_engine.sv:316` |

### 4.1 ReLU / ReLU6 能否表达？—— **不能（硬 blocker）**

- NPU 的负支乘数只有两个取值：`M_pos`（linear）或 `M_pos*0.1`（leaky）。**没有 `M_neg=0` 的 ReLU 分支，也没有 ReLU6 的 `min(6,x)` 上饱和**。
- 全仓库 RTL **grep 不到 relu**（`*.sv` 无匹配）；量化工具只有 `F.leaky_relu(0.1)`（`tools/yolo/darknet_lib.py:614,626`、`tools/yolo/quant_lib.py:252-263`）。
- 目标模型有 **58 层 `nn.ReLU`**（`tools/bottlecap/model_src/nut_detector/model.py:29`；`enhanced_anchor_free.py:27`），**无法逐位对齐浮点基线**。
- 现场做法：给 flags 增加 RELU 位（bit7 空位可用，见 `nn_pkg.sv:71-72`），Q tail 增加激活编码，引擎 `M_neg <= 0`（`nn_conv_engine.sv:976-989` 一处选择），量化工具 tail[2] 扩编码（`tools/yolo/quant_lib.py:252-263`）、`tools/nn_gen_rom.py:107-110` 映射。**这是小改动但属于契约+数值语义变更，必须重跑 E2E**。
- ReLU6 若要保原模型语义：本模型实际用 `nn.ReLU` 而非 ReLU6，**只需 ReLU**；若未来换真 MobileNetV2（ReLU6），需要额外上限饱和逻辑（M 后 clamp 到 6/s_a+...），工作量更大。

---

## 5. 通道 / 布局 / 对齐约束

| 约束 | 内容 | 出处 |
|---|---|---|
| 通道补齐 | `OC_pad=ceil(OC/8)*8`、`IC_pad=ceil(IC/8)*8`，padding 权重写 0；**所有真实通道按 8 通道块寻址** | `results/ai-accel/CONTRACT.md:149` |
| dense 权重布局 | `[tap][IC_pad][OC_pad]`，OC 在最低位；`tap=ky*K+kx`；每个 `(tap,ic)` = 8 字节权重字 | `results/ai-accel/CONTRACT.md:151-158` |
| depthwise 布局 | `[tap][OC_pad]` | `results/ai-accel/CONTRACT.md:160-165` |
| 权重镜像行数 | `yolo_w.hex` = 81,920 行 × 32 bit（320 KB）；脚本内 assert | `tools/yolo/README.md:102`、`results/ai-accel/mem-report.md:389-397` |
| 激活布局 | `addr(C,H,W,c,y,x)=((y*W+x)*C8+c_block)*8+c_byte`；读口 128 bit/拍（16 通道或 2 邻像素）；写口 128 bit + `b_wstrb[15:0]` | `results/ai-accel/CONTRACT.md:183-193`、`nn_pkg.sv:159-167` |
| 激活对齐 | `a_addr` 16 B 对齐（低 4 位忽略）；`b_addr` 16 B 对齐 + 字节 strobe；**不做 RMW** | `nn_mem.sv:43-46,105,110`、`results/ai-accel/SPEC-SPECIALIZED.md:52-53` |
| Q 区每层 | `6*OC_pad + 16` 字节：`bias_adj int32[OC_pad]` + `M_pos int16[OC_pad]` + tail 16 B | `results/ai-accel/CONTRACT.md:167-179` |
| copy/concat | 源/目标通道偏移必须是 **8 的倍数**（`nn_gen_rom.py:138-145` 生成侧也 assert） | `results/ai-accel/CONTRACT.md:383`、`tools/nn_gen_rom.py:138-145` |

**对目标模型的含义**：`make_divisible(x,8)`（`enhanced_anchor_free.py:13-14`）保证 backbone/FPN/头通道都是 8 的倍数（16/24/48/64/72/88/144/288/432/528/864），**布局零浪费**；FPN concat 通道偏移 0/72/144 全部 8 对齐，**concat 可用 copy 实现**；residual add 通道相同（`ad_oc_bad = d_oc != d_ic`，`nn_conv_engine.sv:133`）**满足**。→ 布局层面不是 blocker。

---

## 6. 容量硬限制（片上，v0.7 实况）

| 区 | 容量 | 物理实现 | 出处 |
|---|---|---|---|
| W | **327,680 B（320 KB）** | 80×BRAM36（4 段 64-bit 宽 ROM，每段 2 满宽读口）；综合期 `$readmemh` 烧入 | `nn_pkg.sv:43`、`nn_mem.sv:79,189-192`、`results/ai-accel/mem-report.md:103` |
| Q | **49,152 B（48 KB）** | lo 4096×64 BRAM（8 tiles）+ hi 2048×64 分布式 LUTRAM（0 tiles，~1.6K LUT） | `nn_pkg.sv:44`、`nn_mem.sv:361-362`、`results/ai-accel/mem-report.md:104` |
| A | **98,304 B（96 KB）** | 128-bit 宽阵列（与 B 连续共用 32 tiles） | `nn_pkg.sv:45`、`nn_mem.sv:141,398` |
| B | **32,768 B（32 KB）** | 同上 | `nn_pkg.sv:46` |
| 窗口总长 | 524,288 B（512 KB）：W 0x00000、Q 0x50000、空洞 0x5C000-0x5FFFF（16 KB）、A 0x60000、B 0x78000 | CPU 只能访问 A/B | `nn_pkg.sv:35-38,43-46`、`nn_mem.sv:30-34` |
| 单张量上限 | **A 98,304 B / B 32,768 B**（一个张量必须整段落在同一 buffer；并发峰值 131,072 B） | 引擎用 `a_sel/b_sel` 二选一 | `results/ai-accel/CONTRACT.md:451,459`、`nn_mem.sv:405-413` |
| 微码 ROM | **128 项 × 200 bit**（25,600 bit ≈ 3.2 KB LUTRAM/BRAM）；当前 `NN_ROM_LEN=112` | `nn_pkg.sv:103,111-129`、`nn_rom_pkg.sv:11` |
| BRAM 余量 | nn_mem **120** tiles + core 12 = **132/135**，余 **3** tiles | `results/ai-accel/SPEC-SPECIALIZED.md:71-77`、`results/ai-accel/mem-report.md:229-245` |
| BRAM 可寻址密度 | **4 KB/BRAM36**（32 位宽 1K×36；parity 位不能做字节） | `results/ai-accel/CONTRACT.md:63-67`、`results/ai-accel/PLAN.md:175-179` |
| DSP/LUT | 全实现 LUT 36,985 / FF 16,381 / DSP 168（100 MHz）；引擎 OOC DSP 200（目标 ≤160） | `results/ai-accel/DELIVERY.md:227-230,192` |

> **推论（对任何扩容方案）**：片上总可寻址 BRAM 容量 ≈ 135×4 KB = **540 KB**，扣 core ~12 tiles 后 ≈ **492 KB**；现有 W+Q+A+B 已占 496 KB（其中 Q 不占 BRAM，W+A+B = 448 KB）。**任何「把 2 MB 权重或 1.2 MB 激活放到片上」的想法在物理上不可能**，必须外挂存储。

---

## 7. 地址口径、端口与译码（W / Q / A / B / CPU 窗口）

### 7.1 `nn_mem` 端口清单（v0.7 + wpipe）

| 口 | 方向/位宽 | 语义（字节口径） | 出处 |
|---|---|---|---|
| CPU 窗口 | `cpu_re/cpu_we/cpu_addr[31:0]/cpu_wdata[31:0]/cpu_wstrb[3:0]/cpu_rdata[31:0]` | `cpu_addr` 是**窗口内偏移**（不是 0x9004_xxxx 绝对地址）；只映射 A/B；1 拍寄存读；非 A/B 读 0/写忽略 | `nn_mem.sv:87-93`、`nn_subsys.sv:147`、`results/ai-accel/mem-report.md:96` |
| NPU W 读 | `w_re`、`w_addr[23:0]`、`w_rdata[127:0]` | `w_addr` = **W 区相对**字节偏移，**8 B 对齐（低 3 位忽略）**，返回从该 8B 边界起的 **16 B 小端窗口**；**W 读时延 2 拍**（wpipe） | `nn_mem.sv:94-97,199-218,349,315`、`results/engine-report.md:13` |
| NPU Q 读 | `q_re`、`q_addr[12:0]`、`q_rdata[63:0]` | `q_addr` = **64-bit Q 字索引** 0..6143（48 KB）；越界读 0；1 拍 | `nn_mem.sv:98-101,381-392`、`results/ai-accel/mem-report.md:93` |
| NPU A 读 | `a_sel[1:0]`、`a_re`、`a_addr[23:0]`、`a_rdata[127:0]` | `a_addr` = **NN 窗口绝对字节偏移**，16 B 对齐；A=[0x60000,0x78000)、B=[0x78000,0x80000)；`a_sel` 与地址归属不符或越界 → 0；1 拍 | `nn_mem.sv:102-106,405-413,421` |
| NPU B 写 | `b_sel`、`b_we`、`b_addr[23:0]`、`b_wdata[127:0]`、`b_wstrb[15:0]` | 同上地址口径；16 B 对齐 + 字节 strobe；**无 RMW** | `nn_mem.sv:107-112,424-447` |
| dbg 装载 | `dbg_we/dbg_space/dbg_addr[16:0]/dbg_wdata[31:0]` | **仅仿真存在**（`ifndef SYNTHESIS`）；SoC 里 tie 0；`space=0` W / `space=1` Q，32-bit 字索引 | `nn_mem.sv:113-117,161-169,367-380` |

### 7.2 地址译码实现（关键行）

| 译码 | 实现 | 出处 |
|---|---|---|
| W 字索引 | `w_idx = w_addr_q[18:4]`，`w_odd = w_addr_q[3]`，`w_base = {w_idx,1'b0}\|w_odd`；4 段 ROM 按 `w_base` 段选（<16384 / <24576 / <32768 / 其余） | `nn_mem.sv:211-224,242-245` |
| W 越界 | `w_rd_valid_r <= w_re_q && (w_addr_q < W_BYTES)`；无效返回 0 | `nn_mem.sv:315,349` |
| Q 越界 | `q_rd_valid_r <= q_re && (q_addr < Q64)`；`q_addr[12]` 选 lo/hi | `nn_mem.sv:383-392` |
| A 归属 | `a_in_a=(a_addr>=A_OFF)&&(a_addr<B_OFF)`；`a_in_b=(a_addr>=B_OFF)&&(a_addr<B_END)`；`a_val_act = a_re && ((a_sel==0&&a_in_a)\|\|(a_sel==1&&a_in_b))` | `nn_mem.sv:405-413` |
| B 归属 | 同式 `b_val_act`；写口 NPU 优先于 CPU | `nn_mem.sv:408-447` |
| CPU 命中 | `cpu_sel_act = (cpu_addr>=A_OFF)&&(cpu_addr<B_END)`；**A/B 之外不存在可写窗口** | `nn_mem.sv:416-417,438-445` |

### 7.3 「让 W 区可被 CPU/DMA 写入」需要新增什么

**现状事实**：综合版 W/Q 是**纯 ROM**——写块整体在 `ifndef SYNTHESIS` 内（`nn_mem.sv:161-169,367-380`），且 W 的两个 BRAM 读口都被 cur/next 双读占满（`nn_mem.sv:172-182`，"为什么必须 64-bit 宽 + 两个满宽读口"见 `results/ai-accel/mem-report.md:183-190`）。CPU 窗口只映射 A/B（v0.7 §12.1，`results/ai-accel/CONTRACT.md:451`）。**没有任何 W 写口、没有 W 地址窗、没有任何权重加载寄存器。**

| 需要新增 | 建议形态 | 落点（文件/模块） | 说明 |
|---|---|---|---|
| W 写口 | `w_we`、`w_waddr[23:0]`、`w_wdata[127:0]`/`w_wstrb[15:0]`（或 64-bit 粒度） | `nn_mem.sv`（W 阵列声明 + 写 always 块） | BRAM36 只有 2 口且两读口都占满 ⇒ 必须 **时分复用**（引擎空闲/加载模式下把一口借给写）；或外挂 DDR3 后改成 FIFO→W 双 buffer（双缓冲仍需 +80 tiles，放不下，故实际方案是「不搬进 W BRAM，直接从流式缓存喂引擎」，见 §11） |
| W 加载模式/状态 | `LOAD_MODE`（加载中引擎不可启动）、加载地址计数器、CRC/校验、完成中断 | `nn_subsys.sv`（新增 MMI0 寄存器 + 加载 FSM）+ `nn_seq.sv`（或独立 loader） | 目前 `NN_CTRL` 只有 start/auto（`nn_subsys.sv:294-320`），无加载语义 |
| MMIO 寄存器 | 例：`NN_WLOAD_ADDR`（目标 W 偏移）、`NN_WLOAD_DATA`（数据口）或 `NN_WLOAD_DMA`（源 DDR 地址/长度/命令）+ `NN_WLOAD_STATUS` | `rv32_pkg.sv`（MMIO_NN_* 常量区 `:385-403`）+ `nn_subsys.sv`（写译码 `:294-337`）+ `top_a100t.sv`（`nn_mmio_sel` 地址段 `:265`） | 现有 MMIO 窗口 0xA000_0100..0x0148 只剩 5 个 32-bit 空位（0x140/0x144/0x148 已作为 DBG0/1/2，`nn_subsys.sv:394-396`），扩容要重排 |
| 启动期权重加载源 | QSPI Flash 或 DDR3；CPU 轮询/中断 | 主板/新模块 | 现在权重来自**综合期 `$readmemh`**（`nn_mem.sv:66-72`、`results/ai-accel/PLAN.md:20`），换模型必须重综合 bitstream |
| 时序/端口时延契约 | 写后读一致性、W 读时延保持 2 拍 | `nn_mem.sv` + `nn_conv_engine.sv`（`W_RD_LAT`） | 见 `results/engine-report.md:9-26` |

> 结论：W 可写化不是「加一根 we」那么简单——**W 的两个 BRAM 读口已全满**，要么改变权重读取协议（16B 对齐、引擎自己选半字，回到 75.5 tiles 但仍需写口），要么放弃「W 常驻片上」改**流式**。后者才是 2 MB 模型的可行路线（§11）。

---

## 8. 微码 ROM 与字段位宽：当前实际 vs 需求

### 8.1 当前**实际**字段（`nn_pkg.sv:111-129` + `tools/nn_gen_rom.py:10-12`）

> ⚠️ `results/ai-accel/SPEC-SPECIALIZED.md:31-44` 的 96-bit 字段表是**旧草案**（含 `icb/ocb/ohop/owop`）；**当前 RTL 实际没有这四个字段**，已改为 `ic/oc` 精确 10 bit。

| 字段 | 当前位宽 | 说明 | 备注 |
|---|---:|---|---|
| `kind` | 4 | 0=conv,1=dwconv,2=pool,3=upsample,4=add,5=copy | `nn_pkg.sv:104-109` |
| `flags` | 7 | `NN_F_*`（depthwise/leaky/add/up2x/poolmax/packed3/add_r） | `nn_pkg.sv:65-72,113` |
| `ks` | 4 | conv 1/3/5；pool 2/3/5/9 | `nn_pkg.sv:114` |
| `pad` | 3 | 0..4 | `nn_pkg.sv:115` |
| `stride` | 2 | 1/2 | `nn_pkg.sv:116` |
| `ic` | 10 | 真实输入通道（≤1023） | `nn_pkg.sv:117` |
| `oc` | 10 | 真实输出通道 | `nn_pkg.sv:118` |
| `ih` / `iw` | 9+9 | 输入 H/W（≤511） | `nn_pkg.sv:119-120` |
| **`src` / `dst`** | **19+19** | A/B 窗口内字节偏移（≤524,287） | `nn_pkg.sv:121-122`：**当前实际是 19 bit**（P3 的 21-bit 只是文档决策，未落 RTL） |
| `woff` | 19 | W 区相对字节偏移（≤512 KB） | `nn_pkg.sv:123` |
| `qoff` | 16 | Q 区相对字节偏移（≤64 KB） | `nn_pkg.sv:124` |
| `aux0` / `aux1` | 16+16 | add: R / KADD（copy: 源/目标通道偏移） | `nn_pkg.sv:125-126` |
| `csum` | 32 | golden FNV（debug） | `nn_pkg.sv:127` |
| `rsvd` | 5 | 对齐 | `nn_pkg.sv:128` |
| **合计** | **200 bit** | 200 bit = 25 B/项（128 项 = 3,200 B） | `nn_pkg.sv:129`、`tools/nn_gen_rom.py:12`、`results/ai-accel/nn_rom_table.json`（`total_bits: 200`） |

### 8.2 `nn_desc_t`（引擎描述符，`nn_pkg.sv:78-92`）

`op[1:0] flags[6:0] ks[3:0] stride[1:0] pad[2:0] ih[15:0] iw[15:0] ic[15:0] oc[15:0] src[31:0] dst[31:0] woff[31:0] qoff[31:0]`（= 2+7+4+2+3+16×4+32×4 = 178 bit，packed struct）。

### 8.3 ROM 深度定义在哪 / 改 256 要动哪些地方

| # | 位置 | 当前值 | 改成 256 的动作 |
|---|---|---|---|
| 1 | `nn_pkg.sv:103` | `NN_ROM_DEPTH = 128` | 改 256（或 160/192） |
| 2 | `nn_seq.sv:58` | `logic [7:0] idx` | 8→9 bit |
| 3 | `nn_seq.sv:66` | `last_entry = ... idx == 8'(NN_ROM_LEN-1)` | 位宽 8→9 |
| 4 | `nn_seq.sv:79` | `logic [199:0] rom_mem [0:NN_ROM_DEPTH-1]` | 位宽随字段扩展（200→208）、深度 256 |
| 5 | `nn_seq.sv:81` | 初始化 `for i<NN_ROM_DEPTH` | 自动跟随常量 |
| 6 | `nn_rom_pkg.sv:11,13` | 生成物：`NN_ROM_LEN=112`、`NN_ROM [0:NN_ROM_DEPTH-1]` | 重新生成 |
| 7 | `tools/nn_gen_rom.py:297` | `depth_max = 128` | 改 256 |
| 8 | `tools/nn_gen_rom.py:308-309` | `len(entries) > depth_max` 直接 fail | 自动跟随 |
| 9 | `tools/yolo/gen_rom_table.py:38` | `ROM_DEPTH = 128` | 改 256 |
| 10 | `results/ai-accel/CONTRACT.md:477-483` / `SPEC-SPECIALIZED.md:27` | 契约文字「深度 128 / 108 entries」 | 契约同步 |
| 11 | `sim/tb_nn_seq.sv` | 用 `NN_ROM_LEN`（112） | 重新生成后自动 |

**ROM 物理代价**：128×200 bit = 25,600 bit ≈ 3.2 KB（LUTRAM/BRAM，`nn_pkg.sv:128` 注释、`results/ai-accel/SPEC-SPECIALIZED.md:27`）；256×208 bit = 53,248 bit ≈ 6.5 KB。当前 `nn_seq` 的 ROM 落 BRAM ROM（`nn_seq.sv:74-82` 注释，~1-2 tile），**256 项仍在 1-2 tile 内**，不构成 BRAM 压力。

### 8.4 「跑 150 op / 2 MB 权重」的差值表

| 字段/参数 | 当前实际 | 需求 | 差值 | 必改位置 |
|---|---|---|---|---|
| ROM 深度 | 128 | **150 → ≥256**（本模型实测 106 项，够 128；若按 150 则不够） | +128 项 | 见 §8.3 的 11 处 |
| 单条 ROM 位宽 | 200 bit | **208 bit**（src/dst 19→21 = +4 bit，按字节对齐补到 208；P3 决策见 `results/ai-accel/P3-320-ARENA.md:96-110`） | +8 bit | `nn_pkg.sv:111-129`、`tools/nn_gen_rom.py:10-12`、`nn_seq.sv:79` |
| `src` / `dst` | 19 bit（512 KB） | **21 bit（2 MB arena）** | +2 bit ×2 | `nn_pkg.sv:121-122`、`tools/nn_gen_rom.py` NUM_FIELDS、`results/ai-accel/nn_rom_table.json.total_bits` |
| `woff` | 19 bit（512 KB） | **21 bit（W 2,020,960 B=1.93 MiB < 2 MiB）** | +2 bit | `nn_pkg.sv:123`、生成器 `clamp`（`tools/nn_gen_rom.py:88-93`）会 fail，必须放宽 |
| `qoff` | 16 bit（64 KB） | **17 bit（90,368 B）** — 若 Q 仍放片上；若 Q 进 DDR3 则改语义 | +1 bit | `nn_pkg.sv:124`、`tools/nn_gen_rom.py` |
| `flags` | 7 bit | **8 bit**（+RELU） | +1 bit | `nn_pkg.sv:80,113`、`nn_conv_engine.sv:798-802` |
| `ic`/`oc` | 10 bit（≤1023） | 864 ✓ 不需要改 | 0 | — |
| `ih`/`iw` | 9 bit（≤511） | 224 ✓ | 0 | — |
| ROM 总量 | 25,600 bit | 53,248 bit | +27,648 bit（≈3.3 KB） | — |
| 引擎 `w_addr`/`a_addr`/`b_addr` | 24 bit | DDR arena ≤2 MB，24 bit 够 | 0 | — |
| `nn_mem` W 段拆分 | 固定 4 段（16384/8192/8192/8192） | 2 MB 需 32 段或换存储 | 大改 | `nn_mem.sv:189-192,242-245`、`results/ai-accel/mem-report.md:422-424` |

---

## 9. 引擎地址口径与「OC 块分多次启动」机制

| 问题 | 事实 | 出处 |
|---|---|---|
| `w_addr` 口径 | **W 区相对字节偏移**（0 基），24 bit，8 B 对齐，返回 16 B 窗口；引擎侧 = `d_woff + oc_base_w` | `nn_mem.sv:37-39`；`nn_conv_engine.sv:1002` |
| `a_addr` 口径 | **NN 窗口绝对字节偏移**（A=0x60000 / B=0x78000 起），24 bit，16 B 对齐；引擎 = `desc.src` 派生基址 + 像素/通道步长 | `nn_mem.sv:43-44`；`nn_conv_engine.sv:429-476,889-931` |
| `b_addr` 口径 | 同上（窗口绝对），16 B 对齐 + `b_wstrb[15:0]` | `nn_mem.sv:45-46`；`nn_conv_engine.sv:502,545,555` |
| buffer 选择 | 引擎用**地址比较**：`sel_a_src = (d_src >= NN_B_OFF)`、`sel_b_dst = (d_dst >= NN_B_OFF)`，`nn_mem` 再核对 `a_sel` 与地址归属（不符→0） | `nn_conv_engine.sv:931-932`；`nn_mem.sv:405-413` |
| OC 分块由谁做 | **硬件内部做**：dense 按 16 lane、dw/pool 按 8 lane 分 OC tile；`c_ocb` 是**最外层循环**（S_NEXT2 default 分支才 `c_ocb++`）；**一次 start 跑完整层** | `nn_conv_engine.sv:1172-1226`、`results/ai-accel/P3-DDR3-TILECACHE.md:73-76` |
| plan 是否拆分 OC | **不拆**：`plan.json` 每个 conv 一项，无 OC base 字段；ROM 一项对应一整层 | `results/ai-accel/CONTRACT.md:326-337`、`nn_pkg.sv:111-129` |
| 想把一层拆成多次启动 | 当前**不支持**：desc 里没有 `oc_start/oc_count`；写入目标通道偏移也没有独立字段（`dst` 只给像素基址）。需新增 desc/ROM 字段（如 `oc_base`）或让 plan 生成多个 conv（各自 `dst` 通道偏移 + `woff` 偏移），且引擎要支持"只算 OC 子集" | `nn_pkg.sv:78-92`、`nn_conv_engine.sv:1198-1226` |
| 对 DDR 流量的含义 | OC-block 外层 ⇒ 每个 OC tile 重读输入（dense 读放大 `ceil(oc8/16)` 倍）⇒ C320 估算读放大 4.22×、40.9 MB/帧，必须改 **band-outer** 调度（行带外层） | `results/ai-accel/P3-DDR3-TILECACHE.md:65-76` |
| **DDR3 的直接冲突** | 引擎 buffer 选择用 `d_src >= NN_B_OFF` 判 A/B；若 src/dst 换成 DDR3 arena 绝对地址（base 0x0100_0000），该比较**永远为真** → 全部落 B；且 `a_addr` 只有 24 bit（16 MB 够，但语义/译码要重做） | `nn_conv_engine.sv:931-932`、`nn_mem.sv:405-413` |

> **P3 预留**：`SPEC-SPECIALIZED.md:109-114` 已写「`nn_seq` 增加 `TENSOR_SRC` 字段（0=片上 A/B，1=DDR3）… 128 档不启用，320 档启用；权重永不进 DDR3（D2）」——**该字段当前未实现**（全 RTL grep 无 `TENSOR_SRC`/`ddr`/`axi`/`dma` 实体）。

---

## 10. A/B 地址空间、CPU 窗口映射与「CPU 搬输入图」

### 10.1 地址空间与映射规则

| 项 | 值 | 出处 |
|---|---|---|
| NN 窗口基址/大小 | `NN_BASE=0x9004_0000`、`NN_BYTES=512 KB`（core 地址译码 `sel_nn`） | `rv32_pkg.sv:326-327`、`core.sv:1541-1544` |
| A 区 | 窗口偏移 `0x60000..0x77FFF`（96 KB） | `nn_pkg.sv:37,45`、`nn_mem.sv:33` |
| B 区 | `0x78000..0x7FFFF`（32 KB） | `nn_pkg.sv:38,46` |
| W/Q | `0x00000..0x4FFFF` / `0x50000..0x5BFFF`；**CPU 不可访问**（读 0/写忽略） | `results/ai-accel/CONTRACT.md:446-459`、`nn_mem.sv:415-417` |
| CPU 访问口径 | `cpu_addr` = 窗口内**偏移**（`nn_subsys.sv:147` 做 `cpu_addr - NN_BASE`）；1 拍寄存读；A/B 之外写忽略（**不报错**） | `nn_subsys.sv:147`、`nn_mem.sv:416-417`、`results/ai-accel/mem-report.md:96` |
| busy 期间 | CPU 读 → `0xDEAD_BEEF`；写 → 丢弃并置 `STATUS.err`（sticky） | `nn_subsys.sv:146-149,345-349` |
| MMIO 寄存器 | `0xA000_0100..0x0148`：CTRL/STATUS/CYCLES/OP/SRC/DST/WOFF/QOFF/IH/IW/IC/OC/KS/ST/PAD/FLAGS/DBG0-2 | `rv32_pkg.sv:385-403`、`results/ai-accel/CONTRACT.md:73-100` |

### 10.2 CPU 往 A 区搬输入图：现成函数

| 函数 | 位置 | 做法 |
|---|---|---|
| `gen_input()` | `sw/yolo_demo.c:115-125` | 按 `pattern_v1` 公式 `q=(x*13+y*7+c*29+seed)&0xFF` 生成输入，写到 `YOLO_INPUT_ABS + (y*W+x)*YOLO_INPUT_STRIDE + c` |
| 写字节原语 `wr8(off,v)` | `sw/yolo_demo.c:42` | `NN_WIN[off] = v`（`NN_WIN = (volatile u8*)YOLO_NN_BASE`，`:39`） |
| 常量来源 | `sw/yolo_plan.h:42-51`（`YOLO_INPUT_ABS=0x60000`、`STRIDE=3`、`BYTES=49152`）+ `tools/nn_gen_sw.py` 生成 | 自动生成，禁止手写 |
| 其它 CPU 搬运函数（软件基线用） | `sw_upsample`（`:230-247`）、`sw_pool`（`:220-228`）、`sw_copy`（`:319-327`）、`sw_cat`（`:300-315`）、`sw_cpu_add`（`:280-290`） | 逐字节循环，非 DMA |
| 真实图像通路 | **未实现**：输入是确定性合成图；真实图片「走 UART/后续阶段」 | `sw/yolo_demo.c:8-10`、`results/ai-accel/CONTRACT.md:350-357` |
| 每像素成本 | 3 次 `volatile` 字节写 + 地址计算；128×128×3=49,152 B，约 15~20 万 CPU 拍（量级） | 由代码结构推断（未单独实测） |

> 对 224×224 输入：packed 3B/像素 = **150,528 B > A 96 KB**，`gen_input()` 这种「整图写进 A」的方式**直接放不下**；即使放得下也需要新的 resize/letterbox/归一化/NCHW→NHWC/量化转换（模型预处理 `四色瓶盖模型训练过程.md:111-119`），当前无对应代码。

---

## 11. 外部存储 / 流式（DDR3）维度：现状与必须新增

### 11.1 现状事实（仓库里有什么/没有什么）

| 项 | 事实 | 出处 |
|---|---|---|
| DDR3 RTL / MIG | **没有**：全仓库 `*.sv` grep 无 `mig_7series`/`ddr3`/`AXI`/`DMA` 实体；`top_a100t.sv` 端口只有 `sys_clk/sys_rst_n/led[3:0]/uart_txd/uart_rxd` | `fpga/top_a100t.sv:58-62`；grep 结果（本文件 §11.3） |
| DDR3 引脚 | **没有**：`fpga/daVinciPro.xdc` 仅 42 行，只有 clk/rst/4×LED/UART 引脚 | `fpga/daVinciPro.xdc:47-56` |
| 权重来源 | 综合期 `$readmemh` 烧进 bitstream（QSPI 自启动），**无运行时加载** | `results/ai-accel/PLAN.md:20`、`nn_mem.sv:66-72`、`results/ai-accel/DELIVERY.md:56` |
| P3（DDR3）设计状态 | **只有模型侧规格/分析，无 RTL**：C320 arena 表 819,200 B、21-bit 地址决策、band-outer tile cache 需求 ~12.4 tiles、带宽 0.48–0.56 GB/s vs 有效 1.6–2.2 GB/s | `results/ai-accel/P3-320-ARENA.md:11-35,96-110`、`results/ai-accel/P3-DDR3-TILECACHE.md:12-20,100-113` |
| P3 接口预留 | `nn_seq` 计划增加 `TENSOR_SRC`（0=片上/1=DDR3）+ tile DMA（行块、双缓冲），**未实现** | `results/ai-accel/SPEC-SPECIALIZED.md:109-114` |
| 板卡事实 | 用户已确认板上有 **2 片 DDR3 + 摄像头**（接口待定）；MIG 配置/引脚/参考时钟未给 | `results/ai-accel/PLAN.md:228-260` |
| 带宽预算（C320 参考） | 30fps 需 0.48–0.56 GB/s（占 32-bit DDR3 有效带宽 24–35%）；但若沿用 OC-block 外调度，读放大 4.22× → 40.9 MB/帧 → 1.23 GB/s 不可接受 | `results/ai-accel/P3-DDR3-TILECACHE.md:12-20,65-76,100-113` |
| 对流式最关键的 BRAM 约束 | 整机只剩 **~3 tiles**（132/135）；P3 tile cache 需 ~12.4 tiles ⇒ 必须腾 BRAM（Q 全 LUTRAM/缩 tile/其它） | `results/ai-accel/SPEC-SPECIALIZED.md:82-85`、`results/ai-accel/P3-DDR3-TILECACHE.md:243-245` |

### 11.2 「W 可写 + DMA 流式」最小新增集（文件/模块/端口级）

| # | 新增项 | 具体形态（建议） | 落点 |
|---|---|---|---|
| 1 | DDR3 物理层 | MIG 7-series（或自写控制器）：32-bit（2×16）@DDR3-800 级别，ui_clk 100–200 MHz 域 | 新 `ddr3/` 目录 + `fpga/daVinciPro.xdc`（新引脚约束）+ `fpga/build*.tcl`（IP/DCP 流程）；**破坏「零厂商 IP」纪律，需 Lead 决策** |
| 2 | AXI/简单流接口 | MIG 的 AXI4 从口 + 一个读命令队列（权重/激活两路 QoS） | 新模块 `nn_dma.sv` |
| 3 | 权重流式前端 | DDR3→片上权重 tile（例如 4–8 KB 双 buffer）→ 引擎 `w_*`；引擎地址从「W 区 0 基」改成「DDR3 字节地址 + 当前 tile 基」 | `nn_conv_engine.sv`（`wa_r`/`w_delta`/`W_RD_LAT`）、`nn_mem.sv`（W ROM→RAM/FIFO）、`nn_pkg.sv`（woff 位宽/语义） |
| 4 | 激活 arena / tile 缓存 | 行带（band）+ OC 块两级 tile；DDR3 读写经 DMA 与 A/B 交换；`nn_seq` 增加 tile 循环 | `nn_seq.sv`（新增内层循环/`TENSOR_SRC`）、`nn_mem.sv`（A/B 双缓冲 + DMA 口）、`nn_conv_engine.sv`（**外层循环改 band-outer**，否则读放大 4.22×） |
| 5 | 引擎 buffer 选择重做 | 去掉 `d_src >= NN_B_OFF` 的 A/B 硬编码比较（`nn_conv_engine.sv:931-932`），改为显式 `src_space/dst_space` + tile 内偏移 | `nn_pkg.sv`（desc 字段）、`nn_conv_engine.sv`、`nn_mem.sv` |
| 6 | 启动加载/校验 | 上电后从 Flash/DDR3 加载 W/Q 到片上缓存 + CRC/FNV 校验 + 加载完成标志 | `nn_subsys.sv`（新 FSM + MMIO 寄存器）、`sw/`（loader）、`rv32_pkg.sv`（新 MMIO 地址） |
| 7 | 时钟域 | MIG `ui_clk` 与 `sys_clk_core` 跨时钟桥（异步 FIFO） | 新模块；影响时序收敛 |
| 8 | BRAM 重分配 | W ROM 腾出的 80 tiles 改为 tile 缓存（~12.4 tiles 够 P3，可给更大模型更多）；Q 处理（LUTRAM/BRAM/新容量） | `nn_mem.sv`、`fpga/nn_mem_bb.sv`（OOC 黑盒 DCP 需重生成，`results/ai-accel/DELIVERY.md:250-253`） |
| 9 | 工具链 | 权重/激活的 DDR3 地址分配（arena map 生成器已有：`tools/yolo/gen_arena_map.py`）、plan 增加 tensor 位置字段、ROM 拓宽 | `tools/yolo/gen_arena_map.py`、`tools/nn_gen_rom.py`、`tools/nn_gen_sw.py` |

---

## 12. 执行模式与「新增一个模型」流程

### 12.1 两种模式（同一硬件，v0.7）

| 模式 | 触发 | 行为 | 接口 | 出处 |
|---|---|---|---|---|
| `MODE_CPU`（v0.5 兼容） | `NN_CTRL.start=1`（bit0） | CPU 逐 op 写 14 个描述符寄存器并轮询 done；`nn_subsys` 做 `desc_ok` 检查 | `NN_CTRL/STATUS/CYCLES/OP..FLAGS` | `nn_subsys.sv:294-320`、`results/ai-accel/CONTRACT.md:485-491` |
| `MODE_AUTO`（v0.7） | `NN_CTRL.start=1` **且 bit1=1** | `nn_seq` 按 `nn_rom_pkg::NN_ROM` 自主跑完；CPU 只读 STATUS/CYCLES；done/err 粘滞 | `NN_CTRL=3`；`YOLO_AUTO_OK` 宏门控 | `nn_subsys.sv:300-305,361-368`、`nn_seq.sv:120-137`、`sw/yolo_plan.h:442-443` |
| 双模等价验收 | 同一 plan 两模式逐 op checksum 相同 | 实测 `hw_bad=0 / auto_bad=0`，npu_cycles 均 1,191,020 | — | `.fpga-cache/logs/tb_sw_nn_yolo.log:42-43` |

> 注：v0.7 的 `NN_CTRL` bit1 在 start 拍同时被解释为 `auto`（`nn_subsys.sv:300`），与 CONTRACT §4 的 `irq_en` 语义复用同一 bit（`rv32_pkg.sv:385`）。

### 12.2 新增一个模型的工具链产物（从模型到可跑）

| 步骤 | 产物 | 生成器 | 需要改什么 |
|---|---|---|---|
| ① 浮点模型落地/BN 折叠 | `data/model_float.pt` 等 | `tools/yolo/convert_yolo_fastest.py`（**darknet 专用**） | 目标模型是 PyTorch checkpoint → **必须新写前端**（当前无 torch/onnx→plan 路径，全仓库无 onnx 依赖） |
| ② int8 PTQ + Q 打包 | `data/model_int8_<hw>.npz`（每层 bias_adj/M_pos/SHIFT/zp） | `tools/yolo/quantize.py` + `quant_lib.py` | 需支持新网络结构/激活（ReLU）与 per-layer Q 分配 |
| ③ golden 全整数前向 | `GOLDEN: PASS mismatch=0` | `tools/yolo/golden.py` | 复用数值语义即可 |
| ④ 集成向量 + 镜像 | `plan.json`、`model.json`、`yolo_w.hex`、`yolo_q.hex`、`checksums.txt`、`l*_*.hex` | `tools/yolo/make_vectors.py` | 需 A/B 分配器支持更大模型（现支持 `--buffer-a/--buffer-b` 外挂 arena，`tools/yolo/README.md:89-94`） |
| ⑤ ROM 数据源 | `nn_rom_table.json`（112/128 项） | `tools/yolo/gen_rom_table.py` | ROM_DEPTH/字段位宽 |
| ⑥ 微码 ROM RTL | `nn_rom_pkg.sv` | `tools/nn_gen_rom.py` | depth_max/字段位宽 |
| ⑦ C 头 | `sw/yolo_plan.h`（地址/op 表/FINALS） | `tools/nn_gen_sw.py` | 无（自动从 nn_pkg/plan 生成） |
| ⑧ 软件镜像 | `sim/prog/yolo_demo.hex` + `.dmem.hex` | `tools/build_sw.py --all --with-hw`（`tools/build_sw.py:3-14`） | 大 plan 的 `.data` 表会变大（103 op × 48 B ≈ 5 KB，dmem 16 KB，**可放下但接近**） |
| ⑨ 综合/bitstream | `fpga/cpu_a100t_nn.bit`（W/Q 由 `$readmemh` 烧入） | `python tools/fpga_workflow.py synth --nn ...` | 换模型必须**重综合**；W ROM 展开需 OOC DCP 黑盒（`results/ai-accel/DELIVERY.md:250-253`） |

**完整命令链**（YOLO 现网，可作新模型模板）：`results/ai-accel/DELIVERY.md:145-162`、`tools/yolo/README.md:127-143`。

---

## 13. 目标模型（瓶盖检测）全差距清单

> 术语：**必改** = 不改就一定跑不了；**需 DDR3** = 只有外挂存储路线才能满足（片上物理不可能）。
> 数值口径见 §0.2；「差距/硬限制/需求」均为实测或由源码直算。

### 13.1 结构性 blocker（4 条）

| # | 差距 | 硬限制（现状） | 目标需求 | 倍数 | 必改模块/端口/字段 | 需 DDR3？ |
|---|---|---|---|---|---|---|
| B1 | **权重容量** | W=327,680 B（80 BRAM36，ROM 烧入） | 2,020,960 B（+Q 90,368 B） | **6.17×** | `nn_pkg.sv` W 尺寸/woff 位宽；`nn_mem.sv` W 阵列→流式；`nn_conv_engine.sv` 权重地址/时延；新增 DDR3+MIG+权重 DMA；工具链 woff 分配 | **是**（片上总容量 540 KB < 2.02 MB，无解） |
| B2 | **单张量激活容量** | A=98,304 B / B=32,768 B（单张量必须整段落一个 buffer） | 峰值 **1,204,224 B**（112×112×96）；concat 目标 677,376 B；输入 packed 150,528 B | **12.25×**（对 A）；9.4×（对 A+B） | `nn_pkg.sv` A/B 尺寸；`nn_mem.sv` 激活阵列→DDR3 arena + tile 缓存 + DMA 口；`nn_seq.sv` tile 循环；`nn_conv_engine.sv` band-outer 调度；`nn_pkg.sv` src/dst 21 bit | **是** |
| B3 | **通道上限** | 契约 IC/OC ≤ 256（`nn_subsys.sv:252-253`）；ROM 10 bit；引擎 `ic8[8:3]` 6 bit → IC≤504 | 最大 **864**；33 个 op 超 256（288/432/528/864 等） | **3.375×** | `nn_subsys.sv` desc_ok（256→≥1024）；`nn_pkg.sv` ic/oc 位宽（10 bit 够 864）；`nn_conv_engine.sv` `icb_n` 6→7 bit、Q 读字数、OC tile 计数/`oc_limit_r`；`results/ai-accel/CONTRACT.md:100` | 否（但 Q/权重寻址随之改） |
| B4 | **激活函数缺 ReLU** | 只有 {linear, leaky0.1}；无 ReLU/ReLU6 | **58 层 `nn.ReLU`** | 不可量化 | `nn_pkg.sv` flags +1 bit（bit7 可用）；`nn_conv_engine.sv:976-989` M_neg=0；`tools/yolo/quant_lib.py:252-263` tail 编码；`tools/nn_gen_rom.py:107-110`；CONTRACT §5/§7/§12 | 否（契约+小 RTL 改） |

### 13.2 容量 blocker（2 条）

| # | 差距 | 硬限制 | 需求 | 倍数 | 必改 | 需 DDR3？ |
|---|---|---|---|---|---|---|
| B5 | **Q 区容量** | 49,152 B（lo 32 KB BRAM + hi 16 KB LUTRAM；q_addr 13 bit / qoff 16 bit） | **90,368 B**（`6*OC_pad+16` × 78 conv + 16 B × 20 add） | **1.84×** | `nn_pkg.sv` NN_Q_BYTES / qoff 位宽（16→17）；`nn_mem.sv` Q 子 ROM（扩容需 24 tiles，无余量）→ 建议 Q 也进 DDR3 或在 LUTRAM 扩（~+3K LUT）；`nn_conv_engine.sv` q_addr 13→14+ bit | 二选一（片上无 BRAM 余量） |
| B6 | **输入 / 中间张量 > A** | A 98,304 B；PACKED3 conv0 输入要整段可寻址 | 224²×3 packed = **150,528 B**；conv0 输出 112²×8 = **100,352 B** 也超 A | 1.53×/1.02× | `nn_conv_engine.sv` PACKED3 → 行带流式（C320 已有 band 方案：20 band × 16,320 B，`results/ai-accel/P3-320-ARENA.md:41-62`）；`nn_seq.sv` 内层 loop；DMA | **是** |

### 13.3 非阻塞但需确认/小改（5 条）

| # | 项 | 现状 | 目标模型 | 结论 |
|---|---|---|---|---|
| N1 | ROM 深度 | 128（当前 112） | **106 NPU op**（conv61/dw17/add20/up6/copy2）；若真 150 op | 106 **够**（余 22）；150 需 256（§8.3） |
| N2 | 通道 8 对齐 | OC_pad/IC_pad 必须 8 的倍数 | 全部通道 8 的倍数（`make_divisible`），FPN 72=9×8，concat 偏移 0/72/144 全 8 对齐 | **满足**，无浪费 |
| N3 | concat | 无 concat op，用 copy（8 通道粒度） | 3×72ch → 2 个 copy，偏移 72/144 | **满足**（plan 生成侧展开） |
| N4 | upsample | 只支持 2× 最近邻 | FPN 有 14→56 的 **4×**（`enhanced_anchor_free.py:138`） | 拆成 2 个串联 UP2X（+1 op）；**满足** |
| N5 | residual add | ADD_R：R u16 ≤65535、KADD≤15；`OC==IC` | 20 个 add（12 个 InvertedResidual + 3 FPN + 5 残差块）；通道相同 | 语义满足；**R 溢出风险**：若 `s_s/s_d>2` 则 R>65535 → 需量化时选 KADD 或改契约（待量化实测） |

### 13.4 目标模型逐层画像（关键行，完整表见 `results/bottlecap/model/model_profile.json`，task-3 产物）

| 指标 | 值 |
|---|---|
| op 构成 | conv 61 / dwconv 17 / add 20 / upsample 6 / copy 2 = **106**（FX trace） |
| 超过 256 通道的 op | **33 个**；最大 864（stage5.1/5.2 的 expansion/dwconv） |
| 峰值张量 top-5 | 1,204,224 B（112²×96）；802,816 B ×4（112²×64）；451,584 B（56²×144） |
| 权重分布 | 2,020,960 B；最大单层权重（3×3,72→72）=46,656 B；1×1 61 个 |
| Q 分布 | 90,368 B；最大单层 Q（OC=864）=5,200 B |
| ReLU 层 | 58（ConvBNReLU 53 + 残差后 5）；linear 45 |
| MACs | 2.272 GMAC（≈YOLO 的 113 倍） |

### 13.5 计算时间预算（按现行 v3 公式外推，**不计 DDR 等待/搬运**）

| 口径 | 拍数 | @100 MHz | 帧率 |
|---|---|---|---|
| 峰值上限（128 MAC/拍） | 17,761,848 | 0.178 s | 5.6 fps |
| **逐 op 套 v3 公式（本报告计算）** | **39,870,094** | **0.399 s** | **2.51 fps** |
| 若参考 YOLO 实测效率（16.85 MAC/拍） | 134,900,000 | 1.35 s | 0.74 fps |
| 若主频 122.22 MHz（已验证最高） | 同上 | 0.326 s | 3.07 fps |

- 逐 op 外推明细：conv 33,877,606 拍 / dwconv 4,785,178 / add 968,665 / upsample 125,733 / copy 112,912（方法：`calc_cycles_v3.py` 公式 + FX trace 形状，含 ×4 上采样拆分；**该外推假设引擎能支持 >256 通道，仅用于量级判断**）。
- 结论：**算力不是主要矛盾**（2.5 fps 量级）；真正卡的是「权重/激活放不下」+「DDR 带宽/搬运」。若 DDR 侧只能给 0.5 GB/s，则每帧搬 ~2 MB 权重 + ~几十 MB 激活所需时间要与 0.4 s 叠加，需 DDR3 主线单独核算（task-2）。

### 13.6 精度/验证影响（非 RTL 但会决定可行性）

| 项 | 风险 | 出处 |
|---|---|---|
| per-tensor int8 激活精度 | YOLO-Fastest 实测逐层 cos 0.9738/最小 0.9174，且**理想 QDQ 上限 0.9889/0.9670 证明 0.99 判据不可达** | `results/ai-accel/model-report.md:20,33` |
| 目标模型精度未知 | 无 int8 量化/评测产物（`tools/bottlecap/` 只有 profile/训练源码，无量化链） | 目录实况 |
| ReLU 不可表达 | 若用 leaky 0.1 替代，数值语义即偏离 float 基线 | 本文件 §4.1 |
| 软件基线不可跑 | 2.27 GMAC 的 CPU 基线约 5×10^8~10^9 拍（YOLO 20M MAC 基线 4.73 亿拍，`results/ai-accel/DELIVERY.md:309`）→ **MODE_CPU 双跑验证策略不可用**，必须改为逐 op golden checksum + 代表层 replay | 推论（基于 `results/ai-accel/DELIVERY.md:309`、`results/ai-accel/model-report.md:17`） |

---

## 14. 仿真验证入口与判据

### 14.1 官方入口（唯一合法入口）

```powershell
python tools\fpga_workflow.py verify                 # 增量，全矩阵；期望 PASS 16
python tools\fpga_workflow.py verify --force         # 全量重跑
python tools\fpga_workflow.py verify --only tb_sw_nn_yolo --force   # 单跑整模型 E2E
python tools\fpga_workflow.py verify --only tb_nn_engine tb_nn_mem tb_nn_seq --force
```

出处：`tools/fpga_workflow.py:14-15,3333-3335`。

### 14.2 测试矩阵（AI 相关 4 项）

| 测试名 | 命令 | 判据行（pass_marker） | 实测耗时 | 覆盖 |
|---|---|---|---|---|
| `tb_sw_nn_yolo` | 见上 | `RESULT : PASS` + `hw_bad=0` + `auto_bad=0` + `npu_cycles` | **70.5 s** | 112 op 全模型 E2E；MODE_CPU/MODE_AUTO 双模；逐 op FNV vs golden |
| `tb_nn_engine` | 同上 | `ENGINE_TB: PASS` | **3.8 s** | 47 case + 4 扩展（PACKED3/ADD_R），位精确 |
| `tb_nn_mem` | 同上 | `MEM_TB: PASS` | **3.85 s** | W/Q 全量扫描、A/B 128b+strobe、CPU 窗口 |
| `tb_nn_seq` | 同上 | `NN_SEQ_TB: PASS` | **3.1 s** | 112 次启动/desc 映射/周期累加 |

出处：`tools/fpga_workflow.py:1128-1179`、`.fpga-cache/verify-state.json`、`.fpga-cache/logs/tb_nn_seq.log:26`。

### 14.3 E2E 判据细节（当前 log 原文）

```
[yolo] ops=112 in=128x128x3
[yolo] input_csum=0xcfd271c5 exp=0xcfd271c5 OK
[yolo] hw_bad=0 hw_cycles=10469260 npu_cycles=1191020
[yolo] auto_bad=0 auto_cycles=1191620 auto_npu_cycles=1191020
[yolo] RESULT : PASS
```
出处：`.fpga-cache/logs/tb_sw_nn_yolo.log:40-44`。

### 14.4 其它入口（只读/单程序）

| 工具 | 用法 | 出处 |
|---|---|---|
| `sim/run_prog.py` | `python sim/run_prog.py --imem ... --dmem ... --plus ...`；复用 verify 的编译/仿真链，不写 verify 缓存 | `sim/run_prog.py:1-12,25-34` |
| 引擎模块级 TB | `results/ai-accel/proto/engine/run_tb.bat` → `ENGINE_TB: PASS (47 cases, mismatch=0)` | `results/ai-accel/engine-report.md:251-260,844-848` |
| 周期公式对拍 | `python results/ai-accel/proto/engine/calc_cycles_v3.py <log>` → `bad=0` | `results/ai-accel/proto/engine/calc_cycles_v3.py:135-157` |
| 模型流水线自检 | `golden.py` → `GOLDEN: PASS mismatch=0`；`make_vectors.py` 内置 FNV 断言 | `tools/yolo/README.md:70-83,109-112` |

> 本矩阵**没有跑任何仿真**（任务纪律）；耗时取自 `verify-state.json` 的实测秒数。

---

## 15. 未找到证据 / 待确认

| # | 事项 | 状态 |
|---|---|---|
| Q1 | 目标模型的 int8 量化产物（Q 表、逐层 cos、端到端精度） | **不存在**；`tools/bottlecap/` 只有训练/评估源码与 `best_model.pt`；量化链未建 |
| Q2 | DDR3 型号/引脚/参考时钟/MIG 配置 | **未找到**；xdc 无 DDR 引脚，仓库无 MIG IP/工程；需用户提供（`results/ai-accel/PLAN.md:249-260`） |
| Q3 | 摄像头接口（DVP/MIPI/SPI、分辨率、格式） | **未找到 RTL**；`top_a100t.sv` 无视频口；用户确认板上有摄像头（`results/bottlecap/reports/四色瓶盖模型训练过程.md:111-119` 只描述预处理） |
| Q4 | `nn_rom_t` 21-bit src/dst 是否已落 RTL | **未落**：当前 `nn_pkg.sv:121-122` 仍是 19 bit；P3 只是文档决策（`results/ai-accel/P3-320-ARENA.md:96-110`） |
| Q5 | ADD_R 的 R 是否会溢出（目标模型 scale 比 >2） | **未量化，无法判定**；需先跑量化 |
| Q6 | 「150 op」口径来源 | **未在仓库找到**；本报告实测 106（NPU 折算） |
| Q7 | 目标模型 224 输入时单张量峰值 225 KB 的口径 | **与实测不符**：实测 1,204,224 B；225 KB 只对应深层张量（见 §0.2） |
| Q8 | 2 MB 权重模型的首帧加载时间 / bitstream 增量 | 无数据（当前权重 320 KB 烧 bitstream；2 MB 需外挂） |

---

## 附录 A：证据索引（本文件引用的关键 `file:line`）

| 主题 | 证据 |
|---|---|
| 存储布局/容量 | `results/ai-accel/CONTRACT.md:47-69,446-459`；`nn_pkg.sv:35-48`；`nn_mem.sv:30-46,79-83,141-143` |
| MMIO 寄存器 | `results/ai-accel/CONTRACT.md:73-100`；`rv32_pkg.sv:385-403`；`nn_subsys.sv:294-337,375-399` |
| 量化契约 | `results/ai-accel/CONTRACT.md:104-143,460-475`；`tools/yolo/quant_lib.py:1-20,228-263`；`nn_conv_engine.sv:769-782,978-982` |
| 权重布局 | `results/ai-accel/CONTRACT.md:147-165`；`results/ai-accel/model-report.md:561-570` |
| Q 布局 | `results/ai-accel/CONTRACT.md:167-179`；`tools/yolo/README.md:59-68` |
| 激活布局 | `results/ai-accel/CONTRACT.md:183-193`；`nn_pkg.sv:159-167` |
| 引擎 op/校验 | `nn_conv_engine.sv:27-29,60-65,100-174`；`results/ai-accel/engine-report.md:375-392,670-699` |
| 周期公式 | `results/ai-accel/proto/engine/calc_cycles_v3.py:12-103`；`results/ai-accel/engine-report.md:820-830`；`results/ai-accel/proto/engine/full_model_estimate_v3.md:5-16` |
| ROM/字段 | `nn_pkg.sv:94-129`；`nn_seq.sv:58-86,120-137`；`tools/nn_gen_rom.py:10-12,88-121,182-192,297-309`；`tools/yolo/gen_rom_table.py:7-20,38` |
| nmem 端口/译码 | `nn_mem.sv:76-118,156-224,340-392,394-469`；`results/ai-accel/mem-report.md:42-106,254-295` |
| MODE 双模 | `nn_subsys.sv:141-153,294-320,361-368`；`results/ai-accel/CONTRACT.md:485-491`；`sw/yolo_demo.c:357-382,505-534` |
| CPU 搬图 | `sw/yolo_demo.c:38-45,111-125`；`sw/yolo_plan.h:9-15,41-51`；`tools/nn_gen_sw.py:13-18` |
| 工具链流程 | `tools/yolo/README.md:13-31,96-108,127-146`；`results/ai-accel/DELIVERY.md:145-162` |
| 验证入口 | `tools/fpga_workflow.py:14-15,1128-1179,3333-3335`；`.fpga-cache/verify-state.json` |
| E2E 实况 | `.fpga-cache/logs/tb_sw_nn_yolo.log:40-44`；`results/ai-accel/DELIVERY.md:266-271`；`results/STAGE-REVIEW-1103.md:27` |
| 器件/时序/BRAM | `results/ai-accel/PLAN.md:18`；`results/ai-accel/DELIVERY.md:223-244`；`results/ai-accel/SPEC-SPECIALIZED.md:62-85` |
| DDR3/P3 | `results/ai-accel/PLAN.md:228-268`；`results/ai-accel/P3-320-ARENA.md:9-110`；`results/ai-accel/P3-DDR3-TILECACHE.md:10-113`；`results/ai-accel/SPEC-SPECIALIZED.md:109-114` |
| 目标模型 | `tools/bottlecap/model_src/nut_detector/enhanced_anchor_free.py:13-148`；`mobilenet_anchor_free.py:12-43`；`model.py:8-43`；`results/bottlecap/reports/四色瓶盖模型训练过程.md:111-150` |

## 附录 B：目标模型数值的复现方法

本报告 §0.2 的模型数值由以下方法直算（无新增仓库文件；如需复现可在仓库根用 `python -<stdin>` 执行）：

1. `sys.path.insert(0, "tools/bottlecap/model_src")`，`from nut_detector.enhanced_anchor_free import EnhancedNutAnchorFree`；
2. `m = EnhancedNutAnchorFree(num_classes=4, fpn_channels=72, backbone_width=0.55).eval()`；`sum(p.numel())` 应得 **2,048,721**；
3. 对 1×3×224×224 输入 `torch.fx.symbolic_trace` + `ShapeProp`，遍历 graph：Conv2d 节点取 `in/out shape/k/stride/pad/groups`；`add`/`interpolate`/`cat` 节点取 `tensor_meta`；
4. 按 `pad8(c)=ceil(c/8)*8` 算：权重 `k*k*pad8(ic)*pad8(oc)`（dw 为 `k*k*pad8(oc)`）、Q `6*pad8(oc)+16`、激活 `oh*ow*pad8(oc)`；
5. NPU op 折算：×4 上采样拆 2 个 UP2X；concat 拆 `n-1` 个 copy；add 保留；
6. 周期按 `results/ai-accel/proto/engine/calc_cycles_v3.py` 的公式逐 op 套用（`BASE=8, DRN=4, NEXT=2, REQP=6`）。

交叉校验：`results/bottlecap/ddr3/layers.csv`（task-2 队友的中间产物，若存在）给出 w_bytes=2,020,960、q_bytes=90,368、max out_bytes=1,204,224，与本报告一致。
