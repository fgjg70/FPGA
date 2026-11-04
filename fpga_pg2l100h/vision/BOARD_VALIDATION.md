# PG2L100H实际下载与待完成联调

2026-11-04 当前交付为 `build/dual_caps_sorter128_j11/pg2l100h_vision.pds`：95 MHz 双发射 CPU、50 MHz 的 128 MAC NPU，不使用 DDR3；功能为 CoreMark、手势 1～5 和瓶盖识别。17:48 已完成 Flash 写入、工具校验、完整读回和从 Flash 重载，两次状态均为 `0x081ffca0`。瓶盖自动分拣说明见 [CAP_SORTING.md](CAP_SORTING.md)。用户随后反馈舵机无动作，实物供电、接线、PWM 波形及机械动作尚未完成定位和验收。以下保留各版本的下载记录。

## 2026-11-04 17:48：128 MAC 三功能瓶盖分拣版写入 Flash

SW4 执行 CoreMark，SW5 进入瓶盖自动分拣，SW6 进入手势识别，上电默认瓶盖模式。瓶盖模式下 1 号每 5 秒下料，2 号绿色、3 号黄色、4 号红色；5～7 号不自动启用。自动下料需摄像头配置正常且持续完成推理；异常时回位并停止计时，恢复后重新开始 5 秒周期。动作脉宽为 2000 μs，回位为 1500 μs，安装方向仍需实物校准。

原生综合、布局布线及详细时序检查通过，87 项实现输入与仿真工程完全一致。12 项回归、128 MAC 的 10 张图像及 4320 个整数输出比对、两次按键 CoreMark 短测均通过。短测只验证执行和 CRC，没有生成新的实板正式 CoreMark 成绩。

位流大小 3,791,112 字节，SHA256 为 `4b8168d78e5fa5a9ad8363b93e01078594db47d2f4f94d8253cd70d3ca5128b9`。先下载至 RAM 并确认两次 PLL 锁定，再备份旧 Flash、擦除、写入和工具校验。新位流、SFC 与完整 Flash 读回的 SHA256 一致。从 Flash 重载后两次状态均为 `0x081ffca0`，DONE、done_i、PLL 锁定为 1，五项配置错误为 0；未进行实体断电重上电或舵机机械验收。

烧录证据和旧 Flash 备份位于 `validation/hardware_20261104/caps_sorter128_20261104_1725/`，结果见其中 `programming_summary.json`。本次 JTAG 客户端与服务器均已释放。舵机无动作的后续检查需区分摄像头推理条件、J12 信号、独立舵机电源与共地；目前没有确认其中哪一项是实物故障原因。

## 2026-11-04 11:44：修正 95 MHz PLL 带宽并重新写入 Flash

用户反馈白屏，修复前板卡状态为 `0x0817fca0`，PLL 锁定标志为 0。CPU PLL 的 50 MHz 输入经分频 2 后，PFD 为 25 MHz，但配置为 HIGH；本机 PDS 附带 `UG041001_PLL_IP.pdf` 第 33 页要求该范围使用 LOW 或 OPTIMIZED。顶层在两个 PLL 均锁定前持续保持系统复位，因此未锁定会阻止 LCD 和摄像头启动。

将 `experiments/dual_issue/vision_cpu_clock.v` 的带宽改为 OPTIMIZED，CPU 仍配置 95 MHz，NPU/MMIO 仍为 50 MHz。与修复前清单比较，唯一变化的实现输入为该 PLL 文件；CPU 指令和数据二进制均保持一致。为 `sim/tb_board.v` 补充低于 40 MHz PFD 的带宽检查，先确认原 HIGH 配置被回归拒绝，再确认修正版通过。Verilog-2005 语法、Pango PLL 模型板级启动及 SW2 复位、LCD、CDC、DVP 相机五项检查通过。

原生综合、布局布线及详细时序均通过；95 MHz CPU 详细建立裕量为 +0.436 ns、保持裕量为 +0.353 ns，布局布线后建立裕量为 +0.493 ns。修正版位流共 3,791,112 字节，SHA256 为 `51f5eda2d5e2d178380072dd186902d875836bb031a1c0b041208704fe30cf4c`。

先下载至 FPGA RAM，状态由 `0x0817fca0` 恢复为 `0x081ffca0`，两次确认 PLL 锁定后才固化 Flash。11:44:32 写入完成，11:44:38 工具校验通过，11:44:43 配置区完整读回，SHA256 与修正版位流及 SFC 一致。11:44:45 执行 `cfg_reset_fpga` 从 Flash 重载，11:45:02 和 11:45:08 两次状态均为 `0x081ffca0`，DONE、done_i、PLL 锁定为 1，五项配置错误为 0。未进行实体断电重上电、实际频率测量或 LCD 目视确认；3.9572/MHz 仍为原 CPU/固件的 RTL 短测参考值，本轮没有实板跑分。

