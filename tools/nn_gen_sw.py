#!/usr/bin/env python3
"""nn_gen_sw.py - plan.json (+ rv32_pkg/nn_pkg 常量) -> sw/yolo_plan.h

AI 加速子系统的软件侧生成器。**唯一的地址/布局事实来源是 RTL 侧的
rv32_pkg.sv / nn_pkg.sv 与 plan.json**，本脚本把它们抄成 C 常量，C 程序不手写地址。

用法:
    python tools/nn_gen_sw.py --plan sim/prog/yolo/plan.json -o sw/yolo_plan.h
    python tools/nn_gen_sw.py --plan sim/prog/yolo/plan.json -o sw/yolo_plan.h --check

为什么会存在（纪律）:
  * 本仓库最贵的教训是"同一事实写在两处、只改了一处"(PITFALLS R1)。NN 窗口的
    分区偏移 (NN_A_OFF 等)、MMIO 寄存器地址如果 C 程序手抄一遍，改布局时必错。
    所以 C 侧只认这个生成头文件。
  * plan.json 由 T-model 的 numpy golden 导出（CONTRACT §10.1），C 程序与 RTL TB
    用同一份执行计划与同一组 FNV checksum 判据。

plan.json 需要的字段（CONTRACT §10.1）:
  input: {ih, iw, ic, act_off, csum}
  ops  : [{id, kind, k, stride, pad, leaky, ih, iw, ic, oc,
           src:{buf,off}, dst:{buf,off}, woff, qoff, csum}]
         kind ∈ conv | dwconv | pool | upsample | add | cpu_concat | cpu_copy
  cpu_concat/cpu_copy 额外: {"sources": [{buf,off,c}], "oc_tensor": 目标张量通道数}
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def read_text(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()


def parse_pkg_consts(path):
    """从 rv32_pkg.sv / nn_pkg.sv 抽 localparam/parameter 32 位常量。"""
    txt = read_text(path)
    out = {}
    # 形如: localparam logic [31:0] MMIO_NN_CTRL   = 32'hA000_0100;
    #       parameter logic [31:0] NN_BASE = 32'h9004_0000;
    #       parameter int unsigned NN_BYTES = 512*1024;
    for m in re.finditer(r'(?:localparam|parameter)\s+(?:logic\s*\[31:0\]|int\s+unsigned)\s+'
                         r'([A-Z][A-Z0-9_]+)\s*=\s*([^;]+);', txt):
        name, expr = m.group(1), m.group(2).strip()
        try:
            out[name] = eval_verilog_int(expr)
        except Exception:
            pass
    return out


def eval_verilog_int(expr):
    e = expr.strip().rstrip(';').strip()
    # 去掉 Verilog 数字分隔符与 32'h 前缀
    e = e.replace('_', '')
    m = re.fullmatch(r"\d*'([hHdDbBoO])([0-9a-fA-F]+)", e)
    if m:
        base = {'h': 16, 'd': 10, 'b': 2, 'o': 8}[m.group(1).lower()]
        return int(m.group(2), base)
    if re.fullmatch(r'[0-9+\-*/() ]+', e):
        return int(eval(e, {'__builtins__': {}}, {}))
    raise ValueError('unsupported constant: %r' % expr)


KIND = {
    'conv': 0, 'dwconv': 1, 'pool': 2, 'upsample': 3, 'add': 4,
    'cpu_concat': 5, 'cpu_copy': 6, 'cpu_conv0': 7,
}
HW_KINDS = {0, 1, 2, 3, 4}      # 7 = cpu_conv0 由 CPU 执行, 不走引擎


def abs_off(buf, off, c):
    """plan 的 (buf, off) -> NN 窗口内绝对字节偏移。"""
    if buf == 'A':
        return c['NN_A_OFF'] + off
    if buf == 'B':
        return c['NN_B_OFF'] + off
    raise ValueError('bad buf %r' % (buf,))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--plan', required=True, help='sim/prog/yolo/plan.json')
    ap.add_argument('-o', '--out', default='sw/yolo_plan.h')
    ap.add_argument('--check', action='store_true', help='只要校验, 不写头文件')
    args = ap.parse_args()

    rv = parse_pkg_consts(os.path.join(REPO, 'rv32_pkg.sv'))
    nn = parse_pkg_consts(os.path.join(REPO, 'nn_pkg.sv'))
    needed = ['NN_BASE', 'NN_BYTES', 'MMIO_NN_CTRL', 'MMIO_NN_STATUS', 'MMIO_NN_CYCLES',
              'MMIO_NN_OP', 'MMIO_NN_SRC', 'MMIO_NN_DST', 'MMIO_NN_WOFF', 'MMIO_NN_QOFF',
              'MMIO_NN_IH', 'MMIO_NN_IW', 'MMIO_NN_IC', 'MMIO_NN_OC', 'MMIO_NN_KS',
              'MMIO_NN_ST', 'MMIO_NN_PAD', 'MMIO_NN_FLAGS', 'MMIO_NN_DBG2',
              'MMIO_CYCLE_LO', 'MMIO_CYCLE_HI', 'MMIO_UART_TX', 'MMIO_UART_STAT',
              'MMIO_RESULT']
    missing = [k for k in needed if k not in rv]
    if missing:
        print('[FAIL] rv32_pkg.sv 缺常量: %s' % missing, file=sys.stderr)
        return 1
    for k in ('NN_A_OFF', 'NN_B_OFF'):
        if k not in nn:
            print('[FAIL] nn_pkg.sv 缺常量 %s' % k, file=sys.stderr)
            return 1

    plan = json.loads(read_text(os.path.join(REPO, args.plan)
                                if not os.path.isabs(args.plan) else args.plan))
    ops = plan['ops']
    inp = plan['input']

    # ---- 校验 (fail closed: 不合格不生成) ----
    errs = []
    # A/B 容量从 nn_pkg 反推 (v0.3.1: A=96KB / B=32KB, 不等大):
    #   A_BYTES = NN_B_OFF - NN_A_OFF; B_BYTES = NN_BYTES - NN_B_OFF
    a_bytes = nn['NN_B_OFF'] - nn['NN_A_OFF']
    b_bytes = rv['NN_BYTES'] - nn['NN_B_OFF']
    cap = {'A': a_bytes, 'B': b_bytes}
    for i, op in enumerate(ops):
        kind = op['kind']
        if kind not in KIND:
            errs.append('op %d: 未知 kind %r' % (i, kind))
            continue
        if 'csum' not in op:
            errs.append('op %d: 缺 csum' % i)
        for key in ('src', 'dst'):
            if key not in op:
                continue
            o = op[key]
            if o['buf'] not in cap:
                errs.append('op %d: %s.buf=%r (只允许 A/B)' % (i, key, o['buf']))
                continue
            if o['off'] < 0 or o['off'] >= cap[o['buf']]:
                errs.append('op %d: %s(%s).off=%d 越界 (块容量 %d)'
                            % (i, key, o['buf'], o['off'], cap[o['buf']]))
        if kind in ('conv', 'dwconv'):
            for key in ('k', 'stride', 'pad', 'ih', 'iw', 'ic', 'oc', 'woff', 'qoff'):
                if key not in op:
                    errs.append('op %d: 缺字段 %s' % (i, key))
            if kind == 'dwconv' and op.get('ic') != op.get('oc'):
                errs.append('op %d: dwconv 要求 ic==oc (%r vs %r)' % (i, op.get('ic'), op.get('oc')))
    # 输入图必须落在 A 缓冲内
    if inp['act_off'] < 0 or inp['act_off'] >= a_bytes:
        errs.append('input.act_off 越界')
    if errs:
        print('[FAIL] plan.json 校验失败 (%d 项):' % len(errs), file=sys.stderr)
        for e in errs[:20]:
            print('   ' + e, file=sys.stderr)
        return 1

    # ---- 生成 C 头 ----
    L = []
    w = L.append
    w('/* ==========================================================================')
    w(' * yolo_plan.h - AUTO-GENERATED by tools/nn_gen_sw.py -- DO NOT EDIT BY HAND')
    w(' *   source: %s' % args.plan)
    w(' *   地址常量来自 rv32_pkg.sv / nn_pkg.sv (单一事实来源)。')
    w(' * ==========================================================================*/')
    w('#ifndef YOLO_PLAN_H')
    w('#define YOLO_PLAN_H')
    w('')
    w('/* ---- NN 窗口 (rv32_pkg) ---- */')
    w('#define YOLO_NN_BASE   0x%08xu' % rv['NN_BASE'])
    w('#define YOLO_NN_BYTES  0x%08xu' % rv['NN_BYTES'])
    w('#define YOLO_A_OFF     0x%08xu' % nn['NN_A_OFF'])
    w('#define YOLO_B_OFF     0x%08xu' % nn['NN_B_OFF'])
    w('#define YOLO_A_BYTES   0x%08xu   /* v0.3.1: A/B 不等大 */' % a_bytes)
    w('#define YOLO_B_BYTES   0x%08xu' % b_bytes)
    w('')
    w('/* ---- MMIO 寄存器 (rv32_pkg) ---- */')
    for k in ('MMIO_NN_CTRL', 'MMIO_NN_STATUS', 'MMIO_NN_CYCLES', 'MMIO_NN_OP',
              'MMIO_NN_SRC', 'MMIO_NN_DST', 'MMIO_NN_WOFF', 'MMIO_NN_QOFF',
              'MMIO_NN_IH', 'MMIO_NN_IW', 'MMIO_NN_IC', 'MMIO_NN_OC', 'MMIO_NN_KS',
              'MMIO_NN_ST', 'MMIO_NN_PAD', 'MMIO_NN_FLAGS', 'MMIO_NN_DBG2',
              'MMIO_CYCLE_LO', 'MMIO_CYCLE_HI', 'MMIO_UART_TX', 'MMIO_UART_STAT',
              'MMIO_RESULT'):
        w('#define %-16s 0x%08xu' % (k, rv[k]))
    w('')
    w('/* ---- 模型输入 ---- */')
    w('#define YOLO_INPUT_H       %du' % inp['ih'])
    w('#define YOLO_INPUT_W       %du' % inp['iw'])
    w('#define YOLO_INPUT_C       %du' % inp['ic'])
    w('#define YOLO_INPUT_CSUM    0x%08xu' % inp['csum'])
    w('#define YOLO_INPUT_ABS     0x%08xu  /* 输入图在 NN 窗口内的绝对偏移 */'
      % abs_off('A', inp['act_off'], nn))
    gen = inp.get('gen', {})
    if gen.get('kind') != 'pattern_v1':
        print('[FAIL] input.gen.kind 必须是 pattern_v1（当前 %r）；'
              '公式见 CONTRACT §10.1（C 与 Python 必须逐字节一致）' % (gen.get('kind'),),
              file=sys.stderr)
        return 1
    w('#define YOLO_INPUT_GEN_KIND 1u   /* pattern_v1 */')
    w('#define YOLO_INPUT_GEN_SEED 0x%08xu' % (int(gen.get('seed', 0)) & 0xFFFFFFFF))
    # 输入图存储布局: packed (stride = ic, 无 8 通道 padding) —— v0.3.1
    # 为什么: 128x128x3 按 §8 的 8 通道分块是 128KB, 放不进 64KB 的 A 缓冲;
    # packed 只需 49,152B。第 0 层因此由 CPU 执行 (kind = cpu_conv0)。
    packed = bool(inp.get('packed', True))
    w('#define YOLO_INPUT_PACKED   %du' % (1 if packed else 0))
    w('#define YOLO_INPUT_STRIDE   %du   /* packed 时 = ic, 否则 = ceil(ic/8)*8 */'
      % (inp['ic'] if packed else ((inp['ic'] + 7) // 8) * 8))
    w('#define YOLO_INPUT_BYTES    %du' % (inp['ih'] * inp['iw'] *
                                          (inp['ic'] if packed else ((inp['ic'] + 7) // 8) * 8)))
    w('')
    w('/* ---- op kind ---- */')
    for name, code in KIND.items():
        w('#define YK_%-10s %du' % (name.upper(), code))
    w('#define YOLO_NUM_OPS %du' % len(ops))
    w('')
    w('/* flags 位 (与 nn_pkg 的 NN_F_* 一致) */')
    w('#define YF_DEPTHWISE 0x01u')
    w('#define YF_LEAKY     0x02u')
    w('#define YF_ADD       0x04u')
    w('#define YF_UP2X      0x08u')
    w('#define YF_POOLMAX   0x10u')
    w('')
    w('typedef struct {')
    w('    unsigned int kind, flags, k, stride, pad;')
    w('    unsigned int ih, iw, ic, oc;')
    w('    unsigned int src, dst;      /* NN 窗口绝对偏移 */')
    w('    unsigned int woff, qoff;    /* 权重/量化参数偏移 */')
    w('    unsigned int csum;          /* golden FNV-1a */')
    w('} yolo_op_t;')
    w('')
    # concat 表: 把 cpu_concat/cpu_copy 的源展开成连续表
    cat_entries = []   # (first, nsrc, dst_abs, oc_tensor, csum)
    cat_srcs = []
    for op in ops:
        if KIND[op['kind']] in (5, 6):
            first = len(cat_srcs)
            for s in op['sources']:
                cat_srcs.append((abs_off(s['buf'], s['off'], nn), s['c']))
            cat_entries.append((first, len(op['sources']),
                                abs_off(op['dst']['buf'], op['dst']['off'], nn),
                                op['oc_tensor'], op['csum']))
    w('typedef struct { unsigned int abs, c; } yolo_src_t;')
    w('typedef struct { unsigned int first, nsrc, dst, oc, csum; } yolo_cat_t;')
    w('')
    w('#define YOLO_NUM_CAT_SRC %du' % len(cat_srcs))
    w('#define YOLO_NUM_CATS    %du' % len(cat_entries))
    w('')
    w('static const yolo_src_t YOLO_CAT_SRC[YOLO_NUM_CAT_SRC > 0 ? YOLO_NUM_CAT_SRC : 1] = {')
    for (ab, c) in cat_srcs:
        w('    {0x%08xu, %du},' % (ab, c))
    if not cat_srcs:
        w('    {0u, 0u},')
    w('};')
    w('static const yolo_cat_t YOLO_CATS[YOLO_NUM_CATS > 0 ? YOLO_NUM_CATS : 1] = {')
    for (first, nsrc, dst_abs, oc_t, cs) in cat_entries:
        w('    {%du, %du, 0x%08xu, %du, 0x%08xu},' % (first, nsrc, dst_abs, oc_t, cs))
    if not cat_entries:
        w('    {0u, 0u, 0u, 0u, 0u},')
    w('};')
    w('')
    w('/* ---- 执行计划 ---- */')
    w('static const yolo_op_t YOLO_OPS[YOLO_NUM_OPS > 0 ? YOLO_NUM_OPS : 1] = {')
    cat_index = 0
    for op in ops:
        kind = KIND[op['kind']]
        flags = 0
        if kind == 1:
            flags |= 0x01
        if op.get('leaky'):
            flags |= 0x02
        if op['kind'] == 'upsample':
            flags |= 0x08
        if kind == 2:
            flags |= 0x10
        if kind in (5, 6):
            src_abs = cat_index
            cat_index += 1
            dst_abs = abs_off(op['dst']['buf'], op['dst']['off'], nn)
            woff = len(op['sources'])
            qoff = 0
            ic = op['sources'][0]['c'] if kind == 6 else 0
            oc = op['oc_tensor']
            ih = op.get('ih', 0)
            iw = op.get('iw', 0)
            k = stride = pad = 0
        else:
            src_abs = abs_off(op['src']['buf'], op['src']['off'], nn)
            dst_abs = abs_off(op['dst']['buf'], op['dst']['off'], nn)
            woff = op.get('woff', 0)
            qoff = op.get('qoff', 0)
            ic = op.get('ic', 0)
            oc = op.get('oc', 0)
            ih = op.get('ih', 0)
            iw = op.get('iw', 0)
            k = op.get('k', 0)
            stride = op.get('stride', 0)
            pad = op.get('pad', 0)
        # 【防御】plan.json 里"不适用的字段"可能被写成 -1（例如 pool/add/copy 的 woff/qoff）。
        # 生成的是 unsigned C 字面量, 负值会变成 `0x-0000001u` 这种非法常量 —— 这里统一夹到 0。
        # (首版就踩到了: 84 个 conv 之外的 op 全部 woff/qoff=-1, C 编译直接报 "invalid suffix 'x'")
        k = max(k, 0); stride = max(stride, 0); pad = max(pad, 0)
        ih = max(ih, 0); iw = max(iw, 0); ic = max(ic, 0); oc = max(oc, 0)
        woff = max(woff, 0); qoff = max(qoff, 0)
        w('    {%du, 0x%02xu, %du, %du, %du,  %du, %du, %du, %du,'
          % (kind, flags, k, stride, pad, ih, iw, ic, oc))
        w('     0x%08xu, 0x%08xu, 0x%08xu, 0x%08xu, 0x%08xu},'
          % (src_abs, dst_abs, woff, qoff, op['csum'] & 0xFFFFFFFF))
    if not ops:
        w('    {0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u},')
    w('};')
    w('')
    w('#endif /* YOLO_PLAN_H */')

    if args.check:
        print('PLAN_CHECK=PASS ops=%d cats=%d cat_srcs=%d' % (len(ops), len(cat_entries), len(cat_srcs)))
        return 0
    out = os.path.join(REPO, args.out) if not os.path.isabs(args.out) else args.out
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(L) + '\n')
    print('PLAN_GEN=PASS ops=%d cats=%d cat_srcs=%d -> %s'
          % (len(ops), len(cat_entries), len(cat_srcs), out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
