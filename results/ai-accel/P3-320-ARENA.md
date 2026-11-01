# C320 DDR3 激活 Arena（模型侧数据组织 · P3 输入规格）

> 数据源：`sim/prog/yolo320/plan.json`（冻结，112 op 全硬件，sha256 前缀 `71745e5f…`）
> 机器可读表：`sim/prog/yolo320/arena_map.json`（95,313 B，sha256 前缀 `740c8d6a…`；
> 生成命令 `python tools/yolo/gen_arena_map.py`，默认 arena base = `0x0100_0000`）
> 适用：P3（D2 决策：320 档中间激活放 DDR3，BRAM 只做 tile 缓存）。本文只给**模型侧数据/规格**，
> 不含 RTL 实现；RTL 由 T-mem/T-accel 负责。

## 0. 口径与 DDR3 地址窗口

- **DDR3 arena 基址 = `0x0100_0000`（16 MB 偏移，1 MB 对齐，Lead 2026-11-01 拍板）**；
  预留窗口 `0x0100_0000 .. 0x011F_FFFF`（**2 MB**），实际使用 **0.819 MB（2.56× 余量）**；
  `0x0000_0000 .. 0x00FF_FFFF`（16 MB）留给视频帧缓冲，其余区域扩展；
- JSON 中所有 `arena_off` / `src_arena_off` / `dst_arena_off` / `conv0_streaming.bands` 的字节区间
  **均为 DDR3 绝对字节地址**（= `0x0100_0000 + 相对偏移`），16 B 对齐；
- 布局：紧凑 NHWC（每像素通道补到 8 的倍数，`pad8 = ceil(C/8)*8`），320 输入为 **PACKED3**
  （3 B/像素，不补通道）；
- 复用：静态生命周期打包（张量活跃区间 `[def_op, last_use]` 不重叠即可共享字节），
  张量按大小降序放在最低的不冲突 16 B 偏移 → **0 碎片**（arena 大小 == 生命周期最大并发）；
- 生成器先按 cfg 重建张量图，并**逐 op 断言与冻结 plan320 的 kind/flags/shape/woff/qoff/src/dst 完全一致**
  （`CROSS-CHECK: PASS`），因此表中的地址/大小不是估算。

## 1. Arena 汇总（`arena_map.json.summary` / `arena_usage`）

| 指标 | 实测值 | 说明 |
|---|---:|---|
| op 数 / 张量数 | 112 / 91 | 112 个全硬件 op；91 个唯一激活张量（含输入） |
| **DDR3 地址窗口** | **`0x0100_0000 .. 0x010C_7FFF`**（使用 819,200 B）| 预留到 `0x011F_FFFF`（2 MB）|
| 唯一张量总字节 | **7,077,600 B**（7.078 MB） | 全部张量首尾相接、不复用时的下界 |
| 不复用总字节 | **7,077,600 B** | 同上（每张量只存一份） |
| 生命周期最大并发 | **819,200 B**（0.819 MB） | 任一时刻同时存活的张量字节和（含 16B 对齐） |
| **可复用后最小 arena** | **819,200 B**（0.819 MB） | 静态打包实际占用；无碎片 |
| 单张量最大 | 614,400 B | `t8_conv_L9`（160×160×24ch）|
| 张量尺寸分布 | ≤16 KB: 23 个；≤32 KB: 40；≤64 KB: 60；≤128 KB: 67 | 91 个中绝大多数 ≤128 KB |
| 若按 op 双缓冲（不复用）| 15,246,400 B | 等于逐层 in+out 流量（见 §3），仅作对照 |

- 输入张量 `input_packed3` 占 **`0x0100_0000 .. 0x0104_B000`**（307,200 B）；`op0` 之后该区即可复用
  （输入只被 op0 读一次）。摄像头帧缓冲可在 16 MB 视频区独立存放，tile DMA 每帧把 320×320×3B
  写入 arena 基址，或按可配源地址在帧缓冲原地流式读取。

## 2. 320 输入与 conv0 流式读取（PACKED3）

- 输入：`320×320×3 B = 307,200 B`，位于 **`0x0100_0000`**，逐像素 3 B（R,G,B，无 C8 填充）；
- conv0：`k=3, stride=2, pad=1, oc=8` → 输出 160×160×8；按 **行 band（8 输出行/band）** 流式读取，
  共 **20 个 band**；band b 覆盖输出行 `[8b, 8b+8)`，需要输入行 `[16b−1, 16b+15]`（首/末 band 裁剪到 0..319）；
- 每行 320×3 = 960 B；band0 = 16 行 = **15,360 B**（顶部 pad 行被裁掉），其余 19 个 band = 17 行 = **16,320 B**；
  全部 band 读 **325,440 B**（= 输入大小 + 18,240 B 行 halo，+5.9%）；
- 相邻 band 共享 2 行 halo（可保留在 tile 缓存中；若在 BRAM 里保留 2 行，实际可只读 307,200 B）；
- 扫描顺序：输出行自上而下；band 内按 3 个 k-tap × 8 像素 lane，PACKED3 地址 `base + y*960 + x*3 + c`（c<3），
  lane 3..7 填 `zp_in`；水平方向 `x` 覆盖 `2*px−1 .. 2*px+1`；