本次 JTAG 客户端与服务器均已释放。修复前文件、错误带宽负例、修复后回归、时序、RAM 下载、Flash 读回与状态证据位于 `validation/hardware_20261104/pll95_white_screen_20261104_112520/`；机器可读结果为 `validation/pll95_white_screen_summary.json` 与 `validation/flash_programming_summary.json`。

## 2026-11-04 11:17：95 MHz 双发射固件写入 Flash，PLL 未锁定

按用户要求烧录最新 `build/dual_j11/pg2l100h_vision.pds` 的现有产物。源码、模型、固件与工程清单哈希检查通过；CPU 为 95 MHz，外设为 50 MHz，对应 16 次迭代 RTL 诊断结果为 3.957198/MHz。位流共 3,791,112 字节，SHA256 为 `5d7943e3462cb4b0bdf5152511be33d6cdf09eaff6635c015e04157859cd0966`。扫描确认 PG2L100H ID 为 `0x00602899`、W25Q128Q Flash JEDEC ID 为 `0xEF4018`。11:17:26 写入完成，11:17:32 校验通过，11:17:37 配置区完整读回，SHA256 与原位流和 PDS 生成的 SFC 完全一致。此前 125 MHz 固件配置区已备份。

11:17:39 通过 `cfg_reset_fpga` 从 Flash 重新加载；四次状态读数均为 `0x0817fca0`，DONE 和 done_i 为 1，五项配置错误为 0，PLL 锁定标志为 0。检查发现 `experiments/dual_issue/vision_cpu_clock.v` 使用 50 MHz 输入、输入分频 2，即 PFD 为 25 MHz，但带宽仍设为 HIGH；本机 PDS 附带 `UG041001_PLL_IP.pdf` 第 33 页要求 10～40 MHz PFD 使用 LOW 或 OPTIMIZED。这是已确认的参数不匹配和 PLL 未锁定的疑似原因，尚未通过修改后的构建验证。本次保留用户指定的现有位流，未取得实板 CoreMark、LCD、按键或识别验收结果，也未进行实体断电重上电测试。

本次 JTAG 客户端和服务器均已释放。完整证据及旧配置区备份位于 `validation/hardware_20261104/flash_dual95_20261104_111204/`；机器可读结果为 `validation/flash_programming_summary.json`。

## 2026-11-03 23:44：七路PWM固件再次写入Flash

按用户要求重烧同一份七路PWM固件。外部Flash扫描ID为0xEF4018，PDS识别为W25Q128Q；23:43:10完成擦除，23:44:18完成写入，23:44:23校验成功。23:44:44完整读回本次3791112字节配置区，SHA256与待烧录SFC及SBIT一致，均为 `13b0341ea590836020540ff34d75b9cbebb7756e5cb5ae6eb627eeb5d860fb47`。

23:44:45通过cfg_reset_fpga清除当前配置并重新加载Flash；首次读数仍在配置中，23:45:04和23:45:13两次状态均为0x081ffca0，DONE、done_i及PLL锁定均为1，超时、读回CRC、认证、CRC和ID错误均为0。本轮未执行RAM位流下载，因此已验证从Flash重新加载配置。未操作实体电源开关，断电重上电仍待实物核对。客户端和本轮JTAG服务器均已退出。

位流来自23:03完成的当前源码构建，源码及生成文件哈希检查通过，CPU 125 MHz与外设50 MHz时序均通过。七路舵机复位默认关闭，实际管脚波形和机械位置仍待校准。本轮写入、校验、读回和状态日志见 `validation/hardware_20261103/flash_servo_221827/`，最新机器可读结果见 `validation/flash_programming_summary.json`；此前的RAM下载记录保留为历史。

## 2026-11-03 13:30：发现FPGA未配置，重新下载125/50 MHz版

用户再次反馈白屏、SW2及其他按键无反应。13:28:00扫描确认器件PG2L100H、ID0x00602899，但DONE为0；配置状态0x00180c80，done和done_i均为0，gwen、grsn、gouten也为0。当时没有运行已完成配置的用户逻辑，按SW2逻辑复位不能重新装入工程。之前的JTAG下载均仅写FPGA RAM；断电会丢失，配置清除或重新上电也需重新下载。本轮没有证据区分此前配置被清除的具体原因。未配置状态的pll_lock虽为1，但不能据此认定CPU时钟或应用在运行。

