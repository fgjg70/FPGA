> **范围/口径声明（交付主体）**：本文属于**紫光同创 PG2L100H** 交付主体线。文中"实测"指上板实测并应附证据路径；"未达成/未部署"项见根 [`COMPLIANCE.md`](https://github.com/fgjg70/FPGA/blob/main/COMPLIANCE.md) §4 边界清单。注意：**Pango 侧 Flash 当前尚未写入**（JTAG RAM 下载），详见 [`fpga_pg2l100h/vision/BOARD_VALIDATION.md`](https://github.com/fgjg70/FPGA/blob/main/fpga_pg2l100h/vision/BOARD_VALIDATION.md)。

# 数字标签训练与真实数据闭环

默认标签模型只启用digit 0～digit 9，对应通道12～21。六层卷积、27输出通道、定点移位和单bank ROM布局保持一致。当前活动手势权重仍为旧hand 1～9（通道3～11），使用肤色轮廓输入。用户指定的新一到十标准见 `GESTURE_STANDARD.md`：十类bank可复用通道2表示HAND 10，1～9继续用3～11，不增加输出通道或ROM容量；只有已训练并声明该标准的模型才启用十。新采集目录为camera_hand_northern10，训练默认输出候选，不覆盖活动bank。两模式数据及不同手型标准必须分开。模型是自定义轻量YOLO风格检测器，不能直接装入Ultralytics的PT/ONNX权重。

## 公共数据基线

MNIST训练集用于手写数字，MNIST测试集只用于评估。打印字体训练使用Arial、Calibri、Consolas、Courier、Tahoma及其粗体；评估保留Georgia、Times、Verdana、Trebuchet四种字体。字体文件本身不随工程分发，报告记录SHA256。位置、大小、旋转、对比度、梯度、轻微模糊和背景噪声随机化；加入字母和符号干扰。

初始数字基线保存在 `baselines/digits/`。早期候选在 `candidates/numeric_labels/`、`candidates/numeric_hardneg/`；活动模型为修正负样本生成器后补训的 `candidates/numguard/`。早期专门负样本评估无效，不作精度比较。独立报告保留所有成功、误分类和拒识，不能把合成字体结果写成真实摄像头精度，也不能把同一原始图像的增强版本随机分到训练与测试中。

训练需要CPU PyTorch、NumPy和Pillow，建议使用已建立的独立环境。`requirements.txt`记录训练依赖。选中候选后必须重建固件/工程，再运行验证，不能只替换HEX后沿用旧位流。

```powershell
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/model/train_numeric.py --steps 7000 --background-reduction mean
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/model/train_numeric.py --steps 4000 --negative-ratio 0.4 --printed-ratio 0.75 --background-penalty 2 --background-reduction peak --init fpga_pg2l100h/vision/model/candidates/numeric_labels/micro_yolo.npz --output fpga_pg2l100h/vision/model/candidates/numeric_hardneg
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/model/train_numeric.py --steps 2500 --negative-ratio 0.4 --printed-ratio 0.85 --background-penalty 1 --background-reduction peak --init fpga_pg2l100h/vision/model/candidates/numeric_hardneg/micro_yolo.npz --output fpga_pg2l100h/vision/model/candidates/numguard
python fpga_pg2l100h/vision/model/select_model.py --source fpga_pg2l100h/vision/model/candidates/numguard
python fpga_pg2l100h/vision/build.py --prepare-only --lcd-header J11
```

训练结束先保存浮点检查点；评估失败可用相同训练参数加 `--evaluate-only`重跑评估。检查点和导出后的INT8权重分开保存。训练时间和评估数据以各候选的JSON为准。

## 采集真实OV7670输入

板上`d`命令输出的不是电脑相机图像，而是本次NPU真正收到的64×64 Q7输入；CRC32检查串口传输完整性。采集会暂停等待下次推理的确认约一秒，属于维护/数据采集操作，不用于统计正常业务吞吐。LCD预览仍独立刷新。

采集工具需要Pillow、pyserial。串口号按实际设备替换：

```powershell
python fpga_pg2l100h/vision/tools/capture_numeric.py --port COM5 --session day1_lightA --card-id paper3a --split train --label 3 --box 20 10 44 52 --count 20
python fpga_pg2l100h/vision/tools/capture_numeric.py --port COM5 --session day2_lightB --card-id empty_test1 --split test --label none --count 20
```

`--box`是**当前64×64模型输入上的实际目标框**，不是固定推荐值；上面坐标仅说明命令格式，必须按实际数字测量后填写。没有框的正样本只用于分类评估，不会生成误导的检测标注。摄像头中央128×120经2倍采样，上下各补2行零得到64×64；正样本框应在非补零区内。

工具保存精确4096字节Q7输入、SHA256、CRC32、模式、会话/实体标签编号和重建灰度PNG。重建PNG是160×120的兼容预览图像，不是原始RGB照片。`train_dataset.py`对有元数据的采集样本校验并直接读取Q7原始输入，避免二次RGB预处理；其他原始照片仍按所选模式处理。`classes.json`及有框样本的YOLO格式标注可供训练使用；每个训练/验证类都需覆盖，至少有足够正样本、负样本。读取`DATASET`报错时修正标注和划分，不能移除校验来继续训练。

同一实体卡片、同一拍摄会话或相同输入内容不能跨train / val / test；工具会检查并拒绝泄漏。先确定划分，再采样。手写样本应按书写人划分，手动旋转/增强只能留在原划分中。改变镜头、安装距离、曝光或图像预处理后需要重新评估。

```powershell
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/tools/evaluate_numeric.py --split test
```

这份报告计算实际采集输入的离线精确整数预测，统计十类混淆、正样本拒识/误分类和负样本误接受。它仍不能代替板上业务事件级测试：没有触发事件的漏检、标签未移走的去重、工单误放行都必须按 `competition/ACCEPTANCE.md` 单独记录。

## 限制

字母O与数字0、字母I与数字1可能有相同外观，任意字母/复杂场景不存在已证明的可靠开放集拒识能力。主任务严格限定数字标签；非数字干扰结果必须单列。训练集/验证集用于调参后，应另留完全隔离的实体测试集。三个相似连续画面不是三个独立统计样本。
