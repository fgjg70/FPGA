# 四色瓶盖检测模型 · 逐层画像与 NPU 落地评估

> 自动生成：`python tools/bottlecap/profile_model.py`（本文所有数字均由脚本从 `model_src/best_model.pt` 实测/推导，重跑即复现；勿手改）。
> 生成时间：2026-11-03T23:16:56+0800；torch 2.8.0+cu129；设备口径：画像=CPU 解析、精度基线=cpu。
> 契约口径：`results/ai-accel/CONTRACT.md` v0.7 + `nn_pkg.sv`（W 320KB / Q 48KB / A 96KB / B 32KB，op = conv/dwconv/pool/copy/add，激活 NHWC 8 通道分块）。

## 0. 结论摘要（先看这一节）

| 项目 | 实测/推导值 | 判据 |
|---|---|---|
| 参数量 | **2,048,721**（与 run_config/checkpoint 一致：True） | strict load_state_dict + sum(p.numel()) |
| 总 MACs @224 | **2,271,966,928**（2.272 GMAC，4.54 GFLOP） | 逐层 ic/groups*k*k*oc*oh*ow 求和 |
| int8 权重总字节 | **2,020,960 B**（NPU 打包）/ 2,019,160 B（裸 numel） | CONTRACT §6 OC_pad/IC_pad 补 8 |
| 单张量激活峰值 @224 | **1,204,224 B**（backbone.stage2.0.block.0.0，[1, 112, 112, 96]） | NHWC 8 通道分块 H*W*C8；A 缓冲 96KB 的 12.2x |
| NPU 口径 op 数 | **106 op**（conv 61 + dwconv 17 + add 20 + copy 8） | CSE 前 107；ROM 深度 128 |
| 精度基线（CPU 复跑） | TP=1250 FP=0 FN=0；P=1.000 R=1.000 F1=1.000 mIoU=0.969591 | 与文档一致：True |
| 能否装进 A=96KB | **224/192/160/128 全部不能（全层口径）**；仅 FPN+头段 128 可（73,728 B） | 见 §5 多分辨率表 |
| 整体结论 | **不能直接上 NPU**：W/Q/A/B 四项预算全部超；且 33 层 IC/OC>256 触发引擎限制、5 处 add 后 ReLU 无原语。需改结构/压缩/流式权重，或降到 64x64 输入（无实用意义） | 见 §4 不兼容清单 |

## 1. 模型与加载验证

| 项目 | 值 |
|---|---|
| checkpoint | `D:\USER\Desktop\FPGA\FPGA\tools\bottlecap\model_src\best_model.pt` |
| checkpoint 大小 / SHA256 | 8,472,326 B / `b88f6215cfca1890…` |
| checkpoint epoch | 13 |
| model_variant | `enhanced_mobilenetv2_fpn_decoupled_head` |
| fpn_channels / backbone_width | 72 / 0.55 |
| 参数量（实测） | **2,048,721** |
| 参数构成 | 卷积权重 2,019,160 + BN 可训练(weight/bias) 29,552 + head conv bias 9 = 2,048,721（与参数量一致：True） |
| BN 存储量 | checkpoint 里 BN 共 59,104 个标量（含 running_mean/var 两个 buffer，折叠后推理不需要） |
| run_config / checkpoint 声称参数量 | 2,048,721 / 2,048,721 |
| strict load_state_dict | PASS（无缺失/多余 key） |
| state_dict 条目 | 456 |
| 类别 | red_cap, purple_cap, green_cap, yellow_cap |
| BN 折叠等价性自检（max|Δ|） | 6.318e-06（75 个 Conv+BN 对折叠） |
| checkpoint 内记录指标 | P=1.0 R=1.0 F1=1.0 mIoU=0.9695916731357574 |

## 2. 结构概览（按 stage 聚合）

