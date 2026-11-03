# 第三方与参考资料（THIRD_PARTY.md）

本仓库根目录保留以下第三方/参考目录。**它们保持在根目录是有意的路径依赖**，请不要移动：

| 目录 | 来源/用途 | 路径依赖（移动会破坏构建） |
|---|---|---|
| `ebf_pg2l100h_demo/` | EBF PG2L100H676 底板厂商示例（HDMI/ETH 参考工程、底板原理图、PDS 工程模板） | `fpga_pg2l100h/camera_lcd_debug/project_file.py`：`ROOT.parents[1] / "ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/hdmi_colorbar.pds"` |
| `fpga_mes50hp/` | 早期 MES50HP(PGL50H) 开发工程（摄像头/LCD/UART 相关脚本与参考） | `fpga_pg2l100h/camera_lcd_debug/build.py`：`COMMON = ROOT.parents[1] / "fpga_mes50hp/camera_lcd_debug"` |
| `fpga_pds_1_0_9/` | 原 PGL22G 工程迁移基线（兼容留档） | 无构建依赖；被 `fpga_mes50hp/README.md` 文档引用 |

各目录内的 README/许可证/来源说明保持原样。`archive/pds/`（原 `fpga_pds/`）为旧 PDS 实验工程，无构建依赖。

> 赛题要求交付主体为紫光同创器件；上述第三方目录仅作板卡参考/工具链迁移依据，不改变交付主体。