核对本地源码、暂存项目、模型与固件哈希通过，并确认位流为已修正HIGH带宽的125/50 MHz版，SHA256为 `f179a403c71df8d6c4075faacc28616d2268e9121c35fcd45d82d7eb1162fef2`。13:30:00已重新下载到FPGA RAM，13:30:02和13:30:52两次读回均为0x081ffca0，DONE、done_i及PLL锁定均为1，五项配置错误均为0。CPU、指令存储和数据存储仍配置125 MHz，NPU、采集及MMIO仍为50 MHz，未更改RTL或重新生成位流。

用户随后确认“摄像头显示在屏幕上了”，本次位流的摄像头到LCD预览通路已得到实物目视确认。CPU固件执行、LED心跳、实际按键、识别精度和图像方向仍未单独确认；预览硬件可独立于CPU运行。JTAG客户端及本轮服务器均已退出，未写Flash。证据见 `validation/hardware_20261103/cpu125_white_screen_followup/`。调试时保持供电；断电后需重新下载，SW2只能复位已加载的逻辑。

## 2026-11-03：修正125 MHz PLL带宽并重新烧录

用户反馈125 MHz版白屏，SW2及其他按键无反应；修复前JTAG实读状态0x0817fca0，PLL锁定标志为0。CPU PLL使用50 MHz输入、IDIV=1，PFD为50 MHz，却选择OPTIMIZED带宽，违反PDS附带UG041001 V1.4第33页的带宽要求。系统复位等待视频PLL与CPU PLL均锁定，因此PLL未锁定会同时阻止LCD、摄像头、按键和CPU启动。

将CPU PLL的BANDWIDTH修正为HIGH，CPU、指令存储和数据存储仍为125 MHz，NPU、MMIO和摄像头采集仍为50 MHz。01:05:28完成原生综合、布局布线及新位流生成，所有约束通过，CPU建立WNS为+0.609 ns，50 MHz域为+7.052 ns。严格Verilog-2005编译和Pango PLL模型板级仿真均通过；新增检查可拒绝旧带宽配置，并检查SW2复位、两个PLL重新锁定和复位释放。

01:07:47已将修正版写入FPGA RAM，器件ID0x00602899，DONE及done_i均为1，五项配置错误均为0；01:07:49和01:08:11两次状态均为0x081ffca0，PLL锁定标志已变为1。位流3791112字节，SHA256为 `f179a403c71df8d6c4075faacc28616d2268e9121c35fcd45d82d7eb1162fef2`。本轮JTAG客户端与服务器均已退出。

当前已验证配置完成及PLL锁定，尚未取得修复后LCD画面、物理按键响应或应用UART的实物确认，也未用示波器测量125 MHz。下一步观察LCD是否显示CAM WAIT、CAM ERR或实时画面，以及SW2复位和SW5彩条切换是否响应。证据、修复前后状态、位流及本轮两项回归见 `validation/hardware_20261103/cpu125_white_screen/`；机器可读状态见 `validation/hardware_summary.json`。

## 历史三模式125/50 MHz版本：配置完成，但PLL未锁定

2026-11-02本轮将SW4长按统一为HANDWRITE→GESTURE→COCO80三模式循环。CPU、IMEM和DMEM维持125 MHz，NPU、MMIO和摄像头保持50 MHz。七项定向检查通过，包括实际生产固件九类/十类头文件、严格Verilog、状态机、工具、LCD和两套RV32整机；新增去抖按键完整循环、忙时取消和未部署模式互锁。原生布局布线和详细时序均通过，CPU建立WNS为+0.553 ns，50 MHz域为+7.006 ns；映射LUT4469、FF3706、APM10、DRM64。操作见 `MODES.md`，时钟计时区别见 `CLOCK_SPLIT.md`。

2026-11-02 23:45:46按用户要求再次将同一份125/50 MHz位流写入FPGA RAM；此前一次成功下载为23:09:23。器件ID确认0x00602899，cfg_program成功、DONE及done_i均为1，超时、读回CRC、认证、CRC和ID错误位均为0。位流为 `build/j11/generate_bitstream/top_pg2l100h_vision.sbit`，3791112字节，SHA256为 `0b3b59514c567ab5c313c3f858d7659f19aaf005ab8c7cebcca95e7adaf78baa`，22:46:59生成。Flash未写入，断电后RAM配置丢失。本轮交互式配置客户端成功连接USB Cable II，下载后已释放本轮JTAG服务器。

