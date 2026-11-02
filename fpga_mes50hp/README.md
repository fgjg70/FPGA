# MES50HP 盘古50工程

板卡基础外设调试使用独立工程 [io_debug/README.md](io_debug/README.md)：验证 HDMI 显示、115200 UART 和 KEY2～KEY7 六个按键。执行 `python io_debug/build.py` 生成对应 PDS 工程及 `top_io_debug.sbit`。

已新增 **自研 RISC-V + INT8 加速器的手写数字识别/密码门禁 v2**，接入 KEY2～8、LED5～8、MS7210 HDMI 和 24LC02 EEPROM。识别后显式确认密码位，GUI 同步门状态，配置支持保存、复位恢复及恢复默认。使用说明见 [docs/digit_application.md](docs/digit_application.md)，板卡资料和开源参考见 [docs/references.md](docs/references.md)。

```powershell
python prepare_rtl.py --app digit
python prepare_rtl.py --check --app digit
python tools/build_digit_bitstream.py
python app/digit_demo.py --port COM5
```

首次使用先安装 `app/requirements.txt`，并按应用说明重新构建、下载对应位流。`--app digit` 启用应用与加速器；`--app boot` 保留原启动/回显验证。下文的 `RISCV OK`、PASS LED 和历史资源数据对应 boot 配置。当前生成配置以 `generated/manifest.json` 的 `app` 为准。

应用位流位于 `build/digit/generate_bitstream/top_mes50hp.sbit`，引脚与 50/27 MHz 视频时序见 `mes50hp_digit.fdc`。默认密码 `1234`；KEY2 锁定、KEY3 撤销、KEY4 确认、KEY5 模式、KEY6 重识别、KEY7 清除、KEY8 长按 2 秒恢复默认并保存。HDMI 使用 720×576p50；本次尚未下载到实物，验证记录见 `validation/digit_summary.json`。

应用位流已生成到 `build/digit/generate_bitstream/top_mes50hp.sbit`，应用 PDS 工程为 `build/digit/riscv_mes50hp_digit.pds`。2026-10-24 已通过 50 MHz 时序、完整应用与 115200 串口仿真；详细结果见 `validation/digit_summary.json`。本次未执行实物下载。

本工程面向迈尔微视 MES50HP，器件为 Logos PGL50H / FBG484 / -6，对应板卡手册中的 PGL50H-6IFBG484。使用本机 PDS 2022.2-SP1-Lite（build 132640）生成，工程文件格式为 1.0.9。

## 打开与下载

1. 在 PDS 中通过 **File → Open Project** 打开 `riscv_mes50hp.pds`。
2. 本目录已生成 `generate_bitstream/top_mes50hp.sbit`。如需重新构建，在运行按钮的下拉菜单中选最下面的 **Run Generate Bitstream**，或在左侧 Flow 中右键 **Generate Bitstream → Rerun All**。
3. 通过 **Tools → Configuration** 打开 Fabric Configuration，选择 **Boundary Scan → Scan Device**。确认扫描到 PGL50H，使用 **Assign New Configuration File** 选择上述 `.sbit`，选中 FPGA 后右键 **Program**，完成后可执行 **Verify**。
4. 下载完成后按一下板上的 **KEY1** 复位。LED1 为心跳，LED2 为启动程序完成指示，LED3 为失败指示，LED4 为当前非法指令指示。

这里的下载是 JTAG 配置 FPGA，断电后不会保留；SPI Flash 固化需要另外选择 Flash 配置流程。本工程没有执行任何硬件下载或 Flash 擦写。

板上串口设为 **115200、8 数据位、无校验、1 停止位、无流控**。连接板载 USB 转串口接口并打开串口终端，再按 KEY1，应收到 `RISCV OK` 和换行；随后输入的字节会原样回显。JTAG 下载器本身不替代 USB 串口连接。

## 引脚

引脚依据《MES50HP开发板硬件使用手册_1V1》：器件与时钟见第 6、9 页，USB 串口见第 27 页，LED 与按键见第 33 页。下载工具的操作依据本机 PDS 安装目录下的 `doc/Fabric_Configuration_User_Guide.pdf` 第 11–15 页和 `doc/Pango_Design_Suite_User_Guide.pdf`。

