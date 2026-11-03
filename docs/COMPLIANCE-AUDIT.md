# 全量文件合规性审计（docs/COMPLIANCE-AUDIT.md）

> 生成方式：`python tools/compliance_check.py`（检查）+ 维护者生成的逐文件登记表。
> 覆盖仓库 `main` 分支**全部 835 个文件**。判定规则见 [`COMPLIANCE.md`](../COMPLIANCE.md)。
> "对外陈述"= 文档/注释中可能被引用为项目结论的数字或断言；代码与二进制不构成对外陈述，但逐条登记以便追溯。

## 1. 统计

| 类别 | 文件数 |
|---|---:|
| 交付主体文档 | 348 |
| 第三方/历史参考 | 279 |
| 证据/迭代文档 | 64 |
| Artix-7 对比线 | 55 |
| 工具/开发文档 | 40 |
| 开发/交接文档 | 28 |
| 归档 | 11 |
| 规范/技术文档 | 6 |
| 根文档 | 4 |

| 判定 | 文件数 |
|---|---:|
| 文本(代码/配置，无对外结论) | 449 |
| 数据/二进制(无对外陈述) | 294 |
| 合规(已加范围/口径声明) | 84 |
| 新增规范/技术文档 | 6 |
| 新增合规检查器 | 1 |
| 合规(已加 Artix 声明 + Pango Flash 状态) | 1 |

**总计：835 个文件**（与 main 分支文件数一致）。

## 2. 判定规则

- **合规(已加范围/口径声明)**：文档含可能被引用的数字/结论，已在文首加入对应范围声明（交付主体/证据/对比/参考/归档/开发性质六类）。
- **新增规范/技术文档**：`COMPLIANCE.md`、`docs/{TECHNICAL-OVERVIEW,REPRODUCE,EVIDENCE,SUBMISSION-CHECKLIST,COMPLIANCE-AUDIT}.md`，按 COMPLIANCE.md 分级书写。
- **文本(代码/配置)**：代码注释不作为对外陈述；其行为结果须按 COMPLIANCE.md 分级并附证据路径后引用。
- **数据/二进制**：hex/权重/图片/PDF/位流等，不含陈述。
- **数字级别**：A 实测(上板)/B 实测(仿真)/C 综合/D 派生/E 未测——见 `COMPLIANCE.md` §2。

## 3. 逐文件审计表

