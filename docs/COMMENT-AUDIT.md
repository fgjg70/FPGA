# 源文件注释合规性审计（docs/COMMENT-AUDIT.md）

> 覆盖仓库全部源码/脚本文件（RTL、C、Python、Tcl、约束、批处理等）；按 COMPLIANCE.md 的口径逐文件审查注释陈述。
> 审查方法：注释抽取（`//`、`/* */`、`#`、`REM`、`--`、`<!-- -->`、docstring）→ 与当前事实（交付档 150 MHz、验证矩阵 12 项、AI 分支 16 项、Pango 125/50 MHz、Pango Flash 未写入）比对 → 修复冲突陈述。
> 历史/第三方副本（`fpga_mes50hp/`、`fpga_pds_1_0_9/`、`archive/`、`ebf_*`）保留当时注释原貌，已在 THIRD_PARTY.md / archive/README.md 声明不参与当前交付口径。

## 1. 统计

| 类别 | 源文件数 |
|---|---:|
| 历史/第三方副本 | 208 |
| 交付主体(Pango) | 89 |
| Artix-7 参照线 | 51 |
| 工具脚本 | 28 |
| 根目录 RTL/其他 | 22 |

**总计：398 个源文件**；注释行合计 16,248 条。

## 2. 已修复的注释不一致（逐项）

