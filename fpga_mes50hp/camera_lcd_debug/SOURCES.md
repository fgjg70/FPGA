# 引脚与时序资料依据

核对日期：2026-11-01。工程没有把其他 FPGA 板的管脚直接移植到 MES50HP。

1. 用户提供的 `../camera-ov7670/` 四张图片：22 针 OV7670 + AL422 模块的接口定义、FIFO 控制电平、读复位/读时钟说明。这些是本工程选择 FIFO 接口而不是 DVP 接口的依据。图片不包含完整的 HREF 门控和传感器时钟电路。
2. 用户提供的 `../screen/ALINX 黑金配套4.3 TFT LCD 液晶屏模块  AN430 不含FPGA开发板.jpg`：AN430 J3 的 40 针信号定义。39/40 为 D3V3，但图片没有声明供电方向，需要对照实际模块版本的完整电路图。
3. 逻辑矩阵《MES50HP 开发板硬件使用手册》V1.1，官方公开 PDF：`https://szlogicmatrix.com/wp-content/uploads/2025/12/MES50HP开发板硬件使用手册_1V1.pdf`。PDF 共 38 页，最后两页的 40PIN/PMOD 章节用于定位 FPGA 球号；同册用于确认 K21 的 27 MHz、板载按键、LED 和 UART。此 PDF SHA-256：`61a854d97606010c47971d99f7e84e410563cabecffc492feb4f98e851098f71`。正文/图中的 J8/J16、J12/J11 命名不一致，所以接线表同时注明两种编号。
4. ALINX 官方 AX301 示例仓库的 `src/12_2_an430_lcd_test/src/color_bar.v` 和 LCD PLL 配置，用于核对 AN430 的 9 MHz、480×272、H=41/2/480/2、V=10/2/272/2、低有效 HS/VS。地址：`https://github.com/alinxalinx/AX301/tree/master/src/12_2_an430_lcd_test`。本工程重新编写 RTL，没有复制该示例源文件。
5. OmniVision《OV7670/OV7171 CMOS VGA CameraChip》datasheet V1.4，ALINX 官方 AX309 资料库中的 `DATASHEET/camera/OV7670_DS_(1_4).pdf`：用于核对 SCCB 地址 0x42/0x43、PID/VER 0x0A/0x0B、QVGA/RGB565 和测试条寄存器含义。地址：`https://github.com/alinxalinx/AX309/blob/master/DATASHEET/camera/OV7670_DS_(1_4).pdf`。

电压、连接器方向和摄像头内部电路仍以用户实际购买的模块版本为准。FDC 中所有信号均约束为 LVCMOS33；只有模块电源连接使用 5 V。
