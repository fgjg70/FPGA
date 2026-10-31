# nn_conv_engine.sv — int8 卷积引擎交付报告

> 负责人：T-accel。契约：`results/ai-accel/CONTRACT.md` v0.4（§5 量化 / §6 权重布局 /
> §7 Q 区变长布局 / §8 激活布局 / §9.2 端口 / §11 op 精确语义）。
> 本文所有数字都带**出处**（命令 / 日志文件 / 报告文件），"看起来对"不构成证据。

---

## 0. TL;DR

| 项 | 结果 | 出处 |
|---|---|---|
| 功能 | **`ENGINE_TB: PASS (46 cases, mismatch=0)`**，覆盖 conv1x1/3x3/5x5、depthwise、maxpool K=2/3/5/9、copy、2x upsample、residual add；非法描述符也验证报 err | `results/ai-accel/proto/engine/tb_run10.log` |
| 官方回归 | `python tools\fpga_workflow.py verify --only tb_nn_engine` → **PASS 3.7s** | 该命令输出 |
| 位精确 | 逐 op mismatch = 0（A/B 缓冲**全区逐字** `!==` 比对，X 也算错） | TB 输出（§4） |
| 周期公式 | 46 个 case **实测 cycles 与理论公式逐 case 相等**（误差 0） | §3 表 |
| 资源（Vivado 2018.3，engine 单独 OOC synth） | **LUT 15,213 / FF 8,029 / DSP48E1 52 / BRAM 0** | `proto/engine/synth_engine_util.rpt`，`synth_engine.log` |
| 全模型周期估算（128 输入，plan.json 108 ops） | **1,216,578 拍 ≈ 9.27 ms @131.25 MHz（≈108 fps 纯 NPU 计算）** | §6，由 §3 公式逐 op 求和 |
| 已修 bug | 6 个（详见 §7），其中 3 个是会导致整层/整 op 错的关键 bug | §7 |

---

## 1. 交付物清单

| 文件 | 作用 |
|---|---|
| `nn_conv_engine.sv` | 引擎本体（根目录，已登记进 Lead 的 RTL 清单；**本文件已冻结**） |
| `sim/tb_nn_engine.sv` | 自校验 TB（46 case，阶段 A；已登记进 verify 矩阵） |
| `results/ai-accel/proto/engine/gen_vectors.py` | **独立** Python 全整数 golden + 向量生成器（期望值不来自 RTL） |
| `results/ai-accel/proto/engine/vec/` | 生成的向量（`manifest.txt` + `<case>.{wq,a,b,aexp,bexp}.wr`，46 case × 5 文件） |
| `results/ai-accel/proto/engine/run_tb.bat` | 跑 TB（ModelSim 命令行，env 显式补齐） |
| `results/ai-accel/proto/engine/run_dbg.bat` / `debug_tb.sv` | 临时调试入口（非交付，留作复现 bug） |
| `results/ai-accel/proto/engine/synth_engine.{tcl,bat}` + `synth_engine_util.rpt` | 资源估算的 Vivado 脚本与报告 |
| `results/ai-accel/proto/engine/compile.bat` | 只编译检查（vlib/vlog） |

---

## 2. 微架构

```
        desc (nn_desc_t) ──► 描述符锁存 + 合法性检查
                                   │
    ┌──────────────────────────────┴──────────────────────────────────┐
    │                              FSM                                │
    │ IDLE→INIT→[Q]→BI→(LD→WI→MAC)…→DRN→REQ→NEXT │ PINIT→(LD→WI→PMAX)…  │
    └──────┬───────────────┬──────────────────────┬───────────────────┘
           │w 口 64b/拍    │a 口 128b/拍          │b 口 64b/拍
           ▼               ▼                      ▼
      权重/Q 读地址    band 装载(1 字/拍)      requant/pool/copy/add 写
           │               │
           │          abuf[24]×64b ──► bshift[15]×64b (按 kx 移位)
           │                               │ win[8]×64b (px*stride 选)
           ▼                               ▼
      wp[8]int8 ──► 64× {8x8 有符号乘} ──► prod[8][8]int16 ──► acc[8][8]int32
      (1 拍延迟)          (每拍 64 MAC)         (+2 拍流水)      │
                                                               ▼
                          requant: 8 个宽乘法器(32×32→64) × 8 拍
                          out = clamp((acc*M)>>>SHIFT + zp_out)  ──► b 口写
```

### 2.1 PE 阵列与并行度

- `PX_LANES=8` × `OC_LANES=8` = **64 个 int8 乘法/拍**（output-stationary，像素并行）。
- 每个输出块 = 8 个输出像素 × 8 个输出通道；被乘数 A 操作数按像素 lane 广播/逐字节，
  B 操作数 = 权重字 8 个字节（每拍 1 个 64 位权重读）。
