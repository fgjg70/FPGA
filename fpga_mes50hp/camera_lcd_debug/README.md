# MES50HP：OV7670 FIFO + AN430 调试工程

本工程只连接你提供的两个板外模块：**22 针、带 AL422 FIFO 的 OV7670**，以及 **ALINX AN430 4.3 英寸 LCD**。保留板载 USB 串口、六个功能按键、复位键和八个 LED。顶层为 `top_camera_lcd_debug`，目标器件为 `PGL50H / -6 / FBG484`，不依赖之前的 `io_debug` 工程，也不需要 RISC-V 固件或外部 DDR。

默认上电显示八色彩条，先检查 LCD；按 KEY2 切换摄像头。摄像头设置为 QVGA 320×240 RGB565，读出 FIFO 后隔行、隔列抽取到 160×120，双缓冲保存，在 LCD 中间以 320×240 显示。取景窗口左上角为 `(80,16)`。它是低帧率链路调试工程，存储的图像细节分辨率为 160×120。

## 1. 接线前先确认

- 你给的摄像头图片是 **AL422 FIFO 版本**，有 `FIFO_RCK / FIFO_WR / FIFO_OE / FIFO_WRST / FIFO_RRST`；本工程不适用于没有 FIFO 的裸 OV7670 DVP 模块。图片没有提供完整电路图，工程按模块自带传感器时钟、内部以 HREF 限定 FIFO 写入的常见结构实现。若实物的写使能没有经过 HREF 门控，需要先改接线和采集逻辑。
- 开发板硬件手册 V1.1 有连接器标号冲突：40 针扩展口在正文叫 **J8**、图中叫 **J16**；PMOD 在正文叫 **J12**、图中叫 **J11**。本说明用“40PIN”和“PMOD”区分。请按实物的 1 脚标记、供电脚和下面的 FPGA 球号定位，不能只按 J 编号找插座。
- 40PIN 的 34 路 GPIO，加 PMOD 的 8 路 GPIO，合计 42 路全部分配。LCD 使用 RGB565，未用的颜色低位接地，另保留六条触摸控制器信号。
- **必须用逐线跳线或转接板。不能用 40 芯排线直连 LCD。** 此分配中开发板 40PIN 的 29～36 脚已经给摄像头控制信号，和 AN430 的接口排列不同。
- 所有 FPGA 信号为 3.3 V。LCD 的 `VCC5V` 只接模块供电脚，不能进入任何 FPGA GPIO。摄像头用 3.3 V 供电，两个模块和开发板共地。断电接线，优先短线，FIFO 数据线和时钟附近带地线。

## 2. LCD 接线

以下“LCD 脚”均为你提供图片中的 **AN430 J3**。

| LCD 信号 | LCD 脚 | 开发板 40PIN 脚 | FPGA 球号，顺序对应 |
|---|---|---|---|
| R3～R7 | 6～10 | 3～7 | AB13、Y13、AB11、Y11、W11 |
| G2～G7 | 13～18 | 8～13 | V11、AB10、AA10、Y10、W10、T11 |
| B3～B7 | 22～26 | 14～18 | R11、Y12、W12、U12、T12 |
| LCD_DCLK | 27 | 19 | U10 |
| LCD_HSYNC | 28 | 20 | T10 |
| LCD_VSYNC | 29 | 21 | AB9 |
| LCD_DE | 30 | 22 | Y9 |
| SPI_DCLK | 31 | 23 | V9 |
| SPI_CS | 32 | 24 | U9 |
| SPI_DIN | 33 | 25 | U8 |
| SPI_BUSY | 34 | 26 | T8 |
| SPI_DOUT | 35 | 27 | W8 |
| PENIRQ | 36 | 28 | V7 |

还要连接以下电源和固定电平，**它们不在 GPIO 约束表中**：

| LCD 脚 | 连接 |
|---|---|
| 1、37、38，GND | 开发板 GND，例如 40PIN 的 1、37、38 |
| 2，VCC5V | 开发板 40PIN 的 2，5 V |
| 3、4、5，R0～R2 | GND |
| 11、12，G0～G1 | GND |
| 19、20、21，B0～B2 | GND |
| 39、40，D3V3 | 预留 3.3 V 电源连接，见下段 |

