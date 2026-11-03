# 复现指南（docs/REPRODUCE.md）

> 两条线的完整复现步骤。所有命令均假设仓库根目录（Windows PowerShell）。

## 0. 环境

| 线 | 工具 | 版本 |
|---|---|---|
| 交付主体（PG2L100H） | 紫光同创 PDS | 2022.2-SP6.1 |
| Artix-7 对比线 | Vivado | 2018.3（`D:\software\Learn\Xilinx\Vivado8.3`） |
| 仿真 | ModelSim | win64（`LM_LICENSE_FILE` 指向 license） |
| RISC-V 工具链 | xpack riscv-none-elf-gcc | 15.2.0-1 |
| Python | 3.13 | 仓库脚本 |

## 1. 交付主体（PG2L100H）

```powershell
# 构建/下载（详见工程 README）
python fpga_pg2l100h/vision/build.py --help
# 板级下载与状态检查按 BOARD_VALIDATION.md 的 JTAG 流程
```

验收/演示：`fpga_pg2l100h/vision/competition/ACCEPTANCE.md`（F01–F15）、`DEMO.md`（3 分钟脚本）。
**注意**：Flash 未写入；断电后需重新下载（见 COMPLIANCE.md §4）。

## 2. Artix-7 对比线（[跨厂商对比]）

```powershell
# 仿真回归（PASS 12；feat/ai-accel 分支含 NN 回归共 16）
python tools/fpga_workflow.py verify --force
# 交付档综合/实现（150 MHz 合法配方）
python tools/fpga_workflow.py synth --tag legal150 --no-lc --fanout-limit 128 `
       --pblock-range off --contain-routing --place-directive AltSpreadLogic_high
# 上板跑分镜像（CoreMark；迭代数由脚本按 >=10s 计算并写清单）
python tools/mk_cm_hw.py 4600
python tools/fpga_workflow.py hw --prog cm_hw
```

AI 档（自研 NPU，对比材料）：见 `feat/ai-accel` 分支的 `results/ai-accel/DELIVERY.md` / `MODEL-FREEZE.md`。

## 3. 合规检查（任何对外文档改动后必跑）

```powershell
python tools/compliance_check.py          # 扫描禁用词/缺级别数字
python tools/compliance_check.py --json  # 机器可读
```

## 4. 常见问题

- **Pango 白屏**：先读 `BOARD_VALIDATION.md`：CPU PLL 在 PFD=50 MHz 时须 `BANDWIDTH=HIGH`，复位等两 PLL 锁定；确认配置状态位（DONE/配置错误位）。
- **PDS 工程引用第三方目录**：`fpga_pg2l100h/camera_lcd_debug/{build.py,project_file.py}` 以相对路径引用根目录 `fpga_mes50hp/`、`ebf_pg2l100h_demo/`，**不要移动**（见 `THIRD_PARTY.md`）。
- **Artix 交付档烧写**：`results/NEXT-BURN.md`（含 R54 配方修复与 4600 迭代口径）。
