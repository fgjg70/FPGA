# 坚果数据集：取证结论与三条出路

日期：2026-11-04 · 取证范围：C/D/E/F 全盘 · 结论：**不是弄丢了，是这份拷贝从一开始就没带。**

---

## 1. 结论先说

`04_models_training_code_and_reports(1)` 的 `README.md`（2026-08-19 生成）第 20 行明确列出交付包应含：

```text
training_assets_bundle_20260819/
├─ datasets/
│  ├─ 01_nut_dataset_unlit_bright_augmented_7to1.zip
│  ├─ 02_electronic_component_dataset_multi_augmented_7to1.zip
│  └─ 03_tool_material_daily_goods_dataset_multi_augmented_7to1.zip
├─ models/            ← 本机有
├─ training_code/     ← 本机有
├─ dataset_generation_scripts/  ← 本机有
├─ MANIFEST_SHA256.txt
└─ README.md          ← 本机有
```

本机这份只有 **4 项**：`README.md`、`dataset_generation_scripts/`、`models/`、`training_code/`。
**`datasets/` 整个目录不在，`MANIFEST_SHA256.txt` 也不在。**

⇒ 打包时数据是齐的（README 还写了"可用 MANIFEST 校验三个数据集压缩包是否完整"），
**是拷贝时漏了。原始 zip 极可能还在打包者手上。**

**要的东西就一个文件名：`01_nut_dataset_unlit_bright_augmented_7to1.zip`（15,960 train + 2,280 test，约 1.5 GB）。**

---

## 2. 已排除的可能（别重复搜）

| 搜索项 | 覆盖范围 | 结果 |
|---|---|---|
| 目录名 `*nut*` / `*nut_dataset*` | C/D/E/F，深度 6 | 只命中我自己建的 `D:\USER\Desktop\nut_datasets`（空的）+ `fpga_pg2l100h` 无 |
| 文件 `*nut*.zip/.rar/.7z/.tar*` | C:\Users\19716、D:\USER | 0 |
| 文件名 `01_nut*` / `training_assets*` / `MANIFEST_SHA256.txt` | C/D/E/F 深度 6 | 0 |
| 数据集指纹 `train_annotations.csv` | C/D/E/F 深度 6 | 只有瓶盖那份 |
| 含 `chickpea` 的 `classes.txt` | D、C:\Users\19716 | 只有 `models/nuts/classes.txt` 本身 |
| D 盘回收站 >1 MB 的 `$R*`（622 个） | 全量 | 无数据集，全是 pdf/rtd/zip（那个 2.3 MB zip 是学生活动证明） |
| 上游两个源数据集 `nut_dataset_multi_compact_night_7to1`、`nut_dataset_bright_photometric_augmented_7to1` | 全盘 | 都不在 ⇒ **连合成重造都做不了** |

`E:` 盘当前不可见，`config.json` 记的原路径是 `E:\桌面\codex\ruisa\nut_dataset_unlit_bright_augmented_7to1`。

---

## 3. 本机还有的坚果资产

| 资产 | 位置 | 状态 |
|---|---|---|
| 2M 教师权重 | `04_models.../models/nuts/best_model.pt` | ✅ 载入 `missing=0 / unexpected=0`，2,048,721 参数，epoch 9 |
| 2M ONNX | `.../models/nuts/enhanced_nut_detector_2m.onnx` | ✅ |
| 教师成绩 | `.../models/nuts/test_report.json` | ✅ 2,280 张 / 5,055 目标，P 0.9964 / R 0.9953 / **F1 0.9958** / mIoU 0.9369 |
| 3M 教师 | `config.json` 记 `teacher_checkpoint` 指向 `E:\...\enhanced_nut_detector_3m_distilled` | ❌ 不在本机 |
| 真实图像 | `models/nuts/test_preview.jpg`、`original_bright_eval/test_preview.jpg` | ⚠ 见下 |

### 预览图不能当数据用

两张预览图各 1600×2080 = 5 列 × 8 行 = **40 张 320×240 原生分辨率切片**（每格 320×260：图 240 + 标签条 20），两张共 **80 帧真实场景**。

**但检测框和置信度文字是画在像素上的**（红/绿框 + `P4 0.99` 字样）。
拿它当验证集 = 把答案印在卷子上；拿它当训练集 = 模型学会检测"画上去的框"。
⇒ 只能用来"看一眼真实域长什么样"（暗背景 + LED 光斑 + 1~4 个坚果），**不进入任何数据集**。

---

## 4. 三条出路

### A. 要回 zip（首选，成本 = 一条消息）

零技术风险，域完全一致。到手后照 `results/bottlecap/TEACHER-DISTILL.md` 的两条命令跑：

1. 教师适配到 96 输入（15,960 张，约 35 min，`tools/bottlecap/teacher_fit.py`）
2. 蒸馏训练 slim（80 epoch，约 3 h，`tools/bottlecap/train_slim.py`）

产出与瓶盖平级：容量 6 项 PASS、位精确仿真、F1 实测。

### B. 自拍 300 张（半天，全自动后半段）

不需要原包，但需要实物坚果（超市 20 元）。**教师权重在，可以全自动标注**，`dataset_generation_scripts/` 的合成扩增逻辑也在（1,057 行可参考）。

拍摄规格（必须按这个来，否则和教师的域对不上）：

- 分辨率 ≥ 640×480，拍完统一缩到 320×240（相机 App 别加水印）
- 暗背景（黑布/桌面），**单个 LED 光源侧上方打光**，制造亮斑——这是原数据集 `unlit + fixed_led` 两个 profile 的由来
- 四类分开：鹰嘴豆 / 腰果 / 杏仁 / 核桃，每类 ≥ 3 个不同个体
- 单目标摆拍 4 类 × 30 张 = 120 张（用于抠图合成）
- 混合场景 80 张（每张 1~4 个，随机组合）
- 另留 100 张完全不参与训练，只做测试

流程：教师自动标注 → 人工抽检 30 张 → 实例抠图合成扩增到 ~5,000 张 → 训 slim → 在 100 张留出集上报 F1。
**预期 F1 0.92~0.98**（真实数据量比原包少一个数量级，别期待 0.9976）。

### C. 换瓶盖（本机唯一数据完整的任务）

`bottle_cap_color_dataset_multi_augmented_7to1`：3,500 train / 500 test / 8,750 + 1,250 标注 / 378 MB，**在**。
slim 已到 **F1 0.9976（int8）/ 62.5 fps @50 MHz / 容量 6 项 PASS / ModelSim 71 op 位精确**，零 RTL 改动。

若赛题允许换物料，这是唯一能立刻交出完整证据链的选择。

---

## 5. 建议顺序

1. **今天先发一条消息要 `01_nut_dataset_unlit_bright_augmented_7to1.zip`** —— 成本最低，可能只是拷贝漏了
2. 同时按 B 的规格拍 300 张（半天）作为不依赖他人的兜底
3. 若两样都赶不上，C 是唯一能交的方案
