# tools/yolo — YOLO-Fastest v1.1 → PyTorch → int8 PTQ → numpy golden → 全硬件 plan / 微码 ROM

本目录把官方 **YOLO-Fastest v1.1**（darknet cfg + 1384268 B `.weights`，COCO 80 类，
0.315M 参数）完整落地为 AI 加速子系统可用的交付物。契约见
`results/ai-accel/CONTRACT.md`（v0.7）、`MODEL-FREEZE.md`、`SPEC-SPECIALIZED.md`；
完整实测数据见 `results/ai-accel/model-report.md`。

所有脚本都用绝对可复现的命令 + 机器判据（cos / mismatch / checksum / IoU），
不接受"看起来对"。

## 0. 产物一览

| 文件 | 说明 |
|---|---|
| `darknet_lib.py` | cfg 解析 + 权重读取（含 20B darknet 头）+ BN 折叠 + plan v0.6/0.7（PACKED3/ADD_R/copy）+ AB 分配 + 浮点参考 + MAC 统计 |
| `detect_lib.py` | letterbox 预处理 + darknet yolo decode/NMS/IoU + `pattern_v1` 确定性输入图 |
| `quant_lib.py` | int8 PTQ（CONTRACT §5）+ 向量化整数参考前向 + 独立整数 golden 前向（PACKED3/ADD_R/copy 精确语义） |
| `vec_io.py` | `.hex` 读写 + FNV-1a 32 |
| `download_assets.py` | 下载官方 cfg/weights + 样例图片（尺寸校验与重试） |
| `convert_yolo_fastest.py` | **① 浮点落地**：解析/加载/校验官方权重 → `data/model_float.pt` + 证据 JSON |
| `quantize.py` | **② int8 PTQ** → `data/model_int8_<hw>.npz` + 逐层 cos/maxerr 自检 |
| `golden.py` | **③ 全整数 golden**（独立实现），与 quantize 的向量化整数前向逐位一致（mismatch=0） |
| `make_vectors.py` | **④ 集成向量**：`plan.json` / `model.json` / `yolo_w.hex` / `yolo_q.hex` / `yolo_wq.hex`(存档) / `checksums.txt` / `l*_*.hex` |
| `gen_rom_table.py` | **⑤ 微码 ROM 数据源**：plan.json → `nn_rom_table.json`（SPEC §1 字段） |
| `vector_manifest.json` | 代表层 replay 向量清单：9 个 op 的 `l{op_id}` ↔ plan op_id/kind/layer、in/out 形状与布局、文件格式、w/q 格式 |
| `gen_arena_map.py` | **P3 模型侧数据**：C320 DDR3 激活 arena 地址/张量表（`sim/prog/yolo320/arena_map.json`）+ conv0 流式 band + 流量/ROM 位宽分析 |
| `gen_vector_manifest.py` | **代表层 replay 清单**：`sim/prog/yolo/vector_manifest.json`（l{op_id} ↔ plan op / 形状 / 布局 / 文件格式，供 t-accel 生成 vec/ replay）|
| `evaluate.py` | 端到端 float vs int8 检测框对比（IoU 匹配率） |
| `analyze_ceiling.py` | 量化方案精度天花板诊断（floor/round/QDQ 理想模型对照） |
| `apples_to_apples.py` | 同 case/同 seed 的 Round-1（重建）vs Round-2 对照 + cpu_add fp32 回归检查 |
| `gen_report.py` | 生成 `results/ai-accel/model-report.md` |

## 1. 准备（一次性）

```powershell
python tools/yolo/download_assets.py
```

- cfg 9685 B / weights 1384268 B（= 346062 floats × 4 + **20 B darknet 头**：
  `major=0 minor=2 revision=5 seen=14231680`）。尺寸不符直接报错。
- 样例图片在 `tools/yolo/data/images/`（bus/dog/fruits/home/horses 5 张真实图）。

## 2. 浮点落地与自检（①）

```powershell
python tools/yolo/convert_yolo_fastest.py
```