- 累加器 `acc[8][8]` int32；乘积累加流水 = issue(读权重) → prod(寄存) → acc(加) 三级，
  **吞吐 1 拍/(tap,ic)，延迟 2 拍**（输出块结束的 2 拍 drain 已计入周期公式）。

### 2.2 激活的"转置"与窗口复用

激活 BRAM 布局是 NHWC + 8 通道字（CONTRACT §8），一个 64 位字 = 一个像素的 8 通道。
卷积需要"8 个像素的同一通道"广播到 8 个像素 lane，因此：

1. **band 装载**：`abuf[band_idx] = 一个像素的 8 通道字`（像素主序）。
   一次读 64 位（a 口 128 位只用其中一半，`a_addr[3]` 选半字）。
2. **bshift 移位窗口**：`bshift[i] = band[i+kx]`，每换一个 kx 把 bshift 整体移 1 位、
   尾部从 `abuf[15+kx]` 补入；`win[px] = bshift[px*stride]`。
   这样**每行 band 只装一次，K 个 kx 复用**，避免 K 倍重复读。
3. dense：`A[px][oc] = win[px]` 的第 `c` 字节（广播到 8 个 oc lane）；
   depthwise/pool：`A[px][oc] = win[px]` 的第 `oc` 字节（逐字节对应）。

### 2.3 requant（CONTRACT §5 v0.4，全整数 floor）

- Q 区只存 `M_pos` int16；引擎在 **OC tile 装载阶段**现算
  `M_neg = leaky_en ? (M_pos*3277 + 16384) >>> 15 : M_pos`（int32 运算，M_pos 符号扩展）。
- `y64 = (acc>=0 ? acc*M_pos : acc*M_neg)`（**64 位有符号乘积**，32×32→64）；
  `out = clamp((y64 >>> SHIFT) + zp_out, -128, 127)`；`>>>` = 算术右移 = floor。
- 8 个像素分 8 拍串行做乘法（8 个乘法器），打包/写回与乘法流水重叠
  → requant+write = **9 拍/输出块**（`c_p = 0..8`）。
- 输出 padding 通道（`oc` 到 `OC_pad`）写 `zp_out`（量化零，CONTRACT §8 "未用通道填 zp_a"）。
- **不存 M_neg、per-oc `sh[]` 不读**：SHIFT 取尾部 `[3]` 字节（本版全层统一 16；
  TB 里也测了 SHIFT=10 的 case）。若将来要支持逐 OC 不同 SHIFT，需扩 Q 读取（见 §8）。

### 2.4 Q 参数读取（v0.4 变长紧凑布局，走 w 口）

每个 OC tile 读 **7 次 64 位** + 1 拍算 M_neg：

| 读 | 地址 | 内容 |
|---|---|---|
| 0..3 | `qoff + ocb*32 + i*8` | `bias_adj[8]` int32（4×64b） |
| 4..5 | `qoff + 4*OC_pad + ocb*16 + i*8` | `M_pos[8]` int16（2×64b） |
| 6 | `qoff + 6*OC_pad` | tail：`[0]=zp_out [1]=zp_in [2]=leaky_en [3]=SHIFT` |

地址口径 = NN 窗口绝对字节偏移（CONTRACT §9.1 v0.2 起），8 字节对齐，小端。

### 2.5 FSM

| 状态 | 作用 | 周期 |
|---|---|---|
| `S_IDLE` | 等 start，锁存描述符 | - |
| `S_INIT` | 合法性检查（非法 → `S_FIN` + `err_code`，不写内存） | 1 |
| `S_Q` / `S_QLOAD` | 读 Q 参数 / 算 M_neg（每 OC tile 一次） | 8 + 1 |
| `S_BI` | `acc = bias_adj` | 1 |
| `S_LD` / `S_LDCAP` | band 装载（1 字/拍）+ 等最后返回 | L + 1 |
| `S_WI` | 初始化 bshift | 1（dense K=1 跳过） |
| `S_MAC` | 64 MAC/拍流水 | dense `8*K`；dw/pool `K` |
| `S_DRN` | MAC 流水 drain | 2 |
| `S_REQ` | requant（8 拍乘法）+ 打包写回（重叠） | 9 |
| `S_NEXT` | 推进 (oxg, oy, ocb) | 1 |
| `S_PINIT` / `S_PMAX` | pool：mx 清 -128 / 64 路 max | 1 / K |
| `S_PPACK` | pool 写回 8 个字 | 8 |
| `S_CP_RD`/`S_CP_WR` | copy：读 1 字 → 写 1 份（或 upsample 4 份） | 1 + (1 或 4) |
| `S_AD_R1/R2/WR` | add：读 src、读 dst、饱和加写 | 3 字/像素块 |
| `S_FIN` | `done` 单拍脉冲 | 1 |

