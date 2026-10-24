# P9 · 指令集拓展: RV32A 补全 (LR/SC 真预约) + RV32C 压缩指令集

**分支**: `feat/isa-ac` (基于 `main` = 150 MHz 交付版 `b09e8bc`; main 相对 150 MHz 基线
`6fa51d9` 无任何 RTL 改动, 见 `git diff 6fa51d9..main -- '*.sv'` 为空)
**日期**: 2026-10-24
**性质**: 教学向指令集拓展分支 —— **不承诺 150 MHz fmax 口径** (那仍是 main 分支的交付结论);
本分支的判据是 **全量仿真回归 PASS** 与既有程序 ticks 逐位不变。

---

## 0. 一页结论

| 项 | main 分支 | 本分支 |
|---|---|---|
| RV32I + M + Zicsr + M-mode 陷阱 | ✅ | ✅ (不动) |
| RV32A | 9 AMO + LR.W, **SC.W 恒失败** (`A_EN` 默认关) | **+ LR/SC 预约寄存器, SC 真成功路径, 非对齐 AMO 陷阱, `A_DIS` 默认开** |
| RV32C | ❌ 无 | **✅ 全部 25 条** (取指半字选择 + ID 段规范化展开) |
| 回归 | PASS 12 | **PASS 13** (+`tb_core_rvc`; amo.S 的 LR/SC 组翻新为真预约语义) |
| 汇编器 | RV32I(+M 手工) | **+ 25 条压缩助记符 + 11 条 AMO 助记符 + `.half`/`.align`, 全部与 GNU gas 逐位比对一致** |

**设计总纲 (为什么这样改)**: RV32C 的每条压缩指令都有唯一的 32 位等价形式。在 ID 段
新增一个 `rvc_expand` 把 16 位半字**规范化展开**成标准 32 位编码后,
`control_unit / imm_gen / hazard_unit / branch_unit` 一行都不用改 —— 译码"单一事实来源"
仍是 control_unit, 既有数据通路零扰动。取指侧利用 RV32C 编码空间的两个性质:
32 位指令恒 4 字节对齐 ⇒ **取指永不跨字**, imem 一行不改, 只按 `pc[1]` 选半字。

---

## 1. 取指与 PC (core.sv / pc.sv)

### 1.1 指令长度与顺序下一地址

RV32C 只有 16 位与 4 字节对齐的 32 位两种指令 ⇒ 每个半字槽要么是 16 位指令,
要么是"32 位指令的内部" (永远不会作为指令起点被取指)。于是:

```
pc[1]=0: 指令 = word;        word[1:0]!=11 -> 16 位 (长 2), 否则 32 位 (长 4)
pc[1]=1: 指令必是 word[31:16] 的 16 位半字 (32 位指令不可能从 bit1=1 起始;
         若该半字 [1:0]=11 则是 48/64 位编码空间 -> 本核判非法, 长度仍按 2)
```

`pc_nxi = pc + 指令长度` 一次算出, 供三类消费者共用 (语义天然统一):

1. **取指顺序地址** (pc_next / p2_pc_ns 的非预测项);
2. **链接值** (WB_PC4 写回 rd): 规范 "C" 章明确 C.JAL/C.JALR 的返回地址是 **pc+2**
   (16 位指令的"下一条"), JAL/JALR 是 pc+4 —— 都等于"下一条顺序指令地址";
3. **分支实际不跳的落点** (`actual_target` 的 not-taken 支路)。

`if_pc_plus4` 这个流水字段名沿用历史, 语义已更新为 pc_nxi (链接值/顺序后继)。
`pc.sv` 的顺序更新改用新输入 `pc_nxi` (C 关闭时恒等于 pc+4, 行为与 main 逐位一致)。

**时序代价 (固有)**: `if_c16` 依赖 `imem_rdata[1:0]` (BRAM 输出寄存器), 即
"取指字出 BRAM → 1 级 LUT → pc_next mux" —— 下一 PC 依赖当前指令长度, 无法提前一拍。
本分支不追 150 MHz, 未做时序收敛实测 (见 §6)。

### 1.2 ID 段提取与规范化展开

```
if_half  = pc[1] ? imem_rdata[31:16] : imem_rdata[15:0]
id_instr = c16 ? (rvc_valid ? rvc_expand(if_half) : 32'h0) : imem_rdata
```

- `id_instr` 喂给译码器/寄存器号提取/立即数生成 —— 16 位编码展开成标准形式,
  regfile 读口与 hazard 的 load-use 比较**不需要知道 RVC 的存在**;
