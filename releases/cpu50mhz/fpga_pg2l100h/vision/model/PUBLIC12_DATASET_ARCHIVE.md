# 历史12类数据集实验（已归档）

这是转向数字标签核验之前的记录，以下活动模型说明仅描述当时配置；不代表当前 NUMGUARD 工程。

活动 `micro_yolo.npz`、`weights.hex`、`biases.hex`、`shifts.hex` 使用本轮实际训练的 12 类物体 / 手势实验权重，`model.json` 的 `enabled_classes` 和固件自动生成的掩码启用人、自行车、杯子和中文手势一至九。验证效果仍不足，完整计数见 `TRAINING_REPORT.md`。原数字基线在 `baselines/digits/`；当前 12 类配置不同时启用数字。不能手动打开未参与本次训练的类别掩码来获得识别能力。

公开数据的准备、预训练参考权重、优先 12 类训练和模型切换命令见 `OPEN_SOURCE_MODELS.md`。手势公开集是分类裁剪图，没有真实手部框，本轮合成贴图框不能替代手部标注。下面格式用于补入自己 OV7670 拍到的图像和真实框。64×64 灰度输入对远处小目标、相似手势和复杂场景有明显限制。中国数字手势六、七、八、九应作为独立图像类别训练，不能直接用“伸出手指数”代替。

## 数据格式

训练脚本接受常见 YOLO 文本框标注，每张图片目前限定一个目标，也支持没有目标的空白/背景图。目录如下：

```text
my_camera_data/
  classes.json
  images/train/*.png
  images/val/*.png
  labels/train/*.txt
  labels/val/*.txt
```

`classes.json` 填本次确有数据的类别，例如：

```json
["people", "bike", "cup", "hand 1", "hand 2", "hand 3", "hand 4", "hand 5", "hand 6", "hand 7", "hand 8", "hand 9"]
```

可用名字为 `people`、`bike`、`cup`、`hand 1`～`hand 9`、`digit 0`～`digit 9`。同一个模型要同时支持数字，训练集中也必须加入数字数据。训练会按文件内顺序映射标注类别，再转换成 FPGA 固定类别编号；只有本次真实参与训练的类别会启用。

每张图片都有一个同名 `.txt`。一行格式为：

```text
class_index center_x center_y width height
```

坐标相对于原图宽高归一化到 0…1，类别从 `classes.json` 的第 0 项开始。背景图片也必须有同名空文本，缺少标注文件会报错。图片先缩放到 160×120，再执行与 FPGA 一致的 RGB565 量化、中央裁剪、灰度和反相处理；目标框必须完整落在缩放后 x=16…144、y=0…120 的采集范围内。

训练集和验证集应按不同拍摄片段、背景和人员划分。脚本拒绝训练与验证完全相同的图像内容，检查每个声明类别在两个分组都有真实标注，但这不能替代人工检查相邻帧泄漏。请加入相同背景下的无目标图片和容易混淆的物体，分别记录各类错误。

## 校验、训练与部署

使用 README 中的独立 Python 环境：

```powershell
$visionPython = "fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe"
& $visionPython fpga_pg2l100h/vision/model/train_dataset.py --dataset D:/my_camera_data --validate-only
& $visionPython fpga_pg2l100h/vision/model/train_dataset.py --dataset D:/my_camera_data --steps 8000
python fpga_pg2l100h/vision/build.py --prepare-only --lcd-header J11
& $visionPython fpga_pg2l100h/vision/verify.py
```

训练会替换 `model/` 内当前权重、类别掩码、验证指标和参考向量，开始前应保留想继续使用的模型版本。`model.json` 记录单独验证集的整数推理结果和输入数据校验值；需要检查类别正确、IoU、背景误检，再用 PDS 重新生成位流。替换文件后不重新生成位流不会更新 FPGA 中的权重。

本轮公开数据、源照片分组和实测整数验证结果已保留，但没有实际 OV7670 采集数据或上板准确率。若需要可靠识别，应补充多人员、多背景、不同视距和灯光下的真实框标注，重新评估数据和模型容量；当前紧凑模型的低验证召回不能解释成 PG2L100H 的硬件容量上限。