- 每 band 的精确输入行区间/绝对字节区间在 `arena_map.json.conv0_streaming.bands`（20 条）。

| band | 输出行 | 输入行（裁剪后） | DDR3 绝对字节区间 | 字节 |
|---:|---|---|---|---:|
| 0 | 0–7 | 0–15 | `[0x0100_0000, 0x0100_3C00)` | 15,360 |
| 1 | 8–15 | 15–31 | `[0x0100_3840, 0x0100_7800)` | 16,320 |
| 2 | 16–23 | 31–47 | `[0x0100_7440, 0x0100_B400)` | 16,320 |
| 3 | 24–31 | 47–63 | `[0x0100_B040, 0x0100_F000)` | 16,320 |
| … | … | … | … | 16,320 |
| 19 | 152–159 | 303–319 | `[0x0104_7080, 0x0104_B000)` | 16,320 |

BRAM tile 缓存只需容纳「17 输入行」≈ 16,320 B（远小于 307,200 B 全图），因此 320 输入**不需要**整帧进片上。

> 注：上面的 tile 只覆盖 conv0 的输入侧；conv0 输出 160×160×8 = 204,800 B 写回 arena
> （`dst_arena_off = 0x0104_B000`）。

## 3. 逐层 in+out 流量（MB/帧）

口径：读写均按**紧凑 NHWC 语义字节**（不含 DDR 突发/ECC 开销）。
- conv/dwconv/pool/upsample：读输入张量 + 写输出张量；
- add（18 个，原地）：读 src + 读 dst + 写 dst（read-modify-write）；
- copy（6 个）：读源通道切片 + 写目标切片。

| kind | op 数 | read (MB) | write (MB) | total (MB) |
|---|---:|---:|---:|---:|
| conv | 56 | 3.756 | 4.285 | **8.041** |
| dwconv | 28 | 3.136 | 2.366 | **5.502** |
| add (ADD_R) | 18 | 0.995 | 0.498 | 1.493 |
| copy | 6 | 0.067 | 0.067 | 0.134 |
| upsample | 1 | 0.010 | 0.038 | 0.048 |
| pool | 3 | 0.014 | 0.014 | 0.029 |
| **合计** | **112** | **7.978** | **7.268** | **15.246 MB/帧** |

Top-8 流量 op：`op8 conv L9` 819,200 B；`op9 dwconv L10` 768,000 B；`op7 add L8` 614,400 B；
`op0 conv0` 512,000 B；`op1..6` 各 409,600 B。逐 op 明细见 `arena_map.json.ops[].traffic_read/write`
（交叉引用见 §6）。

**带宽（仅激活，30 fps）**：15.246 MB × 30 = **457.4 MB/s ≈ 0.457 GB/s**（读 239.4 / 写 218.0 MB/s）。
- DDR3-400（32-bit @400 MHz，理论 1.6 GB/s）→ 占用 **28.6%**；
- DDR3-800（有效 ~2.2 GB/s）→ **20.8%**；
- 再加视频侧：摄像头帧写 307,200 B + NPU 读输入 325,440 B（含 halo）+ 显示读（按 RGB565 640×480 ≈ 614,400 B）
  ≈ +1.25 MB/帧 → **≈ 494 MB/s @30fps**，仍在 1.6 GB/s 预算内（~31%）。
- 说明：tile 缓存**不会降低**该流量（每层读写各一次，已是最少），只有把 add 融进 conv、或把 concat 拷贝消除才可能再降；
  **15.246 MB/帧是 P3 带宽预算的模型侧下限**（T-mem 的带宽侧按此核对即可）。

## 4. C320 的 ROM 位宽（结论：**21-bit 字节地址**）

**Lead 2026-11-01 拍板：C320 用 21-bit byte address。** arena = 819,200 B（0.819 MB）：

| 方案 | 位宽/语义 | 覆盖 | 评价 |
|---|---|---:|---|
| 现状 | 19 bit byte | 524,288 B | 不够（arena 819,200 B）|
| 20 bit byte | 20 bit | 1,048,576 B | 刚好覆盖 1 MB，**无余量**（P3 后续扩分辨率/双缓冲会爆）|
| **21 bit byte（选定）** | **21 bit** | **2,097,152 B** | 预留 2 MB 窗口内 2.56× 余量；保持字节地址语义，nn_seq/tile DMA 无需 8B 粒度换算 |
| tile 摊平 | — | — | 1,854 tile > ROM 深度 128，**不可行** |

- 代价：`nn_rom_t` **200 → 208 bit**（src/dst 各 19→21），128 项只多 **128 B LUTRAM**；
- P3 开工时由 Lead 统一改 `nn_pkg.sv` + `tools/nn_gen_rom.py`，并重生成 C128/C320 两套 ROM；
  **C128 现有地址值（0x60000/0x78000 等 ≤0x7FFFF）在 21-bit 内不受影响**；
- 模型侧 `arena_map.json` 保留**字节偏移（绝对 = base + off）**，不再提供 8 B 粒度字段。

