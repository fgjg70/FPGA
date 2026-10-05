# BRAM 存储系统 — 2026-10-05

## 结果: 三项里两项达到历史最好, fmax 退步

| 指标 | 分布式 RAM 版 | **BRAM 版** | |
|---|---|---|---|
| **CoreMark/MHz** | 2.3614 | **2.3614** | 持平 (历史最好) |
| **CoreMark/LUTs** | 5.254e-4 | **9.518e-4** | ✅ **+81% (历史最好)** |
| **最高频率** | 74.6 MHz | 63.9 MHz | ❌ −14% |
| Slice LUTs | 4494 | **2481** | ✅ **−45%** |
| LUT-as-Distributed-RAM | 2131 | 83 | |
| **Block RAM Tile** | 0 | **4** | ✅ |
| FF / DSP | 1050 / 8 | 1059 / 8 | |
| Total ticks | 423,486 | 423,486 | 零性能损失 |
| load-use 停顿 | 30,644 | 30,644 | 不变 |
| CRC | 全对 | **全对** | ✓ |

## 为什么必须改寄存读

组合读无法映射到 BRAM, 只能落分布式 RAM。16KB 的 dmem 吃掉 **2131 个 LUT**
(占全核 4494 的 47%), 而且 "分布式 RAM + 64 位移位器" 正是本核原来的关键路径
(13.2ns, route 占 80%)。改成寄存读后整块交给 BRAM, LUT 直接砍掉 45%。

**这是纯行为级推断, 没有例化任何厂商 IP** —— Xilinx 与紫光同创的 BRAM 原语不同
(36Kb vs 18Kb), 例化 IP 就锁死了, 行为级推断才能零成本迁移 PDS。同时它也是赛题
高阶任务 (2 路组相联 Cache) 的前置条件。

## 怎么做到"零性能损失"

读数据晚一拍。**没有加流水线级数, 也没有增加 load-use 停顿**, 做法是:

1. **把"字节提取 + 符号扩展"整体挪到 WB 段组合完成**。BRAM 的输出寄存器就充当了
   原来 MEM/WB 里那份 load 数据的寄存器 —— 写回 mux 直接用 LSU 的 WB 拍组合输出,
   不再经过第二个寄存器。
2. **WB 段影子寄存器** (`off_wb/size_wb/uns_wb/split_wb`) 在访存请求离开 MEM 那一拍
   记下它的规格, 供 WB 拍提取使用 (WB 拍时 EX/MEM 已换成下一条指令, 不能再读 req_*)。
3. **MMIO 读数据在 core.sv 里同样寄存一拍**, 否则内部 dmem 与外部 MMIO 两条路径
   差一拍, 写回 mux 会取错。
4. 跨字访问状态机改成 IDLE->HEAD->TAIL 三拍 (原来两拍), TAIL 拍继续送尾字地址,
   让 WB 拍 `dmem_rdata` 仍是尾字。CoreMark 里跨字访问为 0, 基础测试覆盖。

## fmax 为什么退步, 以及怎么还

新关键路径:
```
Source:      u_core/u_dmem/mem_reg_3/CLKBWRCLK      (BRAM 输出寄存器)
Destination: u_core/u_pc/pc_reg[2]/D
Data Path:   15.245ns (logic 4.948, route 10.297)
Levels:      18 (CARRY4=4 LUT5=5 LUT6=6 LUT3=2 LUT4=1)
```

即 **"load 出来的值直接当 jalr 的目标"** —— 典型场景是从栈上恢复 ra 后返回, 极常见。
完整链路: BRAM 输出 -> 字节提取 -> 写回 mux -> 前递 mux -> ALU 加法器 -> 目标 mux -> PC,
全部压在一拍内。

**旧版为什么没这个问题**: 提取逻辑在 MEM/WB 寄存器**之前**, 前递路径从寄存器出发, 短。
新版把提取挪到了寄存器**之后**, 于是它落进了前递路径。

**还债方向** (按代价排序):
1. **load 结果寄存器 + 专用前递通道**: 把提取结果在 WB 拍末打进一个 `load_result` 寄存器,
   前递改从它取 (寄存器出发, 路径短)。代价: load-use 停顿 1->2 拍, 约 +7% 周期。
2. **缩短 PC 目标选择链**: 给 JALR 的目标加法器用独立的 2:1 操作数 mux (现在要穿
   ALU 的 3:1 `ex_a` mux), 并把三级目标 mux 压成一级 LUT6。
3. **dmem 保持组合读但缩小容量**: 把 log 缓冲区从 0x90003000 挪低, dmem 从 16KB 降到
   4KB, LUT-as-RAM 2131->约 530, fmax 不受影响。缺点是不是 BRAM。

## 踩的坑

1. **`(expr)[31:0]` 在 SystemVerilog 里非法** —— 不能对括号表达式做位选, 必须先赋中间 wire。
2. **store 的移位量错用了 WB 影子寄存器的 `off_wb`** —— 影子属于上一条已进入 WB 的
   访存指令, 拿它移位会把数据挪错位置。基础测试直接跑挂 (tohost 变成 0x40000)。
   store 必须用当前请求的 `off`。

## 复现
```bash
vsim -c -do "run -all; quit -f" work.tb_sw +imem=<abs>/cm_rv32im.hex +dmem=<abs>/cm_rv32im.dmem.hex
```
