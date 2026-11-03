> **范围/口径声明（证据/迭代文档）**：本文是开发迭代记录或证据文档，"实测"特指上板实测（附日志/清单路径），"派生/仿真"已分别标注。**Artix-7 XC7A100T 的所有数据按赛题规则仅作跨厂商对比**，交付主体为紫光同创 PG2L100H；完整边界见根 [`COMPLIANCE.md`](https://github.com/fgjg70/FPGA/blob/main/COMPLIANCE.md)。

# RV32M 扩展 — 2026-10-05

## 结果: 三项指标全面提升

| 指标 | baseline-v1 | branch-pred-v1 | **m-ext-v1** | 相对基线 |
|---|---|---|---|---|
| **CoreMark/MHz** | 0.8263 | 1.0274 | **2.4151** | **+192%** |
| **最高时钟频率** | 78.4 MHz | 70.1 MHz | **64.7 MHz** | -17.5% |
| **CoreMark/LUTs** | 2.361e-4 | 2.581e-4 | **5.329e-4** | +126% |
| Total ticks | 1,210,148 | 973,352 | **414,062** | −65.8% |
| redirects | 184,890 | 59,466 | **11,501** | −93.8% |
| LUT / FF / BRAM / DSP | 3499 / 732 / 0 / 0 | 3877 / 862 / 0 / 0 | 4532 / 1032 / 0 / 8 | |
| CRC | 全对 | 全对 | **全对** | ✓ |

**为什么收益这么大 (+135% 相对 rv32i)**: 不只是把软件乘除换成单条指令 ——
libgcc 的 `__mulsi3/__udivsi3/__umodsi3` 是**函数调用 + 循环**, 本身分支密集。
启用 M 之后 **redirect 从 59,466 掉到 11,501 (−81%)**, 说明那部分分支流量整个消失了。
代码体积也从 10696 降到 9476 字节 (−11%)。

## 实现要点

`muldiv.sv`:
- **乘法**: 组合单周期。只用 **2 个** 32x32 乘法器 (映射到 DSP48) ——
  MULHSU 用恒等式降维, 不必实例化第三个:
  ```
  signed(a)*unsigned(b) = signed(a)*signed(b) + signed(a)*(b[31] ? 2^32 : 0)
  => high32(MULHSU) = high32(prod_ss) + (b[31] ? a : 0)
  ```
- **除法**: 32 步恢复余数, 多周期; `busy` 经 hazard_unit 冻结流水线。

## 三个真踩到的坑 (全在除法的时序与位宽上)

### 1. 余数必须 33 位
恢复余数法里 rem 左移一位再补进被除数最高位。只用 32 位时, 若除数 > 2^31,
rem 会到 2^31 量级, 左移丢位 → 结果错。

### 2. `busy` 必须覆盖"启动那一拍"
若 busy 只由"迭代中"标志驱动, 启动拍流水线不冻结, DIV 会在结果出来前就离开 EX。
症状: m_ext 第 6 组 (有符号除法) 一上来就失败。

### 3. 单周期的除零/溢出同样要占一拍
除零与 INT_MIN/-1 溢出是单周期出结果, 但它们**同样**需要在 `div_result` 寄存之后
再放行流水线 —— 否则结果和指令在同一个时钟沿离开 EX, EX/MEM 捕获到的是**上一次**
的 div_result。症状: m_ext 第 8 组 (除零) 失败。

统一判据: `busy = 迭代中 || (是除法 && 结果尚未寄存)`。

### 附带: 一个静默配置错误
`build_sw.py` 里把 `-march=rv32i` **硬编码**了。我用 `-D FLAGS_STR=-march=rv32im`
以为切过去了, 结果只改了 CoreMark **打印出来的字符串**, 生成的镜像逐字节相同
(两次 ticks 都是 973352 —— 正是这个"过于一致"暴露了问题)。
现在 `build_sw.py` 有 `--march` 参数, `run_coremark.py` 也透传。

## 复现
```bash
python tools/build_sw.py sw/coremark/*.c -I sw/coremark -D ITERATIONS=1 \
    -D 'FLAGS_STR="-Os -march=rv32im -mabi=ilp32"' --march=rv32im \
    -o sim/prog/cm_rv32im.hex
vsim -c -do "run -all; quit -f" work.tb_sw +imem=<abs>/cm_rv32im.hex +dmem=<abs>/cm_rv32im.dmem.hex
```
