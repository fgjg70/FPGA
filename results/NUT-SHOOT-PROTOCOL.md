# 坚果自拍数据集：拍摄协议（半天内可完成）

前置事实：原数据集 `nut_dataset_unlit_bright_augmented_7to1` 在本机不存在、原环境也联系不上
（取证见 `results/NUT-DATA-STATUS.md`），且两个上游源数据集同样丢失 ⇒ **重造无门，只能重拍**。

好消息：标注这一环已经解决了。`tools/nut/autolabel.py` 用 2M 教师自动打框，
已在**有真值**的瓶盖测试集上验证（见下），不需要人工画框。

---

## 1. 自动标注的可靠性（先看这个，再决定要不要拍）

自测：用瓶盖 2M 教师在瓶盖 `test/` 前 200 张上自动标注，与真实标注比对：

| 指标 | 结果 |
|---|---|
| 图像 | 200 |
| 目标 | 505（每图 1~4 个，分布均匀）|
| TP / FP / FN | 505 / 0 / 0 |
| **F1** | **1.000** |
| 平均匹配 IoU | **0.9727** |

四类目标数 129 / 123 / 127 / 126 —— 没有类偏。
叠框目视检查：框贴合瓶盖边缘，无漏检、无空框。

⇒ 这条链路（预处理 → 解码 → 坐标反变换）与训练时**逐位一致**，可以信任它的输出。

复现命令：

```bash
python tools/nut/autolabel.py \
  --images "<瓶盖数据集>/test" \
  --teacher tools/bottlecap/model_src/best_model.pt \
  --gt-csv "<瓶盖数据集>/test_annotations.csv" \
  --limit 200 --out-dir .tmp/nut/selftest
```

---

## 2. 拍摄规格（照做，别自由发挥）

| 项 | 要求 |
|---|---|
| 相机 | 手机主摄，≥ 640×480；**关闭水印、美颜、HDR、自动夜景** |
| 构图 | 4:3 横向，俯拍；后期统一缩到 **320×240** |
| 背景 | **黑色/深灰不反光**（黑布、黑色桌面）。原数据集就叫 `unlit`——背景要压暗 |
| 灯光 | **单个 LED 光源从侧上方 45° 打**（手机手电、LED 灯条均可），制造亮斑与阴影。不要开顶灯，不要用环形灯（会拍平板光） |
| 距离 | 镜头到物体 25~35 cm，坚果占画面高度 1/5 ~ 1/2 |
| 个体 | **每类至少 3 个不同实物**（大小/色泽不同），否则模型只认那一个 |
| 稳定 | 手机用支架或靠住桌面，别手持 —— 抖动会糊，教师也标不准 |

**灯的摆法是唯一的关键**：原数据集两个 profile 分别是"无打光"和"固定 LED"，
部署现场是数字料箱里的单点 LED。开顶灯拍出来的图，教师和学生的域都会错。

---

## 3. 拍多少、怎么分组

| 组 | 内容 | 张数 | 用途 |
|---|---|---|---|
| **A 单目标** | 四类各 30 张，**每张只放一个坚果** | 120 | 抠图取实例，用于合成扩增 |
| **B 混合** | 每张 1~4 个，四类随机组合 | 80 | 直接当训练样本 + 教会模型处理遮挡/多目标 |
| **C 留出** | 同上，但**全程不参与训练** | 100 | 唯一可信的测试集 |

合计 **300 张**。C 组必须单独存放，训练时不能碰 —— 这是唯一能让 F1 有意义的约束。

命名：`A_chickpea_001.jpg` … `C_001.jpg`。四个类名：
`chickpea / cashew / almond / walnut`（鹰嘴豆 / 腰果 / 杏仁 / 核桃）。

---

## 4. 交付与后续（我这边一条命令）

把三个文件夹放成：

```
D:/USER/Desktop/nut_photos/
├─ A_single/    120 张
├─ B_mixed/      80 张
└─ C_holdout/   100 张
```

然后我跑三步，**全自动**，不需要你再动手：

```bash
# 1) 教师自动标注（约 3 分钟 / 300 张）
python tools/nut/autolabel.py --images D:/USER/Desktop/nut_photos/A_single \
  --teacher "D:/USER/Desktop/04_models_training_code_and_reports(1)/models/nuts/best_model.pt" \
  --out-dir results/nut/labels/A --overlay-dir results/nut/labels/A/overlay

# 2) 同上标 B、C；然后 B+C 抽检 30 张叠框图，人工确认
# 3) 合成扩增 + 训 slim（沿用瓶盖那条已验证的链）
python tools/bottlecap/train_slim.py --dataset-dir results/nut/dataset \
  --teacher-checkpoint "…/models/nuts/best_model.pt" \
  --class-names chickpea,cashew,almond,walnut \
  --width-multiplier 0.4 --fpn-channels 64 --input-size 96 \
  --epochs 80 --batch-size 64 --distill-weight 0.6 --output-dir results/nut/slim
```

**预期 F1 0.92~0.98**（真实数据比原包少一个数量级，别期待 0.9976）。
容量、帧率、位精确仿真这三项与原包无关，仍会拿到和瓶盖同级的结果。

---

## 5. 如果拍不了

`bottle_cap_color_dataset_multi_augmented_7to1` 是**本机唯一数据完整**的任务
（3,500 train / 500 test / 8,750 + 1,250 标注 / 378 MB），slim 已到
F1 0.9976（int8）、62.5 fps @50 MHz、容量 6 项 PASS、ModelSim 71 op 位精确、零 RTL 改动。
赛题若允许换物料，这是唯一能立刻交出完整证据链的选择。
