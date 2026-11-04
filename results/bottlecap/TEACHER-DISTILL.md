# 坚果蒸馏：开源数据集盘点 + 教师适配打通

> 生成：2026-11-04　|　分支 `feat/ai-accel`　|　提交 `17df366`（train_slim 通用化）、`1637353`（teacher_fit）

## 0. 一句话

**开源数据集没有能替代的**（缺类、缺分布、全要账号）；但阻塞蒸馏的真问题不是数据，
是「224 训的教师喂不进 96 的学生」—— 这个已经解决，8 分钟把教师 F1 从 **0.000 救到 0.9992**。

## 1. 开源数据集盘点（2026-11-04 实测）

| 数据集 | 规模 | 类别 | 许可 | 获取 | 判定 |
|---|---|---|---|---|---|
| Mix Dry Fruit & Nut Detection | 3.8k 图 | Date / Almond / Cashew_Nuts / Peanuts / Raisin | CC BY 4.0 | Roboflow（需 API key） | 缺 chickpea、walnut |
| Mix Dry Fruit & Nut Detection (v1) | 3,758 图 | 同上 | CC BY 4.0 | Roboflow（需 key） | 同上 |
| Nut Types | 256 图 | Walnut / Almond / nuts / Peanut | MIT | Roboflow（需 key） | 缺 chickpea、cashew；量太小 |
| Nut Detection | 122 图 | 单类 | CC BY 4.0 | Roboflow（需 key） | 不可用 |
| Indian Pulses Dataset | 633 图 / 32,922 框 | 8 类含 White/Black Chickpeas | CC BY-SA 4.0 | Kaggle（需 key） | 只有鹰嘴豆 |
| Chickpea-Anomaly (GitHub) | 声称 20K+ | 7 类**质量等级**（非坚果种类） | Apache-2.0 | 仓库内无数据 | 不可用 |

**本机网络实测**（走代理）：

| 站点 | 结果 |
|---|---|
| `raw.githubusercontent.com` | **200** ✅ |
| `zenodo.org/api` | **403** "unusual traffic from your network"（出口 IP 被封） |
| `huggingface.co` | 连不上（000） |
| `universe.roboflow.com` | 403 |
| `kaggle.com` | 需登录 |
| 本机凭证 | 无 `~/.kaggle/kaggle.json`、无 `~/.roboflow/`、无相关环境变量 |

### 1.1 为什么"换开源数据"这条路本身不成立

1. **没有四类齐全的**。业务要 chickpea + cashew + almond + walnut；最接近的 Mix Dry Fruit
   只有 almond + cashew 两个对得上，还要凑 2~3 个数据集，标注规范/拍摄条件全不同。
2. **分布差得远**。业务是 320×240 俯拍多目标（每图 1~4 个），开源多是网图/摆拍单目标。
3. **蒸馏的软标签必须来自同分布数据**。教师是在业务数据上训的，换数据 = 换任务，
   学生的软标签监督直接失效。这一条与"数据量够不够"无关。

⇒ **开源数据只能做管线演练，不能做交付。** 真正的数据仍是
`nut_dataset_unlit_bright_augmented_7to1`（15,960 / 2,280，320×240）。

## 2. 真正的阻塞：教师喂不进学生（已解决）

### 2.1 问题

`train_slim.py` 的蒸馏把**同一张图**同时喂给 teacher 和 student：
`teacher(images)` 里 `images` 是 student 的 96×96。而教师是 224 训的（56×56 网格）。
实测教师 2M 在 96 下 **F1 = 0.0000**（`results/bottlecap/slim/teacher_probe.json`）。

瓶盖最终把 `distill_weight` 设成 **0.0** 收场 —— 也就是说**蒸馏代码路径在瓶盖训练里从未被执行过**。

### 2.2 做法（`tools/bottlecap/teacher_fit.py`）

冻结拓扑，只在新输入尺寸上微调：lr 2e-4 / AdamW / batch 32 / 14 epoch。

```bash
python tools/bottlecap/teacher_fit.py \
  --checkpoint tools/bottlecap/model_src/best_model.pt \
  --input-size 96 --epochs 14 --batch-size 32 \
  --output-dir results/teacher96
```

### 2.3 实测（瓶盖教师 2M，96×96，3,500 train / 500 test，5070 Ti）

| | F1 | mIoU | count | exact |
|---|---|---|---|---|
| before（直接迁移） | **0.0000** | 0.0000 | 0.396 | 0.000 |
| after（14 epoch 微调） | **0.9992** | 0.9516 | 1.000 | 0.998 |

- best epoch 12；14 × 32 s = **8 分钟**
- **教师不是不可救，是没人救过。**
- 且 `teacher(96) = 0.9992 > student(96) 纯监督 = 0.9984` ⇒ 蒸馏第一次有了信息增量（+0.0008）

