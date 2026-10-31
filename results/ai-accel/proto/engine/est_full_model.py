# -*- coding: utf-8 -*-
"""全模型 NPU 周期估算 (v2 引擎公式, 逐 op 套公式; 与 E2E 实测 npu_cycles 对齐)。

用法: python est_full_model.py [计划文件] [实测 npu_cycles]
输出: 控制台 + full_model_estimate.md

口径 (与 engine-report §0.5.6 的 v2 公式一致, 数字均为"引擎 cycles 寄存器"值):
  BASE = 8   (S_INIT 1 + S_VCHK 1 + S_CPREP 6)
  Q    = 10  (S_Q 8 + S_QLOAD 2, 每个 OC tile)
  DRN  = 3, REQ = 13, NEXT = 2
  conv:  BASE + OCB*Q + OCB*NB*(1 + sub*per + DRN+REQ+NEXT)
         per = (count+1) + wi + 8K, count = K==1?8:(7*ST+K), wi = K==1?0:1,
         sub = (K==1?1:K)*ICB
  dw:    BASE + OCB*Q + OCB*NB*(1 + K*(count+2+K) + DRN+REQ+NEXT)
  pool:  BASE + NB*(1 + K*(count+2+K) + 8 + NEXT), NB = ICB*OH*ceil(OW/8)
  upsample: BASE + IH*IW*ICB*5
  cpu_* (cpu_conv0/cpu_concat/cpu_add): 0 (CPU 执行, 不占 NPU)
"""
import json
import sys

PLAN = sys.argv[1] if len(sys.argv) > 1 else "../../../../sim/prog/yolo/plan.json"
MEAS = int(sys.argv[2]) if len(sys.argv) > 2 else 1290062

BASE = 8
Q = 10
DRN, REQ, NEXT = 3, 13, 2


