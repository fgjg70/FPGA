# 盘古100H：CoreMark、手势与瓶盖分拣

2026-11-04 最新分拣配置见 [CAP_SORTING.md](CAP_SORTING.md)：SW2 复位、SW4 CoreMark、SW5 瓶盖、SW6 手势 1～5。工程为 `build/dual_caps_sorter128_j11/pg2l100h_vision.pds`，使用 95 MHz 双发射 CPU、50 MHz 的 128 MAC NPU/MMIO，片内存储，不使用 DDR。CoreMark 与识别程序合入同一固件。

瓶盖模式：1 号舵机每 5 秒下料一次、下放保持 500 ms 后回位；2 号绿色、3 号黄色、4 号红色。目标舱门提前 250 ms 打开，下料后保持至 2 秒再关闭。5～7 号不参与自动分拣。动作脉宽和履带通过时间须按机构校准，接线见 [SERVOS.md](SERVOS.md)。手势仍为旧实验权重，实际识别效果和本轮舵机动作需要上板验收。

下面保留历史性能和模型记录；其中旧按键、4 MAC 数据、坚果或 DDR 方案不代表本轮配置，旧位流和旧回归不能代替本轮验收。

## 历史版本记录

活动工程只保留 **BOTTLE CAPS ↔ GESTURE** 两种模式。默认单发射 CPU、指令和数据存储为125 MHz，NPU、相机采集和MMIO为50 MHz。摄像头OV7670接J7，AN430 LCD接J11，活动RTL均为Verilog-2005。

可选 `--cpu dual` 使用95 MHz双发射核心：官方 CoreMark 16次迭代RTL短测为 **3.9572/MHz**，达到3.87目标；PDS详细时序最差裕量为+0.682 ns。独立工程位于 `build/dual_j11`，实现和复现命令见 [双发射实验](experiments/dual_issue/README.md)。此读数尚不属于至少10秒的板卡正式跑分。

新增七路独立舵机PWM：1号入口放行，2～7号为六个盒子口分流，信号使用J12的A20、C19、C18、A19、D19、D18、B19。周期20 ms，脉宽1,000～2,000 μs，复位后关闭。接线、串口逐路校准和自动分拣所需参数见 [SERVOS.md](SERVOS.md)。

当前整板20项回归已通过，包括七路PWM、CPU、NPU和相机/LCD整机仿真。CPU读数对齐和移位路径优化后，PDS整板时序通过：125 MHz CPU域WNS为+0.302 ns，50 MHz外设域为+7.072 ns。它证明生成位流满足工具时序检查，实物识别和七路舵机仍需核对板上验收；此前失败构建与舵机接线记录见SERVOS.md。

| 模式 | 类别 | 当前状态 |
|---|---|---|
| 0 BOTTLE CAPS | red_cap、purple_cap、green_cap、yellow_cap | 已训练并选入约2.2万参数的RGB INT8板端模型；500张合成测试图F1为0.9712，实板精度待验证 |
| 1 GESTURE | 北方一至十接口 | 保留旧九类实验权重；其准确率不足，不能当作已经完成北方十类识别 |

两个用户提供的原始模型均为224×224 RGB、2,048,721参数的MobileNetV2/FPN检测器，不能直接写入本工程的固定小NPU。瓶盖板端模型是用包内标注**重新训练的紧凑模型**，没有复制原始网络权重，也没有做教师logit蒸馏。原始ONNX独立保留，可通过 `model/reference_infer.py` 在电脑运行。适配和测试边界见 `model/OBJECT_MODELS.md`。

本轮查找并下载了HaGRIDv2官方MobileNetV3-small预训练权重、配置和许可证，提供了可执行的电脑参考推理。可以直接理解其33种原有手势，不要求强制对应北方一至十；全部手型、中文含义和示意图见 [HAGRID_LABELS.md](model/HAGRID_LABELS.md)。模型来源和严格校验见 `model/OPEN_SOURCE_MODELS.md`。这个参考模型尚未装入FPGA，旧手势精度尚未改善。

NPU现为四路输出通道并行、连续读ROM的INT8乘加流水线，RGB和手势计算分别为279174和242310周期；50 MHz下约5.583 ms和4.846 ms。它保持原量化结果，提升的是计算吞吐量。CoreMark测量、GitHub分支核查和三种原始检测模型的选择依据见 [PERFORMANCE.md](PERFORMANCE.md)。

## 操作

上电优先进入瓶盖模型；长按SW4一秒后松开，在瓶盖和手势之间切换。短按SW4仅在手势模式切换期望数字，SW5切换彩条，SW6冻结/恢复，SW7重新配置相机，SW2复位逻辑。

物品模式最多显示四个红框，右下角显示置信分数最高目标的英文名称。顶部COUNT是当前快照中的目标数，FRM是已处理快照数，EMPTY是无有效检测的快照数；没有跨帧目标跟踪，不能用FRM代替物品去重计数。手势仍使用原三帧稳定及移走再确认逻辑。

串口115200、8N1，通过板载CH340使用；烧录器的虚拟串口不能代替应用UART。

| 命令 | 功能 |
|---|---|
| p / g | 瓶盖 / 手势 |
| m | 下一个模式，与长按SW4一致 |
| 1～9 | 手势期望值；仅安装完整十类模型后，0代表十 |
| q | 清计数 |
| n / b / f / r | 推理开关 / 彩条 / 冻结 / 相机重配 |
| d | 下一次推理完成后导出实际输入；物品为12288字节RGB Q7，手势为4096字节轮廓Q7，均带CRC32 |
| ? | 状态、模式、是否有模型、当前目标数和推理周期 |
| s1=1500（回车） | 设置1号舵机1,500 μs并启用；编号可用1～7，非零脉宽范围1,000～2,000 μs |
| s1=0 / s0=0（回车） | 关闭单路 / 全部舵机PWM |

## 工程和验证

打开 `build/j11/pg2l100h_vision.pds`。使用包含PG2L100H器件数据和有效许可的PDS；本机完整安装为 `E:/pango/PDS_2022.2-SP6.1`。构建和验证命令从FPGA-main目录执行：

```powershell
python fpga_pg2l100h/vision/build.py --pds-home E:/pango/PDS_2022.2-SP6.1
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/verify.py --pds-home E:/pango/PDS_2022.2-SP6.1
```

`build.py --prepare-only`只生成工程和固件，`--check`验证源码、模型和生成文件哈希。执行完整构建会检查新位流、布局布线摘要和详细时序报告。当前位流及构建结果在 `build/j11/build_summary.json`；仿真结果在 `validation/simulation_summary.json`。这些本地生成文件不自动提交Git。

旧活动手写权重已移到本地 `model/checkpoints/retired_models/20261103/`，不再参与构建；旧候选和CPU50 MHz冻结发行版保留历史。日用品和COCO80只保留电脑参考资料，不在活动模式或已部署能力表中。CoreMark已进行CRC校验的RTL短测，尚无本轮满足十秒要求的实板成绩。板上程序记录另见 `BOARD_VALIDATION.md` 和 `validation/hardware_summary.json`，须核对位流哈希。

数据通路、坐标、ROM、MMIO和四框原子提交见 `ARCHITECTURE.md`，操作细节见 `MODES.md`。本轮模型结果与缺失数据清单见 `model/OBJECT_MODELS.md`；原竞赛文档中数字料箱和COCO80描述属于此前方案。
