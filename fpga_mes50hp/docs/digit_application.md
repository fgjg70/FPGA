# MES50HP 手写数字识别与密码门禁 v2

本应用运行在 PGL50H-6IFBG484 / MES50HP。PC 提供画板或测试图片，将统一处理后的 16×16 小图发送到 FPGA；自研 RISC-V 执行 INT8 MLP 推理、调度 GEMM 加速器、判断四位密码并控制板载外设。HDMI 显示、小图缓存、按键、LED、EEPROM 和串口协议已接入应用配置。CPU 仍使用 50 MHz；板载另一颗 27 MHz 晶振直接提供视频时钟。

## 构建与运行

```powershell
python -m pip install -r app/requirements.txt
python prepare_rtl.py --app digit
python prepare_rtl.py --check --app digit
python tools/build_digit_bitstream.py
python app/digit_demo.py --port COM5
```

将 `build/digit/generate_bitstream/top_mes50hp.sbit` 配置到 FPGA，再按 KEY1。COM5 仅是示例，应选择板载 CP2102 的实际端口。串口为 115200、8N1、无流控。离线画板预览可用 `python app/digit_demo.py --offline`，该模式明确标为 PC 推理。

应用构建放在 `build/digit/`，不会覆盖根目录的历史 boot 位流。`mes50hp_digit.fdc` 是应用引脚及视频时序约束，`prepare_rtl.py` 将所选配置的约束复制为 `generated/profile_constraints.fdc` 并纳入清单校验。不要把 boot 配置位流与 v2 主机程序混用。

## 一次完整演示

1. HDMI 连接显示器，USB 串口连接 PC，下载应用并按 KEY1。空白 EEPROM 使用默认密码 `1234`、硬件模式、开门 5000 ms，显示 `DEFAULT`；启动不会自动写 EEPROM。
2. 在画板写一位数字或载入内置样例，点击 Recognize。PC 只准备输入，板端执行所选的 software / hardware / compare 推理。
3. 检查小图和结果，再点击 Confirm digit 或按 KEY4。每次识别只能确认一次；识别本身不增加密码位。依次确认 1、2、3、4，LED3 及 HDMI 门状态变为开门，到时自动上锁。
4. 输入错误四位密码显示报警；按 KEY2 或点击 Lock 清空输入并锁门。锁定请求在当前串口事务结束后优先执行，主机以板端应答更新状态；板载 KEY2 在固件等待和运算期间也会处理。
5. 用 Save PIN、模式选择或 Save unlock time 保存配置。HDMI/GUI 反馈 `SAVED` 或保存错误。按 KEY1 验证重新加载，按住 KEY8 至少 2 秒恢复默认并保存。

低对比度图像、非数字和域外手写仍可能误识别。当前明确确认流程允许人检查结果，不把 MLP 分数称作经过校准的概率，也没有实现通用非数字拒识模型。

## 板载按键与 LED

| 按键 | FPGA 管脚 | 行为 |
| --- | --- | --- |
| KEY1 | K18 | 复位 CPU、外设和显示，重新读取 EEPROM，最终保持锁门 |
| KEY2 | L15 | 立即锁门，清空密码输入和待确认结果 |
| KEY3 | J17 | 有待确认结果时取消它，否则撤销上一位已确认输入 |
| KEY4 | K16 | 确认当前识别结果一次 |
| KEY5 | J16 | 硬件→软件→对照模式循环，取消旧候选，后台保存配置 |
| KEY6 | J19 | 使用当前板端小图重新识别；没有小图时不操作 |
| KEY7 | H20 | 清除小图、候选和密码输入进度，保留当时门状态 |
| KEY8 | H17 | 持续按住 2 秒，恢复 `1234` / 硬件模式 / 5000 ms，并保存 |

KEY2～8 低有效，50 MHz 下独立同步、5 ms 消抖，按下一次产生一个事件。KEY8 需要持续电平计时，按住不重复写 EEPROM。

