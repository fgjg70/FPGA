# -*- coding: utf-8 -*-
"""v3 周期公式 vs TB 实测逐 case 对照 (46 v2 语义 + 4 新 mode)。

用法: python calc_cycles_v3.py <tb_log> [manifest...]
默认读 v3_run_final.log (vec/) 和 v3_extra.log (vec_v3extra/)。
"""
import io
import os
import re
import sys

BASE = 8          # INIT 1 + VCHK 1 + CPREP 6
DRN = 3
NEXT = 2
QPER8 = 11        # 8-lane tile: S_Q(9, q_iss 0..q_tot+1) + QLOAD(2)
QLOAD = 2
REQP = 6          # requant 流水级数 (acc_sel..out 5 级 + 写起始偏 1)


def pad8(c):
    return ((c + 7) // 8) * 8


def q_tot(act):
    return act // 2 + act // 4 + 1


def q_cycles(act):
    return q_tot(act) + 4             # S_Q = q_tot+2 拍 (q 口打拍) + QLOAD 2


def req_cyc(act, oc8, dst16):
    if act == 16:
        beats = 8 if (oc8 % 16 == 0 and dst16) else 16
    else:
        beats = 8
    return REQP + beats + 2


def dims(o):
    k, st, pad = o['k'], o['st'], o['pad']
    if o['op'] == 1 and pad == 0:
        pad = (k - 1) // 2
    if o['op'] == 2:
        return o['ih'] * 2, o['iw'] * 2
    return (o['ih'] + 2 * pad - k) // st + 1, (o['iw'] + 2 * pad - k) // st + 1


def ceil8(x):
    return ((x + 7) // 8) * 8


def cycles_of(o):
    op = o['op']           # 0 conv,1 pool,2 copy,3 add
    dst16 = ((o.get('dst', 0) & 0xF) == 0)
    flags = o['flags']
    f_dw = (flags >> 0) & 1
    f_up2x = (flags >> 3) & 1
    f_p3 = (flags >> 5) & 1
    f_add_r = (flags >> 6) & 1
    k, st = o['k'], o['st']
    ic8, oc8 = ceil8(o['ic']), ceil8(o['oc'])
    ICB, OCB8 = ic8 // 8, oc8 // 8
    if op == 0 and not f_dw:
        ih, iw = o['ih'], o['iw']
        oh, ow = dims(o)
        NB = oh * ((ow + 7) // 8)
        if k == 1:
            count, wi, sub = 8, 0, ICB
        else:
            count, wi, sub = 7 * st + k, 1, k * ICB
        load = (3 * count + 1) if f_p3 else (count + 1)
        per = load + wi + 8 * k
        tot = BASE
        n_tiles = (oc8 + 15) // 16
        for t in range(n_tiles):
            act = min(16, oc8 - 16 * t)
            tot += q_cycles(act)
            tot += NB * (1 + sub * per + DRN + req_cyc(act, oc8, dst16) + NEXT)
        return tot
    if op == 0 and f_dw:
        oh, ow = dims(o)
        NB = oh * ((ow + 7) // 8)
        count = 7 * st + k
        per = count + 2 + k          # load(count+1) + WI 1 + MAC K
        tot = BASE
        for t in range(OCB8):
            tot += QPER8
            tot += NB * (1 + k * per + DRN + req_cyc(8, oc8, dst16) + NEXT)
        return tot
    if op == 1:
        oh, ow = dims(o)
        NB = ICB * oh * ((ow + 7) // 8)
        count = 7 * st + k
        per = count + 2 + k          # load + PMAX(K)
        return BASE + NB * (1 + k * per + 8 + NEXT)
    if op == 2:
        words = o['ih'] * o['iw'] * ICB
        return BASE + words * (5 if f_up2x else 2)
    # add
    words = o['ih'] * o['iw'] * ICB
    return BASE + (1 if f_add_r else 0) + words * 4


def parse_manifest(path):
    d = {}
    for ln in read_text_auto(path).splitlines():
        a = ln.split()
        if len(a) < 14 or a[0].startswith('#'):
            continue
        d[a[0]] = dict(op=int(a[1]), flags=int(a[2]), k=int(a[3]), st=int(a[4]),
                       pad=int(a[5]), ih=int(a[6]), iw=int(a[7]), ic=int(a[8]),
                       oc=int(a[9]), src=int(a[10]), dst=int(a[11]))
    return d


def read_text_auto(path):
    raw = io.open(path, "rb").read()
    if len(raw) >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
        return raw.decode("utf-16")
    if b"\x00" in raw[:200]:
        return raw.decode("utf-16-le", errors="ignore")
    return raw.decode("utf-8", errors="ignore")


def parse_log(path):
    rows = {}
    txt = read_text_auto(path)
    for m in re.finditer(r"CASE (\S+)\s+op=(\d).*?cyc=(\d+)", txt):
        rows[m.group(1)] = int(m.group(3))
    return rows


def main():
    logs = sys.argv[1:] or ["v3_run_final.log", "v3_extra.log"]
    man = {}
    man.update(parse_manifest("vec/manifest.txt"))
    if len(logs) > 1:
        man.update(parse_manifest("vec_v3extra/manifest.txt"))
    tot_meas = tot_theo = 0
    bad = 0
    for lg in logs:
        if not os.path.exists(lg):
            continue
        rows = parse_log(lg)
        for nm, cyc in rows.items():
            if nm not in man:
                continue
            th = cycles_of(man[nm])
            tot_meas += cyc
            tot_theo += th
            ok = "OK" if th == cyc else "MISMATCH(%+d)" % (th - cyc)
            if th != cyc:
                bad += 1
            print("%-22s meas=%6d theory=%6d %s" % (nm, cyc, th, ok))
    print("---- total: meas=%d theory=%d  bad=%d" % (tot_meas, tot_theo, bad))


if __name__ == "__main__":
    main()
