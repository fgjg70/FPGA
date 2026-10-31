# tools/yolo — YOLO-Fastest v1.1 → PyTorch → int8 PTQ → numpy golden → RTL vectors

本目录把官方 **YOLO-Fastest v1.1**（darknet cfg + 1384268 B `.weights`，COCO 80 类，
0.315M 参数）完整落地为 AI 加速子系统可用的交付物。契约见
`results/ai-accel/CONTRACT.md`（v0.3.1），方案见 `results/ai-accel/PLAN.md`。

所有脚本都用绝对可复现的命令 + 机器判据（cos / mismatch / checksum / IoU），
不接受"看起来对"。完整实测数据见 `results/ai-accel/model-report.md`。

## 0. 产物一览

| 文件 | 说明 |
|---|---|
| `darknet_lib.py` | cfg 解析 + 权重读取（含 20B darknet 头）+ BN 折叠 + 执行计划/AB 分配 + PyTorch/numpy 浮点前向 + MAC 统计 |
| `detect_lib.py` | letterbox 预处理 + darknet yolo decode/NMS/IoU + `pattern_v1` 确定性输入图 |
| `quant_lib.py` | int8 PTQ（CONTRACT §5 v0.3.1）+ 向量化整数参考前向 + 独立整数 golden 前向 + Q payload 生成 |
| `vec_io.py` | `.hex` 读写（CONTRACT §10）+ FNV-1a 32 |
| `download_assets.py` | 下载官方 cfg/weights + 样例图片（带尺寸校验与重试） |
| `convert_yolo_fastest.py` | **① 浮点落地**：解析/加载/校验官方权重 → `data/model_float.pt` + 证据 JSON |
| `quantize.py` | **② int8 PTQ** → `data/model_int8_<hw>.npz` + 逐层 cos/maxerr 自检 |
| `golden.py` | **③ 全整数 golden**（独立实现），与 quantize 的向量化整数前向逐位一致（mismatch=0） |
| `make_vectors.py` | **④ 集成向量**：`sim/prog/yolo/{plan.json,model.json,yolo_wq.hex,checksums.txt,l*_*.hex}` |
| `evaluate.py` | **⑤ 端到端** float vs int8 检测框对比（IoU 匹配率） |

## 1. 准备（一次性）

```powershell
python tools/yolo/download_assets.py
```

- cfg 9685 B / weights 1384268 B（= 346062 floats × 4 + **20 B darknet 头**：
  `major=0 minor=2 revision=5 seen=14231680`）。尺寸不符会直接报错。
- 样例图片在 `tools/yolo/data/images/`（本机网络限制，实际只抓到少量真实图；
  `evaluate.py --augment N` 会生成确定性增广 case 补足 10 个）。

## 2. 浮点落地与自检（①）

```powershell
python tools/yolo/convert_yolo_fastest.py
```

判据（全部内置 assert / 打印）：
- `.weights` 逐层参数个数与 cfg 精确相等（346062 floats，文件字节数对上）；
- BN var 全 > 0，权重/BN 数值抽查正常；
- BN 折叠 vs 未折叠逐层 `cos = 1.0000000000`（max abs diff 1.45e-4，float32 噪声）；
- PyTorch 前向 vs 独立 numpy float64 前向：逐层 `cos = 1.0000000000`（131 层）；
- 官方 320 输入 dog.jpg 检测出 dog(COCO 16) score 0.625 / bicycle 0.594 / car 0.499。

产物：`data/model_float.pt`（folded + raw state dict + 层表 + 4 分辨率 MAC/存储表）、
`data/float_check.json`。

## 3. int8 PTQ（②）

```powershell
python tools/yolo/quantize.py --hw 128 --augment-calib 9
```

- 严格按 CONTRACT v0.3.1 §5：per-OC 对称权重、per-tensor 非对称激活、
  `zp_a = -128 - round(min/s_a)`、`M_pos = round(s_a_in*s_w/s_a_out * 2**SHIFT)`、
  `M_neg = (M_pos*3277+16384)>>15`、requant `floor`、conv 边界填 `zp_in`；
- **每层独立 SHIFT**（tail[3]）：取使 `M_pos` 落在 int16 内的最大 SHIFT（16..24），
  把 M 的整数舍入误差压到 <1e-3（v0.3.1 允许）；
