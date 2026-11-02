# NUMGUARD：RISC-V 数字料箱标签防错核验终端

本轮按用户要求新增CPU125 MHz / NPU50 MHz的独立时钟和MMIO握手，设计、验证与实际构建状态见 `CLOCK_SPLIT.md`。COCO80原版YOLO-FastestV2已在电脑端严格加载并核算算子/存储，当前固定NPU尚未支持该网络，详见 `model/COCO80_FEASIBILITY.md`。最新下载及验收以 `BOARD_VALIDATION.md` 和 `validation/hardware_summary.json` 为准。

按键界面现统一为三个模式：长按SW4一秒，依次切换 **HANDWRITE → GESTURE → COCO80 → HANDWRITE**。COCO80目前只完成模式控制和未部署提示；进入后继续显示相机预览，明确显示 `NO MODEL` / `MODEL NOT LOADED`，停止NPU并清除旧框。不能把能切换到菜单当成已实现80类识别。操作、寄存器和验证范围见 `MODES.md`。

本项目按紫光同创2026选题指南的**选题一：基于紫光同创 RISCV 指令集CPU设计**展开。应用聚焦十种料箱的数字标签0～9：先设定工单期望类别，再识别实际标签，稳定后给出 MATCH / WRONG，移走标签后再允许下一次计数。详细选题依据、目标和证据要求见 `competition/PROJECT.md`。国家级二等奖是设计目标，尚未获得，不能由软件仿真保证。

新增**手势数字1～9实验模式**，用于同一工位的数量手势核验；与数字标签模型分别训练、运行时切换。当前手势独立原图验证的148个增强正样本中，仅52个通过门限且类别正确，66个误分类、30个拒识，尚不适合可靠数量确认。训练、限制和真实相机采集方法见 `model/GESTURES.md`。

用户最新指定手型以参考图的一到十为准，十为双手食指交叉。采集、训练导出、固件及LCD已补齐十类支持，标准见 `model/GESTURE_STANDARD.md`。当前活动权重仍为旧九类，尚无符合该标准的完整实拍训练数据，不能把代码支持写成十类识别已经完成。新十类模型校验通过后构建器才启用MODE HAND 1-10。

板外仅使用实物18针DVP OV7670摄像头和AN430 LCD。目标芯片为PG2L100H / -6 / FBG676，摄像头接J7，LCD接 **J11**。2026-11-02根据实物照片纠正此前22针AL422模块的假设，当前使用 `camera_dvp_capture.v` 与18针重映射约束，旧FIFO接线表停用。复用原MES50HP的RV32IM内核和摄像头配置；当前源码的CPU目标125 MHz，NPU、MMIO和采集50 MHz，视频扫描域27 MHz，LCD像素9 MHz，相机MCLK 12.5 MHz。活动RTL全部为Verilog-2005，CPU源码位于 `rtl/cpu/`，构建不需要SystemVerilog或sv2v。接线及诊断见 `CAMERA_DEBUG.md`，新时钟设计见 `CLOCK_SPLIT.md`，原50 MHz基线记录保留在 `VERILOG_50MHZ.md`。

## 已实现的闭环

- 实时160×120 RGB565预览，LCD放大为320×240；数字红框和英文标签。
- 双模型ROM：数字0～9、手势1～9，复用一个50 MHz INT8引擎；顶部用HANDWRITE / GESTURE区分模式。三模式界面中的COCO80未部署模型，不运行这两个bank。
- 工单期望值0～9；独立识别全部十类后再比对，不用期望值诱导类别选择。
- 目标分数及类别差值门限；连续三次一致且位置稳定才确认。
- 上电、改工单、故障恢复均先要求三次确认空场；标签留在镜头前只计一次，直接换标签不能绕过移走要求。
- LCD顶部显示期望数字、当前数字和状态；底部显示OK/BAD计数和数字类别，左侧Q7为夹紧后的目标分数。
- 串口输出逐次审计事件；可回读带CRC32的4096字节实际模型输入，供真实相机数据采集。
- 独立CoreMark固件，固定官方算法源文件、64位计时与不少于10秒的有效成绩门限。

HANDWRITE复用现有数字模型，支持浅色背景上的单个深色数字；训练同时包含打印字体和MNIST，现有权重偏向打印数字，手写模式仍为实验功能。手势1～9也为实验功能；按用户参考图定义的完整北方1～10模型仍待实拍训练。COCO80和多位数字尚未实现板端识别。分数门限和连续投票不能保证拒绝所有干扰，也不能消除连续的系统性误识别；实际能力以独立数据和实物试验为准。

## 打开哪个工程

日常应用打开：

```text
fpga_pg2l100h/vision/build/j11/pg2l100h_vision.pds
```

顶层 `top_pg2l100h_vision`，项目格式1.1.0。需要包含Logos2 / PG2L100H器件库的完整PDS；本机 `E:/pango/PDS_2022.2-SP6.1` 的授权现已通过，2026-11-02完成实际构建和JTAG下载。工程准备、校验和目标构建命令为：

