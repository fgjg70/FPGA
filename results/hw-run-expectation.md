> **范围/口径声明（证据/迭代文档）**：本文是开发迭代记录或证据文档，"实测"特指上板实测（附日志/清单路径），"派生/仿真"已分别标注。**Artix-7 XC7A100T 的所有数据按赛题规则仅作跨厂商对比**，交付主体为紫光同创 PG2L100H；完整边界见根 [`COMPLIANCE.md`](COMPLIANCE.md)。

# 上板跑分预期值 (算好待比对)

| 项 | 值 |
|---|---|
| 镜像 | `sim/prog/cm_hw.hex` (ITERATIONS=**1200**, -march=rv32im) |
| 单次迭代 tick | 423,527 (仿真实测) |
| **预期 tick 总数** | **508,232,400** = `0x1E4B02D0` |
| **预期运行时长 @50MHz** | **10.16 s** ✅ 满足赛题 >=10s |
| **预期打包值** | `0x9E4B02D0` |
| 预期 CoreMark/MHz | 2.3611 |

## 判定规则 (读回 probe3 = score_result)

```
bit31   = 1  -> 三个数据类 CRC (0xe714 / 0x1fd7 / 0x8e3a) 全部匹配官方值, 算对了
bit30:0      -> 实测 tick 数, 应接近 508,232,400
CoreMark/MHz = 1200e6 / ticks
```

## 两次抓取

| 脚本 | 触发 | 用途 |
|---|---|---|
| `fpga/ila_cap_mark.tcl` | probe2[5] = mark | 抓测量区间起点的 2048 拍流水线波形 (分析报告用) |
| `fpga/ila_cap_done.tcl` | probe2[6] = done | 读回最终判定与 tick 数 |

bitstream: `fpga/ila_proj.runs/impl_1/top_a100t.bit`
(注意: `create_project` 把最后一段当工程名, 所以是 `ila_proj.xpr` + `ila_proj.runs/`,
**不在 `ila_proj/` 子目录里** —— 抓取脚本的路径已按此修正)
