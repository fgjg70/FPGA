#!/usr/bin/env python3
"""asm.py — RV32IMAC 迷你汇编器 (教学用)

用法:
    python tools/asm.py sim/prog/basic.S -o sim/prog/basic.hex

支持:
  - .text / .data 段 (.text -> 0x80000000, .data -> 0x90000000, 见 rv32_pkg 地址映射)
  - .org <addr>   直接指定后续地址
  - .word <imm>   原始数据字 (4 字节)
  - .half <imm>   原始半字 (2 字节; 可用于手工塞压缩指令/非法编码)
  - 标签: name:    (两遍扫描, 分支/跳转自动算相对偏移)
  - 伪指令: li rd, imm32 / mv rd, rs / nop / j label / ret
  - 基础指令: lui auipc jal jalr beq bne blt bge bltu bgeu
              lb lh lw lbu lhu sb sh sw
              addi slti sltiu xori ori andi slli srli srai
              add sub sll slt sltu xor srl sra or and
  - Zicsr: csrrw/csrrs/csrrc/csrrwi/csrrsi/csrrci + 伪指令
  - RV32M: mul mulh mulhsu mulhu div divu rem remu
  - RV32A: lr.w sc.w amoswap.w amoadd.w amoxor.w amoand.w amoor.w
           amomin.w amomax.w amominu.w amomaxu.w (可带 .aq/.rl/.aqrl 后缀)
  - RV32C (压缩, 2 字节): c.addi4spn c.lw c.sw c.nop c.addi c.jal c.li
      c.addi16sp c.lui c.srli c.srai c.andi c.sub c.xor c.or c.and
      c.j c.beqz c.bnez c.slli c.lwsp c.swsp c.jr c.jalr c.mv c.add c.ebreak
  - 操作数: 十进制 / 0x 十六进制 / 负数 / 标签
  - 寄存器: x0-x31 或 ABI 名 (zero ra sp gp tp t0-t6 s0-s11 a0-a7)

【RVC 的地址与输出格式 (feat/isa-ac 新增)】
  - 压缩指令占 2 字节; 32 位指令必须 4 字节对齐 —— 若一条 32 位指令落在
    pc%4==2 处, 汇编器自动补一条 c.nop (0x0001) 再放置 (与 GNU as 的行为一致),
    标签地址按补齐后计算 (两遍一致)。
  - 输出仍是每行一个 32 位字的 hex ($readmemh 口径), 但按**字节地址组包**:
    低地址半字在字的低 16 位 (与 imem 取指 "pc[1]=0 取 [15:0]" 的口径一致)。
  - 空洞 (跳过的半字槽) 填 0x0001 (c.nop)。全 32 位的老程序输出与旧版逐位相同。

输出:
  - hex 文件 (每行一个 32 位字, 供 $readmemh; 只含 .text, 从 .text 起点开始)
  - 汇编清单 + 标签表 (打印到 stdout, 便于对照波形调试)
"""

import sys
import re
import io

TEXT_BASE = 0x80000000
DATA_BASE = 0x90000000

ABI = {
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4,
    't0': 5, 't1': 6, 't2': 7,
    's0': 8, 'fp': 8, 's1': 9,
    'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13, 'a4': 14, 'a5': 15, 'a6': 16, 'a7': 17,
    's2': 18, 's3': 19, 's4': 20, 's5': 21, 's6': 22, 's7': 23,
    's8': 24, 's9': 25, 's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31,
}

# ---- Zicsr: CSR 名字 -> 地址 (只列本核实现的) ----
CSR_NAME = {
    'mstatus': 0x300, 'misa': 0x301, 'mie': 0x304, 'mtvec': 0x305,
    'mscratch': 0x340, 'mepc': 0x341, 'mcause': 0x342, 'mtval': 0x343,
    'mip': 0x344,
    'mvendorid': 0xF11, 'marchid': 0xF12, 'mimpid': 0xF13, 'mhartid': 0xF14,
}

