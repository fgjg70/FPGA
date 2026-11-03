> **范围/口径声明（交付主体）**：本文属于**紫光同创 PG2L100H** 交付主体线。文中"实测"指上板实测并应附证据路径；"未达成/未部署"项见根 [`COMPLIANCE.md`](COMPLIANCE.md) §4 边界清单。注意：**Pango 侧 Flash 当前尚未写入**（JTAG RAM 下载），详见 [`fpga_pg2l100h/vision/BOARD_VALIDATION.md`](fpga_pg2l100h/vision/BOARD_VALIDATION.md)。

# 手势数字1～10：参考约定与训练状态

当前手型以用户上传的北方一到十参考图为准，完整定义见 `GESTURE_STANDARD.md`，代码中的标准编号为user_northern_reference_1_10_v1。特别是1为食指、7为三指尖相捏、9为食指弯钩、10为双手食指交叉，不能使用握拳作为十。现有缓存的十是握拳，部分一为竖拇指，不能直接用于新标准。采集、训练导出、固件及LCD已支持十类，启用范围由实际模型决定；当前活动权重仍为下述旧九类实验模型，新标准十类权重尚未训练，未取得符合标准的真实数据。

更新日期：2026-11-02。已加入九类手势的真实训练权重、板上肤色轮廓预处理、双模型ROM、RV32解码、红框和HAND 1～HAND 9显示。CPU、NPU和采集保持50 MHz，活动RTL仍为Verilog-2005。上电使用原数字标签模型，数字权重未重新训练或替换。

当前手势模型能力较弱：148个开发验证正样本中，52个通过质量门限且分类正确，66个通过门限但分类错误，30个拒识。正确接受占全部正样本35.14%，不能写成稳定识别或真实OV7670精度。LCD顶部显示HANDTEST EXP。三次连续投票不能修正连续的系统性误分类。本功能适合继续采集与改进，尚不能用于可靠数量核验。

## 模式与工位流程

- 串口115200、8N1：g/G进入手势模式，l/L回到数字标签模式。设备分别应答MODE HAND 1-9、MODE LABEL 0-9。
- SW4长按1秒切换模式；短按松开调整期望数字。手势模式循环1～9，标签模式循环0～9。其余按键和原数字业务流程相同。
- 画面一次呈现一只手的一个数字手势，使用与训练样本一致的中文数字手势定义；6～9不是简单按伸出手指数分类。先移走手、确认空场，再呈现；要换手势先再次移走。
- 切换取消旧推理、旧框和连续确认，防止把数字结果解释成手势。期望值独立设置，不从识别结果自动生成；手势模式原期望为0时调整为1。
- LCD保留实时RGB图像和红框，底部英文HAND 1～HAND 9；顶部显示实验标记、期望数量、当前识别和核验状态。
- 两模式共用OK/BAD和事件序号，EVENT最后一列mode为0标签、1手势。分开实验时保存原日志并用q清零计数。

相机为照片确认的18针DVP OV7670，接J7；AN430接J11，没有新增外设。当前约束和采集器已按实物重映射，旧22针AL422接线表停用，详见 `../CAMERA_DEBUG.md`。

## 模型、预处理和存储

模型bank0为原digit 0～9（全局类别12～21），bank1为hand 1～9（全局类别3～11）。每组均为64×64单通道、六层INT8卷积、4×4×27输出，自定义YOLO风格单目标检测器，不兼容直接载入标准YOLO的PT/ONNX权重。输出保留其他类别通道但不参与当前类别选择。

标签仍使用RGB565反相灰度。手势将RGB565高位复制展开到RGB888，按以下条件取肤色轮廓：

```text
R > 50 && G > 25 && B > 10 && R > G + 5 && R > B + 15
满足条件Q7=127，否则Q7=0；上下两行补零。
```

中央128×120裁剪、隔行隔列采样和64×64输入尺寸不变。手势训练、精确整数评估及RTL采用同一RGB565量化和阈值。该规则不是通用肤色分割器；曝光、白平衡、深浅肤色、衣袖和肤色相似的背景都可能使轮廓失真。建议首先使用不含肤色的单色背景、稳定照明和单手；这些条件也必须在独立测试中记录。

每组有效权重21672字节、偏置556字节。双组固定ROM共64 KiB权重、2 KiB偏置、12个移位字节；激活RAM和MAC复用。仿真每次推理为1769238个50 MHz周期，纯计算约35.38 ms；不代表实测画面帧率或业务延迟。DVP18版本的原生PDS资源、时序和JTAG记录见 `../BOARD_VALIDATION.md`；板上手势功能和精度仍待实际画面、串口和独立相机数据验证。

## 数据来源与实际训练

原图来自开源仓库tz28/Chinese-number-gestures-recognition，固定提交2a9136b223064450ffde79d3f2e01c0de41baf09，缓存为checkpoints/public_cache/gestures.zip。原仓库许可保存在gesture/LICENSE.txt。源压缩包SHA256为：

