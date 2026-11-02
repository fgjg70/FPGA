# 本项目手势约定：按用户参考图的一到十

标准编号：`user_northern_reference_1_10_v1`。以用户上传的图片为准，训练、人工标注、固件解码和LCD标签使用同一套定义。

| 数字 | 手型 | LCD名称 |
|---|---|---|
| 1 | 食指伸直，其余收起；不采用竖拇指 | HAND 1 |
| 2 | 食指、中指伸直，呈V形 | HAND 2 |
| 3 | 食指、中指、无名指伸直，拇指和小指收起 | HAND 3 |
| 4 | 除拇指外四指伸直 | HAND 4 |
| 5 | 五指展开 | HAND 5 |
| 6 | 拇指、小指伸出，其余收起 | HAND 6 |
| 7 | 拇指、食指、中指的指尖相捏 | HAND 7 |
| 8 | 拇指、食指伸出，呈八字形 | HAND 8 |
| 9 | 食指弯曲成钩，其余收起；不用另外三指展开的OK手势 | HAND 9 |
| 10 | 双手食指交叉成十字，其余收起；不用握拳 | HAND 10 |

十的标注框必须包住两只手构成的同一手势。背景、脸、胳膊、竖拇指、握拳和不符合本表的手型应作为负样本或待人工复核，不能直接套用旧数据的数字标签。

## 当前模型与数据审查

已检查缓存的tz28原图：十的22组原图全部为握拳，部分标为1的图像是竖拇指。样本预览保存在 `../validation/gesture_north_audit/source_hands_1_10.png`，全部十类原图预览为同目录all_public_ten_groups.png，来源及限制见审查报告。这些样本不能直接当作本标准的十和一。已有模型为旧1～9实验版本，尚无符合本标准、独立划分的完整十类真实训练数据，当前不能宣称已完成一到十识别。

代码已支持十类的采集、训练、INT8导出、类别映射、计数、UART和十进制LCD显示。模型bank1复用原有未启用的类别通道2表示HAND 10，1～9仍为通道3～11；bank0的类别表独立，数字标签0～9仍为通道12～21。网络继续为27输出通道，CPU/NPU保持50 MHz。只有模型文件声明本标准、通道名正确且权重哈希通过，构建器才生成十类固件；旧九类权重不会被当成十类模型。

## 用当前摄像头采集

连接开发板标有USB UART的J10接口，并接通J9的1-2、3-4。COM12/COM13属于当前FTDI下载器；用新出现的CH340串口，115200、8N1。采集工具兼容旧九类固件的原始模型输入，因此采集十字手势不需要先有十类识别模型。

以下COM5及框坐标为格式示例；实际手型需放在中央识别区域内，框要覆盖该手势。每个人、会话和相同输入只能属于一个划分，训练、验证、独立测试应使用不同人物与会话。按一到十逐类采集，并另采负样本。

```powershell
python fpga_pg2l100h/vision/tools/capture_numeric.py --port COM5 --mode hand --session person01_day1 --card-id person01 --split train --label 10 --box 10 8 54 56 --count 20
python fpga_pg2l100h/vision/tools/capture_numeric.py --port COM5 --mode hand --session person02_day2 --card-id person02 --split val --label 10 --box 10 8 54 56 --count 20
python fpga_pg2l100h/vision/tools/capture_numeric.py --port COM5 --mode hand --session person03_day3 --card-id person03 --split test --label 10 --box 10 8 54 56 --count 20
```

默认目录为 `checkpoints/camera_hand_northern10/`，包含十类classes.json、gesture_standard.json、人工标签和4096字节Q7原始输入。保存的PNG是轮廓重建图，训练优先读原始Q7，避免二次肤色处理。旧九类采集目录不能混入此目录。

```powershell
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/model/train_dataset.py --mode hand --dataset fpga_pg2l100h/vision/model/checkpoints/camera_hand_northern10 --validate-only
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/model/train_dataset.py --mode hand --dataset fpga_pg2l100h/vision/model/checkpoints/camera_hand_northern10 --steps 6000
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/tools/evaluate_numeric.py --mode hand --model fpga_pg2l100h/vision/model/candidates/northern10 --split test --output fpga_pg2l100h/vision/validation/northern10_real_report.json
```

十类训练默认导出到 `candidates/northern10/`，不自动替换活动权重。独立数据评估通过、完成整机回归后再选入活动bank并重新构建下载。启用十类模型后，UART应答MODE HAND 1-10，短按SW4循环1～10；手势模式串口0选择期望值10，标签模式0仍选择数字0。LCD以10显示，不显示十六进制A；评估工具用独立的无目标项，不再用数字10代表拒识。
