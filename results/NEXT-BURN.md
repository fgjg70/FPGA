# 当前交付档（2026-11-03 起）—— **150 MHz 交付档配方已修好，待重烧上板** 🎯

> 本文件由 Lead 维护：**每次换档就更新这里**。只写"要做什么、期望看到什么、出问题怎么办"。
> 轨迹与"为什么"在 `results/CHANGELOG.md`（§12 = 150 达成全过程），主频核实见 `results/FREQ-VERDICT.md`。

## 0. ⚠ 2026-11-03 配方漂移已修 —— 板上那份是 `-Os`，不是交付档配方

**发现**：`tools/mk_cm_hw.py` 硬编码 `opt = "-Os"`，而 `tools/build_sw.py` 用
`-O2 -mbranch-cost=1 -fira-loop-pressure`。两者**写同一个文件** `sim/prog/cm_hw.hex`
⇒ 照 §3 烧上去的永远是 `-Os` 镜像，而交付档 tag `deliv150-o2ira` 宣称的 **405.9 永远烧不出来**。
**物证**：`results/uart_final150.txt` 第 9 行 `Compiler flags : -Os -march=rv32im -mabi=ilp32`。

**已修**（R54）：

| 修法 | 落点 |
|---|---|
| 配方提升为**单一事实来源** | 新增 `tools/cm_recipe.py`（`CM_OPT`/`cm_flags_str()`），`build_sw.py` 与 `mk_cm_hw.py` 都从它取 |
| **漂移即失败**闸门 | `mk_cm_hw.py` 比对"仿真日志里 CoreMark **自报**的 Compiler flags"与本次配方，不一致直接 BLOCK |
| 清单带上配方指纹 | `cm_hw.build.json` 新增 `opt`/`march`/`compiler_flags` |
| 端到端闭环 | `tools/uart_capture.py` 新增 `--parse` 交叉核对：配方/迭代数/tick/≥10 s 四项逐项对清单 |
| 第二处漂移 | `build_sw --with-hw` 原写死 `ITERATIONS=3000`（150 MHz 下只跑 **7.39 s**，跌破赛题 10 s 门且与清单矛盾）⇒ 改为**从清单读**，无清单则**不构建** cm_hw |

**当前状态**：RTL 一行未改；镜像/清单已同源（`-O2+bc1+ira`、4600 迭代、expect_tick 1,699,727,600）；
`verify --force` **PASS 16**。**但板上那份仍是 `-Os`** ⇒ **对外仍只能宣称 324.19**，
405.9 是**派生值**，要拿到它必须按 §3 重烧一次。

## 1. 烧什么

| 项 | 值 |
|---|---|
| 频率 | **150 MHz**（VCO = 50 × 21 = 1050, N=7；XDC `-multiply_by 21 -divide_by 7`） |
| **编译配方** | **`-O2 -mbranch-cost=1 -fira-loop-pressure`**（= `tools/cm_recipe.py` 的 `CM_OPT`）—— 板上自证见 §3 的 `Compiler flags` 行 |
| 迭代 | **4600**（`-O2` 口径每迭代 **369,506** 拍） |
| 预期 tick | **1,699,727,600**（31 位占用 79.1%） |
| 预期时长 | **11.33 s**（赛题要求 ≥ 10 s，余量 1.33 s） |
| 预期性能 | **CM/MHz 2.7063**／绝对吞吐 **≈ 405.9**（`iterations×clk/ticks`） |
| 镜像体积 | imem **16,112 B / 16,384 B（98.3%）**—— **只剩 272 B 余量，加代码前先量体积** |
| 正确性 | `Correct operation validated`；`crclist 0xe714 / crcmatrix 0x1fd7 / crcstate 0x8e3a / crcfinal 0x382f` |
| 时序 | 评分流 **WNS +0.007 MET**（**压线**，见 §6 的余量说明）；**不带 ILA**（ILA 流在 150 过不去） |
| 综合/实现选项（合法配方） | `--no-lc --fanout_limit 128 --pblock-range off --contain-routing --place-directive AltSpreadLogic_high` |
| 约束合法性 | **0 Critical Warning**（旧配方用越界 Pblock `X0Y1:X2Y3` → `CRITICAL [Vivado 12-4433]`，而该 Pblock **从未生效**；改成 `off` 才复现 +0.007） |

### 1b. 上一份已上板验证的镜像（`-Os`，**历史值**）

| 项 | 值 |
|---|---|
| 编译配方 | `-Os`（2026-10-17 实测，**不是**交付档配方） |
| 实测 tick | **2,128,330,449**；`Iterations 4600`／14 s／`Iterations/Sec 328`／**CM/MHz 2.1613**／**绝对吞吐 324.19** |
| 证据 | `results/uart_final150.txt` + `.capture.json`；QSPI 自启动 `results/uart_flash_boot_final.txt`（tick 逐位相同） |
| bitstream | `fpga/cpu_a100t.bit` sha256 `794b50e6…`；`cpu_a100t_spix4.bit` sha256 `ef3c970a…` |

⚠ **这条档是"合法但非最优"**：它满足 ≥10 s、CRC 全对，但白扔了 25% 性能。
重烧新版配方后 **324.19 → ≈405.9**。

## 2. 为什么用 UART 而不是 ILA 验证（关键）

