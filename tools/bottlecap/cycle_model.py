# -*- coding: utf-8 -*-
"""瓶盖模型 NPU 周期模型（P0 判据基线，RTL 参数化）。

输入: results/bottlecap/plan/plan.json（106 op 真实计划）
输出: 逐 op 四分量（A MAC / B 激活装载与地址 / C requant+写 / D 其它）+ 合计；
      --scenario 场景对照（p0/p1/p2/p2b/p2c/p3/p3narrow/p3c + 单方案 F/LB/DW/WG/M）；
      --json 机器可读；--self-check 断言默认参数精确复现 39,891,262 拍。

口径（必须与 engine-report v3 公式逐 op 相等）:
  results/ai-accel/proto/engine/calc_cycles_v3.py
  BASE=8, W_RD_LAT=2 => DRN=4, NEXT=2, QPER8=11, REQP=6

参数化假设（只在非基线配置生效；基线完全走 v3 原式）:
  * 阵列 = px_lanes x oc_lanes 个 8x8 乘，mac_width = 两者乘积
  * 每 (tap, ic8) 组 MAC 拍 = px*lane*8K / mac_width = 8K（不变式；基线 128 = 8x16）
  * 装载拍 = (count+1) + (px-8)//8*4（px=16 时每块多 4 拍取数）
  * REQ 拍：基线走 v3 原式；加宽后按物理字节 beats = max(8, ceil(px*act/16))
  * OC 加宽的真实收益受 OC tile padding 影响（例：oc=72 在 32 lane 下是 3 个 tile
    = 96 lane，基线 5 个 tile = 80 lane -> A 只到 0.6x 而非 0.5x）

作者: ddr3-feas (task-12)。只读 plan.json。
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys

BASE = 8
NEXT = 2
QPER8 = 11
REQP = 6
BASELINE_LEGACY = 39891262      # v3 formula WITHOUT PACKED3（task-11/12 的口径，Lead 已接受）
BASELINE_PACKED3 = 40051198     # v3 formula WITH PACKED3（plan flags bit2=4），由 --self-check 断言
BASELINE_CYCLES = BASELINE_LEGACY
FREQS = {"mhz100": 100e6, "mhz122_22": 122.22e6, "mhz150": 150e6}

SCENARIOS = {
    "p0": dict(),
    "f": dict(fusion=True),
    "lb": dict(bopt=0.7),
    "dw": dict(dwpath=True),
    "wg": dict(winograd="all"),
    "m_oc24": dict(mac_width=192, scheme="oc24"),
    "m_oc32": dict(mac_width=256, scheme="oc32"),
    "m_px16": dict(mac_width=256, scheme="px16"),
    "p1_rtl": dict(fusion=True),          # 仅融合（A4/A5e）
    "p1_a7a": dict(fusion=True, dwpath=True),   # 融合 + A7a 保守版（当前 RTL，2026-11-04）
    "p1": dict(fusion=True, bopt=0.7, dwpath=True),
    "p2": dict(fusion=True, bopt=0.7, dwpath=True, mac_width=256, scheme="oc32"),
    "p2b": dict(fusion=True, bopt=0.7, dwpath=True, mac_width=256, scheme="px16"),
    "p2c": dict(fusion=True, bopt=0.7, dwpath=True, mac_width=192, scheme="oc24"),
    "p3": dict(fusion=True, bopt=0.7, dwpath=True, mac_width=256,
               scheme="oc32", winograd="all"),
    "p3narrow": dict(fusion=True, bopt=0.7, dwpath=True, mac_width=256,
                     scheme="oc32", winograd="narrow"),
    "p3c": dict(fusion=True, bopt=0.7, dwpath=True, mac_width=192,
                scheme="oc24", winograd="narrow"),
}


def pad8(c):
    return ((c + 7) // 8) * 8


def ceil_div(a, b):
    return (a + b - 1) // b


def q_cycles(act):
    return act // 2 + act // 4 + 1 + 4


def req_cycles_v3(act, oc8, dst16):
    if act == 16:
        beats = 8 if (oc8 % 16 == 0 and dst16) else 16
    else:
        beats = 8
    return REQP + beats + 2


def req_cycles_gen(act, px):
    return REQP + max(8, ceil_div(px * act, 16)) + 2


def out_dims(o):
    k, st, p = o["k"], o["stride"], o["pad"]
    return (o["ih"] + 2 * p - k) // st + 1, (o["iw"] + 2 * p - k) // st + 1


def op_cycles(o, px=8, lane=16, mac_width=128, w_rd_lat=2, packed3=False):
    """返回 dict(cycles, A, B, C, D, ...)；基线 (8,16,128) 与 v3 逐 op 相等。"""
    drn = (w_rd_lat if w_rd_lat >= 2 else 1) + 2
    kind = o["kind"]
    if kind not in ("conv", "dwconv"):
        ic8 = pad8(o["ic"])
        words = o["ih"] * o["iw"] * (ic8 // 8)
        if kind in ("copy", "upsample"):
            cyc = BASE + words * (5 if kind == "upsample" else 2)
        else:
            cyc = BASE + 1 + words * 5
        return dict(cycles=cyc, A=0.0, B=0.0, C=0.0, D=cyc, macs=0,
                    detail=dict(kind=kind, cat="elemwise"))

    k, st = o["k"], o["stride"]
    ic8, oc8 = pad8(o["ic"]), pad8(o["oc"])
    ICB, OCB8 = ic8 // 8, oc8 // 8
    oh, ow = out_dims(o)
    dst16 = (o["dst"]["off"] & 0xF) == 0
    macs = (o["oc"] * o["ic"] * k * k * oh * ow if kind == "conv"
            else o["oc"] * k * k * oh * ow)
    baseline_cfg = (px, lane) == (8, 16)

    if kind == "conv":
        n_tiles = ceil_div(oc8, lane)
        pblocks = oh * ceil_div(ow, px)
        if k == 1:
            count, wi, sub = 8, 0, ICB
        else:
            count, wi, sub = 7 * st + k, 1, k * ICB
        mac_per_group = px * lane * 8 * k // mac_width
        extra_load = (px - 8) // 8 * 4
        load_cyc = (3 * count + 1) if packed3 else (count + 1)   # v3: PACKED3 口径
        A = B = Cc = Creq = D1 = 0.0
        E = BASE
        for t in range(n_tiles):
            act = min(lane, oc8 - lane * t)
            A += pblocks * sub * mac_per_group
            B += pblocks * sub * (load_cyc + extra_load)
            Cc += pblocks * sub * wi
            D1 += pblocks * (1 + drn + NEXT)
            Creq += (pblocks * req_cycles_v3(act, oc8, dst16) if baseline_cfg
                     else pblocks * req_cycles_gen(act, px))
            E += q_cycles(act)
        total = E + A + B + Cc + D1 + Creq
        return dict(cycles=total, A=A, B=B, C=Creq + Cc, D=D1 + E, macs=macs,
                    detail=dict(kind=kind, cat="dense", k=k, st=st, ic8=ic8,
                                oc8=oc8, ICB=ICB, n_tiles=n_tiles,
                                pblocks=pblocks, sub=sub, count=count,
                                mac_per_group=mac_per_group,
                                Cc=Cc, Creq=Creq, D1=D1, E=E, drn=drn,
                                packed3=packed3, load_cyc=load_cyc))

    pblocks = oh * ceil_div(ow, px)
    count = 7 * st + k
    A = B = Cc = Creq = D1 = 0.0
    E = BASE
    for t in range(OCB8):
        A += pblocks * k * k
        B += pblocks * k * count
        Cc += pblocks * 2 * k
        D1 += pblocks * (1 + drn + NEXT)
        Creq += (pblocks * req_cycles_v3(8, oc8, dst16) if baseline_cfg
                 else pblocks * req_cycles_gen(8, px))
        E += QPER8
    total = E + A + B + Cc + D1 + Creq
    return dict(cycles=total, A=A, B=B, C=Creq + Cc, D=D1 + E, macs=macs,
                detail=dict(kind=kind, cat="dw", k=k, st=st, oc8=oc8,
                            OCB8=OCB8, pblocks=pblocks, count=count,
                            Cc=Cc, Creq=Creq, D1=D1, E=E, drn=drn))


def find_narrow_ids(ops):
    return [o["id"] for o in ops
            if o["kind"] == "conv" and o["k"] == 3 and o["stride"] == 1
            and o["ic"] == 72 and o["oc"] == 72 and o["oh"] == 56 and o["ow"] == 56]


def decompose(ops, packed3_mode="auto", **kw):
    rows, macs = [], 0
    for o in ops:
        p3 = (packed3_mode == "auto") and bool(int(o.get("flags", 0)) & 4)
        r = op_cycles(o, packed3=p3, **kw)
        r.update(id=o["id"], kind=o["kind"], module=o.get("module", ""),
                 k=o.get("k", 0), ic=o.get("ic", 0), oc=o.get("oc", 0),
                 oh=o.get("oh", 0), ow=o.get("ow", 0))
        macs += r.pop("macs", 0)
        rows.append(r)
    return rows, macs


def totals(rows):
    return dict(cycles=sum(r["cycles"] for r in rows),
                A=sum(r["A"] for r in rows), B=sum(r["B"] for r in rows),
                C=sum(r["C"] for r in rows), D=sum(r["D"] for r in rows))


def fused_conv_ids(ops):
    """P1 融合映射：add(plan flags bit3=8, 即 NN_F_ADD_R/骨架残差) 的 dst 张量 == 某 conv 的 dst
    => 该 add 融进该 conv（不单独跑 add op）。copy(concat) 融进后继 conv 的 src 读。
    返回 (unique conv op id 列表, 被融合 conv 在 ops 里的下标集合)。"""
    ids, seen = [], set()
    for i, o in enumerate(ops):
        if o.get("kind") != "add" or not (int(o.get("flags", 0)) & 8):
            continue
        dst = o.get("dst", {})
        for j in range(i - 1, -1, -1):
            q = ops[j]
            if (q.get("kind") == "conv"
                    and q.get("dst", {}).get("buf") == dst.get("buf")
                    and q.get("dst", {}).get("off") == dst.get("off")):
                if j not in seen:
                    seen.add(j)
                    ids.append(q["id"])
                break
    return ids, seen


def apply_scenario(ops, fusion=False, bopt=None, dwpath=False, mac_width=128,
                   scheme="oc32", winograd="none", w_rd_lat=2, narrow_ids=(),
                   packed3_mode="auto"):
    notes = []
    if mac_width == 128:
        rows, macs = decompose(ops, px=8, lane=16, mac_width=128, w_rd_lat=w_rd_lat,
                               packed3_mode=packed3_mode)
    else:
        px, lane = (8, 32) if scheme == "oc32" else (8, 24) if scheme == "oc24" else (16, 16)
        if px * lane != mac_width:
            raise ValueError("mac_width must equal px*lane")
        rows, macs = decompose(ops, px=px, lane=lane, mac_width=mac_width,
                               w_rd_lat=w_rd_lat, packed3_mode=packed3_mode)
        notes.append("加宽: px=%d lane=%d mac_width=%d" % (px, lane, mac_width))

    if bopt:
        saved = 0.0
        for r in rows:
            if r["detail"].get("cat") == "dense":
                d = r["B"] * (1 - bopt)
                saved += d
                r["B"] -= d
                r["cycles"] = r["A"] + r["B"] + r["C"] + r["D"]
        notes.append("bopt=%.2f: 稠密 B 省 %.0f 拍" % (bopt, saved))

    if dwpath:
        # A7a 保守版实测口径（2026-11-04）：只有 ic==oc 且 %16==0 的 dw 层能 16-lane，
        #   OC tile 数减半 => 该层总周期 ≈ ×0.5（YOLO E2E 实测 141,931  vs 模型 142,765，差 0.6%）。
        #   其余 dw 层保持不变（旧 8-lane 路径）。A7b(行缓冲) 未实施，公式里不再假设。
        saved = 0.0
        for r in rows:
            if r["detail"].get("cat") == "dw":
                if r["ic"] == r["oc"] and r["oc"] % 16 == 0:
                    a0, b0, c0 = r["A"], r["B"], r["C"]
                    r["A"] = a0 / 2.0
                    r["B"] = b0 / 2.0
                    r["C"] = c0 / 2.0
                    new = r["A"] + r["B"] + r["C"] + r["D"]
                    saved += r["cycles"] - new
                    r["cycles"] = new
        notes.append("dwpath(A7a 保守版: 16-lane dw ×0.5): 省 %.0f 拍" % saved)

    if fusion:
        already_fused = any("fused_add" in o for o in ops)
        saved = 0.0
        if not already_fused:
            for r in rows:
                if r["detail"].get("cat") == "elemwise" and r["kind"] in ("add", "copy"):
                    saved += r["cycles"]
                    r["cycles"] = r["A"] = r["B"] = r["C"] = r["D"] = 0.0
        # A5e 实测口径：融合进 conv 的 add 使该 conv 每个输出块 +13 拍
        #   = S_ADRD 读 dst (wrbeats+2=10) + 写回延后 3 拍（三项流水）；1 个输出块 = 8 拍写
        #   （16 lane 单16B 模式；8-lane 尾块最多 +21）
        if already_fused:
            fidx = [j for j, o in enumerate(ops) if "fused_add" in o]
        else:
            _fids, fidx = fused_conv_ids(ops)
        fuse_cost = 0.0
        for j in fidx:
            r = rows[j]
            nb = r["detail"].get("pblocks", 0) * r["detail"].get("n_tiles", 1)
            add = 13.0 * nb
            r["D"] += add
            r["cycles"] += add
            fuse_cost += add
        notes.append("fusion%s: add+copy %.0f 拍 -> %d 个 conv、%.0f 拍融合代价(13 拍/块)"
                     % ("(已融合plan)" if already_fused else "", saved, len(fidx), fuse_cost))

    if winograd != "none":
        t_add = 0.25e6 if mac_width != 128 else 0.5e6
        if winograd == "all":
            picked = [r for r in rows if r["detail"].get("k") == 3
                      and r["detail"].get("cat") == "dense"]
        else:
            picked = [r for r in rows if r["id"] in set(narrow_ids)]
        a3 = sum(r["A"] for r in picked)
        per_op = t_add / max(1, len(picked))
        for r in picked:
            r["A"] = r["A"] / 2.25 + per_op
            r["cycles"] = r["A"] + r["B"] + r["C"] + r["D"]
        notes.append("winograd(%s): %d 层 A3=%.0f -> 净省 %.0f 拍"
                     % (winograd, len(picked), a3,
                        a3 - sum(r["A"] for r in picked) + t_add))

    return rows, totals(rows), macs, notes


def fps_of(cycles):
    return {k: round(v / cycles, 2) for k, v in FREQS.items()}


def main():
    ap = argparse.ArgumentParser(description="bottlecap NPU cycle model (P0)")
    ap.add_argument("--plan", default=None)
    ap.add_argument("--mac-width", type=int, default=128, choices=(128, 192, 256))
    ap.add_argument("--scheme", default="oc32", choices=("oc24", "oc32", "px16"))
    ap.add_argument("--w-rd-lat", type=int, default=2)
    ap.add_argument("--packed3", default="auto", choices=("auto", "off"),
                    help="auto=按 plan flags bit2(=4) 识别 PACKED3（v3 公式 load=3*count+1）；"
                         "off=不复现 PACKED3（task-11/12 的历史口径 39,891,262）")
    ap.add_argument("--bopt", type=float, default=None)
    ap.add_argument("--fusion", action="store_true")
    ap.add_argument("--dwpath", action="store_true")
    ap.add_argument("--winograd", default="none", choices=("none", "all", "narrow"))
    ap.add_argument("--scenario", default=None, choices=tuple(SCENARIOS) + ("all",))
    ap.add_argument("--json", default=None)
    ap.add_argument("--self-check", action="store_true")
    ap.add_argument("--top", type=int, default=10)
    args = ap.parse_args()

    plan_path = args.plan
    if plan_path is None:
        here = os.path.dirname(os.path.abspath(__file__))
        plan_path = os.path.abspath(os.path.join(
            here, "..", "..", "results", "bottlecap", "plan", "plan.json"))
    if not os.path.exists(plan_path):
        print("ERROR: plan.json not found: %s" % plan_path)
        return 2
    plan = json.load(io.open(plan_path, encoding="utf-8"))
    ops = plan["ops"]
    narrow_ids = find_narrow_ids(ops)

    rows, macs = decompose(ops, px=8, lane=16, mac_width=128,
                           w_rd_lat=args.w_rd_lat, packed3_mode=args.packed3)
    tot = totals(rows)
    total = tot["cycles"]

    if args.self_check:
        # 双基线：legacy=不复现 PACKED3（task-11/12 口径 39,891,262）；
        #         auto=复现 PACKED3（修正口径 40,051,198，与 YOLO 实测互证 -0.12%）
        exp = BASELINE_LEGACY if args.packed3 == "off" else BASELINE_PACKED3
        ok = abs(total - exp) < 0.5
        print("SELF-CHECK(packed3=%s): ops=%d cycles=%.0f expected=%d -> %s"
              % (args.packed3, len(ops), total, exp, "PASS" if ok else "FAIL"))
        print("  A=%.0f B=%.0f C=%.0f D=%.0f  sum=%.0f  narrow=%d  w_rd_lat=%d"
              % (tot["A"], tot["B"], tot["C"], tot["D"],
                 tot["A"] + tot["B"] + tot["C"] + tot["D"], len(narrow_ids),
                 args.w_rd_lat))
        return 0 if ok else 1

    payload = dict(
        plan=plan_path, ops=len(ops), macs=macs,
        baseline=dict(params=dict(px_lanes=8, oc_lanes=16, mac_width=128,
                                  w_rd_lat=args.w_rd_lat),
                      cycles=round(total, 1),
                      components=dict(A_mac=round(tot["A"], 1),
                                      B_load_addr=round(tot["B"], 1),
                                      C_requant_write=round(tot["C"], 1),
                                      D_other=round(tot["D"], 1)),
                      fps=fps_of(total),
                      effective_mac_per_cycle=round(macs / total, 1)),
        narrow_layer_ids=narrow_ids,
        per_op=[dict(id=r["id"], kind=r["kind"], module=r["module"],
                     cycles=round(r["cycles"], 1), A=round(r["A"], 1),
                     B=round(r["B"], 1), C=round(r["C"], 1), D=round(r["D"], 1))
                for r in rows],
    )

    if not args.scenario:
        print("== per-op cycles (top %d) ==" % args.top)
        for r in sorted(rows, key=lambda x: -x["cycles"])[:args.top]:
            print("  op%3d %-7s %-24s cyc=%9.0f A=%9.0f B=%9.0f C=%8.0f D=%8.0f"
                  % (r["id"], r["kind"], r["module"][:24], r["cycles"],
                     r["A"], r["B"], r["C"], r["D"]))
        print("\n== four components ==")
        for k in ("A", "B", "C", "D"):
            print("  %-4s %12.0f  (%5.1f%%)" % (k, tot[k], 100.0 * tot[k] / total))
        print("  %-4s %12.0f   (macs=%d)" % ("SUM", total, macs))
        print("  fps: @100=%.2f @122.22=%.2f @150=%.2f"
              % (100e6 / total, 122.22e6 / total, 150e6 / total))

    if args.scenario:
        keys = list(SCENARIOS) if args.scenario == "all" else [args.scenario]
        payload["scenarios"] = {}
        print("\n== scenarios ==")
        for key in keys:
            cfg = dict(SCENARIOS[key])
            _, t2, m2, notes = apply_scenario(ops, narrow_ids=narrow_ids,
                                              w_rd_lat=args.w_rd_lat,
                                              packed3_mode=args.packed3, **cfg)
            f = fps_of(t2["cycles"])
            payload["scenarios"][key] = dict(
                config={k: v for k, v in cfg.items()},
                cycles=round(t2["cycles"], 1),
                effective_mac_per_cycle=round(m2 / t2["cycles"], 1),
                fps=f)
            print("  %-9s cyc=%10.0f  effMAC=%6.1f  @100=%5.2f @122=%5.2f @150=%5.2f"
                  % (key, t2["cycles"], m2 / t2["cycles"], f["mhz100"],
                     f["mhz122_22"], f["mhz150"]))
            for n in notes:
                print("      - %s" % n)

    if args.json:
        with io.open(args.json, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1)
        print("wrote %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
