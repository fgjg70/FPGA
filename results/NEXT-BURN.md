# 下次上板（2026-10-12）操作单

> 由 Lead 在 2026-10-11 夜间准备。**所有产物已本地验证并提交推送**（`origin/main`），
> 可直接烧录。板子需上电、JTAG 可用。

## 1. 烧什么（已就绪）

| 项 | 值 | 来源 |
|---|---|---|
| 频率 | **128.125 MHz** (VCO 1025 = 50×20.5, N=8; XDC `-multiply_by 41 -divide_by 16`) | `fpga/top_a100t.sv` / `fpga/daVinciPro.xdc` |
| 迭代 | **4700** | `sim/prog/cm_hw.build.json` |
| 预期 tick | **2,133,527,400** | 由 `mk_cm_hw.py` 从仿真日志的"每迭代 453,942 拍"推导 |
| 采集等待 | 21 s（内置） | 同上 |
| 预期运行时长 | **16.65 s**（赛题要求 ≥10 s，余量 6.65 s） | 计算 |
| ILA 像时序 | `ILA_TIMING=PASS`（WNS +0.027） | `fpga/ila_build.log` |
| RTL 指纹 | `8c1307d4ac1d06d40d5c7027ee6e65357f9886a7a66e5ce04fd1bf726f309c67` | 同上 |

## 2. 命令

```powershell
cd D:\USER\Desktop\FPGA\FPGA
cmd /c fpga\jtag_probe.bat        # 先确认识别到器件 (IDCODE 0x13631093)
cmd /c fpga\ila_cap_done.bat      # 烧写 + 采集 (脚本内置 21 s 等待)
python tools\fpga_workflow.py hw  # 判读
```

预期判读（全部满足才算 PASS）：
```
ila_ctrl     = 0xC2  -> locked=1 done=1 pass=1 fail=0 illegal=0
score_result = 0x??..      bit31=1 -> 结果有效
tick         ≈ 2,133,527,400  (门限偏差 ≤0.5%)
时长         ≈ 16.65 s @128.125MHz  (>=10s ✓)
dbg_pc       静止在结尾 `j .` (dbg_instr=0x0000006F)
```
**注意**：`hw` 会在采集超过 20 分钟时判 STALE 并拒绝作为结论 —— 采集完请尽快判读。

## 3. 关于"5000 迭代" —— 当前打包方式下的硬上限

`tick` 计数器在硬件里是 **64 位**（`mmio_subsys.sv:126`），限制不在硬件，而在**上报打包**：
软件写 `MMIO_RESULT = (valid?0x80000000:0) | (ticks & 0x7fffffff)`
（`sw/core_portme.c:152`），**bit31 被借去当"CRC 有效"标志**。于是 tick 只有 31 位可用：

```
每迭代 453,942 拍; 31 位上限 2,147,483,647
  4700 迭代 -> tick 2,133,527,400   OK   (含 0.5% 安全余量, 16.65 s)
  4730 迭代 -> tick 2,147,145,660   超出含余量上限 2,136,799,648  => 闸门 BLOCK
  5000 迭代 -> tick 2,269,710,000   超出 31 位上限            => 闸门 BLOCK
```
安全余量的理由：**实测硬件 tick 比仿真外推低 0.151%**（105 MHz 档 1,359,770,617 vs
1,361,826,000），方向虽有利，但拿 0.016% 的余量去赌不稳妥；回绕后的 tick 会**看起来
像"变快了"**，正是这个闸门要防的。闸门在 `tools/mk_cm_hw.py`。

### 要真正做到 5000（可选，需一次单独改动 + 一次单独上板）

不需要改 RTL，只改**打包与判读**（有效性标志从 `score_result` 的 bit31 搬到
`ila_ctrl` 的 `pass_r` —— 而 `pass_r` **本来就是 CPU 自己写的**（tohost=1），
而且 `hw` 判据**已经要求** `pass=1`）：

1. `sw/core_portme.c:152-153`：写满 32 位 tick（去掉 `| 0x80000000`）；
2. `tools/fpga_workflow.py:2778`：`tick = res`（全 32 位），有效性取自 `pass`；
3. `sim/tb_sw.sv:564-565`：`CRC-valid` 那行打印随之失效，需改口径（否则是过期打印）；
4. `results/coremark.csv` / 文档里的打包说明同步；
5. 重新 `verify --force`（PASS 12）+ 重建镜像与 ILA 像。

**代价**：明天第一次烧的就是"新打包方式"，一旦判读端有问题会浪费一次板子会话。
**收益**：5000 迭代 = 17.71 s（比 4700 多 **1.06 s，6%**）。
⇒ Lead 的建议：**先烧 4700 确认 128.125 MHz 这一档**，把"真 5000"作为下一次单独改动。

## 4. 回退路径（若今天这版有问题）

```powershell
python tools\mk_cm_hw.py 3000     # 回到已上板验证过的 3000 迭代镜像
cmd /c fpga\build_ila.bat         # 重建 ILA 像 (重建前先清 ila_proj.* 与 .Xil, 见下)
cmd /c fpga\ila_cap_done.bat
python tools\fpga_workflow.py hw
```
**已上板验证过的档位**（可随时回退对照）：75 / 105 / 118.75 / **128.125 MHz**
（128.125 档的 tick 1,359,770,617 @3000 迭代 = 10.61 s）。

## 5. 已知环境坑（都在 `skills/fpga-riscv-a100t/PITFALLS.md` 有记录）

1. **`IP_Flow 19-3505` 间歇性 IP 生成失败**：建像前必须**彻底清掉** `ila_proj.xpr`
   `.srcs/.cache/.hw/.ip_user_files/.Xil`，并确认没有 Vivado 实例在跑；
   清干净后**重试一次**通常就过（实测：118.75 首次失败、重试成功；128.125 第二次成功）。
   **别把 IP 故障误记成"这一档时序不够"** —— 那会导致白白降档。
2. **不要同时跑两个 Vivado**（IP 生成器初始化失败的头号根因）。
3. 含中文的 `.ps1` 用 `powershell -File` 跑会被按 GBK 解码而**吃掉字符串引号** ⇒
   编排脚本一律纯 ASCII。