### 2.4 副作用结论

2M 模型在 **96 输入**下能到 F1 0.9992 —— 说明 96 分辨率**不是**精度瓶颈。
之前"96 太小"的担心不成立；瓶颈只在 NPU 的 A 缓冲容量。

## 3. 蒸馏跑批（进行中）

用适配后的 96-teacher 跑完整 80 epoch，与纯监督 0.9984 对照：

```bash
python tools/bottlecap/train_slim.py --teacher-checkpoint /tmp/tfit96/best_model.pt \
  --distill-weight 0.6 --width-multiplier 0.4 --fpn-channels 64 --input-size 96 \
  --epochs 80 --batch-size 64 --patience 15 --output-dir results/bottlecap/slim-d96
```

判据：`test_f1 > 0.9984`（纯监督基线）才算蒸馏有正收益。

## 4. 对坚果的动作序列（数据到位后照抄）

```bash
# 1. 教师适配到 96（约 35 分钟，坚果 15,960 张）
python tools/bottlecap/teacher_fit.py \
  --checkpoint "D:/USER/Desktop/04_models_training_code_and_reports(1)/models/nuts/best_model.pt" \
  --dataset-dir D:/USER/Desktop/nut_dataset_unlit_bright_augmented_7to1 \
  --input-size 96 --epochs 14 --output-dir results/nut/teacher96

# 2. 蒸馏训练（约 3 小时）
python tools/bottlecap/train_slim.py \
  --dataset-dir D:/USER/Desktop/nut_dataset_unlit_bright_augmented_7to1 \
  --teacher-checkpoint results/nut/teacher96/best_model.pt \
  --class-names chickpea,cashew,almond,walnut \
  --distill-weight 0.6 --width-multiplier 0.4 --fpn-channels 64 --input-size 96 \
  --epochs 80 --batch-size 64 --patience 15 --output-dir results/nut/slim
```

## 5. 坑

| 症状 | 原因 | 处理 |
|---|---|---|
| `size of tensor a (56) must match tensor b (24)` | Windows `num_workers>0` 会 spawn 新解释器，`preprocess_multi` / `make_multi_targets` 的 monkeypatch 丢失 | `--num-workers 0`（`teacher_fit.py` 默认已是 0） |
| `python` 报无 torch | 指向 WorkBuddy 内置 3.13.12 | 用 `C:/Users/19716/AppData/Local/Programs/Python/Python313/python.exe` |

---

## 6. 蒸馏实测结果（2026-11-04 15:28 跑完）

命令：`train_slim.py --teacher-checkpoint /tmp/tfit96/best_model.pt --distill-weight 0.6
--width-multiplier 0.4 --fpn-channels 64 --input-size 96 --epochs 80 --batch-size 64 --patience 15`

- **63 epoch 早停**（patience 15），1,975.8 s = 32.9 min，best epoch **48**
- 产出 `results/bottlecap/slim-d96/`（best_model.pt / FIT-CHECK.json / SLIM-REPORT.md / test_report.json）

| | 蒸馏 slim-d96 | 纯监督 slim（基线） | 差 |
|---|---|---|---|
| F1 | **0.9992** | 0.9984 | **+0.0008** |
| Precision | 0.9992 | 0.9984 | +0.0008 |
| Recall | 0.9992 | 0.9984 | +0.0008 |
| 平均匹配 IoU | 0.9475 | **0.9495** | **−0.0020** |
| 整图全对率 | **0.9980** | 0.9960 | +0.0020 |
| 计数正确率 | 1.0000 | 1.0000 | 0 |

### 怎么读这张表（别过度解读）

测试集 500 张 / 1,250 个目标。**+0.0008 的 F1 精确等于 1 个目标**，exact +0.0020 也精确等于 1 张图。
⇒ 这是**噪声量级的差异，不能声称"蒸馏提升了精度"**。

真正的结论只有两条：

1. **蒸馏路径第一次真正跑通并证明了"不伤精度"**——此前瓶盖把 `distill_weight` 设成 0，
   这条代码路径从未被执行过；现在教师 96 适配后同尺寸蒸馏跑满 63 epoch，精度持平。
2. **mIoU 略降 0.0020**：软标签带来的是分类/计数上的收益，框的紧致度反而输给纯标签监督。
   若下游更看重框贴合（例如按面积估大小），纯监督仍更优。

### 容量核算（同一份 slim 结构，与是否蒸馏无关）

W 130,448 B / Q 22,608 B / A 峰值 73,728 B（`backbone_stage2_0_block_0_0`）/ B 27,648 B /
71 op（39 conv + 18 dwconv + 3 upsample + 11 add）/ IC-OC 峰值 256 —— **全部 PASS**（`FIT-CHECK all_pass = True`）。
