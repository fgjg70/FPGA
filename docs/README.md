# 文档索引（docs/README.md）

> 仓库根 README 是比赛总览；本文件是"文档在哪"的地图。根目录仍保留若干开发/交接文档（被大量历史文档以相对路径引用，暂不移动）。

## 交付与验收（PG2L100H）
- `fpga_pg2l100h/README.md` — Pango 工程总览
- `fpga_pg2l100h/vision/BOARD_VALIDATION.md` — 实际下载/上板验证记录（芯片 ID/DONE/配置错误位/PLL/摄像头）
- `fpga_pg2l100h/vision/CLOCK_SPLIT.md` — 125/50 MHz 双时钟域与计时口径
- `fpga_pg2l100h/vision/MODES.md` — 三模式操作说明
- `fpga_pg2l100h/vision/competition/ACCEPTANCE.md` — 实物验收清单（F01–F15）与统计口径
- `fpga_pg2l100h/vision/competition/DEMO.md` — 三分钟演示脚本与答辩准备
- `fpga_pg2l100h/vision/CAMERA_DEBUG.md` — 摄像头/引脚调试记录
- `fpga_pg2l100h/vision/model/COCO80_FEASIBILITY.md` — COCO80 可行性边界

## 比赛/评审
- `results/COMPETITION-PLAN.md` — 赛题拆解与优先级
- `results/STAGE-REVIEW-1103.md` — 提交前 24h 阶段性评审
- `results/DESIGN-REPORT.md` — 设计报告素材
- `results/CHANGELOG.md` — 逐轮优化与决策记录
- `results/gap-analysis.md` — 赛题逐项对照
- `results/coremark.csv` — 各档 CoreMark/资源/时序记录

## Artix-7 对比线（历史交付）
- `README-ARTIX.md` — Artix-7 交付档完整说明（成绩/架构/测试/文件一览）
- `results/NEXT-BURN.md` — 150 MHz 交付档烧写说明（含 R54 配方修复）
- `results/FREQ-VERDICT.md` — 主频核实
- `sim/`、`sw/`、`fpga/`、根目录 `*.sv` — RTL/仿真/软件/Vivado 工程
- `skills/fpga-riscv-a100t/PITFALLS.md` — 开发踩坑记录

## 开发/交接
- `CODE-MAP.md`、`CODE-REVIEW-PLAN.md`、`HANDOFF*.md` — 代码地图/审查计划/交接文档（根目录）
- `tools/fpga_workflow.py` — 构建/仿真/上板统一入口
- `archive/README.md` — 归档内容说明
