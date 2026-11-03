# E2E-HANDOFF — slim 模型 ModelSim 端到端（71 op，96×96，纯片上）

> 模型: `results/bottlecap/slim/best_model.pt` (arch=slim, input=96, params=136321)  
> checkpoint sha256: `7a1417e02f998823c85ee5f4336d89d9bf19e12ec3d100c59cf9d8d6c4b47f9e`（FINAL.json 里为权威记录）  
> 判定：MODE_AUTO 跑完 71 op 后逐 op checksum 对 `checksums.txt`，`hw_bad=0`；head 值对 `opvec/` 字节金标（如需）。

## ① 运行 E2E 需要的输入文件（全部由 `gen_npu_artifacts.py` 生成）

| 文件 | 说明 |
|---|---|
| `slim_plan.h` | tools/nn_gen_sw.py 生成（`--guard SLIM_PLAN_H`），C 侧 op 表；与 sw/ 一起编进 imem/dmem 镜像 |
| `nn_rom_pkg_slim.sv` | tools/nn_gen_rom.py 生成的微码 ROM 包，替换/并列 `nn_rom_pkg.sv`（由 Lead 决定 E2E 构建用哪个，**勿覆盖 YOLO 的包**） |
| `w.hex` / `q.hex` | W=130448 B / Q=22784 B，§6/§7 布局（32-bit 小端字/行）。**nn_mem 装载用分开的 `+nnw`/`+nnq`（自适应行数，slim: W 16,306×64b、Q 2,848×64b）——已实测正确** |
| `slim_wq.hex` | W||Q 合并的 32-bit 镜像，38308 行（= (130448+22784)/4）。**仅供 DDR3 镜像/参考**；`+nnwq` 通道按 YOLO 固定行数拆分，**不适合 slim，勿用于 nn_mem 初始化** |
| `checksums.txt` | 输入 + 逐 op FNV-1a（真实通道×H×W，NHWC y,x,c；opvec/index.json 为逐 op 字节金标） |

**W/Q 合并镜像命令（已由本脚本在 `--emit-wq-merged` 执行，可复现）**：
```powershell
# w.hex/q.hex 都是 32-bit little-endian 字/行；逐行拼接即为 W||Q 连续镜像
Get-Content w.hex, q.hex | Set-Content slim_wq.hex
# 校验行数（必须 = (W+Q)/4 = 38308）
(Get-Content slim_wq.hex).Count
```

## ② 输入图（conv0 PACKED3，96×96×3）—— E2E 用真实图

**首选（真实检测图）**：`opvec/<img>/input.hex`（E2E 用 8 张参考图之一，建议 img=0349）—— 96×72 letterbox + 上下 12 行 edge pad，`/127.5-1` 后按 plan 的 s_in/zp_in 量化为 int8 PACKED3，格式 = u32-LE words/行（6,912 行 = 27,648 B）。复制为仿真输入：
```powershell
Copy-Item opvec/0349/input.hex ..\..\..\sim\prog\slim\input_96.hex
# 或：1 字节/行 compact 版（便于 TB 逐像素比对）
Copy-Item opvec/0349/input_compact.hex ..\..\..\sim\prog\slim\input_96_compact.hex
```
（`input_compact.hex` = 每行 1 字节 2-hex 的 y,x,c 逻辑序 PACKED3，27,648 字节。）

**备选（合成图，仅协议回归）**：`q[y][x][c] = int8((x*13 + y*7 + c*29 + seed) & 0xFF)`，seed=12345，存 packed 3B/像素(y-major,x,c)，A 区 offset=0；该图对应 `checksums.txt`（plan/ROM 的 debug csum 就是它）。**真实检测精度必须用首选真实图**。

## ③ 逐 op checksum / 金标位置（判 hw_bad=0）

- **真实图（E2E 判据）**：`opvec/0349/checksums.txt`（71 op 逐 op FNV，真实通道×H×W、NHWC y,x,c 逻辑序；input FNV 同文件首行）+ `opvec/0349/op*.hex`（整块 int8 字节，u32-LE，NHWC pad8 含 pad 字节）。
- `checksums.txt`：pattern_v1 输入的逐 op FNV（ROM debug csum / MODE_AUTO 同源）。
- `opvec/manifest.json` / `opvec/index.json`：逐 op shape/bytes/fnv/arena_off 索引。

## ④ 期望 npu_cycles（v3 公式，**与 ModelSim 实测逐拍一致**）

