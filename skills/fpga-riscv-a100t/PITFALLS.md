# 错误台账 — 症状优先速查

> 用途: 长任务里防止重复踩坑。**先查症状, 再看原因和修法。**
> 每条都是本工程真实踩过的, 不是臆测。

---

## ⚠️ 一、反复犯过的 (最高优先级)

### R1. 改了 A, 忘了同步 B —— 用旧产物静默跑 ✅踩过 5+ 次
这是本工程最高频的错误, 且**全部是静默失败** (不报错, 结果不对或不变)。

| 改了什么 | 必须同步 |
|---|---|
| 新增 RTL 文件 | `fpga/build.tcl` 的 read_verilog 列表、`tools/run_coremark.py` 的 RTL 列表、ModelSim 的 vlog 列表 |
| 改软件源码 | **重新构建 .hex**, 再**重新综合** bitstream (imem/dmem 是综合时 $readmemh 进去的) |
| 改 link.ld 地址 | portme.c / crt0.S / core_portme.c / top_a100t.sv / 三个 tb 的 TOHOST_ADDR / **sim/prog/*.S 里硬编码的地址** |
| 改 .S 文件 | **重新用 asm.py 汇编** (tb 用的是 .hex 不是 .S) |
| 改 RTL | 重新 vlog + vsim; 上板还要重新综合 |
| 改 tb 里的预期值 | 想清楚"预期"本身对不对 (见 R3) |

**识别信号**: 结果与上次"完全一致" (ticks 一模一样、镜像逐字节相同)、或程序跑到 `j .` 自旋。

### R2. .bat 里写中文 → 每行首字符被吃掉 ✅踩过 2 次
`cmd` 用 OEM 代码页解析 .bat, 中文会让整行错位:
`'et' 不是内部或外部命令`、`'cho' 不是内部或外部命令`。
**修法: .bat 一律纯 ASCII** (echo 的说明文字也用英文)。

### R3. 测试期望值自己算错 ✅踩过 1 次
`0xFFFFFFEC / 3` 我写成 1431655762, 实际是 **1431655758**。
**修法: 期望值先独立验算一遍** (换成好算的数, 比如除以 16)。

### R4. 陷阱处理程序破坏了它自己要用的寄存器 ✅踩过 1 次 (P1 接线后才暴露)
`sim/prog/trap.S` 用 `t0` 存 handler 地址, 而 handler 自己也用 `t0`
(`csrr t0, mcause` / `csrr t0, mepc`) —— 一进陷阱 `t0` 就被覆盖成 `mcause`。
于是主程序后面那句 `csrw mtvec, t0` 把 **mtvec 写成了 11**, 下一次陷阱直接跳到
`0x00000000` 跑飞。

**这个 bug 在"陷阱没接线"时永远不会暴露**: ecall 根本没陷入, handler 从没执行过,
`t0` 一直是好的。P1 接线一完成才现形 —— 与 SKILL 9.3 的 JAL 前递是同一类:
**"今天触发不了"的代码, 加新特性后会变成真 bug。**

**修法**: handler 与"安装陷阱的代码"**不要共用寄存器**。trap.S 现在用 `s1` 存
handler 地址 (handler 只碰 `t0/s0/s2/s3/t1`)。
**识别信号**: 第二次陷阱跳到 `0x00000000` 或某个小整数, 而首次陷阱正常。

### R5. 调试标志与它要监视的事件不在同一级流水 ✅踩过 1 次
`dbg_illegal` 曾在 **ID 段**锁存 (`id_ctrl.illegal`), 但陷阱是 **EX 段**裁决的
(`trap_enter` 由 `id_ex_ctrl.illegal` 驱动)。ID 段比 EX 段早整一拍 ->
标志在"非法指令还在 ID、trap 尚未触发"那一拍就置位, 与 `trap_enter` 对不上,
`tb_core` 立刻 `$fatal`, 测试程序根本没机会跑 handler。
**修法**: 判据必须与事件同级 —— 用 `id_ex_ctrl.illegal`。
**诊断方法**: 在 `negedge clk` 上逐拍打印 (见下条)。

---

## 一·五、逐拍诊断: 粘滞标志 + $fatal 会让"猜"变成唯一手段 (P1 血的教训)

调 `tb_core_trap` 时连猜错两次 (先报 `PC=0x8000005c`, 又报 `0x80000058`, 真正的非法
指令在 `0x80000054`)。根因是**证据不够**:

1. `dbg_illegal` 是**粘滞**标志 (只置位不清零), 值本身不含"哪一拍、哪条指令"的信息;
2. `tb_core` 一看到它就 `$fatal`, **仿真当场终止** —— 事后拿不到任何上下文。

**解法 (已固化在 `tb_core.sv`, 加 `+illegal_trace` 启用)**:

```systemverilog
// 在 NEGEDGE 采样: 此刻组合逻辑已稳定, 而 tb 的 always_ff 还没在下一个
// posedge 置位并 $fatal —— 所以即使 $fatal 立刻终止仿真, 证据也已经打印出来。
always @(negedge clk) begin
  if (!rst && $test$plusargs("illegal_trace") && cycles >= 40) begin
    $display("[pre] cyc=%0d if_pc=0x%08x if_instr=0x%08x | ex_pc=0x%08x ex_illegal=%b",
             cycles, u_dut.if_pc, u_dut.if_instr, u_dut.id_ex_pc, u_dut.id_ex_ctrl.illegal);
    // 把 id_/ex_ 两级、pipe_stall、trap_enter、redirect、pc_src 一起打出来
  end
end
```

**两条通用经验**:
- **`posedge` 上采样只能看到"上一拍"的状态** (NBA 还没更新), 追时序问题时优先用 `negedge`;
- 逐拍打印时**必须同时打印 ID 段和 EX 段**, 并标注哪个信号属于哪一级 ——
  这次就是把 `if_pc`/`id_ctrl.illegal` (ID 段) 和 `ex_illegal`/`trap_enter` (EX 段)
  混在一起读, 才误判成"陷阱没触发"。

### R6. `mcause` 的位布局被写错 —— 只在"读 mcause[31] 判中断"时才暴露 ✅踩过 1 次
`csr_file.sv` 原来写的是 `mcause <= {27'b0, trap_cause};`, 而 `trap_cause` 是紧凑的
5 位 `{is_interrupt, code[3:0]}` —— 于是**中断位被放到了 bit4**, 而规范要求它在 **bit31**。

实测症状: 中断确实进了 (mstatus.MIE 被清、handler 也跑了), 但 `mcause` 读回
`0x00000017` 而不是 `0x80000007`, 于是 handler 里"检查 mcause[31] 判断是中断"的
分支全部走错, 中断处理程序认为收到的是异常。

**为什么一直没暴露**: 之前只测同步异常, 而异常的 bit31 本来就是 0,
`{27'b0, cause}` 与正确布局**恰好一致**。只有中断才有 bit31=1。

**修法**: 显式重排 `mcause <= {trap_cause[4], 27'b0, trap_cause[3:0]};`
**通用教训**: 两个"看起来都是原因码"的表示之间**必须查规范确认位布局**,
不要凭"字段名一样"就直连。紧凑编码 (5 位) 与寄存器布局 (32 位) 是两回事。

### R7. Zicsr 立即数形式只有 5 位, 高位掩码是**静默**的 ✅踩过 1 次
`csrsi mie, 0x80` 想置 MTIE (mie 的 bit7 = 0x80), 但规范规定 CSRRSI/CSRRCI 的
立即数取自 `instr[19:15]`, **只有 5 位, 上限 31**。`0x80 & 0x1F = 0`,
所以这条指令实际等价于 `csrsi mie, 0` —— **中断永远使能不上, 且不报任何错**。

症状: 定时器测试一直自旋等中断, 最后靠打印 `ie_mtie` 才定位。
**修法**: 任何 bit ≥ 5 的 CSR 位都用寄存器形式: `li t0, 0x80` + `csrw mie, t0`。
(对照: `csrsi mstatus, 8` 没问题, 因为 MIE 是 bit3 < 32 —— 所以这个坑很容易漏。)

### R8. 具名端口连接里的未声明信号会被**隐式声明**成 net ✅踩过 1 次
`.irq_timer (irq_timer)` 若 `irq_timer` 尚未声明, 仿真器会在此处隐式声明一条 net;
之后那句 `logic irq_timer;` 就变成重复声明 -> `vlog-2388 already declared in this scope`。
**修法**: **声明一律写在例化之前**。报错行号指向的是显式声明那行, 不是隐式声明处,
所以看上去像"我只声明了一次却报重复"。

### R9. 用错测试平台: `tb_core` 不接外设 ✅踩过 1 次
`tb_core.sv` 里 `ext_rdata` 恒 0、`irq_timer` 恒 0 (它只测 CPU 核, 这是**正确的**设计)。
把需要外设的程序 (碰 MMIO / 等定时器中断) 挂到 `tb_core` 上, 症状是
**MMIO 读回 0、中断永远不来**, 而 RTL 完全没问题。
**修法**: 涉及 MMIO/定时器/UART 的测试用 `tb_soc` 或 `tb_sw`; `tb_core` 只跑纯 CPU 程序。

### R10. PowerShell `Set-Content -Encoding UTF8` 会**写入 BOM**, 破坏 CSV/源码 ✅踩过 1 次
想改 `results/coremark.csv` 里一行 notes, 用了
`Set-Content -Path x.csv -Value $lines -Encoding UTF8` —— **PowerShell 5.x 的 `-Encoding UTF8`
会写入 BOM**(`EF BB BF`)。BOM 一进文件头, 首列列名就变成 `\ufeffdate`,
所有按列名索引的解析全部失配 —— 表现是 `report` 里所有数字变成 `-`, 而文件**看起来正常**。

**修法**: 不要用 PowerShell 读写工程里的文本/CSV 文件。用 Python:
```python
io.open(p, "w", encoding="utf-8", newline="")   # 无 BOM
```
或用 git 恢复 (`git checkout -- <file>`) 再重做改动。
**通用教训**: 涉及编码的改动, 改完**必须用消费方(解析器)验一遍**, 不能只看文件"能打开"。

### R11. 用 `split("\n")` 切 CRLF 文件会把首行和次行粘在一起 ✅踩过 1 次
同上那次: 文件是 CRLF, 我用 `text.split("\n")` 拆行再拼回, 每行尾部残留的 `\r`
让处理错位, 且重写后首个注释行与下一行**合并成一行**。
**修法**: 先 `text.replace("\r\n", "\n")` 归一化; 或者干脆用 `csv` 模块读写 CSV
(它会正确处理引号与换行, 自己拼逗号很容易把 `"a, b"` 这类带逗号的字段弄坏)。

### R12. `write_hw_ila_data` 覆盖已存在的 CSV 必须加 `-force` ✅踩过 1 次
不带 `-force` 时报 `ERROR: [Labtoolstcl 44-54] You must use the -force option to
overwrite existing file`。**坑在于抓取本身是成功的** (PROGRAMMED/ARMED/CAPTURE 都过了),
只有最后一步落盘失败 —— 症状是"全流程 OK 却没有结果文件", 很容易误判成抓取失败。
**修法**: `write_hw_ila_data -force -csv_file <path> hw_ila_data_1`。

### R13. `get_property REGISTER.IDCODE` 不是合法属性 ✅踩过 1 次
报 `ERROR: [Labtoolstcl 44-56] hw_device [xc7a100t_0] does not have a
[REGISTER.IDCODE] property`。**修法**: 用 `get_property IDCODE $dev`
(实测回二进制串 `00010011011000110001000010010011` = **0x13631093**, 与器件手册一致)。

### R14. `ITERATIONS` 只影响 **dmem 镜像**, imem 逐字节相同 —— 别把它当"没生效" ✅查过 1 次
用不同 `-D ITERATIONS=1` 与 `-D ITERATIONS=1200` 构建 CoreMark, 两个 **`.hex`(imem)
逐字节相同**, 只有 **`.dmem.hex` 不同**。

一度以为是"宏没生效"这个经典静默失败, 实测是**正常的**: CoreMark 把迭代数放在
**可写数据变量**里 (不在指令流里), 所以改迭代数**只改数据段**。

**但这条引出一个真风险 —— 与 R1 同源**:
本核是哈佛结构, imem 与 dmem 是**两个独立镜像**(`IMEM_INIT_FILE` / `DMEM_INIT_FILE`)。
改了 `ITERATIONS` 却只重建/只同步了一个镜像, 就会得到
**"新程序 + 旧迭代数"** 的组合, 而且**不报任何错** —— 表现是上板跑分时长莫名其妙。
**所以换迭代数时两个宏都必须重新生成 hex 并重新综合。**

判据: 想确认镜像对不对, **比对 `.dmem.hex`**, 不要只比 `.hex`。

### R15. PowerShell 会吃掉 `-D 'X="a b c"'` 里的内层引号 ✅踩过 1 次
在 PowerShell 里敲:
```
python tools/build_sw.py ... -D 'FLAGS_STR="-Os -march=rv32im -mabi=ilp32"'
```
PowerShell 剥掉单引号后, gcc 收到的是 `FLAGS_STR=-Os -march=rv32im -mabi=ilp32`
被当成**多个参数**, 于是报一堆
`error: 'Os' undeclared` / `'march' undeclared` / `'ilp32' undeclared`,
看起来像源码问题, 其实是**引号在 shell 层就丢了**。

**修法**: 别在 shell 里拼这种带内层引号的参数 —— **用 Python 侧 `subprocess` 传 argv
列表**(`tools/run_coremark.py` 就是这么做的, 一直是对的)。
本项目"构建一律走 .bat / Python 脚本"的约定, 一半原因就是这个。

### R16. `btb.sv` 注释里"64 项冲突是误判主因"是**错的** —— 实测方向预测器才是 ✅实测推翻
`btb.sv` 顶部注释写着:
> 但 64 项在 9.5KB 的 CoreMark 代码上按 `pc[7:2]` 索引会严重冲突(256 字节就一轮),
> **这是原方案条件分支误判率停在 8.6% 的主因**

**实测把这条推翻了**(在 tb_sw 里用层次化引用读 BTB 阵列, 纯观测不改 RTL):

```
条件分支总数 = 70135
BTB 有表项   = 67457 (96%)      <-- 表命中率很高
BTB 无表项   =  2678 ( 3%)
条件分支误判 =  6055
  其中 无表项(容量/冲突) = 1185  (19%)
  其中 有表项但方向判反  = 4870  (80%)   <-- 真正的主因
```

**96% 的分支在表里, 80% 的误判是"表命中了但方向预测错了"。**
所以扩容 BTB / 改组相联收益很小 —— **该改的是方向预测器**(2 位 Smith 对
CoreMark 这种分支行为不够用)。

**通用教训**: RTL 注释里的"根因分析"是**当时的猜测**, 不是实测结论。
动手改结构之前, 先花几分钟把"表命中率"和"方向准确率"分开量一下 ——
这两者的修法完全不同, 猜错方向会白做一整轮。

### R17. `vlog` 的宏必须写 `+define+NAME` —— 写 `+NAME` 会**静默不定义** ✅踩过, 影响最大的一次
本项目最严重的一次静默失败。工具里原本写的是:
```python
flags = ["+" + d for d in defines]          # -> vlog -sv +IMEM_REG_READ ...
```
**`vlog` 把 `+FOO` 当成未知选项, 宏根本不会被定义, 而编译"成功"**
(不返回错误), 于是仿真跑的是**没开宏的版本**。
实测对照 (最小复现):
```
vlog -sv +FOO         -> RESULT: FOO_NOT_DEFINED
vlog -sv +define+FOO  -> RESULT: FOO_DEFINED
```
正确写法: `+define+NAME`。

**为什么后果特别严重**: 综合侧用的是 Tcl 的 `-verilog_define`, **那个是生效的**。
于是形成"**综合开了宏、仿真没开宏**" —— 两边跑的不是同一份设计:
- 综合侧的数字是**真的**: 取指改寄存读后 LUT 3945 → 2656, load 结果改寄存器后
  fmax 65.3 → 75.0;
- 但仿真侧的"**ticks 逐位不变、零代价**"是**假的** —— 它测的一直是没开宏的版本。

修好宏传递后实测:
```
基线 (三宏全关)      PASS   ticks 423527
IMEM_REG_READ       FAIL   仿真 timeout (取指与 PC 配对错位)
LOAD_RESULT_REG     FAIL   仿真 timeout
BTB_GSHARE          PASS   ticks 449317   <- 能跑, 但比基线**慢 6%**
```
即两个"零代价优化"实际是**坏的**, 第三个是**负优化**。

**三条通用教训**:
1. **宏生效必须有自证**。现在每个宏生效的模块都会 `$display` 一行
   (如 `[btb] GSHARE ... ACTIVE`); 没有这种标志, "改了没效果"永远分不清是
   "算法无用"还是"宏没定义"。
2. **综合与仿真必须用同一份宏**。两边用不同机制传宏, 就必须核对两边都生效。
   `build.tcl` 与 `tools/fpga_workflow.py verify` 的默认值必须一致。
3. **"零代价"这种结论要格外怀疑**。这次两个优化都报"ticks 逐位不变",
   而真相是仿真根本没跑到那段代码 —— **"完全不变"往往是"没生效"的征兆**,
   不是"代价为零"的证据。

### R18. 上板验证的 bitstream 与评分版可能**不是同一个配置** ✅踩过
`build_ila.tcl`(上板调试版) 与 `build.tcl`(评分版) 各自维护自己的
`verilog_define`。ILA 版只给 `USE_ILA` + 两个镜像路径, **没带任何架构宏**。
后果: 上板 PASS 证明的是**"三个宏全不开"的配置**是对的, 而评分版当时默认开宏 ——
**"上板验证通过"并不等于"评分版通过了"**。

**修法**: 两边的默认值必须一致 (现已都改成三个宏全关), 并且改默认值时要问
"上板那次跑的是哪个配置"。

### R19. 数值结果不对时, **编译器也是嫌疑人** —— `gemm_sw` 循环形状在 `-Os`/`-O2` 下被编错 ✅踩过
写应用场景的 GEMM 时, 软件实现与参考实现 256 个元素里 255 个对不上。第一反应是
"核的乘法/访存有问题", 于是去查 64 位乘 (RV32 没有 64 位乘, 走 libgcc `__muldi3`)。
**结果核是干净的**: 32 位乘、64 位乘、普通赋值循环在三个优化级别下全部正确。

真因: **同一份源码, 只改优化级别结果就不同** (最小复刻 `sw/opt_probe.c`):

| 优化 | C(0,0) | C(0,1) | C(15,15) | 主机端期望 |
|---|---|---|---|---|
| **`-O0`** | **104** | **224** | **−40** | ✅ 完全一致 |
| `-Os` | −9 | 6 | −48 | ❌ |
| `-O2` | 88 | −3920 | −56 | ❌ |

出问题的**只有 `gemm_sw` 那一种循环形状** (`i/k/j` 顺序, 内层对 `B[k][j]` 连续取,
累加到 `C[i][j]`); 同样的矩阵与算法写成别的形状就正确。这是**优化通道在这个
形状上生成了错误代码**, 不是数据通路算错。

**三条教训**:
1. **数值不对时把"编译器"列为嫌疑之一**, 尤其当"算法逻辑看起来没问题"时。
   先做一组**独立**自检把核摘干净 (32 位/64 位乘、简单循环), 再怀疑编译器。
2. **`-O0` 通过不代表 `-Os` 通过**。本项目 `build_sw.py` 默认 `-Os`;
   数值类程序必须**逐级验证** (`-O0` / `-Os` / `-O2`)。
3. **校验和/参考实现必须走独立计算路径**。第一版 `checksum_ref` 我错写成
   "再对 C 求一次校验和", 于是两个校验和恒等、`match` 永远是 1 ——
   一个**永远为真、什么也证明不了**的检查。改成独立累加器 + 独立乘法路径后
   差异才暴露。**自己和自己比等于没比。**

**回归探针**: `sw/opt_probe.c` 保留下来。换工具链版本或改编译选项时先跑它,
它把候选构造拆开、每个算 FNV 校验和, 期望值可由主机端复算。
详见 `results/p5-compiler-bug.md`。

### R20. 验证工具可能**制造虚假证据** —— 板子掉线后仍报"上板 PASS" ✅踩过
`python tools\fpga_workflow.py hw` 只解析 `results/ila_done.csv`, 那是某一次抓取的
**快照**。板子掉线 / 没重新抓取时这个文件不会更新, 于是它**照样打印"上板验证 PASS"**
—— 把 4.5 小时前的旧结果当成新验证。

实测: 板子 22:13 已掉线 (JTAG 报 `No devices detected on target`), 而 `hw` 仍输出
`=> 上板验证 PASS`。是核对了 `ila_done.csv` 的 mtime (17:49) 才发现。

**为什么这类 bug 比功能 bug 更危险**: 它是**静默**的, 而且伪造的是"证据"本身 ——
功能 bug 会让测试失败, 这种 bug 会让**本该失败的验证显示通过**。

**修法 (两处, 都做了)**:
1. `hw` 子命令: 打印 CSV 抓取时间与"多少分钟前"; 超过 `--max-age-min` (默认 20)
   就**拒绝给验证结论**并返回非 0。措辞上把"结果本身是什么"与"本次是否算验证过"
   分开, 避免误导。
2. `ila_cap_done.tcl` 自证: 落盘后核对 `file mtime`, 与当前时间差 > 120 秒就
   `error "CAPTURE_STALE"`。**只打印 CAPTURE_OK 不算自证** —— 落盘静默失败时
   脚本依然"看起来成功"。

**通用教训**: 任何"读上一次产物并给结论"的工具都必须校验**新鲜度**, 否则它就成了
虚假证据的来源。这与 R17 (宏没生效却报编译成功) 同类:
**"看起来成功了"和"真的成功了"之间必须有一条硬判据。**

### R21. 往 Vivado 的 `.tcl` 里写中文会**毁掉文件** ✅又踩一次
`fpga/ila_cap_done.tcl` 里有一行中文注释, 实测含 **42 个非 ASCII 字节**
(`ila_cap_mark.tcl` 同样 42 字节)。Vivado 的 Tcl 按非 UTF-8 处理, 中文被掩码成
控制字符, 其中一些正好是 `0x0A` —— **把注释行劈成代码行**, 报 `invalid command name`。

**修法**: 两个文件都改成纯 ASCII (中文注释译为英文), 并加字节检查:
```python
bad = [i for i, x in enumerate(open(p, 'rb').read()) if x > 127]
```
**纪律**: 编辑 `.tcl` 后必须跑一次这个字节检查。`check` 里虽然会提醒, 但那是
"提醒"不是"拦截" —— 本项目已经两次栽在这上面 (第一次是编码掩码, 这次是我自己新写中文)。

### R22. **硬件在环掉线要立刻停下报告** —— 不要自己继续推代码 ✅判断错了一次
**用户明确要求**: 硬件在环 (HIL) 是本项目的核心验证手段, 板子掉线就等于
**闭环断了**。继续往前推代码 = 在无验证的情况下积累未验证的改动 —— 这正是本项目
吃过三次亏的模式 (P1/P3 的"零代价"结论、R17 宏失效, 都是"先推进、后验证"的产物)。

**实测**: 板子 22:13 掉线 (`No devices detected on target`), 我没有立刻停止,
而是自己又跑了 3 轮 (含两次失败尝试与一次回退), 到 22:2x 才报告。
**这是判断错误** —— 那 3 轮里产生的改动全部是"未上板验证"的。

**正确做法**: 发现掉线 -> **立即停止本轮并报告**:
- 掉线时间与报错原文
- 最后一次成功上板的时间与结论
- **在最后一次上板之后做过的改动清单** (即"未上板验证的改动")
- 恢复所需操作

**不要**: 反复自己重试、把"板子恢复"当成可以等的机会、或拿陈旧 CSV 当结论。

**配套 (已加进 `check`)**: 新增 `[HIL]` 一节, 打印最后一次上板数据的时间与年龄;
超过 1 小时就提醒"期间的 RTL 改动未经上板验证"。
配合 R20 的新鲜度门限 (板子掉线时 `hw` 会拒绝给结论并返回非 0),
**"板子不在位"这件事现在有两个地方会主动报出来**, 不再依赖我的自觉。

### R23. 症状是"读回 0", 真因是**地址算错** —— 别一头扎进读通路 ✅绕了三轮
**做 A 扩展时实测**: AMO 读回的内存值恒为 0。我连续三轮 (Round 25/26/27) 去查
**读通路** —— 查 `dmem_rdata`、查译码 mux、查 `sel_dmem_r` 寄存器、查 dmem 写端口
—— 每轮都"更接近", 每轮都不对。

**真因与读通路毫无关系**: `control_unit.sv` 的 `OPC_AMO` 分支**只设了 `alu_op`,
没设 `alu_a_src`/`alu_b_src`/`imm_fmt`**。而 `ctrl = '0` 的默认值恰好是

| 字段 | 默认 | 对 AMO |
|---|---|---|
| `alu_a_src` | `ALU_A_RS1`(0) | ✅ |
| `alu_b_src` | **`ALU_B_RS2`(0)** | ❌ b 取 rs2 而非立即数 |
| `imm_fmt` | `IMM_I`(0) | 值对但用不上 |

于是地址被算成 `rs1 + rs2`。实测: `sw` 写 `0x90003100`, 同一 `t0` 上的 AMO 却访问
`0x90003114` —— **差的正是当时 `t1` 的值 `0x14`**。AMO 读的是一个**从没被写过的字**,
当然是 0。

**教训 (可复用)**: **"读回 0"时, 先确认"读的地址对不对", 再怀疑读通路。**
一行打印 `addr` 就能省三轮。

### R24. 一条指令同时要"算子"和"地址"时, **不能让两者复用同一个 ALU 输出** ✅第二次踩
`core.sv` 里:
```systemverilog
ex_result = is_muldiv ? md_result : is_csr ? csr_rdata : ex_alu_out;
```
而 AMO 的 `alu_op` 是 `ALU_AMO_*` —— 那是算 **"应写回内存的新值"** (`old op rs2`)
的, **不是地址**。于是 LSU 拿到的"地址"其实是**算子结果** (`old + imm`),
地址恒差一个 `+4` (当时 `imm=4` 被当加法项加进去)。

**修法**: 给 AMO 一个**独立的地址加法器**
```systemverilog
ex_amo_addr = ex_rs1 + id_ex_imm;                       // I 型: rs1 + imm
assign ex_result = ... : id_ex_ctrl.amo_en ? ex_amo_addr : ex_alu_out;
```

> **这与 R?? (P3 的"跳转目标独立加法器") 是同一个坑的第二次出现** ——
> 见 `results/p3-fmax.md`。**只要一条指令的 ALU 输出被复用于两个语义
> (算子 / 地址), 就一定会错**。加新指令时先问一句:
> "这条指令的 `alu_op` 算的是地址, 还是算子? 如果两者都要, 就必须分开通路。"

### R25. 隐式 1 位网络: `assign` 一个未声明名字 ✅
`assign amo_newdata = (cond) ? amo_new_comb : 32'd0;` 在 `amo_newdata` **未声明**时,
ModelSim 把它当成**隐式 1 位网络**, 接到 32 位端口上只驱动了 1 位 → 其余位是 `Z`
→ **AMO 把 `Z` 写进内存**。唯一提示是
`vopt-2241 Connection width does not match width of port`。
**修法**: 在例化**之前**显式声明, 宽度写全。
(与 R8 同类: 未声明的名字被隐式推断, 静默出错 —— 但这次的提示更隐蔽, 是"宽度"不是"未定义"。)

### R26. **同一段新逻辑上往往不止一个 bug** —— 修掉一个不见效≠方向错了 ✅反复出现
写 A 扩展的 AMO 时, **同一段逻辑上叠了两个 bug, 修掉第一个完全没改善现象**:

- **地址**上叠了两个: ① `alu_b_src` 没设 (默认取 `rs2` 而非立即数) →
  ② 即便设对了, `ex_result` 仍取 `ex_alu_out`(算子结果) 而不是 `rs1+imm`。
  只修 ① 时地址仍差 `+4`, 看起来"这个方向错了", 实际是第二个 bug 在等着。
- **数据来源**上也叠了两个: ① `amo_op` 跨 EX→MEM 被 `hold_mem` 挡住没锁存 →
  ② `amo_mode_r` 只保持一拍 (WB 拍选错来源)。
  修掉 ① 后前两组通过, 第 3 组仍挂 —— 又是第二个 bug。

**教训**: 新增一条指令/一个新状态机时, **不要因为"改了一处没效果"就换方向**。
先把该通路的**每一个中间量都打出来**(见 R27), 一次列出所有异常项, 再逐个修。
本项目在 AMO 上因此多花了约 6 轮。

### R27. 调试新指令: **先用 tohost 上报, 再用打印**, 一次砍一层 ✅方法有效
`amo.S` 一次测 9 组, 失败时只知道"第 N 组错", **不知道错在地址/读/写哪一环** ——
前几轮都在这个模糊度里打转。

改为**两层诊断**后效率陡增:

1. **单步诊断程序 + tohost 上报**("哪一环错了"直接变成一个数字):
   ```asm
   li   t1, 100
   sw   t1, 0(t0)
   lw   t4, 0(t0)
   bne  t4, t3, rep2        # 2 = 基础读写就坏了
   ...
   .word 0x0062A3AF         # AMO
   bne  t2, t3, rep5        # 5 = rd(旧值) 不对
   ```
   实测一次就得到 `tohost=5` → 立刻排除"读通路坏了"(同程序的 `lw` 是好的)。
2. **逐拍打印中间量**(`[ex-amo]` → `[amo-new]` → `[ex]` → `[amo-w]` → `[L]`),
   每加一条消掉一个假设。

**两条一起用**: tohost 告诉你**哪一环**, 打印告诉你**为什么**。

### R28. `hw` 的陈旧数据陷阱还有个变体: **bit 文件不存在** ✅
`check` 的新鲜度判据只看 mtime/哈希。有一次 ILA 构建**失败**
(`IP_Flow 19-3505 Failed to generate IP 'ila_0'`) 并**把 `top_a100t.bit` 删掉了**
—— 此时 `hw` 仍然拿上一次的 `ila_done.csv` 报 "PASS"。
**修法/纪律**: 上板前先确认 **bit 文件本身存在**(`Test-Path`), 再谈新鲜度。
(与 R20 同类: 验证工具不能把"上一次的产物"当成"这一次的结论"。)

### R29. **PowerShell 5.1 的 `Get-Content | Set-Content` 会把 UTF-8 文件写成乱码** ✅毁过一次文件
`Get-Content` 在没有 BOM 时按**系统 ANSI 代码页(GBK)** 解码 —— 于是读进来的中文
已经是乱码, `Set-Content -Encoding UTF8` 再把乱码**按 UTF-8 写回**, 双重编码,
中文**永久损坏**。实测: 用这条管道改 `results/p4-macro-failure.md` 的一节,
整篇中文变成 `涓€鍙ヨ瘽绛旀` 这类乱码, 只能用 `git checkout --` 恢复。

**修法**:
- 改文本一律用 **edit / write 工具**(它们按 UTF-8 正确处理), **不要**用 PS 往返。
- 需要脚本化改文件时, 把 Python 脚本**写成文件**再执行; Python 显式指定
  `io.open(..., encoding='utf-8')`。**不要**用 `python -c "..."` 从 PowerShell
  传中文/反引号进去 —— PS 会把反引号当转义符吃掉, 中文也会被代码页破坏。
- 出事后 `git checkout -- <file>` 是唯一可靠的恢复手段 (前提是上一次提交是好的)。

**判据**: 用 `read` 工具看文件, 若中文正常而 `Get-Content` 显示乱码, 那是**显示**
问题; 若 `read` 工具也乱码, 文件**真的坏了**。

### R30. 取指地址要接"**下一拍的 pc**", 不是当前 pc (IMEM 寄存读的配对口径)
见 `results/p4-macro-failure.md` 5.1。一句话:
`imem_addr = pc_next(组合推出)` ⇒ `imem_rdata(N) == mem[pc(N)]`,
与组合读**逐位同口径**, IF/ID 一行都不用改, 重定向代价仍 2 拍。
配套必须**复位后冻结取指一拍**, 否则 `PC_RESET` 处第一条指令从未进过 IMEM。
前五轮的错法(延迟副本 + 补偿 mux / 统一 FAR)全部记录在案, 不要再走。

---

## 二、SystemVerilog / Verilog 语法
| 症状 | 原因 | 修法 |
|---|---|---|
| `vlog-13069 unexpected '['` | **不能对括号表达式位选**: `(a>>b)[31:0]` 非法 | 先赋中间 wire 再切片 |
| `vlog-2730 Undefined variable` | `assign` 写在了信号声明**之前** | 观测类 assign 放 `endmodule` 前 |
| `Synth 8-27 string type not supported` | `string` 不可综合 | ``ifdef SYNTHESIS` 包住仿真专用代码 |
| `vopt-7061` | `initial` 与 `always_ff` 同驱动一个变量 (LRM 违规) | 改用 `always` |
| `always_ff` 里不能有 `wait`/`#delay` | — | 拆到独立 `initial` |
| 信号恒为 X | `logic x = expr;` 是**声明式初始化**, 只在 0 时刻求值一次 | 用 `assign` 或 `always_comb` |

---

## 三、RTL 逻辑 (都真跑挂过)

1. **跳转重定向目标取错**: 条件分支 *不 taken* 时 `ex_pc_target` 是分支目标而非后继。
   正确: `actual_target = actual_taken ? ex_pc_target : id_ex_pc_plus4`。
2. **JAL 链接值前递**: jal 在 EX/MEM 时 `alu_out` 是跳转目标, 链接值在 `ex_mem_pc_plus4`。
   **按 `wb_src` 选前递源**, 绝不要把 WB_PC4 整条前递路径排除 —— 那会让消费者读到陈旧 ra
   (被 2 拍冲刷掩盖, 加分支预测后立刻暴露)。
3. **除法器余数必须 33 位**: 32 位时若除数 > 2^31, 左移丢位。
4. **除法器 `busy` 必须覆盖启动那一拍**: 否则 DIV 在结果出来前离开 EX。
5. **单周期的除零/溢出同样要占一拍**: 否则 EX/MEM 捕获到上一次的 `div_result`。
   统一判据: `busy = 迭代中 || (是除法 && 结果尚未寄存)`。
6. **store 的移位量用当前请求的 `off`**, 不是 WB 影子寄存器的 `off_wb`。
   症状: tohost 变成 0x40000。
7. **MMIO 需要读选通 (`ext_re`)**: 只靠 `we` 的话外设的粘滞就绪标志永远清不掉。
8. **UART RX 起始位下降沿判据是 `rxd_sync[2:1] == 2'b10`**, 不是 `2'b01`
   (1->0 的样点序列是 111->110->100->000)。
9. **计数要用单拍脉冲, 不能用粘滞标志** (如 `rx_rdy`) —— 会变成每拍 +1。
10. **哈佛结构: load 到不了 imem 空间**。所以 `.rodata` 不能留 IMEM; `.data` 也不能靠
    crt0 从 IMEM 搬运。两者都靠 dmem 自己的初始化镜像装入。
11. **组合读无法推断 BRAM**。要 BRAM 必须寄存读, 并把字节提取挪到 WB 拍吸收延迟。

---

## 四、构建/工具链

| 症状 | 原因 | 修法 |
|---|---|---|
| Vivado `32-bit platform is not supported` | 会话 env 被剥离, 缺 `PROCESSOR_ARCHITECTURE` | .bat 里 `set PROCESSOR_ARCHITECTURE=AMD64` |
| ModelSim `Unable to checkout a license` | 会话缺 `LM_LICENSE_FILE` | .bat 里显式 set |
| 综合出 25 个 LUT | 没装程序, 全被常量折叠 | 必须 `-verilog_define IMEM_INIT_FILE=...` |
| `Too many positional options` | `-retiming on` 放在了 `-verilog_define {...}` 之后 | 选项顺序要对 |
| `open_hw_manager` 无效 | Vivado 2018.3 用 `open_hw` | 换命令 |
| `read_verilog -define` 不生效 | 需要 compile-unit 模式 | 用 `synth_design -verilog_define` |
| Tcl `invalid command name "xxx.sv"` | **`[...]` 内换行是命令分隔符, 不是列表分隔符** | 文件列表**写在一行** |
| IP 生成器 `::ipgen_iptclns` 初始化失败, 谎报 `pkgIndex.tcl` 缺失 | **两个 Vivado 实例重叠** | 构建串行化 + 设 `XILINX_VIVADO` |
| `Synth 8-2715 syntax error near /`, 行号指向 `$readmemh` 那行 | **`set_property verilog_define` 里路径没加引号** —— 宏展开成裸路径, 报错点落在路径的 `/` 上, 行号极具误导性 | 值写成 `\"path\"`; 非工程模式用 `-verilog_define {X="path"}` |
| 找不到 bitstream / runs 目录 | `create_project ... <dir>/<name>` 会把最后一段当**工程名**, 文件落在**父目录** | 按 `<dir>/<name>.xpr` 和 `<dir>/<name>.runs/` 去找 |
| Vivado Tcl 报 `invalid command name "W??"` | **.tcl 用 7 位掩码编码写会毁掉中文注释** —— 非 ASCII 字节被掩码成控制字符, 其中一些正好是 `0x0A`, 把注释行劈成代码行 | **Vivado 的 .tcl 一律纯 ASCII** (与 .bat 同规则, 成因不同: 这是编码掩码, 那是代码页) |
| `get_hw_probes probe2` 返回空 | **ILA 探针名是连接的网络名**, 不是 probe0/probe1/... | 先 `get_hw_probes -of_objects $ila` 列出实际名字 |
| `Designutils 20-610 Invalid logic operator '8'` / `20-614 No apostrophe specified` | `TRIGGER_COMPARE_VALUE` 需要**比较前缀**且位宽匹配 | 用 `eq8'h40`; 默认值 `eq8'hXX` 就是格式提示 |
| 触发值看起来对但 ILA 永不触发 | **精确匹配太脆弱**: `eq8'h40` 要求其余 7 位全 0, 而程序结束时 pass 位也是 1 (ila_ctrl=0x42) | 清空触发值用默认 `eq8'hXX` (无条件), 等状态稳定后 arm 直接抓 |
| 临时目录跑到工作区 (`undefined\temp`) | `os.tmpdir()` 在空 env 下返回相对路径 | 用绝对临时路径 |
| 找不到 `powershell` | 会话 PATH 被剥离 | 补 `C:\Windows\System32\WindowsPowerShell\v1.0` |

---

## 五、软件 / 链接

1. **漏 `crt0.S` + `--gc-sections` 会静默产生 0 字节镜像**。
2. **CoreMark 的 `exit()` 根本没被调用** —— 程序靠 crt0 在 main 返回后写 tohost 结束。
   放 exit() 里的代码是死代码 (反汇编可验证)。
3. **`results[]`/`total_time` 是 main() 的局部变量**, 跨文件拿不到 → 加 extern 全局。
4. **`.data+.bss` 边界要留余量**: CoreMark 正好用满 4KB, 加 12 字节就溢出。
5. **build_sw.py 已自动包含 `crt0.S` 和 `libc_min.c`**, 不要再手动传 (multiple definition)。
   但 `hello.c` 需要手动带 `sw/portme.c`。
6. **`build_sw.py` 的 `--march` 才是真生效的**; `-D FLAGS_STR` 只改 CoreMark 打印的字符串。

---

## 六、优化决策纪律

1. **赛题记三项指标, 改一项必须同时量三项** + 绝对吞吐 (CoreMark/MHz × fmax)。
   反例: RAS+BTB128 让 CoreMark/MHz +1.0%, 但 fmax −4.6%、CoreMark/LUTs −4.4% → 净亏, 回退。
2. **优化前先测量**。本工程靠剖析发现"分支惩罚 29%", 才决定先做预测而不是 M 扩展。
3. **改动后重新量, 不凭感觉**。`phys_opt_design` 单用无效, 要配
   `place_design -directive ExtraTimingOpt` + `route_design -directive AggressiveExplore`。
4. **计数器/标签会过时**。`redirect` 语义从"分支 taken"改成"预测错误"后,
   原先叫 `n_br_taken` 的计数器实际统计的是"被误判的条件分支"。
5. **层次化引用路径要核对**: `load_use` 在 `u_hazard` 内部, 不是 core 顶层信号。

---

## 七、编辑操作

1. **替换注释块时把代码一起包进 old/new string** —— 曾因只换注释而误删两行 `assign`.
2. **编辑失败要看清是真失败还是 no-op** (`old_string and new_string must differ`)。
3. **删端口行后会留下悬空逗号** → 语法错误, 要一并处理。

---

## 八、改动后的自检清单 (每次收尾必跑)

- [ ] 所有 RTL 文件都在 build.tcl / run_coremark.py / vlog 列表里?
- [ ] 软件改了 → 重新构建 .hex **并重新综合 bitstream**?
- [ ] .S 改了 → 重新汇编 .hex?
- [ ] 地址/布局改了 → 所有引用点都同步了 (含 tb 和 .S)?
- [ ] 全套仿真回归跑过 (units / basic / m_ext / soc / hello / coremark)?
- [ ] CoreMark 三个数据类 CRC (0xe714 / 0x1fd7 / 0x8e3a) 仍匹配?
- [ ] 三项指标 + 绝对吞吐 都重新量并记进 results/coremark.csv?
- [ ] .bat 是纯 ASCII?