| 信号 | 管脚 | 说明 |
| --- | --- | --- |
| sys_clk | P20 | 板载 50 MHz 时钟 |
| sys_rst_n | K18 | KEY1，低有效 |
| led[0] | B2 | LED1，心跳 |
| led[1] | A2 | LED2，启动完成 |
| led[2] | B3 | LED3，失败 |
| led[3] | A3 | LED4，非法指令 |
| uart_txd | R9 | FPGA 发送到板载 USB 转串口芯片 |
| uart_rxd | R8 | FPGA 接收板载 USB 转串口芯片的数据 |

以上 I/O 使用 LVCMOS33，LED 高电平点亮，约束保存在 `mes50hp.fdc`。未使用 DDR3、HDMI 或其他扩展接口。

## 源码和启动程序

本工程从 `fpga_pds_1_0_9/src/` 复制 23 个源文件，新增 `top_mes50hp.sv` 作为板级顶层。内部复用的 `top_pgl22g` 只是已有模块名称，实际 PDS 目标器件已经改为 PGL50H。

为适配 PDS，`imem.sv`、`dmem.sv` 的综合路径使用完整初始化镜像；`bht.sv`、`btb.sv`、`regfile.sv` 的综合初始化改为 `$readmemh`，避免 ADS 忽略数组的 `initial` 循环。仿真路径保留原来的初始化行为。原工程和 `fpga_pds_1_0_9` 中的源码不受这些修改影响。

`firmware/boot.S` 是上板验证程序：写 GPIO、输出串口启动提示、向 tohost 写入完成值，然后进入串口回显循环。它用于验证处理器和板级接口，不是完整应用程序或 CoreMark 固件。

`prepare_rtl.py` 使用本项目中的汇编器 `tools/asm.py` 生成启动镜像，补满 4096 条指令，未用指令填 NOP；同时生成数据 RAM、预测表和寄存器堆的初始化文件，再调用 sv2v 0.0.13 将 SystemVerilog 转成 PDS 可编译的 Verilog。PDS 只注册 `generated/riscv_pds.v` 和 `mes50hp.fdc`，不要同时再加入原始 SystemVerilog 文件。

修改 `src/` 或 `firmware/boot.S` 后，在本目录执行：

```powershell
python .\prepare_rtl.py
python .\prepare_rtl.py --check
```

再回 PDS 执行 **Generate Bitstream → Rerun All**。`generated/manifest.json` 保存源码、初始化镜像、转换器和生成 Verilog 的 SHA-256。不要直接编辑生成的 Verilog 或 `.hex` 文件。

如需重新生成 `.pds`，执行 `create_project.bat`。该脚本会重置工程配置与流程状态，但不自动编译或下载。默认 PDS 安装位置为 `E:/PDS`，可用 `PDS_HOME` 修改。缺少转换器时可运行 `powershell -ExecutionPolicy Bypass -File .\setup_tools.ps1`，或通过 `SV2V` 指定已有转换器。构建脚本需要 Python 3。

命令行完整构建：

```powershell
& "E:\PDS\bin\pds_shell.exe" -project "riscv_mes50hp.pds" -run gen_bit_stream
```

## 验证

2026-10-21 已在本机完成 Compile、Synthesize、Device Map、Place & Route、Report Timing、Generate Netlist 和 Generate Bitstream，最终日志中没有 `E:` 错误。

| 项目 | 结果 |
| --- | --- |
| 综合资源 | 3907 LUT，1420 寄存器，17 DRM18K 等效块，4 APM |
| 布局布线后时序 | 50 MHz，慢角 setup WNS +6.368 ns，快慢角无内部时序违例 |
| 启动仿真 | 输出完整 `RISCV OK`、启动完成 LED 点亮、UART 接收和回显均通过 |
| 位流 | generate_bitstream/top_mes50hp.sbit |

综合资源见 `synthesize/run.log`；完整时序报告见 `report_timing/top_mes50hp.rtr`；启动仿真日志见 `validation/sim/boot.log`；构建控制台日志见 `validation/bitstream_console.log`。`validation/build_summary.json` 记录最终文件校验值与验证结果。

时序报告中的“All Constraints Met”针对已约束的内部时钟路径。LED 和异步串口没有外部同步接口时序约束，工具会提示这些端口未约束；不能将内部时序通过理解为这些异步接口完成了独立的板级时序验证。尚未实际下载板卡，串口输出和 LED 行为仍需上板确认。

可使用本机 Vivado 2018.3 Xsim 重现启动与回显仿真：

```powershell
powershell -ExecutionPolicy Bypass -File .\validation\run_sim.ps1
```

其他 Vivado 安装位置可通过 `VIVADO_HOME` 指定。该测试使用与 PDS 相同的生成 Verilog 和初始化镜像。