**D3V3 的接法需要按实物版本确认**：你提供的是接口定义图，它标出了 39、40 脚为 D3V3，但没有说明电源方向。若完整原理图确认这两脚是外部 3.3 V 输入，就接开发板 40PIN 的 39、40；若该版本从 5 V 在模块内部生成 D3V3，则这两脚是电源输出，应悬空，避免与开发板稳压器并接。GPIO 球号分配和 RTL 不依赖这项确认，供电接线则需要确认后再上电。

触摸接口本版仅做预留和触笔中断检查：`SPI_CS=1`，`SPI_DCLK=0`，`SPI_DIN=0`。串口报告原始 BUSY、DOUT、PENIRQ；按下触摸屏时左上角出现白色小块。**没有实现触摸坐标读取或校准**。若暂时不接触摸接口，请把 FPGA 的 `touch_irq_n` 接 3.3 V、`touch_busy/touch_miso` 接地，输入不要悬空。

## 3. OV7670 FIFO 接线

以下“摄像头脚”均按你提供图片中的 **22 针 P1**，从连接器的 1 脚标记辨认正反面。

| 摄像头信号 | 摄像头脚 | 开发板连接 | FPGA 球号 |
|---|---:|---|---|
| SIO_C | 3 | 40PIN-29 | AB8 |
| SIO_D | 4 | 40PIN-30 | AA8 |
| VSYNC | 5 | 40PIN-31 | Y6 |
| FIFO_RCK | 18 | 40PIN-32 | W6 |
| FIFO_WR / WR_CTR，高有效 | 19 | 40PIN-33 | AB5 |
| FIFO_OE，低有效 | 20 | 40PIN-34 | Y5 |
| FIFO_WRST，低有效 | 21 | 40PIN-35 | AB4 |
| FIFO_RRST，低有效 | 22 | 40PIN-36 | AA4 |
| D0 | 14 | PMOD-1 | AB6 |
| D1 | 13 | PMOD-2 | AA6 |
| D2 | 12 | PMOD-3 | AB7 |
| D3 | 11 | PMOD-4 | Y7 |
| D4 | 10 | PMOD-5 | Y8 |
| D5 | 9 | PMOD-6 | W9 |
| D6 | 8 | PMOD-7 | U6 |
| D7 | 7 | PMOD-8 | T7 |
| VCC | 1 | PMOD-11 或 12，3.3 V | 电源，不是 GPIO |
| GND | 2 | PMOD-9 或 10，GND | 电源，不是 GPIO |
| RESET，低有效 | 15 | 3.3 V，保持不复位 | 固定电平 |
| PWDN，高有效 | 16 | GND，保持工作 | 固定电平 |
| HREF | 6 | 悬空，不接 FPGA | 模块输出 |
| STROBE | 17 | 悬空，不接 FPGA | 模块输出 |

SIO_D 为开漏输出，需要到 **3.3 V** 的上拉。请检查摄像头板上的 SCCB 上拉；没有时外加约 4.7 kΩ，上拉不要接到 5 V。SIO_C 本工程用推挽输出。摄像头图片没有外部 XCLK 引脚，本工程不额外输出 XCLK；如果实物需要外部时钟，说明模块版本与图片不同。

摄像头 D0～D7 的模块脚号从 14 递减到 7，别按递增脚号接反。PMOD 数据路径经过开发板上的串联电阻，FIFO 读时钟采用较保守的 4.5 MHz，并在上升沿后约 111 ns 采样。

每次采集先等 VSYNC 高电平期间复位写指针，再在低电平期间允许一帧写入，下一次 VSYNC 上升沿关闭写入。随后 `/RRST` 保持低电平经过三个 RCK 上升沿，再读出 153600 字节，RGB565 高字节在前。完成一帧后，直到 LCD 帧边界才交换显示缓冲区。

完整的 42 条 GPIO 逐线表见 [WIRING.md](WIRING.md)，可用 Excel 打开 [wiring.csv](wiring.csv)。`generate_pins.py` 是 GPIO 分配的唯一来源，重新生成约束时执行 `python camera_lcd_debug/generate_pins.py`。

