# 上板自主读回 (ILA over JTAG) — 2026-10-05

## 问题: 串口读不回来

本板 FT2232H 只有 D2XX 驱动、没有 COM 口, CH340 也都不在。**没有串口接收通道**,
所以"程序跑完了吗、跑了多少周期、算得对不对"无法用常规 printf 读回。

## 方案: 软件上报 + ILA over JTAG

软件通过 MMIO 把结果告诉硬件, 硬件用 ILA 抓, PC 端经 JTAG 读回:

| MMIO | 地址 | 语义 |
|---|---|---|
| MMIO_MARK   | 0xA0000020 | W: 单拍脉冲, **ILA 触发点** = 测量区间起点 |
| MMIO_RESULT | 0xA0000024 | W/R: 锁存结果并置 done |

**一个 32 位寄存器打包两件事** (上板只能回读一个数):
```
bit31   = 1 表示三个数据类 CRC 全部等于 CoreMark 官方参考值
bit30:0 = 实测 tick 数 (1200 次迭代约 5.08e8, 只占 29 位)
```

**为什么是这三个 CRC**: 实测 `crclist/crcmatrix/crcstate` 与迭代次数**无关**
(ITERATIONS=1 与 3 完全一致), 只有跨迭代累积的 `crcfinal` 会变。所以它们是判定
"硬件算得对不对"的硬依据, 不受 10 秒要求带来的迭代次数影响。

## ILA 配置

| probe | 宽度 | 内容 |
|---|---|---|
| probe0 | 32 | dbg_pc (IF 段取指地址) |
| probe1 | 32 | dbg_instr |
| probe2 | 8  | {done, mark, redirect, stall, illegal, pass, fail} |
| probe3 | 32 | score_result (打包后的判定+tick) |

- 触发 A: probe2[5] = mark → 抓测量区间起点的 2048 拍流水线波形 (分析报告用)
- 触发 B: probe2[6] = done → 读回最终判定与 tick 数

**ILA 只在 `USE_ILA 时例化在顶层** —— CPU core 本身不含任何厂商 IP,
正式评分构建 (build.tcl) 不带 ILA。

## 踩的四个坑

### 1. `exit()` 里的上报是死代码
CoreMark 的 `exit()` **根本没被调用** —— 程序是靠 crt0 在 `main` 返回后写 tohost
结束的。反汇编里只有 mark 那条 `sw`, 没有写 MMIO_RESULT 的。
**上报改放 `stop_time()`** (测量区间结束处必然执行, 且 `stop_time_val` 刚读到)。

### 2. Tcl 里 `[...]` 内的换行是命令分隔符, 不是列表分隔符
```tcl
add_files -norecurse [list \
    "a.sv"
    "b.sv" ]
```
这样写 `[list` 在第一个元素后就结束, 第二个元素被当成新命令执行:
`invalid command name "b.sv"`。**文件列表必须写在一行**。

### 3. Vivado IP 生成器初始化失败 (竞态)
`Error initializing slave interpreter '::ipgen_iptclns'` +
`couldn't read file .../grammar_me/pkgIndex.tcl` —— 但该文件其实存在。
原因是**两个 Vivado 实例重叠**。串行化构建 + 补上 `XILINX_VIVADO` 环境变量后正常。

### 4. `results[]`、`total_time` 都是 `main()` 的局部变量
`core_portme.c` 拿不到。解法: 在 `core_main.c` 里加 `extern` 全局, 在 `stop_time()`
之前把首轮 CRC 填进去。

## 内存布局调整 (连带影响面比想象大)

CoreMark 的 `.data+.bss` 正好用满 4KB (2064+2032=4096), 上板验证再放几个全局变量
12 字节就 `overflow past 0x90001000`。把 **tohost 从 0x90001000 上移到 0x90002000**,
`.data/.bss` 扩到 8KB:

```
0x90000000 .. 0x90001FFF   .data / .bss   (8KB, ASSERT 守卫)
0x90002000 .. 0x90002003   tohost
0x90002004 .. 0x90002BFF   栈 (顶 0x90002C00)
0x90003000 .. 0x90003FFF   日志缓冲区
```

**必须同步改的地方 (漏一个就静默挂)**: `sw/link.ld` (PROVIDE + ASSERT)、
`sw/portme.c`、`sw/crt0.S`、`sw/coremark/core_portme.c`、`fpga/top_a100t.sv`、
`sim/tb_core.sv` `tb_soc.sv` `tb_sw.sv` 的 TOHOST_ADDR、以及
`sim/prog/*.S` 里硬编码的 tohost 地址 (basic/mmio/m_ext 共 19 处)。
**症状**: 程序跑到 `j .` 自己转圈, tb 报超时 —— 因为 tb 在新地址上看不到写入。

另: `hello.c` 用 build_sw 重建时要带 `sw/portme.c`, 但**不要**再传 `libc_min.c`
(build_sw 已自动包含, 重复会 multiple definition)。
