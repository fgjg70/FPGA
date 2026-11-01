# -*- coding: utf-8 -*-
"""分析 v3r (真 nn_mem) 的 46 case pass/fail 与 weight-offset 对齐的关系。"""
import io
import re

man = {}
for ln in io.open("vec/manifest.txt", encoding="utf-8"):
    a = ln.split()
    if len(a) < 14:
        continue
    man[a[0]] = dict(op=int(a[1]), flags=int(a[2]), k=int(a[3]), st=int(a[4]), pad=int(a[5]),
                     ih=int(a[6]), iw=int(a[7]), ic=int(a[8]), oc=int(a[9]),
                     src=int(a[10]), dst=int(a[11]), woff=int(a[12]), qoff=int(a[13]))

txt = io.open("v3r_run.log", "rb").read()
if b"\x00" in txt[:200]:
    txt = txt.decode("utf-16-le", errors="ignore")
else:
    txt = txt.decode("utf-8", errors="ignore")
res = {}
for m in re.finditer(r"CASE (\S+).*?misB=(\d+)", txt):
    res[m.group(1)] = int(m.group(2))

pad8 = lambda c: ((c + 7) // 8) * 8
print("%-20s %2s %2s %5s %5s %5s %4s %4s %s" % ("case", "op", "dw", "oc8%16", "woff%16", "flags", "misB", "PASS", "note"))
for nm, r in man.items():
    if nm not in res:
        continue
    oc8 = pad8(r["oc"])
    ic8 = pad8(r["ic"])
    dw = 1 if (r["op"] == 0 and (r["flags"] & 1)) else 0
    p3 = 1 if (r["flags"] & 0x20) else 0
    print("%-20s %2d %2d %5d %5d %5x %4d %4s p3=%d ic8=%d" % (
        nm, r["op"], dw, oc8 % 16, r["woff"] % 16, r["flags"], res[nm],
        "PASS" if res[nm] == 0 else "FAIL", p3, ic8))