| # | 文件 | 问题 | 修复 |
|---:|---|---|---|
| 1 | `README.md` | 仿真回归：`python tools/fpga_workflow.py verify`（PASS 16）。 | 仿真回归：`python tools/fpga_workflow.py verify`（**PASS 12**；`feat/ai-accel |
| 2 | `docs/REPRODUCE.md` | # 仿真回归（PASS 16） | # 仿真回归（PASS 12；feat/ai-accel 分支含 NN 回归共 16） |
| 3 | `docs/TECHNICAL-OVERVIEW.md` | ModelSim 回归 PASS 16；112-op 双模 E2E 位精确 PASS | ModelSim 回归 PASS 12（`feat/ai-accel` 分支含 NN 4 项共 16）；112-op 双模 E2E 位精确  |
| 4 | `fpga/top_a100t.sv` | //   2026-10-11 的档位序列(全部实测): 70 -> 75 -> 95.45 -> 105(已上板)
//     -> 1 | //   2026-10-11 的档位序列(历史, 全部实测): 70 -> 75 -> 95.45 -> 105(已上板)
//      |
| 5 | `fpga/top_a100t.sv` | // 名字刻意**不含频率**: 本轮在时钟阶梯上迭代(75/95.45/105/128.125/131.25 MHz...), | // 名字刻意**不含频率**: 历史在时钟阶梯上迭代(75/95.45/105/128.125/131.25 MHz...), |
| 6 | `fpga/top_a100t.sv` | // top_a100t.sv — 正点原子 达芬奇Pro (XC7A100T-FGG484-2) 上板顶层 | // top_a100t.sv — 正点原子 达芬奇Pro (XC7A100T-FGG484-2) 上板顶层
// [跨厂商对比] 本文件属 |
| 7 | `core.sv` | // core.sv — RV32I **五级**流水线处理器 (IF / ID / EX / MEM / WB) | // core.sv — RV32I **五级**流水线处理器 (IF / ID / EX / MEM / WB)
// [跨厂商对比] 本 |
| 8 | `tools/build_sw.py` | # 【W-07】一条命令构建**全部 11 项回归**需要的镜像 (全新克隆可复现 PASS 11) | # 【W-07】一条命令构建**全部 12 项回归**需要的镜像 (全新克隆可复现 PASS 12) |
| 9 | `tools/build_sw.py` | # amo_diag2 不在 11 项里, 但它是 amo_diag 的备用诊断支, 一起建齐免得下次找不到。 | # amo_diag2 不在 12 项里, 但它是 amo_diag 的备用诊断支, 一起建齐免得下次找不到。 |
| 10 | `tools/fpga_workflow.py` | # ⚠ 加入这一项后全量回归是 **PASS 12**(文档里的"PASS 11"需要同步更新)。 | # ⚠ 加入这一项后全量回归是 **PASS 12**（文档已同步；历史版本曾为 PASS 11）。 |
| 11 | `tools/fpga_workflow.py` | # 修好后实测: IMEM_REG_READ 已打通并**转为默认**(回归 PASS 11, ticks 逐位一致); | # 修好后实测: IMEM_REG_READ 已打通并**转为默认**(当时回归 PASS 11, ticks 逐位一致; 当前矩阵 12  |
| 12 | `sw/coremark/core_portme.c` | 于是"CRC 不匹配"也报 RESULT : PASS —— 11 项回归里 | 于是"CRC 不匹配"也报 RESULT : PASS —— 早期 11 项回归里（当前矩阵 12 项） |
| 13 | `sw/portme.c` | (11 项里有 3 项的结论只靠人眼看日志)。 | (早期 11 项里有 3 项的结论只靠人眼看日志；当前矩阵 12 项)。 |

## 3. 逐文件审计表

| # | 源文件 | 类别 | 注释条数 | 判定/处置 |
|---:|---|---|---:|---|
| 1 | `alu.sv` | 根目录 RTL/其他 | 36 | 审查通过（未发现与当前口径冲突的陈述） |
| 2 | `archive/legacy/ALU.v` | 历史/第三方副本 | 5 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 3 | `archive/legacy/Branch_unit.v` | 历史/第三方副本 | 6 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 4 | `archive/legacy/Control_unit.v` | 历史/第三方副本 | 67 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 5 | `archive/legacy/PC.v` | 历史/第三方副本 | 1 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 6 | `archive/legacy/Regfile.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 7 | `archive/legacy/imm.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 8 | `archive/pds/impl.tcl` | 历史/第三方副本 | 1 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 9 | `archive/pds/riscv_pgl22g.pds` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 10 | `archive/pds/top_pgl22g.sv` | 历史/第三方副本 | 31 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 11 | `bht.sv` | 根目录 RTL/其他 | 87 | 审查通过（未发现与当前口径冲突的陈述） |
| 12 | `branch_unit.sv` | 根目录 RTL/其他 | 9 | 审查通过（未发现与当前口径冲突的陈述） |
| 13 | `btb.sv` | 根目录 RTL/其他 | 124 | 审查通过（未发现与当前口径冲突的陈述） |
| 14 | `control_unit.sv` | 根目录 RTL/其他 | 155 | 审查通过（未发现与当前口径冲突的陈述） |
| 15 | `core.sv` | 根目录 RTL/其他 | 1031 | 审查通过（未发现与当前口径冲突的陈述） |
| 16 | `csr_file.sv` | 根目录 RTL/其他 | 92 | 审查通过（未发现与当前口径冲突的陈述） |
| 17 | `dmem.sv` | 根目录 RTL/其他 | 24 | 审查通过（未发现与当前口径冲突的陈述） |
| 18 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/constraint_backup/hdmi_colorbar_2026_10_08_18_32_37.fdc` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 19 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/hdmi_colorbar.fdc` | 历史/第三方副本 | 60 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 20 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/hdmi_colorbar.pds` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 21 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/impl.tcl` | 历史/第三方副本 | 1 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 22 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/ipcore/clk_gen/clk_gen.v` | 历史/第三方副本 | 79 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 23 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/ipcore/clk_gen/clk_gen_tb.v` | 历史/第三方副本 | 19 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 24 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/ipcore/clk_gen/clk_gen_tmpl.v` | 历史/第三方副本 | 10 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 25 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_colorbar.v` | 历史/第三方副本 | 60 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 26 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_i2c/hdmi_cfg.v` | 历史/第三方副本 | 42 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 27 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_i2c/hdmi_i2c.v` | 历史/第三方副本 | 3 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 28 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_i2c/i2c_ctrl.v` | 历史/第三方副本 | 80 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 29 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_i2c/iic_dri.v` | 历史/第三方副本 | 124 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 30 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_i2c/ms7210_ctl.v` | 历史/第三方副本 | 75 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 31 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/vga_ctrl.v` | 历史/第三方副本 | 55 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 32 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/vga_pic.v` | 历史/第三方副本 | 38 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 33 | `ebf_pg2l100h_demo/20_hdmi_colorbar/sim/tb_board_check.v` | 历史/第三方副本 | 2 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 34 | `ebf_pg2l100h_demo/20_hdmi_colorbar/sim/tb_hdmi_colorbar.v` | 历史/第三方副本 | 32 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 35 | `ebf_pg2l100h_demo/20_hdmi_colorbar/sim/tb_ms7210_config.v` | 历史/第三方副本 | 2 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 36 | `ebf_pg2l100h_demo/20_hdmi_colorbar/sim/tb_pixel_clock.v` | 历史/第三方副本 | 1 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 37 | `ebf_pg2l100h_demo/20_hdmi_colorbar/sim/tb_vga_ctrl.v` | 历史/第三方副本 | 55 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 38 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/constraint_backup/hdmi_loop_2023_03_03_14_25_29.fdc` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 39 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/hdmi_loop.fdc` | 历史/第三方副本 | 3 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 40 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/hdmi_loop.pds` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 41 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/hdmi_loop_baseboard.pds` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 42 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/impl.tcl` | 历史/第三方副本 | 1 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 43 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/clk_gen/clk_gen.v` | 历史/第三方副本 | 79 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 44 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/clk_gen/clk_gen_tb.v` | 历史/第三方副本 | 19 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 45 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/clk_gen/clk_gen_tmpl.v` | 历史/第三方副本 | 10 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 46 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/source/new/hdmi_cfg.v` | 历史/第三方副本 | 46 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 47 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/source/new/hdmi_i2c.v` | 历史/第三方副本 | 42 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 48 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/source/new/hdmi_loop.v` | 历史/第三方副本 | 51 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 49 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/source/new/i2c_ctrl.v` | 历史/第三方副本 | 88 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 50 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/hdmi_cfg.v` | 历史/第三方副本 | 46 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 51 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/hdmi_i2c.v` | 历史/第三方副本 | 42 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 52 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/hdmi_loop.v` | 历史/第三方副本 | 1 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 53 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/i2c_ctrl.v` | 历史/第三方副本 | 88 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 54 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/iic_dri.v` | 历史/第三方副本 | 127 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 55 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/ms7200_ctl.v` | 历史/第三方副本 | 69 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 56 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/ms7210_ctl.v` | 历史/第三方副本 | 75 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 57 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/ms72xx_shared.v` | 历史/第三方副本 | 3 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 58 | `ebf_pg2l100h_demo/31_hdmi_loop/sim/arbiter_test.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 59 | `ebf_pg2l100h_demo/31_hdmi_loop/sim/init_test.v` | 历史/第三方副本 | 1 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 60 | `ebf_pg2l100h_demo/31_hdmi_loop/sim/video_test.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 61 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/constraint_backup/eth_udp_loop_2026_10_08_19_28_31.fdc` | 历史/第三方副本 | 166 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 62 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/constraint_backup/eth_udp_loop_2026_10_08_19_29_57.fdc` | 历史/第三方副本 | 186 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 63 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/constraint_backup/eth_udp_loop_2026_10_08_19_30_34.fdc` | 历史/第三方副本 | 186 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 64 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/constraint_backup/eth_udp_loop_2026_10_08_19_30_54.fdc` | 历史/第三方副本 | 186 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 65 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/constraint_backup/eth_udp_loop_2026_10_08_19_34_01.fdc` | 历史/第三方副本 | 186 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 66 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/eth_udp_loop.fdc` | 历史/第三方副本 | 186 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 67 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/eth_udp_loop.pds` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 68 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/impl.tcl` | 历史/第三方副本 | 1 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 69 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/async_fifo_2048x8b.v` | 历史/第三方副本 | 103 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 70 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/async_fifo_2048x8b_tb.v` | 历史/第三方副本 | 41 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 71 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/async_fifo_2048x8b_tmpl.v` | 历史/第三方副本 | 18 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 72 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/rtl/async_fifo_2048x8b_Reset_Value.v` | 历史/第三方副本 | 1 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 73 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/rtl/ipm2l_fifo_ctrl_v1_1_async_fifo_2048x8b.v` | 历史/第三方副本 | 78 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 74 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/rtl/ipm2l_fifo_v1_7_async_fifo_2048x8b.v` | 历史/第三方副本 | 19 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 75 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/rtl/ipm2l_sdpram_v1_6a_async_fifo_2048x8b.v` | 历史/第三方副本 | 131 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 76 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/rtl/ipm2l_fifo_ctrl_v1_1_sync_fifo_2048x8b.v` | 历史/第三方副本 | 78 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 77 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/rtl/ipm2l_fifo_v1_7_sync_fifo_2048x8b.v` | 历史/第三方副本 | 19 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 78 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/rtl/ipm2l_sdpram_v1_6a_sync_fifo_2048x8b.v` | 历史/第三方副本 | 131 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 79 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/rtl/sync_fifo_2048x8b_Reset_Value.v` | 历史/第三方副本 | 1 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 80 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/sync_fifo_2048x8b.v` | 历史/第三方副本 | 103 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 81 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/sync_fifo_2048x8b_tb.v` | 历史/第三方副本 | 41 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 82 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/sync_fifo_2048x8b_tmpl.v` | 历史/第三方副本 | 18 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 83 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/arp/arp.v` | 历史/第三方副本 | 60 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 84 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/arp/arp_rx.v` | 历史/第三方副本 | 76 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 85 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/arp/arp_tx.v` | 历史/第三方副本 | 97 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 86 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/arp/crc32_d8.v` | 历史/第三方副本 | 36 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 87 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/eth_ctrl.v` | 历史/第三方副本 | 82 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 88 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/eth_udp_loop.v` | 历史/第三方副本 | 102 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 89 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/gmii_to_rgmii/gmii_to_rgmii.v` | 历史/第三方副本 | 43 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 90 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/gmii_to_rgmii/rgmii_rx.v` | 历史/第三方副本 | 62 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 91 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/gmii_to_rgmii/rgmii_tx.v` | 历史/第三方副本 | 48 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 92 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/icmp/icmp.v` | 历史/第三方副本 | 66 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 93 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/icmp/icmp_rx.v` | 历史/第三方副本 | 100 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 94 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/icmp/icmp_tx.v` | 历史/第三方副本 | 126 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 95 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/udp/udp.v` | 历史/第三方副本 | 62 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 96 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/udp/udp_rx.v` | 历史/第三方副本 | 81 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 97 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/udp/udp_tx.v` | 历史/第三方副本 | 112 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 98 | `ebf_pg2l100h_demo/50_eth_udp_loop/sim/tb/tb_udp.v` | 历史/第三方副本 | 53 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 99 | `ex_mem_reg.sv` | 根目录 RTL/其他 | 130 | 审查通过（未发现与当前口径冲突的陈述） |
| 100 | `fpga/build.bat` | Artix-7 参照线 | 10 | 审查通过（未发现与当前口径冲突的陈述） |
| 101 | `fpga/build.tcl` | Artix-7 参照线 | 320 | 审查通过（未发现与当前口径冲突的陈述） |
| 102 | `fpga/build_ila.bat` | Artix-7 参照线 | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 103 | `fpga/build_ila.tcl` | Artix-7 参照线 | 139 | 审查通过（未发现与当前口径冲突的陈述） |
| 104 | `fpga/ila_cap_done.bat` | Artix-7 参照线 | 7 | 审查通过（未发现与当前口径冲突的陈述） |
| 105 | `fpga/ila_cap_done.tcl` | Artix-7 参照线 | 66 | 审查通过（未发现与当前口径冲突的陈述） |
| 106 | `fpga/ila_cap_mark.bat` | Artix-7 参照线 | 1 | 审查通过（未发现与当前口径冲突的陈述） |
| 107 | `fpga/ila_cap_mark.tcl` | Artix-7 参照线 | 14 | 审查通过（未发现与当前口径冲突的陈述） |
| 108 | `fpga/ila_info.bat` | Artix-7 参照线 | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 109 | `fpga/ila_info.tcl` | Artix-7 参照线 | 1 | 审查通过（未发现与当前口径冲突的陈述） |
| 110 | `fpga/ila_try.bat` | Artix-7 参照线 | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 111 | `fpga/ila_try.tcl` | Artix-7 参照线 | 1 | 审查通过（未发现与当前口径冲突的陈述） |
| 112 | `fpga/jtag_probe.bat` | Artix-7 参照线 | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 113 | `fpga/jtag_probe.tcl` | Artix-7 参照线 | 4 | 审查通过（未发现与当前口径冲突的陈述） |
| 114 | `fpga/mmio_subsys.sv` | Artix-7 参照线 | 120 | 审查通过（未发现与当前口径冲突的陈述） |
| 115 | `fpga/prog_uart.bat` | Artix-7 参照线 | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 116 | `fpga/prog_uart.tcl` | Artix-7 参照线 | 13 | 审查通过（未发现与当前口径冲突的陈述） |
| 117 | `fpga/top_a100t.sv` | Artix-7 参照线 | 110 | 已修复: 交付档注释 128.125→150 MHz；增加[跨厂商对比]声明 |
| 118 | `fpga_mes50hp/app/digit_cli.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 119 | `fpga_mes50hp/app/digit_demo.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 120 | `fpga_mes50hp/app/evaluate_board.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 121 | `fpga_mes50hp/app/inference.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 122 | `fpga_mes50hp/app/preprocessing.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 123 | `fpga_mes50hp/app/protocol.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 124 | `fpga_mes50hp/camera_lcd_debug/build.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 125 | `fpga_mes50hp/camera_lcd_debug/create_project.tcl` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 126 | `fpga_mes50hp/camera_lcd_debug/generate_pins.py` | 历史/第三方副本 | 2 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 127 | `fpga_mes50hp/camera_lcd_debug/mes50hp_camera_lcd.fdc` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 128 | `fpga_mes50hp/camera_lcd_debug/rtl/camera_config.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 129 | `fpga_mes50hp/camera_lcd_debug/rtl/camera_console.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 130 | `fpga_mes50hp/camera_lcd_debug/rtl/camera_fifo_capture.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 131 | `fpga_mes50hp/camera_lcd_debug/rtl/camera_framebuffer.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 132 | `fpga_mes50hp/camera_lcd_debug/rtl/camera_sccb.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 133 | `fpga_mes50hp/camera_lcd_debug/rtl/debug_keys.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 134 | `fpga_mes50hp/camera_lcd_debug/rtl/debug_uart.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 135 | `fpga_mes50hp/camera_lcd_debug/rtl/lcd_debug_video.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 136 | `fpga_mes50hp/camera_lcd_debug/rtl/top_camera_lcd_debug.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 137 | `fpga_mes50hp/camera_lcd_debug/sim/tb_capture.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 138 | `fpga_mes50hp/camera_lcd_debug/sim/tb_config.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 139 | `fpga_mes50hp/camera_lcd_debug/sim/tb_controls.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 140 | `fpga_mes50hp/camera_lcd_debug/sim/tb_video.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 141 | `fpga_mes50hp/camera_lcd_debug/uart_monitor.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 142 | `fpga_mes50hp/camera_lcd_debug/verify.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 143 | `fpga_mes50hp/create_project.bat` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 144 | `fpga_mes50hp/create_project.tcl` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 145 | `fpga_mes50hp/firmware/boot.S` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 146 | `fpga_mes50hp/firmware/digit/link.ld` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 147 | `fpga_mes50hp/firmware/digit/main.c` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 148 | `fpga_mes50hp/firmware/digit/platform.c` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 149 | `fpga_mes50hp/firmware/digit/platform.h` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 150 | `fpga_mes50hp/firmware/digit/start.S` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 151 | `fpga_mes50hp/generated/profile_constraints.fdc` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 152 | `fpga_mes50hp/generated/riscv_pds.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 153 | `fpga_mes50hp/io_debug/build.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 154 | `fpga_mes50hp/io_debug/create_project.tcl` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 155 | `fpga_mes50hp/io_debug/mes50hp_io_debug.fdc` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 156 | `fpga_mes50hp/io_debug/rtl/debug_console.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 157 | `fpga_mes50hp/io_debug/rtl/debug_i2c_write.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 158 | `fpga_mes50hp/io_debug/rtl/debug_keys.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 159 | `fpga_mes50hp/io_debug/rtl/debug_ms7210.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 160 | `fpga_mes50hp/io_debug/rtl/debug_uart.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 161 | `fpga_mes50hp/io_debug/rtl/debug_video.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 162 | `fpga_mes50hp/io_debug/rtl/top_io_debug.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 163 | `fpga_mes50hp/io_debug/run_sim.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 164 | `fpga_mes50hp/io_debug/tb/tb_clock_health.sv` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 165 | `fpga_mes50hp/io_debug/tb/tb_console.sv` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 166 | `fpga_mes50hp/io_debug/tb/tb_io_debug.sv` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 167 | `fpga_mes50hp/io_debug/uart_check.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 168 | `fpga_mes50hp/mes50hp.fdc` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 169 | `fpga_mes50hp/mes50hp_digit.fdc` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 170 | `fpga_mes50hp/model/digit_model.h` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 171 | `fpga_mes50hp/model/train.py` | 历史/第三方副本 | 2 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 172 | `fpga_mes50hp/prepare_rtl.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 173 | `fpga_mes50hp/riscv_mes50hp.pds` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 174 | `fpga_mes50hp/setup_tools.ps1` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 175 | `fpga_mes50hp/src/alu.sv` | 历史/第三方副本 | 36 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 176 | `fpga_mes50hp/src/bht.sv` | 历史/第三方副本 | 87 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 177 | `fpga_mes50hp/src/branch_unit.sv` | 历史/第三方副本 | 9 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 178 | `fpga_mes50hp/src/btb.sv` | 历史/第三方副本 | 124 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 179 | `fpga_mes50hp/src/control_unit.sv` | 历史/第三方副本 | 155 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 180 | `fpga_mes50hp/src/core.sv` | 历史/第三方副本 | 1031 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 181 | `fpga_mes50hp/src/csr_file.sv` | 历史/第三方副本 | 92 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 182 | `fpga_mes50hp/src/digit_peripherals.sv` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 183 | `fpga_mes50hp/src/digit_video.sv` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 184 | `fpga_mes50hp/src/dmem.sv` | 历史/第三方副本 | 24 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 185 | `fpga_mes50hp/src/ex_mem_reg.sv` | 历史/第三方副本 | 130 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 186 | `fpga_mes50hp/src/gemm_accel.sv` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 187 | `fpga_mes50hp/src/hazard_unit.sv` | 历史/第三方副本 | 108 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 188 | `fpga_mes50hp/src/id_ex_reg.sv` | 历史/第三方副本 | 56 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 189 | `fpga_mes50hp/src/imem.sv` | 历史/第三方副本 | 32 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 190 | `fpga_mes50hp/src/imm_gen.sv` | 历史/第三方副本 | 19 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 191 | `fpga_mes50hp/src/load_store_unit.sv` | 历史/第三方副本 | 207 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 192 | `fpga_mes50hp/src/mem_wb_reg.sv` | 历史/第三方副本 | 8 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 193 | `fpga_mes50hp/src/mmio_subsys.sv` | 历史/第三方副本 | 91 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 194 | `fpga_mes50hp/src/muldiv.sv` | 历史/第三方副本 | 116 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 195 | `fpga_mes50hp/src/pc.sv` | 历史/第三方副本 | 13 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 196 | `fpga_mes50hp/src/ras.sv` | 历史/第三方副本 | 38 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 197 | `fpga_mes50hp/src/regfile.sv` | 历史/第三方副本 | 22 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 198 | `fpga_mes50hp/src/rv32_pkg.sv` | 历史/第三方副本 | 260 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 199 | `fpga_mes50hp/src/top_mes50hp.sv` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 200 | `fpga_mes50hp/src/top_pgl22g.sv` | 历史/第三方副本 | 31 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 201 | `fpga_mes50hp/src/uart_rx_fifo.sv` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 202 | `fpga_mes50hp/tools/asm.py` | 历史/第三方副本 | 20 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 203 | `fpga_mes50hp/tools/build_digit.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 204 | `fpga_mes50hp/tools/build_digit_bitstream.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 205 | `fpga_mes50hp/tools/summarize_digit.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 206 | `fpga_pds_1_0_9/create_project.bat` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 207 | `fpga_pds_1_0_9/create_project.tcl` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 208 | `fpga_pds_1_0_9/generated/riscv_pds.v` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 209 | `fpga_pds_1_0_9/prepare_rtl.py` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 210 | `fpga_pds_1_0_9/riscv.fdc` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 211 | `fpga_pds_1_0_9/riscv_pgl22g.pds` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 212 | `fpga_pds_1_0_9/setup_tools.ps1` | 历史/第三方副本 | 0 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 213 | `fpga_pds_1_0_9/src/alu.sv` | 历史/第三方副本 | 36 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 214 | `fpga_pds_1_0_9/src/bht.sv` | 历史/第三方副本 | 87 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 215 | `fpga_pds_1_0_9/src/branch_unit.sv` | 历史/第三方副本 | 9 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 216 | `fpga_pds_1_0_9/src/btb.sv` | 历史/第三方副本 | 124 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 217 | `fpga_pds_1_0_9/src/control_unit.sv` | 历史/第三方副本 | 155 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 218 | `fpga_pds_1_0_9/src/core.sv` | 历史/第三方副本 | 1031 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 219 | `fpga_pds_1_0_9/src/csr_file.sv` | 历史/第三方副本 | 92 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 220 | `fpga_pds_1_0_9/src/dmem.sv` | 历史/第三方副本 | 24 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 221 | `fpga_pds_1_0_9/src/ex_mem_reg.sv` | 历史/第三方副本 | 130 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 222 | `fpga_pds_1_0_9/src/gemm_accel.sv` | 历史/第三方副本 | 64 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 223 | `fpga_pds_1_0_9/src/hazard_unit.sv` | 历史/第三方副本 | 108 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 224 | `fpga_pds_1_0_9/src/id_ex_reg.sv` | 历史/第三方副本 | 56 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 225 | `fpga_pds_1_0_9/src/imem.sv` | 历史/第三方副本 | 32 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 226 | `fpga_pds_1_0_9/src/imm_gen.sv` | 历史/第三方副本 | 19 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 227 | `fpga_pds_1_0_9/src/load_store_unit.sv` | 历史/第三方副本 | 207 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 228 | `fpga_pds_1_0_9/src/mem_wb_reg.sv` | 历史/第三方副本 | 8 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 229 | `fpga_pds_1_0_9/src/mmio_subsys.sv` | 历史/第三方副本 | 120 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 230 | `fpga_pds_1_0_9/src/muldiv.sv` | 历史/第三方副本 | 116 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 231 | `fpga_pds_1_0_9/src/pc.sv` | 历史/第三方副本 | 13 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 232 | `fpga_pds_1_0_9/src/ras.sv` | 历史/第三方副本 | 38 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 233 | `fpga_pds_1_0_9/src/regfile.sv` | 历史/第三方副本 | 22 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 234 | `fpga_pds_1_0_9/src/rv32_pkg.sv` | 历史/第三方副本 | 285 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 235 | `fpga_pds_1_0_9/src/top_pgl22g.sv` | 历史/第三方副本 | 31 | 保留原貌（历史/第三方副本，不参与当前交付口径） |
| 236 | `fpga_pg2l100h/camera_lcd_debug/build.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 237 | `fpga_pg2l100h/camera_lcd_debug/create_project.tcl` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 238 | `fpga_pg2l100h/camera_lcd_debug/generate_pins.py` | 交付主体(Pango) | 11 | 审查通过（未发现与当前口径冲突的陈述） |
| 239 | `fpga_pg2l100h/camera_lcd_debug/pg2l100h_camera_lcd.fdc` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 240 | `fpga_pg2l100h/camera_lcd_debug/project_file.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 241 | `fpga_pg2l100h/camera_lcd_debug/rtl/pg2l100h_clock.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 242 | `fpga_pg2l100h/camera_lcd_debug/rtl/top_pg2l100h_camera_lcd.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 243 | `fpga_pg2l100h/camera_lcd_debug/sim/tb_board.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 244 | `fpga_pg2l100h/camera_lcd_debug/verify.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 245 | `fpga_pg2l100h/vision/build.py` | 交付主体(Pango) | 4 | 审查通过（未发现与当前口径冲突的陈述） |
| 246 | `fpga_pg2l100h/vision/competition/core_portme.c` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 247 | `fpga_pg2l100h/vision/competition/core_portme.h` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 248 | `fpga_pg2l100h/vision/competition/coremark.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 249 | `fpga_pg2l100h/vision/competition/package_project.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 250 | `fpga_pg2l100h/vision/competition/verify_coremark.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 251 | `fpga_pg2l100h/vision/firmware/link.ld` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 252 | `fpga_pg2l100h/vision/firmware/main.c` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 253 | `fpga_pg2l100h/vision/firmware/numeric_guard.h` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 254 | `fpga_pg2l100h/vision/firmware/numeric_main.c` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 255 | `fpga_pg2l100h/vision/firmware/start.S` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 256 | `fpga_pg2l100h/vision/model/audit_coco.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 257 | `fpga_pg2l100h/vision/model/camera_preprocess.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 258 | `fpga_pg2l100h/vision/model/fetch_reference_weights.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 259 | `fpga_pg2l100h/vision/model/gesture_standard.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 260 | `fpga_pg2l100h/vision/model/make_font.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 261 | `fpga_pg2l100h/vision/model/network.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 262 | `fpga_pg2l100h/vision/model/prepare_gesture_dataset.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 263 | `fpga_pg2l100h/vision/model/prepare_public_dataset.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 264 | `fpga_pg2l100h/vision/model/preview_public.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 265 | `fpga_pg2l100h/vision/model/select_model.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 266 | `fpga_pg2l100h/vision/model/train.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 267 | `fpga_pg2l100h/vision/model/train_dataset.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 268 | `fpga_pg2l100h/vision/model/train_numeric.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 269 | `fpga_pg2l100h/vision/model/train_public.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 270 | `fpga_pg2l100h/vision/rtl/camera_dvp_capture.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 271 | `fpga_pg2l100h/vision/rtl/cpu/alu.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 272 | `fpga_pg2l100h/vision/rtl/cpu/bht.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 273 | `fpga_pg2l100h/vision/rtl/cpu/branch_unit.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 274 | `fpga_pg2l100h/vision/rtl/cpu/btb.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 275 | `fpga_pg2l100h/vision/rtl/cpu/control_unit.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 276 | `fpga_pg2l100h/vision/rtl/cpu/core.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 277 | `fpga_pg2l100h/vision/rtl/cpu/csr_file.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 278 | `fpga_pg2l100h/vision/rtl/cpu/dmem.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 279 | `fpga_pg2l100h/vision/rtl/cpu/ex_mem_reg.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 280 | `fpga_pg2l100h/vision/rtl/cpu/hazard_unit.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 281 | `fpga_pg2l100h/vision/rtl/cpu/id_ex_reg.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 282 | `fpga_pg2l100h/vision/rtl/cpu/imem.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 283 | `fpga_pg2l100h/vision/rtl/cpu/imm_gen.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 284 | `fpga_pg2l100h/vision/rtl/cpu/load_store_unit.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 285 | `fpga_pg2l100h/vision/rtl/cpu/mem_wb_reg.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 286 | `fpga_pg2l100h/vision/rtl/cpu/muldiv.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 287 | `fpga_pg2l100h/vision/rtl/cpu/pc.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 288 | `fpga_pg2l100h/vision/rtl/cpu/ras.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 289 | `fpga_pg2l100h/vision/rtl/cpu/regfile.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 290 | `fpga_pg2l100h/vision/rtl/top_pg2l100h_vision.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 291 | `fpga_pg2l100h/vision/rtl/vision_cpu_clock.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 292 | `fpga_pg2l100h/vision/rtl/vision_framebuffer.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 293 | `fpga_pg2l100h/vision/rtl/vision_lcd.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 294 | `fpga_pg2l100h/vision/rtl/vision_mmio_bridge.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 295 | `fpga_pg2l100h/vision/rtl/vision_npu.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 296 | `fpga_pg2l100h/vision/rtl/vision_snapshot.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 297 | `fpga_pg2l100h/vision/rtl/vision_soc.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 298 | `fpga_pg2l100h/vision/rtl/vision_video_bridge.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 299 | `fpga_pg2l100h/vision/sim/tb_board.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 300 | `fpga_pg2l100h/vision/sim/tb_camera.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 301 | `fpga_pg2l100h/vision/sim/tb_camera_dvp.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 302 | `fpga_pg2l100h/vision/sim/tb_cdc.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 303 | `fpga_pg2l100h/vision/sim/tb_coremark.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 304 | `fpga_pg2l100h/vision/sim/tb_cpu_mmio.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 305 | `fpga_pg2l100h/vision/sim/tb_lcd.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 306 | `fpga_pg2l100h/vision/sim/tb_muldiv.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 307 | `fpga_pg2l100h/vision/sim/tb_npu.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 308 | `fpga_pg2l100h/vision/sim/tb_snapshot.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 309 | `fpga_pg2l100h/vision/sim/tb_snapshot_hand.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 310 | `fpga_pg2l100h/vision/sim/tb_soc.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 311 | `fpga_pg2l100h/vision/sim/tb_soc_hand.v` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 312 | `fpga_pg2l100h/vision/sim/test_cpu_mmio.c` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 313 | `fpga_pg2l100h/vision/sim/test_cpu_mmio.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 314 | `fpga_pg2l100h/vision/sim/test_hand_firmware.c` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 315 | `fpga_pg2l100h/vision/sim/test_hand_firmware.py` | 交付主体(Pango) | 5 | 审查通过（未发现与当前口径冲突的陈述） |
| 316 | `fpga_pg2l100h/vision/sim/test_numeric_guard.c` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 317 | `fpga_pg2l100h/vision/sim/test_tools.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 318 | `fpga_pg2l100h/vision/sim/test_training_data.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 319 | `fpga_pg2l100h/vision/tools/capture_numeric.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 320 | `fpga_pg2l100h/vision/tools/evaluate_numeric.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 321 | `fpga_pg2l100h/vision/tools/make_demo_cards.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 322 | `fpga_pg2l100h/vision/tools/preview_gestures.py` | 交付主体(Pango) | 5 | 审查通过（未发现与当前口径冲突的陈述） |
| 323 | `fpga_pg2l100h/vision/tools/preview_numeric.py` | 交付主体(Pango) | 3 | 审查通过（未发现与当前口径冲突的陈述） |
| 324 | `fpga_pg2l100h/vision/verify.py` | 交付主体(Pango) | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 325 | `gemm_accel.sv` | 根目录 RTL/其他 | 64 | 审查通过（未发现与当前口径冲突的陈述） |
| 326 | `hazard_unit.sv` | 根目录 RTL/其他 | 108 | 审查通过（未发现与当前口径冲突的陈述） |
| 327 | `id_ex_reg.sv` | 根目录 RTL/其他 | 56 | 审查通过（未发现与当前口径冲突的陈述） |
| 328 | `imem.sv` | 根目录 RTL/其他 | 32 | 审查通过（未发现与当前口径冲突的陈述） |
| 329 | `imm_gen.sv` | 根目录 RTL/其他 | 19 | 审查通过（未发现与当前口径冲突的陈述） |
| 330 | `impl.pds` | 根目录 RTL/其他 | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 331 | `load_store_unit.sv` | 根目录 RTL/其他 | 207 | 审查通过（未发现与当前口径冲突的陈述） |
| 332 | `mem_wb_reg.sv` | 根目录 RTL/其他 | 8 | 审查通过（未发现与当前口径冲突的陈述） |
| 333 | `muldiv.sv` | 根目录 RTL/其他 | 116 | 审查通过（未发现与当前口径冲突的陈述） |
| 334 | `pc.sv` | 根目录 RTL/其他 | 13 | 审查通过（未发现与当前口径冲突的陈述） |
| 335 | `ras.sv` | 根目录 RTL/其他 | 38 | 审查通过（未发现与当前口径冲突的陈述） |
| 336 | `regfile.sv` | 根目录 RTL/其他 | 22 | 审查通过（未发现与当前口径冲突的陈述） |
| 337 | `rv32_pkg.sv` | 根目录 RTL/其他 | 285 | 审查通过（未发现与当前口径冲突的陈述） |
| 338 | `sim/prog/_csr_probe.S` | Artix-7 参照线 | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 339 | `sim/prog/amo.S` | Artix-7 参照线 | 60 | 审查通过（未发现与当前口径冲突的陈述） |
| 340 | `sim/prog/amo_diag.S` | Artix-7 参照线 | 32 | 审查通过（未发现与当前口径冲突的陈述） |
| 341 | `sim/prog/amo_diag2.S` | Artix-7 参照线 | 21 | 审查通过（未发现与当前口径冲突的陈述） |
| 342 | `sim/prog/basic.S` | Artix-7 参照线 | 50 | 审查通过（未发现与当前口径冲突的陈述） |
| 343 | `sim/prog/lu_bench.S` | Artix-7 参照线 | 62 | 审查通过（未发现与当前口径冲突的陈述） |
| 344 | `sim/prog/m_ext.S` | Artix-7 参照线 | 40 | 审查通过（未发现与当前口径冲突的陈述） |
| 345 | `sim/prog/mmio.S` | Artix-7 参照线 | 25 | 审查通过（未发现与当前口径冲突的陈述） |
| 346 | `sim/prog/timer_irq.S` | Artix-7 参照线 | 158 | 审查通过（未发现与当前口径冲突的陈述） |
| 347 | `sim/prog/trap.S` | Artix-7 参照线 | 59 | 审查通过（未发现与当前口径冲突的陈述） |
| 348 | `sim/run.bat` | Artix-7 参照线 | 18 | 审查通过（未发现与当前口径冲突的陈述） |
| 349 | `sim/run.sh` | Artix-7 参照线 | 15 | 审查通过（未发现与当前口径冲突的陈述） |
| 350 | `sim/run_prog.py` | Artix-7 参照线 | 6 | 审查通过（未发现与当前口径冲突的陈述） |
| 351 | `sim/tb_core.sv` | Artix-7 参照线 | 38 | 审查通过（未发现与当前口径冲突的陈述） |
| 352 | `sim/tb_soc.sv` | Artix-7 参照线 | 57 | 审查通过（未发现与当前口径冲突的陈述） |
| 353 | `sim/tb_sw.sv` | Artix-7 参照线 | 281 | 审查通过（未发现与当前口径冲突的陈述） |
| 354 | `sim/tb_units.sv` | Artix-7 参照线 | 148 | 审查通过（未发现与当前口径冲突的陈述） |
| 355 | `sw/coremark/core_list_join.c` | Artix-7 参照线 | 59 | 审查通过（未发现与当前口径冲突的陈述） |
| 356 | `sw/coremark/core_main.c` | Artix-7 参照线 | 36 | 审查通过（未发现与当前口径冲突的陈述） |
| 357 | `sw/coremark/core_matrix.c` | Artix-7 参照线 | 14 | 审查通过（未发现与当前口径冲突的陈述） |
| 358 | `sw/coremark/core_portme.c` | Artix-7 参照线 | 18 | 已修复: 历史 11 项措辞→早期 11 项/当前 12 项 |
| 359 | `sw/coremark/core_portme.h` | Artix-7 参照线 | 29 | 审查通过（未发现与当前口径冲突的陈述） |
| 360 | `sw/coremark/core_state.c` | Artix-7 参照线 | 24 | 审查通过（未发现与当前口径冲突的陈述） |
| 361 | `sw/coremark/core_util.c` | Artix-7 参照线 | 7 | 审查通过（未发现与当前口径冲突的陈述） |
| 362 | `sw/coremark/coremark.h` | Artix-7 参照线 | 27 | 审查通过（未发现与当前口径冲突的陈述） |
| 363 | `sw/coremark/ee_printf.c` | Artix-7 参照线 | 28 | 审查通过（未发现与当前口径冲突的陈述） |
| 364 | `sw/crt0.S` | Artix-7 参照线 | 15 | 审查通过（未发现与当前口径冲突的陈述） |
| 365 | `sw/hello.c` | Artix-7 参照线 | 18 | 审查通过（未发现与当前口径冲突的陈述） |
| 366 | `sw/libc_min.c` | Artix-7 参照线 | 1 | 审查通过（未发现与当前口径冲突的陈述） |
| 367 | `sw/link.ld` | Artix-7 参照线 | 0 | 审查通过（未发现与当前口径冲突的陈述） |
| 368 | `sw/nn_demo.c` | Artix-7 参照线 | 48 | 审查通过（未发现与当前口径冲突的陈述） |
| 369 | `sw/opt_probe.c` | Artix-7 参照线 | 13 | 审查通过（未发现与当前口径冲突的陈述） |
| 370 | `sw/portme.c` | Artix-7 参照线 | 8 | 已修复: 历史 11 项措辞→早期 11 项/当前 12 项 |
| 371 | `tools/amo_vectors.py` | 工具脚本 | 17 | 审查通过（未发现与当前口径冲突的陈述） |
| 372 | `tools/asm.py` | 工具脚本 | 20 | 审查通过（未发现与当前口径冲突的陈述） |
| 373 | `tools/build_sw.py` | 工具脚本 | 28 | 已修复: 11 项→12 项（矩阵当前 12 项） |
| 374 | `tools/check_equiv.py` | 工具脚本 | 16 | 审查通过（未发现与当前口径冲突的陈述） |
| 375 | `tools/compliance_check.py` | 工具脚本 | 7 | 审查通过（未发现与当前口径冲突的陈述） |
| 376 | `tools/doctor.bat` | 工具脚本 | 12 | 审查通过（未发现与当前口径冲突的陈述） |
| 377 | `tools/elf2hex.py` | 工具脚本 | 2 | 审查通过（未发现与当前口径冲突的陈述） |
| 378 | `tools/flash_boot.ps1` | 工具脚本 | 23 | 审查通过（未发现与当前口径冲突的陈述） |
| 379 | `tools/flash_mkimage.tcl` | 工具脚本 | 14 | 审查通过（未发现与当前口径冲突的陈述） |
| 380 | `tools/flash_partcheck.tcl` | 工具脚本 | 8 | 审查通过（未发现与当前口径冲突的陈述） |
| 381 | `tools/flash_probe.tcl` | 工具脚本 | 13 | 审查通过（未发现与当前口径冲突的陈述） |
| 382 | `tools/flash_program.tcl` | 工具脚本 | 137 | 审查通过（未发现与当前口径冲突的陈述） |
| 383 | `tools/flash_readback.tcl` | 工具脚本 | 15 | 审查通过（未发现与当前口径冲突的陈述） |
| 384 | `tools/flash_run.ps1` | 工具脚本 | 16 | 审查通过（未发现与当前口径冲突的陈述） |
| 385 | `tools/flash_sweep.ps1` | 工具脚本 | 14 | 审查通过（未发现与当前口径冲突的陈述） |
| 386 | `tools/fpga_workflow.py` | 工具脚本 | 537 | 已修复: 历史 PASS 11 措辞→当前矩阵 12 项 |
| 387 | `tools/ftdi_probe.py` | 工具脚本 | 3 | 审查通过（未发现与当前口径冲突的陈述） |
| 388 | `tools/hier_util.tcl` | 工具脚本 | 28 | 审查通过（未发现与当前口径冲突的陈述） |
| 389 | `tools/mk_cm_hw.py` | 工具脚本 | 63 | 审查通过（未发现与当前口径冲突的陈述） |
| 390 | `tools/path_families.py` | 工具脚本 | 14 | 审查通过（未发现与当前口径冲突的陈述） |
| 391 | `tools/path_hotspot.py` | 工具脚本 | 39 | 审查通过（未发现与当前口径冲突的陈述） |
| 392 | `tools/pdf_mine.py` | 工具脚本 | 8 | 审查通过（未发现与当前口径冲突的陈述） |
| 393 | `tools/pdf_text.py` | 工具脚本 | 6 | 审查通过（未发现与当前口径冲突的陈述） |
| 394 | `tools/run_coremark.py` | 工具脚本 | 28 | 审查通过（未发现与当前口径冲突的陈述） |
| 395 | `tools/sweep_clk.py` | 工具脚本 | 9 | 审查通过（未发现与当前口径冲突的陈述） |
| 396 | `tools/sweep_pblock_place.ps1` | 工具脚本 | 5 | 审查通过（未发现与当前口径冲突的陈述） |
| 397 | `tools/trace_diff.py` | 工具脚本 | 10 | 审查通过（未发现与当前口径冲突的陈述） |
| 398 | `tools/uart_capture.py` | 工具脚本 | 6 | 审查通过（未发现与当前口径冲突的陈述） |

## 4. 一致性口径（审查依据）

| 事实 | 当前值 | 依据 |
|---|---|---|
| Artix-7 交付档频率 | **150 MHz**（MMCM 21/7；WNS +0.007） | `fpga/top_a100t.sv`、`fpga/daVinciPro.xdc`、`results/coremark.csv` |
| Artix-7 验证矩阵 | **12 项**（PASS 12）；`feat/ai-accel` 分支含 NN 4 项共 16 | `tools/fpga_workflow.py::test_matrix()` |
| Pango 时钟域 | CPU/IMEM/DMEM 125 MHz；NPU/采集/MMIO 50 MHz | `fpga_pg2l100h/vision/CLOCK_SPLIT.md` |
| Pango Flash | **未写入**（JTAG RAM 下载） | `fpga_pg2l100h/vision/BOARD_VALIDATION.md`、`COMPLIANCE.md` §4 |
| AI 线 NPU（对比材料） | 112-op E2E PASS；NPU 1,191,020 周期；SW 473,254,313 周期；401.9× | `feat/ai-accel` 分支文档（[跨厂商对比]） |
| 禁用/限制用语 | 见 `COMPLIANCE.md` §3 | `COMPLIANCE.md` |