> **范围/口径声明（交付主体）**：本文属于**紫光同创 PG2L100H** 交付主体线。文中"实测"指上板实测并应附证据路径；"未达成/未部署"项见根 [`COMPLIANCE.md`](https://github.com/fgjg70/FPGA/blob/main/COMPLIANCE.md) §4 边界清单。注意：**Pango 侧 Flash 当前尚未写入**（JTAG RAM 下载），详见 [`fpga_pg2l100h/vision/BOARD_VALIDATION.md`](https://github.com/fgjg70/FPGA/blob/main/fpga_pg2l100h/vision/BOARD_VALIDATION.md)。

# 盘古 100H 移植工程

目标板：`ebf_pg2l100h_demo` 对应的 EBF PG2L100H676，器件为 **Logos2 / PG2L100H / -6 / FBG676**。

第一阶段历史工程位于 [camera_lcd_debug](camera_lcd_debug/README.md)，面向资料中的22针OV7670 FIFO模块。用户当前实物为18针DVP模块，当前上板入口使用下述vision工程及其接线表。

参赛应用位于 [vision](vision/README.md)：按紫光同创指南的RISC-V CPU选题，聚焦NUMGUARD数字料箱标签防错核验，十类数字0～9，支持工单比对、连续确认、去重计数和LCD英文状态。复用原MES50HP的CPU，CPU/NPU和采集统一50 MHz，全部活动RTL为Verilog，LCD像素9 MHz。J11工程为 `vision/build/j11/pg2l100h_vision.pds`。打印标签为主场景，手写数字为扩展；新增手势1～9专用模型的实验模式，当前验证效果较弱，报告见 `vision/model/GESTURES.md`。人、车、杯子混合模型保留为历史资料。

2026-11-02已完成目标PDS综合、布局布线、50 MHz时序收敛和JTAG实际下载，芯片DONE=1、配置CRC/ID错误位为0。当前未接通板载CH340串口，摄像头/LCD/手势应用验收和温度检查仍待完成；实际记录见 `vision/BOARD_VALIDATION.md`，不能以配置成功代替识别效果或国赛成绩。

原 MES50HP 项目实际文件名为 `fpga_mes50hp/riscv_mes50hp.pds`。本阶段复用 `fpga_mes50hp/camera_lcd_debug/rtl` 的外设调试逻辑，新增 100H 板级封装和独立构建目录。原工程不需要修改。

**当前摄像头实物及J7均为18针，vision约束按1接1至18接18重映射；J7-1为3.3V、J7-2为GND。旧22针FIFO转接表停用。接线以 `vision/build/j11/WIRING.md` 和 `vision/CAMERA_DEBUG.md` 为准。LCD接J11；J12与备用CoreMark目录保留历史产物，本轮DVP变更仅重新构建J11应用。**
