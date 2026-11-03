# 提交检查清单（docs/SUBMISSION-CHECKLIST.md）

> 截止：**2026-11-04 18:00**。状态截至 2026-11-03 晚。
> 规则依据：赛题 1.4/1.8/2.4/2.5/2.7/3.4 + 指南第 10–11 页高阶任务（见 `results/COMPETITION-PLAN.md`；阶段性评审在 `feat/ai-accel` 分支）。

## A. 硬性提交物

| # | 要求 | 状态 | 证据/位置 | 负责人/截止 |
|---|---|---|---|---|
| A1 | 完整工程源码（紫光同创器件为交付主体） | ✅ 仓库 `main` | `fpga_pg2l100h/`（Pango 主体）+ `feat/ai-accel`（对比） | 已就绪 |
| A2 | CoreMark 跑分结果（Pango 实测） | 🔴 缺 | 待 `validation/coremark_hardware.json` + 原始串口 | 11-04 上午 |
| A3 | PPA 指标 | 🟠 部分 | WNS/LUT/FF/APM/DRM 已有；功耗未测 | 11-04 上午 |
| A4 | 设计报告（Word + PDF，含扩展部分） | 🔴 缺 | 素材：`README.md`、`docs/`、`results/DESIGN-REPORT.md`、Pango docs | 11-04 14:00 |
| A5 | 演示视频（约 3 分钟，1080P） | 🔴 缺 | 脚本：`fpga_pg2l100h/vision/competition/DEMO.md` | 11-04 14:00 |
| A6 | 演示当场可复现（Flash 自启动优先） | 🔴 **最高风险** | 见 B1 | 今晚 |

## B. 现场与证据

| # | 项 | 状态 | 备注 |
|---|---|---|---|
| B1 | **Pango Flash 自启动**（断电重启不接 JTAG） | 🔴 未做 | 二选一：PDS Flash 工程烧写；或固化 JTAG 下载流程 + 备机 + 兜底视频 |
| B2 | 摄像头→LCD 画面 | ✅ 目视确认 | 建议补照片/视频帧 |
| B3 | CPU 固件执行 / 按键 / 应用 UART | 🟠 未逐项确认 | BOARD_VALIDATION 标注"未单独确认" |
| B4 | NUMGUARD 验收（≥30 样本/类，含错料/空场，保留失败） | 🔲 待做 | 口径见 ACCEPTANCE.md |
| B5 | 手势实验（~35%） | ⚠️ 实验分支 | 不作主线宣称，可展示失败边界 |
| B6 | COCO80 部署 | ❌ 未部署 | 仅主机前向/资源核查，报告须明确 |
| B7 | 决赛 FPGA 基础编程考核（PDS 下载/看时序） | 🟠 待演练 | 每名队员独立操作一遍 |

## C. 仓库/文档合规

| # | 项 | 状态 |
|---|---|---|
| C1 | 根 README 为比赛总览（交付主体 + 结构 + 边界） | ✅ 2026-11-03 |
| C2 | 全量文件合规审计（`docs/COMPLIANCE-AUDIT.md`） | ✅ 2026-11-03 |
| C3 | 合规规范与证据分级（`COMPLIANCE.md`） | ✅ 2026-11-03 |
| C4 | 技术总览/复现/证据登记（`docs/TECHNICAL-OVERVIEW.md` 等） | ✅ 2026-11-03 |
| C5 | 禁用词/未标注数字自动检查（`tools/compliance_check.py`） | ⚠️ 已运行；默认 exit 1（209 条含历史/负面清单误报），以 `docs/COMPLIANCE-AUDIT.md` 为准 |
| C6 | 分支/tag 收口（main + feat/ai-accel + feat/isa-ac；tag 归档） | ✅ 2026-11-03 |

## D. 提交动作（建议时间盒）

1. **11-03 21:00 前**：Flash 方案定稿（B1）；报告/视频开工（A4/A5）。
2. **11-04 08:00–12:00**：Pango CoreMark 实测（A2）+ NUMGUARD 验收（B4）+ CPU/UART 确认（B3）。
3. **11-04 14:00 前**：报告 PDF + 视频定稿；`docs/EVIDENCE.md` 更新。
4. **11-04 15:30–16:30**：整体复验（位流 sha、报告中的每个数字对照 EVIDENCE 表）+ 提交演练。
5. **11-04 16:30 前提交**（留 1.5 小时 buffer）。