网络 = EnhancedMobileNetV2(0.55) 骨干（C2=24 / C3=48 / C4=88 / C5=144，stage4 中间层 72ch） + 四层 FPN(lateral 1x1, 72ch) + 4 个 ResidualConvBlock 精炼 + 多尺度 concat(216ch)-融合 1x1 + 三个解耦头塔（obj 3 层 / cls 3 层 / box 2 层，均 3x3 72ch），输出在 56x56（stride 4）。

| stage | 层数 | conv/dw | add | copy | MACs | MACs 占比 | 权重 B(int8) | 最大单张量 B |
|---|---|---|---|---|---|---|---|---|
| input | 1 | 0 | 0 | 0 | 0 | 0.0% | 0 | 150,528 |
| backbone.stem | 1 | 1 | 0 | 0 | 5,419,008 | 0.2% | 432 | 200,704 |
| backbone.stage1 | 8 | 6 | 2 | 0 | 65,830,912 | 2.9% | 5,248 | 802,816 |
| backbone.stage2 | 11 | 9 | 2 | 0 | 80,683,008 | 3.6% | 21,120 | 1,204,224 |
| backbone.stage3 | 15 | 12 | 3 | 0 | 88,397,568 | 3.9% | 102,384 | 451,584 |
| backbone.stage4 | 18 | 15 | 3 | 0 | 80,965,248 | 3.6% | 371,616 | 225,792 |
| backbone.stage5 | 11 | 9 | 2 | 0 | 38,212,944 | 1.7% | 640,464 | 103,488 |
| fpn.lateral | 7 | 4 | 3 | 0 | 9,878,400 | 0.4% | 21,888 | 225,792 |
| fpn.refine | 21 | 8 | 4 | 6 | 388,644,480 | 17.1% | 373,248 | 225,792 |
| fpn.fusion | 6 | 3 | 1 | 3 | 341,397,504 | 15.0% | 108,864 | 677,376 |
| head.tower | 8 | 8 | 0 | 0 | 1,170,505,728 | 51.5% | 373,248 | 225,792 |
| head.out | 3 | 3 | 0 | 0 | 2,032,128 | 0.1% | 648 | 25,088 |

- 总 MACs：**2,271,966,928**；后段（fpn.tower/head 的 56x56x72 段）占 83.7%——2M 参数不等于低算力，检测头在 56x56 分辨率上是主要算力来源。

## 3. 逐层画像（最重/最大张量 Top）

完整逐层表（约 110 条，含 name/op/入出 NHWC/k-s-p-groups/权重字节/MACs/输出字节/激活类型）见 `model_profile.json` 的 `layers` 字段（机器可读）。下面是摘要：

### 3.1 MACs Top 12

| 层 | op | in NHWC | out NHWC | k/s/p/g | MACs | 权重 B | 激活 |
|---|---|---|---|---|---|---|---|
| refine2.conv1.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | relu |
| refine2.conv2.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | none |
| multi_scale_fusion.1.conv1.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | relu |
| multi_scale_fusion.1.conv2.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | none |
| objectness_tower.0.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | relu |
| objectness_tower.1.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | relu |
| objectness_tower.2.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | relu |
| class_tower.0.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | relu |
| class_tower.1.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | relu |
| class_tower.2.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | relu |
| box_tower.0.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | relu |
| box_tower.1.0 | conv3x3 | [1, 56, 56, 72] | [1, 56, 56, 72] | 3/1/1/1 | 146,313,216 | 46,656 | relu |

### 3.2 单张量激活 Top 8

