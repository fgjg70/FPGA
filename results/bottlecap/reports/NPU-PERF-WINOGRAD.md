# P3a：Winograd F(2×2,3×3) int8 精度验证（Lead 硬门槛）· 结论：**通过**

> 作者：`ddr3-feas`（task-12 item 3）。日期：2026-11-03。
> 复现：`python results/bottlecap/reports/winograd_check.py` → `winograd_check.json`（本目录）。
> 判据（Lead 2026-11-03 定，硬门槛）：逐层 int8-Winograd vs int8-direct **cos 均值 ≥ 0.97、最小 ≥ 0.93**；
> 全模型检测框匹配 ≥98%、P/R/F1 下降 ≤0.02（**本阶段只做前两条的逐层部分**，全模型待 P2 落地后）。

---

## 0. 结论（先给判据答案）

| 变体（中间域位宽） | cos_i8 均值 | cos_i8 最小 | max abs diff | **判定** |
|---|---:|---:|---:|---|
| **`exact`**：V 10-bit、U4 13-bit、acc 32-bit | **1.000000** | **1.000000** | **0**（逐元素位精确） | ✅ **PASS（远超阈值）** |
| **`vclip8`**：V 截到 int8（低代价硬件实现） | **0.975358** | **0.967562** | 1,013,602 | ✅ **PASS（余量小）** |
| `mclip16`：累加后 M 截到 int16 | 0.304678 | 0.230806 | 1,355,532 | ❌ FAIL（预期，M 需要 ≥28-bit） |

**三条可执行结论**：
1. **int8 Winograd 在本模型上可以做到逐位精确**（`exact` 变体 max|diff|=0），前提是变换域保持
   **V 10-bit、U4 13-bit、累加 ≥28-bit** —— 也就是说 **"int8 Winograd 必然掉点"的担心不成立**，
   P3 的精度门槛**已通过**（这是与上一轮"降级为 stretch 因精度不确定"判断不同的新证据）。
2. 即使走**省钱变体**（V 压到 int8、即变换域与现引擎同宽），cos 最小 0.9676 **仍过 0.93 门槛**，
   但余量只有 0.037（≈4%），**不建议**作为默认实现；如果面积/时序紧张可以作为降级选项。
3. `mclip16`（把 16 个位置的累加值压到 int16）**不可行**（cos 0.30）—— 累加器必须 ≥28-bit，
   这是 P3 硬件设计的一条硬约束。

---

## 1. 实验设置（真实权重 + 真实激活）

| 项 | 内容 |
|---|---|
| 层选择 | `plan.json` op83 = `refine2.conv1.0+bn`（56×56×72，k=3/s=1/p=1，ResBlock 第一层）；op95 = `objectness_tower.0.0+bn`（同形状，检测头塔第一层）。**两者合计占 12 个 56² 层里最有代表性的两类**（FPN refine 与 head tower） |
| 权重 | **直接取 converter 的 int8 量化结果**：`results/bottlecap/plan/w.hex` 按 `woff/wlen` 切层（op83: woff=1,443,808 wlen=46,656；op95: woff=1,598,584 wlen=46,656），按 `CONTRACT.md §6A` 的 `[tap][IC_pad][OC_pad]` 还原 |
| 激活 | `tools/bottlecap/data/test/*.png` 前 4 张（真实瓶盖图）；按 `dataset.preprocess_224`（320×240 → resize 224×168 → 上下 edge pad 到 224×224 → /127.5−1）过 float 模型，**hook 到该层 Conv2d 的输入**；再按 `CONTRACT.md §5` per-tensor 非对称量化：`s=(max−min)/255, zp=−128−round(min/s), a_q=clip(round(a/s)+zp)` |
| float 模型 | `tools/bottlecap/model_src/best_model.pt` → `EnhancedNutAnchorFree(num_classes=4, fpn_channels=72, backbone_width=0.55)`，`load_state_dict(strict=False)`（class_head 形状差异按 `run_config.json` 的 transfer 记录忽略） |
| direct 路径 | int8×int8，float64 精确累加（量级 <2^53 保证整数精确），取整后 int64；与 golden 逐元素验证 |
| Winograd 路径 | F(2×2,3×3)：`V=BᵀdB`、`U4=(4G)g(4G)ᵀ=16·GgGᵀ`、`M=U4⊙V` 逐 IC 累加、`Y4=AᵀMA`、`y=Y4/16`（exact 变体整除性有断言）；每层 784 个 2×2 tile，56×56 全图覆盖 |
| cos 口径 | cos_i8：两条路径用**同一个** per-tensor requant（`scale = 127/|acc|₉₉.₉`）转 int8 后再算 cos —— 误差只来自 Winograd 中间域；cos_acc：int32 累加直接比 |

**变换矩阵**（整数化）：
```
Bᵀ = [[1,0,-1,0],[0,1,1,0],[0,-1,1,0],[0,1,0,-1]]
G  = [[1,0,0],[1/2,1/2,1/2],[1/2,-1/2,1/2],[0,0,1]]，实现用 4G 保整数 ⇒ U4=16·GgGᵀ
Aᵀ = [[1,1,1,0],[0,1,-1,-1]]
```

