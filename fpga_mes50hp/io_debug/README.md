> **参考资料声明（第三方/历史工程）**：本目录是板卡厂商示例或早期开发工程，**不是赛题交付主体**；其中的结论/数字不进入交付成绩，引用时需标注来源并置于"跨厂商对比/参考资料"语境。

# MES50HP：HDMI、UART、6 个按键调试工程

目标板卡：盘古 50K / Logos PGL50H，MES50HP，器件选择为 `PGL50H / -6 / FBG484`。
顶层模块是 `rtl/top_io_debug.v` 中的 `top_io_debug`。本目录提供独立的 Verilog 工程、引脚约束、PDS 构建脚本、仿真和电脑串口自检工具。

## 1. 接线和下载

1. 给板卡正常供电，使用 JTAG 下载器连接板卡 JTAG 接口。
2. 将板卡的 **HDMI 输出口 / HDMI OUT / TX** 接到显示器的 HDMI 输入，显示器选择相应输入源。板卡另一个 HDMI 接口是输入口，注意区分。
3. 板卡的 USB-UART Type-C 接口接电脑；在设备管理器找到 **CP2102** 对应的 `COMx`。下载器接口与串口接口的用途不同。
4. 用 PDS 打开构建生成的 `build/mes50hp_io_debug.pds`，通过 `Tools → Configuration` 选择 JTAG 和 `build/generate_bitstream/top_io_debug.sbit`，执行 SRAM 下载。
5. 串口助手设置 **115200、8 数据位、无校验、1 停止位、关闭流控、关闭本地回显**。打开串口后发送英文 `?` 获取状态，或者按一下 KEY1 重新输出启动状态。

显示采用板载 27 MHz 晶振，输出 **720×576、50 Hz、RGB888，576p50 / VIC 17**。显示器需要支持该 HDMI 输入格式；没有音频输出。本工程使用固定视频模式，不根据 EDID 自动切换分辨率。

## 2. 应看到的现象

显示器显示标题 `MES50HP HDMI UART KEY TEST`、两条测试图案带、六个按键状态框、每个按键的计数、串口接收字节数、最近接收字节和错误状态。

| 板上按键 | FPGA 引脚 | 对应 LED | 按下后的图案 |
| --- | --- | --- | --- |
| KEY2 | L15 | LED1 / B2 | 彩条 |
| KEY3 | J17 | LED2 / A2 | 黑白棋盘格 |
| KEY4 | K16 | LED3 / B3 | 红色 |
| KEY5 | J16 | LED4 / A3 | 绿色 |
| KEY6 | J19 | LED5 / C5 | 蓝色 |
| KEY7 | H20 | LED6 / A5 | 灰阶 |

按下一个键，对应 LED 亮、屏幕状态变为 `DOWN`、该键计数增加，松开后 LED 熄灭、屏幕变为 `UP`。每个键独立进行两级同步和约 20 ms 消抖；长按只计数一次。支持同时按下多个键，所有按键均计数，图案优先选择编号最高的键。单键计数为 8 位，`FF` 后回到 `00`；总计数为 32 位。屏幕和串口的数字采用十六进制。

KEY1 / K18 用于复位整个调试逻辑，KEY8 / H17 未接入本工程的六键接口。板上重新加载 FPGA 的 RESET 键与 KEY1 的逻辑复位不同。

LED7 / F7 每秒闪烁一次，表示 50 MHz 系统逻辑运行；LED8 / F8 在 MS7210 的全部初始化写操作获得 ACK 后常亮。

## 3. 串口操作

每个有效接收字节都会进入 1024 字节回显 FIFO 并发回电脑；特定 ASCII 字符同时作为命令。因此可先发送大写 `HELLO` 检查回显，再使用下面的命令：

| 发送字符 | 行为 |
| --- | --- |
| `?` | 回显 `?`，随后输出一行状态 |
| 小写 `c` | 清零六键计数、总按键计数、UART 接收计数及错误标志 |
| 小写 `r` | 重新复位并配置 MS7210 |
| `0`～`5` | 分别选择彩条、棋盘格、红、绿、蓝、灰阶 |

上电、按键状态变化、HDMI 初始化状态变化或视频时钟健康状态变化时，也会输出状态。状态行发送期间到达的串口数据会排队回显；持续满速输入并频繁触发状态输出时，回显吞吐会受状态行占用带宽影响，FIFO 满会明确置位错误标志。

```text
[MES50HP] KEY=00 COUNT=00000000 RX=00000001 LAST=3F HDMI=OK   STEP=59 VIDEO=OK   FIFO=0 FRAME=0 MODE=0
```

`KEY` 的 bit0～bit5 依次对应 KEY2～KEY7，`01` 表示 KEY2 按下，`20` 表示 KEY7 按下，`3F` 表示六键同时按下。`COUNT` 为按键按下总次数，`RX` 为有效接收字节数，`LAST` 为最近接收字节，`STEP` 为当前 MS7210 配置表索引，全部配置成功后为十六进制 `59`。

`HDMI=INIT` 表示正在配置，`HDMI=NACK` 表示 I²C 没有应答或等待总线超时，失败后约 1 秒自动重试；可用 `r` 立即重试。`HDMI=OK` 仅表示全部 90 次寄存器写入获得应答，不代表检测到了显示器或已经验证了 HDMI 电气链路。`VIDEO=OK` 表示正在收到 27 MHz 视频域的帧心跳；停止约 100 ms 后变为 `STOP`。两项诊断可帮助区分初始化故障与视频时钟故障。

