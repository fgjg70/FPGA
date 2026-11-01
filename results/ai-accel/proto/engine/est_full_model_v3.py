# -*- coding: utf-8 -*-
"""v3 全模型周期估算 (当前 112-op plan) + 与 v2 引擎口径对比。"""
import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from calc_cycles_v3 import cycles_of, BASE  # noqa: E402

PLAN = "../../../../sim/prog/yolo/plan.json"
NN_A_OFF = 0x60000
NN_B_OFF = 0x78000


def dst_abs(o):
    d = o.get("dst")
    if isinstance(d, dict):
        return (NN_A_OFF if d.get("buf") == "A" else NN_B_OFF) + d.get("off", 0)
    return 0
plan = json.load(open(PLAN, encoding="utf-8"))
ops = plan["ops"] if isinstance(plan, dict) else plan


def to_engine_op(o):
    kind = o["kind"]
    dabs = dst_abs(o)
    ret = _to_engine_op(o)
    ret["dst"] = dabs
    return ret


def _to_engine_op(o):
    kind = o["kind"]
    k = max(1, o["k"])
    if kind == "conv":
        f = 0x20 if o["ic"] == 3 else 0
        return dict(op=0, flags=f, k=k, st=o["stride"], pad=o["pad"],
                    ih=o["ih"], iw=o["iw"], ic=o["ic"], oc=o["oc"])
    if kind == "dwconv":
        return dict(op=0, flags=1, k=k, st=o["stride"], pad=o["pad"],
                    ih=o["ih"], iw=o["iw"], ic=o["ic"], oc=o["oc"])
    if kind == "pool":
        return dict(op=1, flags=0, k=k, st=o["stride"], pad=o["pad"],
                    ih=o["ih"], iw=o["iw"], ic=o["ic"], oc=o["oc"])
    if kind in ("copy", "upsample"):
        return dict(op=2, flags=(8 if kind == "upsample" else 0), k=0, st=1, pad=0,
                    ih=o["ih"], iw=o["iw"], ic=o["ic"], oc=o["oc"])
    if kind == "add":
        return dict(op=3, flags=0x40, k=0, st=1, pad=0,
                    ih=o["ih"], iw=o["iw"], ic=o["ic"], oc=o["oc"])
    raise SystemExit("bad kind " + kind)


# v2 口径 (对照): 64 MAC, OC8 tile, Q 10/tile, REQ=13, 无 PACKED3/ADD_R
def pad8(c):
    return ((c + 7) // 8) * 8


def dims_v2(o):
    k, st, pad = o["k"], o["stride"], o["pad"]
    if o["kind"] == "pool" and pad == 0:
        pad = (k - 1) // 2
    if o["kind"] == "upsample":
        return o["ih"] * 2, o["iw"] * 2
    return (o["ih"] + 2 * pad - k) // st + 1, (o["iw"] + 2 * pad - k) // st + 1


def cycles_v2(o):
    kind = o["kind"]
    ic8, oc8 = pad8(o["ic"]), pad8(o["oc"])
    ICB, OCB = ic8 // 8, oc8 // 8
    k, st = max(1, o["k"]), o["stride"]
    if kind in ("conv", "dwconv"):
        oh, ow = dims_v2(o)
        NB = oh * ((ow + 7) // 8)
        if kind == "conv":
            count, wi, sub = (8, 0, ICB) if k == 1 else (7 * st + k, 1, k * ICB)
        else:
            count, wi, sub = 7 * st + k, 1, 1
        per = (count + 1) + wi + 8 * k
        blk = 1 + sub * per + 3 + 13 + 2
        if kind == "dw":
            blk = 1 + k * (count + 2 + k) + 3 + 13 + 2
        return 8 + OCB * 10 + OCB * NB * blk
    if kind == "pool":
        oh, ow = dims_v2(o)
        NB = ICB * oh * ((ow + 7) // 8)
        return 8 + NB * (1 + k * (count_pool := (7 * st + k) + 2 + k) + 8 + 2)
    if kind == "copy":
        words = o["ih"] * o["iw"] * ICB
        return 8 + words * 2
    if kind == "upsample":
        words = o["ih"] * o["iw"] * ICB
        return 8 + words * 5
    if kind == "add":
        words = o["ih"] * o["iw"] * ICB
        return 8 + words * 3
    raise SystemExit(kind)


rows = []
tot3 = tot2 = 0
for o in ops:
    eo = to_engine_op(o)
    c3 = cycles_of(eo)
    c2 = cycles_v2(o)
    tot3 += c3
    tot2 += c2
    rows.append((o["id"], o["kind"], o["k"], o["stride"], o["pad"], o["ih"], o["iw"],
                 o["ic"], o["oc"], c3, c2))

print("v3 estimate (current plan, %d ops): %d cycles" % (len(rows), tot3))
print("v2 equivalent on same plan        : %d cycles" % tot2)
print("speedup                           : %.3fx" % (tot2 / tot3))
for clk in (100.0, 95.45, 87.5):
    print("  @%6.2f MHz: %.3f ms/frame (%.1f fps)" % (clk, tot3 / (clk * 1e6) * 1e3, clk * 1e6 / tot3))

# 与已实测 E2E 的旧 plan 对比: 旧 plan (87 HW op) v2 实测 1,290,062
per = {}
for r in rows:
    per.setdefault(r[1], [0, 0, 0])
    per[r[1]][0] += 1
    per[r[1]][1] += r[9]
    per[r[1]][2] += r[10]
with io.open("full_model_estimate_v3.md", "w", encoding="utf-8") as f:
    f.write("# 全模型 NPU 周期估算（v3 引擎，当前 112-op plan）\n\n")
    f.write("> 由 `proto/engine/est_full_model_v3.py` 生成；引擎 v3 = 128 MAC/拍（16 OC lane × 8 px）。\n\n")
    f.write("| kind | ops | v3 cycles | v2 cycles | v3-v2 |\n|---|---|---|---|---|\n")
    for kind in ("conv", "dwconv", "pool", "copy", "upsample", "add"):
        if kind in per:
            n, a, b = per[kind]
            f.write("| %s | %d | %d | %d | %d |\n" % (kind, n, a, b, a - b))
    f.write("| **合计** | **%d** | **%d** | **%d** | **%d** |\n\n" % (len(rows), tot3, tot2, tot3 - tot2))
    f.write("- **v3 估算 = %d 拍**；@100MHz = **%.3f ms/帧（%.1f fps）**\n" % (
        tot3, tot3 / 1e8 * 1e3, 1e8 / tot3))
    f.write("- v2 引擎口径同 plan = %d 拍（v3 快 %.2fx）\n" % (tot2, tot2 / tot3))
    f.write("\n## 逐 op\n\n| id | kind | k/st/pad | IHxIW | IC->OC | v3 cyc | v2 cyc |\n|---|---|---|---|---|---|---|\n")
    for r in rows:
        f.write("| %d | %s | %d/%d/%d | %dx%d | %d->%d | %d | %d |\n" % r)
print("wrote full_model_estimate_v3.md")