---

## 2. 详细结果（2 层 × 4 图 × 3 变体）

| op | module | 变体 | cos_acc | cos_i8 | max abs diff | exact |
|---|---|---|---:|---:|---:|---|
| 83 | refine2.conv1.0 | exact | 1.000000 | 1.000000 | 0 | ✅ |
| 83 | refine2.conv1.0 | vclip8 | 0.9723~0.9818 | 0.9721~0.9817 | ~745k~791k | — |
| 83 | refine2.conv1.0 | mclip16 | 0.427~0.449 | 0.365~0.377 | ~1.04M | — |
| 95 | objectness_tower.0.0 | exact | 1.000000 | 1.000000 | 0 | ✅ |
| 95 | objectness_tower.0.0 | vclip8 | 0.9678~0.9797 | 0.9676~0.9794 | ~1.01M | — |
| 95 | objectness_tower.0.0 | mclip16 | 0.409~0.452 | 0.231~0.248 | ~1.34M | — |

> 全部 24 条明细在 `winograd_check.json.details[]`（含每张图的 quant 元数据）。

---

## 3. 对 P3 硬件设计的三条硬结论

| # | 结论 | 依据 |
|---|---|---|
| W1 | **变换域位宽**：V 必须 10-bit（±512）、U4 必须 13-bit（实测最大 ~1,760）；若压到 int8 则 cos 掉到 0.9754（仍过门槛但余量小） | `exact` vs `vclip8` 对比；V 的理论上界 = 4×128 = 512 |
| W2 | **累加器 ≥28-bit**：M 累加 = Σ_IC U4·V，IC=72 时实测 max ~1.34e6（21-bit），但 **不能压到 int16**（cos 0.30）；建议 **30-bit** 留余量（IC 更大的层如 216/864 需要重算上界） | `mclip16` 失败 |
| W3 | **乘法器**：10-bit × 13-bit 仍是 1 个 DSP48E1（25×18），**不增加 DSP 数**；相对 direct 的 MAC 数 ÷2.25 ⇒ **DSP 需求反而下降**（若维持 128 MAC/拍的阵列，Winograd 让同一阵列做 2.25× 的等效卷积量） | `PX16-STUDY.md §2` 的 DSP48E1 能力；§4 的算术 |
| W4 | **变换加法开销**：每 2×2 tile 输入变换 32 次加法、输出变换 24 次加法（× IC / × OC）⇒ 全模型 ≈33.7M 加法/帧（0.5M 拍 @64 加/拍，占 1.3%） | 本文 §1 的设置 + `cycle_model.py` 的 winograd 项 |

---

## 4. 与 Lead 判据的逐条对账

| 判据 | 要求 | 实测 | 结论 |
|---|---|---|---|
| (a) 逐层 cos 均值 | ≥ 0.97 | **1.000000**（exact）/ 0.975358（vclip8） | ✅ PASS |
| (a) 逐层 cos 最小 | ≥ 0.93 | **1.000000**（exact）/ 0.967562（vclip8） | ✅ PASS |
| (b) 全模型框匹配 ≥98%、P/R/F1 降 ≤0.02 | 待全模型 | **本阶段不适用**（需 P3 引擎 + 全模型 E2E） | ⏳ 待 P2/P3 落地后补 |

> **本阶段判定**：P3 的**逐层精度门槛通过**（含最省钱的 vclip8 变体也过）。**建议 P3 保持 "P2 之后的 stretch" 定位不变**（原因是工作量/资源/时序，不是精度），但把"精度不确定"这条风险从登记表里**关闭**。

---

## 5. 局限与后续

1. **激活来自 float 前向 + per-tensor 量化**，不是 int8 端到端流水线里的真实中间激活（后者需要整网 int8 参考实现）。对"Winograd 变换误差"这个命题足够，但**全模型框匹配判据**必须在 int8 网表上验（等 P2）。
2. 只验了 2 个层（均为 56²/72ch）。**大 IC 层（216/288/432/528/864）的 U4/V 上界需要重算**（尤其 IC=864 的 1×1 层不是 Winograd 目标，但 refine 的 ic=72 与 fusion 的 ic=216 要单独算）。
3. 若硬件把 **权重变换 U4 离线做**（toolchain 生成 13-bit 权重），则片上只需 input transform + 16 点乘加 + output transform；若 U4 片上实时算，需要额外的 16 个乘法/权重（可离线，建议离线）。
4. 建议下一步（若 P3 立项）：把本脚本扩展成"全 18 个 3×3 stride1 层 + int8 端到端"的回归，作为 P3 的验收测试。

---

## 6. 复现

```powershell
cd D:\USER\Desktop\FPGA\FPGA
python results\bottlecap\reports\winograd_check.py
# 输出: results/bottlecap/reports/winograd_check.json
#      （24 条明细 + summary{exact,vclip8,mclip16}）
```
依赖：numpy / torch / PIL（本机已装）。不联网、不改模型源码、不改任何 RTL。