`FIFO=1` 是回显队列曾溢出，`FRAME=1` 是曾收到错误 UART 停止位；错误保持到发送 `c` 或按 KEY1。错误停止位的数据不会作为正常接收字节计数，也不会执行命令。

## 4. 电脑串口自检

先关闭占用同一个串口的串口助手，再执行：

```powershell
python -m pip install pyserial
python io_debug/uart_check.py --list
python io_debug/uart_check.py --port COM5
python io_debug/uart_check.py --port COM5 --watch
```

将 `COM5` 改为实际端口。脚本查询 FPGA 状态、发送并检查 528 字节回显，再检查 HDMI 配置、视频心跳及串口错误标志。`--watch` 持续刷新状态，适合逐一按六个键并核对 `KEY` 和 `COUNT`。脚本检查不代替人工观察显示器画面。

## 5. 重新构建

在本仓库根目录执行，默认寻找 `E:/PDS`：

```powershell
python io_debug/build.py
```

如果安装目录不同：

```powershell
python io_debug/build.py --pds-home "D:/Pango/PDS"
```

脚本将本目录的 RTL 和约束复制到 `io_debug/build/`，调用 PDS 创建并构建工程，生成：

- `build/mes50hp_io_debug.pds`：可直接打开的 PDS 工程。
- `build/generate_bitstream/top_io_debug.sbit`：JTAG 调试位流。
- `build/build_summary.json`：构建状态、输入 SHA-256 和位流 SHA-256。
- `build/create_console.log`、`build/bitstream_console.log`：构建日志。
- `build/place_route/top_io_debug_timing_summary_after_hold_fix.txt`：布局布线时序报告。

修改源代码后使用构建脚本更新工程内的 RTL 副本。构建脚本不自动连接下载器，也不自动烧写板卡。

## 6. 仿真

需要 Icarus Verilog；可通过 PATH、`IVERILOG` 环境变量或 `--iverilog` 指定编译器。本机已有的临时工具缓存也会自动识别。

```powershell
python io_debug/run_sim.py
python io_debug/run_sim.py --iverilog "C:/iverilog/bin/iverilog.exe"
```

仿真覆盖六键消抖、长按与同时按下、单键计数、115200 串口收发、错误停止位拒收、1024 字节 FIFO 容量和溢出保护、错误清除、MS7210 的 90 次初始化写入、视频时序寄存器和 AVI 校验和、I²C NACK / SCL 卡低后的重试，以及视频帧尺寸、同步脉宽、RGB 彩条、跨时钟域状态快照和视频时钟丢失检测。

输出位于 `sim/`：`result.json`、`simulation.log`、`uart_capture.bin` 和 `display.ppm`。安装了 Pillow 时会额外生成 `display.png`。集成仿真使用独立 I²C 从机模型，缩短 HDMI 配置等待、I²C 周期和按键消抖时间，保留 50 MHz 系统时钟、27 MHz 视频时钟和 115200 UART 实际时序。单独的时钟健康测试将系统时钟及 `CLOCK_HZ` 同时降至 1 MHz，以减少仿真周期数，仍检查实际 100 ms 超时和下一视频帧内自动恢复。不模拟 MS7210 内部 PHY 或 HDMI TMDS 电气信号。

## 7. 引脚和参考依据

`mes50hp_io_debug.fdc` 约束了全部 50 个外部信号。系统时钟为 P20 / 50 MHz，视频时钟为 K21 / 27 MHz，UART 为 R9 / TX 和 R8 / RX，MS7210 为 P17 / SCL、P18 / SDA、R17 / RESET、M22 / 像素时钟。I²C 使用开漏输出，只输出低电平或高阻态，使用板载上拉。

引脚依据 MES50HP 官方硬件使用手册 1V1 的 PDF 第 10、27、31～34 页，2026-10-31 重新核对，PDF SHA-256 为 `61a854d97606010c47971d99f7e84e410563cabecffc492feb4f98e851098f71`。

- 手册入口：<https://szlogicmatrix.com/384.html>
- 手册 PDF：<https://szlogicmatrix.com/wp-content/uploads/2025/12/MES50HP开发板硬件使用手册_1V1.pdf>
- MS7210 寄存器配置沿用本仓库 `firmware/digit/platform.c` 中的 27 MHz / 576p50 配置事实，参考来源见 `../docs/references.md`。

验收分为 RTL 仿真、PDS 位流及时序检查、实际板卡连显示器与串口测试三部分。构建与仿真的机器结果会记录 `hardware_programmed: false`；实际显示、六键手感与串口表现仍需下载后逐项确认。

## 8. 本次位流检查

2026-10-31 使用本机 PDS 2022.2-SP1-Lite / build 132640 完成编译、综合、布局布线和位流生成；最终报告为 `All Constraints Met`。慢角建立时间余量分别为：50 MHz 系统域 `13.329 ns`、27 MHz 视频域 `11.578 ns`、视频到 HDMI 输出 `8.117 ns`；快角最差保持时间余量为 `0.192 ns`。

同日完成三组仿真，八项检查全部通过，结果见 `sim/result.json`。`sim/display.png` 为实际从仿真 RGB 输出采集的 720×576 画面，包含彩条及 KEY2 按下后的绿色状态框。

综合资源统计为 1591 个 FF、2908 个 LUT、0.5 个 DRM、50 个 I/O，不使用 PLL。具体布局后的统计与路径请查看 `build/bitstream_console.log` 和 `build/place_route/top_io_debug_timing_summary_after_hold_fix.txt`。位流大小为 2,101,696 字节，SHA-256 记录在 `build/build_summary.json`。
