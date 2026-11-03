> **范围/口径声明（交付主体）**：本文属于**紫光同创 PG2L100H** 交付主体线。文中"实测"指上板实测并应附证据路径；"未达成/未部署"项见根 [`COMPLIANCE.md`](COMPLIANCE.md) §4 边界清单。注意：**Pango 侧 Flash 当前尚未写入**（JTAG RAM 下载），详见 [`fpga_pg2l100h/vision/BOARD_VALIDATION.md`](fpga_pg2l100h/vision/BOARD_VALIDATION.md)。

# 轻量开源模型与本工程的兼容性

核查日期：2026-11-01。以下参数和预训练能力来自原作者仓库或论文；它们不是 PG2L100H 的资源利用率、时序或摄像头识别实测。

| 项目 | 规模与现成权重 | 人 / 自行车 / 杯子 | 中文数字手势一至九 | 与当前 FPGA 的关系 |
|---|---|---|---|---|
| [YOLO-FastestV2](https://github.com/dog-qiuqiu/Yolo-FastestV2) | 作者报告约 0.25M 参数；仓库提供 COCO `.pth`，本地核实为 1,158,025 字节 | COCO 预训练包含 person、bicycle、cup | 没有这九个数字手势类别，需要另外训练 | 最值得参考的成品小检测器之一；包含深度卷积、通道重排和拼接，不能加载到当前固定六层核 |
| [Ultralytics YOLOv8n](https://docs.ultralytics.com/models/yolov8/) | 官方表列 3.2M 参数；提供 COCO 预训练 `yolov8n.pt` | 包含上述 COCO 类别 | 需要自定义数据再训练 | 可用于电脑基线或教师模型；当前工程未移植其结构 |
| [TinyissimoYOLO](https://github.com/ETH-PBL/TinyissimoYOLO) | [论文](https://arxiv.org/abs/2311.01057)提出小于 0.5M 参数、INT8 的模型族 | 取决于具体训练配置 | 需要自定义数据 | 官方仓库有训练 / 导出实现；此次核查的仓库和指南没有给出已验证的目标类别通用权重下载项，不视为已拿到现成模型 |
| [Chinese-number-gestures-recognition](https://github.com/tz28/Chinese-number-gestures-recognition) | 提供约 6.78MB 的 TensorFlow `.pb` 冻结图 | 不支持 | 作者提供 0～10 的中文数字手势分类器及 64×64 数据 | 是分类模型，不是带真实手部框的 YOLO 检测器；不能直接导入当前 NPU |
| 本工程 MicroYOLO-64 | 21,672 字节 INT8 卷积权重，22 个固定类别槽位 | 可用实际样本重训 | 可用实际样本重训 | 六层普通卷积结构和整数运算与 RTL 一致；能力以本工程独立验证结果为准 |

COCO 的 `cup` 与 `bottle` 是不同类别。本次水杯使用 `cup` 标注，不能把它解释成对全部矿泉水瓶、保温瓶和任意容器的覆盖。

## 已下载和校验的参考权重

这两份文件保存在 `model/checkpoints/pretrained/`，只作参考，没有伪装成 FPGA 可加载的 ROM：

| 文件 | SHA-256 |
|---|---|
| `yolo_fastestv2_coco.pth` | `bdd956aa079bf1cdd3e0090a295ac26d73c40aef7b61b6405981b1afcbea985c` |
| `chinese_number_gestures.pb` | `69d593f024903bba4b0d415ec8a38a1588ae4ba6dcbdca8847f34c6aa7df96f7` |

对应源版本为 YOLO-FastestV2 `ac2a5e3060bff76dd1e45f9b921dd77bfbeb194d`、中文手势仓库 `2a9136b223064450ffde79d3f2e01c0de41baf09`。下载脚本固定源版本，核对文件长度和 SHA-256，不执行下载仓库中的训练代码：

```powershell
$visionPython = "fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe"
& $visionPython fpga_pg2l100h/vision/model/fetch_reference_weights.py
```

已用 PyTorch 的 `weights_only=True` 检查 YOLO-FastestV2 文件：444 个状态张量，共 251,664 个状态元素，包含 BatchNorm 缓冲区；这个数不能当作精确可训练参数数。`.pth` 是浮点状态文件，文件大小也不能直接等同于 INT8 权重大小或 FPGA 总存储需求。

## 本轮兼容训练的数据

`prepare_public_dataset.py` 从官方 COCO 2017 数据中选取 person、bicycle、cup，使用原始实例框裁剪，并用源图 ID 固定训练 / 验证分组。这里内部划分的是 COCO val 子集，不能把结果报成标准 COCO mAP。

中文手势仓库的原始数据只有 215 张照片，仓库内的 64×64 图片大多是这些照片的增强结果。脚本按文件中保留的原始照片前缀划分分组，将同一照片的全部增强变体放在同一侧；没有被试身份信息，因此不能声称做过独立人员测试。所选一至九手势共有 183 个源照片分组。

手势原数据没有手部实例框。本轮将分类照片贴入画面，使用整个贴图矩形作为弱框标签。该框是合成贴图的位置，不等于真实摄像头中的紧致手部框。需要真实手部框标注和 OV7670 图像补训，才能评估现场定位效果。标签名称 `HAND 6`～`HAND 9` 来自中文手势图像，不是统计伸出手指的数量。

优先训练的 12 类数据位于 `model/checkpoints/public12_dataset/`，共 2141 张：1829 张用于训练、312 张用于验证，包含真实 COCO 无目标背景和合成空白。手势分类照片以 112×112 贴入 160×120 画面，在模型内占 56×56 像素。数据清单、分组、来源、样本数和原档案校验值保存在该目录的 `provenance.json`。图像预处理与 RTL 的 RGB565、64×64 中央区域、反相灰度和 Q7 量化一致。训练使用类别平衡采样、平移、水平翻转和灰度噪声。

原始数字模型保存在 `model/baselines/digits/`。物体 / 手势模型与数字模型是不同权重配置，切换后必须重新生成位流；当前没有在同一位流中同时切换两套模型。`candidates/public22/` 保留了混合 22 类的早期实验，其指定 12 类的平均召回很低，不能据此宣称已经具备通用识别能力。

```powershell
& $visionPython fpga_pg2l100h/vision/model/prepare_public_dataset.py --output fpga_pg2l100h/vision/model/checkpoints/public12_dataset --requested-only --hand-patch-size 112
& $visionPython fpga_pg2l100h/vision/model/train_public.py --dataset fpga_pg2l100h/vision/model/checkpoints/public12_dataset --output fpga_pg2l100h/vision/model/candidates/public12 --requested-only --from-scratch --class-weight 1.0 --steps 12000
python fpga_pg2l100h/vision/model/select_model.py --source fpga_pg2l100h/vision/model/candidates/public12
python fpga_pg2l100h/vision/build.py --prepare-only --lcd-header J11
& $visionPython fpga_pg2l100h/vision/verify.py
```

默认数据整理命令拒绝覆盖已完成的数据清单，避免旧分组图像残留；需要重做时使用一个新的 `--output` 目录。训练先写候选目录，选择模型后才替换活动 ROM。原数字版保存在 `model/baselines/digits/`，可以用 `select_model.py --source` 切回，再重新准备工程和生成位流。

## 结果的解释

`model.json` 的 `per_class` 同时记录每类样本数、检出数、类别正确数、类别正确且 IoU≥0.5 的数量和召回率。`oracle_cell_correct` 是给定正确网格位置时的分类计数，不能当作端到端检测正确数。`confusion` 最后一行 / 列代表无目标；`blank_false_positives` 是无目标图被误报的张数。平均值采用逐类平均，不能隐藏低样本类别的不确定性。

所有这些都是特定小验证集上的精确整数软件评估。RTL 仿真核对整数算术、固件解码和显示接口；它不能代替真实镜头、照明、视距、多人背景和 PG2L100H 资源 / 时序测试。当前逐次只选一个最高分目标，完整 YOLO 的多尺度多目标能力不包含在本次结构内。
