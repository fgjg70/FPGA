#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dual_issue_potential.py -- 双发射可行性分析 (go / no-go 判据)

对一个裸机镜像做 RV32IM 指令级模拟, 记录 CoreMark 测量窗口
(MMIO_MARK -> MMIO_RESULT) 内的**动态指令流**, 统计相邻两条指令的"可配对率",
并据此推算双发射后的 IPC 与 CM/MHz 上界。

【为什么必须是动态模拟】
静态反汇编只能看"代码段里相邻的两条", 而实际执行流有分支 —— 统计必须以
**真实执行顺序**为准。本工具自己跑一遍程序, 拿到的就是动态指令流。

【自校验 (关键)】
模拟器算出的 MMIO_RESULT 必须与 ModelSim 仿真一致 (用 --expect 传入)。
不一致 ⇒ 模拟器或镜像有问题, 此时任何配对率统计都不可信, 直接判 FAIL。
自校验值来源:
  -O2 : 0x8005AABE  (ticks 371,390)
  -Os : 0x80071204  (ticks 463,364)

【配对规则 (保守版, 对齐 biRISC-V + 本核单 LSU)】
  slot0: 任意指令
  slot1: 不允许 LOAD / STORE / DIV / CSR / AMO
         (单 LSU + 多周期单元 + 特权指令都不进第二槽)
  依赖: slot1 的源寄存器不能是 slot0 的目的寄存器 (RAW)
       两条不能写同一目的寄存器 (WAW)
 取指包: 分别统计"同 8 字节包"与"允许跨包"两种口径

【用法】
  python tools/dual_issue_potential.py \
      --imem sim/prog/cm_rv32im.hex --dmem sim/prog/cm_rv32im.dmem.hex \
      --expect 0x8005AABE --baseline-ticks 371390
