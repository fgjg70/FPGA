# AI 档上板验证步骤（YOLO-Fastest int8 · UART 读回）

> 状态：**2026-11-01 JTAG 探测 `no current hw_target` —— 板卡当前不在位**，本文件是"板子连上就能照做"的清单。
> 判据全部机器可判定：程序自己把 `RESULT : PASS/FAIL` 写进 dmem 日志并（上板模式）打印到 UART。

---

## 0. 前置（一次性）

| 项 | 要求 |
|---|---|
| 板卡 | 正点原子达芬奇Pro XC7A100T，JTAG（FT2232H/Digilent 兼容）可被 Vivado 识别 |
| 串口 | 板上 **uart_txd=D17 → USB-TTL 的 RXD**，**uart_rxd=E14 ← USB-TTL TXD**，共地；115200 8N1（板载 FT2232H 只有 JTAG，无 COM） |
| 构建产物 | `fpga/cpu_a100t_nn.bit`（AI 档，默认名，**不会覆盖交付档 `cpu_a100t.bit`**） |
| 程序镜像 | 已烧进 bitstream：`sim/prog/yolo_board.hex`（imem）+ `sim/prog/yolo_board.dmem.hex`（dmem）+ `sim/prog/yolo/yolo_wq.hex` 的 4 段切分（权重/Q BRAM 初值） |

## 1. 构建 AI 档 bitstream（若还没有）

```powershell
cd D:\USER\Desktop\FPGA\FPGA
# 先确认模型产物在: sim/prog/yolo/{plan.json,yolo_wq.hex} + sw/yolo_plan.h
python tools\fpga_workflow.py synth --nn --prog yolo_board ^
    --no-lc --fanout-limit 128 --pblock-range off --contain-routing ^
    --place-directive AltSpreadLogic_high --timeout 7200
# 判据: 日志里 BUILD_TIMING=PASS (= 150MHz 达标) 且 BUILD_OK
# 输出: fpga/cpu_a100t_nn.bit  (sha256 记录到 results/ai-accel/impl/)
```

> 当前（Round 2）状态：引擎流水化进行中。若 `BUILD_TIMING=FAIL`，**不要烧**——先把引擎时序修到
> OOC WNS ≥ +2ns，或按"AI 档降到 95.45/75 MHz"的方案改时钟（三处同源：top MMCM / XDC / CLK_HZ）。

## 2. 开串口监听（**必须先起监听，再烧写**）

```powershell
python tools\uart_capture.py --list
# 假设枚举出 COM13（每次上电可能变化，以 --list 为准）
python tools\uart_capture.py --port COM13 --seconds 60 --out .fpga-cache\logs\yolo_board.txt
```

## 3. 烧写 AI 档 bitstream（JTAG，不写 QSPI FLASH）

```powershell
cd D:\USER\Desktop\FPGA\FPGA
set UART_BIT=D:\USER\Desktop\FPGA\FPGA\fpga\cpu_a100t_nn.bit
cmd /c fpga\prog_uart.bat
# 判据: 日志末尾 PROGRAMMED / VIVADO_EXIT=0
```

## 4. 期望输出（板级判据）

AI 档 `yolo_board` 程序（非 `YOLO_HW_ONLY`）会在板上跑两遍并打印：

```
[yolo] YOLO-Fastest v1.1 int8 (Xilinx A100T NPU)
[yolo] ops=108 in=128x128x3
[yolo] input_csum=0xcfd271c5 exp=0xcfd271c5 OK
[yolo] sw_bad=0 sw_cycles=<软件基线周期>
[yolo] hw_bad=0 hw_cycles=<硬件遍总周期> npu_cycles=<>  
[yolo] speedup_x100=<...> (<n.nn>x)
[yolo] speedup_npu_x100=<...> (<n.nn>x, sw vs NPU-only)
[yolo] RESULT : PASS
```

**PASS 判据（全部满足）**：
1. `input_csum` OK；
2. `sw_bad=0`（软件基线逐 op 对齐 golden）且 `hw_bad=0`（硬件逐 op 位精确）；
3. `npu_cycles` ≈ 1,216,578（±2%，引擎流水化后会略增，以 engine-report 的公式为准）；
4. 最后一行 `RESULT : PASS`。

> `speedup_x100` = `sw_cycles/hw_cycles`（硬件遍含 CPU conv0/搬运/checksum 等）；`speedup_npu_x100`
> = `sw_cycles/npu_cycles`（NPU 纯计算）—— **两个都报**，避免用 debug 开销稀释口径。

## 5. 失败时怎么查（按顺序）

| 现象 | 先查 |
|---|---|
| UART 完全无输出 | LED0 是否闪烁（MMCM/复位）；`baud` 接线是否接反；重新 `--list` 选对 COM |
| `input_csum MISMATCH` | CPU 窗口路径（nn_subsys 的 `cpu_off = cpu_addr - NN_BASE`）、`+nnwq`/BRAM 初值切分 |
| `sw_bad≠0` / `hw_bad≠0` | 具体 bad op 编号 → 用 `results/ai-accel/proto/engine/make_e2e_case.py` 重放该层 |
| 程序跑不完/超时 | 先确认 AI 档时钟是否可行（fmax），不要用未收敛的 bitstream |

## 6. 备选：写 QSPI FLASH 断电自启动（演示用）

确认 JTAG 通道 PASS 之后再做（`tools/flash_boot.ps1`，**注意它会覆盖板上现有 CoreMark 150MHz 自启动镜像**；
如果不希望覆盖，可以先把交付档镜像备份/重烧）。步骤见 `results/NEXT-BURN.md` §6。