- 非法 16 位编码展开失败时给全 0: opcode=0 → control_unit 判 illegal, 寄存器号
  全 0 (x0) 无副作用 —— 与"非法指令严格无副作用"口径一致;
- `if_instr_carry` (16 位时零扩展的原始半字) 随 ID/EX 的 instr 字段走, 专供 mtval
  (R-02 口径: 非法指令异常记触发指令的原始编码; 16 位记 16 位零扩展);
- `if_instr` 保持原始字不变 —— tb_sw 的"取指对齐自检" (imem_rdata == mem[pc])
  与 RVC 无关, 原样保留, 继续生效。

### 1.3 预测器适配 (btb/bht 零改动)

- BTB 索引/标签只切 `pc[13:2]` (不含 bit1): **同字内两条压缩指令共享一个 BTB 槽位**,
  只影响预测精度 (误判由 EX 重定向兜底), 不影响正确性;
- PHT 索引含 bit1 (`PC[13:1] ^ GHR`) ✓ 天然区分半字槽位;
- BTB 目标存 14 位含 bit[1:0] ✓ 压缩分支的 2 字节对齐目标可存;
- C-14 的 JALR 单链比较只要求 `pred_target[0]==0` (bit0 恒 0: JALR 清位 + 偏移全偶数)
  —— 两条对齐断言从 `[1:0]!=00` 收紧为 `[0]!=0` (原判据在 RVC 下会误报)。

---

## 2. RV32A 补全 (load_store_unit.sv / core.sv / control_unit.sv)

### 2.1 预约寄存器 (LR/SC 真语义)

main 分支的口径是"SC.W 恒失败" (规范允许的单核简化)。本分支实现真预约:

- **预约寄存器** = `{res_valid, res_addr[31:2]}` (单核单地址预约, 规范允许);
- **LR.W**: 只读 + 建立预约 (写相关写使能照旧关闭, 历史 bug 的防线保留);
- **SC.W**: 启动拍判定 `res_valid && res_addr==addr` → 成功: 写 rs2 进内存,
  rd=0; 失败: 不写, rd=1。**无论成败, SC 之后预约一律失效** (规范要求);
  新的 LR 覆盖旧预约;
- 同 hart 的 store 不清预约 (规范允许 "may"); mret/异常不清 (规范不要求) —— 两处
  取舍都写进了代码注释;
- SC 的写数据走 core 的 `amo_newdata` 选择 (成功 → rs2, 而不是 AMO ALU 的新值);
  rd/前递路径 (`amo_wb_value`) 用新输出 `amo_sc_ok`。

### 2.2 非对齐 AMO 陷阱 (规范补齐)

原先 LSU 会把 AMO 地址静默向下取整到字 —— 那会读/写一个软件从没想访问的字。
现在 EX 段检出 `amo_en && addr[1:0]!=0` → 地址错异常 (LR → load misaligned 4,
其余 → store misaligned 6), **mtval 记出错地址**。顺带: LR 的 rs2 字段 ≠0 判非法
(规范保留编码)。

### 2.3 宏翻转

`ifdef A_EN` (默认关) → **`ifndef A_DIS` (默认开)**, 涉及 control_unit / core /
load_store_unit / tb_units 四处。定义 `A_DIS` 可整体裁掉全部 AMO 逻辑, 恢复 main 的
最小配置。main 上"默认关"的理由 (对 CoreMark 三项零贡献, 实测 fmax −4.7%) 是竞赛
取舍, 本分支主题就是指令集, 默认打开。

---

## 3. RVC 展开器 (rvc_expand.sv, 新文件)

覆盖 RV32IMAC 全部 25 条压缩指令 + HINT (rd=x0 的 ADDI/LI/SLLI/MV/ADD/LUI 展开成
对应 32 位形式, 无害) + 保留编码判非法 (全零半字、C.ADDI4SPN nzuimm=0、C.LUI imm=0、
RV32 下 shamt[5]=1、C.SUBW/C.ADDW、F 槽位)。每条指令的展开在行内注释标了立即数位映射,
可逐位对照规范复查。

**已修掉的三个真 bug (教学价值最高, 全是"字段拼接位宽/位置"错误)**:

