# Model Freeze · `model-yolofastest-v1.1-coco-int8`

> 决策时间：2026-11-01（Lead + 用户确认）。本文件是**唯一冻结记录**：一旦冻结，模型/权重/层序列不再变更；
> 后续所有硬件特化（微码 ROM、权重硬布局、conv0/add 专用块、DDR3 调度）都以本文件的参数为准。
> 变更冻结内容 = 新版本号（v1.1-coco-int8-r2），必须重跑全量 E2E 与精度评测。

## 0. 决策记录（用户 2026-11-01 拍板）

| # | 决策 | 内容 |
|---|---|---|
| D1 | 最终分辨率 | **320×320 为最终验收分辨率**；128×128 仅作 bring-up 与回归档（两者共用同一套权重） |
| D2 | DDR3 用途 | **两用**：① 摄像头/显示的视频帧缓冲 ② 320 输入的中间激活张量（权重不进 DDR3） |
| D3 | 性能目标 | 320 输入下 **≥30fps**（勉强流畅即可）→ 选 **128 MAC/拍**双阵列方案（16 OC lanes × 8 像素） |
| D4 | 主频要求 | NPU 特化后全实现 **≥100MHz**；最终越高越好；**硬下限 50MHz**（实在不行才接受，需显式记录） |
| D5 | 形态定位 | 最终交付是**完整作品**：摄像头采集 → NPU 识别 → TFT/HDMI 显示；不追求通用性，允许针对本模型/权重做硬件特化 |

## 1. 冻结对象

| 项 | 冻结值 | 校验 |
|---|---|---|
| 模型 | YOLO-Fastest v1.1（darknet），COCO 80 类，131 层（84 conv、28 depthwise、18 shortcut、3 maxpool、5 route、18 dropout、2 yolo）| `tools/yolo/convert_yolo_fastest.py` 逐层参数个数与官方 weights 对齐 |
| 官方权重 | `yolo-fastest-1.1.weights`（1,384,268 B）| `data/float_check.json`：header major=0 minor=2 rev=5 seen=14231680 |
| 浮点复核 | PyTorch vs numpy float64 逐层 cos=1.0；BN 折叠 vs 未折叠 cos=1.0 | `data/float_check.json` |
| **int8 权重 payload** | **319,792 B**（≤320KB BRAM 预算）| `plan.json` 累计；`yolo_wq.hex` 权重部分 |
| **权重镜像** | `sim/prog/yolo/yolo_wq.hex`，**94,208 行 × 32-bit**（368KB = W 320KB + Q 48KB）| sha256 `8f8f8027…`（见下表） |
| 量化方案 | per-OC 对称权重、per-tensor 非对称激活、BN 折叠、int16 M_pos + 每层 SHIFT、floor 右移、M_neg 现算 | `CONTRACT.md` §5 |
| 层序列 | 108 个 op：conv 55 / dwconv 28 / maxpool 3 / upsample 1 / cpu_add 18 / cpu_concat 2 / cpu_conv0 1 | `plan.json` sha256 `5874fc41…` |

> 注意：**权重与输入分辨率无关**；320 档只需要按 320 校准的激活量化参数（Q 区）。因此"权重冻结"在两种分辨率下都成立。

## 2. 冻结文件哈希（sha256 前缀，完整值见 `checksums.txt`）

| 文件 | 大小 | sha256 前缀 |
|---|---|---|
| `sim/prog/yolo/plan.json` | 36,843 B | `5874fc4117cad642` |
| `sim/prog/yolo/yolo_wq.hex` | 847,872 B / 94,208 行 | `8f8f802722f727a5` |
| `sim/prog/yolo/checksums.txt` | 5,079 B | `f30d6b4875e6a3f0` |
| `sim/prog/yolo/model.json` | 30,177 B | `0acef62e53089d86` |

## 3. 两个部署配置（共用同一套权重）

| 配置 | 输入 | 激活峰值 | 存储 | 用途 | 精度口径 |
|---|---|---|---|---|---|
| **C128（bring-up/回归）** | 128×128 | A 98,304 B / B 32,768 B（片上）| 全部片上 | 逐位精确 E2E、RTL 回归、双模对照 | int8 vs float 框匹配 81.8%（已测）|
| **C320（最终交付）** | 320×320 | A≈614,400 B（**必须 DDR3**）| 权重 BRAM + 激活 DDR3 + tile 缓存 BRAM | 完整作品（摄像头→NPU→显示）| 官方口径：COCO mAP@0.5 ≈ 23.65（v1 系列官方值，320 输入）|

C320 的 Q 参数需**按 320 重新校准**（`quantize.py --hw 320` → 新 Q 区），权重字节不变。C320 的 E2E 验证靠"320 golden + 板上逐 op checksum（可选 demo 模式外）"。

## 4. 硬件特化清单（冻结后允许硬编码的东西）

1. **层序列/参数 ROM**（~1.7KB LUTRAM）：108 op 的 kind、输入/输出张量、权重/Q 偏移、尺寸、stride/pad、M/SHIFT/zp；
2. **权重硬布局**：按层顺序展开、按 PE 加载顺序重排，烧入 80 块 BRAM（320KB），地址=计数器递增；
3. **Q 区 48KB → 分布式 RAM（LUTRAM）**，释放 12 块 BRAM；
4. **conv0 专用块**：packed 3B/像素输入 → 64×64×8 int8 输出，固定权重/Q，硬件直算（消灭 CPU conv0）；
5. **shortcut add 专用块**：per-tensor R 的 residual add（精度方案 v0.5 的硬件化），消灭 CPU add；
6. **copy/route 用引擎现有 copy 通路**（8 通道粒度），消灭 CPU concat；
7. CPU 只保留：相机帧写入/读取、NMS/画框、显示调度；推理期间 CPU 可并行做别的事（调度解耦）。

## 5. 性能/时序目标（验收线）

| 指标 | 目标 | 依据 |
|---|---|---|
| 320 帧率 | **≥30 fps** = 每帧 ≤33.3 ms | 125.44M MACs × 30fps = 3.76 GMAC/s；128 MAC/拍 @100MHz 峰值 12.8 GMAC/s，需 30% 效率 |
| NPU 主频（全实现） | **≥100MHz**（硬下限 50MHz，若触发须记录原因）| D4 |
| 引擎流水 | 128 MAC/拍（16 OC lanes × 8 像素），输出 128-bit/拍写回 | D3 |
| 资源 | 引擎 ≤ 25K LUT / ≤110 DSP / BRAM 0；整机 BRAM ≤ 121.5/135（Q 迁 LUTRAM 后）| 现有 25.2K LUT 全机预算 + 视频链路 |

## 6. 验证策略（不可省）

1. **双模对照**：同一硬件保留"CPU 逐 op 驱动"（现有 v0.5 模式）与"自主微码"（v0.7 新模式）两种执行方式，同一份 128 plan 各跑一遍，**逐 op checksum 必须相同**；
2. **golden 位精确**：新模式对 golden checksums `hw_bad=0`；
3. **精度**：C128 相对浮点 81.8% 保持；C320 出 320 精度数据（不劣于 CPU 参考实现）；
4. **时序**：OOC WNS ≥ +1.0ns @100MHz；全实现 `BUILD_TIMING=PASS` @≥100MHz；
5. **交付档不变**：无 `NN_EN` 时 LUT 3098 / FF 1447 / BRAM 9 / DSP 8 / fmax 150.2 逐项不变。
