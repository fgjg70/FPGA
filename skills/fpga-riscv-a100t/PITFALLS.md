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