**tile/循环估算**（row band = 8 输出行，OC_LANES=16，copy 8 通道粒度；`arena_map.json.ops[].tile_est`）：

| kind | tile 数（全部 op 合计） |
|---|---:|
| conv | 970 |
| dwconv | 631 |
| add | 124 |
| copy | 93 |
| pool | 18 |
| upsample | 18 |
| **合计** | **1,854** |

- 最大单层 tile 数 = **48**（op111：head conv 20×20×255，3 band × 16 个 OC tile）；
- 结论：**ROM 仍按每 op 1 项（112 项）+ 内层循环**（row-band × OC-tile × IC-block）设计，tile 数只是循环次数，
  不是 ROM 深度；ROM 项只加宽 src/dst 字段即可（见上）。
- tile 缓存尺寸（供 T-mem）：最大输入 band **65,280 B**（op9：17 行×160×24ch），最大输出 band **40,960 B**
  （op111：8 行×20×256ch）；同层叠加 ≈106 KB，可放进 A 96KB+B 32KB（建议 64KB in / 48KB out，或拆小 OC tile）。

## 5. 320 精度复核（仍有效）

以下数字来自冻结的 C320 产物，本轮没有改动任何 plan/w/q/模型：
- **golden mismatch = 0**（112 op，含 PACKED3/ADD_R/copy；`make_vectors.py --hw 320` 内置断言，2026-11-01 实测）；
- 端到端 int8 vs float（`tools/yolo/data/eval_320.json`）：float 52 框，int8 77 框，**匹配 38 框 = 73.1%**
  （IoU≥0.5，**mean IoU 0.843**），与 v0.5 CPU 参考版 320 完全一致；
- 冻结 sha（前缀）：`yolo320/plan.json` `71745e5f…`、`yolo320/yolo_w.hex` `09ce6ffe…`（= C128 W，权重未变）、
  `yolo320/yolo_q.hex` `3386b084…`（Q 按 320 校准）、`arena_map.json` `740c8d6a…`（本次按 base/21-bit 重出）；
- 结论：**320 精度结论对 P3 集成仍然有效**；本 arena 表只改变"激活放哪里/地址多宽"，不改变任何 op 的数值/形状/顺序。

## 6. 复现与文件（JSON ↔ 报告交叉引用）

```powershell
python tools/yolo/gen_arena_map.py
#   默认 --arena-base 0x01000000
# -> sim/prog/yolo320/arena_map.json（95 KB, sha256 740c8d6a…）
```

`arena_map.json` 结构与报告对应关系：

| JSON 字段 | 内容 | 报告小节 |
|---|---|---|
| `arena_base` / `arena_usage` | DDR3 基址 0x0100_0000、使用区间/预留 2 MB/余量 | §0 / §1 |
| `summary` | 唯一张量/不复用/峰值并发/最小 arena/流量/tile 合计 | §1 / §3 / §4 |
| `rom_width` | 21-bit byte 地址结论、`nn_rom_t` 影响、tile 摊平不可行 | §4 |
| `conv0_streaming` | 输入位置、PACKED3 寻址、20 个 band（行/绝对字节区间/halo） | §2 |
| `tensors[91]` | `{tid,name,h,w,c,pad8,bytes,packed,arena_off,def_op,last_use}` | §1 / §6 |
| `ops[112].tensor_in/out` | 逐 op 输入/输出张量尺寸与字节 | §1 |
| `ops[].src_arena_off/dst_arena_off` | 逐 op DDR3 绝对地址（copy 已含通道偏移） | §1 / §2 |
| `ops[].traffic_read/write` | 逐 op 读/写流量 | §3 |
| `ops[].tile_est` | `row_band_rows/n_tiles/in_band_bytes/out_band_bytes` | §4 |
| `ops[].c_src/c_dst`（copy）、`in_place`（add） | copy 通道偏移 / add 原地标记 | §3 |

## 7. 风险 / 待定（模型侧视角）

1. **DDR3 物理映射**：本表基址 0x0100_0000、预留 2 MB 已按 Lead 规划；MIG 地址映射、视频区/arena 区分界
   由 T-mem/Lead 在 P3 实现时确认（模型侧只假设"arena 为连续 2 MB 可读写区"）。
2. **ROM 21-bit 改动**：由 Lead 在 P3 开工时统一改 `nn_pkg.sv` + `nn_gen_rom.py` 并重生成两套 ROM；
   在此之前 C128 集成继续用 19-bit 口径（不受影响）。
3. **tile 缓存/带宽**：15.246 MB/帧是模型侧下限；若 MIG 与视频链路争用导致有效带宽 <0.5 GB/s，
   需评估降低 320 帧率或把 add/concat 融合（属后续优化，不在本轮）。
4. 输入 halo 重读 +5.9%（18,240 B/帧）；可在 tile 缓存里保留 2 行消除，是否值得由 T-mem 决定。
5. 模型侧产物**冻结**：plan128/plan320/w/q/ROM 表 sha 不变；本表重出只改 `arena_map.json` 与本文件。
