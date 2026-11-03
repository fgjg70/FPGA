> **范围/口径声明（证据/迭代文档）**：本文是开发迭代记录或证据文档，"实测"特指上板实测（附日志/清单路径），"派生/仿真"已分别标注。**Artix-7 XC7A100T 的所有数据按赛题规则仅作跨厂商对比**，交付主体为紫光同创 PG2L100H；完整边界见根 [`COMPLIANCE.md`](COMPLIANCE.md)。

# 分支预测 v1 (BTB + 2 位方向预测器) — 2026-10-05

## 结果: 三项评分指标 2 升 1 降

| 指标 | 基线 | 现在 | 变化 |
|---|---|---|---|
| **CoreMark/MHz** (执行效率) | 0.8263 | **1.0274** | **+24.3%** |
| **CoreMark/LUTs** (资源效率) | 2.361e-4 | **2.650e-4** | **+12.2%** |
| **最高时钟频率** | 78.4 MHz | **70.1 MHz** | **-10.6%** |
| Total ticks | 1,210,148 | 973,352 | −19.6% |
| redirects | 184,890 | 59,466 | −67.8% |
| CPI | 1.21 | 1.10 | |
| LUT / FF / BRAM | 3499 / 732 / 0 | 3877 / 862 / 0 | |
| CoreMark CRC | 全对 | **全对** | ✓ |

**净评价**: 赛题三项指标里赢两项 (执行效率 +24.3%、资源效率 +9.3%)、输一项 (频率 −10.6%)。
绝对吞吐 (CoreMark/MHz × fmax) 从 64.8 升到 72.0 (**+11.2%**)。
**fmax 是待还的技术债, 不是失败** —— 见下节。

## 设计

- `btb.sv`: 64 项直接映射, 每项 {valid, tag, target, ctr[2]}。组合读用于 IF 预测。
- 2 位饱和计数器 = 经典 Smith 预测器; 新条目按首次结果初始化。
- **IF 预测 / EX 校验**; 预测结果随 IF/ID → ID/EX 传递 (不做这一步 EX 无法判断预测对错)。
- **关键语义改动**: `redirect_raw` 从"分支 taken"重定义为 **"预测错误"**。
  预测正确时绝不冲刷, 否则两条正确路径被白丢, 收益归零。
- 重定向目标 = 正确后继 PC: 实际 taken → 控制流目标; 不 taken → **id_ex_pc_plus4**。

## 关键路径分析 (fmax 为什么降)

关键路径 (加 BTB 后): `ex_mem_rd → hazard/前递 (fwd_b fanout 34) → ALU → 目标选择 → pc`

实测 **logic 仅 3.7 ns, route 占 9.99~11.0 ns (72~75%)** —— 是**布局/扇出**问题, 不是逻辑深度。
对策与实测:
| 措施 | fmax |
|---|---|
| 无 (只 synth/opt/place/route) | 65.1 MHz |
| + `phys_opt_design` | 65.9 MHz (几乎无效) |
| + `place_design -directive ExtraTimingOpt` + `route_design -directive AggressiveExplore` | **70.1 MHz** ✅ |

另外一个已消除的路径贡献: 第一版在关键路径上写 `id_ex_pc + 32'd4`(额外 32 位加法器),
改用流水寄存器里现成的 `id_ex_pc_plus4` 后 WNS 4.636→4.825。

**还债方向** (留给后续):
1. 给 PC 目标计算**独立的小加法器**, 不要把 ALU 的全部运算结果 mux 串在 pc 路径上
   (现在 ALU 是"兼职目标加法器", 省了面积但加了关键路径)。
2. 前递 mux 的高扇出 (fwd_b fanout 34) 值得用复制/分级降低。
3. 更彻底: 分支判定前移到 ID (惩罚 2→1 拍), 但会加长 ID 关键路径, 需权衡。

## 决策依据: 先测量再优化

优化前用测试台层次化引用 core 内部信号做性能剖析:

```
fetch = 1,053,936   redirects = 184,890 -> 2拍/次 = 369,780 周期 = 29%  ← 绝对瓶颈
stalls = 36,488 (2%)                CPI = 1.21
条件分支 217,875 (taken 61%) = 全部指令的 20.7%
JAL 33,183        JALR(函数返回) 17,865
```

## 踩到的两个坑

### 1. 重定向目标用错 → 程序跑飞
第一版把 `actual_target` 写成"非 PC_NEXT 就取 ex_pc_target"。但**条件分支不 taken 时
ex_pc_target 是分支目标而不是后继**; BTB 一旦预测 taken 而实际不跳, PC 就被送进错误路径。

### 2. JAL 链接值前递 —— 被新特性暴露的老 bug (最有价值的一条)
`jal ra, f` 紧跟 `mv t0, ra` 是**距离 1** RAW。jal 在 EX/MEM 时 alu_out 是跳转目标,
但链接值 (PC+4) 也在同一流水寄存器里 (`ex_mem_pc_plus4`)。

早先按审查报告 §1.6 做过"防御性"修改: 把 WB_PC4 从 EX/MEM 前递中**排除** —— 那是错的。
正确做法是**按 wb_src 换前递源**:
```systemverilog
wire [31:0] ex_mem_fwd_data = (ex_mem_ctrl.wb_src == WB_PC4) ? ex_mem_pc_plus4
                                                            : ex_mem_alu_out;
```
排除后消费者只能拿到 ID 段读到的陈旧 ra。**加预测之前它被 2 拍冲刷掩盖着**
(jal 后的指令被冲掉重取, 到 WB 时 ra 已写好), 预测一生效立刻暴露 ——
表现为 libgcc 的 `__umodsi3` 陷入死循环 (`jr t0` 自我跳回)。

正是审查报告 §1.6 预言的那类潜伏 bug: "今天触发不了, 改了重定向就会算错"。
只是触发它的不是改重定向, 而是**加分支预测**。

## 复现
```bash
python tools/run_coremark.py --tag <名字> --iterations 1 --record
python tools/build_sw.py sw/coremark/*.c -I sw/coremark -D ITERATIONS=1 \
    -D 'FLAGS_STR="-Os -march=rv32i"' -o sim/prog/coremark.hex
```