`err_code`（0x00=OK）：0x11/12/13 conv k/stride/pad 非法；0x14/15 ic,oc/ih,iw 非法；
0x16 depthwise 但 oc≠ic；0x21..0x25 pool 参数非法；0x31..0x33 copy 参数非法；
0x41..0x43 add 参数非法；0x18 oh/ow 会算成 0。

---

## 3. 周期公式与实测对照

记：`ICB = ceil(IC/8)`，`OCB = ceil(OC/8)`，`ceil8(x)=ceil(x/8)*8`，
`OH=(IH+2PAD-K)/ST+1`，`OW=(IW+2PAD-K)/ST+1`，输出块 = 8 像素 × 8 通道。
所有"周期数"= `cycles` 输出寄存器的值（= 除 `S_IDLE/S_FIN` 外的状态拍数；`busy` 会多 1 拍）。

```
conv (dense):
  L  = (K==1) ? 8 : 7*ST+K                 # band 装载字数 (K==1 时按 stride 跳采)
  NB = OH*ceil(OW/8)                       # 每个 OC tile 的输出块数
  sub = (K==1 ? 1 : K)*ICB                 # (ky,icb) 子块数
  per_sub = (L+1) + (K==1 ? 0 : 1) + 8*K   # 装载 + 窗口初始化(可选) + MACN
  block = 1(BI) + sub*per_sub + 2(DRN) + 9(REQ) + 1(NEXT)
  cycles = 1(INIT) + OCB*(8+1)(Q) + OCB*NB*block

depthwise:
  L = 7*ST+K;  block = 1 + K*((L+1)+1+K) + 2 + 9 + 1
  cycles = 1 + OCB*9 + OCB*(OH*ceil(OW/8))*block

maxpool:
  L = 7*ST+K;  NB = ICB*OH*ceil(OW/8)
  block = 1(PINIT) + K*((L+1)+1+K) + 8(PPACK) + 1(NEXT)
  cycles = 1 + NB*block

copy/upsample:
  words = IH*IW*ICB;  cycles = 1 + words*(UPS2X ? 5 : 2)

add:
  words = IH*IW*ICB;  cycles = 1 + words*3
```

**实测 vs 理论（46 case 全等）**——来源 `proto/engine/tb_run10.log`（TB 逐 case 打印 `cyc=`）：
生成脚本 `proto/engine/calc_cycles.py`（理论公式）/ `mk_table.py`（本表）。