判据：`.weights` 逐层参数个数精确对齐；BN var>0；BN 折叠 cos=1.0；
PyTorch vs 独立 numpy float64 逐层 cos=1.0000000000；dog.jpg@320 检出 dog 0.625 / bicycle 0.594。

## 3. int8 PTQ（②）

```powershell
python tools/yolo/quantize.py --hw 128 --augment-calib 7
python tools/yolo/quantize.py --hw 320 --augment-calib 7   # C320（只重算 Q 区，W 不变）
```

- per-OC 对称权重、per-tensor 非对称激活（`zp_a=-128-round(min/s_a)`）、int16 M_pos + 每层 SHIFT、
  floor requant、conv 边界填 `zp_in`；
- **ADD_R（18 个 shortcut，取代 cpu_add）**：Q 块 16 B（v0.7 口径）：
  `[0]=zp_s [1]=zp_d(debug) [2:3]=R(u16 LE) [4]=KADD [5:15]=0`；
  `out = clamp(q_d + (((q_s-zp_s)*R)>>KADD), -128,127)`（int64 中间、floor）。18 个 R∈[4249,41736]；
- **PACKED3（conv0）**：输入 packed 3B/像素，权重仍 dense IC_pad=8（后 5 个 IC=0）；
- 激活组：pool/upsample/copy 两侧共享 (s_a,zp_a)（copy 不做 requant），add 两侧独立；
- Q 区：84 个 conv 块 44,256 B（偏移 0..44,255，与 v0.5 相同）+ 18 个 ADD_R 块 288 B
  （偏移 44,256..44,543），共 **44,544 B ≤ 48 KB**；**qoff 为 Q 区相对偏移**；
- A/B 分配：128 档 A 峰值 98,304 B / B 32,768 B（布局 A=0x60000/96KB、B=0x78000/32KB）。

## 4. 全整数 golden（③）

```powershell
python tools/yolo/golden.py --hw 128
```

`quant_lib.golden_forward` 与 `int8_forward` 是两份**独立实现**（per-channel 循环 + `np.floor_divide`
vs im2col matmul + 算术右移；copy 用 `np.copyto` 逐通道）。整数运算精确 ⇒ 必须逐位一致：

```
GOLDEN: PASS mismatch=0 maxdiff=0 pad_mismatch=0
```

## 5. 集成向量与微码 ROM 数据源（④⑤）

```powershell
python tools/yolo/make_vectors.py --hw 128
python tools/yolo/gen_rom_table.py --plan sim/prog/yolo/plan.json --out results/ai-accel/nn_rom_table.json

python tools/yolo/make_vectors.py --hw 320 --outdir sim/prog/yolo320 ^
    --buffer-a 4194304 --buffer-b 4194304 --a-base 0 --b-base 4194304 --no-vectors
python tools/yolo/gen_rom_table.py --plan sim/prog/yolo320/plan.json --out sim/prog/yolo320/nn_rom_table.json
python tools/yolo/gen_arena_map.py   # -> sim/prog/yolo320/arena_map.json（P3 arena 表）
python tools/yolo/gen_vector_manifest.py   # -> sim/prog/yolo/vector_manifest.json
```

输出（`sim/prog/yolo/`，C320 在 `sim/prog/yolo320/`）：