## 4. 按键、串口与 LED

KEY1 为低有效复位；KEY2～KEY7 是六个调试按键，均同步并做 20 ms 消抖。

| 板载按键 | 串口命令，小写单字符 | 动作 |
|---|---|---|
| KEY2 | `c` | 显示摄像头窗口 |
| KEY3 | `b` | 显示 FPGA 八色彩条 |
| KEY4 | `f` | 切换冻结/继续，已开始的帧会完成后停住 |
| KEY5 | `t` | 切换 OV7670 内部测试条，重新配置，并切到摄像头窗口 |
| KEY6 | `r` | 重新配置摄像头，解除冻结 |
| KEY7 | `?` 或 `s` | 立即请求一次状态报告 |

板载 USB-UART：**115200，8 数据位，无校验，1 停止位，无流控**。命令不需要回车。工程每秒自动输出一次状态，按键和收到串口字符也会请求状态。它不做字符回显。

```text
CAMLCD M=1 C=1 E=0 ID=7673 S=31 F=0 N=0012 V=008A T=0000 K=00 P=0 U=0000
```

所有数值按十六进制输出：`M` 为显示模式，0 彩条/1 摄像头；`C` 为配置成功；`E` 为配置失败；`ID` 为 PID/VER，预期 76/73；`S` 为配置步骤，正常完成为 31；`F` 为冻结；`N` 为采集完成帧数；`V` 为 VSYNC 上升沿数；`T` 为无 VSYNC 超时次数；`K` 的 bit0～bit5 对应 KEY2～KEY7 当前按下状态；`P` 的 bit2 为触笔按下、bit1 为 BUSY、bit0 为 DOUT；`U` 为 UART 停止位错误计数。计数器为 16 位，会回卷，重新配置会清零采集计数。

上方状态条：红色表示 SCCB/ID 失败，黄色表示初始化，蓝色表示等待首帧，绿色表示已有图像；下方黄色表示冻结，蓝色表示运行。彩条模式不依赖摄像头是否连接。

| LED | 表示 |
|---|---|
| LED1 | 系统时钟心跳 |
| LED2 | 摄像头配置成功 |
| LED3 | 摄像头配置失败 |
| LED4 | 显示缓冲区已有完整帧 |
| LED5 | 摄像头显示模式 |
| LED6 | 冻结 |
| LED7 | 已采集帧数最低位 |
| LED8 | 触笔按下 |

## 5. 编译、下载与上板顺序

本机 PDS 位于 `E:\PDS`。在仓库根目录执行：

```powershell
python camera_lcd_debug/build.py
```

其他安装目录：

```powershell
python camera_lcd_debug/build.py --pds-home D:\PDS
```

脚本复制 RTL、Tcl、FDC 到独立的 `camera_lcd_debug/build`，创建项目并运行到位流生成。脚本要求生成新位流、无 PDS 错误且布局布线时序报告为 `All Constraints Met` 才报告成功。

- 打开的 PDS 项目：`build/mes50hp_camera_lcd.pds`。
- 下载位流：`build/generate_bitstream/top_camera_lcd_debug.sbit`。
- 构建结果、输入 SHA-256 和位流 SHA-256：`build/build_summary.json`。
- 布局布线时序：`build/place_route/top_camera_lcd_debug_timing_summary_after_hold_fix.txt`。
- 工程以板载 **27 MHz / K21** 为唯一系统时钟，逻辑分频转发 **9 MHz、50% 占空比** LCD 时钟；LCD 总时序为 525×286，有效 480×272，约 59.94 Hz，HS/VS 低有效。

建议调试顺序：

