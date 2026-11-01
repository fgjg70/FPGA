# nn_mem OOC DCP 时钟周期变体（2026-11-01 19:5x，T-mem）

背景：125MHz 全实现 post-route **WNS = −3.817ns**（实际路径 ≈11.817ns → 整机 fmax ≈ **84.6MHz**），
降频保交付（NPU 硬下限 50MHz）。本目录预生成多个 **同网表、仅 create_clock 周期不同** 的 DCP
（每个变体单独 OOC synth，`-directive Default`，W/Q 初始化镜像同 canonical）；
整机黑盒流程按目标频点选文件即可（不改 RTL / 不改 tile 数）。

## 文件清单（同目录 `results/ai-accel/impl/nn_mem_ooc/`）

| DCP 文件 | 频率 | 周期(ns) | sha256 | Block RAM Tile | OOC WNS @该周期 |
|---|---|---|---|---|---|
| `nn_mem_12p500.dcp` | **80 MHz（首选交付频点）** | 12.500 | `2e7c329ae3655dbd03889aa751f6d7fb6724d91ad8afb25df55bd798bf74d2f3` | 120 | **+6.806** |
| `nn_mem_11p428.dcp` | 87.5 MHz（备选） | 11.428 | `c053d2f494e61225c0a046e655267fbf8574d9555114819d10303ae58907a3e5` | 120 | **+5.734** |
| `nn_mem_10p500.dcp` | 95.45 MHz（保底） | 10.500 | `57cc499fa645809360cfd5b8bf58404e88e9db80e328523bd7ddb14341b28acd` | 120 | **+4.806** |
| `nn_mem_10p000.dcp` | 100 MHz | 10.000 | `aa99b4c74038e6a73426d9d9fb64ffa01a90b2cf10d4516fb05ee077e969653a` | 120 | **+4.306** |
| `nn_mem_9p524.dcp` | 105 MHz | 9.524 | `eae3c808a283cec2c2c2e2b342dccaf6b49c129624df0f14691fd5a90d0ef5db` | 120 | **+3.830** |
| `nn_mem.dcp`（canonical） | 125 MHz | 8.000 | `c56bb34759bfe42f21a7df0ad304bb2fe6216c7a7cceeb2e45ead7f8b816cda6` | 120 | +2.306 |
| `nn_mem_7p619.dcp` | 131.25 MHz | 7.619 | `6ee7795cccec976f043aff8d3941c03407c260f5f0751614e37eb04d2affe1bd` | 120 | **+1.925** |
| `nn_mem_7p000.dcp` | 142.86 MHz | 7.000 | `a1ecf510e79e289775dba780e6ea7fcec2bef392404d419754a01eb60c74e82b` | 120 | **+1.306** |

> - 全部 **RAMB36=120 / RAMB18=0 / FDRE=90 / LUT≈2,456**（W80 + Qlo8 + Qhi(LUT)0 + A/B32；
>   网络内容与 canonical 8.0ns 等价，只综合目标周期不同）。
> - WNS 口径：DCP 内只有 `create_clock -name clk`；表内 WNS 是 `open_checkpoint` 后临时加
>   0.5ns 虚拟 I/O 的**报告值**（不写回 DCP），worst path 不变（`w_cur_a_reg → w_rdata`）。
> - 严格线性可交叉验证：`WNS(period) = period − 5.694ns`（8 个点全部吻合）。

## 频点决策（r11 post-route 实测）

- r11 @125MHz post-route **WNS = −3.817ns** ⇒ 整机实际最差路径 ≈ **11.817ns**、fmax ≈ **84.6MHz**；
  瓶颈在**顶层集成/拥塞**（OOC engine+mem 有 +1.37~2.3ns 余量，mem 自身 @7ns 仍 +1.306），非 mem。
- **80MHz(12.500ns)**：预期整机 ≈ **+0.68ns** → **首选交付频点**（满足 NPU ≥50MHz 硬下限）；
- **87.5MHz(11.428ns)**：预期 ≈ **−0.39ns** → 需 physopt 后 WNS 好于 ≈−3.4ns 才可能过，备选；
- 95.45/100MHz 需先做时序优化（E1-全量 + 核心 NN 窗口路径）后再说；
- 131.25/142.86MHz 仅作以后冲高频备用（mem 侧余量充足，整机瓶颈不在这里）。

## 复现命令

```bat
cd results\ai-accel\impl\nn_mem_ooc
rem 生成一个频点变体（约 1 分钟/个）:
vivado -mode batch -source synth_nn_mem_clockvar.tcl -tclargs 12.500 12p500
rem 汇总验证全部变体（open_checkpoint，不重综合）:
vivado -mode batch -source check_clockvars.tcl
```
产物：`nn_mem_<tag>.dcp` + `nn_mem_<tag>_{util,timing,paths}.rpt`；汇总表在 `check_clockvars.rpt`。