```text
2699f16057895f01e8e1a141917cbf2a388418e4236f972b34242c0d0c2efeb9
```

只使用1～9，共183张原照片，146张训练、37张验证；同一原图的所有变体只属于一个划分。它不是按不同人的严格划分，37张照片也不能当作148个独立受试者。训练生成9344个手势正样本（每张64个变体），加入1504个数字/背景负样本；验证为148个手势变体和378个负样本。来源和逐图划分保存在gesture/dataset_provenance.json。框是整张贴入照片区域的弱标注，不是手掌/手指的精确人工边界。

先训练灰度九类模型6000步，质量门限后仅25/148正确、98误分类、25拒识，保留于candidates/gesture_gray。随后切换肤色轮廓，从头训练9000步，batch96、seed2026、class_weight1.2、background_penalty1.0，CPU训练及评估约244.15秒，活动结果在gesture/model.json。数字标签原模型不变。

在项目根目录可复现数据准备、手势专用训练和软件预览。数据准备依赖已有public_cache原图及public_dataset数字/背景负样本；不分发大规模原始照片。

```powershell
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/model/prepare_gesture_dataset.py --per-photo 64
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/model/train_public.py --dataset fpga_pg2l100h/vision/model/checkpoints/gesture_dataset --output fpga_pg2l100h/vision/model/gesture --gesture-only --from-scratch --steps 9000 --batch-size 96 --class-weight 1.2 --background-penalty 1
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/tools/preview_gestures.py
```

预览固定选每类第一个验证样本，保留错误与拒识，未按成功结果筛选。validation/gesture_examples.png是软件参考图，不是板上照片。

## 实际精确INT8开发验证

选择全图目标分数最高的单元，在九类中比较；目标分数>=72且第一/二类差值>=24才接受，分数<40才记为空场。Q7线性分数不是概率。以下数字不包含三次投票，不是业务事件级验收。

| 统计 | 数量 |
|---|---:|
| 正样本总数 | 148 |
| 不施加类别差值门限的正确类别 | 61 |
| 通过质量门限且类别正确 | 52 |
| 通过质量门限但类别错误 | 66 |
| 正样本拒识 | 30 |
| 负样本总数 / 通过质量门限 | 378 / 0 |

378个负样本只覆盖准备的数字/背景，不能据此声称任意姿势、脸、胳膊或复杂场景都能正确拒绝。

| 手势 | 验证数 | 未施加类别差值门限的正确类别数 |
|---|---:|---:|
| 1 | 16 | 9 |
| 2 | 16 | 5 |
| 3 | 8 | 3 |
| 4 | 24 | 3 |
| 5 | 20 | 11 |
| 6 | 16 | 8 |
| 7 | 8 | 5 |
| 8 | 20 | 11 |
| 9 | 20 | 6 |

## 用实际OV7670补数据

手势与标签数据放在不同目录。下例COM5、人物编号、框仅演示格式，按实际串口、人物和64×64输入中的手部边界填写。--card-id在手势模式下作为人物ID，同一人、同一会话或相同输入不能跨训练/验证/测试；相邻视频帧也不能当独立样本。

```powershell
python fpga_pg2l100h/vision/tools/capture_numeric.py --port COM5 --mode hand --session person01_day1 --card-id person01 --split train --label 3 --box 12 8 50 56 --count 20
python fpga_pg2l100h/vision/tools/capture_numeric.py --port COM5 --mode hand --session person09_day2 --card-id person09 --split test --label 3 --box 12 8 50 56 --count 20
python fpga_pg2l100h/vision/tools/capture_numeric.py --port COM5 --mode hand --session empty_day2 --card-id empty02 --split test --label none --count 20
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/tools/evaluate_numeric.py --mode hand --model fpga_pg2l100h/vision/model/candidates/northern10 --split test --output fpga_pg2l100h/vision/validation/real_hand_report.json
```

工具先等待模式切换应答，再采集带CRC32的实际4096字节模型输入。保存的PNG是轮廓重建图，不是原始RGB；train_dataset检测元数据后直接使用Q7原始输入，避免把灰度重建图再次送入肤色阈值而变为空白。每个训练/验证类别都需要实际样本与人工框，并加入空场、非数字手势、脸/胳膊、遮挡和不同肤色背景负样本。

```powershell
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/model/train_dataset.py --mode hand --dataset fpga_pg2l100h/vision/model/checkpoints/camera_hand_northern10 --validate-only
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/model/train_dataset.py --mode hand --dataset fpga_pg2l100h/vision/model/checkpoints/camera_hand_northern10 --steps 6000
```

十类采集默认保存到camera_hand_northern10，需采齐每类训练、验证、测试及负样本；十类训练默认导出到candidates/northern10，不覆盖活动权重。完成独立评估后再选择新bank、重建验证及下载。评估工具会核对模型和数据类别/手型标准，不能用旧九类模型填写新十类成绩。上线前仍需不同人的实拍混淆矩阵、误接受/拒识统计、切换和业务事件测试。
