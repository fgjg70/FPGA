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
    # v0.6/v0.7: route/concat 展开后的硬件 copy op (走引擎 NN_OP_COPY)
    'copy': 9,
    # v0.5: shortcut residual-add 改由 CPU 执行 (per-tensor 源 requant)。
    # 目的: 解除 branch/sum 张量被迫共享激活 scale 的约束 (int8 精度根因, 见 model-report §6)。
    'cpu_add': 8,
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
    w('#define YF_PACKED3   0x20u   /* v0.7: conv0 输入 3B/像素 packed */')
    w('#define YF_ADD_R     0x40u   /* v0.7: add 用 per-tensor 源 requant */')
    w('')
    # 【紧凑结构体】dmem 的 .data/.bss 预算只有 8KB (link.ld ASSERT ≤0x2000)。
    # 108 个 op × 全 u32 (68B) 会到 9KB+ 而链接失败; 把 kind/尺寸字段压成 u16 后
    # 每项 52B ⇒ 约 5.6KB。字段顺序必须与下面的初始化列表逐项一致。
    w('typedef struct {')
    w('    unsigned short kind, flags, k, stride, pad;')
    w('    unsigned short ih, iw, ic, oc;')
    w('    unsigned int src, dst;      /* NN 窗口绝对偏移 */')
    w('    unsigned int woff, qoff;    /* 权重/量化参数偏移 */')
    w('    /* v0.5: cpu_add 用 aux0=R(源域->目标域的 per-tensor 乘数),')
    w('     *       aux1=KADD(右移位数), aux2=zp_s(源张量 zero-point, 符号扩展存 u32);')
    w('     *       其它 kind 全 0。C 侧公式见 CONTRACT §11。 */')
    w('    unsigned int aux0, aux1, aux2;')
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
        if kind == 1 or op.get('depthwise'):
            flags |= 0x01                 # NN_F_DEPTHWISE
        if op.get('leaky'):
            flags |= 0x02                 # NN_F_LEAKY
        if op['kind'] == 'upsample':
            flags |= 0x08                 # NN_F_UP2X
        if kind == 2:
            flags |= 0x10                 # NN_F_POOLMAX
        if op.get('packed3') or op['kind'] == 'cpu_conv0':
            flags |= 0x20                 # NN_F_PACKED3 (conv0: 3B/像素 packed 输入)
        if op['kind'] == 'add' and ('r_scale' in op or 'R' in op):
            flags |= 0x40                 # NN_F_ADD_R (per-tensor 源 requant)
        if op['kind'] == 'add' and not (flags & 0x40):
            flags |= 0x04                 # NN_F_ADD (纯 add)
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
        if kind == 8:
            aux0 = int(op.get('r_scale', 0)) & 0xFFFFFFFF
            aux1 = int(op.get('k_add', 0)) & 0xFFFFFFFF
            aux2 = int(op.get('zp_s', 0)) & 0xFFFFFFFF
            ic = op.get('ic', 0)
            oc = op.get('ic', 0)      # cpu_add 输出通道数 = 输入通道数 (原地写回 dst)
        else:
            aux0 = aux1 = aux2 = 0
        w('    {%du, 0x%02xu, %du, %du, %du,  %du, %du, %du, %du,'
          % (kind, flags, k, stride, pad, ih, iw, ic, oc))
        w('     0x%08xu, 0x%08xu, 0x%08xu, 0x%08xu,'
          % (src_abs, dst_abs, woff, qoff))
        w('     0x%08xu, 0x%08xu, 0x%08xu, 0x%08xu},'
          % (aux0, aux1, aux2, op['csum'] & 0xFFFFFFFF))
    if not ops:
        w('    {0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u},')
    w('};')
    w('')
    # ---- 最终输出张量表 (MODE_AUTO 完成后校验用) ----
    fin_ops = plan.get('final_ops', [])

    def out_dim(d, k, s, p):
        k = max(int(k), 1); s = max(int(s), 1); p = int(p)
        return (int(d) + 2 * p - k) // s + 1

    finals = []
    for fi in fin_ops:
        op = ops[int(fi)]
        oh = out_dim(op.get('ih', 0), op.get('k', 1), op.get('stride', 1), op.get('pad', 0))
        ow = out_dim(op.get('iw', 0), op.get('k', 1), op.get('stride', 1), op.get('pad', 0))
        oc = int(op.get('oc', 0))
        finals.append((abs_off(op['dst']['buf'], op['dst']['off'], nn),
                       oh, ow, oc, int(op.get('csum', 0)) & 0xFFFFFFFF))
    w('')
    legacy = [op.get('kind') for op in ops if str(op.get('kind', '')).startswith('cpu_')]
    w('')
    w('/* MODE_AUTO 可用性: 1 = plan 全硬件 op (v0.6+) 且 ROM 已生成；0 = 过渡期/空 ROM */')
    w('#define YOLO_AUTO_OK %du' % (0 if legacy else 1))
    w('/* ---- 最终输出张量 (MODE_AUTO 校验) ---- */')
    w('typedef struct { unsigned int abs, h, w, c, csum; } yolo_final_t;')
    w('#define YOLO_FINAL_N %du' % len(finals))
    w('static const yolo_final_t YOLO_FINALS[YOLO_FINAL_N > 0 ? YOLO_FINAL_N : 1] = {')
    for (ab, oh, ow, oc, cs) in finals:
        w('    {0x%08xu, %du, %du, %du, 0x%08xu},' % (ab, oh, ow, oc, cs))
    if not finals:
        w('    {0u, 0u, 0u, 0u, 0u},')
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