1. 断电核对连线和 D3V3 电源方向。先只接 LCD，摄像头先不接。
2. 在 PDS Programmer 中选择板载下载器，经 JTAG 把 `.sbit` 下载到 FPGA。首次建议先做易失配置，断电后会丢失。本工程没有自动操作下载器。
3. 检查默认八色彩条，以及 KEY3/串口 `b`。无图先看 LCD 供电、DCLK、DE 和颜色位接线。
4. 断电连接摄像头，再上电并重新下载。打开开发板对应的串口，等待 `C=1 E=0 ID=7673`。
5. 按 KEY2，等待上方状态条变绿、`N` 持续变化。KEY4 检查冻结，KEY5 检查传感器内部测试条，以区分镜头/曝光问题和数字链路问题。
6. 逐个按 KEY2～KEY7，观察动作和 UART 中的 `K`；KEY7 只触发状态输出，快速按下再松开时 UART 快照里的 K 可能已回到 00。

可选串口脚本，`COM5` 请换为设备管理器中开发板对应的串口：

```powershell
python camera_lcd_debug/uart_monitor.py --port COM5 --command c --seconds 10
```

## 6. 仿真与时序范围

```powershell
python camera_lcd_debug/verify.py
```

需要 Icarus Verilog，脚本会查 PATH 和本机已有的仿真工具缓存；其他路径用 `--iverilog C:\Tools\iverilog\bin\iverilog.exe`。Pillow 可选，用于将仿真 PPM 转为 PNG。串口脚本另需 `pyserial`。

- `tb_capture`：带延迟的 FIFO 模型，检查首字节、读复位的三个时钟、RGB565 字节顺序、抽样地址、完整帧交换、冻结、超时恢复及中途复位。
- `tb_video`：两帧完整 AN430 光栅，逐像素检查彩条和模拟图像缩放，检查同步宽度、有效像素数、DCLK 周期/占空比、数据建立时间，输出预览图。
- `tb_config`：SCCB 从设备模型，检查配置、STOP 后读寄存器、最后一字节 NACK、器件不存在、恢复重配和错误 ID 拒绝。
- `tb_controls`：顶层集成，检查六键动作、短毛刺拒绝、UART 收发命令/状态格式、错误停止位拒绝、触摸 SPI 空闲。此测试只缩短消抖门限，加快仿真，硬件默认仍为 20 ms。

输出在 `validation/`，包括日志、`simulation_summary.json`、`lcd_colorbars.png` 和 `camera_gradient.png`。两张图是**仿真生成的测试图**，不是实物摄像头照片。

约束文件对 FIFO 输入设置了三周期建立检查，以及 5～80 ns 的外部路径预算，预算覆盖 RCK 输出、AL422 响应、串联电阻和跳线。实际采样距离 RCK 上升沿约 111 ns；还需要在实物上确认数据有效和保持窗口满足预算，尤其不要用长排线。异步的 VSYNC、SCCB 输入、UART RX、按键和触摸输入经过同步器，约束中按异步输入处理。LCD 输出按 10 ns 建立、2 ns 保持预算约束。

本工程的“编译通过 / 仿真通过”仅说明工具验证结果，**不等于已完成实物下载和外设电气验证**。你提供的图片未明确 LCD D3V3 电源方向，也未展示摄像头完整 HREF/FIFO 门控电路，这两处需要对照实物版本确认。

## 7. 常见故障

| 现象 | 优先检查 |
|---|---|
| LCD 无背光 | VCC5V、GND、模块版本的背光供电方式 |
| 有背光无彩条 | D3V3、DCLK/HS/VS/DE、LCD 接口方向；不能直插排线 |
| 彩条颜色不对 | R/G/B 的高位顺序、低位是否接地；不要把 D0 接到 D7 |
| E=1，ID=0000，S=00 | SCCB 无应答，检查 3.3 V、RESET/PWDN、SIO_C/SIO_D 和上拉 |
| ID 与 7673 不同 | 模块型号/版本不同，先确认实物，再调整 ID 判定和配置 |
| C=1，但 V 不变化、T 增长 | VSYNC 接线或模块传感器时钟；本工程没有 XCLK 输出 |
| V 在变但画面错行、斜纹 | FIFO WR 有效电平、HREF 门控、是否真为 QVGA RGB565、数据线接反 |
| 图像偶发噪点 | 缩短连线、增加地线，测量 FIFO 数据稳定窗口和电源纹波 |
| N 停住而 F=1 | 已冻结，按 KEY4 或发 f |

原始资料和引脚定位依据见 [SOURCES.md](SOURCES.md)。