| bug | 症状 | 根因 |
|---|---|---|
| CIW 的 rd' 用了 [9:7] | a2 从未被写入, c.lw 拿垃圾基址 | C.ADDI4SPN 的 rd' 在 [4:2], 与 CL/CS 的 [9:7] 不同 |
| C.LW 的 rs1/rd 互换 | load 地址 = 目的寄存器的旧值 | CL 格式: 基址在 [9:7], 目的在 [4:2] |
| C.SW 的 S 型拼接错位 | canonical 的 funct3=100 (非法) → 陷阱 | S 型位宽是 7+5+**5**+3+5+7, 拼接漏了 rs1 的 5 位 |

**教训**: 汇编器编码方向与 RTL 译码方向是**两条独立路径**, 与 GNU gas 逐位比对只能
证明前者; 后者必须有 RTL 侧的值断言 (rvc.S 的每组测试都检查架构结果)。

**配套的 RVC 适配 (main 分支的 4 字节时代假设)**:

- **csr_file: mepc 写入不再强制 4 字节对齐** (原 `{wdata[31:2],2'b00}`)。16 位指令
  陷阱的 mepc 是半字对齐; handler 里 `mepc+=2` 后写回会被截断 → mret 永远回到
  触发指令 → 死循环 (rvc.S 的非法指令测试抓到的);
- muldiv 的 `md_op_eff` 从裸 `wire[4:0]` 改为枚举类型 (修 vsim-3999, 让
  `-voptargs=+acc` 调试可用; 功能不变)。

---

## 4. 汇编器 (tools/asm.py)

- **25 条压缩助记符** + AMO 11 条 (含 `.aq/.rl/.aqrl` 后缀) + `.half`/`.align`;
- **2 字节寻址**: 压缩指令占 2 字节; ≥4 字节的指令落在 `pc%4==2` 时自动补一条
  c.nop (0x0001) 半字 (与 GNU as 的对齐语义一致; 实测坑: 只判 `size==4` 会漏掉
  8 字节的 `li` —— lui 落在半字槽上, 整个镜像从那里开始错位);
- **输出按字节地址组包**: 低地址半字在字的低 16 位 (与取指 "pc[1]=0 取 [15:0]"
  一致); 空洞半字槽填 0x0001; 全 32 位老程序输出与旧版**逐位相同** (7 个既有程序
  diff 验证 IDENTICAL);
- **双重交叉验证**: ① 26 条压缩指令 + 13 条 AMO 与 GNU gas
  (`riscv-none-elf-gcc -march=rv32imac/ima`) 反汇编逐位一致 (BAD=0);
  ② c.lui/c.addi16sp 手工对照规范核验。

---

## 5. 验证

### 5.1 回归口径

判据 = `python tools\fpga_workflow.py verify` 打印的 `RESULT : PASS`
(仿真级; 本分支无上板验证 —— 那是 main 分支 150 MHz 交付版的口径)。

- 矩阵 **PASS 13**: 原 12 项 + `tb_core_rvc` (RV32C 系统级自校验);
- `tb_core_amo` 的 LR/SC 组翻新: 13 (SC 无预约 → 失败) / 14 (LR+SC 同地址 → **成功**,
  rd=0, 内存=rs2) / 15 (异地址失败 + 失败后预约已失效) / 16 (LR(A)+LR(B)+SC(B) 成功);
- `sim/prog/rvc.S` 新增 (14 组): CI/CR/CA/CB/CJ/CL/CS/CIW/CSS 全指令类 +
  **C.JAL 链接值 = pc+2 的哨兵检查** (错成 pc+4 会跳过哨兵) +
  非法半字陷阱 (mcause=2/mtval=0/mepc+=2) + c.ebreak 陷阱 (mcause=3);
- **既有程序 ticks 逐位不变** 是本分支最强的等价性证据 (C 取指逻辑对全 32 位
  程序必须退化为 pc+4 路径): 见 verify 的 tb_sw_coremark/lu_bench/nn_demo。

### 5.2 本分支不做的事 (诚实口径)

- **不上板**: 分支目的是指令集学习与仿真验证; 上板需要重走综合/时序收敛
  (RVC 取指路径变长, 150 MHz 需要重新收敛, 那是 main 的交付口径);
- **不追 fmax**: `if_c16` 的 BRAM 输出依赖是取指路径的固有代价;
- BTB 同字别名只保正确性不保精度 (可作后续学习课题: 索引进 bit1)。

## 6. 复现

```bat
python tools\asm.py sim\prog\rvc.S -o sim\prog\rvc.hex
python tools\fpga_workflow.py verify            :: 期望 PASS 13, 无 XFAIL
python tools\fpga_workflow.py verify --only tb_core_rvc tb_core_amo
```