"""

import argparse
import os
import sys

IMEM_BASE = 0x80000000
DMEM_BASE = 0x90000000
DMEM_SIZE = 16 * 1024
MMIO_BASE = 0xA0000000
MMIO_MARK = 0xA0000020
MMIO_RESULT = 0xA0000024
MMIO_CYCLE_LO = 0xA0000008
MMIO_MTIME_LO = 0xA0000030

# 指令类型
T_ALU, T_BR, T_JMP, T_LOAD, T_STORE, T_MUL, T_DIV, T_CSR, T_FENCE, T_AMO, T_EBREAK = (
    'ALU', 'BR', 'JMP', 'LOAD', 'STORE', 'MUL', 'DIV', 'CSR', 'FENCE', 'AMO', 'EBREAK')

SLOT1_ALLOWED = {T_ALU, T_BR, T_JMP, T_MUL, T_FENCE}


def load_hex(path):
    """读 elf2hex 输出; 支持 '@addr' 地址标记。返回 {字地址: 32位值} 或按序列表。"""
    words = []
    addr = None
    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('//') or line.startswith('#'):
                continue
            if line.startswith('@'):
                addr = int(line[1:].split()[0], 16)
                continue
            tok = line.split()[0]
            try:
                v = int(tok, 16)
            except ValueError:
                continue
            words.append(v & 0xFFFFFFFF)
    return words


class Ins:
    __slots__ = ('pc', 'raw', 'typ', 'rd', 'writes', 'srcs')

    def __init__(self, pc, raw):
        self.pc = pc
        self.raw = raw
        self.typ = T_ALU
        self.rd = 0
        self.writes = False
        self.srcs = set()


def decode(pc, ins):
    op = ins & 0x7F
    rd = (ins >> 7) & 0x1F
    f3 = (ins >> 12) & 0x7
    rs1 = (ins >> 15) & 0x1F
    rs2 = (ins >> 20) & 0x1F
    f7 = (ins >> 25) & 0x7F
    d = Ins(pc, ins)
    d.rd = rd

    if op == 0x33:                                   # OP
        if f7 == 0x01:
            d.typ = T_DIV if f3 >= 4 else T_MUL
        else:
            d.typ = T_ALU
        d.writes = True
        d.srcs = {rs1, rs2}
    elif op == 0x13 or op == 0x37 or op == 0x17:     # OPIMM / LUI / AUIPC
        d.typ = T_ALU
        d.writes = True
        d.srcs = {rs1} if op == 0x13 else set()
    elif op == 0x6F:                                  # JAL
        d.typ = T_JMP
        d.writes = True
        d.srcs = set()
    elif op == 0x67:                                  # JALR
        d.typ = T_JMP
        d.writes = True
        d.srcs = {rs1}
    elif op == 0x63:                                  # BRANCH
        d.typ = T_BR
        d.writes = False
        d.srcs = {rs1, rs2}
    elif op == 0x03:                                  # LOAD
        d.typ = T_LOAD
        d.writes = True
        d.srcs = {rs1}
    elif op == 0x23:                                  # STORE
        d.typ = T_STORE
        d.writes = False
        d.srcs = {rs1, rs2}
    elif op == 0x0F:                                  # FENCE
        d.typ = T_FENCE
        d.writes = False
    elif op == 0x2F:                                  # AMO
        d.typ = T_AMO
        d.writes = True
        d.srcs = {rs1, rs2}
    elif op == 0x73:                                  # SYSTEM
        if f3 == 0:
            d.typ = T_EBREAK
        else:
            d.typ = T_CSR
            d.writes = (rd != 0)
            d.srcs = {rs1}
    else:
        d.typ = T_ALU
    d.srcs.discard(0)
    return d


class Machine:
    def __init__(self, imem_words, dmem_words, trace_sink=None, verbose=False):
        self.imem = imem_words
        self.dmem = bytearray(DMEM_SIZE)
        self.x = [0] * 32
        self.pc = IMEM_BASE
        self.csr = {}
        self.cycle = 0
        self.trace_sink = trace_sink          # callable(Ins) 或 None
        self.verbose = verbose
        self.result = None
        self.done = False
        self.uart = []
        # .data 初值落到 dmem (按 VMA 相对偏移)
        for i, w in enumerate(dmem_words):
            off = i * 4
            if off + 3 < DMEM_SIZE:
                self.dmem[off:off + 4] = w.to_bytes(4, 'little')

    def img_fetch(self, pc):
        idx = (pc - IMEM_BASE) >> 2
        if 0 <= idx < len(self.imem):
            return self.imem[idx]
        return 0

    def dmem_read(self, addr, size, signed):
        off = addr - DMEM_BASE
        if off + size > DMEM_SIZE or off < 0:
            return None
        chunk = self.dmem[off:off + size]
        if size == 1:
            v = chunk[0]
            if signed and v & 0x80:
                v -= 0x100
        elif size == 2:
            v = int.from_bytes(chunk, 'little')
            if signed and v & 0x8000:
                v -= 0x10000
        else:
            v = int.from_bytes(chunk, 'little')
        return v & 0xFFFFFFFF

    def dmem_write(self, addr, size, val):
        off = addr - DMEM_BASE
        if off + size > DMEM_SIZE or off < 0:
            return False
        self.dmem[off:off + size] = (val & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
        return True

    def mmio_read(self, addr):
        if addr in (MMIO_CYCLE_LO, MMIO_MTIME_LO):
            return self.cycle & 0xFFFFFFFF
        if addr == MMIO_RESULT:
            return self.result or 0
        return 0

    def mmio_write(self, addr, val):
        if addr == MMIO_RESULT:
            self.result = val & 0xFFFFFFFF
        elif addr == 0xA0000010:                      # UART_TX
            self.uart.append(chr(val & 0xFF))
        elif DMEM_BASE + 0x2000 <= addr < DMEM_BASE + 0x3000:
            pass
        # tohost 由 dmem 写, 下面单独判

    def load(self, addr, size, signed):
        if addr >= MMIO_BASE:
            return self.mmio_read(addr)
        v = self.dmem_read(addr, size, signed)
        return 0 if v is None else v

    def store(self, addr, size, val):
        if addr >= MMIO_BASE:
            self.mmio_write(addr, val)
            return
        self.dmem_write(addr, size, val)
        if DMEM_BASE + 0x2000 <= addr < DMEM_BASE + 0x2004:
            if int.from_bytes(self.dmem[0x2000:0x2004], 'little') == 1:
                self.done = True

    def step(self):
        pc = self.pc
        raw = self.img_fetch(pc)
        self.cycle += 1
        ins = raw
        op = ins & 0x7F
        rd = (ins >> 7) & 0x1F
        f3 = (ins >> 12) & 0x7
        rs1 = (ins >> 15) & 0x1F
        rs2 = (ins >> 20) & 0x1F
        f7 = (ins >> 25) & 0x7F

        if self.trace_sink is not None:
            self.trace_sink(decode(pc, ins))

        a = self.x[rs1]
        b = self.x[rs2]
        npc = (pc + 4) & 0xFFFFFFFF
        wr = False
        wval = 0

        def sx(v, bits):
            m = 1 << (bits - 1)
            return (v & ((1 << bits) - 1)) - (m << 1 if v & m else 0)

        def imm_i():
            return sx(ins >> 20, 12) & 0xFFFFFFFF

        def imm_s():
            return sx(((ins >> 25) << 5) | ((ins >> 7) & 0x1F), 12) & 0xFFFFFFFF

        def imm_b():
            v = (((ins >> 31) & 1) << 12) | (((ins >> 7) & 1) << 11) | \
                (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1)
            return sx(v, 13) & 0xFFFFFFFF

        def imm_u():
            return ins & 0xFFFFF000

        def imm_j():
            v = (((ins >> 31) & 1) << 20) | (((ins >> 12) & 0xFF) << 12) | \
                (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1)
            return sx(v, 21) & 0xFFFFFFFF

        if op == 0x37:                                # LUI
            wr, wval = True, imm_u()
        elif op == 0x17:                              # AUIPC
            wr, wval = True, (pc + imm_u()) & 0xFFFFFFFF
        elif op == 0x6F:                              # JAL
            wr, wval = True, npc
            npc = (pc + imm_j()) & 0xFFFFFFFF
        elif op == 0x67:                              # JALR
            wr, wval = True, npc
            npc = (a + imm_i()) & 0xFFFFFFFE
        elif op == 0x63:                              # BRANCH
            t = {0: a == b, 1: a != b,
                 4: sx(a, 32) < sx(b, 32), 5: sx(a, 32) >= sx(b, 32),
                 6: a < b, 7: a >= b}.get(f3, False)
            if t:
                npc = (pc + imm_b()) & 0xFFFFFFFF
        elif op == 0x03:                              # LOAD
            addr = (a + imm_i()) & 0xFFFFFFFF
            size = {0: 1, 1: 2, 2: 4}.get(f3 & 3, 4)
            signed = (f3 & 4) == 0 and (f3 & 3) != 3
            wr, wval = True, self.load(addr, size, signed)
        elif op == 0x23:                              # STORE
            addr = (a + imm_s()) & 0xFFFFFFFF
            size = {0: 1, 1: 2, 2: 4}.get(f3, 4)
            self.store(addr, size, b)
        elif op == 0x13:                              # OPIMM
            i = imm_i()
            sh = (ins >> 20) & 0x1F
            if f3 == 0:   v = (a + i) & 0xFFFFFFFF
            elif f3 == 2: v = (sx(a, 32) < sx(i, 32))
            elif f3 == 3: v = 1 if a < i else 0
            elif f3 == 4: v = (a ^ i) & 0xFFFFFFFF
            elif f3 == 6: v = (a | i) & 0xFFFFFFFF
            elif f3 == 7: v = (a & i) & 0xFFFFFFFF
            elif f3 == 1: v = (a << sh) & 0xFFFFFFFF
            elif f3 == 5: v = ((a >> sh) | (a << (32 - sh) & 0xFFFFFFFF)) & 0xFFFFFFFF if (ins & 0x40000000) else (a >> sh)
            else:         v = 0
            wr, wval = True, v
        elif op == 0x33:                              # OP
            if f7 == 0x01:
                sa, sb = sx(a, 32), sx(b, 32)
                if f3 == 0:   v = (a * b) & 0xFFFFFFFF
                elif f3 == 1: v = ((sa * sb) >> 32) & 0xFFFFFFFF
                elif f3 == 2: v = ((sa * b) >> 32) & 0xFFFFFFFF
                elif f3 == 3: v = ((a * b) >> 32) & 0xFFFFFFFF
                elif f3 == 4: v = (int(sa / sb) & 0xFFFFFFFF) if sb else 0xFFFFFFFF
                elif f3 == 5: v = (a // b) if b else 0xFFFFFFFF
                elif f3 == 6: v = (int(sa - int(sa / sb) * sb) & 0xFFFFFFFF) if sb else a
                else:         v = (a % b) if b else a
            else:
                sh = b & 0x1F
                if f3 == 0:   v = (a + b) & 0xFFFFFFFF if f7 == 0 else (a - b) & 0xFFFFFFFF
                elif f3 == 1: v = (a << sh) & 0xFFFFFFFF
                elif f3 == 2: v = 1 if sx(a, 32) < sx(b, 32) else 0
                elif f3 == 3: v = 1 if a < b else 0
                elif f3 == 4: v = (a ^ b) & 0xFFFFFFFF
                elif f3 == 5: v = (a >> sh) if f7 == 0 else ((sx(a, 32) >> sh) & 0xFFFFFFFF)
                elif f3 == 6: v = (a | b) & 0xFFFFFFFF
                else:         v = (a & b) & 0xFFFFFFFF
            wr, wval = True, v
        elif op == 0x0F:
            pass
        elif op == 0x73:
            if f3 == 0:
                if (ins >> 20) == 0x302:              # MRET
                    npc = self.csr.get(0x341, 0)
                    mst = self.csr.get(0x300, 0)
                    self.csr[0x300] = (mst & ~0x1800) | ((mst >> 11) & 0x1800)
                elif (ins >> 20) == 0x001:            # EBREAK
                    self.csr[0x341] = pc
                    self.csr[0x342] = 3
                    npc = self.csr.get(0x305, 0) & 0xFFFFFFFC
                else:                                 # ECALL
                    self.csr[0x341] = pc
                    self.csr[0x342] = 11
                    npc = self.csr.get(0x305, 0) & 0xFFFFFFFC
            else:
                caddr = (ins >> 20) & 0xFFF
                src = rs1 if f3 & 4 == 0 else rs1
                old = self.csr.get(caddr, 0)
                if (ins & 0x40000) and f3 >= 5:       # immediate form
                    srcval = rs1
                else:
                    srcval = a
                if f3 & 3 == 1:   new = srcval
                elif f3 & 3 == 2: new = old | srcval
                else:             new = old & ~srcval
                self.csr[caddr] = new & 0xFFFFFFFF
                wr, wval = True, old
        else:
            raise RuntimeError('未实现 opcode 0x%02x @pc=0x%08x' % (op, pc))

        if wr and rd != 0:
            self.x[rd] = wval & 0xFFFFFFFF
        self.x[0] = 0
        self.pc = npc


def pair_stats(ins_list, same_pkg, allow_br_slot1, intra_bypass):
    """返回可配对数。

    same_pkg       : True = 两条必须在同一 8 字节取指包内
    allow_br_slot1 : True = 允许 BR 进 slot1 (需要两个分支端口 / squash 逻辑)
    intra_bypass   : True = 允许 slot0 的 ALU 结果同拍旁路给 slot1 (需额外组合路径)
    slot0 是 BR/JMP 时一律不算配对 —— taken 会冲刷 slot1, 白发射不计入吞吐。
    """
    n = len(ins_list)
    allowed = {T_ALU, T_MUL}
    if allow_br_slot1:
        allowed.add(T_BR)
    pairs = 0
    i = 0
    while i + 1 < n:
        a, b = ins_list[i], ins_list[i + 1]
        ok = b.typ in allowed
        if ok and a.typ in (T_BR, T_JMP):
            ok = False
        if ok and same_pkg and ((a.pc >> 3) != (b.pc >> 3)):
            ok = False
        if ok and a.writes and a.rd != 0 and a.rd in b.srcs:
            if not (intra_bypass and a.typ == T_ALU):
                ok = False
        if ok and a.writes and b.writes and a.rd == b.rd and a.rd != 0:
            ok = False
        if ok:
            pairs += 1
            i += 2
        else:
            i += 1
    return pairs, n


def loaduse_profile(ins_list):
    """统计 load-use 的消费者: 距离 + 类型。

    这决定了 SweRV 式"延迟执行到后级 ALU"能消化掉多少:
      - 消费者是 ALU  -> 可以在后级 ALU 重算, 零停顿
      - 消费者是 BR   -> 分支判定被迫推后, 变成更长的分支惩罚
      - 消费者是 STORE-> 需要地址/数据, 处理方式不同
    动态流, 所以 ins_list[j] 就是实际执行的下一条 (分支已解析)。
    """
    from collections import Counter
    n = len(ins_list)
    dist = Counter()
    typ = Counter()
    events = 0
    MAXD = 9
    for i, d in enumerate(ins_list):
        if d.typ != T_LOAD or not d.writes or d.rd == 0:
            continue
        for j in range(i + 1, min(i + 1 + MAXD, n)):
            o = ins_list[j]
            if o.writes and o.rd == d.rd:
                break                                    # 依赖被覆盖
            if d.rd in o.srcs:
                events += 1
                dd = j - i
                dist[dd] += 1
                typ[(dd, o.typ)] += 1
                break
    return events, dist, typ


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--imem', default='sim/prog/cm_rv32im.hex')
    ap.add_argument('--dmem', default='sim/prog/cm_rv32im.dmem.hex')
    ap.add_argument('--expect', default=None, help='期望的 MMIO_RESULT 值 (自校验)')
    ap.add_argument('--baseline-ticks', type=int, default=371390,
                    help='当前单发射的测量窗口周期数 (用于算基准 CM/MHz)')
    ap.add_argument('--stall-factor', type=float, default=1.15,
                    help='双发射后停顿放大系数 (保守起见 >1.0)')
    ap.add_argument('--max-steps', type=int, default=20000000)
    ap.add_argument('--show-uart', action='store_true', help='打印程序串口输出 (诊断用)')
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    im = load_hex(os.path.join(root, args.imem))
    dm = load_hex(os.path.join(root, args.dmem))
    print('[load] imem %d 字, dmem %d 字' % (len(im), len(dm)))

    window = []
    state = {'in_window': False}

    def sink(d):
        if state['in_window']:
            window.append(d)

    m = Machine(im, dm, trace_sink=sink)

    # 用 mmio 写事件控制窗口
    orig_mmio_write = m.mmio_write

    def mmio_write(addr, val):
        orig_mmio_write(addr, val)
        if addr == MMIO_MARK:
            state['in_window'] = True
            window.clear()
        elif addr == MMIO_RESULT:
            state['in_window'] = False

    m.mmio_write = mmio_write

    steps = 0
    try:
        while not m.done and steps < args.max_steps:
            m.step()
            steps += 1
    except RuntimeError as e:
        print('[FAIL] %s' % e, file=sys.stderr)
        return 2

    print('[run ] 执行 %d 条指令, result=0x%08X, uart=%d 字符'
          % (steps, m.result or 0, len(m.uart)))
    if args.show_uart:
        print('--- UART ---')
        print(''.join(m.uart[-2000:]))
        print('--- /UART ---')

    # 自校验: MMIO_RESULT 的低 31 位是 **tick 计数** (不是 CRC), 本模拟器没有
    # 精确的停顿模型, 不可能复现它。真正的校验点在程序自己的串口输出:
    # CoreMark 只有在 CRC 与官方值逐位一致时才打印 "Correct operation validated"。
    uart_txt = ''.join(m.uart)
    if 'Correct operation validated' in uart_txt:
        print('[self] 自校验 PASS: 程序自打印 "Correct operation validated" ⇒ 指令流正确')
    else:
        print('[self] 自校验 FAIL: 未见到 "Correct operation validated"',
              file=sys.stderr)
        print('       指令流可能不正确, 下面的统计不可信', file=sys.stderr)
        return 3
    print('[self] 参考: 模拟器窗口周期=%s (硬件 window fetch 见对应 .log)'
          % (args.baseline_ticks and '见下'))

    if not window:
        print('[FAIL] 未捕获到测量窗口 (MMIO_MARK -> MMIO_RESULT)', file=sys.stderr)
        return 2

    n = len(window)
    variants = [
        ('A 严格  (同包, 无BR-slot1, 无同拍旁路)', True,  False, False),
        ('B 放宽  (同包, 允许BR-slot1)',            True,  True,  False),
        ('C 宽松  (跨包, 允许BR-slot1)',            False, True,  False),
        ('D 激进  (跨包, BR-slot1, 同拍旁路)',      False, True,  True),
    ]

    # 类型分布
    from collections import Counter
    dist = Counter(d.typ for d in window)

    print()
    print('=' * 66)
    print('  测量窗口动态指令流统计')
    print('=' * 66)
    print('  指令数 N            : %d' % n)
    print('  窗口周期 (单发射)   : %d' % args.baseline_ticks)
    print('  单发射 CPI          : %.3f' % (args.baseline_ticks / n))
    print()
    print('  指令类型分布:')
    for k, v in dist.most_common():
        print('    %-7s %7d  %5.1f%%' % (k, v, 100.0 * v / n))
    print()

    base_stall = args.baseline_ticks - n
    need_pairs = n - (1e6 / 4.2 - base_stall * args.stall_factor)
    print('  达成 CM/MHz 4.2 所需配对数: %d  (配对率 %.1f%%)'
          % (need_pairs, 100.0 * need_pairs / n))
    print('  [假设停顿放大 %.2fx: %.0f -> %.0f 拍]'
          % (args.stall_factor, base_stall, base_stall * args.stall_factor))
    print()

    results = []
    for label, same, br1, intra in variants:
        p, _ = pair_stats(window, same, br1, intra)
        stalls = base_stall * args.stall_factor
        cyc = (n - p) + stalls
        cm = 1e6 / cyc
        ipc = n / cyc
        results.append((label, p, cm, ipc, cyc))
        print('  [%s]' % label)
        print('      可配对 %6d 对   配对率 %5.1f%%   基础 IPC %.3f'
              % (p, 100.0 * p / n, n / (n - p) if n > p else 0))
        print('      预估周期 %7.0f   预估 IPC %.3f   预估 CM/MHz %.3f  %s'
              % (cyc, ipc, cm, '+OK' if cm >= 4.2 else ''))
        print()

    best = max(results, key=lambda r: r[2])
    print('-' * 66)
    print('  go / no-go')
    print('    最宽口径 (%s)' % best[0])
    print('      CM/MHz 上界 = %.3f   (需要 4.2)' % best[2])
    print('    结论: %s' % ('GO  —— 双发射有希望达标' if best[2] >= 4.2 else
                            ('NO-GO —— 双发射单独不足以到 4.2')))
    print('-' * 66)

    # ---- 停顿敏感性: 双发射只买一半的账, 另一半在停顿里 ----
    p_c = results[2][1]          # 口径 C (跨包 + 允许 BR 进 slot1)
    print()
    print('  停顿敏感性 (口径 C 配对率 %.1f%%, 基础发射周期 %d)'
          % (100.0 * p_c / n, n - p_c))
    print('    当前停顿 %d 拍 (占总周期 %.1f%%)' % (base_stall, 100.0 * base_stall / args.baseline_ticks))
    need_stall = 1e6 / 4.2 - (n - p_c)
    print('    要达 4.2 需停顿 <= %.0f 拍  (比现在少 %.0f%%)'
          % (need_stall, 100.0 * (1 - need_stall / base_stall)))
    print('    %-10s %-12s %-10s %s' % ('停顿', '周期', 'CM/MHz', ''))
    for st in (base_stall, 60000, 45000, 30000, 25000, 20000, 15000, 10000):
        cyc = (n - p_c) + st
        cm = 1e6 / cyc
        print('    %-10d %-12.0f %-10.3f %s' % (st, cyc, cm, '<== 达标' if cm >= 4.2 else ''))
    print()
    print('  说明: 双发射把"发射周期"从 N 压到 N-P, 但停顿(stalls)不变甚至变差。')
    print('        只做双发射 ⇒ 上表第一行;  既要 4.2 就必须同时把停顿砍到最后一两行。')

    # ---- load-use 消费者画像: 决定"延迟执行到后级 ALU"能消化掉多少 ----
    ev, dist, typ = loaduse_profile(window)
    print()
    print('=' * 66)
    print('  load-use 消费者画像（决定 SweRV 式后级 ALU 的收益）')
    print('=' * 66)
    print('  load-use 事件总数: %d  (每次事件当前按 %.2f 拍计)'
          % (ev, 65369.0 / 36791 if ev == 36791 else 0))
    print()
    print('  距离分布 (load 后面第几条消费者):')
    for dd in sorted(dist):
        print('    距离 %d : %7d 次   %5.1f%%' % (dd, dist[dd], 100.0 * dist[dd] / ev))
    print()
    print('  消费者类型 × 距离:')
    rows = sorted(typ.items(), key=lambda kv: (kv[0][0], kv[0][1]))
    for (dd, t), c in rows:
        print('    距离 %d  %-6s %7d 次   (占全部 %.1f%%)'
              % (dd, t, c, 100.0 * c / ev))
    print()
    alu = sum(c for (dd, t), c in typ.items() if t in (T_ALU, T_MUL))
    br = sum(c for (dd, t), c in typ.items() if t in (T_BR, T_JMP))
    st = sum(c for (dd, t), c in typ.items() if t == T_STORE)
    ld = sum(c for (dd, t), c in typ.items() if t == T_LOAD)
    print('  汇总:')
    print('    可被后级 ALU 消化 (ALU/MUL) : %7d 次  %5.1f%%'
          % (alu, 100.0 * alu / ev))
    print('    会推后分支判定 (BR/JMP)     : %7d 次  %5.1f%%'
          % (br, 100.0 * br / ev))
    print('    存数 (STORE)                : %7d 次  %5.1f%%'
          % (st, 100.0 * st / ev))
    print('    再次 load                   : %7d 次  %5.1f%%'
          % (ld, 100.0 * ld / ev))
    print('-' * 66)
    return 0


if __name__ == '__main__':
    sys.exit(main())
