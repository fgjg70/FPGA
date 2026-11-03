> **参考资料声明（第三方/历史工程）**：本目录是板卡厂商示例或早期开发工程，**不是赛题交付主体**；其中的结论/数字不进入交付成绩，引用时需标注来源并置于"跨厂商对比/参考资料"语境。

# PDS 1.0.9 兼容工程

板卡现已确认为 MES50HP（PGL50H）。请使用新建的 `../fpga_mes50hp/riscv_mes50hp.pds`：该工程已补齐板级引脚和启动程序，并生成 `../fpga_mes50hp/generate_bitstream/top_mes50hp.sbit`。本目录保留为原 PGL22G 配置的兼容迁移基线。

本工程使用本机 PDS 2022.2-SP1-Lite（build 132640）生成，工程格式为 1.0.9。
已修复 `Verilog-4203`、模块头 `import` 语法错误，以及默认循环展开上限不足的问题。

在 PDS 中关闭之前打开的工程，再通过 **File → Open Project** 打开本目录的 `riscv_pgl22g.pds`，以加载更新后的文件列表。

## 当前配置与上板条件

| 项目 | 配置 |
| --- | --- |
| 器件 | Logos / PGL22G / FBG256 / -6 |
| 顶层 | top_pgl22g |
| PDS 编译输入 | generated/riscv_pds.v |
| 转换宏 | SYNTHESIS |
| 循环展开上限 | 10000 |
| 时钟约束 | sys_clk，50 MHz，周期 20 ns |

本目录器件配置沿用原工程，**不要将本目录 PGL22G 配置的输出下载到 MES50HP**。针对 MES50HP 的 PGL50H / FBG484 / -6 配置、引脚约束和完整构建结果位于 `../fpga_mes50hp/`。

`riscv.fdc` 目前仅包含时钟约束，没有物理管脚分配。工程也尚未绑定 `IMEM_INIT_FILE` / `DMEM_INIT_FILE` 启动镜像。PDS 会忽略部分 `initial` 中的初始化行为，当前综合结果有大量逻辑被优化，不能据此认定处理器已经具备上板运行条件。下载前应核对实际器件、板卡原理图、I/O 电平、物理引脚和启动程序，再进行完整实现及板上验证。

## 源码与兼容转换

原工程的 23 个 SystemVerilog 文件保存在 `src/`，与迁移前源码逐一通过 SHA-256 校验。根目录原文件和旧工程保持原样。

本机 PDS 的 ADS 前端不能直接处理这些源码中的枚举和部分 package/import 语法。`prepare_rtl.py` 使用 sv2v 0.0.13，按照 `sources.f` 的顺序将 `src/` 转成 Verilog，再由 PDS 编译。不要在 PDS 中同时加入生成文件和原始 SystemVerilog 文件。

后续修改本工程时编辑 `src/`，然后执行：

```powershell
python .\prepare_rtl.py
python .\prepare_rtl.py --check
```

生成文件是 `generated/riscv_pds.v`。`generated/manifest.json` 保存输入、转换器和输出的校验值；`--check` 可发现生成文件未随源码更新的情况。不要直接修改生成的 Verilog。

转换器已放在 `tools/sv2v/sv2v.exe`。如果复制工程时没有带上可执行文件，可执行下面的命令重新下载固定版本并校验 SHA-256：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_tools.ps1
```

也可通过 `SV2V` 环境变量或 `prepare_rtl.py --sv2v <路径>` 使用其他位置的转换器。脚本需要 Python 3。

## 编译与生成下载文件

在 PDS 左侧 **Flow** 中双击 **Compile** 可检查编译，双击 **Synthesize** 可运行综合。

完成板级适配后，右键 **Generate Bitstream → Rerun All**，执行包括前置步骤的完整流程：

**Compile → Synthesize → Device Map → Place & Route → Generate Bitstream**

成功后使用生成的 `.sbit` 文件下载。当前尚未执行 Device Map、布局布线及位流生成。

也可在本目录执行已经验证的命令：

```powershell
& "E:\PDS\bin\pds_shell.exe" -project "riscv_pgl22g.pds" -run compile
& "E:\PDS\bin\pds_shell.exe" -project "riscv_pgl22g.pds" -run synthesize
```

## 下载器操作

在 PDS 中选择 **Tools → Configuration**，打开 Fabric Configuration。

1. 选择左侧 **Boundary Scan**，点击 **Scan Device**，先读取连接器件的型号。
2. 核对扫描型号与工程器件一致后，使用 **Assign New Configuration File** 选择对应 `.sbit`。
3. 选中 FPGA，右键 **Program**；完成后可执行 **Verify** 校验。

JTAG 下载和 SPI Flash 固化是不同操作。需要断电后保留时，应按实际板卡的 Flash 型号和启动方式配置，不能直接套用 FPGA 的下载设置。

## 已完成验证

验证日期：2026-10-20。

| 验证项 | 结果 | 日志 |
| --- | --- | --- |
| PDS Compile | 通过 | validation/compile.log |
| PDS Synthesize | 通过 | validation/synthesis.log |
| 现有 tb_units 单元测试 | 243 检查，0 错误 | validation/units/units.log |
| basic | PASS，179 周期 | validation/core/basic.log |
| trap | PASS，94 周期 | validation/core/trap.log |
| m_ext | PASS，326 周期 | validation/core/m_ext.log |
| mmio | PASS，12893 周期 | validation/core/mmio.log |
| timer_irq | PASS，15517 周期 | validation/core/timer_irq.log |

单元测试使用实际生成的 Verilog；处理器和 SoC 测试使用同一组源码的仿真转换版本，保留运行时镜像加载。仿真由本机 Vivado 2018.3 Xsim 执行，测试程序来自现有 `sim/prog/`，没有修改原测试断言。未运行所有可选处理器参数组合。

编译和综合日志中没有 `E:` 错误，但仍有初始化、属性和 I/O 约束相关警告。上述仿真不替代综合网表、时序收敛和板级验证。兼容修复前的工程和日志备份位于 `validation/before_compatibility.pds.bak` 和 `validation/before_compatibility.log`。

## 重新生成工程

双击 `create_project.bat` 可先转换源码，再重新生成 `riscv_pgl22g.pds`；默认安装路径为 `E:/PDS`，可用 `PDS_HOME` 修改。

重新生成会恢复 `create_project.tcl` 中的器件和流程配置，并重置已有流程状态。若已修改器件、顶层或板级设置，应先将相应配置同步到脚本。该批处理只生成工程，不自动编译或下载。