| 层 | op | stage | 输出 NHWC | 字节 | A 96KB 的倍数 |
|---|---|---|---|---|---|
| backbone.stage2.0.block.0.0 | conv1x1 | backbone.stage2 | [1, 112, 112, 96] | 1,204,224 | 12.25x |
| backbone.stage1.0.block.0.0 | conv1x1 | backbone.stage1 | [1, 112, 112, 64] | 802,816 | 8.17x |
| backbone.stage1.0.block.1.0 | dwconv3x3 | backbone.stage1 | [1, 112, 112, 64] | 802,816 | 8.17x |
| backbone.stage1.1.block.0.0 | conv1x1 | backbone.stage1 | [1, 112, 112, 64] | 802,816 | 8.17x |
| backbone.stage1.1.block.1.0 | dwconv3x3 | backbone.stage1 | [1, 112, 112, 64] | 802,816 | 8.17x |
| cat | concat | fpn.fusion | [1, 56, 56, 216] | 677,376 | 6.89x |
| backbone.stage2.1.block.0.0 | conv1x1 | backbone.stage2 | [1, 56, 56, 144] | 451,584 | 4.59x |
| backbone.stage2.1.block.1.0 | dwconv3x3 | backbone.stage2 | [1, 56, 56, 144] | 451,584 | 4.59x |

### 3.3 单个 op 需同时驻留的激活（src+dst）Top 6

| 层 | op | in NHWC | out NHWC | 驻留 B | A+B 128KB 的倍数 |
|---|---|---|---|---|---|
| backbone.stage1.0.block.1.0 | dwconv3x3 | [1, 112, 112, 64] | [1, 112, 112, 64] | 1,605,632 | 12.25x |
| backbone.stage1.1.block.1.0 | dwconv3x3 | [1, 112, 112, 64] | [1, 112, 112, 64] | 1,605,632 | 12.25x |
| backbone.stage2.0.block.1.0 | dwconv3x3 | [1, 112, 112, 96] | [1, 56, 56, 96] | 1,505,280 | 11.48x |
| backbone.stage2.0.block.0.0 | conv1x1 | [1, 112, 112, 16] | [1, 112, 112, 96] | 1,404,928 | 10.72x |
| cat | concat | [[1, 56, 56, 72], [1, 56, 56, 72], [1, 56, 56, 72]] | [1, 56, 56, 216] | 1,354,752 | 10.34x |
| backbone.stage1.0.block.0.0 | conv1x1 | [1, 112, 112, 16] | [1, 112, 112, 64] | 1,003,520 | 7.66x |

## 4. NPU 落地评估（CONTRACT v0.7 口径）

### 4.1 预算对账

| 预算项 | NPU 容量 | 本模型需求 | 结论 |
|---|---|---|---|
| 权重 W | 327,680 B (320.0 KB) | 2,020,960 B（6.17x） | **超** |
| 量化参数 Q | 49,152 B (48.0 KB) | 90,368 B（1.84x） | **超** |
| 激活 A（最大单张量） | 98,304 B (96.0 KB) | 1,204,224 B（12.25x） | **超** |
| 激活 A+B（单 op 驻留） | 131,072 B (128.0 KB) | 1,605,632 B（12.25x） | **超** |
| op ROM | 128 项 | 106 op | 够 |
| engine IC/OC | <= 256 | 最大 864 ch（扩张层） | **超** |

### 4.2 NPU 口径 op 数

| 原语 | 数量 | 说明 |
|---|---|---|
| conv（dense，含 head 1x1） | 61 | k=1/3；BN+ReLU 融合，不计额外 op |
| dwconv | 17 | InvertedResidual 的 3x3 depthwise |
| pool | 0 | 网络里没有池化 |
| copy（upsample 2x） | 6 | 5 处 2x + 1 处 4x(=2 次 2x)；重复的 p3->56 CSE 省 1 次 |
| copy（concat 通道偏移） | 3 | 3 个源 -> 同一 dst 通道偏移 |
| add | 20 | 12 shortcut + 5 ResidualConv + 3 FPN 融合 |
| **合计** | **106** | CSE 前 107；另有 5 处 add 后 ReLU 无原语 |

### 4.3 NPU 不兼容点清单