- 合计 = **799520 拍**（= `results/ai-accel/proto/engine/calc_cycles_v3.py` 口径逐 op 求和；MODE_CPU 逐 op CYCLES 之和 = MODE_AUTO CYCLES = 该值，已实测 0 delta）
- 分 kind：conv=447935, dwconv=294042, add=49959, upsample=7584, copy=0, pool=0。
- 100MHz ≈ 8.00 ms / 122MHz ≈ 6.55 ms / 150MHz ≈ 5.33 ms（=125.08/152.59 fbs）。
- band 级启动固定开销（v2 tile，total_bands=122）≈ 6100~12200 拍/帧（相对上述总数 <0.2%）。

## ⑤ 与现有 tb_sw_nn_yolo / tb_sw.sv 的差异点

1. plan 只有 **71 op**（YOLO 112）；ROM 深度 71，`nn_rom_pkg_slim.sv` 与 YOLO 包二选一。
2. 输入 **96×96 PACKED3**（YOLO 128/320 同口径，但尺寸不同；A 区 offset=0）。
3. 激活只走 **A/B 两个 bank（real 分配）**：A 峰值 92160/98304 B、B 峰值 23040/32768 B；src/dst 为 A/B 窗口相对偏移（plan 里另有 arena 绝对口径字段，E2E 不需要）。
4. flags v0.8：per-op 显式 `act="relu"/"none"` + plan flags bit4（生成器映射到 nn_pkg bit7 RELU）；ADD_R 11 个、全部 per-tensor R≤65535。
5. 无 concat/copy op（YOLO 有 6 copy）；upsample 3 个（2x, ic==oc）；pool 0 个。
6. 与 `tb_sw_nn_yolo` 相同的是 MMIO 描述符逐 op 下发接口（MODE_CPU 回归）与 MODE_AUTO ROM 自主执行；不同点仅为上述 op/形状/ROM 内容，故 E2E 构建只需换 sw 头 + ROM 包 + plan 输入尺寸。

## ⑥ 产物 sha256（权威记录见 FINAL.json）

- `graph.json`  71bed9a9151718aa
- `quant_report.json`  06efbffc9a6b2dcf
- `plan.json`  275faf4672aec9e3
- `model.json`  e4694035d9c71eac
- `nn_rom_table.json`  718874cf39f37981
- `w.hex`  06bb5d116f595385
- `q.hex`  a68da99ba9cf7b32
- `checksums.txt`  48ec4fa45538d2c1
- `DEPLOY-CHECK.json`  b246ca2160b120e2
- `band_plan.json`  e6bacd6e271e155d
- `slim_wq.hex`  7ddbe6e1e482e380
- `nn_rom_pkg_slim.sv`  beee6738076289c6
- `slim_plan.h`  ae6ae75629dd7d28
- `opvec/manifest.json`  635826997ebe8ff0
- `opvec/index.json`  5f484387c99dbc1a
- `GOLDEN-REPORT-SLIM.md`  d58f2693d4cc8de2
- `e2e_metrics.json`  be6adbe733169218

## ⑦ 给 M6a / npu-spec 的口径确认（照抄即可，勿猜）

**(a) 逐 op FNV 计算口径（与 opvec/0349/checksums.txt 完全一致）**：
```python
h = 2166136261
for byte_in_arr_compact:           # 只遍历「真实通道」的 y,x,c 逻辑序
    h ^= byte & 0xFF; h = (h * 16777619) & 0xFFFFFFFF
# 即：arr = op 输出张量 (H,W,C8) int8; for y in range(H): for x in range(W):
#       for c in range(real_C): fnv ^= arr[y,x,c]   # 不含 c>=real_C 的 pad 字节
# 输入图 FNV: 对 PACKED3 的 y,x,c(c<3) 逻辑序逐字节(a_q 已量化 int8)
```
（和 CONTRACT §10 / checksums.txt 同一口径；`opvec/<img>/checksums.txt` 已按此生成。）

**(b) 输入图 `opvec/0349/input.hex` 加载方式（二选一，均与金标等价）**：
- 方式1（与 YOLO 相同的 `+pattern` 位置改为文件装载）：把 `input.hex` 按 u32 小端逐行解析为 27,648 字节，写入 NN 窗口 A 区偏移 `plan.input.act_off`（=0）开始的 27,648 B；不做任何反量化（这些字节就是 conv0 要读的 a_q）。
- 方式2（固件按 PACKED3 写）：固件自己从 `input_compact.hex`/原始图量化时，必须用 plan 的 `input.s_in/zp_in`（不是固定 2/255），按 `a_q = clip(round(x/s_in)+zp_in, -128,127)` 写 `addr = y*iw*3 + x*3 + c`。
- conv0 读取：engine PACKED3，`iw=96`，行步长 288 B，pad=1 → 边界行填 `zp_in`。