R_OPS = {
    'add': (0x00, 0), 'sub': (0x20, 0), 'sll': (0x00, 1), 'slt': (0x00, 2),
    'sltu': (0x00, 3), 'xor': (0x00, 4), 'srl': (0x00, 5), 'sra': (0x20, 5),
    'or': (0x00, 6), 'and': (0x00, 7),
    # ---- RV32M: funct7 = 0x01 ----
    'mul': (0x01, 0), 'mulh': (0x01, 1), 'mulhsu': (0x01, 2), 'mulhu': (0x01, 3),
    'div': (0x01, 4), 'divu': (0x01, 5), 'rem': (0x01, 6), 'remu': (0x01, 7),
}
I_ARITH = {
    'addi': 0, 'slti': 2, 'sltiu': 3, 'xori': 4, 'ori': 6, 'andi': 7,
    'slli': 1, 'srli': 5, 'srai': 5,
}
LOAD = {'lb': 0, 'lh': 1, 'lw': 2, 'lbu': 4, 'lhu': 5}
STORE = {'sb': 0, 'sh': 1, 'sw': 2}
BRANCH = {'beq': 0, 'bne': 1, 'blt': 4, 'bge': 5, 'bltu': 6, 'bgeu': 7}

# ---- RV32A: 助记符 -> funct5 ----
AMO_OPS = {
    'amoadd.w': 0x00, 'amoswap.w': 0x01, 'lr.w': 0x02, 'sc.w': 0x03,
    'amoxor.w': 0x04, 'amoor.w': 0x08, 'amoand.w': 0x0C,
    'amomin.w': 0x10, 'amomax.w': 0x14, 'amominu.w': 0x18, 'amomaxu.w': 0x1C,
}

COMPRESSED_2BYTE = True   # c.* 助记符一律 2 字节


def reg(tok):
    t = tok.strip().lower()
    if t.startswith('x') and t[1:].isdigit():
        n = int(t[1:])
        if 0 <= n <= 31:
            return n
    if t in ABI:
        return ABI[t]
    raise ValueError('bad register: %s' % tok)


def value(tok, labels, pc=0, relative=False):
    """解析立即数: 十进制/十六进制/负数/标签"""
    t = tok.strip()
    if t in labels:
        v = labels[t] - pc if relative else labels[t]
        return v
    v = int(t, 0)
    return v


def csr(tok, labels):
    """CSR 操作数: 支持助记名 (mstatus/mtvec/...) 也支持数字"""
    t = tok.strip()
    if t in CSR_NAME:
        return CSR_NAME[t]
    return value(t, labels) & 0xFFF


def r_type(f7, rs2, rs1, f3, rd):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0b0110011


def i_type(imm12, rs1, f3, rd, opc):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc


