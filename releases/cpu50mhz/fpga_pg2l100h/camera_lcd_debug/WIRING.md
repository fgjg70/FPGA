# PG2L100H 接线表（LCD：J11）

由 `generate_pins.py` 生成。依据 `ebf_pg2l100h_demo/EBF_PG2L100H676_BASEBOARD_SCH.pdf` 第 3、7、8 页，球号再与第 2、3 页 BTB 连接器对照。时钟依据同目录 HDMI 示例的 `hdmi_colorbar.fdc`。

## 摄像头必须按信号转接

J7 为 18 针，所给带 AL422 FIFO 的 OV7670 为 22 针，电源位置也不同，不能逐脚直插。下面的 J7 五个原 DVP 信号被改作 FIFO 控制；这份约束假定实物已按本表逐线连接。若现有连线不同，应修改 CAMERA 分配后重建，不能直接下载验证。

| 板上接口 | 脚号 | 原理图网络 | FPGA 球号 | RTL 端口 | FPGA 方向 | 外设 | 外设脚号 | 外设信号 |
|---|---:|---|---|---|---|---|---:|---|
| J11 | 3 | LCD_R0 | AC26 | lcd_r[0] | OUTPUT | AN430 J3 | 3 | LCD_R0 |
| J11 | 4 | LCD_R1 | AB26 | lcd_r[1] | OUTPUT | AN430 J3 | 4 | LCD_R1 |
| J11 | 5 | LCD_R2 | Y26 | lcd_r[2] | OUTPUT | AN430 J3 | 5 | LCD_R2 |
| J11 | 6 | LCD_R3 | W25 | lcd_r[3] | OUTPUT | AN430 J3 | 6 | LCD_R3 |
| J11 | 7 | LCD_R4 | W23 | lcd_r[4] | OUTPUT | AN430 J3 | 7 | LCD_R4 |
| J11 | 8 | LCD_R5 | V23 | lcd_r[5] | OUTPUT | AN430 J3 | 8 | LCD_R5 |
| J11 | 9 | LCD_R6 | W26 | lcd_r[6] | OUTPUT | AN430 J3 | 9 | LCD_R6 |
| J11 | 10 | LCD_R7 | V26 | lcd_r[7] | OUTPUT | AN430 J3 | 10 | LCD_R7 |
| J11 | 11 | LCD_G0 | AC24 | lcd_g[0] | OUTPUT | AN430 J3 | 11 | LCD_G0 |
| J11 | 12 | LCD_G1 | AB24 | lcd_g[1] | OUTPUT | AN430 J3 | 12 | LCD_G1 |
| J11 | 13 | LCD_G2 | Y21 | lcd_g[2] | OUTPUT | AN430 J3 | 13 | LCD_G2 |
| J11 | 14 | LCD_G3 | W21 | lcd_g[3] | OUTPUT | AN430 J3 | 14 | LCD_G3 |
| J11 | 15 | LCD_G4 | T15 | lcd_g[4] | OUTPUT | AN430 J3 | 15 | LCD_G4 |
| J11 | 16 | LCD_G5 | T14 | lcd_g[5] | OUTPUT | AN430 J3 | 16 | LCD_G5 |
| J11 | 17 | LCD_G6 | Y20 | lcd_g[6] | OUTPUT | AN430 J3 | 17 | LCD_G6 |
| J11 | 18 | LCD_G7 | W20 | lcd_g[7] | OUTPUT | AN430 J3 | 18 | LCD_G7 |
| J11 | 19 | LCD_B0 | AB25 | lcd_b[0] | OUTPUT | AN430 J3 | 19 | LCD_B0 |
| J11 | 20 | LCD_B1 | AA24 | lcd_b[1] | OUTPUT | AN430 J3 | 20 | LCD_B1 |
| J11 | 21 | LCD_B2 | AA23 | lcd_b[2] | OUTPUT | AN430 J3 | 21 | LCD_B2 |
| J11 | 22 | LCD_B3 | AA22 | lcd_b[3] | OUTPUT | AN430 J3 | 22 | LCD_B3 |
| J11 | 23 | LCD_B4 | W19 | lcd_b[4] | OUTPUT | AN430 J3 | 23 | LCD_B4 |
| J11 | 24 | LCD_B5 | V19 | lcd_b[5] | OUTPUT | AN430 J3 | 24 | LCD_B5 |
| J11 | 25 | LCD_B6 | U16 | lcd_b[6] | OUTPUT | AN430 J3 | 25 | LCD_B6 |
| J11 | 26 | LCD_B7 | U15 | lcd_b[7] | OUTPUT | AN430 J3 | 26 | LCD_B7 |
| J11 | 27 | LCD_DCLK | V14 | lcd_dclk | OUTPUT | AN430 J3 | 27 | LCD_DCLK |
| J11 | 28 | LCD_HSYNC | U14 | lcd_hsync | OUTPUT | AN430 J3 | 28 | LCD_HSYNC |
| J11 | 29 | LCD_VSYNC | U22 | lcd_vsync | OUTPUT | AN430 J3 | 29 | LCD_VSYNC |
| J11 | 30 | LCD_DE | V22 | lcd_de | OUTPUT | AN430 J3 | 30 | LCD_DE |
| J11 | 31 | SPI_DCLK | W24 | touch_sclk | OUTPUT | AN430 J3 | 31 | SPI_DCLK |
| J11 | 32 | SPI_CS | V24 | touch_cs_n | OUTPUT | AN430 J3 | 32 | SPI_CS |
| J11 | 33 | SPI_DIN | N18 | touch_mosi | OUTPUT | AN430 J3 | 33 | SPI_DIN |
| J11 | 34 | SPI_BUSY | U24 | touch_busy | INPUT | AN430 J3 | 34 | SPI_BUSY |
| J7 | 4 | CMOS_SCL | Y23 | cam_scl | OUTPUT | OV7670 P1 | 3 | SIO_C |
| J7 | 6 | CMOS_SDA | V18 | cam_sda | INOUT | OV7670 P1 | 4 | SIO_D |
| J7 | 3 | CMOS_VSYNC | W18 | cam_vsync | INPUT | OV7670 P1 | 5 | VSYNC |
| J7 | 16 | CMOS_PCLK | Y22 | cam_rclk | OUTPUT | OV7670 P1 | 18 | FIFO_RCK |
| J7 | 5 | CMOS_HREF | V16 | cam_we | OUTPUT | OV7670 P1 | 19 | FIFO_WR |
| J7 | 7 | CMOS_RESET | V17 | cam_oe_n | OUTPUT | OV7670 P1 | 20 | FIFO_OE_N |
| J7 | 18 | CMOS_PWDN | Y25 | cam_wrst_n | OUTPUT | OV7670 P1 | 21 | FIFO_WRST_N |
| J7 | 17 | CMOS_XCLK | AA25 | cam_rrst_n | OUTPUT | OV7670 P1 | 22 | FIFO_RRST_N |
| J7 | 8 | CMOS_D0 | T17 | cam_data[0] | INPUT | OV7670 P1 | 14 | D0 |
| J7 | 9 | CMOS_D1 | U19 | cam_data[1] | INPUT | OV7670 P1 | 13 | D1 |
| J7 | 10 | CMOS_D2 | T18 | cam_data[2] | INPUT | OV7670 P1 | 12 | D2 |
| J7 | 11 | CMOS_D3 | T19 | cam_data[3] | INPUT | OV7670 P1 | 11 | D3 |
| J7 | 12 | CMOS_D4 | U20 | cam_data[4] | INPUT | OV7670 P1 | 10 | D4 |
| J7 | 13 | CMOS_D5 | V21 | cam_data[5] | INPUT | OV7670 P1 | 9 | D5 |
| J7 | 14 | CMOS_D6 | T20 | cam_data[6] | INPUT | OV7670 P1 | 8 | D6 |
| J7 | 15 | CMOS_D7 | U21 | cam_data[7] | INPUT | OV7670 P1 | 7 | D7 |