| case | op | k/stride/pad | in HxW | out HxW | IC->OC | 实测 cyc | 理论 cyc | mismatch(A,B) |
|---|---|---|---|---|---|---|---|---|
| conv1x1_s1 | conv/dw | 1/1/0 | 8x10 | 8x10 | 8->8 | 490 | 490 | 0,0 |
| conv1x1_s1_i3o5 | conv/dw | 1/1/0 | 6x7 | 6x7 | 3->5 | 190 | 190 | 0,0 |
| conv1x1_s2 | conv/dw | 1/2/0 | 12x12 | 6x6 | 8->8 | 190 | 190 | 0,0 |
| conv1x1_oc24 | conv/dw | 1/1/0 | 5x20 | 5x20 | 8->24 | 1378 | 1378 | 0,0 |
| conv1x1_i13o13 | conv/dw | 1/1/0 | 6x6 | 6x6 | 13->13 | 583 | 583 | 0,0 |
| conv3x3_s1p1 | conv/dw | 3/1/1 | 9x10 | 9x10 | 8->8 | 2188 | 2188 | 0,0 |
| conv3x3_s1p0 | conv/dw | 3/1/0 | 7x5 | 5x3 | 8->8 | 615 | 615 | 0,0 |
| conv3x3_s2p1 | conv/dw | 3/2/1 | 14x13 | 7x7 | 8->16 | 2007 | 2007 | 0,0 |
| conv3x3_s2p0 | conv/dw | 3/2/0 | 12x11 | 5x5 | 16->8 | 1365 | 1365 | 0,0 |
| conv3x3_i13o13 | conv/dw | 3/1/1 | 8x9 | 8x9 | 13->13 | 7347 | 7347 | 0,0 |
| conv5x5_s1p2 | conv/dw | 5/1/2 | 9x8 | 9x8 | 8->8 | 2557 | 2557 | 0,0 |
| conv5x5_s2p2 | conv/dw | 5/2/2 | 14x13 | 7x7 | 8->8 | 2236 | 2236 | 0,0 |
| conv5x5_i16o16 | conv/dw | 5/1/2 | 8x8 | 8x8 | 16->16 | 8867 | 8867 | 0,0 |
| conv1x1_bigM | conv/dw | 1/1/0 | 5x5 | 5x5 | 8->8 | 160 | 160 | 0,0 |
| conv1x1_mixM | conv/dw | 1/1/0 | 6x6 | 6x6 | 8->8 | 190 | 190 | 0,0 |
| conv3x3_shift10 | conv/dw | 3/1/1 | 7x7 | 7x7 | 8->8 | 857 | 857 | 0,0 |
| conv1x1_srcoff8 | conv/dw | 1/1/0 | 5x6 | 5x6 | 8->8 | 160 | 160 | 0,0 |
| conv1x1_srcB | conv/dw | 1/1/0 | 6x6 | 6x6 | 8->8 | 190 | 190 | 0,0 |
| conv3x3_srcB | conv/dw | 3/1/1 | 8x8 | 8x8 | 16->8 | 1842 | 1842 | 0,0 |
| conv1x1_bigbias | conv/dw | 1/1/0 | 5x5 | 5x5 | 8->8 | 160 | 160 | 0,0 |
| dw3x3_c8 | conv/dw | 3/1/1 | 9x10 | 9x10 | 8->8 | 1054 | 1054 | 0,0 |
| dw3x3_c16 | conv/dw | 3/1/1 | 8x8 | 8x8 | 16->16 | 947 | 947 | 0,0 |
| dw3x3_c24 | conv/dw | 3/1/1 | 6x7 | 6x7 | 24->24 | 1072 | 1072 | 0,0 |
| dw3x3_c13 | conv/dw | 3/1/0 | 7x8 | 5x6 | 13->13 | 599 | 599 | 0,0 |
| dw3x3_s2 | conv/dw | 3/2/1 | 12x11 | 6x6 | 8->8 | 484 | 484 | 0,0 |
| dw5x5_c8 | conv/dw | 5/1/2 | 9x8 | 9x8 | 8->8 | 982 | 982 | 0,0 |
| dw5x5_c16 | conv/dw | 5/1/2 | 8x9 | 8x9 | 16->16 | 3475 | 3475 | 0,0 |
| dw5x5_s2 | conv/dw | 5/2/2 | 14x13 | 7x7 | 8->8 | 1011 | 1011 | 0,0 |
| pool2_s2p0 | pool | 2/2/0 | 8x8 | 4x4 | 8->8 | 201 | 201 | 0,0 |
| pool2_s2p1 | pool | 2/2/1 | 8x7 | 5x4 | 8->8 | 251 | 251 | 0,0 |
| pool3_s1p1 | pool | 3/1/1 | 7x9 | 7x9 | 8->8 | 771 | 771 | 0,0 |
| pool3_s2p1 | pool | 3/2/1 | 12x13 | 6x7 | 8->8 | 457 | 457 | 0,0 |
| pool5_s1p2 | pool | 5/1/2 | 8x8 | 8x8 | 16->16 | 1681 | 1681 | 0,0 |
| pool9_s1p4 | pool | 9/1/4 | 12x11 | 12x11 | 8->8 | 6073 | 6073 | 0,0 |
| pool9_c13 | pool | 9/1/4 | 10x10 | 10x10 | 13->13 | 10121 | 10121 | 0,0 |
| pool2_s2_c24 | pool | 2/2/0 | 9x9 | 4x4 | 24->24 | 601 | 601 | 0,0 |
| pool3_srcB | pool | 3/1/1 | 7x7 | 7x7 | 8->8 | 386 | 386 | 0,0 |
| copy | copy/up | 1/1/0 | 7x6 | 7x6 | 8->8 | 85 | 85 | 0,0 |
| copy_c16 | copy/up | 1/1/0 | 5x6 | 5x6 | 16->16 | 121 | 121 | 0,0 |
| copy_oc16 | copy/up | 1/1/0 | 4x5 | 4x5 | 8->16 | 41 | 41 | 0,0 |
| ups2x | copy/up | 1/1/0 | 5x4 | 10x8 | 8->8 | 101 | 101 | 0,0 |
| ups2x_c16 | copy/up | 1/1/0 | 4x5 | 8x10 | 16->16 | 201 | 201 | 0,0 |
| add | add | - | 6x7 | 6x7 | 8->8 | 127 | 127 | 0,0 |
| add_c24 | add | - | 5x5 | 5x5 | 24->24 | 226 | 226 | 0,0 |
| add_srcB | add | - | 6x6 | 6x6 | 8->8 | 109 | 109 | 0,0 |
| add_same_buf | add | - | 5x6 | 5x6 | 16->16 | 181 | 181 | 0,0 |

