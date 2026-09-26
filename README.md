# RV32I 五级流水线处理器

SystemVerilog 实现的 RV32I 处理器：**5 级流水线 (IF/ID/EX/MEM/WB)**，
含冒险处理、非对齐访存硬件自动拆分、自校验测试程序。

当前 194 项单元检查 + 6 组系统级测试全部通过。

## 文件一览

### 基础模块 (单周期与流水线共用)
| 文件 | 模块 | 说明 |
|---|---|---|
| `rv32_pkg.sv` | — | 编码包 (单一事实来源)：指令/ALU/分支/访存/写回编码、`ctrl_s` 控制束、地址映射、前递枚举、数据通路契约 |
| `alu.sv` | `alu` | 10 条基础运算；M 扩展编码预留 (命中输出 x 报警) |
| `branch_unit.sv` | `branch_unit` | 6 种分支判定，利用编码结构只做 3 个比较 |
| `control_unit.sv` | `control_unit` | RV32I 全译码 + 三级合法性检查；非法指令严格无副作用 |
| `imm_gen.sv` | `imm_gen` | I/S/B/U/J 五种立即数 |
| `pc.sv` | `pc` | PC 寄存器，带 `stall`/`flush` 钩子 |
| `regfile.sv` | `regfile` | 2R1W，x0 恒零，**组合读 + 写旁路**，调试读口 |

### 流水线模块
| 文件 | 模块 | 说明 |
|---|---|---|
| `imem.sv` / `dmem.sv` | — | 指令/数据存储器 (组合读 LUTRAM；dmem 带字节写使能) |
| `if_id_reg.sv` 等 4 个 | `*_reg` | 4 个流水寄存器 (控制束整束传递，气泡 = 真实 NOP) |
| `hazard_unit.sv` | `hazard_unit` | 前递选择 + load-use 停顿 + 重定向门控 |
| `load_store_unit.sv` | `load_store_unit` | 字节通道 + **非对齐跨字访存 2 拍自动拆分** |
| `core.sv` | `core` | 五级流水线顶层 + 调试口 |

### 验证
| 文件 | 说明 |
|---|---|
| `sim/tb_units.sv` | 6 个基础模块的单元回归 (194 检查点，含全部历史 bug 定向回归) |
| `sim/tb_core.sv` | 系统级自校验 (监视 tohost + illegal 粘滞标志 + 超时保护) |
| `sim/prog/basic.S` | 6 组测试程序 (算术/冒险/访存/非对齐/分支/移位) |
| `tools/asm.py` | 迷你 RV32I 汇编器 (两遍扫描，标签/伪指令 li/mv/nop/j/ret) |
| `legacy/` | 最初的 Verilog 单周期代码 (历史留档) |

## 跑测试

```
sim\run.bat                      :: Windows
./sim/run.sh                     :: Linux / WSL

:: 只跑系统测试并转波形 (GTKWave 查看)
cd sim
vvp tb_core.vvp +imem=prog/basic.hex +dump=wave.vcd

:: 换程序: 改 basic.S 后重新汇编即可 (无需重新编译 RTL)
python tools/asm.py sim/prog/basic.S -o sim/prog/basic.hex
```

本机已装便携版 iverilog 13.0 (`%LOCALAPPDATA%\riscv-tools\mingw64`)，
`run.bat` 自动查找。**注意 `run.bat` 必须保持纯 ASCII**：cmd 用 OEM 代码页
解析批处理，UTF-8 中文注释会导致解析错误。

## 流水线架构

```
 IF          ID              EX                MEM                WB
─────    ──────────    ──────────────    ──────────────    ──────────
 PC  ──►  译码/立即数 ──►  前递mux/ALU  ──►  访存单元   ──►  写回mux
 IMEM      Regfile读      分支判定          DMEM             Regfile写
                           跳转目标计算      非对齐拆分
```

**关键设计点**

1. **跳转目标复用 ALU**：`BR/JAL` 用 `a=PC`、`JALR` 用 `a=rs1`，`b=imm`，
   ALU 兼作目标加法器 → 省一个 32 位加法器。JALR 目标清最低位 (规范要求)。
2. **分支在 EX 判定** → 重定向冲刷 IF/ID 与 ID/EX (2 周期惩罚)。
3. **前递**：EX/MEM 与 MEM/WB 两级前递到 EX；load 不在 EX/MEM 段前递
   (那时只有地址没有数据)，由 load-use 停顿保证。
4. **寄存器堆写旁路**：覆盖"距离 3"的 RAW (WB 写与 ID 读同拍)。
   距离 1/2 由前递解决，距离 3 必须靠写旁路 —— 光靠 NBA 不够，因为
   ID/EX 的读数据在时钟沿前就被锁存了。
5. **停顿与重定向互斥**：重定向信号被停顿门控。冻结期间 EX 中的指令可能
   因操作数未就绪算出错误判定，下一拍重算后再生效。
6. **非法指令**：控制束已中性化为无副作用 (`reg_write/mem_read/mem_write=0`,
   `pc_sel=PC_NEXT`)，顶层置粘滞标志 `dbg_illegal` 供 TB 断言。
   trap 阶段替换为跳异常入口。

## 非对齐访存 (硬件自动拆分)

采用**统一移位法**：头字与尾字拼成 64 位后按字节偏移整体移位，
一套逻辑覆盖全部对齐/非对齐情况：

```
load : raw = {tail_word, head_word} >> (8*addr[1:0])   再按 size/符号扩展
store: shifted = {32'b0, rs2} << (8*addr[1:0]), 写使能为掩码移位到两个字
```

**何时需要两拍**：仅当 `off + size_bytes > 4` (跨 4 字节边界)：
- 字节访问：永不跨字 (零开销)
- 字内非对齐半字 (`off=1`)：不跨字，零额外开销
- 跨字访问：第 1 拍读/写头字并冻结流水线，第 2 拍读/写尾字并当拍合并
  → 总代价 1 个停顿周期

## 已知取舍与后续路线

- **M 扩展**：ALU 操作码已扩到 5 位，8 条 M 指令编码已预留
  (`ALU_MUL..ALU_REMU`)，当前译码为 illegal。启用时在 `control_unit` 加
  `funct7==F7_MULDIV` 分支 + ALU 实现 (乘法走 DSP；除法建议多周期状态机 +
  `pc.stall`)。
- **CSR/trap**：`illegal` 标志与 `pc.flush/flush_pc` 钩子已就位，
  下一步实现 `mtvec/mepc/mcause/mstatus` 后可支持非法指令/非对齐/断点异常。
- **存储器升级 BRAM**：`imem`/`dmem` 改寄存输出即可，接口不变，
  流水线无需改动 (需相应调整取指时序)。
- **设计坑记录** (都踩过并已修复，代码注释里有详细说明)：
  1. `logic x = expr;` 是**声明式初始化**，只在 0 时刻求值一次，
     不是连续赋值 —— 多处曾因此产生恒 X 信号。全部改为显式 `assign`。
  2. **连续赋值调用函数**时，若函数体引用模块级信号，部分仿真器
     (实测 iverilog) 只把实参计入敏感列表 → 前递结果变陈旧值。
     `hazard_unit` 已改为显式组合逻辑。
  3. 枚举类型的三目运算在 iverilog 需显式转换，改用 `always_comb` + if/else。