def s_type(imm12, rs2, rs1, f3):
    return (((imm12 >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
           | ((imm12 & 0x1F) << 7) | 0b0100011


def b_type(imm13, rs2, rs1, f3):
    return (((imm13 >> 12) & 1) << 31) | (((imm13 >> 5) & 0x3F) << 25) | (rs2 << 20) \
           | (rs1 << 15) | (f3 << 12) | (((imm13 >> 1) & 0xF) << 8) \
           | (((imm13 >> 11) & 1) << 7) | 0b1100011


def u_type(imm20, rd, opc):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | opc


def j_type(imm21, rd):
    return (((imm21 >> 20) & 1) << 31) | (((imm21 >> 1) & 0x3FF) << 21) \
           | (((imm21 >> 11) & 1) << 20) | (((imm21 >> 12) & 0xFF) << 12) \
           | (rd << 7) | 0b1101111


def parse_mem_operand(tok, labels):
    m = re.match(r'^(.*?)\(\s*([A-Za-z0-9_]+)\s*\)$', tok.strip())
    if not m:
        raise ValueError('bad memory operand: %s' % tok)
    off_s = m.group(1).strip()
    return (value(off_s, labels) if off_s else 0), reg(m.group(2))


def li_split(v):
    """li 伪指令的 lui/addi 拆分, 返回 (hi20, lo12)"""
    hi = (v + 0x800) >> 12
    lo = v - (hi << 12)
    return hi & 0xFFFFF, lo & 0xFFF


# ============================================================================
# RV32C 编码 (feat/isa-ac 新增) —— 位序逐位对照规范 "C" 章
# ============================================================================

def _need(cond, msg):
    if not cond:
        raise ValueError(msg)


def _rd_f(tok):
    """压缩字段 rd'/rs1' (x8..x15); tok 可以是寄存器号 (int) 或寄存器 token (str)"""
    r = tok if isinstance(tok, int) else reg(tok)
    _need(8 <= r <= 15, "compressed register must be x8..x15: %s" % tok)
    return r - 8


def c_addi4spn(rd, imm):
    _need(0 < imm <= 1020 and imm % 4 == 0, 'c.addi4spn imm must be 4..1020 step 4')
    rd_f = _rd_f(rd)
    imm &= 0x3FF
    return ((imm >> 2) & 0x1) << 6 | ((imm >> 3) & 0x1) << 5 \
         | ((imm >> 6) & 0xF) << 7 | ((imm >> 4) & 0x3) << 11 \
         | rd_f << 2 | 0b00


def c_lw_sw(off, r1, rd, is_store):
    """C.LW / C.SW (CL/CS 格式): offset[6]=inst[5] [5:3]=inst[12:10] [2]=inst[6]
    r1/rd 传**寄存器号** (8..15)"""
    _need(0 <= off <= 124 and off % 4 == 0, 'c.lw/c.sw offset must be 0..124 step 4')
    _need(8 <= r1 <= 15, 'c.lw/c.sw base must be x8..x15')
    _need(8 <= rd <= 15, 'c.lw/c.sw data register must be x8..x15')
    r1f, rdf = r1 - 8, rd - 8
    u = (off >> 2) & 0x1F                       # offset[6:2]
    # offset[5:3]=u[3:1] -> inst[12:10];  offset[2]=u[0] -> inst[6];  offset[6]=u[4] -> inst[5]
    inst = ((u >> 1) & 0x7) << 10 | ((u >> 0) & 0x1) << 6 | ((u >> 4) & 0x1) << 5
    f3 = 0b110 if is_store else 0b010
    # CL 与 CS 的布局相同: 基址 rs1' 在 [9:7], 目标 rd'/数据 rs2' 都在 [4:2]
    return inst | f3 << 13 | r1f << 7 | rdf << 2 | 0b00


def c_addi(rd, imm):
    _need(-32 <= imm <= 31, 'c.addi imm must fit 6-bit signed')
    _need(rd != 0, 'c.addi rd must not be x0 (use c.nop)')
    imm &= 0x3F
    return (imm >> 5) << 12 | (rd & 0x1F) << 7 | (imm & 0x1F) << 2 | 0b01


def c_li(rd, imm):
    _need(-32 <= imm <= 31, 'c.li imm must fit 6-bit signed')
    imm &= 0x3F
    return (imm >> 5) << 12 | (rd & 0x1F) << 7 | (imm & 0x1F) << 2 | 0b01 | 0b010 << 13


def c_lui(rd, imm):
    """imm 为 18 位符号数 (低 12 位为 0)"""
    _need(rd not in (0, 2), 'c.lui rd must not be x0/x2')
    _need(imm % 4096 == 0, 'c.lui imm must be multiple of 4096')
    nz = (imm >> 12) & 0x3F
    _need(nz != 0, 'c.lui imm must be non-zero')
    return (nz >> 5) << 12 | (rd & 0x1F) << 7 | (nz & 0x1F) << 2 | 0b01 | 0b011 << 13


def c_addi16sp(imm):
    """nzimm[9]=inst[12] [8:7]=inst[4:3] [6]=inst[5] [5]=inst[2] [4]=inst[6]"""
    _need(imm != 0 and imm % 16 == 0, 'c.addi16sp imm must be non-zero multiple of 16')
    _need(-512 <= imm <= 496, 'c.addi16sp imm out of range')
    n = imm & 0x3FF
    inst = ((n >> 9) & 0x1) << 12 | ((n >> 4) & 0x1) << 6 | ((n >> 6) & 0x1) << 5 \
         | ((n >> 7) & 0x3) << 3 | ((n >> 5) & 0x1) << 2
    return inst | (2 & 0x1F) << 7 | 0b01 | 0b011 << 13


def c_srli_srai(rd, shamt, is_sra):
    _need(1 <= shamt <= 31, 'c.srli/c.srai shamt must be 1..31')
    rdf = _rd_f(rd)
    f2 = 0b01 if is_sra else 0b00
    return (shamt & 0x1F) << 2 | rdf << 7 | f2 << 10 | 0b01 | 0b100 << 13


def c_andi(rd, imm):
    _need(-32 <= imm <= 31, 'c.andi imm must fit 6-bit signed')
    rdf = _rd_f(rd)
    imm &= 0x3F
    return (imm >> 5) << 12 | rdf << 7 | (imm & 0x1F) << 2 | 0b01 | 0b100 << 13 \
         | 0b10 << 10


def c_reg_op(rd, rs2, op):
    """C.SUB/C.XOR/C.OR/C.AND (CA 格式)"""
    rdf, r2f = _rd_f(rd), _rd_f(rs2)
    return r2f << 2 | op << 5 | rdf << 7 | 0b11 << 10 | 0b01 | 0b100 << 13


def c_jal_j(off, is_jal):
    """C.J / C.JAL (CJ 格式)"""
    _need(off % 2 == 0 and -2048 <= off <= 2046, 'c.j/c.jal offset out of range')
    o = off & 0xFFF
    inst = ((o >> 11) & 0x1) << 12 | ((o >> 4) & 0x1) << 11 | ((o >> 8) & 0x3) << 9 \
         | ((o >> 10) & 0x1) << 8 | ((o >> 6) & 0x1) << 7 | ((o >> 7) & 0x1) << 6 \
         | ((o >> 1) & 0x7) << 3 | ((o >> 5) & 0x1) << 2
    f3 = 0b001 if is_jal else 0b101
    return inst | f3 << 13 | 0b01


def c_beqz_bnez(r1, off, is_bnez):
    """C.BEQZ / C.BNEZ (CB 格式): 9 位符号偏移"""
    r1f = _rd_f(r1)
    _need(off % 2 == 0 and -256 <= off <= 254, 'c.beqz/c.bnez offset out of range')
    o = off & 0x1FF
    inst = ((o >> 8) & 0x1) << 12 | ((o >> 3) & 0x3) << 10 | r1f << 7 \
         | ((o >> 6) & 0x3) << 5 | ((o >> 1) & 0x3) << 3 | ((o >> 5) & 0x1) << 2
    f3 = 0b111 if is_bnez else 0b110
    return inst | f3 << 13 | 0b01


def c_slli(rd, shamt):
    _need(1 <= shamt <= 31, 'c.slli shamt must be 1..31')
    _need(rd != 0, 'c.slli rd=x0 is a HINT, not accepted here')
    return (shamt & 0x1F) << 2 | (rd & 0x1F) << 7 | 0b10


def c_lwsp(rd, off):
    _need(0 <= off <= 252 and off % 4 == 0, 'c.lwsp offset must be 0..252 step 4')
    _need(rd != 0, 'c.lwsp rd=x0 is reserved')
    u = (off >> 2) & 0x3F                       # offset[7:2]
    # offset[5]=inst[12], offset[4:2]=inst[6:4], offset[7:6]=inst[3:2]
    inst = ((u >> 3) & 0x1) << 12 | ((u >> 0) & 0x7) << 4 | ((u >> 4) & 0x3) << 2
    return inst | (rd & 0x1F) << 7 | 0b010 << 13 | 0b10


def c_swsp(rs2, off):
    _need(0 <= off <= 252 and off % 4 == 0, 'c.swsp offset must be 0..252 step 4')
    u = (off >> 2) & 0x3F
    inst = ((u >> 0) & 0xF) << 9 | ((u >> 4) & 0x3) << 7
    return inst | (rs2 & 0x1F) << 2 | 0b110 << 13 | 0b10


def c_jr_jalr_mv_add(rd, rs2, kind):
    """CR 格式: c.jr/c.jalr (rs2=x0) 与 c.mv/c.add (rs2!=x0)"""
    _need(rd != 0, 'c.jr/c.jalr/c.mv/c.add rd must not be x0')
    if kind in ('jr', 'jalr'):
        _need(rs2 == 0, 'c.jr/c.jalr has no rs2 operand')
        f4 = 0b1000 if kind == 'jr' else 0b1001
        return (rd & 0x1F) << 7 | f4 << 12 | 0b10
    else:
        _need(rs2 != 0, 'c.mv/c.add needs a source register (rs2!=x0)')
        f4 = 0b1000 if kind == 'mv' else 0b1001
        return (rs2 & 0x1F) << 2 | (rd & 0x1F) << 7 | f4 << 12 | 0b10


def amo_type(funct5, aq, rl, rs2, rs1, f3, rd):
    return (funct5 << 27) | (aq << 26) | (rl << 25) | (rs2 << 20) | (rs1 << 15) \
           | (f3 << 12) | (rd << 7) | 0b0101111


def instruction_size(mn, ops, labels):
    """该行占用的字节数 (li 可能展开为两条; c.* 为 2 字节)"""
    if mn == 'li':
        t = ops[1].strip()
        try:
            v = int(t, 0)
        except ValueError:
            # 符号操作数 (如 li t0, handler): 第一遍标签还没算出来。
            # **两遍都必须给同一个答案**, 否则地址布局会错位 —— 所以一律按
            # 8 字节预留。imem 地址 0x8000_xxxx 的 li 本来就是 8 字节, 不浪费。
            return 8
        hi, lo = li_split(v)
        return 8 if (lo != 0 or hi == 0) else 4
    if mn.startswith('c.') or mn == 'c.nop':
        if mn in ('c.ebreak',):
            return 2
        return 2
    return 4


def encode(mn, ops, pc, labels):
    """编码一行, 返回 (字节数, 编码值) 列表 —— 字节数之和必须与 instruction_size 一致"""
    if mn == 'nop':
        return [(4, i_type(0, 0, 0, 0, 0b0010011))]
    if mn == 'mv':
        return [(4, i_type(0, reg(ops[1]), 0, reg(ops[0]), 0b0010011))]
    if mn == 'li':
        rd = reg(ops[0])
        hi, lo = li_split(value(ops[1], labels))
        out = [(4, u_type(hi, rd, 0b0110111))]
        if lo != 0 or hi == 0:
            out.append((4, i_type(lo, rd, 0, rd, 0b0010011)))
        return out
    if mn == 'j':
        return [(4, j_type(value(ops[0], labels, pc, True) & 0x1FFFFF, 0))]
    if mn == 'ret':
        return [(4, i_type(0, 1, 0, 0, 0b1100111))]
    if mn in R_OPS:
        f7, f3 = R_OPS[mn]
        return [(4, r_type(f7, reg(ops[2]), reg(ops[1]), f3, reg(ops[0])))]
    if mn in I_ARITH:
        f3 = I_ARITH[mn]
        rd, rs1 = reg(ops[0]), reg(ops[1])
        v = value(ops[2], labels)
        if mn in ('slli', 'srli', 'srai'):
            sh = v & 0x1F
            if mn == 'srai':
                sh |= 0x400
            return [(4, i_type(sh, rs1, f3, rd, 0b0010011))]
        return [(4, i_type(v & 0xFFF, rs1, f3, rd, 0b0010011))]
    if mn in LOAD:
        rd = reg(ops[0])
        off, rs1 = parse_mem_operand(ops[1], labels)
        return [(4, i_type(off & 0xFFF, rs1, LOAD[mn], rd, 0b0000011))]
    if mn in STORE:
        rs2 = reg(ops[0])
        off, rs1 = parse_mem_operand(ops[1], labels)
        return [(4, s_type(off & 0xFFF, rs2, rs1, STORE[mn]))]
    if mn in BRANCH:
        rs1, rs2 = reg(ops[0]), reg(ops[1])
        off = value(ops[2], labels, pc, True)
        return [(4, b_type(off & 0x1FFF, rs2, rs1, BRANCH[mn]))]
    if mn in ('beqz', 'bnez'):
        # 伪指令: beqz rs, label / bnez rs, label
        f3 = 1 if mn == 'bnez' else 0
        off = value(ops[1], labels, pc, True)
        return [(4, b_type(off & 0x1FFF, 0, reg(ops[0]), f3))]
    if mn == 'lui':
        return [(4, u_type(value(ops[1], labels) & 0xFFFFF, reg(ops[0]), 0b0110111))]
    if mn == 'auipc':
        return [(4, u_type(value(ops[1], labels) & 0xFFFFF, reg(ops[0]), 0b0010111))]
    if mn == 'jal':
        if len(ops) == 1:
            rd, target = 1, ops[0]
        else:
            rd, target = reg(ops[0]), ops[1]
        return [(4, j_type(value(target, labels, pc, True) & 0x1FFFFF, rd))]
    if mn == 'jalr':
        if len(ops) == 1:
            rd, off, rs1 = 1, 0, reg(ops[0])
        elif len(ops) == 2 and '(' in ops[1]:
            rd = reg(ops[0])
            off, rs1 = parse_mem_operand(ops[1], labels)
        else:
            rd, rs1 = reg(ops[0]), reg(ops[1])
            off = value(ops[2], labels)
        return [(4, i_type(off & 0xFFF, rs1, 0, rd, 0b1100111))]
    # ---- Zicsr (opcode 1110011 = SYSTEM) ----
    if mn in ('csrrw', 'csrrs', 'csrrc'):
        f3 = {'csrrw': 1, 'csrrs': 2, 'csrrc': 3}[mn]
        return [(4, i_type(csr(ops[1], labels), reg(ops[2]), f3, reg(ops[0]), 0b1110011))]
    if mn in ('csrrwi', 'csrrsi', 'csrrci'):
        f3 = {'csrrwi': 5, 'csrrsi': 6, 'csrrci': 7}[mn]
        return [(4, i_type(csr(ops[1], labels), value(ops[2], labels) & 0x1F, f3, reg(ops[0]), 0b1110011))]
    # 伪指令
    if mn == 'csrr':
        return [(4, i_type(csr(ops[1], labels), 0, 2, reg(ops[0]), 0b1110011))]
    if mn == 'csrw':
        return [(4, i_type(csr(ops[0], labels), reg(ops[1]), 1, 0, 0b1110011))]
    if mn == 'csrs':
        return [(4, i_type(csr(ops[0], labels), reg(ops[1]), 2, 0, 0b1110011))]
    if mn == 'csrc':
        return [(4, i_type(csr(ops[0], labels), reg(ops[1]), 3, 0, 0b1110011))]
    if mn == 'csrsi':
        return [(4, i_type(csr(ops[0], labels), value(ops[1], labels) & 0x1F, 6, 0, 0b1110011))]
    if mn == 'csrci':
        return [(4, i_type(csr(ops[0], labels), value(ops[1], labels) & 0x1F, 7, 0, 0b1110011))]
    # ---- 陷阱指令 (SYSTEM 的固定编码) ----
    if mn == 'ecall':
        return [(4, 0x00000073)]
    if mn == 'ebreak':
        return [(4, 0x00100073)]
    if mn == 'mret':
        return [(4, 0x30200073)]
    if mn == 'fence':
        return [(4, 0x0FF0000F)]          # 本核顺序执行, FENCE 可退化为 NOP
    # ---- RV32A 原子指令 (可选 .aq/.rl/.aqrl 后缀) ----
    base_mn = mn
    aq = rl = 0
    for suf, bit in (('.aqrl', None), ('.aq', 'aq'), ('.rl', 'rl')):
        if mn.endswith(suf):
            base_mn = mn[:-len(suf)]
            if suf == '.aqrl':
                aq = rl = 1
            elif bit == 'aq':
                aq = 1
            else:
                rl = 1
            break
    if base_mn in AMO_OPS:
        funct5 = AMO_OPS[base_mn]
        rd = reg(ops[0])
        if funct5 == 0x02:                       # lr.w rd, (rs1)
            _need(len(ops) == 2, 'lr.w takes rd, (rs1)')
            rs1 = reg(ops[1].split('(')[1].rstrip(') '))
            return [(4, amo_type(funct5, aq, rl, 0, rs1, 2, rd))]
        # 其余: rd, rs2, (rs1)
        rs2 = reg(ops[1])
        off, rs1 = parse_mem_operand(ops[2], labels)
        _need(off == 0, 'AMO offset must be 0 (no immediate)')
        return [(4, amo_type(funct5, aq, rl, rs2, rs1, 2, rd))]
    # ---- RV32C 压缩指令 ----
    if mn == 'c.nop':
        _need(len(ops) == 0, 'c.nop takes no operand')
        return [(2, 0x0001)]
    if mn == 'c.addi4spn':
        # 兼容两种写法: `c.addi4spn rd, imm` 与 gas 的 `c.addi4spn rd, sp, imm`
        if len(ops) == 3:
            _need(reg(ops[1]) == 2, 'c.addi4spn base must be sp')
            ops = [ops[0], ops[2]]
        return [(2, c_addi4spn(ops[0], value(ops[1], labels)))]
    if mn == 'c.lw':
        off, rs1 = parse_mem_operand(ops[1], labels)
        _need(rs1 >= 8 and rs1 <= 15, 'c.lw base must be x8..x15')
        return [(2, c_lw_sw(off, rs1, reg(ops[0]), False))]
    if mn == 'c.sw':
        off, rs1 = parse_mem_operand(ops[1], labels)
        _need(rs1 >= 8 and rs1 <= 15, 'c.sw base must be x8..x15')
        return [(2, c_lw_sw(off, rs1, reg(ops[0]), True))]
    if mn == 'c.addi':
        return [(2, c_addi(reg(ops[0]), value(ops[1], labels)))]
    if mn in ('c.call', 'c.jal'):
        return [(2, c_jal_j(value(ops[0], labels, pc, True), True))]
    if mn == 'c.li':
        return [(2, c_li(reg(ops[0]), value(ops[1], labels)))]
    if mn == 'c.addi16sp':
        # 兼容两种写法: `c.addi16sp imm` 与 gas 的 `c.addi16sp sp, imm`
        if len(ops) == 2:
            _need(reg(ops[0]) == 2, 'c.addi16sp target must be sp')
            ops = [ops[1]]
        return [(2, c_addi16sp(value(ops[0], labels)))]
    if mn == 'c.lui':
        return [(2, c_lui(reg(ops[0]), value(ops[1], labels)))]
    if mn == 'c.srli':
        return [(2, c_srli_srai(reg(ops[0]), value(ops[1], labels), False))]
    if mn == 'c.srai':
        return [(2, c_srli_srai(reg(ops[0]), value(ops[1], labels), True))]
    if mn == 'c.andi':
        return [(2, c_andi(reg(ops[0]), value(ops[1], labels)))]
    if mn in ('c.sub', 'c.xor', 'c.or', 'c.and'):
        op = {'c.sub': 0, 'c.xor': 1, 'c.or': 2, 'c.and': 3}[mn]
        return [(2, c_reg_op(reg(ops[0]), reg(ops[1]), op))]
    if mn == 'c.j':
        return [(2, c_jal_j(value(ops[0], labels, pc, True), False))]
    if mn == 'c.beqz':
        return [(2, c_beqz_bnez(reg(ops[0]), value(ops[1], labels, pc, True), False))]
    if mn == 'c.bnez':
        return [(2, c_bezz_wrapper(ops, labels, pc))]
    if mn == 'c.slli':
        return [(2, c_slli(reg(ops[0]), value(ops[1], labels)))]
    if mn == 'c.lwsp':
        off, rs1 = parse_mem_operand(ops[1], labels)
        _need(rs1 == 2, 'c.lwsp base must be sp')
        return [(2, c_lwsp(reg(ops[0]), off))]
    if mn == 'c.swsp':
        off, rs1 = parse_mem_operand(ops[1], labels)
        _need(rs1 == 2, 'c.swsp base must be sp')
        return [(2, c_swsp(reg(ops[0]), off))]
    if mn == 'c.jr':
        return [(2, c_jr_jalr_mv_add(reg(ops[0]), 0, 'jr'))]
    if mn == 'c.jalr':
        return [(2, c_jr_jalr_mv_add(reg(ops[0]), 0, 'jalr'))]
    if mn == 'c.mv':
        return [(2, c_jr_jalr_mv_add(reg(ops[0]), reg(ops[1]), 'mv'))]
    if mn == 'c.add':
        return [(2, c_jr_jalr_mv_add(reg(ops[0]), reg(ops[1]), 'add'))]
    if mn == 'c.ebreak':
        return [(2, 0x9002)]
    raise ValueError('unknown mnemonic: %s' % mn)


def c_bezz_wrapper(ops, labels, pc):
    # 独立小包装只为可读性: c.bnez 与 c.beqz 共用编码函数
    return c_beqz_bnez(reg(ops[0]), value(ops[1], labels, pc, True), True)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    src_path = sys.argv[1]
    out_path = 'prog.hex'
    if '-o' in sys.argv:
        out_path = sys.argv[sys.argv.index('-o') + 1]

    lines = open(src_path, encoding='utf-8').read().splitlines()

    # 第一遍: 计算每条指令的地址与标签 (含 2 字节压缩指令与 4 字节对齐补垫)
    pc = TEXT_BASE
    seg = 'text'
    labels = {}
    items = []                          # (地址, 源码行, mn, ops, 大小)
    for raw in lines:
        line = raw.split('#')[0].strip()
        if not line:
            continue
        if line.startswith('.text'):
            seg, pc = 'text', TEXT_BASE
            continue
        if line.startswith('.data'):
            seg, pc = 'data', DATA_BASE
            continue
        if line.startswith('.org'):
            pc = int(line.split()[1], 0)
            continue
        if line.startswith('.align'):
            # .align n: 对齐到 2^n 字节, 空隙补 c.nop (0x0001) 半字。
            # 用途: mtvec 等 CSR 要求 4 字节对齐的入口 (如陷阱 handler)。
            a = int(line.split()[1], 0)
            mask = (1 << a) - 1
            while pc & mask:
                items.append((pc, '# pad c.nop (.align)', '.pad', [], 2))
                pc += 2
            continue
        if line.startswith('.word'):
            if seg == 'text':
                items.append((pc, raw, '.word', [line.split()[1]], 4))
                pc += 4
            continue
        if line.startswith('.half'):
            if seg == 'text':
                items.append((pc, raw, '.half', [line.split()[1]], 2))
                pc += 2
            continue
        if line.endswith(':'):
            labels[line[:-1].strip()] = pc
            continue
        if ':' in line:
            lab, rest = line.split(':', 1)
            labels[lab.strip()] = pc
            line = rest.strip()
            if not line:
                continue
        mn = line.split()[0].lower()
        ops = [o.strip() for o in line[len(mn):].split(',') if o.strip()]
        size = instruction_size(mn, ops, labels)
        # 【RVC 对齐】所有 ≥4 字节的指令 (32 位单指令与 li 的 lui+addi 对) 都必须
        # 4 字节对齐: 落在 pc%4==2 时自动补一条 c.nop (0x0001) 半字。
        # 补垫与指令都进 items, 两遍地址一致。(实测坑: 只判 size==4 会漏掉
        # 8 字节的 li —— lui 落在半字槽上, 整个镜像从那里开始错位。)
        if size >= 4 and (pc % 4) == 2:
            items.append((pc, '# pad c.nop (alignment)', '.pad', [], 2))
            pc += 2
        items.append((pc, raw, mn, ops, size))
        pc += size

    # 第二遍: 编码, 按字节地址组包
    image = {}                          # 字节地址 -> 字节值
    listing = []
    for addr, raw, mn, ops, size in items:
        if mn == '.word':
            enc = [(4, int(ops[0], 0) & 0xFFFFFFFF)]
        elif mn == '.half':
            enc = [(2, int(ops[0], 0) & 0xFFFF)]
        elif mn == '.pad':
            enc = [(2, 0x0001)]
        else:
            enc = encode(mn, ops, addr, labels)
        total = sum(n for n, _ in enc)
        if total != size:
            print('WARN: %s 展开 %d 字节, 预期 %d 字节 (%s)' % (mn, total, size, raw))
        for n, e in enc:
            for i in range(n):
                image[addr + i] = (e >> (8 * i)) & 0xFF
            listing.append((addr, n, e & 0xFFFFFFFF, raw))
            addr += n

    # 组字输出: 从 .text 起点到镜像末尾, 每 4 字节一个字; 未覆盖的半字槽填
    # 0x0001 (c.nop)。全 32 位的老程序没有空洞, 输出与旧版汇编器逐位相同。
    end = max(image) + 1 if image else 0
    words = []
    for w in range(TEXT_BASE, (end + 3) & ~3, 4):
        val = 0
        for b in range(4):
            a = w + b
            if a in image:
                val |= image[a] << (8 * b)
            elif (a - TEXT_BASE) % 2 == 0 and (a + 1) not in image:
                val |= 0x0001 << (8 * b)       # 空洞半字 -> c.nop
                image[a] = 0x01
                image[a + 1] = 0x00
        words.append(val)

    with io.open(out_path, 'w', encoding='ascii') as f:
        for w in words:
            f.write('%08x\n' % w)

    print('=== 汇编清单 (%d 字节镜像, 输出 %s) ===' % (len(words) * 4, out_path))
    for addr, n, e, raw in listing:
        print('%08x: %0*x    %s' % (addr, n * 2, e, raw))
    print('=== 标签 ===')
    for k, v in sorted(labels.items()):
        print('%-12s = 0x%08x' % (k, v))
    return 0


if __name__ == '__main__':
    sys.exit(main())
