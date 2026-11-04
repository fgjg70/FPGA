# PG2L100H 最终工程

本目录保留 2026-11-04 17:48 已写入板上 Flash 的三功能版本：CoreMark、手势 1～5、瓶盖识别。CPU 为 95 MHz 双发射 RISC-V，NPU 为 50 MHz、128 MAC，模型与中间数据使用片上存储。

## 打开工程

使用 Pango PDS 2022.2-SP6.1 打开：

`fpga_pg2l100h/vision/build/dual_caps_sorter128_j11/pg2l100h_vision.pds`

工程目录包含本次构建的 RTL、固件 HEX、模型 ROM、管脚约束、完整实现结果和时序报告，可直接打开并重新综合。原 `manifest.json` 保留编译时的输入记录；当前保留文件的逐项校验值见根目录 `RELEASE_MANIFEST.json`。

- `fpga_pg2l100h/vision/firmware/`：本版应用 C 源码和启动代码。
- `fpga_pg2l100h/vision/competition/`：CoreMark 的 RISC-V 平台适配源码。
- `fpga_pg2l100h/vision/build/coremark_source/`：本版使用的 CoreMark 源码及许可证。
- `fpga_pg2l100h/vision/model/`：本版选中的瓶盖和手势模型权重与配置。
- `fpga_pg2l100h/vision/validation/`：本版仿真、整数输出比对、运行回归及实板烧录记录。

## 操作与接线

上电默认进入瓶盖模式。SW2 复位，SW4 执行 CoreMark，SW5 选择瓶盖自动分拣，SW6 选择手势识别。摄像头接 J7，LCD 接 J11，舵机信号接 J12。

| 舵机 | 功能 | FPGA 球号 | 接口脚号 |
|---|---|---|---|
| 1 | 每 5 秒下料，保持 500 ms 后回位 | A20 | J12-12 |
| 2 | 绿色瓶盖舱门 | C19 | J12-10 |
| 3 | 黄色瓶盖舱门 | C18 | J12-8 |
| 4 | 红色瓶盖舱门 | A19 | J12-6 |
| 5～7 | 本版不自动启用 | D19、D18、B19 | J12-9、J12-7、J12-5 |

自动流程要求摄像头配置正常且持续完成推理。摄像头异常、冻结或超过 1 秒没有有效推理时，自动动作回位并停止计时；恢复后重新开始 5 秒周期。连续两帧确认单个有效颜色后，在下料前 250 ms 打开对应舱门，下料后保持 2 秒再关门。

PWM 为 50 Hz，回位脉宽 1500 μs，动作脉宽 2000 μs，实际方向由安装决定；参数位于 `firmware/sorter.h`。舵机使用符合其额定电压和电流要求的独立电源，并与 FPGA 共地。J12 只提供 3.3 V 控制信号。用户反馈的舵机无动作问题尚未完成实物定位。

## 位流与烧录结果

位流：`fpga_pg2l100h/vision/build/dual_caps_sorter128_j11/generate_bitstream/top_pg2l100h_vision.sbit`

Flash SFC、烧录 Tcl、工具日志和完整读回：`fpga_pg2l100h/vision/validation/hardware_20261104/caps_sorter128_20261104_1725/`

本版已通过原生时序检查、Flash 工具校验和完整读回 SHA256 比对。从 Flash 重载后的两次状态均为 `0x081ffca0`，DONE 和 PLL 锁定为 1，五项配置错误为 0。位流 SHA256：

`4b8168d78e5fa5a9ad8363b93e01078594db47d2f4f94d8253cd70d3ca5128b9`

12 项回归、128 MAC 的 10 张图像及 4320 个整数输出比对、两次 CoreMark 短测均通过。短测用于执行和 CRC 验证，实板正式 CoreMark 成绩、舵机 PWM 测量与机械动作仍需实物验收。

## GitHub 交付

仓库当前只保留最终版工程、当前模型、固件源码、实现产物、验证记录和 RAR 压缩包。历史工程、训练数据、缓存和操作脚本已从工作区清理。

位流 SHA256：`4b8168d78e5fa5a9ad8363b93e01078594db47d2f4f94d8253cd70d3ca5128b9`