- **带 ILA 的网表在 150 过不去时序**（−0.293~−0.514）：调试核在高频抢布线；
- **评分流只差 0.172 ns**，补齐后 **WNS +0.000** ⇒ 交付的必须是**评分流那份网表**；
- 于是观测通道改用 **UART**：软件把日志镜像到 `MMIO_UART_TX (0xA0000010)`
  （打印发生在 `stop_time()` 之后 ⇒ 不污染测量窗口，ticks 逐位不变）。

## 3. 命令

```powershell
cd D:\USER\Desktop\FPGA\FPGA
# 1) 重建上板镜像（配方单一来源, 会核对仿真日志自报的 flags, 漂移即 BLOCK）
python tools\mk_cm_hw.py 4600
# 2) 综合（配方与之前完全一致, RTL 一行未改 ⇒ 预计网表/时序不变）
python tools\fpga_workflow.py synth --no-lc --fanout-limit 128 `
    --pblock-range CLOCKREGION_X0Y1:CLOCKREGION_X2Y3 --contain-routing `
    --tag deliv150 --record --status keep
# 3) 只烧写（不采集）
cmd /c fpga\prog_uart.bat
# 4) 读串口（先开监听, 再烧写! 程序配置完就跑, 11 秒后打印）
python tools\uart_capture.py --list
python tools\uart_capture.py --port COM13 --seconds 40 --out .fpga-cache\logs\uart_150.txt
```
**注意顺序**：`uart_capture.py` 必须先起监听，再 `prog_uart.bat`；否则 11.3 秒后的输出会错过。

预期判据（全部满足才算 PASS）：
```
Total ticks ≈ 1,699,727,600（±0.5%）   Iterations/Sec ≈ 406   Total time ≈ 11 s（>=10s ✓）
Compiler flags : -O2 -mbranch-cost=1 -fira-loop-pressure -march=rv32im -mabi=ilp32
Correct operation validated            crclist 0xe714  crcfinal 0x382f
[portme] rate gate: clk=150000000 Hz ... min10s=ok
```

**`uart_capture.py` 会自动与构建清单交叉核对**（配方 / 迭代数 / tick / ≥10 s 四项），
最后一行给 `=> PASS` 或 `=> FAIL`。**"Compiler flags" 那一行是"烧的是哪份镜像"的运行期自证** ——
它必须与 `sim/prog/cm_hw.build.json` 的 `compiler_flags` **逐字相同**。
（用历史日志 `results/uart_final150.txt` 试 `--parse` 会报 FAIL —— 那份是 `-Os` 旧配方。）

## 4. 回退档

| 档 | 验证通道 | 备注 |
|---|---|---|
| **150 MHz** | UART | 当前交付（压线 WNS +0.000） |
| 138.75 MHz | ILA + UART | WNS +0.033/+0.050；调试核轻，两条通道都过 |
| 128.125 MHz | ILA | 候选 B 树（无 C-12c，CM/MHz 2.2063） |

**换档三处必须同源**：`fpga/top_a100t.sv` 的 `.CLKFBOUT_MULT_F`/`.CLKOUT0_DIVIDE_F`/`.CLK_HZ` +
`fpga/daVinciPro.xdc` 的 `create_generated_clock -multiply_by/-divide_by`；改完跑
`python tools\mk_cm_hw.py <iters>` 再重建（它会按新主频重算 ≥10 s 所需迭代数）。
**并且：见到任何 WNS，先用 `period = 1000/fmax + WNS`
反推约束周期、对到标准档，再往下推理**（这条规矩已写进 `core.sv`/`ex_mem_reg.sv` 文件头）。

## 5. 已知环境坑

1. **`IP_Flow 19-3505` 间歇故障**：建 ILA 像前彻底清 `fpga/ila_proj.*` 与 `fpga/.Xil`，重试通常就过。
2. **Vivado 在"几乎不可行的目标"上会确定性崩溃**（`EXCEPTION_ACCESS_VIOLATION`，rc=3221225477）：
   `--fanout-limit 64`/`--retiming` 在 150 档都触发过。
3. **非单调/不可插值**：同配置不同 Pblock 差 0.1~0.3 ns；**WNS=+0.000 是合格但要交叉验证**。
4. **脚本必须纯 ASCII**；**`.bat` 用极简样板**（`call settings64.bat` + `cd /d` + `vivado -mode batch`）；
   Tcl 里用 **`open_hw`**（不是 `open_hw_manager`）。注释里别写方括号伪代码。
5. **31 位 tick 闸门**：`-O2` 配方每迭代 **369,506** 拍 ⇒ 迭代上限 **5813**
   （`-Os` 口径是 463,366 拍 ⇒ 4611）；越过它 `mk_cm_hw` 会 BLOCK 并提前返回
   （镜像与 build.json 都不更新，看起来像"没报错"）。
6. **串口必须"先监听后烧写"**（见 §3）。
7. **⚠ 配方漂移（R54）**：`cm_hw.hex` 有**两个**写入者（`build_sw --with-hw` 与 `mk_cm_hw.py`），
   配方/迭代数一旦不一致就是"镜像与清单互相矛盾"，而**板上跑得更快看起来像好成绩**。
   现在的防线：`cm_recipe.py` 单一来源 + `mk_cm_hw` 的**漂移即失败**闸门 +
   `uart_capture.py` 的端到端交叉核对。**改配方只改 `tools/cm_recipe.py` 一处。**

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
