# -*- coding: utf-8 -*-
# 生成 engine-report.md 用的 46 行 markdown 表 (v2). 用法: python mk_table.py [log]
import re
import sys

LOG = sys.argv[1] if len(sys.argv) > 1 else "tb_v3_19.log"
raw = open(LOG, "rb").read()
txt = None
for enc in ("utf-16", "utf-8", "latin-1"):
    try:
        t = raw.decode(enc)
        if "CASE conv1x1_s1" in t:
            txt = t
            break
    except Exception:
        pass
if txt is None:
    raise SystemExit("log not parsed: " + LOG)

rows = []
for line in open("vec/manifest.txt", encoding="utf-8"):
    p = line.split()
    if len(p) != 14:
        continue
    name = p[0]
    op, fl, ks, st, pad, ih, iw, ic, oc, src, dst, woff, qoff = map(int, p[1:])
    rows.append(dict(name=name, op=op, flags=fl, ks=ks, st=st, pad=pad,
                     ih=ih, iw=iw, ic=ic, oc=oc))

meas = {}
for m in re.finditer(r"CASE (\S+)\s+op=(\d+).*?cyc=(\d+)\s+misA=(\d+)\s+misB=(\d+)", txt):
    meas[m.group(1)] = (int(m.group(3)), int(m.group(4)), int(m.group(5)))


def ceil8(x):
    return ((x + 7) // 8) * 8


def dims(c):
    k, st, pad = c['ks'], c['st'], c['pad']
    if c['op'] == 1 and pad == 0:
        pad = (k - 1) // 2
    if c['op'] == 2:
        return (c['ih'] * 2, c['iw'] * 2) if (c['flags'] & 8) else (c['ih'], c['iw'])
    return (c['ih'] + 2 * pad - k) // st + 1, (c['iw'] + 2 * pad - k) // st + 1


BASE = 8       # S_INIT 1 + S_VCHK 1 + S_CPREP 6
QPER = 10      # S_Q 8 + S_QLOAD 2
REQN = 13
DRN = 3
NEXT = 2


def theory(c):
    ic8 = ceil8(c['ic']); oc8 = ceil8(c['oc'])
    ICB = ic8 // 8; OCB = oc8 // 8
    k, st = c['ks'], c['st']
    oh, ow = dims(c)
    nb = oh * ((ow + 7) // 8)
    if c['op'] == 0:
        if c['flags'] & 1:
            count = 7 * st + k
            return BASE + OCB * QPER + OCB * nb * (1 + k * (count + 2 + k) + DRN + REQN + NEXT)
        count = 8 if k == 1 else 7 * st + k
        wi = 0 if k == 1 else 1
        sub = (1 if k == 1 else k) * ICB
        return BASE + OCB * QPER + OCB * nb * (1 + sub * ((count + 1) + wi + 8 * k) + DRN + REQN + NEXT)
    elif c['op'] == 1:
        count = 7 * st + k
        nb = ICB * oh * ((ow + 7) // 8)
        return BASE + nb * (1 + k * (count + 2 + k) + 8 + NEXT)
    elif c['op'] == 2:
        w = c['ih'] * c['iw'] * ICB
        return BASE + w * (5 if (c['flags'] & 8) else 2)
    return BASE + c['ih'] * c['iw'] * ICB * 3


NAMES = {0: 'conv/dw', 1: 'pool', 2: 'copy/up', 3: 'add'}
out = []
for c in rows:
    oh, ow = dims(c)
    me, ma, mb = meas[c['name']]
    th = theory(c)
    out.append("| %s | %s | %d/%d/%d | %dx%d | %dx%dx%d->%d | %d | %d | %d,%d |" % (
        c['name'], NAMES[c['op']], c['ks'], c['st'], c['pad'], c['ih'], c['iw'],
        oh, ow, c['ic'], c['oc'], me, th, ma, mb))
open("case_table.md", "w", encoding="utf-8").write("\n".join(out) + "\n")
bad = sum(1 for c in rows if theory(c) != meas[c['name']][0])
print("\n".join(out[:2]))
print("... rows=%d cyc_formula_mismatch=%d" % (len(out), bad))
