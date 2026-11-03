> **范围/口径声明（交付主体）**：本文属于**紫光同创 PG2L100H** 交付主体线。文中"实测"指上板实测并应附证据路径；"未达成/未部署"项见根 [`COMPLIANCE.md`](COMPLIANCE.md) §4 边界清单。注意：**Pango 侧 Flash 当前尚未写入**（JTAG RAM 下载），详见 [`fpga_pg2l100h/vision/BOARD_VALIDATION.md`](fpga_pg2l100h/vision/BOARD_VALIDATION.md)。

# PG2L100H：OV7670 FIFO + AN430 外设调试

历史参考：本目录适配资料中的22针AL422模块。2026-11-02实物照片确认当前摄像头为18针DVP，应打开 `../vision/build/j11/pg2l100h_vision.pds`，按 `../vision/CAMERA_DEBUG.md` 和该工程生成的接线表连接。本目录FIFO信号表不适用于当前实物。

本工程对应 `ebf_pg2l100h_demo` 的 EBF PG2L100H676 底板，目标器件为 **Logos2 / PG2L100H / -6 / FBG676**。板外只使用 OV7670 摄像头和 ALINX AN430 4.3 英寸 LCD。它是移植的第一阶段：先验证时钟、LCD、SCCB、FIFO、按键和串口，不依赖 RISC-V 程序或外部 DDR。

顶层为 `top_pg2l100h_camera_lcd`。板载 50 MHz 时钟从 R3 输入，按目标板 HDMI 示例使用 **LVCMOS15 / 1.5 V**；其他已分配 I/O 为 **LVCMOS33 / 3.3 V**。Logos2 `GTP_GPLL` 将 50 MHz 转成 27 MHz，锁定后释放调试逻辑复位；LCD 输出 9 MHz、50% 占空比时钟。

## 先核对这两处连接

1. **摄像头 J7 是 18 针 DVP 接口，图片里的 OV7670 是 22 针 AL422 FIFO 模块。** 两者不能按脚号直插，电源位置也不同。本工程把 J7 的 HREF、RESET、PCLK、XCLK、PWDN 五条原 DVP 网络改作 FIFO 控制。必须逐线符合 [WIRING.md](WIRING.md)；“已经接到正点原子口”不足以确定这五条线的实际分配。若现有转接不同，修改 `generate_pins.py` 的 `CAMERA` 表后重建。
2. **LCD 默认接 J11，同号连线。** 底板另有 J12，接口编号不同，FPGA 球号也完全不同；若实际接在 J12，使用下述 J12 项目。J11 的 35、36 脚为 NC，本版不读取触摸坐标和触笔中断。SPI_CS 固定为高，仅保留 BUSY 状态输入。

AN430 图片只给出针脚定义，未给出完整电源电路。J3-2 是 5 V 供电脚；J3-39、40 标为 D3V3，目标板同号脚是 3.3 V 输出。若实物模块将它们作为外部输入，可同号连接；若实物由 5 V 自行产生 D3V3 并从这两脚输出，应隔离这两脚，不能并接板上稳压器。信号脚均不得接入 5 V。

摄像头供电接 J7-1 的 3.3 V，地接 J7-6；模块 RESET 固定接 3.3 V，PWDN 接地。所给图片没有外部 XCLK 端子，因此本工程使用摄像头模块自身时钟；J7 的 CMOS_XCLK 在本工程中是 FIFO_RRST。完整的 AL422 写入门控电路未提供，本工程沿用模块内部按 HREF 限定写入的假设。

## 生成和打开工程

在仓库根目录执行，无需先安装 PDS：

```powershell
python fpga_pg2l100h/camera_lcd_debug/build.py --prepare-only --lcd-header J11
```

打开 `build/j11/pg2l100h_camera_lcd.pds`。目录内带齐 11 个 RTL 源文件、FDC 和本次接线表；PDS 内全部文件使用相对路径。项目由所给 `hdmi_colorbar.pds` 模板生成，保留正确的 Logos2 器件配置，清除示例的 HDMI 源码、IP 和编译状态，并设置新顶层。

若 LCD 接在 J12：

```powershell
python fpga_pg2l100h/camera_lcd_debug/build.py --prepare-only --lcd-header J12
```

打开 `build/j12/pg2l100h_camera_lcd.pds`。两个版本使用不同输出目录，可同时保留；每个版本目录内的 `WIRING.md`、`wiring.csv` 和 `pinout.json` 对应自身约束。工程根目录下的这三份文件反映最近生成的版本。

## PDS 编译要求和本机限制

需要**包含 Logos2 / PG2L100H 器件库的完整 PDS**。参考示例使用 PDS 2022.2-SP4.2。当前本机 `E:\PDS` 实际为 **2022.2-SP1-Lite**，只有 Logos 等器件库，创建目标工程时实际报错：

