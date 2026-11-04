# 证据登记表（docs/EVIDENCE.md）

> 每个"对外数字"必须能在此表找到一行。级别定义见 [`COMPLIANCE.md`](../COMPLIANCE.md) §2。
> 状态：✅ 已入库 / ⚠️ 部分或待补 / 🔲 缺失。

## 1. 交付主体（PG2L100H）

> **当前烧录版本 = 95 MHz 双发射**（2026-11-04，位流 `51f5eda2…`），详见 [`fpga_pg2l100h/vision/CURRENT-BUILD.md`](../fpga_pg2l100h/vision/CURRENT-BUILD.md)。
> 下表 P-01~P-05 描述的是**上一版 125 MHz 单发射**（位流 `f179a403…`），保留作历史对照。

| # | 结论/数字 | 级别 | 证据路径 | 状态 |
|---|---|---|---|---|
| P-01 | CPU/IMEM/DMEM 125 MHz，WNS +0.609 | C | `fpga_pg2l100h/vision/BOARD_VALIDATION.md`；PDS 时序报告 | ✅（报告需入库） |
| P-02 | NPU/采集/MMIO 50 MHz，WNS +7.052 | C | 同上 | ✅ |
| P-03 | LUT 4469 / FF 3706 / APM 10 / DRM 64 | C | 同上；PDS 资源报告 | ✅ |
| P-04 | 芯片 ID 0x00602899 / DONE=1 / 5 项配置错误全 0 / PLL 锁 0→1 | A | 同上（JTAG 状态读回记录） | ✅ |
| P-05 | 位流 3,791,112 B，SHA256 `f179a403…` | — | 同上 | ✅ |
| P-06 | 摄像头→LCD 预览目视确认 | A | 同上，2026-11-03 记录 | ⚠️ 建议补照片/视频帧 |
| P-07 | NPU 纯计算 1,769,238 周期 @50 MHz = 35.38 ms | B/C | `fpga_pg2l100h/vision/competition/ACCEPTANCE.md` | ⚠️ 原始串口/波形待入库 |
| P-08 | NUMGUARD 业务核验统计 | A | `competition/ACCEPTANCE.md`（待实测样本） | 🔲 待补 ≥30 样本/类 |
| P-09 | Pango CoreMark 跑分（赛题主口径） | A | 待产出 `validation/coremark_hardware.json` + 原始串口 | 🔲 **缺失（R-2）** |
| P-10 | Flash 自启动 | A | 待产出（当前未写入） | 🔲 **缺失（R-1）** |
| **P-11** | **当前烧录：CPU 95 MHz 双发射，WNS +0.493（All Constraints Met）** | C | `build/dual_j11/place_route/…timing_summary_after_hold_fix.txt` | ✅ 报告已入库 |
| **P-12** | **当前烧录资源：LUT 9980 / FF 6573 / APM 13 / DRM 99** | C | `build/dual_j11/device_map/run.log` | ✅ |
| **P-13** | **当前烧录位流 3,791,112 B，SHA256 `51f5eda2…`** | — | `build/dual_j11/generate_bitstream/top_pg2l100h_vision.sbit` | ✅（文件已入库） |
| **P-14** | 当前烧录功耗 ≈1.02 W（PDS `report_power`） | C | `build/dual_j11/report_power/`、`multiseed_summary.csv` | ✅ |
| **P-15** | 当前烧录**上板实测记录** | A | —— | 🔲 **缺（`hardware_tested: false`，无下载日志/照片）** |

## 2. Artix-7 对比线（[跨厂商对比]，不构成交付成绩）

| # | 结论/数字 | 级别 | 证据路径 | 状态 |
|---|---|---|---|---|
| A-01 | 交付档 150 MHz，WNS +0.007；LUT 3098/FF 1447/BRAM 9/DSP 8 | C | `results/coremark.csv` 行 `legal150-*`；`.fpga-cache/reports/` | ✅ |
| A-02 | QSPI Flash 自启动（断电重启） | A | `results/uart_flash_boot_final.txt`、`results/flash_done.txt` | ✅ |
| A-03 | CoreMark 324.19（`-Os` 旧固件，14 s） | A | `results/uart_flash_boot_final.txt` | ✅ |
| A-04 | 405.9（`-O2` 配方派生） | D | `results/NEXT-BURN.md`（公式+输入），**从未上板** | ⚠️ 仅派生 |
| A-05 | AI 线 112-op 双模 E2E PASS（hw_bad=0/auto_bad=0） | B | `feat/ai-accel`: `results/ai-accel/DELIVERY.md`、日志 | ✅（分支内） |
| A-06 | NPU 1,191,020 周期；SW 473,254,313 周期；401.9× | B | 同上 + `impl/swprobe/sw112_full.log` | ✅（分支内） |
| A-07 | 100 MHz 位流 sha `537af245…`；最高 122.22 MHz | C | `feat/ai-accel` 文档/bitstream | ✅（从未上板） |

## 3. 待补证据清单（按优先级）

1. 🔴 **Pango Flash 自启动**（P-10）——现场演示生死项。
2. 🔴 **Pango CoreMark 原始日志 + JSON**（P-09）——赛题 1.4 主口径。
3. 🔴 **设计报告（Word/PDF）+ 演示视频**——赛题 1.8 硬性提交物。
4. 🟠 P-07 原始串口/波形；P-06 照片/视频帧；P-08 验收样本统计。
5. 🟡 `validation/hardware_*` 目录入库（BOARD_VALIDATION 引用的路径目前不在仓库）。
