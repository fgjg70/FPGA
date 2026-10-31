# -*- coding: utf-8 -*-
# v2(T-accel-R2) 周期公式与实测对照. 用法: python calc_cycles.py [log]
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
QPER = 10      # 每个 OC tile: S_Q 8 + S_QLOAD 2
REQN = 13      # requant 5 级 + 写尾
DRN = 3        # MAC 4 级流水 drain
NEXT = 2       # S_NEXT + S_NEXT2


def theory(c):
    ic8 = ceil8(c['ic']); oc8 = ceil8(c['oc'])
    ICB = ic8 // 8; OCB = oc8 // 8
    k, st = c['ks'], c['st']
    oh, ow = dims(c)
    nb = oh * ((ow + 7) // 8)
    if c['op'] == 0:
        if c['flags'] & 1:                        # depthwise
            count = 7 * st + k
            per = count + 2 + k                  # LD + LDCAP + WI + K MAC
            return BASE + OCB * QPER + OCB * nb * (1 + k * per + DRN + REQN + NEXT)
        count = 8 if k == 1 else 7 * st + k
        wi = 0 if k == 1 else 1
        sub = (1 if k == 1 else k) * ICB
        per = (count + 1) + wi + 8 * k           # LD + LDCAP + WI + 8K MAC
        return BASE + OCB * QPER + OCB * nb * (1 + sub * per + DRN + REQN + NEXT)
    elif c['op'] == 1:                            # maxpool
        count = 7 * st + k
        nb = ICB * oh * ((ow + 7) // 8)
        return BASE + nb * (1 + k * (count + 2 + k) + 8 + NEXT)
    elif c['op'] == 2:                            # copy / 2x upsample
        w = c['ih'] * c['iw'] * ICB
        return BASE + w * (5 if (c['flags'] & 8) else 2)
    else:                                         # add
        return BASE + c['ih'] * c['iw'] * ICB * 3


tot_mis = 0
bad = 0
lines = []
for c in rows:
    th = theory(c)
    me, ma, mb = meas.get(c['name'], (-1, 0, 0))
    tot_mis += ma + mb
    ok = (th == me) and (ma == 0) and (mb == 0)
    bad += 0 if ok else 1
    lines.append("%-17s meas=%6d theory=%6d mis=%d,%d %s" % (
        c['name'], me, th, ma, mb, "OK" if ok else ("CYCFAIL" if th != me else "MISMATCH")))
print("\n".join(lines))
print("TOTAL cases=%d fail=%d tot_mismatch=%d" % (len(rows), bad, tot_mis))
open("cycle_table.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