| # | 文件 | 类别 | 判定 |
|---:|---|---|---|
| 1 | `.gitignore` | 开发/交接文档 | 数据/二进制(无对外陈述) |
| 2 | `CODE-MAP.md` | 开发/交接文档 | 合规(已加范围/口径声明) |
| 3 | `CODE-REVIEW-PLAN.md` | 开发/交接文档 | 合规(已加范围/口径声明) |
| 4 | `COMPLIANCE.md` | 根文档 | 新增规范/技术文档 |
| 5 | `HANDOFF-HW-LOOP.md` | 开发/交接文档 | 合规(已加范围/口径声明) |
| 6 | `HANDOFF-WORKFLOW.md` | 开发/交接文档 | 合规(已加范围/口径声明) |
| 7 | `HANDOFF.md` | 开发/交接文档 | 合规(已加范围/口径声明) |
| 8 | `README-ARTIX.md` | 根文档 | 合规(已加范围/口径声明) |
| 9 | `README.md` | 根文档 | 合规(已加范围/口径声明) |
| 10 | `THIRD_PARTY.md` | 根文档 | 合规(已加范围/口径声明) |
| 11 | `alu.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 12 | `archive/README.md` | 归档 | 合规(已加范围/口径声明) |
| 13 | `archive/legacy/ALU.v` | 归档 | 文本(代码/配置，无对外结论) |
| 14 | `archive/legacy/Branch_unit.v` | 归档 | 文本(代码/配置，无对外结论) |
| 15 | `archive/legacy/Control_unit.v` | 归档 | 文本(代码/配置，无对外结论) |
| 16 | `archive/legacy/PC.v` | 归档 | 文本(代码/配置，无对外结论) |
| 17 | `archive/legacy/Regfile.v` | 归档 | 文本(代码/配置，无对外结论) |
| 18 | `archive/legacy/imm.v` | 归档 | 文本(代码/配置，无对外结论) |
| 19 | `archive/pds/impl.tcl` | 归档 | 文本(代码/配置，无对外结论) |
| 20 | `archive/pds/multiseed_summary.csv` | 归档 | 文本(代码/配置，无对外结论) |
| 21 | `archive/pds/riscv_pgl22g.pds` | 归档 | 文本(代码/配置，无对外结论) |
| 22 | `archive/pds/top_pgl22g.sv` | 归档 | 文本(代码/配置，无对外结论) |
| 23 | `bht.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 24 | `branch_unit.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 25 | `btb.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 26 | `control_unit.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 27 | `core.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 28 | `csr_file.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 29 | `dmem.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 30 | `docs/COMPLIANCE-AUDIT.md` | 规范/技术文档 | 新增规范/技术文档 |
| 31 | `docs/EVIDENCE.md` | 规范/技术文档 | 新增规范/技术文档 |
| 32 | `docs/README.md` | 规范/技术文档 | 合规(已加范围/口径声明) |
| 33 | `docs/REPRODUCE.md` | 规范/技术文档 | 新增规范/技术文档 |
| 34 | `docs/SUBMISSION-CHECKLIST.md` | 规范/技术文档 | 新增规范/技术文档 |
| 35 | `docs/TECHNICAL-OVERVIEW.md` | 规范/技术文档 | 新增规范/技术文档 |
| 36 | `ebf_pg2l100h_demo/20_hdmi_colorbar/doc/VESA VGA时序标准.pdf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 37 | `ebf_pg2l100h_demo/20_hdmi_colorbar/doc/hdmi_colorbar.vsdx` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 38 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/constraint_backup/hdmi_colorbar_2026_10_08_18_32_37.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 39 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/hdmi_colorbar.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 40 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/hdmi_colorbar.pds` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 41 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/impl.tcl` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 42 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/ipcore/clk_gen/.last_generated` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 43 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/ipcore/clk_gen/.settings` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 44 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/ipcore/clk_gen/clk_gen.idf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 45 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/ipcore/clk_gen/clk_gen.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 46 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/ipcore/clk_gen/clk_gen_tb.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 47 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/ipcore/clk_gen/clk_gen_tmpl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 48 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/ipcore/clk_gen/clk_gen_tmpl.vhdl` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 49 | `ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/multiseed_summary.csv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 50 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_colorbar.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 51 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_i2c/hdmi_cfg.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 52 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_i2c/hdmi_i2c.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 53 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_i2c/i2c_ctrl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 54 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_i2c/iic_dri.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 55 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/hdmi_i2c/ms7210_ctl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 56 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/vga_ctrl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 57 | `ebf_pg2l100h_demo/20_hdmi_colorbar/rtl/vga_pic.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 58 | `ebf_pg2l100h_demo/20_hdmi_colorbar/sim/tb_board_check.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 59 | `ebf_pg2l100h_demo/20_hdmi_colorbar/sim/tb_hdmi_colorbar.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 60 | `ebf_pg2l100h_demo/20_hdmi_colorbar/sim/tb_ms7210_config.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 61 | `ebf_pg2l100h_demo/20_hdmi_colorbar/sim/tb_pixel_clock.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 62 | `ebf_pg2l100h_demo/20_hdmi_colorbar/sim/tb_vga_ctrl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 63 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/constraint_backup/hdmi_loop_2023_03_03_14_25_29.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 64 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/hdmi_loop.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 65 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/hdmi_loop.pds` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 66 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/hdmi_loop_baseboard.pds` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 67 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/impl.tcl` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 68 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/clk_gen/.last_generated` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 69 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/clk_gen/.settings` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 70 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/clk_gen/clk_gen.idf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 71 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/clk_gen/clk_gen.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 72 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/clk_gen/clk_gen_tb.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 73 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/clk_gen/clk_gen_tmpl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 74 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/clk_gen/clk_gen_tmpl.vhdl` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 75 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/ipcore/l/l.idf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 76 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/multiseed_summary.csv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 77 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/source/new/hdmi_cfg.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 78 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/source/new/hdmi_i2c.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 79 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/source/new/hdmi_loop.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 80 | `ebf_pg2l100h_demo/31_hdmi_loop/pds_prj/source/new/i2c_ctrl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 81 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/hdmi_cfg.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 82 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/hdmi_i2c.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 83 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/hdmi_loop.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 84 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/i2c_ctrl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 85 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/iic_dri.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 86 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/ms7200_ctl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 87 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/ms7210_ctl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 88 | `ebf_pg2l100h_demo/31_hdmi_loop/rtl/ms72xx_shared.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 89 | `ebf_pg2l100h_demo/31_hdmi_loop/sim/arbiter_test.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 90 | `ebf_pg2l100h_demo/31_hdmi_loop/sim/init_test.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 91 | `ebf_pg2l100h_demo/31_hdmi_loop/sim/video_test.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 92 | `ebf_pg2l100h_demo/50_eth_udp_loop/doc/udp.vsdx` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 93 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/constraint_backup/eth_udp_loop_2026_10_08_19_28_31.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 94 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/constraint_backup/eth_udp_loop_2026_10_08_19_29_57.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 95 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/constraint_backup/eth_udp_loop_2026_10_08_19_30_34.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 96 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/constraint_backup/eth_udp_loop_2026_10_08_19_30_54.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 97 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/constraint_backup/eth_udp_loop_2026_10_08_19_34_01.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 98 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/eth_udp_loop.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 99 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/eth_udp_loop.pds` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 100 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/impl.tcl` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 101 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/.last_generated` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 102 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/.settings` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 103 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/async_fifo_2048x8b.idf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 104 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/async_fifo_2048x8b.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 105 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/async_fifo_2048x8b_tb.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 106 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/async_fifo_2048x8b_tmpl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 107 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/async_fifo_2048x8b_tmpl.vhdl` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 108 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/rtl/async_fifo_2048x8b_Reset_Value.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 109 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/rtl/ipm2l_fifo_ctrl_v1_1_async_fifo_2048x8b.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 110 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/rtl/ipm2l_fifo_v1_7_async_fifo_2048x8b.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 111 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/async_fifo_2048x8b/rtl/ipm2l_sdpram_v1_6a_async_fifo_2048x8b.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 112 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/.last_generated` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 113 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/.settings` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 114 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/rtl/ipm2l_fifo_ctrl_v1_1_sync_fifo_2048x8b.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 115 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/rtl/ipm2l_fifo_v1_7_sync_fifo_2048x8b.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 116 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/rtl/ipm2l_sdpram_v1_6a_sync_fifo_2048x8b.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 117 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/rtl/sync_fifo_2048x8b_Reset_Value.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 118 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/sync_fifo_2048x8b.idf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 119 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/sync_fifo_2048x8b.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 120 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/sync_fifo_2048x8b_tb.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 121 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/sync_fifo_2048x8b_tmpl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 122 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/ipcore/sync_fifo_2048x8b/sync_fifo_2048x8b_tmpl.vhdl` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 123 | `ebf_pg2l100h_demo/50_eth_udp_loop/prj/multiseed_summary.csv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 124 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/arp/arp.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 125 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/arp/arp_rx.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 126 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/arp/arp_tx.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 127 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/arp/crc32_d8.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 128 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/eth_ctrl.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 129 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/eth_udp_loop.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 130 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/gmii_to_rgmii/gmii_to_rgmii.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 131 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/gmii_to_rgmii/rgmii_rx.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 132 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/gmii_to_rgmii/rgmii_tx.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 133 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/icmp/icmp.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 134 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/icmp/icmp_rx.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 135 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/icmp/icmp_tx.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 136 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/udp/udp.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 137 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/udp/udp_rx.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 138 | `ebf_pg2l100h_demo/50_eth_udp_loop/rtl/udp/udp_tx.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 139 | `ebf_pg2l100h_demo/50_eth_udp_loop/sim/tb/tb_udp.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 140 | `ebf_pg2l100h_demo/50_eth_udp_loop/sim/tb_udp.cr.mti` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 141 | `ebf_pg2l100h_demo/50_eth_udp_loop/sim/tb_udp.mpf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 142 | `ebf_pg2l100h_demo/50_eth_udp_loop/sim/vsim.wlf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 143 | `ebf_pg2l100h_demo/EBF_PG2L100H676_BASEBOARD_SCH.pdf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 144 | `ebf_pg2l100h_demo/ebf_pg2l100h676_baseboard_pcb.pdf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 145 | `ex_mem_reg.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 146 | `fpga/build.bat` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 147 | `fpga/build.tcl` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 148 | `fpga/build_ila.bat` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 149 | `fpga/build_ila.tcl` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 150 | `fpga/daVinciPro.xdc` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 151 | `fpga/ila_cap_done.bat` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 152 | `fpga/ila_cap_done.tcl` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 153 | `fpga/ila_cap_mark.bat` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 154 | `fpga/ila_cap_mark.tcl` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 155 | `fpga/ila_info.bat` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 156 | `fpga/ila_info.tcl` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 157 | `fpga/ila_try.bat` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 158 | `fpga/ila_try.tcl` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 159 | `fpga/jtag_probe.bat` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 160 | `fpga/jtag_probe.tcl` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 161 | `fpga/mmio_subsys.sv` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 162 | `fpga/prog_uart.bat` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 163 | `fpga/prog_uart.tcl` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 164 | `fpga/top_a100t.sv` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 165 | `fpga_mes50hp/.gitignore` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 166 | `fpga_mes50hp/README.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 167 | `fpga_mes50hp/app/digit_cli.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 168 | `fpga_mes50hp/app/digit_demo.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 169 | `fpga_mes50hp/app/evaluate_board.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 170 | `fpga_mes50hp/app/inference.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 171 | `fpga_mes50hp/app/preprocessing.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 172 | `fpga_mes50hp/app/protocol.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 173 | `fpga_mes50hp/app/requirements.txt` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 174 | `fpga_mes50hp/camera-ov7670/630f057905412416681f6090e88fc50c.png` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 175 | `fpga_mes50hp/camera-ov7670/86e6b39d2c60b681e246f9d29dc29d24.png` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 176 | `fpga_mes50hp/camera-ov7670/9f3c405863504c56dc9d27147ac2bb0a.png` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 177 | `fpga_mes50hp/camera-ov7670/de5f548f9b7c3080ce12e0280a3da70f.png` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 178 | `fpga_mes50hp/camera_lcd_debug/.gitignore` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 179 | `fpga_mes50hp/camera_lcd_debug/README.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 180 | `fpga_mes50hp/camera_lcd_debug/SOURCES.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 181 | `fpga_mes50hp/camera_lcd_debug/WIRING.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 182 | `fpga_mes50hp/camera_lcd_debug/build.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 183 | `fpga_mes50hp/camera_lcd_debug/create_project.tcl` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 184 | `fpga_mes50hp/camera_lcd_debug/generate_pins.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 185 | `fpga_mes50hp/camera_lcd_debug/mes50hp_camera_lcd.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 186 | `fpga_mes50hp/camera_lcd_debug/rtl/camera_config.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 187 | `fpga_mes50hp/camera_lcd_debug/rtl/camera_console.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 188 | `fpga_mes50hp/camera_lcd_debug/rtl/camera_fifo_capture.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 189 | `fpga_mes50hp/camera_lcd_debug/rtl/camera_framebuffer.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 190 | `fpga_mes50hp/camera_lcd_debug/rtl/camera_sccb.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 191 | `fpga_mes50hp/camera_lcd_debug/rtl/debug_keys.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 192 | `fpga_mes50hp/camera_lcd_debug/rtl/debug_uart.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 193 | `fpga_mes50hp/camera_lcd_debug/rtl/lcd_debug_video.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 194 | `fpga_mes50hp/camera_lcd_debug/rtl/top_camera_lcd_debug.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 195 | `fpga_mes50hp/camera_lcd_debug/sim/tb_capture.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 196 | `fpga_mes50hp/camera_lcd_debug/sim/tb_config.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 197 | `fpga_mes50hp/camera_lcd_debug/sim/tb_controls.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 198 | `fpga_mes50hp/camera_lcd_debug/sim/tb_video.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 199 | `fpga_mes50hp/camera_lcd_debug/uart_monitor.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 200 | `fpga_mes50hp/camera_lcd_debug/verify.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 201 | `fpga_mes50hp/camera_lcd_debug/wiring.csv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 202 | `fpga_mes50hp/create_project.bat` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 203 | `fpga_mes50hp/create_project.tcl` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 204 | `fpga_mes50hp/docs/digit_application.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 205 | `fpga_mes50hp/docs/peripheral_application_review.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 206 | `fpga_mes50hp/docs/references.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 207 | `fpga_mes50hp/firmware/bht_init.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 208 | `fpga_mes50hp/firmware/boot.S` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 209 | `fpga_mes50hp/firmware/boot.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 210 | `fpga_mes50hp/firmware/btb_zero.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 211 | `fpga_mes50hp/firmware/digit/link.ld` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 212 | `fpga_mes50hp/firmware/digit/main.c` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 213 | `fpga_mes50hp/firmware/digit/platform.c` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 214 | `fpga_mes50hp/firmware/digit/platform.h` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 215 | `fpga_mes50hp/firmware/digit/start.S` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 216 | `fpga_mes50hp/firmware/digit_dmem.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 217 | `fpga_mes50hp/firmware/digit_imem.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 218 | `fpga_mes50hp/firmware/dmem_zero.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 219 | `fpga_mes50hp/firmware/regfile_zero.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 220 | `fpga_mes50hp/generated/manifest.json` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 221 | `fpga_mes50hp/generated/profile_constraints.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 222 | `fpga_mes50hp/generated/riscv_pds.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 223 | `fpga_mes50hp/io_debug/.gitignore` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 224 | `fpga_mes50hp/io_debug/README.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 225 | `fpga_mes50hp/io_debug/build.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 226 | `fpga_mes50hp/io_debug/create_project.tcl` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 227 | `fpga_mes50hp/io_debug/mes50hp_io_debug.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 228 | `fpga_mes50hp/io_debug/rtl/debug_console.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 229 | `fpga_mes50hp/io_debug/rtl/debug_i2c_write.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 230 | `fpga_mes50hp/io_debug/rtl/debug_keys.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 231 | `fpga_mes50hp/io_debug/rtl/debug_ms7210.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 232 | `fpga_mes50hp/io_debug/rtl/debug_uart.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 233 | `fpga_mes50hp/io_debug/rtl/debug_video.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 234 | `fpga_mes50hp/io_debug/rtl/top_io_debug.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 235 | `fpga_mes50hp/io_debug/run_sim.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 236 | `fpga_mes50hp/io_debug/tb/tb_clock_health.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 237 | `fpga_mes50hp/io_debug/tb/tb_console.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 238 | `fpga_mes50hp/io_debug/tb/tb_io_debug.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 239 | `fpga_mes50hp/io_debug/uart_check.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 240 | `fpga_mes50hp/mes50hp.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 241 | `fpga_mes50hp/mes50hp_digit.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 242 | `fpga_mes50hp/model/digit_model.h` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 243 | `fpga_mes50hp/model/digit_model.npz` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 244 | `fpga_mes50hp/model/metrics.json` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 245 | `fpga_mes50hp/model/requirements-train.txt` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 246 | `fpga_mes50hp/model/sample_0.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 247 | `fpga_mes50hp/model/sample_1.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 248 | `fpga_mes50hp/model/sample_2.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 249 | `fpga_mes50hp/model/sample_3.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 250 | `fpga_mes50hp/model/sample_4.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 251 | `fpga_mes50hp/model/sample_5.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 252 | `fpga_mes50hp/model/sample_6.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 253 | `fpga_mes50hp/model/sample_7.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 254 | `fpga_mes50hp/model/sample_8.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 255 | `fpga_mes50hp/model/sample_9.hex` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 256 | `fpga_mes50hp/model/samples.json` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 257 | `fpga_mes50hp/model/train.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 258 | `fpga_mes50hp/prepare_rtl.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 259 | `fpga_mes50hp/riscv_mes50hp.pds` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 260 | `fpga_mes50hp/screen/ALINX 黑金配套4.3 TFT LCD 液晶屏模块  AN430 不含FPGA开发板.jpg` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 261 | `fpga_mes50hp/setup_tools.ps1` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 262 | `fpga_mes50hp/sources.f` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 263 | `fpga_mes50hp/src/alu.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 264 | `fpga_mes50hp/src/bht.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 265 | `fpga_mes50hp/src/branch_unit.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 266 | `fpga_mes50hp/src/btb.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 267 | `fpga_mes50hp/src/control_unit.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 268 | `fpga_mes50hp/src/core.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 269 | `fpga_mes50hp/src/csr_file.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 270 | `fpga_mes50hp/src/digit_peripherals.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 271 | `fpga_mes50hp/src/digit_video.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 272 | `fpga_mes50hp/src/dmem.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 273 | `fpga_mes50hp/src/ex_mem_reg.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 274 | `fpga_mes50hp/src/gemm_accel.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 275 | `fpga_mes50hp/src/hazard_unit.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 276 | `fpga_mes50hp/src/id_ex_reg.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 277 | `fpga_mes50hp/src/imem.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 278 | `fpga_mes50hp/src/imm_gen.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 279 | `fpga_mes50hp/src/load_store_unit.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 280 | `fpga_mes50hp/src/mem_wb_reg.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 281 | `fpga_mes50hp/src/mmio_subsys.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 282 | `fpga_mes50hp/src/muldiv.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 283 | `fpga_mes50hp/src/pc.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 284 | `fpga_mes50hp/src/ras.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 285 | `fpga_mes50hp/src/regfile.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 286 | `fpga_mes50hp/src/rv32_pkg.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 287 | `fpga_mes50hp/src/top_mes50hp.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 288 | `fpga_mes50hp/src/top_pgl22g.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 289 | `fpga_mes50hp/src/uart_rx_fifo.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 290 | `fpga_mes50hp/tools/asm.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 291 | `fpga_mes50hp/tools/build_digit.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 292 | `fpga_mes50hp/tools/build_digit_bitstream.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 293 | `fpga_mes50hp/tools/summarize_digit.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 294 | `fpga_mes50hp/tools/sv2v/LICENSE` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 295 | `fpga_mes50hp/tools/sv2v/NOTICE` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 296 | `fpga_mes50hp/tools/sv2v/README.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 297 | `fpga_mes50hp/全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-紫光同创.pdf` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 298 | `fpga_pds_1_0_9/.gitignore` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 299 | `fpga_pds_1_0_9/README.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 300 | `fpga_pds_1_0_9/create_project.bat` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 301 | `fpga_pds_1_0_9/create_project.tcl` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 302 | `fpga_pds_1_0_9/generated/manifest.json` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 303 | `fpga_pds_1_0_9/generated/riscv_pds.v` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 304 | `fpga_pds_1_0_9/prepare_rtl.py` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 305 | `fpga_pds_1_0_9/riscv.fdc` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 306 | `fpga_pds_1_0_9/riscv_pgl22g.pds` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 307 | `fpga_pds_1_0_9/setup_tools.ps1` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 308 | `fpga_pds_1_0_9/sources.f` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 309 | `fpga_pds_1_0_9/src/alu.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 310 | `fpga_pds_1_0_9/src/bht.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 311 | `fpga_pds_1_0_9/src/branch_unit.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 312 | `fpga_pds_1_0_9/src/btb.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 313 | `fpga_pds_1_0_9/src/control_unit.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 314 | `fpga_pds_1_0_9/src/core.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 315 | `fpga_pds_1_0_9/src/csr_file.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 316 | `fpga_pds_1_0_9/src/dmem.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 317 | `fpga_pds_1_0_9/src/ex_mem_reg.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 318 | `fpga_pds_1_0_9/src/gemm_accel.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 319 | `fpga_pds_1_0_9/src/hazard_unit.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 320 | `fpga_pds_1_0_9/src/id_ex_reg.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 321 | `fpga_pds_1_0_9/src/imem.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 322 | `fpga_pds_1_0_9/src/imm_gen.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 323 | `fpga_pds_1_0_9/src/load_store_unit.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 324 | `fpga_pds_1_0_9/src/mem_wb_reg.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 325 | `fpga_pds_1_0_9/src/mmio_subsys.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 326 | `fpga_pds_1_0_9/src/muldiv.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 327 | `fpga_pds_1_0_9/src/pc.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 328 | `fpga_pds_1_0_9/src/ras.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 329 | `fpga_pds_1_0_9/src/regfile.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 330 | `fpga_pds_1_0_9/src/rv32_pkg.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 331 | `fpga_pds_1_0_9/src/top_pgl22g.sv` | 第三方/历史参考 | 文本(代码/配置，无对外结论) |
| 332 | `fpga_pds_1_0_9/tools/sv2v/LICENSE` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 333 | `fpga_pds_1_0_9/tools/sv2v/NOTICE` | 第三方/历史参考 | 数据/二进制(无对外陈述) |
| 334 | `fpga_pds_1_0_9/tools/sv2v/README.md` | 第三方/历史参考 | 合规(已加范围/口径声明) |
| 335 | `fpga_pg2l100h/README.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 336 | `fpga_pg2l100h/camera_lcd_debug/.gitignore` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 337 | `fpga_pg2l100h/camera_lcd_debug/README.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 338 | `fpga_pg2l100h/camera_lcd_debug/WIRING.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 339 | `fpga_pg2l100h/camera_lcd_debug/build.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 340 | `fpga_pg2l100h/camera_lcd_debug/create_project.tcl` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 341 | `fpga_pg2l100h/camera_lcd_debug/generate_pins.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 342 | `fpga_pg2l100h/camera_lcd_debug/pg2l100h_camera_lcd.fdc` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 343 | `fpga_pg2l100h/camera_lcd_debug/pinout.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 344 | `fpga_pg2l100h/camera_lcd_debug/project_file.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 345 | `fpga_pg2l100h/camera_lcd_debug/rtl/pg2l100h_clock.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 346 | `fpga_pg2l100h/camera_lcd_debug/rtl/top_pg2l100h_camera_lcd.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 347 | `fpga_pg2l100h/camera_lcd_debug/sim/tb_board.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 348 | `fpga_pg2l100h/camera_lcd_debug/verify.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 349 | `fpga_pg2l100h/camera_lcd_debug/wiring.csv` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 350 | `fpga_pg2l100h/vision/.gitignore` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 351 | `fpga_pg2l100h/vision/ARCHITECTURE.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 352 | `fpga_pg2l100h/vision/BOARD_VALIDATION.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 353 | `fpga_pg2l100h/vision/CAMERA_DEBUG.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 354 | `fpga_pg2l100h/vision/CLOCK_SPLIT.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 355 | `fpga_pg2l100h/vision/MODES.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 356 | `fpga_pg2l100h/vision/PUBLIC12_ARCHIVE.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 357 | `fpga_pg2l100h/vision/README.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 358 | `fpga_pg2l100h/vision/VERILOG_50MHZ.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 359 | `fpga_pg2l100h/vision/build.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 360 | `fpga_pg2l100h/vision/clock_config.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 361 | `fpga_pg2l100h/vision/competition/ACCEPTANCE.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 362 | `fpga_pg2l100h/vision/competition/DEMO.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 363 | `fpga_pg2l100h/vision/competition/PROJECT.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 364 | `fpga_pg2l100h/vision/competition/REPORT_TEMPLATE.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 365 | `fpga_pg2l100h/vision/competition/VALIDATION.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 366 | `fpga_pg2l100h/vision/competition/core_portme.c` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 367 | `fpga_pg2l100h/vision/competition/core_portme.h` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 368 | `fpga_pg2l100h/vision/competition/coremark.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 369 | `fpga_pg2l100h/vision/competition/demo_cards.pdf` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 370 | `fpga_pg2l100h/vision/competition/package_project.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 371 | `fpga_pg2l100h/vision/competition/package_summary.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 372 | `fpga_pg2l100h/vision/competition/verify_coremark.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 373 | `fpga_pg2l100h/vision/firmware/link.ld` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 374 | `fpga_pg2l100h/vision/firmware/main.c` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 375 | `fpga_pg2l100h/vision/firmware/numeric_guard.h` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 376 | `fpga_pg2l100h/vision/firmware/numeric_main.c` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 377 | `fpga_pg2l100h/vision/firmware/start.S` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 378 | `fpga_pg2l100h/vision/model/COCO80_FEASIBILITY.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 379 | `fpga_pg2l100h/vision/model/DATASET.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 380 | `fpga_pg2l100h/vision/model/GESTURES.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 381 | `fpga_pg2l100h/vision/model/GESTURE_STANDARD.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 382 | `fpga_pg2l100h/vision/model/OPEN_SOURCE_MODELS.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 383 | `fpga_pg2l100h/vision/model/PUBLIC12_DATASET_ARCHIVE.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 384 | `fpga_pg2l100h/vision/model/PUBLIC12_TRAINING_REPORT_ARCHIVE.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 385 | `fpga_pg2l100h/vision/model/TRAINING_REPORT.md` | 交付主体文档 | 合规(已加范围/口径声明) |
| 386 | `fpga_pg2l100h/vision/model/audit_coco.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 387 | `fpga_pg2l100h/vision/model/baselines/digits/biases.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 388 | `fpga_pg2l100h/vision/model/baselines/digits/micro_yolo.npz` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 389 | `fpga_pg2l100h/vision/model/baselines/digits/model.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 390 | `fpga_pg2l100h/vision/model/baselines/digits/shifts.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 391 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/input_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 392 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/input_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 393 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/input_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 394 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/input_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 395 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/input_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 396 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/input_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 397 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/input_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 398 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/input_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 399 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/output_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 400 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/output_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 401 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/output_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 402 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/output_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 403 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/output_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 404 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/output_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 405 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/output_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 406 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/output_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 407 | `fpga_pg2l100h/vision/model/baselines/digits/vectors/reference_detections.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 408 | `fpga_pg2l100h/vision/model/baselines/digits/weights.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 409 | `fpga_pg2l100h/vision/model/biases.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 410 | `fpga_pg2l100h/vision/model/camera_preprocess.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 411 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/biases.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 412 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/micro_yolo.npz` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 413 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/model.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 414 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/shifts.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 415 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/input_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 416 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/input_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 417 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/input_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 418 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/input_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 419 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/input_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 420 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/input_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 421 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/input_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 422 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/input_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 423 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/output_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 424 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/output_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 425 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/output_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 426 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/output_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 427 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/output_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 428 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/output_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 429 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/output_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 430 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/output_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 431 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/vectors/reference_detections.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 432 | `fpga_pg2l100h/vision/model/candidates/gesture_gray/weights.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 433 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/biases.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 434 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/micro_yolo.npz` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 435 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/model.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 436 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/shifts.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 437 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/training_report.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 438 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/input_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 439 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/input_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 440 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/input_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 441 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/input_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 442 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/input_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 443 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/input_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 444 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/input_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 445 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/input_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 446 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/output_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 447 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/output_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 448 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/output_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 449 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/output_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 450 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/output_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 451 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/output_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 452 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/output_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 453 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/output_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 454 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/vectors/reference_detections.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 455 | `fpga_pg2l100h/vision/model/candidates/numeric_hardneg/weights.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 456 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/biases.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 457 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/micro_yolo.npz` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 458 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/model.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 459 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/shifts.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 460 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/training_report.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 461 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/input_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 462 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/input_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 463 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/input_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 464 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/input_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 465 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/input_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 466 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/input_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 467 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/input_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 468 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/input_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 469 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/output_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 470 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/output_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 471 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/output_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 472 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/output_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 473 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/output_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 474 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/output_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 475 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/output_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 476 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/output_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 477 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/vectors/reference_detections.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 478 | `fpga_pg2l100h/vision/model/candidates/numeric_labels/weights.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 479 | `fpga_pg2l100h/vision/model/candidates/numguard/biases.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 480 | `fpga_pg2l100h/vision/model/candidates/numguard/micro_yolo.npz` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 481 | `fpga_pg2l100h/vision/model/candidates/numguard/model.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 482 | `fpga_pg2l100h/vision/model/candidates/numguard/shifts.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 483 | `fpga_pg2l100h/vision/model/candidates/numguard/training_report.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 484 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/input_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 485 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/input_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 486 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/input_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 487 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/input_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 488 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/input_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 489 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/input_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 490 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/input_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 491 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/input_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 492 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/output_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 493 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/output_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 494 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/output_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 495 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/output_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 496 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/output_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 497 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/output_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 498 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/output_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 499 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/output_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 500 | `fpga_pg2l100h/vision/model/candidates/numguard/vectors/reference_detections.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 501 | `fpga_pg2l100h/vision/model/candidates/numguard/weights.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 502 | `fpga_pg2l100h/vision/model/candidates/public12/biases.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 503 | `fpga_pg2l100h/vision/model/candidates/public12/micro_yolo.npz` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 504 | `fpga_pg2l100h/vision/model/candidates/public12/model.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 505 | `fpga_pg2l100h/vision/model/candidates/public12/shifts.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 506 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/input_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 507 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/input_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 508 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/input_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 509 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/input_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 510 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/input_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 511 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/input_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 512 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/input_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 513 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/input_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 514 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/output_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 515 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/output_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 516 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/output_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 517 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/output_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 518 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/output_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 519 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/output_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 520 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/output_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 521 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/output_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 522 | `fpga_pg2l100h/vision/model/candidates/public12/vectors/reference_detections.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 523 | `fpga_pg2l100h/vision/model/candidates/public12/weights.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 524 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/biases.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 525 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/micro_yolo.npz` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 526 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/model.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 527 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/shifts.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 528 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/input_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 529 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/input_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 530 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/input_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 531 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/input_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 532 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/input_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 533 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/input_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 534 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/input_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 535 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/input_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 536 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/output_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 537 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/output_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 538 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/output_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 539 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/output_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 540 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/output_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 541 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/output_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 542 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/output_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 543 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/output_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 544 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/vectors/reference_detections.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 545 | `fpga_pg2l100h/vision/model/candidates/public12_hardneg/weights.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 546 | `fpga_pg2l100h/vision/model/candidates/public22/biases.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 547 | `fpga_pg2l100h/vision/model/candidates/public22/micro_yolo.npz` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 548 | `fpga_pg2l100h/vision/model/candidates/public22/model.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 549 | `fpga_pg2l100h/vision/model/candidates/public22/shifts.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 550 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/input_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 551 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/input_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 552 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/input_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 553 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/input_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 554 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/input_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 555 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/input_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 556 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/input_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 557 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/input_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 558 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/output_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 559 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/output_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 560 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/output_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 561 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/output_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 562 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/output_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 563 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/output_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 564 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/output_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 565 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/output_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 566 | `fpga_pg2l100h/vision/model/candidates/public22/vectors/reference_detections.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 567 | `fpga_pg2l100h/vision/model/candidates/public22/weights.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 568 | `fpga_pg2l100h/vision/model/fetch_reference_weights.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 569 | `fpga_pg2l100h/vision/model/font5x7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 570 | `fpga_pg2l100h/vision/model/gesture/LICENSE.txt` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 571 | `fpga_pg2l100h/vision/model/gesture/biases.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 572 | `fpga_pg2l100h/vision/model/gesture/dataset_provenance.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 573 | `fpga_pg2l100h/vision/model/gesture/micro_yolo.npz` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 574 | `fpga_pg2l100h/vision/model/gesture/model.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 575 | `fpga_pg2l100h/vision/model/gesture/shifts.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 576 | `fpga_pg2l100h/vision/model/gesture/vectors/input_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 577 | `fpga_pg2l100h/vision/model/gesture/vectors/input_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 578 | `fpga_pg2l100h/vision/model/gesture/vectors/input_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 579 | `fpga_pg2l100h/vision/model/gesture/vectors/input_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 580 | `fpga_pg2l100h/vision/model/gesture/vectors/input_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 581 | `fpga_pg2l100h/vision/model/gesture/vectors/input_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 582 | `fpga_pg2l100h/vision/model/gesture/vectors/input_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 583 | `fpga_pg2l100h/vision/model/gesture/vectors/input_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 584 | `fpga_pg2l100h/vision/model/gesture/vectors/output_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 585 | `fpga_pg2l100h/vision/model/gesture/vectors/output_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 586 | `fpga_pg2l100h/vision/model/gesture/vectors/output_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 587 | `fpga_pg2l100h/vision/model/gesture/vectors/output_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 588 | `fpga_pg2l100h/vision/model/gesture/vectors/output_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 589 | `fpga_pg2l100h/vision/model/gesture/vectors/output_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 590 | `fpga_pg2l100h/vision/model/gesture/vectors/output_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 591 | `fpga_pg2l100h/vision/model/gesture/vectors/output_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 592 | `fpga_pg2l100h/vision/model/gesture/vectors/reference_detections.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 593 | `fpga_pg2l100h/vision/model/gesture/weights.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 594 | `fpga_pg2l100h/vision/model/gesture_standard.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 595 | `fpga_pg2l100h/vision/model/make_font.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 596 | `fpga_pg2l100h/vision/model/micro_yolo.npz` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 597 | `fpga_pg2l100h/vision/model/model.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 598 | `fpga_pg2l100h/vision/model/network.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 599 | `fpga_pg2l100h/vision/model/prepare_gesture_dataset.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 600 | `fpga_pg2l100h/vision/model/prepare_public_dataset.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 601 | `fpga_pg2l100h/vision/model/preview_public.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 602 | `fpga_pg2l100h/vision/model/requirements.txt` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 603 | `fpga_pg2l100h/vision/model/select_model.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 604 | `fpga_pg2l100h/vision/model/shifts.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 605 | `fpga_pg2l100h/vision/model/train.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 606 | `fpga_pg2l100h/vision/model/train_dataset.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 607 | `fpga_pg2l100h/vision/model/train_numeric.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 608 | `fpga_pg2l100h/vision/model/train_public.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 609 | `fpga_pg2l100h/vision/model/vectors/input_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 610 | `fpga_pg2l100h/vision/model/vectors/input_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 611 | `fpga_pg2l100h/vision/model/vectors/input_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 612 | `fpga_pg2l100h/vision/model/vectors/input_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 613 | `fpga_pg2l100h/vision/model/vectors/input_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 614 | `fpga_pg2l100h/vision/model/vectors/input_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 615 | `fpga_pg2l100h/vision/model/vectors/input_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 616 | `fpga_pg2l100h/vision/model/vectors/input_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 617 | `fpga_pg2l100h/vision/model/vectors/output_0.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 618 | `fpga_pg2l100h/vision/model/vectors/output_1.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 619 | `fpga_pg2l100h/vision/model/vectors/output_2.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 620 | `fpga_pg2l100h/vision/model/vectors/output_3.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 621 | `fpga_pg2l100h/vision/model/vectors/output_4.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 622 | `fpga_pg2l100h/vision/model/vectors/output_5.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 623 | `fpga_pg2l100h/vision/model/vectors/output_6.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 624 | `fpga_pg2l100h/vision/model/vectors/output_7.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 625 | `fpga_pg2l100h/vision/model/vectors/reference_detections.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 626 | `fpga_pg2l100h/vision/model/weights.hex` | 交付主体文档 | 数据/二进制(无对外陈述) |
| 627 | `fpga_pg2l100h/vision/rtl/camera_dvp_capture.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 628 | `fpga_pg2l100h/vision/rtl/cpu/alu.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 629 | `fpga_pg2l100h/vision/rtl/cpu/bht.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 630 | `fpga_pg2l100h/vision/rtl/cpu/branch_unit.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 631 | `fpga_pg2l100h/vision/rtl/cpu/btb.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 632 | `fpga_pg2l100h/vision/rtl/cpu/control_unit.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 633 | `fpga_pg2l100h/vision/rtl/cpu/core.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 634 | `fpga_pg2l100h/vision/rtl/cpu/csr_file.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 635 | `fpga_pg2l100h/vision/rtl/cpu/dmem.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 636 | `fpga_pg2l100h/vision/rtl/cpu/ex_mem_reg.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 637 | `fpga_pg2l100h/vision/rtl/cpu/hazard_unit.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 638 | `fpga_pg2l100h/vision/rtl/cpu/id_ex_reg.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 639 | `fpga_pg2l100h/vision/rtl/cpu/imem.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 640 | `fpga_pg2l100h/vision/rtl/cpu/imm_gen.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 641 | `fpga_pg2l100h/vision/rtl/cpu/load_store_unit.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 642 | `fpga_pg2l100h/vision/rtl/cpu/mem_wb_reg.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 643 | `fpga_pg2l100h/vision/rtl/cpu/muldiv.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 644 | `fpga_pg2l100h/vision/rtl/cpu/pc.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 645 | `fpga_pg2l100h/vision/rtl/cpu/provenance.json` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 646 | `fpga_pg2l100h/vision/rtl/cpu/ras.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 647 | `fpga_pg2l100h/vision/rtl/cpu/regfile.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 648 | `fpga_pg2l100h/vision/rtl/top_pg2l100h_vision.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 649 | `fpga_pg2l100h/vision/rtl/vision_cpu_clock.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 650 | `fpga_pg2l100h/vision/rtl/vision_framebuffer.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 651 | `fpga_pg2l100h/vision/rtl/vision_lcd.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 652 | `fpga_pg2l100h/vision/rtl/vision_mmio_bridge.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 653 | `fpga_pg2l100h/vision/rtl/vision_npu.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 654 | `fpga_pg2l100h/vision/rtl/vision_snapshot.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 655 | `fpga_pg2l100h/vision/rtl/vision_soc.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 656 | `fpga_pg2l100h/vision/rtl/vision_video_bridge.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 657 | `fpga_pg2l100h/vision/sim/tb_board.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 658 | `fpga_pg2l100h/vision/sim/tb_camera.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 659 | `fpga_pg2l100h/vision/sim/tb_camera_dvp.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 660 | `fpga_pg2l100h/vision/sim/tb_cdc.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 661 | `fpga_pg2l100h/vision/sim/tb_coremark.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 662 | `fpga_pg2l100h/vision/sim/tb_cpu_mmio.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 663 | `fpga_pg2l100h/vision/sim/tb_lcd.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 664 | `fpga_pg2l100h/vision/sim/tb_muldiv.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 665 | `fpga_pg2l100h/vision/sim/tb_npu.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 666 | `fpga_pg2l100h/vision/sim/tb_snapshot.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 667 | `fpga_pg2l100h/vision/sim/tb_snapshot_hand.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 668 | `fpga_pg2l100h/vision/sim/tb_soc.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 669 | `fpga_pg2l100h/vision/sim/tb_soc_hand.v` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 670 | `fpga_pg2l100h/vision/sim/test_cpu_mmio.c` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 671 | `fpga_pg2l100h/vision/sim/test_cpu_mmio.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 672 | `fpga_pg2l100h/vision/sim/test_hand_firmware.c` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 673 | `fpga_pg2l100h/vision/sim/test_hand_firmware.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 674 | `fpga_pg2l100h/vision/sim/test_numeric_guard.c` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 675 | `fpga_pg2l100h/vision/sim/test_tools.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 676 | `fpga_pg2l100h/vision/sim/test_training_data.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 677 | `fpga_pg2l100h/vision/tools/capture_numeric.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 678 | `fpga_pg2l100h/vision/tools/evaluate_numeric.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 679 | `fpga_pg2l100h/vision/tools/make_demo_cards.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 680 | `fpga_pg2l100h/vision/tools/preview_gestures.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 681 | `fpga_pg2l100h/vision/tools/preview_numeric.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 682 | `fpga_pg2l100h/vision/verify.py` | 交付主体文档 | 文本(代码/配置，无对外结论) |
| 683 | `gemm_accel.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 684 | `hazard_unit.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 685 | `id_ex_reg.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 686 | `imem.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 687 | `imm_gen.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 688 | `impl.pds` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 689 | `load_store_unit.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 690 | `mem_wb_reg.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 691 | `muldiv.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 692 | `pc.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 693 | `ras.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 694 | `regfile.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 695 | `results/CHANGELOG.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 696 | `results/COMPETITION-PLAN.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 697 | `results/DESIGN-REPORT.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 698 | `results/FREQ-VERDICT.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 699 | `results/NEXT-BURN.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 700 | `results/analysis-report.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 701 | `results/baseline-v1.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 702 | `results/bram-v1.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 703 | `results/branch-pred-v1.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 704 | `results/branch-pred-v2.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 705 | `results/coremark.csv` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 706 | `results/flash_done.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 707 | `results/gap-analysis.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 708 | `results/hw-run-expectation.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 709 | `results/hw-runout.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 710 | `results/hw-verified.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 711 | `results/ila_done.csv` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 712 | `results/ila_pipeline.csv` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 713 | `results/m-ext-v1.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 714 | `results/p2-timer-irq.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 715 | `results/p3-fmax.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 716 | `results/p3-imem.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 717 | `results/p3-load-result.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 718 | `results/p4-c1-2stage-gshare.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 719 | `results/p4-gshare.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 720 | `results/p4-macro-failure.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 721 | `results/p4-ras.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 722 | `results/p5-ai-accelerator.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 723 | `results/p5-compiler-bug.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 724 | `results/p6-a-extension.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 725 | `results/p7-cache-analysis.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 726 | `results/p8-ifid-elide.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 727 | `results/pg2l100h_schematic/j11.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 728 | `results/pg2l100h_schematic/j7.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 729 | `results/pg2l100h_schematic/page_1.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 730 | `results/pg2l100h_schematic/page_1.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 731 | `results/pg2l100h_schematic/page_2.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 732 | `results/pg2l100h_schematic/page_2.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 733 | `results/pg2l100h_schematic/page_3.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 734 | `results/pg2l100h_schematic/page_3.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 735 | `results/pg2l100h_schematic/page_4.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 736 | `results/pg2l100h_schematic/page_4.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 737 | `results/pg2l100h_schematic/page_5.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 738 | `results/pg2l100h_schematic/page_5.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 739 | `results/pg2l100h_schematic/page_6.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 740 | `results/pg2l100h_schematic/page_6.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 741 | `results/pg2l100h_schematic/page_7.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 742 | `results/pg2l100h_schematic/page_7.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 743 | `results/pg2l100h_schematic/page_8.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 744 | `results/pg2l100h_schematic/page_8.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 745 | `results/pg2l100h_schematic/page_9.png` | 证据/迭代文档 | 数据/二进制(无对外陈述) |
| 746 | `results/pg2l100h_schematic/page_9.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 747 | `results/pg2l100h_schematic/pll_guide.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 748 | `results/review-fixes-v1.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 749 | `results/rvcorep-reading-guide.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 750 | `results/rvcorep-vs-ours.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 751 | `results/style-audit.md` | 证据/迭代文档 | 合规(已加范围/口径声明) |
| 752 | `results/uart_boot.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 753 | `results/uart_cm_final.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 754 | `results/uart_done.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 755 | `results/uart_done_138.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 756 | `results/uart_final150.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 757 | `results/uart_flash_boot_final.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 758 | `results/uart_scoreprint.txt` | 证据/迭代文档 | 文本(代码/配置，无对外结论) |
| 759 | `rv32_pkg.sv` | 开发/交接文档 | 文本(代码/配置，无对外结论) |
| 760 | `sim/prog/_csr_probe.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 761 | `sim/prog/amo.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 762 | `sim/prog/amo_diag.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 763 | `sim/prog/amo_diag2.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 764 | `sim/prog/amo_vectors.hex` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 765 | `sim/prog/basic.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 766 | `sim/prog/lu_bench.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 767 | `sim/prog/m_ext.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 768 | `sim/prog/mmio.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 769 | `sim/prog/timer_irq.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 770 | `sim/prog/trap.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 771 | `sim/run.bat` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 772 | `sim/run.sh` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 773 | `sim/run_prog.py` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 774 | `sim/tb_core.sv` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 775 | `sim/tb_soc.sv` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 776 | `sim/tb_sw.sv` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 777 | `sim/tb_units.sv` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 778 | `skills/fpga-riscv-a100t/OPTIMIZATION-PLAYBOOK.md` | 工具/开发文档 | 合规(已加范围/口径声明) |
| 779 | `skills/fpga-riscv-a100t/PITFALLS.md` | 工具/开发文档 | 合规(已加范围/口径声明) |
| 780 | `skills/fpga-riscv-a100t/SKILL.md` | 工具/开发文档 | 合规(已加范围/口径声明) |
| 781 | `skills/fpga-workflow/SKILL.md` | 工具/开发文档 | 合规(已加范围/口径声明) |
| 782 | `sw/coremark/LICENSE.md` | Artix-7 对比线 | 合规(已加范围/口径声明) |
| 783 | `sw/coremark/README.md` | Artix-7 对比线 | 合规(已加范围/口径声明) |
| 784 | `sw/coremark/core_list_join.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 785 | `sw/coremark/core_main.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 786 | `sw/coremark/core_matrix.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 787 | `sw/coremark/core_portme.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 788 | `sw/coremark/core_portme.h` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 789 | `sw/coremark/core_state.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 790 | `sw/coremark/core_util.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 791 | `sw/coremark/coremark.h` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 792 | `sw/coremark/ee_printf.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 793 | `sw/crt0.S` | Artix-7 对比线 | 数据/二进制(无对外陈述) |
| 794 | `sw/hello.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 795 | `sw/libc_min.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 796 | `sw/link.ld` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 797 | `sw/nn_demo.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 798 | `sw/opt_probe.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 799 | `sw/portme.c` | Artix-7 对比线 | 文本(代码/配置，无对外结论) |
| 800 | `tools/README.md` | 工具/开发文档 | 合规(已加范围/口径声明) |
| 801 | `tools/amo_vectors.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 802 | `tools/asm.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 803 | `tools/build_sw.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 804 | `tools/check_equiv.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 805 | `tools/compliance_check.py` | 工具/开发文档 | 新增合规检查器 |
| 806 | `tools/doctor.bat` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 807 | `tools/elf2hex.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 808 | `tools/flash_boot.ps1` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 809 | `tools/flash_logs/REPORT.md` | 工具/开发文档 | 合规(已加 Artix 声明 + Pango Flash 状态) |
| 810 | `tools/flash_logs/help.txt` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 811 | `tools/flash_logs/part_props.txt` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 812 | `tools/flash_logs/probe2_ramp.mcs` | 工具/开发文档 | 数据/二进制(无对外陈述) |
| 813 | `tools/flash_logs/probe3_onebyte32.mcs` | 工具/开发文档 | 数据/二进制(无对外陈述) |
| 814 | `tools/flash_logs/probe_pattern.mcs` | 工具/开发文档 | 数据/二进制(无对外陈述) |
| 815 | `tools/flash_logs/sweep_results.csv` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 816 | `tools/flash_mkimage.tcl` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 817 | `tools/flash_partcheck.tcl` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 818 | `tools/flash_probe.tcl` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 819 | `tools/flash_program.tcl` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 820 | `tools/flash_readback.tcl` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 821 | `tools/flash_run.ps1` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 822 | `tools/flash_sweep.ps1` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 823 | `tools/fpga_workflow.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 824 | `tools/ftdi_probe.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 825 | `tools/hier_util.tcl` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 826 | `tools/mk_cm_hw.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 827 | `tools/path_families.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 828 | `tools/path_hotspot.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 829 | `tools/pdf_mine.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 830 | `tools/pdf_text.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 831 | `tools/run_coremark.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 832 | `tools/sweep_clk.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 833 | `tools/sweep_pblock_place.ps1` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 834 | `tools/trace_diff.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |
| 835 | `tools/uart_capture.py` | 工具/开发文档 | 文本(代码/配置，无对外结论) |