> 吞吐（MAC/拍）示例：conv5x5_i16o16 理论 409,600 MAC / 8,867 拍 = **46.2 MAC/拍**（峰值 64）；
> conv1x1 类约 40~55；depthwise 约 9~10（受激活带宽限制，见 §8）；pool 为纯比较无 MAC。

---

## 4. 功能验证（位精确）

### 4.1 方法（独立参考，非循环论证）

1. `gen_vectors.py` 用 **Python int** 重算全部整数语义（acc/bias 用 int、乘法不截断、
   `>>` 即 floor），生成期望值；**不使用任何 RTL 输出**。
2. TB 通过 **CPU 窗口**把 W/Q 与 A/B 初值逐字写进真实 `nn_mem.sv`，跑 1 个 op 后
   把 A/B 缓冲的**受测区域全区逐字读回**，用 `!==` 与期望比较（X 也算 mismatch）。
3. 每个 case 都覆盖：descriptor 装配 → start 单拍 → busy/done 握手 → 逐字节回读比较。
4. 额外验证：非法描述符（conv ks=2）→ `err_code=0x11`、不写内存、`done` 正常脉冲。

### 4.2 判据输出（`tb_run10.log` 原文摘要）

```
ERRCASE invalid-desc : PASS (err=11, cyc=1)
SUMMARY cases=46 pass=46 fail=0 total_mismatch=0
  op=0 ( conv/dw) cases=28 fail=0 mismatch=0 max_cycles=8867
  op=1 (    pool) cases=9  fail=0 mismatch=0 max_cycles=10121
  op=2 (copy/ups) cases=5  fail=0 mismatch=0 max_cycles=201
  op=3 (     add) cases=4  fail=0 mismatch=0 max_cycles=226
ENGINE_TB: PASS (46 cases, mismatch=0)
```

覆盖的边角：stride 1/2、pad 0/1/2（pool K=9 的 pad=4）、IC/OC 非 8 倍数（3/5/13/24）、
OW 非 8 倍数（10/7/5/9/11/13）、多 OC 块（oc=24）、多像素组（ow=20）、
src/dst 在 A 或 B、非 16 字节对齐的 src 偏移（+8 → 走 a 口高半字）、
SHIFT=10、M_pos 大/小/mix、bias 大幅值（饱和路径）、upsample、同 buffer 的 add。

### 4.3 阶段 B（T-model 逐层向量）

Lead 正在做 E2E（`tb_sw_nn_yolo`，108 ops）。本 TB 结构（manifest + 逐 case 描述符）可以
直接扩展到逐层向量：把 T-model 的 `l<NN>_*.hex` 按 §6/§7/§8 打包成 `wq.wr/a.wr/b.wr/aexp.wr`
即可复用同一 compare 框架（每个 op 独立 case，mismatch 计数不变）。

---

## 5. 资源实测

命令：`results/ai-accel/proto/engine/synth_engine.bat`
（Vivado 2018.3，`synth_design -top nn_conv_engine -part xc7a100tfgg484-2 -mode out_of_context`，
**无时钟约束** → 本报告不引用 fmax；报告文件：`proto/engine/synth_engine_util.rpt` / `synth_engine.log`）

| 资源 | 用量 | 器件总量 | 占比 | 任务/PLAN 预算 |
|---|---|---|---|---|
| Slice LUTs | **15,213** | 63,400 | 24.0% | PLAN 估 "+6~10K" → **超估**（Lead 已接受） |
| Slice Registers | **8,029** | 126,800 | 6.3% | ≤10K ✓ |
| DSP48E1 | **52** | 240 | 21.7% | ≤240 ✓（PLAN 估 72；Vivado 把 8×8 MAC 部分收进 LUT） |
| Block RAM Tile | **0** | 135 | 0% | PE 阵列不落 BRAM ✓（GEMM 教训不重犯） |
| F7 Muxes | 397 | 31,700 | 1.3% | - |

> LUT 偏高的主要来源（按模块分解的推断，未逐项做 report_hierarchy）：
> ① requant 的 `acc` 行选择（8 拍 × 8 lane × 32 位 8:1 mux）；
> ② bshift 窗口 + 可变字节选择 + pool 的 64 路 max；
> ③ 8×8 乘法有相当部分被综合成 LUT 乘法（DSP 仅 52）。
> **优化路径**（未做，留给后续）：给 MAC 乘寄存器加 `(* use_dsp = "yes" *)` 强行落 DSP；
> requant 的 8 拍行选择改成"转置累加器 + 列选择"或流水化；窗口选择改成 shift-register 直连。

整机预算（Lead 口径）：交付档 CPU ~3.1K LUT + 引擎 15.2K = ~18.3K / 63.4K，余量充足。

---