```text
E: Flow-0146: Family 'Logos2' is not defined.
```

`Flow-0016` 中“工程 1.1.0、当前仅支持 1.0.9”同样属于软件版本与工程格式不兼容，不是 License 授权失败。应安装包含目标器件库的完整 PDS；账号注册和授权申请按厂商下载页面要求办理。单独添加 License 不能补齐当前 Lite 安装缺失的器件库，也不能只将目标工程版本号改为 1.0.9。

2026-11-01 修复了工程生成器遗漏源文件和约束文件必需的 `_timespec` 字段造成的 `Flow-0130` 语法错误，已重新生成 J11/J12 工程并增加文件登记格式检查。本机旧版 PDS 的独立语法对照测试可复现修复前的第 28 行错误，修复后通过工程解析；该测试使用旧版支持的临时器件配置，仅验证文件语法，不能替代 PG2L100H 编译。对照日志见 `validation/project_parser/`。

因此本目录提供正确器件的 `.pds`、RTL、约束和仿真结果，**当前没有生成 100H 的 `.sbit`，也没有完成综合、布局布线或上板验证**。不能把旧 MES50HP 位流下载到 100H。

2026-11-01 本机已通过全部 5 项仿真、60 个端口的引脚检查，以及 J11/J12 两个工程的器件、源文件、独立约束和源码副本一致性检查。结果见 `validation/simulation_summary.json`，板级厂商 PLL 模型日志见 `validation/board.log`。当前 PDS 环境被构建脚本正确拒绝，记录见 `validation/pds_preflight.log` 和 J11 工程的 `build_summary.json`。

使用已安装的完整版本路径构建，例如：

```powershell
python fpga_pg2l100h/camera_lcd_debug/build.py --pds-home D:/PDS/PDS_2022.2-SP4.2-ads --lcd-header J11
```

该路径是参考示例原来的安装路径，并非声称当前电脑已安装。也可在兼容版本 GUI 中打开 `.pds`，执行 Generate Bitstream / Rerun All。`create_project.tcl` 可由兼容版本 `pds_shell` 创建同样的工程。

完整构建脚本要求：PDS 无 `E:` 错误、生成本次新位流、布局布线时序报告含 `All Constraints Met`，才设置 `build_summary.json` 的 `success=true`。仅准备项目时为 `project_prepared=true`、`success=false`，后者专指尚未成功生成位流。脚本发现安装目录没有 PG2L100H 器件库时停止构建，并保留正确的待编译工程，不降级成 50K 工程。

成功编译后的下载文件为所选版本的 `build/j11/generate_bitstream/top_pg2l100h_camera_lcd.sbit` 或 `build/j12/generate_bitstream/top_pg2l100h_camera_lcd.sbit`。首次在 PDS Programmer 经 JTAG 下载到 FPGA 验证即可。工程脚本不操作下载器或板卡 Flash。

## 上电后的显示与控制

默认显示八色彩条，独立于摄像头是否初始化成功。LCD 有效区 **480×272**，总时序 **525×286**，HS/VS 低有效，约 **59.94 Hz**。摄像头配置为 **QVGA 320×240 RGB565**，从 AL422 读出后隔行、隔列抽取到 **160×120**，在屏幕中央的 320×240 窗口放大显示，左上角为 `(80,16)`。双缓冲只在 LCD 帧边界交换，属于低帧率接口调试预览。

板端连接全部 R0～R7、G0～G7、B0～B7；内部 RGB565 通过高位复制扩展为 RGB888，因此无须将 LCD 低位颜色线另外接地。

| 板载按键 / 位号 | 串口命令 | 动作 |
|---|---|---|
| KEY1 / SW4 | `c` | 显示摄像头窗口 |
| KEY2 / SW5 | `b` | 显示 FPGA 彩条 |
| KEY3 / SW6 | `f` | 冻结 / 继续；当前采集帧会完成 |
| KEY4 / SW7 | `t` | 切换摄像头内部测试彩条，重新配置并切到摄像头窗口 |
| 无独立功能键 | `r` | 重新配置摄像头并解除冻结 |
| 无独立功能键 | `?` 或 `s` | 请求状态报告 |
| RESET / SW2 | 无 | 复位 PLL 和调试逻辑 |

SW3 连接 FPGA_CONFIG_N，是重新配置键，不能代替四个功能键。按键低有效并做 20 ms 消抖。

| RTL / 网络 / 原理图 LED 位号 | 状态 |
|---|---|
| led[0] / LED1 / LED2 | 时钟心跳 |
| led[1] / LED2 / LED3 | 摄像头 SCCB 配置和 ID 校验成功 |
| led[2] / LED3 / LED4 | 摄像头初始化失败 |
| led[3] / LED4 / LED5 | 显示缓冲区已有完整图像 |

## USB 串口定位故障

