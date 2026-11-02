# Verilog / 50 MHz 移植记录

更新日期：2026-11-02。应用入口为 `build/j11/pg2l100h_vision.pds`，顶层为 `top_pg2l100h_vision`。

## 源码与范围

盘古100H当前活动工程使用32份 `.v` RTL，包含19个CPU模块；活动源码和PDS注册文件均不再包含 `.sv`。CPU源码位于 `rtl/cpu/`，SoC位于 `rtl/vision_soc.v`。这次进行了语法转换和包常量展开，保留原RV32IM流水线、预测器、CSR、乘除法和存储器逻辑。`rv32_pkg.sv` 中使用到的定义已展开到模块内，无需额外的Verilog包文件。

CPU转换来源和原始文件SHA256记录在 `rtl/cpu/provenance.json`。初次转换采用随原工程提供的sv2v；当前工程构建直接读取这些Verilog文件，后续修改也应直接编辑 `.v`，构建过程不再调用sv2v。

原MES50HP、Xilinx及旧PDS参考目录继续保存历史源码和跑分。100H构建不读取这些目录中的SystemVerilog文件。共享SCCB/UART模块本身为Verilog；当前实物18针DVP采集使用 `rtl/camera_dvp_capture.v`，不读取历史FIFO采集模块。

## 时钟

| 用途 | 频率 / 配置 |
|---|---|
| 板载晶振、CPU、NPU、MMIO、相机采集状态机 | 50 MHz，周期20 ns |
| 视频扫描与双缓冲读端 | PLL由50 MHz生成27 MHz |
| AN430像素DCLK | 视频域三分频，9 MHz |
| 相机MCLK | 50 MHz四分频，12.5 MHz；J7-8 / T17输出 |
| DVP采样 | 50 MHz域同步PCLK/HREF/VSYNC及数据，按PCLK上升沿组装RGB565 |
| 相机速度 | CLKRC=03，实际PCLK速度待测 |
| 传感器启动 | PWDN=0，MCLK启动1 ms后释放RESET，再等待50 ms |
| SCCB | 50 kHz，检查应答及PID/版本 |
| UART | 115200 / 8N1 |
| 按键去抖、相机超时、固件结果超时 | 20 ms、1 s、1 s |

`clock_config.json` 记录当前固定配置，构建器据此生成固件的 `platform_clock.h` 和工程清单。CPU直接使用板上50 MHz；PLL只服务于视频域。LCD时序仍为525×286总像素、480×272有效像素，刷新约59.94 Hz。

NPU的每次完整推理仍为1769238周期，50 MHz下纯计算时间为35.38476 ms。该值不包含相机帧等待、DVP采集、CPU后处理、三次业务确认和LCD提交，不能作为实测摄像头帧率。

## 跨时钟交接

`vision_framebuffer.v` 的写端使用50 MHz，读端使用27 MHz；两端通过请求/确认翻转位和两级同步器交接缓冲区所有权。LCD只在帧起始切换前台，采集端收到确认后才复用旧前台。等待确认时禁止后续写入，重配摄像头时同步清除两端有效标志。

`vision_video_bridge.v` 把框坐标、类别、业务状态、计数、视频控制和128位摄像头诊断合成272位完整数据包。源端保持数据直到确认，目的端在帧边界一次性更新显示数据。视频帧事件通过翻转位返回50 MHz，避免漏掉窄脉冲。显示交接可能多等待一帧，端到端延迟仍需上板测量。诊断字段新增PCLK、HREF和坏帧计数；字段和CAM WAIT/CAM ERR的区别见 `CAMERA_DEBUG.md`。

当前J11约束包含50 MHz输入、27 MHz视频、9 MHz像素和12.5 MHz相机MCLK。DVP输入到同步器首级为异步路径，后续同步器和采集逻辑继续计时；保持的数据包通路约束最大20 ns。原生PDS已完成本版时序检查，但该检查不测量外部PCLK频率、数据相位或实物连接。J12与备用CoreMark保留历史产物，本轮没有重建其DVP版本。

## 验证与已有跑分

`verify.py` 的完整回归包括13项：严格Verilog-2005编译、核验状态机、协议工具、训练数据、灰度快照、手势轮廓快照、272位跨时钟交接、DVP摄像头采样、LCD、双模型INT8逐值对照、RV32标签整机、RV32手势切换整机和实际Pango PLL模型。此前DVP采集版全部通过，报告保存在 `validation/hardware_20261102/dvp18_20261102_194149/simulation_summary.json`。本次传感器180度旋转修改执行Verilog及板级两项检查，当前 `validation/simulation_summary.json` 只记录这两项。

跨时钟测试覆盖272位数据包一致性、帧边界提交、事件脉冲、双缓冲所有权、待确认写保护和复位。DVP测试使用与50 MHz非整数相位关系的PCLK，核对高低字节顺序和抽样，同时覆盖无图像同步脉冲、短行、奇数字节、完整帧、冻结、超时及配置失效。固件整机测试检查 `VISION50 READY` 启动串、115200串口命令、模型输入4096字节和最终检测框。手势整机覆盖忙时模式切换和旧结果取消；板级模型额外核对12.5 MHz MCLK、RESET/PWDN和SW4短按/长按。

新增手势1～9不改变时钟或RTL语言，使用第二组权重ROM与同一NPU。权重固定容量由32 KiB增至64 KiB，偏置由1 KiB增至2 KiB，激活RAM不增加。手势单次计算同为1769238周期。手势模型仍是低精度实验版本，不能用算术仿真通过替代识别能力评估，详见 `model/GESTURES.md`。

使用者已完成CoreMark跑分。原始成绩和测试条件保留，本轮不要求重新跑分，也未用短仿真成绩覆盖原记录。备用CoreMark工程和移植层已同步为50 MHz；历史短迭代日志仍属于此前27 MHz版本。

## 目标工具状态

2026-11-02本机 `E:/pango/PDS_2022.2-SP6.1` 完成旋转版PG2L100H实际构建，All Constraints Met，clk50建立WNS为8.111 ns。映射为LUT 4248、FF 3460、APM 13、DRM 65。MVFP=37在传感器输出端统一旋转LCD预览与模型输入，此前许可证失败日志属于历史记录。

跨时钟复位同步器异步预置端采用 `video_reset_sync[*]/P` 和 `framebuffer/reset_sync[*]/P` 例外；同步器D/Q与下游同步释放路径继续计时。PDS自动重写工程元数据后更新该文件artifact哈希。当前两项相关回归、原生PDS构建及构建后源/固件/ROM和约束校验通过，先前完整回归另行保留。需要重新构建时执行：

```powershell
python fpga_pg2l100h/vision/build.py --pds-home E:/pango/PDS_2022.2-SP6.1
```

脚本仍要求产生新的位流且布局布线后所有时序约束通过，才报告硬件构建成功。

20:03:24（Asia/Shanghai）已将180度旋转位流JTAG下载到PG2L100H（ID 0x00602899），DONE=1、done_i=1、配置错误位为0。用户此前实拍已确认摄像头初始化成功且有画面；本次旋转后是否正立仍待确认。over_temp状态位及实际温度尚未核实，完整识别验收待完成，详见 `BOARD_VALIDATION.md`。