## 6. 全模型周期/吞吐估算（128 输入，T-model `sim/prog/yolo/plan.json`）

按 §3 公式逐 op 求和（`cpu_conv0` / `cpu_concat` 由 CPU 做，不计；pool 的 pad=0 时按
(K-1)/2 推——plan 里 K=9 pool 显式 pad=4，v0.4 起可直接传）：

| op 类 | 个数 | 周期 | MAC |
|---|---|---|---|
| conv（含 1x1/3x3/dw 之外的 dense） | 55 | 777,430 | 16,279,552 |
| dwconv | 28 | 398,398 | 3,701,376 |
| add | 18 | 29,874 | 0 |
| pool | 3 | 9,915 | 0 |
| upsample | 1 | 961 | 0 |
| **合计（NPU 计算）** | 105 | **1,216,578** | **19,980,928** |

- @131.25 MHz：**9.27 ms/帧 ≈ 107.9 fps**（纯算力上限；E2E 还要加 CPU 层调度/搬运开销）
- @150 MHz（交付档 CPU 主频可到 150MHz，NPU 建议 131.25）：8.11 ms ≈ 123 fps
- 平均效率 16.4 MAC/拍（峰值 64）：dense 20.9、depthwise 9.3（详见 §8）
- 软件基线（PLAN §3）：逐 MAC 约 1.2~1.7 s/帧 → 预期 **≥100×** 加速

---

## 7. 已修 bug 记录（都是"数字不对"才发现，值得留档）

| # | 症状 | 根因 | 修法 | 定位方法 |
|---|---|---|---|---|
| 1 | 所有 conv/dw 输出近似"只有 bias"，但逐通道不同 | Q tail 的 `SHIFT` 取错字节：`w_rdata[23:16]` 是 `leaky_en` 字节，SHIFT 在 `[31:24]`；SHIFT 读成 1 导致右移错 | `shift_q <= w_rdata[31:24]` | 单 case 调试 TB dump `prod64`，发现 prod64 与手算一致但输出饱和；再看 QLOAD 打印 SHIFT=1 |
| 2 | 所有 ADD op 输出 = src（dst 读回 0） | ADD 要读 src 和 dst，但 `a_sel` 只由 `desc.src` 决定；src 在 A、dst 在 B 时 dst 读会返回 0（nn_mem 对 sel/地址不一致返回 0） | ADD 的 dst 读（`S_AD_R2`）把 `a_sel` 切到 dst 所在 buffer | 对比 src/dst 分处 A/B 的 case 全错、同 buffer 的正确 |
| 3 | pool 输出全错且与输入无关 | `S_WI` 无条件跳 `S_MAC`，pool 走进 MAC 路径（还读了 woff=0 的假权重 + 用上次 Q 参数 requant） | `S_WI: state <= is_pool ? S_PMAX : S_MAC` | dump FSM：pool case 从未进入 `S_PMAX` |
| 4 | upsample 只有 1/4 写出（其余 0） | nn_mem 的 `a_rdata` 只在 `a_re` 下一拍有效（之后回 0）；COPY 的 4 份写里后 3 份读到 0 | 读返回拍锁存 `cp_word_q`，c_wr=0 用 a_rdata、其后用锁存 | dump `S_CP_WR`：c_wr=1/2/3 的 `b_wdata=0` |
| 5 | OC 非 8 倍数时输出 padding 通道 = 0x03/0x00 | 打包 padding 通道写 `{zp_out[7],zp_out[7]}`（2 位拼接被零扩展） | `bb = zp_out` | 对比 exp/got 只在通道 5..7 不同 |
| 6 | pool K=9 输出尺寸算成 1x1（SPP 全错） | `nn_desc_t.pad` 原为 2 位，`pad=4` 被截成 0；oh/ow 公式用错 pad | v0.4 Lead 已加宽到 3 位；引擎 `d_pad[2:0]` 直接用 `desc.pad`（另留 `pad==0 → (K-1)/2` 防御分支） | 对照 T-model plan 的 pool pad=4 |

> 另：**Python golden 自身的 dw 语义 bug** 也修了一个（最初把 depthwise 写成"每个输出通道
> 累加所有输入通道"，正确是"输出通道 c 只用输入通道 c"）。TB 先红后发现是 golden 错而不是
> RTL 错——说明"独立参考"也要接受审查（但方向正确：先让 golden 与手算对，再比 RTL）。

---

## 8. 已知限制与优化路径

