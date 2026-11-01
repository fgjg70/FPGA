#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nn_gen_rom.py — plan.json → 微码 ROM 包 (`nn_rom_pkg.sv`) + 可核对表 (nn_rom_table.json)

v0.7 特化架构：NPU 自主执行（nn_seq）按 ROM 顺序跑完所有 op；ROM 项类型见 nn_pkg::nn_rom_t。
本工具是"从模型计划到硬件微码"的唯一生成入口，生成物进 git（可复现、可 review）。

用法：
    python tools/nn_gen_rom.py --plan sim/prog/yolo/plan.json -o nn_rom_pkg.sv
    python tools/nn_gen_rom.py --plan sim/prog/yolo/plan.json -o nn_rom_pkg.sv \
        --table results/ai-accel/nn_rom_table.json

字段打包顺序（与 nn_pkg::nn_rom_t 声明顺序一致，MSB 在前）：
    kind4 flags7 ks4 pad3 stride2 ic10 oc10 ih9 iw9 src19 dst19 woff19 qoff16
    aux0_16 aux1_16 csum32 rsvd5  = 200 bit

kind 映射：
    conv → 0 (flags.PACKED3 表示 conv0 的 3B/像素输入)
    dwconv → 1
    pool → 2
    upsample → 3 (copy + UP2X)
    add → 4 (flags.ADD_R 时带 per-tensor R)
    copy → 5
    cpu_conv0 → 转成 conv + PACKED3
    cpu_add  → 转成 add + ADD_R
    cpu_concat/cpu_copy → 展开成多个 copy（8 通道粒度；最后一个 copy 带该 op 的 csum）
