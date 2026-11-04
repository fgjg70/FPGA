# 三功能瓶盖分拣工程（2026-11-04）

活动工程：`build/dual_caps_sorter128_j11/pg2l100h_vision.pds`。配置为 PG2L100H、95 MHz 双发射 RISC-V、50 MHz 128 MAC NPU、片内模型与特征存储，不使用 DDR。功能为 CoreMark、手势识别、瓶盖识别；瓶盖和手势使用各自的 INT8 模型 bank。

## 功能选择

| 操作 | 功能 |
|---|---|
| 上电或 SW2 | 复位，优先进入瓶盖模式 |
| SW4 / 串口 `k` | 停止自动分拣、舵机回位，执行同一固件内的 CoreMark |
| SW5 / 串口 `p` | 瓶盖识别并启用自动分拣，重新开始 5 秒计时 |
| SW6 / 串口 `g` | 手势 1～5 识别，退出自动分拣并回位 |
| 串口 `m` | 在瓶盖和手势之间切换 |
| 串口 `s0=0` 加回车 | 关闭全部 PWM，暂停自动分拣；重新选择瓶盖恢复 |

摄像头 OV7670 接 J7，LCD 接 J11，舵机信号接 J12。串口为 115200、8N1。CoreMark 仍按官方 CRC 和至少 10 秒计时判定有效；本次修改没有生成新的实板跑分成绩。

## 舵机分配

| 舵机 | 瓶盖模式用途 | FPGA 管脚 |
|---|---|---|
| 1 | 将板上的瓶盖下放至履带，每 5 秒一次 | A20 |
| 2 | 绿色瓶盖舱门 | C19 |
| 3 | 黄色瓶盖舱门 | C18 |
| 4 | 红色瓶盖舱门 | A19 |
| 5～7 | 不参与自动分拣，PWM 不启用 | D19、D18、B19 |

瓶盖模型仍包含紫色类；紫色、未知、低置信度、没有目标或同时有多个目标时，不打开任何分类舱门。1 号仍按 5 秒周期动作。每次在识别板上放置一个待分拣瓶盖，其他情况由履带末端收集。

## 一个下料周期

1. 摄像头先识别板上的瓶盖，连续两帧确认同一有效颜色。
2. 下料前 250 ms，锁存颜色并打开对应的一个舱门；识别结果超过 1 秒不再用于选门。
3. 第 5 秒，1 号执行下放动作，保持 500 ms 后回位。
4. 下料后 2 秒关闭本次舱门，下一次下料仍安排在下一组 5 秒周期。

下料开始后清除本次分类，只接收 1 号回位之后拍摄的新图像，避免将上一件瓶盖的颜色用于下一件。下一件可以与上一件同色。目标舱门在本次运输期间保持锁存，不会被随后识别到的另一种颜色改变。

相机未配置、失败、冻结、彩条、识别停止或超过 1 秒没有有效推理完成时，停止自动动作并回位。恢复有效推理后重新开始 5 秒计时。切换手势、CoreMark 或执行手动舵机命令同样退出自动流程；手动模式需重新选择瓶盖后恢复自动。

## 机械校准

默认 PWM 周期为 20 ms，各路回位为 1500 μs、动作位为 2000 μs。2000 μs 对应哪个物理方向由舵机安装决定，必须空载校准后才可认定是“向下”或“开门”。在 `firmware/sorter.h` 的 `sorter_home_us`、`sorter_action_us` 中分别设置每个舵机的两个位置。

`SORTER_FEED_TICKS` 控制 5 秒周期，`SORTER_RELEASE_TICKS` 控制下放保持，`SORTER_PREOPEN_TICKS` 和 `SORTER_GATE_TICKS` 控制提前开门与运输等待。默认 2 秒没有使用到位传感器，需要按履带速度和各舱门距离调整。供电和共地要求见 [SERVOS.md](SERVOS.md)。

## 重新构建与验证

在仓库根目录执行：

```powershell
python fpga_pg2l100h/vision/build.py --cpu dual --npu 128 --output-dir fpga_pg2l100h/vision/build/dual_caps_sorter128_j11 --pds-home E:/pango/PDS_2022.2-SP6.1
python fpga_pg2l100h/vision/build.py --cpu dual --npu 128 --output-dir fpga_pg2l100h/vision/build/dual_caps_sorter128_j11 --check
& fpga_pg2l100h/vision/model/checkpoints/train_env/Scripts/python.exe fpga_pg2l100h/vision/verify.py --cpu dual --npu 128 --build-dir fpga_pg2l100h/vision/build/dual_caps_sorter128_j11 --pds-home E:/pango/PDS_2022.2-SP6.1
```

位流位于新工程的 `generate_bitstream/`。是否已完成综合和时序验收以同目录 `build_summary.json` 为准。本次 12 项回归结果位于 `validation/dual_caps_sorter128_sim/simulation_summary.json`；128 MAC 的 10 张图像、4320 个输出精确比对结果位于 `validation/dual_caps_sorter128_npu/summary.json`；按键切换和两次 CoreMark 短测结果位于 `validation/dual_caps_sorter128_runtime/summary.json`。这三份报告均已通过。CoreMark 短测只验证执行和 CRC，实板正式成绩需满足官方运行时间要求。Flash 写入和读回结果见 [BOARD_VALIDATION.md](BOARD_VALIDATION.md)。软件和数字仿真通过不能替代实板识别、PWM 测量和机械位置验证。
