# 当前交付档（2026-10-17 起）—— **150 MHz 已上板验证 PASS** 🎯

> 本文件由 Lead 维护：**每次换档就更新这里**。只写"要做什么、期望看到什么、出问题怎么办"。
> 轨迹与"为什么"在 `results/CHANGELOG.md`（§12 = 150 达成全过程），主频核实见 `results/FREQ-VERDICT.md`。

## 1. 烧什么（已就绪、已上板验证）

| 项 | 值 |
|---|---|
| 频率 | **150 MHz**（VCO = 50 × 21 = 1050, N=7；XDC `-multiply_by 21 -divide_by 7`） |
| 迭代 | **4600**（C-12c 后每迭代 463,366 拍） |
| 预期 tick | **2,131,483,600**（31 位占用 99.3%） |
| 实测 tick | **2,128,330,449**（偏差 0.148%）—— 与 138.75 MHz 档**逐位相同** |
| 实测性能 | **Iterations/Sec 328**／14 s／**CoreMark/MHz 2.1613**／绝对吞吐 **324.2** |
| 正确性 | `Correct operation validated`；`crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a / crcfinal 0x382f` |
| 时序 | 评分流 **WNS +0.000 MET**（压线！）；**不带 ILA**（见下） |
| bitstream | `fpga/cpu_a100t.bit`（**评分流**产物，不是 ILA 流） |
| 综合/实现选项 | `-no_lc` + `-fanout_limit 128` + `--pblock-range CLOCKREGION_X0Y1:CLOCKREGION_X2Y3` + `--contain-routing` |
| RTL 指纹 | 见 `results/uart_done.capture.json` 的 `rtl_sha256` |

## 2. 为什么用 UART 而不是 ILA 验证（关键）

- **带 ILA 的网表在 150 过不去时序**（−0.293~−0.514）：调试核在高频抢布线；
- **评分流只差 0.172 ns**，补齐后 **WNS +0.000** ⇒ 交付的必须是**评分流那份网表**；
- 于是观测通道改用 **UART**：软件把日志镜像到 `MMIO_UART_TX (0xA0000010)`
  （打印发生在 `stop_time()` 之后 ⇒ 不污染测量窗口，ticks 逐位不变）。

## 3. 命令

```powershell
cd D:\USER\Desktop\FPGA\FPGA
# 1) 重建（如需）: 先确认时钟三处同源 + 重建镜像
python tools\mk_cm_hw.py 4600
python tools\fpga_workflow.py synth --no-lc --fanout-limit 128 `
    --pblock-range CLOCKREGION_X0Y1:CLOCKREGION_X2Y3 --contain-routing `
    --tag deliv150 --record --status keep
# 2) 只烧写（不采集）
cmd /c fpga\prog_uart.bat
# 3) 读串口（先开监听, 再烧写! 程序配置完就跑, 14 秒后打印）
python tools\uart_capture.py --list
python tools\uart_capture.py --port COM13 --seconds 40 --out .fpga-cache\logs\uart_150.txt
```
**注意顺序**：`uart_capture.py` 必须先起监听，再 `prog_uart.bat`；否则 14.5 秒后的输出会错过。

预期判据（全部满足才算 PASS）：
```
Total ticks ≈ 2,131,483,600（±0.5%）   Iterations/Sec ≈ 328   Total time ≈ 14 s（>=10s ✓）
Correct operation validated            crclist 0xe714  crcfinal 0x382f
[portme] rate gate: clk=150000000 Hz ... min10s=ok
```

## 4. 回退档（都已上板验证过）

| 档 | 验证通道 | 备注 |
|---|---|---|
| **150 MHz** | UART | 当前交付（压线 WNS +0.000） |
| 138.75 MHz | ILA + UART | WNS +0.033/+0.050；调试核轻，两条通道都过 |
| 128.125 MHz | ILA | 候选 B 树（无 C-12c，CM/MHz 2.2063） |

**换档三处必须同源**：`fpga/top_a100t.sv` 的 `.CLKFBOUT_MULT_F`/`.CLKOUT0_DIVIDE_F`/`.CLK_HZ` +
`fpga/daVinciPro.xdc` 的 `create_generated_clock -multiply_by/-divide_by`；改完跑
`python tools\mk_cm_hw.py <iters>` 再重建。**并且：见到任何 WNS，先用 `period = 1000/fmax + WNS`
反推约束周期、对到标准档，再往下推理**（这条规矩已写进 `core.sv`/`ex_mem_reg.sv` 文件头）。

## 5. 已知环境坑

1. **`IP_Flow 19-3505` 间歇故障**：建 ILA 像前彻底清 `fpga/ila_proj.*` 与 `fpga/.Xil`，重试通常就过。
2. **Vivado 在"几乎不可行的目标"上会确定性崩溃**（`EXCEPTION_ACCESS_VIOLATION`，rc=3221225477）：
   `--fanout-limit 64`/`--retiming` 在 150 档都触发过。
3. **非单调/不可插值**：同配置不同 Pblock 差 0.1~0.3 ns；**WNS=+0.000 是合格但要交叉验证**。
4. **脚本必须纯 ASCII**；**`.bat` 用极简样板**（`call settings64.bat` + `cd /d` + `vivado -mode batch`）；
   Tcl 里用 **`open_hw`**（不是 `open_hw_manager`）。注释里别写方括号伪代码。
5. **31 位 tick 闸门**：每迭代 463,366 拍 ⇒ 迭代上限 **4611**；越过它 `mk_cm_hw` 会 BLOCK 并提前返回
   （镜像与 build.json 都不更新，看起来像"没报错"）。
6. **串口必须"先监听后烧写"**（见 §3）。

## 6. FLASH 自启动（2026-10-17 已完成并验证）

**现状**：板子的 QSPI FLASH 里已经烧好 **150 MHz** 的启动镜像，**断电重启即自启动**，无需 JTAG。

```powershell
# 重新构建 SPIx4 启动镜像（注意两个 env）
$env:SPI_BOOT_X4 = '1'; $env:BIT_NAME = 'cpu_a100t_spix4.bit'
python tools\fpga_workflow.py synth --no-lc --contain-routing --fanout-limit 128 `
    --pblock-range CLOCKREGION_X0Y1:CLOCKREGION_X2Y3 --place-directive AltSpreadLogic_high `
    --tag spix4-150 --record --status measure
# 烧写 + 读回校验（脚本自带 accessor 加载与 16MB diff）
powershell -File tools\flash_boot.ps1 -Bit "D:/USER/Desktop/FPGA/FPGA/fpga/cpu_a100t_spix4.bit" -Iface SPIx4
```
**判据**：`VERDICT=PROGRAM_OK` + `VERIFY=PASS`（读回逐字节一致）—— **不要只看"Flash programming completed successfully"**
（PITFALLS R44：`VERIFY=0`+`CFG_PROGRAM=0` 时它照样打印成功）。

**已验证**：断电重启后从 QSPI 自动加载、以 150 MHz 运行、UART 在上电约 15 s 后打印 CoreMark 结论；
`Total ticks = 2,128,330,449` 与 JTAG 通道**逐位一致**。

⚠ **余量说明**：150 MHz 的 WNS 是 **+0.007 ns（压线）**。尝试过 6 种"加余量"方案（降频到 148.44/146.875、
VCO 1200、opt_design 的 ExploreWithRemap、其它 Pblock/放置/物理指令）**全部更差** —— 150 档正是这套工具
对该设计的"甜点"。若要更大工程余量，回退到 **138.75 MHz**（WNS +0.033/+0.050，ILA+UART 双验证过）。