本次配置状态连续两次读为0x0817fca0，其中pll_lock位19仍为0，over_temp位27为1；实际温度及其标志解释未测定。DONE和配置错误检查证明文件已配置，不能据此认定125 MHz用户时钟正常运行。尚待按SW2逻辑复位，并观察LCD、心跳LED或读取应用UART确认启动；未根据聚合状态位判断具体哪个PLL。本次未修改RTL或重新构建位流。

当前构建权重仍是原数字模型和旧九类手势；北方十类尚待实拍训练，COCO80只完成主机前向和资源核查。三模式中的COCO80设计为保持预览并显示NO MODEL，硬件停止NPU，固件不读取旧结果或产生识别事件；板上行为尚待观察。80类移植边界见 `model/COCO80_FEASIBILITY.md`。本次成功配置的文件、命令和PDS日志在 `validation/hardware_20261102/program_cpu125_20261102_234420/`，前次成功记录保留在 `validation/hardware_20261102/program_cpu125_20261102_230549/`。三模式构建、七项检查和此前两次失败扫描冻结在 `validation/hardware_20261102/three_modes_20261102_225013/`。首次时钟拆分版本15项完整回归及下载失败记录保留在 `validation/hardware_20261102/cpu125_npu50_20261102_220034/`，不能将其位流哈希或15项结果写成本轮执行结果。

## 历史成功下载：50 MHz基线

日期：2026-11-02，Asia/Shanghai。已使用本机PDS 2022.2-SP6.1完整版本完成实际综合、布局布线、时序分析和位流生成，并经PANGO USB CABLE II下载到扫描确认的PG2L100H。应用层的摄像头、LCD、数字/手势识别验收尚未完成。

20:54:59已下载当前北方手势一至十接口版本，保留MVFP=37的180度旋转设置。用户此前实拍确认DVP版已有真实画面，ID76、VR73、C1 E0、完整帧非零，但方向倒置；旋转后的正立画面仍待确认。本次完整13项回归、原生PDS构建、时序和源码哈希通过，另补充实际固件九类/十类解码和训练数据评估测试。当前证据目录为 `validation/hardware_20261102/northern10_interfaces_20261102_204814/`，此前相机实拍观察记录保存在 `validation/hardware_20261102/dvp18_20261102_194149/`。

手型以用户参考图为准，十为双手食指交叉；采集、训练导出、固件和LCD已支持十类，但当前下载仍包含原九类权重，不能据此声称已能识别新标准或“十”。缓存中标为十的22组原图全部是握拳，不采用；一的部分旧样本也与伸食指要求不符。标准、数据审核及采集流程见 `model/GESTURE_STANDARD.md`。

此前FIFO位流的实拍为CAM ERR、ID00、VR00、ST00、RX30、F0000、T0000、C0 E1，首次SCCB写入即失败。最新两张实物照片确认蓝色摄像头是18针DVP，而此前错误地按资料中的22针AL422模块适配。旧映射把实物SCL作为VSYNC计数、未提供MCLK、把PWDN作为高电平FIFO控制，符合触碰后V增加且无图像的现象。当前已重映射并更换采集器；这确认了接口适配错误，尚不能排除接触不良或模块本身问题。新约束假定18针逐号相连，J7-1为3.3V、J7-2为GND，旧22针接线表停用。

## 已取得的实测证据

| 项目 | 本次结果 | 证据 |
|---|---|---|
| 芯片识别 | PG2L100H，ID 0x00602899 | 本轮证据目录/jtag_scan.log |
| 目标构建 | Logos2 / PG2L100H / -6 / FBG676，PDS构建成功 | build/j11/build_summary.json |
| 时序 | All Constraints Met，clk50建立WNS为7.912 ns | build/j11/place_route/top_pg2l100h_vision_timing_summary_after_hold_fix.txt |
| 映射资源 | LUT 4261/66600，FF 3460/133200，APM 13/240，DRM 65/155 | build/j11/device_map/run.log |
| 下载 | Program成功，DONE=1，done_i=1 | 本轮证据目录/jtag_program.log |
| 配置错误位 | id_err、crc_err、aut_err、rbcrc_err、timeout均为0 | 本轮证据目录/jtag_program.log |
| 配置状态 | 0x081ffca0，over_temp位为1 | 本轮证据目录/jtag_program.log |
| 应用串口 | 仍只有FTDI COM12/COM13，没有CH340 | 本轮证据目录/serial_inventory.json |
| 源码回归 | 当前完整13项全部通过，另补九类/十类生产固件与训练数据评估测试 | 本轮证据目录/simulation_summary.json、hand_firmware_summary.json、training_data_supplement.json |