```powershell
python fpga_pg2l100h/vision/build.py --prepare-only --lcd-header J11
python fpga_pg2l100h/vision/build.py --check
python fpga_pg2l100h/vision/build.py --pds-home E:/pango/PDS_2022.2-SP6.1 --lcd-header J11
```

最后一行的PDS目录替换为实际安装目录。脚本要求新位流和布局布线后 `All Constraints Met` 才报告构建成功。当前DVP18版本的构建、资源、位流哈希与实际下载记录统一见 `BOARD_VALIDATION.md`；旧FIFO下载记录不能作为本版通过证据。实物接线按 `build/j11/WIRING.md`，当前约束假定18针逐号对应。屏幕P/L/V是原始活动计数，F是通过完整性检查的帧计数，二者含义不同。相机画面、识别、应用串口和温度仍需实物验收。

## 操作

| 操作 | 功能 |
|---|---|
| SW2 | 硬件复位 |
| SW4短按松开 | 数字模式的期望值加一；手写0～9循环，手势按实际模型1～9或1～10循环；COCO80模式忽略此操作 |
| SW4长按1秒后松开 | 手写数字→数字手势→COCO80→手写数字；每次按住只切一次，不触发短按 |
| SW5 | 彩条/相机画面切换 |
| SW6 | 冻结/恢复画面；冻结期间不继续核验 |
| SW7 | 重新配置摄像头 |
| 串口`0`～`9` | 设置期望数字；手势模式仅接受1～9 |
| `h` / `l`、`g`、`o` | 分别选择手写数字、数字手势、COCO80；`l`保留原采集工具兼容性，上电默认手写数字 |
| `m` | 与长按SW4相同，切换到下一个模式 |
| `q` | 清零OK/BAD，保留事件序号；重新要求移走标签 |
| `n` / `b` / `f` / `r` | 推理开关 / 彩条 / 冻结 / 重新配置 |
| `d` | 在下一次完整推理结果后输出一帧模型输入 |
| `?` | 输出状态 |

串口115200、8N1，无流控，使用板载CH340和接线表内的J9跳线。计数用**十六进制**显示，超过五位显示FULL；串口保留完整32位计数。LCD和审计事件把目标分数夹紧到0～127，网络原始线性输出可超出此范围；这些分数不是校准后的概率或百分比。

READY表示空场确认、可呈现标签；WAIT表示正在确认；MATCH / WRONG表示已记录一次核验；REMOVE要求先移走；UNSURE表示质量门限未通过；FAULT表示采集不可用、推理停用或结果超时。状态和红框在同一LCD帧边界提交。

切换模式清除旧框和未完成的连续确认，OK/BAD计数与事件序号继续累计，事件最后一列记录模式（0手写数字、1手势）。COCO80未部署时不产生识别或计数事件。需要分开统计时先保存日志，再用q清零计数。手势模式不自动把识别结果写成工单期望值，期望数量仍由按键或串口设置。

## 验证与数据

```powershell
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/verify.py
python fpga_pg2l100h/vision/tools/make_demo_cards.py
```

此前DVP采集版的十三项完整回归覆盖Verilog-2005、数字状态机、协议与训练数据、灰度和手势快照、272位跨时钟交接、DVP完整帧、LCD、双模型INT8、RV32固件和Pango GPLL板级包装，报告保存在对应冻结证据目录。本次修正实拍倒像，仅调整传感器MVFP参数，执行严格Verilog-2005及板级两项检查，当前报告为 `validation/simulation_summary.json`。仿真使用Icarus与Vivado Xsim，模型工具Python隔离于 `model/checkpoints/train_env/`。使用者已有CoreMark成绩和原始记录保留，本轮只重建J11应用。

训练和真实相机采集方法见 `model/DATASET.md`，实际模型结果见 `model/TRAINING_REPORT.md`。十类合成样本的精确整数预览在 `validation/numeric_examples.png`，它不是板上照片。打印演示卡在 `competition/demo_cards.pdf`。验收试验与答辩材料框架见 `competition/ACCEPTANCE.md`、`competition/REPORT_TEMPLATE.md`、`competition/DEMO.md`。

完整验证通过后可执行 `python fpga_pg2l100h/vision/competition/package_project.py`，生成 `competition/NUMGUARD_project.zip`，含源码、模型、独立J11 PDS工程、校验清单和仿真证据。打包器会拒绝旧模型/旧固件的失配工程；压缩包仍明确标注实物验收待完成，不作为已获奖或已完成硬件测评的证明。

本轮交付结果汇总在 `competition/VALIDATION.md`。软件回归、PG2L100H实际综合/布局布线、50 MHz时序和JTAG配置均已完成；板载CH340串口未接通，仍待温度检查、摄像头/LCD、冷启动和独立识别验收。原始硬件记录在 `validation/hardware_summary.json` 及 `validation/hardware_20261102/`。此前混合12类实验保存在 `PUBLIC12_ARCHIVE.md` 和 `model/PUBLIC12_*_ARCHIVE.md`；新手势专用模型独立保存在 `model/gesture/`。手势示例 `validation/gesture_examples.png` 保留各类首个样本及其失败结果，是软件整数参考图，不是板上照片。