| LED | 管脚 | 含义 |
| --- | --- | --- |
| LED1 | B2 | 心跳 |
| LED2 | A2 | 已完成一次有效识别 |
| LED3 | B3 | 门已打开 |
| LED4 | A3 | 密码错误报警或非法指令 |
| LED5 / LED6 / LED7 | C5 / A5 / F7 | 输入进度：确认第 1、2、3 位时依次点亮；第四位完成密码判断后清空 |
| LED8 | F8 | 推理进行中 |

## HDMI 输出

MS7210 使用独立开漏 I²C，7 位地址 `0x59`，SCL=P17、SDA=P18、RESETn=R17；寄存器地址按低字节、高字节发送。固件检查读写应答及测试寄存器，然后配置外部 RGB888/SDR、576p50 视频和 AVI InfoFrame，关闭音频。状态查询分别报告芯片初始化结果和 EEPROM 状态，缺失芯片不会阻止识别。

输出为 720×576p50，像素时钟 27 MHz，总时序 864×625，行同步 64 像素、场同步 5 行，均为负极性。有效区开始于水平 132、垂直 44。输出像素时钟使用视频时钟的反相，使 MS7210 在数据稳定后采样。约束包含视频时钟、生成的 HDMI 时钟及数据/同步/DE 的外部输出延迟。

画面显示 16×16 输入的 12 倍放大小图、识别数字、待确认提示、门/报警状态、密码进度、模式、软件与硬件耗时以及 EEPROM 状态。耗时为板端推理周期换算后的 `DDD.ddd ms`，软件和硬件均包含 CPU 数据搬运和调度；单独执行某一种模式时，另一种显示零。对照模式显示同一输入的两次结果耗时。

双缓存图像和元数据在帧边界一次切换，跨 50/27 MHz 时钟域采用请求/应答；CPU 在提交未完成时保留更新请求，避免撕裂画面。完整仿真截图见 `validation/peripheral_sim/display.png`。截图中的时间和状态是显示测试台注入的数据，实际整机推理计时见 `validation/digit_summary.json`。

固定 576p50 没有实现 EDID 自动选模、热插拔重配或音频。实际显示器须支持该模式；`hdmi_initialized` 表示 I²C 初始化成功，不能代表接收端已经锁定 TMDS。实物还需要核验显示器兼容性、颜色顺序和输出波形。

## EEPROM 与复位约定

板载 24LC02 为 256 字节，7 位 I²C 地址 `0x50`，SCL=F15、SDA=G8。驱动处理总线恢复、重复起始、逐字节应答、8 字节分页写及写完成 ACK 轮询；启动读取前也先等待就绪，覆盖复位发生在内部写周期中的情况。等待上限 10 ms；不存在或持续 NACK 时有界退出，不阻塞启动。

配置保存密码四位、模式、开门时长、格式版本和递增代数。两份 24 字节记录分别位于地址 0 和 32，每份带 CRC16；更新时先使备用记录无效，再分页写数据，最后写提交标记并读回校验。只有成功后才提升当前代数。中途写入失败或复位时保留上一份有效记录，下一次启动选有效且最新的一份。

| 操作 | RAM 与 EEPROM 行为 |
| --- | --- |
| 首次上电、两份无效或 EEPROM 缺失 | 使用 `1234` / 硬件 / 5000 ms；不自动写入；锁门 |
| KEY1 / CPU 复位 | 清除小图、候选和输入进度；从 EEPROM 重新加载配置；锁门 |
| 重新配置 FPGA或整板断电重启 | RAM 清空；下次从板外 EEPROM 恢复有效配置；锁门 |
| 修改密码、模式或开门时间 | 先更新运行配置，再保存；保存失败返回状态 8，并显示错误；本次 RAM 配置仍可使用，重启恢复上次成功保存值 |
| KEY8 长按 / GUI Restore defaults | 恢复默认、锁门并尝试保存；GUI 要求一次确认，串口要求 `RST!` 标记；保存失败仍明确报错 |
| KEY2 / Lock / Clear | 不改 EEPROM |