CPU、NPU和采集的设计与约束为50 MHz，视频27 MHz、LCD像素9 MHz，相机MCLK 12.5 MHz、SCCB 50 kHz。PWDN固定低，MCLK启动1 ms后释放RESET，再等待50 ms配置。尚未通过示波器测量相机MCLK/PCLK及数据相位；原生时序通过与实际外部采样验证分开记录。映射资源来自当前DVP18工程。

下载文件：build/j11/generate_bitstream/top_pg2l100h_vision.sbit，3791112字节，SHA256：

```text
20c02300464a9122a146ae9dd9fc9c55ee8fcc55bc0d7a47c6d2f0f2e312f9a3
```

本次使用cfg_program作JTAG逻辑配置，未执行Flash、eFuse或密钥写入命令。此RAM配置断电后丢失；断电后需重新下载才能验证本版应用。本轮证据目录保存实际命令program_ram.tcl、下载日志、完整位流副本和构建/仿真摘要。

## 本轮修正

当前活动采集器为 `camera_dvp_capture.v`，以50 MHz同步慢速DVP输入，高低字节合成RGB565，仅接收320×240完整帧并抽样为160×120；空同步脉冲、短行、奇数字节或总数不符会被拒绝，显示确认前禁止覆盖。P/L/V为原始边沿计数，F为合格帧，B为拒绝帧，区分干扰与完整图像。

复位同步器的GTP_DFF_P/P异步端例外保留，同步器级间及同步释放路径继续计时。DVP输入只对首级同步路径作异步处理，显示数据包最大延迟20 ns。PDS合法重写元数据后的artifact哈希按实际输出更新。本次完整13项回归、原生构建及build.py --check通过；固件十类分支还通过主机MMIO夹具执行实际生产解码代码验证，但尚无十类训练模型的整机或实物识别结果。

配置进行中显示黄色CAM WAIT，配置失败显示红色CAM ERR，配置完成但尚无整帧时显示NO FRAME。128位摄像头诊断随272位完整包在视频帧边界交接。当前保持SCCB应答与PID/版本检查，不以强制成功绕过实际故障；数字、手势模型和50 MHz主频保持原配置。

## 当前需要接线配合的部分

电脑仍只枚举到同一个FTDI下载器的COM12/COM13，未识别板载CH340。本轮没有打开下载器串口，JTAG烧录成功后已释放自己启动的服务器。新位流应用状态尚不能从当前USB连接读取。

首先确认当前旋转版LCD人像已正立，保持ID76、VR73、C1 E0且F有变化。此前用户照片已确认真实预览，完整识别精度和长时间稳定性仍未验证。串口联调另接J10 CH340N的USB接口，J9的1-2、3-4接通，115200、8N1、无流控。确认周期状态行NUMGUARD S=...后再执行：

1. 输入?，核对配置成功、图像有效、推理计数NN增长和NPU周期；记录所有失败状态。
2. 输入g、l，分别等待MODE HAND 1-9和MODE LABEL 0-9，核对切换后旧框清除；SW4长按1秒也需实物操作验证。
3. 用tools/capture_numeric.py分别采集标签和手势输入，校验4096字节、补零、CRC32及手势0/127轮廓。新手势数据保存到camera_hand_northern10，依照参考图采集一至十、独立人物/会话与负样本；十的标注框要同时包含双手。当前九类固件也能提供十手型的原始输入快照，此时不表示模型能识别十。没有有效相机帧时保留故障，不填写识别结果。
4. 目视检查J11 AN430的实时画面、红框和英文标签，保存实际照片/连续录像。软件预览图不能代替此步骤。
5. 按competition/ACCEPTANCE.md采集独立人物和标签样本，统计成功、误分类、拒识及无事件。现有手势公开图验证仍只有52/148正确接受，尚未取得板上识别精度。

另外，本轮下载后的配置状态显示over_temp位为1。尚未取得实际温度或该位在当前未使用ADC配置下的解释，不能据此填写温度数值或长时间稳定运行通过。需要核实芯片温度和散热，再做长时间运行验收；原始位值保留在hardware_summary.json和JTAG日志中。

机器可读汇总为validation/hardware_summary.json：本轮125/50 MHz版本programming_success=false、application_verified=false、overall_acceptance_complete=false；上一次50 MHz成功配置单列在last_successful_programming。以下基线数据不能作为新版本已烧录或应用验收的证据。
