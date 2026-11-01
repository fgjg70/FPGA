# dw 16-lane 设计（B 项，待落地）

> 现状：C128 阶段 dwconv = 449,176 拍（38.6% of 1,167,368），28 个 dw 层全部 8-lane（64 MAC/拍，128 MAC 阵列一半闲置）。
> 目标：dw 层也用 16 OC lane（128 MAC/拍），C8=8 的少数层降级 8-lane。

## 1. 数据通路要点
- dw 输出通道 c 用输入通道 c；16-lane 需要"同一像素 16 个输入通道"。
- 现 band word 是 64b（8 通道/像素）。16-lane 需要 **128b band word**（16 通道/像素）：
  - C8 ≥ 16 时：`a_addr = pixel_byte + cb*16`，读 16B 窗口；
    - 对齐：A 读口 16B 对齐（低 4 位忽略），engine 传 `(pixel_byte + cb*16) & ~15`，再从窗口内按 offset 提取 16 通道；
    - offset ∈ {0,8}：offset=0 时窗口直接是 16 通道；offset=8 时需要"本窗口高 8B + 下一窗口低 8B" → 引擎内二级窗（与 PACKED3 类似）或一次读两个窗口；
  - C8 = 8 的 dw 层（本 plan 中 ic=8 的 2 个层）：降级 8-lane（用现有路径）。
- 权重：dw 布局 `[tap][OC8]`，16-lane tile 读 `w_addr = woff + tap*OC8 + cb*16`（8B 对齐 128b 读，已由 t-mem 支持）✓。
- Q：与 conv 相同按 16-lane tile（bias int32[OC8], mpos int16[OC8], tail），`q_addr = qoff>>3 + …`；act16 tile → Q(16)=17 拍、act8 → 11 拍（现有公式）。
- requant/写回：直接用现有 dense 16-lane 通道（16B 单 beat / 8B×2），无新逻辑。

## 2. 周期公式（v3 扩展）
```
dw 16-lane:
  num16 = dw 层 tile 数（C8>=16 → ceil(OC8/16)），num8 = 1（C8==8 时）
  cycles = BASE + Σ_tiles Q(act) + Σ_tile NB·(1 + K·per_tile + DRN3 + REQ(act) + NEXT2)
  per_tile = (count+1) + 1 + K      （band 装载 + WI + K 次 MAC；与现 8-lane 相同）
  其中 NB = oh·ceil(ow/8)（16-lane 时 NB 不变，因为 PX=8；每个 tile 处理 8 px×16 ch）
```
- 说明：16-lane dw 每个 block 处理 8 px × 16 ch = 128 MAC；MAC 拍数 per_tile 不变（K 拍），
  **tile 数减半** ⇒ dw 周期 ≈ 0.5×（C8>=16 的层）。
- C8=8 层保持 8-lane（同现公式）。

## 3. 实现步骤
1. 新增 `dense16_r`（是否 16-lane）与 dw 的 band 装载分支：dw16 时 band word 128b、地址 `(pixel+C8·? )` 增量；
2. abuf 宽度 64b→128b（dw16 用），或 dw16 复用 packed3 的二级窗缓冲（推荐后者，避免全数组加宽）；
3. MAC 选择：dw16 时 `a_pipe[px][lane] = win128[lane*8 +:8]`（16 lane），权重 `w_rdata[lane*8+:8]`；
4. Q/写回走现有 dense16 路径（act_l=16）；
5. 8-lane 层保持现有路径（用 `dw8` 标志选择）。

## 4. 预期收益
- C128：dw 449k → 约 230–250k（C8>=16 的 26 层减半）⇒ 总周期 ~0.95M（−18%）。
- C320：粗估 7.3M → ~6.0M 拍 @100MHz ≈ 60ms = 16.7fps（+3fps）。
- 与 PX16 叠加后（研究文档）可到 23–26fps。

## 5. 风险
- dw16 band 装载 offset=8 的跨窗问题（C8=24/40 等）：需要二级窗或两次读，公式要加 +1 拍/位置的少数情况；
- 与 conv16 共用数组可能加大 LUT/FF；建议 dw16 band 用独立 128b 小缓冲（~2KB FF）。