板载 CH340：**115200、8N1、无流控**。J9 的 1-2、3-4 两组跳帽都需接通。命令为小写单字符，无需回车；每秒自动输出一次状态。

```text
CAMLCD M=1 C=1 E=0 ID=7673 S=31 F=0 N=0012 V=008A T=0000 K=00 P=0 U=0000
```

数值为十六进制：`M` 显示模式；`C` 初始化成功；`E` 失败；`ID` 是 PID/VER，预期 76/73；`S` 配置步骤，完成为 31；`F` 冻结；`N` 完成采集的帧数；`V` VSYNC 上升沿数；`T` 缺失 VSYNC 超时次数；`K` 低四位为 KEY1～KEY4；`P` bit1 为 BUSY，bit2/bit0 固定为零；`U` UART 停止位错误次数。

可复用原工程的串口读取脚本，将 COM5 换成板卡实际端口：

```powershell
python fpga_mes50hp/camera_lcd_debug/uart_monitor.py --port COM5 --command c --seconds 5
```

| 现象 | 检查位置 |
|---|---|
| 无彩条 | 确认使用 J11 或 J12 对应项目；检查 5 V、D3V3、方向、DCLK、DE |
| 颜色顺序不对 | LCD 是否同号连线，尤其 R/G/B 各颜色位 |
| E=1、ID=0000 | SCCB 的 SCL/SDA、模块 RESET/PWDN、电源；J7 自带 4.7 kΩ 上拉 |
| C=1，但 V 不变、T 增长 | VSYNC 接线与模块自带时钟 |
| V 增长，N 不增长或画面错行 | 五条 FIFO 控制转接、D0～D7 倒序脚号、模块 HREF 门控 |
| N 停止且 F=1 | 已冻结，按 KEY3 或发 `f` |

上方状态条红色表示失败，黄色表示初始化中，蓝色表示等待首帧，绿色表示有完整图像；下方黄色表示冻结，蓝色表示运行。

## 仿真和约束范围

```powershell
python fpga_pg2l100h/camera_lcd_debug/verify.py
```

脚本复用 MES50HP 的四个模块测试，并加入本板封装测试。四个通用测试需要 Icarus Verilog，自动查 PATH 和本机已有缓存，也可用 `--iverilog` 指定。板级测试使用 Vivado Xsim 实际执行 PDS 安装目录的 `GTP_GPLL.v` 模型；本机为 `E:/Vivado/2018.3`，可用 `--vivado-home` 指定其他安装目录，用 `--pds-home` 改变 Pango 模型目录。Icarus 在当前厂商 PLL 模型上未能完成运行，因此板级模型测试固定使用 Xsim。Vivado 仅作仿真器，不用于编译紫光器件。Pillow 可选，仅用于生成 PNG 预览图。

- FIFO 首字节、读复位、RGB565 字节序、抽取、双缓冲、冻结、超时恢复。
- 两帧完整 LCD 光栅，逐像素检查彩条和模拟图像，检查行场同步、有效像素数、9 MHz 时钟、占空比与建立时间。
- SCCB 写、读、应答、缺失设备、ID 错误和重新配置。
- 复用控制器的按键、UART 命令、状态报文和停止位错误。
- PG2L100H 封装：厂商模型 50→27 MHz、9 MHz LCD、RGB888 接口、四个实体键、UART 命令、复位后 PLL 重新锁定。

日志、`simulation_summary.json` 和测试画面在 `validation/`。图片来自仿真测试数据，不是实物采集图。60 个端口均有约束，核查两种 LCD 接口无球号冲突，避开电源、地及 J11 的 NC 脚。

LCD 按建立 10 ns、保持 2 ns 预算设置输出约束。FIFO 输入继承 5～80 ns 外部路径预算和三周期采样约束，RCK 为 4.5 MHz，采样距 RCK 上升沿约 111 ns。异步输入通过同步器处理。时序约束仅表达设计预算，仍须使用兼容 PDS 完成实际布局布线检查，并用实物确认外部连线满足预算。

## 资料与源码关系

引脚来源：底板原理图第 7 页 J7、按键、LED、UART，第 8 页 J11/J12，第 2、3 页 FPGA 球号和 BTB 网络；时钟参考 `20_hdmi_colorbar/pds_prj/hdmi_colorbar.fdc`。外设脚号来自 `fpga_mes50hp/camera-ov7670` 四张图片及 `fpga_mes50hp/screen` AN430 针脚图。

板级新增 RTL 位于本目录 `rtl/`；通用调试逻辑位于 `fpga_mes50hp/camera_lcd_debug/rtl/`。构建时把两者复制到所选版本的独立 `build/*/rtl/`。修改源码后重新准备 / 构建，不直接编辑构建目录中的副本。`generate_pins.py` 是约束和接线文档的唯一生成源。