1. **性能（未做流水重叠）**
   - band 装载与 MAC 串行（`L+1` 拍装载 / `8*K` 拍 MAC）；dense 1x1 时装载占约 1/2 时间。
     优化：双 buffer（`abuf` 双份）把下一 (ky,icb) 的装载藏进当前 MAC；预计 dense +80~90%。
   - requant 8 个宽乘法串行 8 拍；可扩到 16 个乘法器（2 像素/拍）→ 5 拍。
   - depthwise 吞吐只有 ~9.3 MAC/拍：每个 (8px,8ch) 块要装 `7*stride+K` 个字才做 `K` 次
     64-lane MAC。优化：128 位读口一次取 2 个相邻像素（stride=1 时 band 装载减半）、
     或加"2 像素/拍 + 通道并行"模式（PLAN §7 已列风险）。
   - 128 位 a 口当前只用 1 个 64 位字（另一个空闲）；dense 且 `ICB==1` 时可用双字一次取
     2 个相邻像素，把装载减半（本次未做，TB 的 a 口口径已按"只用半字 + 半字选择"验证）。
2. **接口/契约口径**
   - `a_sel` 对 ADD 是**按当前读地址动态切**的（src 读用 src buffer，dst 读用 dst buffer）。
     CONTRACT §11 只给了"a_sel=(desc.src>=NN_B_OFF)"的规则，对"src/dst 分处 A/B 的 ADD"
     必须动态切；对 conv/pool/copy 与契约完全一致。已在代码注释里写死。
   - pool 输出 padding 通道（`c>=IC`）写 `0`；conv/dw 输出 padding 通道写 `zp_out`。
   - `NN_F_POOLMAX` 不参与逻辑（v1 只做 max，pool 一律取 max）。
   - conv 的 add-mode（`NN_F_ADD`）**未实现**（CONTRACT §11 允许 v1 后置，shortcut 用独立
     ADD op 覆盖）。
   - **per-OC `sh[]` 不读**：SHIFT 取 tail 的 `[3]`（全层统一）；Q 区 `+0xC00` 的 sh 数组不用。
   - `M_neg` 现算依赖 `leaky_en`（tail`[2]` 的 bit0）：非 leaky 层 M_neg=M_pos，
     否则 `(M_pos*3277+16384)>>>15`。
   - pool 的 `pad` 防御分支：`desc.pad==0` 时按 `(K-1)/2` 推（v0.4 起主路径用 desc.pad=4）。
3. **规模限制**
   - `band` 寄存器组 24 字：支持 `7*stride+K ≤ 24`，即 conv/dw K≤5,stride≤2（19）与
     pool K≤9,stride 1（16）/K≤2,stride 2 等；**pool K=9 stride=2 需要 24**（=23+1 富余，可用）。
   - `IC/OC ≤ 256`（ICB/OCB ≤ 32）；engine 内部用 16 位计数器，最大张量按 64KB/96KB 缓冲
     假设（不检查越界，由 nn_subsys 的 desc_ok + 软件契约保证）。
   - 单层 Q 块 `6*OC_pad+16` 字节（变长），qoff 由 T-model/C 软件按 Q 区顺序分配。

---

## 9. 复现命令

```bat
rem 1) 生成向量（自动从 nn_pkg.sv 解析地址/容量, 布局改了就重跑, R1）
cd results\ai-accel\proto\engine
python gen_vectors.py
rem 2) 跑 TB（ModelSim；env 由 bat 显式补齐, 不依赖会话 env）
run_tb.bat
rem 期望输出: ENGINE_TB: PASS (46 cases, mismatch=0)

rem 3) 官方入口（仓库根）
python tools\fpga_workflow.py verify --only tb_nn_engine
rem 期望: PASS tb_nn_engine

rem 4) 资源
synth_engine.bat
rem 期望: synth_engine_util.rpt 里 LUT 15213 / FF 8029 / DSP 48E1 52 / BRAM 0

rem 5) 理论周期对照
python calc_cycles.py   (读 tb_run10.log + vec/manifest.txt)
```

* `tb_run10.log` 是上面命令 2 的输出（UTF-16 重定向），`cycle_table.md`/`case_table.md`
  是周期对照表生成结果。
* 向量重新生成的唯一触发条件：`nn_pkg.sv` 的地址/容量常量变化（脚本自动解析，不手写死）。

---

## 10. 结论

引擎按 CONTRACT v0.4 实现并通过 46 个独立参考向量的**位精确**自检（mismatch=0），
周期行为与理论公式逐 case 一致；资源 FF/DSP/BRAM 在预算内，LUT 超 PLAN 估算但器件充足；
已接入 `nn_subsys` + `nn_mem`，E2E（`tb_sw_nn_yolo`）通路已通。
后续若 E2E 出现某个 op 的 mismatch，请把 op 编号 + 该层 `plan.json` 条目发给 T-accel，
按 §4/§11 框架可直接复现到具体 cycle。

---

## 11. 阶段 B：用 T-model 真向量**逐层重放**（并已用此定位一次 E2E mismatch）