## 4. 已知风险文件与处置（人工复核）

| 文件 | 风险点 | 处置 |
|---|---|---|
| `tools/flash_logs/REPORT.md` | 原文"达芬奇Pro QSPI Flash 已写入"易被误读为 Pango Flash 状态 | 已加范围声明（Artix 线）并交叉引用 Pango 未写入状态 |
| `fpga_pg2l100h/vision/competition/DEMO.md` | 含"零误检/通用YOLO"字样 | 实为"不能宣称"的负面清单；已加交付主体范围声明，保持原文 |
| `fpga_pg2l100h/vision/model/PUBLIC12_TRAINING_REPORT_ARCHIVE.md` | 含"通用 YOLO/保证"字样 | 实为局限性说明；已加交付主体范围声明 |
| `results/*`（Artix 实测数据） | 324.19/405.9 等易与交付成绩混淆 | 已加证据/对比范围声明；引用时必须带级别（324.19=A 实测旧固件，405.9=D 派生未上板） |
| 根目录 `CODE-MAP/HANDOFF*` 等 | 大量历史 Artix 实测断言 | 已加开发/交接文档性质声明 |
| `fpga_mes50hp/**`、`ebf_pg2l100h_demo/**` | 第三方/历史工程结论 | 已加参考资料声明，不进入交付成绩 |
| `fpga_pg2l100h/**` 的未达成项（Flash/手势/COCO80/报告视频） | 不能被当作已完成 | 按 `COMPLIANCE.md` §4 边界清单在报告/演示中显式声明 |