"""
import argparse
import json
import os
import re
import sys

# ---- 从 nn_pkg.sv 读取地址常量（单一事实来源，禁止手写两份）----
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_pkg_int(name, default=None):
    path = os.path.join(REPO, 'nn_pkg.sv')
    txt = open(path, encoding='utf-8').read()
    m = re.search(
        r'localparam\s+logic\s+\[31:0\]\s+' + name + r'\s*=\s*32\'h([0-9a-fA-F_]+)', txt)
    if not m:
        if default is None:
            raise SystemExit('[FAIL] nn_pkg.sv 里找不到 %s' % name)
        return default
    return int(m.group(1).replace('_', ''), 16)


NUM_FIELDS = [
    # (名字, 位宽)
    ('kind', 4), ('flags', 7), ('ks', 4), ('pad', 3), ('stride', 2),
    ('ic', 10), ('oc', 10), ('ih', 9), ('iw', 9),
    ('src', 19), ('dst', 19), ('woff', 19), ('qoff', 16),
    ('aux0', 16), ('aux1', 16), ('csum', 32), ('rsvd', 5),
]
TOTAL_BITS = sum(w for _, w in NUM_FIELDS)

# flags 位（与 nn_pkg.sv 一致）
F_DEPTHWISE = 0
F_LEAKY = 1
F_ADD = 2
F_UP2X = 3
F_POOLMAX = 4
F_PACKED3 = 5
F_ADD_R = 6

KIND_CODE = {
    'conv': 0, 'dwconv': 1, 'pool': 2, 'upsample': 3, 'add': 4, 'copy': 5,
    'cpu_conv0': 0, 'cpu_add': 4,
}
KNOWN_KINDS = set(KIND_CODE) | {'cpu_concat', 'cpu_copy'}


def fail(msg):
    print('[FAIL] ' + msg)
    raise SystemExit(1)


def abs_off(buf, off, a_off, b_off):
    if buf == 'A':
        return a_off + int(off)
    if buf == 'B':
        return b_off + int(off)
    fail('未知 buffer %r（只允许 A/B）' % buf)


def clamp(v, w, what):
    if v < 0:
        fail('%s 为负 (%d)' % (what, v))
    if v >= (1 << w):
        fail('%s=%d 超出 %d 位字段' % (what, v, w))
    return v


def op_flags(op, kind_code):
    """把 plan 的 flags 约定映射到 nn_pkg::NN_F_* 的位位置。

    plan.json (v0.6, T-model 生成) 的 flags 约定:
      bit0 = depthwise, bit1 = leaky, bit2 = PACKED3, bit3 = ADD_R
    nn_pkg 的位位置: depthwise=0, leaky=1, add=2, up2x=3, poolmax=4, packed3=5, add_r=6
    （两者**不是同一张表** —— 首版直接照搬 plan.flags 会让 ROM 的 PACKED3/ADD_R 丢失,
      引擎就会按普通 conv/add 跑，数值全错。这里显式映射并在文件头记下差异。）
    """
    pf = int(op.get('flags', 0) or 0)
    f = 0
    if op.get('kind') == 'dwconv' or (pf & 1) or op.get('depthwise'):
        f |= 1 << F_DEPTHWISE
    if (pf & 2) or op.get('leaky'):
        f |= 1 << F_LEAKY
    if (pf & 4) or op.get('packed3'):
        f |= 1 << F_PACKED3
    if (pf & 8) or (op.get('kind') == 'add' and ('r_scale' in op or 'R' in op)):
        f |= 1 << F_ADD_R
    if kind_code == 2:                       # pool
        f |= 1 << F_POOLMAX
    if kind_code == 3:                       # upsample (copy + UP2X)
        f |= 1 << F_UP2X
    if kind_code == 4 and not (f & (1 << F_ADD_R)):
        f |= (1 << F_ADD)                    # 纯 add（不带 R）时置 ADD 位
    return f


def build_entries(plan, a_off, b_off):
    """把 plan.op 展开成 ROM 项（只做结构转换，不改数值语义）。"""
    entries = []
    ops = plan['ops']
    for idx, op in enumerate(ops):
        k = op.get('kind')
        if k not in KNOWN_KINDS:
            fail('op#%d 未知 kind=%r' % (idx, k))
        if k in ('cpu_concat', 'cpu_copy'):
            # 展开成多个 copy（8 通道粒度）；最后一项带该 op 的 csum 供 debug 对照
            sources = op.get('sources', [])
            if not sources:
                fail('op#%d %s 缺少 sources' % (idx, k))
            oc_t = int(op.get('oc_tensor') or op.get('oc') or 0)
            if oc_t % 8:
                fail('op#%d concat 目标通道 %d 不是 8 的倍数' % (idx, oc_t))
            dst_base = abs_off(op['dst']['buf'], op['dst']['off'], a_off, b_off)
            ch = 0
            for si, s in enumerate(sources):
                sc = int(s['c'])
                if sc % 8:
                    fail('op#%d 源#%d 通道 %d 不是 8 的倍数（引擎 copy 限制）' % (idx, si, sc))
                src = abs_off(s['buf'], s['off'], a_off, b_off)
                e = dict(kind='copy', flags=0, ks=1, pad=0, stride=1,
                         ic=sc, oc=oc_t, ih=int(op.get('ih', 0)), iw=int(op.get('iw', 0)),
                         src=src, dst=dst_base + ch, woff=0, qoff=0, aux0=0, aux1=0,
                         csum=(int(op['csum']) & 0xFFFFFFFF) if si == len(sources) - 1 else 0)
                entries.append(e)
                ch += sc
            if ch != oc_t:
                fail('op#%d concat 源通道和 %d != oc_tensor %d' % (idx, ch, oc_t))
            continue

        kind_code = KIND_CODE[k]
        flags = op_flags(op, kind_code)
        ih = int(op.get('ih', 0))
        iw = int(op.get('iw', 0))
        ic = int(op.get('ic', 3 if k == 'cpu_conv0' else 0))
        oc = int(op.get('oc', 8 if k == 'cpu_conv0' else 0))
        woff = int(op.get('woff', -1))
        qoff = int(op.get('qoff', -1))
        if woff < 0:
            woff = 0                             # pool/copy/upsample/add 无权重
        if qoff < 0:
            # pool/copy/upsample 不需要 Q; conv/dw/add 必须有
            if kind_code in (2, 3, 5):           # pool / upsample / copy
                qoff = 0
            else:
                fail('op#%d kind=%s 缺 qoff（conv/dw/add 必须给 Q 区字节偏移）' % (idx, k))
        aux0 = aux1 = 0
        if kind_code == 4 and (flags & (1 << F_ADD_R)):
            R = int(op.get('r_scale', op.get('R', 0)))
            K = int(op.get('k_add', op.get('KADD', 0)))
            if not (0 < R <= 0xFFFF):
                fail('op#%d add R=%d 超出 16 位 (需 0<R≤65535)' % (idx, R))
            aux0, aux1 = R, K
        e = dict(kind=k, flags=flags, ks=int(op.get('k', 1) or 1),
                 pad=int(op.get('pad', 0) or 0), stride=int(op.get('stride', 1) or 1),
                 ic=ic, oc=oc, ih=ih, iw=iw,
                 src=abs_off(op['src']['buf'], op['src']['off'], a_off, b_off),
                 dst=abs_off(op['dst']['buf'], op['dst']['off'], a_off, b_off),
                 woff=woff, qoff=qoff, aux0=aux0, aux1=aux1,
                 csum=(int(op.get('csum', 0)) & 0xFFFFFFFF))
        entries.append(e)
    return entries


def pack(entry, code_kind):
    val = 0
    for name, width in NUM_FIELDS:
        if name == 'kind':
            v = code_kind
        elif name == 'rsvd':
            v = 0
        else:
            v = int(entry[name])
        val = (val << width) | clamp(v, width, name)
    return val


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--plan', required=True)
    ap.add_argument('-o', '--out', required=True, help='生成的 nn_rom_pkg.sv 路径')
    ap.add_argument('--table', default=None, help='同时输出可核对 JSON 表')
    args = ap.parse_args()

    plan = json.load(open(args.plan, encoding='utf-8'))
    a_off = read_pkg_int('NN_A_OFF')
    b_off = read_pkg_int('NN_B_OFF')
    depth_max = 128

    legacy = [op.get('kind') for op in plan['ops'] if str(op.get('kind', '')).startswith('cpu_')]
    if legacy:
        # 过渡期（plan 还是 v0.5 CPU 混合格式时）生成空 ROM，保证 RTL 可编译；
        # v0.6 全硬件 plan 到位后重新生成即可。MODE_AUTO 在空 ROM 下不做任何事。
        print('[WARN] plan 含 CPU kind %r -> 生成占位空 ROM（MODE_AUTO 不可用，等 v0.6 plan）'
              % sorted(set(legacy)))
        entries = []
    else:
        entries = build_entries(plan, a_off, b_off)
    if len(entries) > depth_max:
        fail('ROM 项数 %d > %d，需要加深 ROM（改 nn_pkg::NN_ROM_DEPTH）' % (len(entries), depth_max))

    lines = []
    lines.append('// ============================================================================')
    lines.append('// nn_rom_pkg.sv — 微码 ROM（**自动生成，请勿手改**）')
    lines.append('//   生成命令: python tools/nn_gen_rom.py --plan %s -o nn_rom_pkg.sv' %
                 args.plan.replace('\\', '/'))
    lines.append('//   源计划: %d 个 op 展开为 %d 条 ROM 项 (kind/fields 见 nn_pkg::nn_rom_t)' %
                 (len(plan['ops']), len(entries)))
    lines.append('// ============================================================================')
    lines.append('`timescale 1ns/1ps')
    lines.append('')
    lines.append('package nn_rom_pkg;')
    lines.append('  import nn_pkg::*;')
    lines.append('')
    lines.append('  localparam int unsigned NN_ROM_LEN = %d;' % len(entries))
    lines.append('')
    lines.append('  localparam nn_pkg::nn_rom_t NN_ROM [0:NN_ROM_DEPTH-1] = \'{')
    for i, e in enumerate(entries):
        code = KIND_CODE[e['kind']]
        val = pack(e, code)
        hexs = ('%0' + str((TOTAL_BITS + 3) // 4) + 'x') % val
        # 逗号规则: 只要不是整个数组的最后一个元素就必须有逗号
        # (首版按"最后一条真实项"判逗号, 有 padding 时漏逗号 -> vlog 语法错)
        need_comma = (i < depth_max - 1)
        lines.append("    %d'h%s%s   // %3d: %-8s flags=0x%02x ic=%d oc=%d ih=%d iw=%d" %
                     (TOTAL_BITS, hexs, ',' if need_comma else '', i, e['kind'],
                      e['flags'], e['ic'], e['oc'], e['ih'], e['iw']))
    # 未用项填 0（kind=0 但 flags 全 0 且 ic=0 → nn_seq 以 ic==0 判结束，或按 NN_ROM_LEN 控制）
    for i in range(len(entries), depth_max):
        lines.append("    %d'h0%s" % (TOTAL_BITS, ',' if i < depth_max - 1 else ''))
    lines.append('  };')
    lines.append('')
    lines.append('endpackage')
    lines.append('')

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
    open(out, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))
    print('[OK] nn_rom_pkg.sv: %d 条 ROM 项 -> %s' % (len(entries), out))

    if args.table:
        tbl = {'plan': os.path.basename(args.plan), 'num_ops': len(plan['ops']),
               'num_rom_entries': len(entries), 'total_bits': TOTAL_BITS,
               'fields': [n for n, _ in NUM_FIELDS], 'entries': entries}
        tout = os.path.abspath(args.table)
        os.makedirs(os.path.dirname(tout) or '.', exist_ok=True)
        json.dump(tbl, open(tout, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        print('[OK] table: %s' % tout)


if __name__ == '__main__':
    main()