### 11.1 工具

`results/ai-accel/proto/engine/make_e2e_case.py` + `run_e2e.bat`：
直接把 `sim/prog/yolo/l<op>_{in,w,q,out}.hex` 按 CONTRACT §6/§7/§8 打包成
单 op 重放的 A/B + W/Q 镜像（自动从 `nn_pkg.sv` 解析地址/容量），复用
`sim/tb_nn_engine.sv` 的装载/比较框架（`+vec=vec_e2e`）。覆盖 conv/dwconv/pool/upsample；
add/cpu_concat 需要 dst 初值，暂未支持。

### 11.2 重放结果（引擎部分**全部位精确**）

| op | kind | shape | k/s/p | 引擎 cycles | mismatch |
|---|---|---|---|---|---|
| 2 | dwconv | 64x64x8→8 | 3/1/1 (leaky, zp_in=-93, SHIFT=18) | 29,706 | **0** |
| 70 | conv | 4x4x136→48 | 1/1/0 | 7,303 | **0** |
| 93 | pool | 4x4x48→48 | 9/1/4 (pad=4, SPP) | 6,073 | **0** |
| 96 | dwconv | 4x4x96→96 | 5/1/2 | 5,293 | **0** |
| 100 | conv (head) | 4x4x96→255 | 1/1/0 (OC_pad=256) | 28,065 | **0** |
| 101 | upsample | 4x4x96→96 | 2/2 (2x) | 961 | **0** |

结论：**引擎对 T-model 的逐层期望输出是位精确的**（含 zp_in≠0 的空间 padding、逐层
SHIFT 17/18/23、OC=255 的通道 padding、pool pad=4）。因此 E2E 的 mismatch 只能来自
集成层（C 程序 / MMIO 描述符装配 / 调度）。

### 11.3 2026-10-31 E2E op2 mismatch 的根因（集成层，非引擎）

现场：`tb_sw_nn_yolo` HW-only，op0/op1 PASS，op2（dwconv k3 s1 p1）got=0xedb78029
exp=0x9985162c，之后 106 op 级联失败。

1. 用 §11.1 工具原样重放 op2（同一份 `l2_in/w/q/out`、同 woff/qoff、同 src/dst）：
   **PASS，mismatch=0，29,706 拍** → 引擎无罪。
2. 把 got checksum 反推：对 op2 的输入执行 **maxpool k=3, stride=1, pad=1**，
   其紧凑输出 FNV-1a 恰好 = **0xEDB78029**（= got）。即**引擎实际收到的是 op=1（POOL）**。
3. 根因：`sw/yolo_demo.c:271` 把 C 侧 `kind` 枚举**原样**写进 `MMIO_NN_OP`：
   ```c
   REG(MMIO_NN_OP) = o->kind;   /* 错: kind 0=conv,1=dwconv,2=pool,3=upsample,4=add */
   ```
   而 `NN_OP` 编码（CONTRACT §4）是 `0=conv/dwconv, 1=maxpool, 2=copy/upsample, 3=add`。
   于是 op2(dwconv) 被当成 pool 执行，后续全部级联错。
4. 建议修复（`sw/` 属 Lead 作用域，未由 T-accel 修改）：
   ```c
   static u32 hw_op_code(const yolo_op_t *o) {
       switch (o->kind) {
           case YK_CONV: case YK_DWCONV: return 0u;   /* NN_OP_CONV */
           case YK_POOL:                 return 1u;   /* NN_OP_POOL */
           case YK_UPSAMPLE:             return 2u;   /* NN_OP_COPY */
           default:                      return 3u;   /* YK_ADD -> NN_OP_ADD */
       }
   }
   ...
   REG(MMIO_NN_OP) = hw_op_code(o);   /* hw_run() 第 271 行 */
   ```
   其余描述符字段核对无误：C 表里 op2 flags=0x03(depthwise|leaky)、pool op91/92/93
   flags=0x10(poolmax) pad=1/2/4 k=3/5/9、op101 flags=0x08(UP2X) 都与契约一致；
   depthwise 由 `NN_FLAGS.bit0` 表达，不需要单独 op 码。
5. 修复后按 §11.2 的重放证据，剩下的 conv/dw/pool/upsample/add op 预期都能过；
   若仍有 mismatch，把 op id 发 T-accel，可 5 分钟内重放到具体像素。

> 纪律说明：本轮只改/新增了 `results/ai-accel/proto/engine/` 下的重放工具与本文档，
> `nn_conv_engine.sv` / `sim/tb_nn_engine.sv` **未改动**（engine 保持冻结），
> `tools\fpga_workflow.py verify --only tb_nn_engine --force` 仍 PASS。
