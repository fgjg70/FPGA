# PG2L100H CPU 50 MHz 历史版本

本目录恢复自2026-11-02 20:22:58保存的 `fpga_pg2l100h.zip`，对应修正18针OV7670接口和180度画面旋转后的50 MHz工程。构建清单中的54个输入文件均与备份校验值一致；来源、文件哈希和补齐的公共依赖记录在 `SOURCE_SNAPSHOT.json`。本目录保留文件原始字节，便于核对历史构建清单。

| 部分 | 配置 |
|---|---|
| CPU、指令存储、数据存储 | 50 MHz，直接使用板载时钟 |
| NPU、MMIO、摄像头采集 | 50 MHz |
| 视频扫描 | 27 MHz |
| LCD像素时钟 | 9 MHz |
| 摄像头MCLK | 12.5 MHz |
| 器件 | PG2L100H / -6 / FBG676 |
| 摄像头 / LCD | 18针DVP OV7670接J7，AN430接J11 |

活动RTL位于 `fpga_pg2l100h/vision/rtl/`，使用Verilog-2005。备份中的模型为数字0～9和旧九类手势实验模型；功能及限制见该目录原有README。本目录中的顶层SystemVerilog文件保留CPU转换来源，PDS应用工程使用 `rtl/cpu/` 中的Verilog版本。

## 生成和打开工程

在仓库根目录执行：

```powershell
cd releases/cpu50mhz
python fpga_pg2l100h/vision/build.py --prepare-only --pds-home E:/pango/PDS_2022.2-SP6.1 --lcd-header J11
python fpga_pg2l100h/vision/build.py --check
```

脚本会查找RISC-V GCC；也可通过 `RISCV_GCC` 或 `--gcc` 指定编译器。PDS安装目录按实际位置替换。生成后打开：

```text
releases/cpu50mhz/fpga_pg2l100h/vision/build/j11/pg2l100h_vision.pds
```

工程、固件、模型ROM及引脚约束均在本目录内生成。完整执行PDS综合、布局布线和位流生成时，使用：

```powershell
python fpga_pg2l100h/vision/build.py --pds-home E:/pango/PDS_2022.2-SP6.1 --lcd-header J11
```

## 验证记录

`evidence/original_project_manifest.json`、`original_build_summary.json`、`original_hardware_summary.json` 和 `original_simulation_summary.json` 保留备份时的历史记录。历史原生构建时序通过，50 MHz建立WNS为+8.111 ns；记录中的位流SHA256为 `9e05a4b2a24ec27dc05505a45ac4654aa9915417c6af9fa2b0b487685b7f8ef6`，已完成当时的JTAG RAM下载，应用完整验收尚未完成。

本次恢复后的检查记录在 `evidence/restoration_validation.json`。恢复源码期间未重新烧录FPGA，也未重新运行CoreMark跑分。
