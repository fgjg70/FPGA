# 资料来源与实现范围

核对日期：2026-10-24。

## MES50HP 官方资料

- 硬件使用手册入口：`https://szlogicmatrix.com/384.html`
- PDF：`https://szlogicmatrix.com/wp-content/uploads/2025/12/MES50HP开发板硬件使用手册_1V1.pdf`
- PDF SHA-256：`61a854d97606010c47971d99f7e84e410563cabecffc492feb4f98e851098f71`
- 手册共 38 个 PDF 页面。PDF 第 7 页确认 PGL50H-6IFBG484；第 9～10 页确认 50 MHz 晶振与 P20；第 27 页图 3-4、表 3-5 确认 CP2102、R9/TX 和 R8/RX；第 33 页确认 KEY1/K18；第 33～34 页确认 LED 高电平点亮及 B2/A2/B3/A3 引脚。

本次使用手册所附外围电路图和引脚表核对板载接口，没有为未连接的触摸屏、摄像头或舵机指定引脚。手册 PDF 未打包到本项目。

v2 补充核对：PDF 第 10 页的 27 MHz/K21；第 30～32 页的 MS7210 电路与表 3-8 的 RGB、同步、时钟、I²C 和复位引脚；第 33～34 页的 KEY2～8、LED5～8；第 34 页 24LC02 电路图和 F15/G8。24LC02 地址脚接地，地址为 0x50；MS7210 SA 接法对应 7 位 0x59。全部应用引脚写入 `mes50hp_digit.fdc`。

## HDMI 与 EEPROM 参考

- 原作者 MS7210 Linux 驱动：`https://github.com/avmwww/ms7210-linux-driver`，参考 `ms7210.c` / `ms7210.h` 的寄存器含义、低字节优先地址、低像素时钟 PHY、DVIN 时序和 AVI InfoFrame 配置。上游 GPL-3.0；本项目没有打包或整份移植 Linux 驱动。
- 同类 FPGA 工程：`https://github.com/Yoraro/pango_signal_analysis`，参考 `source/rtl/hdmi/ms7210_ctl.v` 的芯片地址与初始化寄存器事实。新的显示逻辑和软件 I²C 驱动为本工程实现，时序调整为使用板载 27 MHz 的 576p50。
- Microchip 官方 24LC02B 产品与数据手册：`https://www.microchip.com/en-us/product/24lc02b`。核对 2 Kbit 容量、8 字节分页写、重复起始与 ACK 轮询；实际板卡手册标注 24LC02，需按板上器件版本验收。

这些开源资料用于交叉核对芯片寄存器及接口事实，不能替代 MS7210/EEPROM 在本板上的实测。仿真中 `validation/i2c_devices.sv` 是独立编写的协议模型，没有模拟 HDMI TMDS 电气行为。

## 模型与开源参考

- MNIST 数据说明：`https://www.tensorflow.org/datasets/catalog/mnist`
- 原始 MNIST 数据镜像：`https://ossci-datasets.s3.amazonaws.com/mnist/`
- PyTorch 官方 MNIST 加载器及校验值：`https://github.com/pytorch/vision/blob/main/torchvision/datasets/mnist.py`
- scikit-learn MLPClassifier：`https://scikit-learn.org/stable/modules/generated/sklearn.neural_network.MLPClassifier.html`
- scikit-learn 源码：`https://github.com/scikit-learn/scikit-learn/blob/main/sklearn/neural_network/_multilayer_perceptron.py`
- Arm CMSIS-NN：`https://github.com/ARM-software/CMSIS-NN`
- TensorFlow Lite INT8 量化规范：`https://github.com/tensorflow/tensorflow/blob/master/tensorflow/lite/g3doc/performance/quantization_spec.md`
- 同型号板卡上的开源 RISC-V 应用参考：`https://github.com/Dark-be/2023_FPGA_MES50HP`
- xPack RISC-V 工具链：`https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/tag/v15.2.0-1`

本项目复用已有的自研 RISC-V 内核，使用 scikit-learn 训练小型 MLP；参考 INT8 输入/权重与 INT32 累加的实现方式。板端算子、串口协议、交互程序和 GEMM RTL 为本工程实现，没有将 Arm 内核专用的 CMSIS-NN 代码直接移植进来。定点缩放比例为本项目自定义，不宣称与 TensorFlow Lite/CMSIS-NN 的完整量化 ABI 按位兼容。

导出的模型由本项目脚本重新训练，数据文件的 MD5、网络规模、随机种子、训练轮数、测试准确率和模型哈希见 `model/metrics.json`。不依赖来源不明的预训练参数。

该应用覆盖选题一的应用场景、特定模型延迟与识别率对比；小型 MLP 不等同于指南高阶任务中提到的 YOLO 或轻量版大模型。
