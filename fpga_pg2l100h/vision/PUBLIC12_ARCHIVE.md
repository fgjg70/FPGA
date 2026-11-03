> **范围/口径声明（交付主体）**：本文属于**紫光同创 PG2L100H** 交付主体线。文中"实测"指上板实测并应附证据路径；"未达成/未部署"项见根 [`COMPLIANCE.md`](https://github.com/fgjg70/FPGA/blob/main/COMPLIANCE.md) §4 边界清单。注意：**Pango 侧 Flash 当前尚未写入**（JTAG RAM 下载），详见 [`fpga_pg2l100h/vision/BOARD_VALIDATION.md`](https://github.com/fgjg70/FPGA/blob/main/fpga_pg2l100h/vision/BOARD_VALIDATION.md)。

# 历史通用识别实验（已归档，不是当前参赛项目）

以下保留转向数字标签核验之前的12类实验记录，其中“当前”均指当时的历史配置。活动项目现在为 `competition/PROJECT.md` 定义的 NUMGUARD；活动模型只启用数字0～9。

目标为 Logos2 / PG2L100H / -6 / FBG676，LCD 为 J11 上的 AN430，摄像头为 J7 转接的 OV7670 + AL422 FIFO。只使用这两个板外外设；板载 USB 串口用于状态输出和控制，推理不依赖电脑。

这是从 MES50HP 工程复用原 RISC-V 内核、摄像头配置和 FIFO 采集链路的新应用。CPU、卷积引擎和采集逻辑统一使用 **27 MHz**，LCD 像素时钟为 **9 MHz**。模型权重放在 FPGA 初始化存储器中，不用串口从电脑计算结果。

## 当前能力与边界

| 项目 | 本次状态 |
|---|---|
| OV7670 配置、FIFO 采集、双缓冲 | 已接入，复用既有外设逻辑 |
| LCD 摄像头预览 | 160×120 RGB565，放大为 320×240 居中显示，LCD 时序为 480×272 |
| 检测红框和右下角英文标签 | 已实现；坐标和类别在帧边界一起提交 |
| 手写数字 0～9 | 已训练的数字基线保存在 `model/baselines/digits/`；当前物体 / 手势配置不启用数字 |
| 人、自行车、水杯 | 已用 COCO 原始实例标注训练，`PEOPLE`、`BIKE`、`CUP` 在实验配置中启用 |
| 手势一～九 | 已用中文数字手势图像训练，`HAND 1`～`HAND 9` 在实验配置中启用；使用合成贴图弱框 |
| PG2L100H 综合、布局布线、时序和实物 | 尚未完成目标编译和实物验证；当前没有本工程 `.sbit` |

当前配置是 **12 类物体 / 手势训练实验版**。类别已经参与实际训练，但独立验证效果仍不足，尤其是手势分类和真实背景误检，不能把类别启用解释成这些类别已可靠识别。逐类计数与数据限制见 `model/TRAINING_REPORT.md`。手势框标注的是分类照片贴入画面的范围，没有真实手部实例框。每次只显示最高分的一个目标，未实现多目标跟踪；红框会比连续刷新的画面有采集和推理延迟。原数字基线是独立模型，切换模型后必须重新生成位流，当前未实现两套模型在同一位流中同时运行。

本模型名为 MicroYOLO-64，是采用网格、目标置信度、边框回归和类别输出的自定义小型 YOLO 风格检测器。**不能直接装入 YOLOv5/YOLOv8 的 `.pt` 或 ONNX 权重**；网络层数、通道、量化与硬件布局必须一致。当前并不是标准 YOLO 通用预训练模型的 FPGA 移植。

## 打开与构建

安装包含 PG2L100H 的完整 PDS，例如你准备安装的 `PDS_2022.2-SP6.7-ads-win64`，在新版本程序中打开：

```text
fpga_pg2l100h/vision/build/j11/pg2l100h_vision.pds
```

顶层为 `top_pg2l100h_vision`。这个目录内带独立 RTL、固件镜像、模型初始化文件、引脚约束和接线表，编译期间相对路径从该工程目录解析。不要同时把原始 SystemVerilog 和转换后的 `vision_soc.v` 加入 PDS。

从仓库根目录重新准备工程：

```powershell
python fpga_pg2l100h/vision/build.py --prepare-only --lcd-header J11
python fpga_pg2l100h/vision/build.py --check
```

准备脚本需要原工程已有的 sv2v 和 RISC-V GCC；可用 `--sv2v`、`--gcc` 指定路径。构建现有已训练模型不需要 PyTorch。

安装完成后，将下面路径替换为实际安装目录，运行完整构建：

```powershell
python fpga_pg2l100h/vision/build.py --pds-home D:/PDS/PDS_2022.2-SP6.7-ads-win64 --lcd-header J11
```

也可在 PDS 中执行 Generate Bitstream / Rerun All。构建脚本只有在没有 `E:` 错误、产生新位流、布局布线后时序报告含 `All Constraints Met` 时才写 `success=true`。目标下载文件为 `build/j11/generate_bitstream/top_pg2l100h_vision.sbit`，当前尚未生成。

接线沿用 `build/j11/WIRING.md`。J7 是 18 针，所给 FIFO 摄像头是 22 针，应按信号转接；具体 FPGA 球号与 J11/J7 信号映射均保存在工程自己的 `pinout.json` 和 `wiring.csv` 中。

## 控制与现象

默认显示摄像头并启用当前权重中的 12 类检测。未检测到目标时显示 `NO TARGET`，检出时显示 `PEOPLE`、`BIKE`、`CUP` 或 `HAND 1`～`HAND 9`。切回数字基线后使用 `DIGIT 0`～`DIGIT 9`。没有摄像头帧时不会显示检测框。

| 板载键 | 串口字符 | 功能 |
|---|---|---|
| SW4 | `n` | 开关识别 |
| SW5 | `b` | 开关 FPGA 彩条 |
| SW6 | `f` | 冻结 / 继续采集 |
| SW7 | `r` | 重新配置摄像头并解除冻结 |
| SW2 | 无 | 全部逻辑复位 |
| 无 | `c` | 回到摄像头并启用识别 |
| 无 | `?` | 请求串口状态 |

串口为 115200、8N1。启动输出 `VISION27 READY MICROYOLO64 INT8` 和有效类别掩码；12 类配置掩码为 `0x00000fff`，数字基线为 `0x003ff000`。每秒状态中的 `FR` 为摄像头采集帧数，`NN` 为固件确认过的推理次数，`CYC` 为最近一次推理周期，`DET` 表示最近一次解码是否有框。置信度是网格的目标分数，不是经过 softmax 校准的类别概率。

LED 对应心跳、摄像头配置成功、卷积引擎运行、摄像头失败或 CPU 非法指令。四个输出依次是 `led[0]`～`led[3]`；板上丝印和原理图元件编号见接线表。

## 验证结果

2026-11-01 的物体 / 手势数据实验使用 1829 张训练图和 312 张独立源照片分组的验证图，其中 284 张有目标、28 张无目标。人、自行车、杯子使用 COCO 实例框；手势使用分类照片的合成贴图框。每类样本数、类别正确和 IoU≥0.5 的计数、背景误检详见 `model/TRAINING_REPORT.md` 和活动模型 `model/model.json`，不能将其称作标准 COCO mAP 或真实摄像头准确率。

| 验证项 | 结果 |
|---|---|
| 当前训练类别 | 0…11：人、自行车、杯子、中文数字手势一至九 |
| 当前权重与偏置 | 21,672 字节 INT8 权重、556 字节偏置，网络结构未扩大 |
| 两个 RTL 样本与整数参考逐值对比 | 864 个输出值全部一致 |
| 纯卷积引擎周期 | 1,769,238，27 MHz 下约 65.53 ms |

数字基线的旧合成验证为 386 / 419 正确且 IoU≥0.5，空白误检 0 / 93；这些数只适用于 `model/baselines/digits/`，不能套用到当前 12 类模型。65.53 ms 是计算时间，不是整机 FPS；采集、等待下一完整帧、CPU 解码和显示提交还需要时间。

单独测试覆盖快照裁剪/补边/灰度、LCD 红框和字形、卷积输出保持/确认/中途复位，以及实际 RISC-V 固件从 RGB565 摄像头数据到检测框的完整链路。板级测试使用本机 PDS 的真实 GPLL 仿真模型，验证时钟、LCD、RGB888 扩展、四个按键和 PLL 重锁复位。报告在 `validation/simulation_summary.json` 与 `validation/board_summary.json`，图像在 `validation/lcd_overlay.png`；图像是固定框的 RTL 显示测试画面。

`validation/public_validation_examples.png` 使用固定的每类首张验证图，画出真实整数参考输出；绿框为标注、红框为预测，失败样本也保留。它不是实物摄像头照片。`validation/digit_reference_preview.png` 是旧数字基线的参考图，不能据此评估当前模型。

重现训练与仿真使用独立 Python 环境，避免改变已有 Python 包：

```powershell
python -m venv fpga_pg2l100h/vision/model/checkpoints/train_env
$visionPython = "fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe"
& $visionPython -m pip install -r fpga_pg2l100h/vision/model/requirements.txt
& $visionPython fpga_pg2l100h/vision/model/prepare_public_dataset.py --output fpga_pg2l100h/vision/model/checkpoints/public12_dataset --requested-only --hand-patch-size 112
& $visionPython fpga_pg2l100h/vision/model/train_public.py --dataset fpga_pg2l100h/vision/model/checkpoints/public12_dataset --output fpga_pg2l100h/vision/model/candidates/public12 --requested-only --from-scratch --class-weight 1.0 --steps 12000
python fpga_pg2l100h/vision/model/select_model.py --source fpga_pg2l100h/vision/model/candidates/public12
python fpga_pg2l100h/vision/build.py --prepare-only --lcd-header J11
& $visionPython fpga_pg2l100h/vision/verify.py
```

MNIST 数据使用仓库原工程的 `fpga_mes50hp/model/cache/`。验证需要 Icarus Verilog，板级测试另需本机 Vivado Xsim 和 PDS 的 GPLL 模型；各工具路径可用脚本参数指定。已有权重和参考向量随 `model/` 保留，日常验证无需重新训练。

自行采集并补训的格式见 `model/DATASET.md`，开源预训练模型调查和参考权重下载见 `model/OPEN_SOURCE_MODELS.md`；存储、网络和寄存器接口见 `ARCHITECTURE.md`。