- Q payload（v0.3.1）：`bias_adj int32[OC_pad] | M_pos int16[OC_pad] | tail 16B`
  = `6*OC_pad+16` B，**84 层合计 44,256 B ≤ 48 KB Q 区**；qoff 变长（16B 对齐）；
- A/B 分配：`allocate()` 按张量生命周期做区间分配（输入 packed 3B/像素放 A@0，
  op0=cpu_conv0 在 B，长寿命残差张量优先 B……），128 输入实测
  **A 峰值 98,304 B / B 峰值 32,768 B**，因此布局用 **A=0x60000(96KB)、B=0x78000(32KB)**
  （仍恰好占满 0x80000=512KB 窗口；BRAM36 数量与 64K+64K 相同）。

产物：`data/model_int8_<hw>.npz`、`data/quant_summary_<hw>.json`。

## 4. 全整数 golden（③）

```powershell
python tools/yolo/golden.py --hw 128
```

`quant_lib.golden_forward` 与 `int8_forward` 是两份**独立实现**（前者按 ic/oc 标量循环 +
`np.floor_divide`，后者 im2col matmul + 算术右移）。整数运算精确 ⇒ 必须逐位一致：

```
GOLDEN: PASS mismatch=0 maxdiff=0 pad_mismatch=0
input pattern_v1 checksum = 0xcfd271c5
```

## 5. 集成向量（④）

```powershell
python tools/yolo/make_vectors.py --hw 128
```

输出到 `sim/prog/yolo/`：

| 文件 | 内容 |
|---|---|
| `plan.json` | 108 个原语 ops（`conv/dwconv/pool/upsample/add/cpu_concat/cpu_conv0`），src/dst `{buf,off}`、`woff/qoff`、每 op FNV-1a `csum`、`final_ops=[100,107]`、`input.gen=pattern_v1(seed=12345)` |
| `model.json` | §10 层表（绝对 NN 窗口偏移：A=0x60000/B=0x78000；w_off/q_off 绝对偏移）+ 校验和表 |
| `yolo_wq.hex` | **94,208 行** × 32 位小端字（368 KB WQ 平面：W 319,792 B ≤320 KB + Q 44,256 B ≤48 KB）；行数内置 assert |
| `checksums.txt` | 每个 op 输出真实通道 × H × W 的 FNV-1a + 输入图 checksum + 过滤器常量 |
| `l<op>_{in,w,q,out}.hex` | 代表层向量：op0 `cpu_conv0`、op70 `conv1x1`、op2 `dwconv3x3`、op96 `dwconv5x5`、op93 `pool9`、op7 `add`、op100 `head_conv255`、op101 `upsample` |
| `representative_layers.json` | 代表层 op id ↔ 类型标签 |

**checksum 口径**：`FNV-1a 32`，作用在"真实通道 × H × W、紧凑 NHWC 逻辑序
(y-major, x, c)"字节上，**不含通道 padding 字节**。输入图是 packed 3 字节/像素
（`q[y][x][c] = int8((x*13 + y*7 + c*29 + seed) & 0xFF)`），checksum 也按 packed 3ch 算。
`yolo_wq.hex` / `l*_q.hex` 都是 `b[4n] | b[4n+1]<<8 | ...` 的小端 32 位字打包。

## 6. 端到端精度（⑤）

```powershell
python tools/yolo/evaluate.py --hw 320 --augment 9   # float vs int8 框匹配
```

判据：类一致的框 IoU≥0.5 贪心匹配，`match_rate = matched / float_dets`。
实测（10 case = 真实图 + 确定性增广）：320 → 80.0%，160 → 81.2%，128 → 66.7%，
96 → 100%(仅 2 个框)。逐层 int8-vs-float cos：128 均值 0.976。**未达到
"逐层 cos≥0.99 / 端到端≥90%" 验收线**，根因与改进方向见 model-report §6。

## 7. 复现全链（从零）

```powershell
python tools/yolo/download_assets.py
python tools/yolo/convert_yolo_fastest.py
python tools/yolo/quantize.py --hw 128 --augment-calib 9
python tools/yolo/golden.py --hw 128
python tools/yolo/make_vectors.py --hw 128
python tools/yolo/evaluate.py --hw 320 --augment 9
```

约 1–2 分钟（不含下载）。所有随机量都用固定 seed / 确定性公式，重复运行逐字节一致
（`model_float.pt` 含 cfg/weights sha256，`plan.json`/`checksums.txt` 可对比）。