| 文件 | 内容 |
|---|---|
| `plan.json` | **112 个全硬件 ops**（conv 56 / dwconv 28 / add 18 / copy 6 / pool 3 / upsample 1，**0 个 CPU op**）：conv0=`conv`+PACKED3；shortcut=`add`+ADD_R；concat 展开成 6 个 `copy`；含 src/dst `{buf,off}`、`woff`(W 相对)、`qoff`(**Q 相对**)、每 op FNV `csum`、`final_ops`、`input.gen=pattern_v1(seed=12345)` |
| `model.json` | 层表（绝对 NN 窗口偏移）+ 校验和表；op code 0..5（conv/dwconv/pool/upsample/add/copy）|
| `yolo_w.hex` | **81,920 行** × 32 位小端字（W 320 KB；**与冻结 v0.5 W 区逐字节相同**，脚本 assert）|
| `yolo_q.hex` | **12,288 行** × 32 位小端字（Q 48 KB：84 conv 块 + 18 ADD_R 块）|
| `yolo_wq.hex` | 历史合并镜像（W\|\|Q，94,208 行），仅存档；v0.7 集成用 w/q 两个文件 |
| `checksums.txt` | 每 op 输出的 FNV；`copy` 的 csum 覆盖写入的通道切片，`concatL<layer>` 行为拼接完成后的完整目标 FNV |
| `l<op>_{in,w,q,out}.hex` | 代表层：conv0(PACKED3)、copy(concat)、conv1x1、dwconv3x3、dwconv5x5、pool9、add(ADD_R)、head_conv255、upsample |
| `nn_rom_table.json` | 微码 ROM 数据源：**112/128 条**，字段 kind/flags/pad/stride/icb/ocb/ih/iw/ohop/owop/woff/qoff/csum/aux0/aux1/src/dst；src/dst 为窗口绝对偏移（C128 A=0x60000、B=0x78000），woff W 相对，qoff Q 相对，aux0/aux1 = add 的 R/KADD 或 copy 的源/目标通道偏移 |

**W/Q 镜像硬保证**：`yolo_w.hex`（C128 与 C320）与冻结 v0.5 W 区逐字节相同；
`make_vectors.py` 内置回归断言：108 个输出（conv/dwconv/pool/upsample/add + concat 目标）
与冻结 v0.5 FNV **逐位相同**；golden mismatch=0（112 ops）。

## 6. 端到端精度

```powershell
python tools/yolo/evaluate.py --hw 128 --augment 9
python tools/yolo/evaluate.py --hw 320 --augment 9
python tools/yolo/analyze_ceiling.py --hw 128
```

**C128（bring-up）**：端到端框匹配 **81.8%**（45/55，IoU≥0.5，mean IoU 0.811）——与 v0.5 相同（数值未变）；
逐层 cos 与 v0.5 共享输出完全一致（均值 0.9742 / 最小 0.9174，108-op 口径）；
per-tensor int8 的可实现上限（理想 QDQ）为 0.9889/0.9670 ⇒ ≥0.99 判据本身不可达（见 model-report §6）。
**C320（最终验收，D1）**：端到端框匹配 **73.1%**（38/52，mean IoU 0.843），与 v0.5 CPU 版 320 逐位一致；
320 中间激活按 MODEL-FREEZE D2 放 DDR3（分配器 4MB 虚拟 arena：peak A/B = 768,000/204,800 B）。

## 7. 复现全链（从零，约 2 分钟）

```powershell
python tools/yolo/download_assets.py
python tools/yolo/convert_yolo_fastest.py
python tools/yolo/quantize.py --hw 128 --augment-calib 7
python tools/yolo/golden.py --hw 128
python tools/yolo/make_vectors.py --hw 128
python tools/yolo/gen_rom_table.py --plan sim/prog/yolo/plan.json --out results/ai-accel/nn_rom_table.json
python tools/yolo/quantize.py --hw 320 --augment-calib 7
python tools/yolo/make_vectors.py --hw 320 --outdir sim/prog/yolo320 `
    --buffer-a 4194304 --buffer-b 4194304 --a-base 0 --b-base 4194304 --no-vectors
python tools/yolo/gen_rom_table.py --plan sim/prog/yolo320/plan.json --out sim/prog/yolo320/nn_rom_table.json
python tools/yolo/gen_arena_map.py   # -> sim/prog/yolo320/arena_map.json（P3 arena 表）
python tools/yolo/evaluate.py --hw 320 --augment 9
python tools/yolo/gen_report.py
```

所有随机量都用固定 seed / 确定性公式；`plan.json`/`checksums.txt`/`yolo_w.hex`/`yolo_q.hex`
重复运行逐字节一致。微码 ROM 由 Lead 的 `tools/nn_gen_rom.py` 消费 `plan.json` 生成 `nn_rom_pkg.sv`
（112 条 ROM 项，200-bit/项）。