开门时长允许 1000～30000 ms。按键模式切换先合并为后台保存，避免在每一轮轮询或识别时写 EEPROM。EEPROM 中的密码是演示配置明文，没有提供密码防提取或商用门禁安全机制。

## 模型与统一输入

网络 `256→32→10`，INT8 输入/权重、INT32 偏置与累加，共 8680 字节参数。`app/preprocessing.py` 的 `digit-normalize-v2` 统一服务训练、GUI、图片 CLI 和板端评测：极性判断、阈值裁剪、20×20 等比缩放、28×28 画布质心居中、缩放 16×16、量化至 0～127。避免旧版训练直接缩放而画板另行居中的差异。

模型在 60000 张 MNIST 训练图像上以固定种子 2026 训练 30 轮。完整 10000 张 MNIST 测试集的 PC 参考准确率为浮点 96.89%、INT8 96.72%，见 `model/metrics.json`。该准确率对应上述统一输入和当前模型，属于 PC 定点参考结果，不是整板或现场手写实测。历史 v1 的 97.09% 使用另一种输入路径，不能混用。

IMEM 和 DMEM 各 16 KiB；模型放在数据镜像。CPU 内核、GEMM 运算公式与 CoreMark 配置保持原有范围，新增 GEMM 中止控制用于超时恢复。最终资源、周期、时序和位流哈希以重新生成的 `validation/digit_summary.json` 为准。

2026-10-24 的 v2 最终布局布线使用 5838 LUT、2166 寄存器、25 个 DRM18K 等效资源、6 个 APM。50 MHz CPU 建立裕量 +4.086 ns；27 MHz 视频域 +13.026 ns；视频到 HDMI 输出 +7.926 ns；对应保持检查也通过。固件 `.text` 为 14472 字节、`.data` 为 9400 字节，链接时仍检查 2 KiB 栈空间。

十个数字的 RTL 整机测试逐项核对 100 个输出分数；两组同时执行软硬件的样例，板端推理加速比中位数为 2.3547 倍。加速器内核保持 17066 周期，完整硬件推理随样例和轮询相位约为 3.24～3.30 万周期。该比较不含串口、PC 和显示刷新；115200 下仅一帧输入及完整结果的传输下界已为 29.17 ms，精简结果为 25.69 ms。

## 串口 v2 与状态同步

帧为 `PG | command:u8 | sequence:u8 | length:u16LE | payload | CRC16:u16LE`；CRC16/CCITT-FALSE 覆盖命令到载荷。最大载荷 256 字节。响应命令为请求加 `0x80`，序号必须匹配。接收 FIFO 为 512 字节，停止位错误与溢出分别累计并可查询，清除错误标志不会清空累计计数。固件在帧开始后采用总 250 ms 接收期限，防止残帧长期占用。

| 命令 | 载荷 / 结果 |
| --- | --- |
| 1 hello | 返回状态、版本 2、50 MHz 和加速器 ID |
| 2 / 3 / 4 | 256 字节输入，执行软件 / 硬件 / 对照；64 字节完整结果 |
| 18 / 19 / 20 | 相同输入，24 字节精简结果，省略十类分数 |
| 5 / 9 / 11 | 无载荷，锁定 / 撤销 / 清除输入 |
| 6 | 四个 0～9 的数值字节，更新并保存密码 |
| 7 | 40 字节状态：门、进度、候选及 token、模式、剩余开门时间、软硬件耗时、EEPROM/HDMI 标志、UART 累计错误和配置代数 |
| 8 | 4 字节识别 token，确认一次；过期、取消或重复提交返回 6 |
| 10 | 模式 0=硬件、1=软件、2=对照，更新并保存 |
| 12 | `RST!`，恢复默认并保存 |
| 14 | 4 字节开门毫秒数，更新并保存 |
| 15 | 84 字节诊断：软件/硬件有效标志及各十个 INT32 分数 |

完整识别结果布局 `<BBBBIIII10iI`，精简结果 `<BBBBIIIII`，状态布局 `<8B8I`，均小端。前四个字节依次为状态、数字、门标志和输入进度；后续为软件周期、硬件周期、内核周期、不一致数量，最后附单次确认 token。完整结果在 token 前包含十类分数。