## 电源、固定电平与未使用的脚

| 外设脚 | 连接 |
|---|---|
| OV7670 P1-1，VCC | J7-1，3.3 V |
| OV7670 P1-2，GND | J7-2，GND |
| OV7670 P1-15，RESET | 3.3 V |
| OV7670 P1-16，PWDN | GND |
| OV7670 P1-6，HREF；P1-17，STROBE | 不接；模块 FIFO 写端假定内部按 HREF 门控 |
| AN430 J3-1、37、38，GND | J11 同号脚 |
| AN430 J3-2，VCC5V | J11-2，5 V；只给模块供电 |
| AN430 J3-39、40，D3V3 | 板端同号脚为 3.3 V；须先确认 AN430 实物电源方向，见 README |
| AN430 J3-35，SPI_DOUT；36，PENIRQ | 本工程不读取；J11 同号脚本来就是 NC，J12 也不分配这两个输入 |

LCD 使用完整 R0～R7、G0～G7、B0～B7，同号连线。32 路 LCD GPIO 加 16 路摄像头 GPIO，共 48 路板外信号。SPI_CS 保持高电平，触摸控制器不被访问。

J11 的 35、36 脚在底板原理图中为 NC，不能借这两脚读取触摸数据。J12 的 35、36 脚为 E22、H17，本版为统一调试功能同样不读取。

J9 跳帽：1-2、3-4 接通后，CH340 才与 FPGA UART 相连。SW2 是逻辑复位；SW3 是 FPGA_CONFIG_N，不能当功能按键使用。

## 板载信号

| 器件 | 网络 | 球号 | RTL 端口 | 电平 |
|---|---|---|---|---|
| CORE | SYS_CLK | R3 | sys_clk | 1.5 V |
| SW2 | RESET | G25 | reset_n | 3.3 V |
| SW4 | KEY1 | K25 | keys_n[0] | 3.3 V |
| SW5 | KEY2 | K26 | keys_n[1] | 3.3 V |
| SW6 | KEY3 | P26 | keys_n[2] | 3.3 V |
| SW7 | KEY4 | R26 | keys_n[3] | 3.3 V |
| LED2 | LED1 | N23 | led[0] | 3.3 V |
| LED3 | LED2 | N24 | led[1] | 3.3 V |
| LED4 | LED3 | U26 | led[2] | 3.3 V |
| LED5 | LED4 | U25 | led[3] | 3.3 V |
| J9 | UART_TX | L24 | uart_txd | 3.3 V |
| J9 | UART_RX | L25 | uart_rxd | 3.3 V |