- **[FATAL] 权重区 W 320KB 装不下** —— int8 权重 2,020,960 B (1.93 MB)（NPU 打包口径），是 W=327,680 B (320.0 KB) 的 6.17x；checkpoint fp32 为 8,194,884 B (7.82 MB)（2,048,721 参数）。片上常驻不可能，必须 DDR3 流式（或蒸馏/剪枝/换更小骨干）。
- **[FATAL] 量化参数区 Q 48KB 装不下** —— 按 CONTRACT §7（6*OC_pad+16 每层 + 16 B/ADD_R）估算 90,368 B (88.2 KB)，是 Q=49,152 B (48.0 KB) 的 1.84x。
- **[FATAL] 激活 A/B 缓冲装不下单张量** —— 224 输入单张量峰值 1,204,224 B (1.15 MB)（backbone.stage2.0.block.0.0），是 A=98,304 B (96.0 KB) 的 12.25x；最大单 op 驻留（src+dst）1,605,632 B (1.53 MB)，是 A+B=131,072 B (128.0 KB) 的 12.25x。
- **[FATAL] 首层输入装不进 A** —— 224x224 输入按 PACKED3=3B/像素 也要 150,528 B (147.0 KB) > A=98,304 B (96.0 KB)；NHWC C8 口径为 401,408 B (392.0 KB)。与 v0.7 cpu_conv0 先例一致：第一层只能 CPU 执行（或把输入缩到 <=160 且做通道分块）。
- **[BLOCKER] engine 规模限制 IC/OC <= 256 被打破** —— 33/78 个卷积层越界 (IC>256: 22 层；OC>256: 22 层；其中 11 个 InvertedResidual 的扩张通道 288/432/528/864）。OC>256 的扩张 1x1 可拆成 2 个 op 顺序写不同输出通道（不跨 256），但 IC>256 的 depthwise/pointwise 必须『拆 IC + 部分和累加』，而 v0.7 引擎的 conv add-mode 未实现（engine-report §8.2），且 conv 描述符没有通道偏移字段，需额外 copy 把通道块搬成独立张量；当前 ISA 不能直接映射。
- **[BLOCKER] 4x 最近邻上采样无直接原语** —— 1 处 4x（interpolate_4）：COPY 只支持 2x（UP2X），4x 必须链式 2 次 2x 拷贝，多 1 个中间张量 + 1 次激活读写；若输入 224，中间张量 56x56x72=225,792 B。
- **[BLOCKER] concat 只能靠多 copy 拼，dst 张量过大** —— 1 处 concat（out [1, 56, 56, 216]）：可用 3 个通道偏移 copy 实现（偏移 [0, 72, 144] 均 8 对齐=True），但 dst 单张量 677,376 B (661.5 KB) 远超 A 缓冲。
- **[BLOCKER] add 之后紧跟 ReLU 无对应原语** —— 5 处（ResidualConvBlock 的 x+conv2(x) 后接 relu；另 12 个 MobileNetV2 shortcut 的 add 后**没有**激活，可直接用 ADD op）：ISA 的 ADD 是纯 int8 饱和加，无后置激活；conv 的融合激活只能作用在卷积输出上。只能 CPU 做（v0.5 cpu_add 先例）或改结构（去掉 add 后 relu / 改成 conv add-mode，需引擎先支持 add-mode）。
- **[WARN] ADD 要求两操作数同 scale/zp** —— 20 个 add（12 个 MobileNetV2 shortcut + 5 个 ResidualConvBlock + 3 个 FPN 横向融合）按 CONTRACT §11 需要两操作数 scale/zp 相同；v0.5 用 cpu_add + per-tensor R 绕过。属于量化设计约束（可解），不是原语缺失。
- **[WARN] 预处理/后处理不在 NPU 图内** —— 预处理：320x240 -> bilinear 224x168 -> edge pad 28 -> /127.5-1 -> NCHW，NPU 只吃 NHWC int8 8 通道分块；后处理：objectness sigmoid + 3x3 local-max、class softmax、top-k、类内 NMS、网格解码，均应留在 CPU（与 yolo 档一致，代价可忽略）。
- **[PASS] 原语层面大体可映射** —— 78 个卷积全部为 k=1/3、stride=1/2、pad=0/1（k=1 -> pad0，k=3 -> pad1），深度可分离卷积可用 depthwise flag；BN 全部可折叠（75 层）；激活全是 ReLU（可用 zp_out=-128 的 requant 表达，无 ReLU6/leaky）；无 pool；通道全部是 8 的倍数（仅 3 个 head 的 OC=1/4 需 padding 到 8）。
- **[PASS] op 条数不超 ROM 深度** —— NPU 口径 106 op（CSE 前 107），ROM 深度 128；条数不是瓶颈，瓶颈是权重/激活容量。
- **[INFO] 最后 3 个 head 是 linear 1x1 conv（无激活）** —— objectness/class/box 三个 1x1 conv 带 bias、无激活：引擎可用 M_neg=M_pos（CONTRACT §5『无 leaky 的层 M_neg=M_pos』）+ 覆盖负值的输出量化范围表达 linear，bias 走 Q 区 bias_adj；之后的 sigmoid / local-max / softmax / top-k / NMS 全部在 CPU。

## 5. 多分辨率激活估算与「96KB A 缓冲」结论

口径：保持网络结构与通道不变，输入尺寸 S 等比缩放所有空间尺寸（224->112->56->28->14->7 对应 S/2..S/32），激活字节按 NHWC 8 通道分块 H*W*C8；峰值 = 全网络所有中间张量（含输入张量）的最大单张量。**注意**：真实 96KB 判定还受 A/B 乒乓（单 op 需 src+dst 同时驻留）与 B=32KB 不等大限制。

| 输入 S | 全层峰值 B | 融合段峰值 B（不含 concat） | 融合段峰值 B（含 concat） | 输入 PACKED3 B | MACs | 全层 <=98,304? | 融合段 <=98,304? | 含 concat <=98,304? |
|---|---|---|---|---|---|---|---|---|
| 224 | 1,204,224 | 225,792 | 677,376 | 150,528 | 2,271,966,928 | **否** | 否 | 否 |
| 192 | 884,736 | 165,888 | 497,664 | 110,592 | 1,669,200,192 | **否** | 否 | 否 |
| 160 | 614,400 | 115,200 | 345,600 | 76,800 | 1,159,166,800 | **否** | 否 | 否 |
| 128 | 393,216 | 73,728 | 221,184 | 49,152 | 741,866,752 | **否** | 是 | 否 |
| 96 | 221,184 | 41,472 | 124,416 | 27,648 | 417,300,048 | **否** | 是 | 否 |
| 64 | 98,304 | 18,432 | 55,296 | 12,288 | 185,466,688 | 是 | 是 | 是 |

**结论**：
1. **严格按全层单张量口径：128/160/192 都塞不进 96KB**（128 峰值 393,216 B = A 的 4.0x；160 为 614,400 B；192 为 884,736 B）。解析阈值：全层峰值 <= 98,304 B（= 96KiB，正好是 A 的容量）需要 S <= 64.0，即 **64x64（峰值恰好 98,304 B）**。瓶颈是 stem 后 stage1/stage2 的全分辨率扩张张量（224 下 96ch x 112x112 = 1,204,224 B），不是 FPN。
2. **若只把 FPN+检测头段放进 A 缓冲（忽略 stem/扩张段）**：只有 **128 输入**满足 （72ch x 32x32 = 73,728 B <= 98,304 B）；160 为 115,200 B、192 为 165,888 B，均超。解析阈值 S <= 147.8。
3. **concat 单独再卡一刀**：3 路 56x56x72 -> 216ch 的张量在 224 下 677,376 B，即使 128 也要 221,184 B > 96KB（阈值 S <= 85.3）。若要保 concat 而不拆，需要把融合段降到 <= 84x84 量级。
4. **A/B 乒乓更严**：单 op 需 src+dst 同时驻留；224 下最大单 op 驻留 1,605,632 B（12.2x A+B=128KB）。即使 128 输入，融合段相邻两个 72ch 张量也要 2 x 73,728 = 147,456 B > 128KB（且 B 只有 32KB，放不下 32x32x72 张量），**必须做通道分块/部分和（conv add-mode）或降低头部分辨率**，否则连 128 也排不进 A/B。

### 5.1 A/B 贪心分配实测（乐观：add 原地、不拆通道）

| 输入 S | 全层最大单张量 B | 分配结果 | 失败点 | peak_A | peak_B | 备注 |
|---|---|---|---|---|---|---|
| 224 | 1,204,224 | **FAIL** | 输入张量 150528 B > A(98304 B) | 150,528 | 0 | 输入/首层就超 A |
| 192 | 884,736 | **FAIL** | 输入张量 110592 B > A(98304 B) | 110,592 | 0 |  |
| 160 | 614,400 | **FAIL** | op 0（backbone.stem.0，conv3x3） 输出张量 102400 B 放不进 A(98304B)/B(32768B) | 76,800 | 0 |  |
| 128 | 393,216 | **FAIL** | op 0（backbone.stem.0，conv3x3） 输出张量 65536 B 放不进 A(98304B)/B(32768B) | 49,152 | 0 |  |
| 96 | 221,184 | **FAIL** | op 1（backbone.stage1.0.block.0.0，conv1x1） 输出张量 147456 B 放不进 A(98304B)/… | 64,512 | 0 |  |
| 64 | 98,304 | **FAIL** | op 2（backbone.stage1.0.block.1.0，dwconv3x3） 输出张量 65536 B 放不进 A(98304B)… | 65,536 | 16,384 |  |

> 分配器口径与 `tools/yolo/darknet_lib.allocate` 同思路（生命周期 + A/B 两区贪心），但未建模通道分块/tile；因此 FAIL 表示「按整张量放不可能」，OK 也只是必要条件。

**为什么连 64x64 也 FAIL**：A/B 不等大（96KB + 32KB）。64x64 时 stage1 的扩张张量 64ch x 32x32 = 65,536 B，相邻两个这样的张量需要 2 x 65,536 = 131,072 B，恰好等于 A+B 总容量，但 B 只有 32,768 B、放不下任何 65,536 B 张量 ⇒ 单 op 的 src/dst 无法分置两区。也就是说：**在现有 A/B 划分下，即使 64x64 输入也必须做通道分块（把 64ch 拆成 8/16 通道块）才能排进缓冲**；128/160/192 则需要同时解决通道分块与 96KB 上限。

## 6. 浮点精度基线实测（复跑文档指标）

口径（与 `nut_detector/evaluate_multi_mobilenet_anchor_free.py` 完全一致）：预处理 320x240 RGB -> bilinear 224x168 -> 上下 edge pad 28 -> `/127.5-1` -> NCHW；解码 `decode_multi_predictions`：sigmoid objectness x 3x3 local-max x softmax 类概率，pre-NMS top-40、置信度 0.20、类内 NMS IoU 0.35、最多 4 个；匹配：类内贪心、IoU>=0.5。

| 指标 | 文档声称 | 本机实测（CPU） | 差值 |
|---|---|---|---|
| 测试图片 | 500 | 500 | 0 |
| 目标数 | 1250 | 1250 | 0 |
| TP | 1250 | 1250 | 0 |
| FP | 0 | 0 | 0 |
| FN | 0 | 0 | 0 |
| Precision | 1.0 | 1.000000 | 0.00e+00 |
| Recall | 1.0 | 1.000000 | 0.00e+00 |
| F1 | 1.0 | 1.000000 | 0.00e+00 |
| mean matched IoU | 0.969592 | 0.969591 | -8.35e-07 |
| 目标数量准确率 | 1.0 | 1.000000 | 0.00e+00 |
| 整图全对率 | 1.0 | 1.000000 | 0.00e+00 |

**与文档一致性：True**（差值全部在浮点/阈值容差内；CPU 500 张耗时 30.3 s，纯 CPU 可复现）。

按目标数分组：

| 真实目标数 | 图片数 | Precision | Recall | F1 | 整图全对率 |
|---|---|---|---|---|---|
| 1 | 125 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| 2 | 125 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| 3 | 125 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| 4 | 125 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |

按类别分组：

| 类别 | 真实数 | 预测数 | 匹配数 | Precision | Recall |
|---|---|---|---|---|---|
| red_cap | 313 | 313 | 313 | 1.0000 | 1.0000 |
| purple_cap | 313 | 313 | 313 | 1.0000 | 1.0000 |
| green_cap | 312 | 312 | 312 | 1.0000 | 1.0000 |
| yellow_cap | 312 | 312 | 312 | 1.0000 | 1.0000 |

### 6.1 独立交叉复核：直接运行 nut_detector 自带评估脚本（强制 CPU）

产物：`results/bottlecap/model/eval_packaged/`（test_predictions.csv, test_preview.jpg, test_report.json）。这条路径用的是**未折叠 BN 的原始模型**和打包脚本自己的 batch/评测循环，用来独立验证 §6 的基线不是本脚本实现偏差。

| 指标 | 本脚本基线（折叠 BN） | 打包脚本复跑 | 差值 |
|---|---|---|---|
| TP | 1250 | 1250 | 0 |
| FP | 0 | 0 | 0 |
| FN | 0 | 0 | 0 |
| Precision | 1.000000 | 1.000000 | +0.00e+00 |
| Recall | 1.000000 | 1.000000 | +0.00e+00 |
| F1 | 1.000000 | 1.000000 | +0.00e+00 |
| mean matched IoU | 0.969591 | 0.969592 | +8.61e-07 |
| 整图全对率 | 1.000000 | 1.000000 | +0.00e+00 |
| checkpoint epoch | - | 13 | - |

→ 两个独立实现的整数指标完全一致、mIoU 差 8.61e-07，**文档指标复现成立**。

### 6.2 GPU 复核（仅交叉验证，不作为可复现基线）

- GPU：NVIDIA GeForce RTX 5070 Ti Laptop GPU；与 CPU 指标一致（容差 1e-4）：**True**；逐图预测数一致：True；原始输出 max|ΔCPU-GPU| = 5.543e-06（已关 TF32；GPU 5.9 s）。

## 7. 对 NPU 落地的直接建议（数据驱动）

1. **权重是第一位瓶颈**：int8 2,020,960 B 是 W 320KB 的 6.2x。要么 DDR3 流式权重（W 只做当前层 cache），要么换 ~300KB 量级的子网/剪枝+蒸馏，否则「2M 参数整模型上 96KB A + 320KB W」不成立。
2. **算力也不小**：2.27 GMAC @224，其中检测头 56x56x72 段占 84%。若必须上现有 NPU，先把 head/FPN 从 stride-4（56x56）降到 stride-8（28x28），MACs 约降到 ~0.85 GMAC。
3. **结构上最硬的坎**：22 个 conv 的 IC>256（另有 22 个 OC>256），以及 5 处 add 后 ReLU。前者需要引擎支持 conv add-mode + 通道偏移（当前都未实现），后者需要新原语或 CPU 执行；这两项不是「改量化参数」能绕过的。
4. **如果只是想验证流程**：把输入降到 128 且只把 FPN+头段放 A，需要同时（a）拆 channel 到 <=256 的块、（b）消除 concat 的 216ch dst（改成 3 个 72ch 局部和 + add）、（c）stem/扩张段另行 tile。工作量接近重写部署图，不如先做「int8 子网 + 28x28 头」的新模型。

## 8. 复现

```powershell
cd D:\USER\Desktop\FPGA\FPGA
python tools/bottlecap/profile_model.py                 # 画像 + CPU 精度基线 + GPU/打包脚本双复核
python tools/bottlecap/profile_model.py --no-gpu-check   # 不用 GPU
python tools/bottlecap/profile_model.py --no-packaged-eval  # 不额外跑打包评估脚本
python tools/bottlecap/profile_model.py --skip-eval      # 只画像
```

产物：`results\bottlecap\model\model_profile.json`（逐层表 + 全部汇总，机器可读）、`results\bottlecap\model\MODEL-PROFILE.md`（本文，脚本自动生成）。