GUI 使用单独的串行工作线程，待处理操作排队；Lock 优先清除尚未执行的动作，等待当前事务完成后发送锁定并确认应答。空闲时每 250 ms 请求状态，自动回锁或板上按键操作会同步显示。断连时显示状态未知。重新编辑画板会使本地旧 token 无效。

```powershell
python app/digit_cli.py --port COM5 --sample 7 --mode compare
python app/digit_cli.py --port COM5 --status
python app/digit_cli.py --port COM5 --confirm 42
python app/digit_cli.py --port COM5 --set-pin 9876
python app/digit_cli.py --port COM5 --set-mode compare
python app/digit_cli.py --port COM5 --set-unlock-ms 3000
python app/digit_cli.py --port COM5 --lock
python app/evaluate_board.py --help
```

示例 token 42 应替换为本次识别实际返回值。主机不自动重试修改配置或确认等命令，避免不确定应答引起重复副作用。不一致错误保留状态、完整分数和计时，GUI 可再读取双方分数；评测脚本把错误及部分进度写入报告。板端推理周期、串口往返时间和 PC 预处理时间分别记录，不用内核加速比替代端到端性能。

## 验证与限制

```powershell
python -m unittest discover -s validation -p 'test_digit*.py' -v
python validation/run_rtl.py boot
python validation/run_rtl.py uart
python validation/run_rtl.py peripherals
python validation/run_rtl.py gemm
python validation/run_rtl.py digit --fast
python validation/run_rtl.py digit --fast --simulator verilator --directory validation/digit_verilator --cxx-abi 0
python validation/run_rtl.py digit --smoke
python validation/run_rtl.py digit --fast --missing-peripherals
python tools/summarize_digit.py
```

`run_rtl.py` 支持 Icarus Verilog、Vivado xsim 和 Verilator。xsim 使用 `VIVADO_HOME` 或 `E:/Vivado/2018.3`；Verilator 使用 `VERILATOR` / `--verilator` 指定可执行文件，并需要本机 C++ 工具链，Windows 可配置 `MSYS2_ROOT`。本机 MSYS2 构建使用 `--cxx-abi 0`，其他正常工具链可省略该选项。PowerShell 包装入口仍为 `validation/run_digit.ps1`，默认 xsim，加 `-Icarus` 切换。快速整机测试仅将 UART 改为 1 Mbaud，独立 smoke 使用真实 115200。消抖和长按测试只在 testbench 加速时间门槛，产品 RTL/固件仍为真实参数。

整机测试先完成 MS7210 初始化及 AVI 检查，再在 EEPROM 复位子用例断开 HDMI 模型，以验证配置恢复独立于显示芯片存在。启动时先注入 5 ms EEPROM 忙状态；写入故障后确认 EEPROM 仍忙，再立即复位。Verilator 将整机测试运行时间缩短至约半分钟；xsim 的真实 115200 smoke 约 15 分钟。加 `--directory` 可隔离不同仿真器的产物；不要同时写同一个输出目录。`summarize_digit.py` 依次选择通过的 `digit_sim`、`digit_verilator`、`digit_xsim`，并校验位流、RTL、固件、模型和约束证据。

验证包括整帧像素与输入小图逐点比较、全部按键和进度灯、十个数字及 100 个输出分数、重复确认、自动上锁、EEPROM 分页/忙时 NACK/复位恢复/中途写失败/默认恢复、MS7210 初始化寄存器和 AVI 校验，以及缺失外设时有界降级。I²C 行为模型验证协议，不替代真实芯片和 HDMI 接收器测试。

本次没有执行 JTAG 编程、Flash 固化或真实串口评测。请在实际板卡确认上述引脚与硬件版本后，用 HDMI、KEY1～8、LED1～8 和断电重启完成现场验收。当前 MLP 应用覆盖手写门禁演示；赛题所述 YOLO/轻量大模型高阶任务仍需独立实现。