def ceil8(x):
    return ((x + 7) // 8) * 8


def dims(o):
    k, st, pad = o['k'], o['stride'], o['pad']
    if o['kind'] == 'pool' and pad == 0:
        pad = (k - 1) // 2
    if o['kind'] == 'upsample':
        return o['ih'] * 2, o['iw'] * 2
    return (o['ih'] + 2 * pad - k) // st + 1, (o['iw'] + 2 * pad - k) // st + 1


def per_op_v2(o):
    kind = o['kind']
    if kind in ('cpu_conv0', 'cpu_concat', 'cpu_add', 'cpu_copy'):
        return 0
    ic8, oc8 = ceil8(o['ic']), ceil8(o['oc'])
    ICB, OCB = ic8 // 8, oc8 // 8
    k, st = o['k'], o['stride']
    oh, ow = dims(o)
    nb = oh * ((ow + 7) // 8)
    if kind == 'conv':
        count = 8 if k == 1 else 7 * st + k
        wi = 0 if k == 1 else 1
        sub = (1 if k == 1 else k) * ICB
        per = (count + 1) + wi + 8 * k
        return BASE + OCB * Q + OCB * nb * (1 + sub * per + DRN + REQ + NEXT)
    if kind == 'dwconv':
        count = 7 * st + k
        return BASE + OCB * Q + OCB * nb * (1 + k * (count + 2 + k) + DRN + REQ + NEXT)
    if kind == 'pool':
        count = 7 * st + k
        nb = ICB * oh * ((ow + 7) // 8)
        return BASE + nb * (1 + k * (count + 2 + k) + 8 + NEXT)
    if kind == 'upsample':
        return BASE + o['ih'] * o['iw'] * ICB * 5
    raise SystemExit('unknown kind ' + kind)


def per_op_v1(o):
    """v1 公式 (R1 交付), 只用于对比"v2 流水化代价"。"""
    kind = o['kind']
    if kind in ('cpu_conv0', 'cpu_concat', 'cpu_add', 'cpu_copy'):
        return 0
    ic8, oc8 = ceil8(o['ic']), ceil8(o['oc'])
    ICB, OCB = ic8 // 8, oc8 // 8
    k, st = o['k'], o['stride']
    oh, ow = dims(o)
    nb = oh * ((ow + 7) // 8)
    if kind == 'conv':
        count = 8 if k == 1 else 7 * st + k
        wi = 0 if k == 1 else 1
        sub = (1 if k == 1 else k) * ICB
        return 1 + OCB * 9 + OCB * nb * (1 + sub * ((count + 1) + wi + 8 * k) + 2 + 9 + 1)
    if kind == 'dwconv':
        count = 7 * st + k
        return 1 + OCB * 9 + OCB * nb * (1 + k * (count + 2 + k) + 2 + 9 + 1)
    if kind == 'pool':
        count = 7 * st + k
        nb = ICB * oh * ((ow + 7) // 8)
        return 1 + nb * (1 + k * (count + 2 + k) + 8 + 1)
    if kind == 'upsample':
        return 1 + o['ih'] * o['iw'] * ICB * 5
    raise SystemExit('unknown kind ' + kind)


plan = json.load(open(PLAN, encoding='utf-8'))
rows = []
sums = {}
for o in plan['ops']:
    v2 = per_op_v2(o)
    v1 = per_op_v1(o)
    rows.append((o['id'], o['kind'], o['k'], o['stride'], o['pad'],
                 o['ih'], o['iw'], o['ic'], o['oc'], v2, v1, v2 - v1))
    sums.setdefault(o['kind'], [0, 0, 0])
    sums[o['kind']][0] += 1
    sums[o['kind']][1] += v2
    sums[o['kind']][2] += v1

tot2 = sum(r[9] for r in rows)
tot1 = sum(r[10] for r in rows)
diff = tot2 - MEAS

lines = []
lines.append("# 全模型 NPU 周期估算（v2 公式逐 op 求和）\n")
lines.append("> 由 `proto/engine/est_full_model.py` 生成；计划 `sim/prog/yolo/plan.json`（%d ops），"
             "实测 `npu_cycles=%d`（Lead `tb_sw_nn_yolo` HW-only, 2026-11-01）。\n" % (len(plan['ops']), MEAS))
lines.append("| kind | ops | v2 cycles | v1 cycles | v2-v1 |")
lines.append("|---|---|---|---|---|")
for kind in ('conv', 'dwconv', 'pool', 'upsample', 'cpu_conv0', 'cpu_concat', 'cpu_add'):
    if kind in sums:
        n, s2, s1 = sums[kind]
        lines.append("| %s | %d | %d | %d | %d |" % (kind, n, s2, s1, s2 - s1))
lines.append("| **HW 合计** | **%d** | **%d** | **%d** | **%d** |" % (
    sum(1 for r in rows if r[1] not in ('cpu_conv0', 'cpu_concat', 'cpu_add')), tot2, tot1, tot2 - tot1))
lines.append("")
lines.append("- **v2 估算 = %d 拍**；实测 = **%d 拍**；差 **%+d 拍（%+.2f%%）**" % (
    tot2, MEAS, diff, 100.0 * diff / MEAS))
lines.append("- @150MHz（E2E 实测主频）= %.3f ms/帧（实测值）" % (MEAS / 150e6 * 1000))
lines.append("- v2 比 v1 慢 %d 拍 (+%.1f%%) —— 流水化代价" % (tot2 - tot1, 100.0 * (tot2 - tot1) / tot1))
lines.append("")
lines.append("## v1→v2 差异说明（与上一版报告 1,320,062 的 30,000 拍差从哪来）")
lines.append("")
lines.append("上一版估算 = v1 估算(1,216,578, 旧 plan 108 op/105 HW) + v2 流水化增量(103,484) = 1,320,062。")
lines.append("**错在基准 plan 过期**：新 plan（T-model 精度修复后）把 18 个 shortcut-add 改成 `cpu_add`（CPU 执行），"
             "NPU 不再跑；旧 v1 估算里这 18 个 HW add 的周期（约 %d 拍）被当成 NPU 周期带进基准，"
             "而 v2 增量又按105 个 HW op加了一遍 +7/op 等，于是多算。" % sum(
                 per_op_v1(o) for o in plan['ops'] if o['kind'] == 'cpu_add'))
lines.append("")
lines.append("**正确口径**：逐 op 套 v2 公式（本文件脚本），只计真正跑 NPU 的 op："
             "conv 55 + dwconv 28 + pool 3 + upsample 1 = **87 个 HW op**；"
             "`cpu_conv0/cpu_concat/cpu_add` 均不计。")
lines.append("")
lines.append("## 逐 op 明细")
lines.append("")
lines.append("| id | kind | k/st/pad | IHxIW | IC->OC | v2 cyc | v1 cyc | delta |")
lines.append("|---|---|---|---|---|---|---|---|")
for r in rows:
    lines.append("| %d | %s | %d/%d/%d | %dx%d | %d->%d | %d | %d | %+d |" % (
        r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11]))

out = "\n".join(lines) + "\n"
open("full_model_estimate.md", "w", encoding="utf-8").write(out)
print("\n".join(lines[:16]))
print("...\nTOTAL v2=%d measured=%d diff=%+d (%.2f%%)" % (tot2, MEAS, diff, 100.0 * diff / MEAS))
