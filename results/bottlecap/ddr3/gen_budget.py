# -*- coding: utf-8 -*-
"""瓶盖检测模型（EnhancedNutAnchorFree: MobileNetV2-0.55 + FPN72 + anchor-free 解耦头）
逐 op 画像 / NPU 周期 / DDR3-QSPI 带宽与预取预算 / band-outer tile 与 arena 预算。

只读 tools/bottlecap/model_src；只写本目录。
输出: bandwidth_budget.json / layers_224.csv

用法: python results/bottlecap/ddr3/gen_budget.py [--sizes 56,64,96,112,128,160,192,224]
依赖: torch（仅用于取算子序列与形状）；MAC/字节/周期为纯整数运算。
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys


def _repo_root() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", "..", ".."))


ROOT = _repo_root()
sys.path.insert(0, os.path.join(ROOT, "tools", "bottlecap", "model_src"))

import torch
import torch.nn as nn
from torch.fx import symbolic_trace
from torch.fx.passes.shape_prop import ShapeProp

from nut_detector.enhanced_anchor_free import EnhancedNutAnchorFree

BASE = 8
W_RD_LAT = 2
DRN = W_RD_LAT + 2
NEXT = 2
QPER8 = 11
REQP = 6

DDR3_THEORY_MBPS = 1600.0
DDR3_USABLE_MBPS = 1120.0
QSPI_X4_50MHZ_MBPS = 25.0
QSPI_USABLE_MBPS = 20.0
BRAM_TILES_TOTAL = 135
BRAM_BYTES_PER_TILE = 4096
CH_LIMIT = 248
NPU_MAC_PER_CYCLE = 128
CLK_HZ = 100e6
CLK_HZ_MAX = 122.22e6


def pad8(c):
    return ((c + 7) // 8) * 8


def q_cycles(act):
    return act // 2 + act // 4 + 1 + 4


def req_cyc(act, oc8, dst16):
    if act == 16:
        beats = 8 if (oc8 % 16 == 0 and dst16) else 16
    else:
        beats = 8
    return REQP + beats + 2


def _dims(o):
    k, st, p = o["k"], o["st"], o["pad"]
    if o["op"] == 1 and p == 0:
        p = (k - 1) // 2
    if o["op"] == 2:
        return o["ih"] * 2, o["iw"] * 2
    return (o["ih"] + 2 * p - k) // st + 1, (o["iw"] + 2 * p - k) // st + 1


def cycles_of(o):
    op, f = o["op"], o["flags"]
    dst16 = (o.get("dst", 0) & 0xF) == 0
    f_dw, f_up2x = (f >> 0) & 1, (f >> 3) & 1
    f_p3, f_add_r = (f >> 5) & 1, (f >> 6) & 1
    k, st = o["k"], o["st"]
    ic8, oc8 = pad8(o["ic"]), pad8(o["oc"])
    ICB, OCB8 = ic8 // 8, oc8 // 8
    if op == 0 and not f_dw:
        oh, ow = _dims(o)
        NB = oh * ((ow + 7) // 8)
        count, wi, sub = (8, 0, ICB) if k == 1 else (7 * st + k, 1, k * ICB)
        load = (3 * count + 1) if f_p3 else (count + 1)
        per = load + wi + 8 * k
        tot = BASE
        n_tiles = (oc8 + 15) // 16
        for t in range(n_tiles):
            act = min(16, oc8 - 16 * t)
            tot += q_cycles(act)
            tot += NB * (1 + sub * per + DRN + req_cyc(act, oc8, dst16) + NEXT)
        return dict(cycles=tot, blocks=NB * n_tiles, n_tiles=n_tiles, NB=NB)
    if op == 0 and f_dw:
        oh, ow = _dims(o)
        NB = oh * ((ow + 7) // 8)
        count = 7 * st + k
        per = count + 2 + k
        tot = BASE
        for t in range(OCB8):
            tot += QPER8
            tot += NB * (1 + k * per + DRN + req_cyc(8, oc8, dst16) + NEXT)
        return dict(cycles=tot, blocks=NB * OCB8, n_tiles=OCB8, NB=NB)
    if op == 1:
        oh, ow = _dims(o)
        NB = ICB * oh * ((ow + 7) // 8)
        count = 7 * st + k
        return dict(cycles=BASE + NB * (1 + k * (count + 2 + k) + 8 + NEXT),
                    blocks=NB, n_tiles=1, NB=NB)
    if op == 2:
        words = o["ih"] * o["iw"] * ICB
        return dict(cycles=BASE + words * (5 if f_up2x else 2), blocks=words, n_tiles=1, NB=words)
    words = o["ih"] * o["iw"] * ICB
    return dict(cycles=BASE + (1 if f_add_r else 0) + words * 5, blocks=words, n_tiles=1, NB=words)


def build_model(num_classes=4, fpn_channels=72, backbone_width=0.55):
    return EnhancedNutAnchorFree(num_classes=num_classes, fpn_channels=fpn_channels,
                                 backbone_width=backbone_width).eval()


def trace_ops(model, hw):
    x = torch.randn(1, 3, hw, hw)
    gm = symbolic_trace(model)
    ShapeProp(gm).propagate(x)
    mods = dict(gm.named_modules())
    nodes = list(gm.graph.nodes)
    owner = {}

    deps = {}
    for n in gm.graph.nodes:
        srcs = set()

        def walk(a):
            if hasattr(a, "op") and hasattr(a, "name"):
                srcs.add(a.name)
            elif isinstance(a, (list, tuple)):
                for y in a:
                    walk(y)
        walk(n.args)
        deps[n.name] = srcs

    def osh(n):
        t = n.meta.get("tensor_meta")
        return tuple(t.shape) if t is not None else None

    ops, pending = [], []

    def flush():
        if pending:
            ops.append(dict(pending[0]))
            pending.clear()

    def add_op(n, **kw):
        ops.append(dict(name=n.name, ins=sorted(deps[n.name]), **kw))
        owner[n.name] = ops[-1]["name"]

    for n in nodes:
        if n.op == "call_module":
            m = mods[n.target]
            if isinstance(m, nn.Conv2d):
                flush()
                is_, os_ = osh(n.args[0]), osh(n)
                kind = "dwconv" if (m.groups == m.in_channels and m.groups > 1) else "conv"
                pending.append(dict(name=n.name, kind=kind, k=m.kernel_size[0],
                                    stride=m.stride[0], pad=m.padding[0], groups=m.groups,
                                    ic=int(is_[1]), oc=int(os_[1]),
                                    ih=int(is_[2]), iw=int(is_[3]),
                                    oh=int(os_[2]), ow=int(os_[3]), act="linear",
                                    ins=sorted(deps[n.name])))
                owner[n.name] = pending[0]["name"]
            elif isinstance(m, (nn.BatchNorm2d, nn.Sequential)):
                if pending:
                    owner[n.name] = pending[0]["name"]
            elif isinstance(m, nn.ReLU):
                if pending:
                    pending[0]["act"] = "relu"
                    owner[n.name] = pending[0]["name"]
            else:
                flush()
        elif n.op == "call_function":
            fn = str(n.target)
            if "interpolate" in fn:
                flush()
                is_, os_ = osh(n.args[0]), osh(n)
                add_op(n, kind="upsample", k=2, stride=2, pad=0, groups=1,
                       ic=int(is_[1]), oc=int(is_[1]), ih=int(is_[2]), iw=int(is_[3]),
                       oh=int(os_[2]), ow=int(os_[3]), act="linear")
            elif "cat" in fn.lower():
                flush()
                os_ = osh(n)
                add_op(n, kind="concat", k=0, stride=1, pad=0, groups=1,
                       ic=int(os_[1]), oc=int(os_[1]), ih=int(os_[2]), iw=int(os_[3]),
                       oh=int(os_[2]), ow=int(os_[3]), act="linear")
            elif "add" in fn.lower():
                flush()
                os_ = osh(n)
                add_op(n, kind="add", k=0, stride=1, pad=0, groups=1,
                       ic=int(os_[1]), oc=int(os_[1]), ih=int(os_[2]), iw=int(os_[3]),
                       oh=int(os_[2]), ow=int(os_[3]), act="linear")
            elif "relu" in fn.lower():
                if pending:
                    pending[0]["act"] = "relu"
                elif ops and ops[-1]["kind"] == "add":
                    ops[-1]["act"] = "relu"
                    owner[n.name] = ops[-1]["name"]
        elif n.op == "placeholder":
            owner[n.name] = "input"
    flush()
    return ops, owner


def conv_w_bytes(kind, k, ic, oc):
    return pad8(oc) * k * k if kind == "dwconv" else pad8(oc) * pad8(ic) * k * k


def q_bytes(oc):
    return 6 * pad8(oc) + 16


def act_bytes(h, w, c):
    return h * w * pad8(c)


def macs_of(op):
    if op["kind"] in ("conv", "dwconv"):
        return op["oc"] * op["ic"] * op["k"] * op["k"] // op["groups"] * op["oh"] * op["ow"]
    if op["kind"] in ("add", "upsample"):
        return op["oh"] * op["ow"] * op["ic"]
    return 0


def band_bytes(op, B):
    ih_b = (B - 1) * op["stride"] + op["k"]
    bands = op["oh"] // B + (1 if op["oh"] % B else 0)
    last = op["oh"] % B or B
    in_last = (last - 1) * op["stride"] + op["k"]
    in_total = ((bands - 1) * ih_b * op["iw"] * pad8(op["ic"])
                + in_last * op["iw"] * pad8(op["ic"]))
    return dict(bands=bands, in_bytes=in_total,
                out_bytes=op["oh"] * op["ow"] * pad8(op["oc"]),
                in_band_max=ih_b * op["iw"] * pad8(op["ic"]),
                out_band_max=B * op["ow"] * pad8(op["oc"]))


def ew_band(op, B):
    bands = op["oh"] // B + (1 if op["oh"] % B else 0)
    r = min(B, op["oh"])
    return dict(bands=bands, in_bytes=op["oh"] * op["ow"] * pad8(op["ic"]),
                out_bytes=op["oh"] * op["ow"] * pad8(op["oc"]),
                in_band_max=r * op["ow"] * pad8(op["ic"]),
                out_band_max=r * op["ow"] * pad8(op["oc"]))


def to_npu_ops(ops):
    out, oid = [], 0
    for idx, op in enumerate(ops):
        kind = op["kind"]
        if kind in ("conv", "dwconv"):
            oc8, ic8 = pad8(op["oc"]), pad8(op["ic"])
            n_tile = 1 if kind == "dwconv" else (oc8 + 15) // 16
            w_b = conv_w_bytes(kind, op["k"], op["ic"], op["oc"])
            w_tile = (8 * op["k"] * op["k"]) if kind == "dwconv" else (16 * ic8 * op["k"] * op["k"])
            flags = (0x01 if kind == "dwconv" else 0) | (0x02 if op["act"] == "relu" else 0)
            e = cycles_of(dict(op=0, flags=flags, k=op["k"], st=op["stride"], pad=op["pad"],
                               ih=op["ih"], iw=op["iw"], ic=op["ic"], oc=op["oc"],
                               src=0, dst=0))
            n_is = max(1, (ic8 + CH_LIMIT - 1) // CH_LIMIT)
            n_os = max(1, (oc8 + CH_LIMIT - 1) // CH_LIMIT)
            rec = dict(id=oid, kind=kind, name=op["name"], k=op["k"], stride=op["stride"],
                       pad=op["pad"], ic=op["ic"], oc=op["oc"], ic_pad=ic8, oc_pad=oc8,
                       ih=op["ih"], iw=op["iw"], oh=op["oh"], ow=op["ow"], act=op["act"],
                       macs=macs_of(op), w_bytes=w_b, q_bytes=q_bytes(op["oc"]),
                       in_bytes=op["ih"] * op["iw"] * (3 if idx == 0 else ic8),
                       out_bytes=act_bytes(op["oh"], op["ow"], op["oc"]),
                       cycles=e["cycles"], blocks=e["blocks"], n_oc_tile=n_tile,
                       w_tile_bytes=w_tile, n_ic_split=n_is, n_oc_split=n_os,
                       n_split_ops=n_is * n_os, ins=list(op.get('ins', [])),
                       prefetch_B_per_cyc=round(w_tile / max(1.0, e["cycles"] / n_tile), 4))
            for B in (1, 2, 4, 8):
                rec["band_B%d" % B] = band_bytes(op, B)
            out.append(rec)
            oid += 1
        elif kind == "add":
            words = op["oh"] * op["ow"] * (pad8(op["ic"]) // 8)
            b = act_bytes(op["oh"], op["ow"], op["ic"])
            e = cycles_of(dict(op=3, flags=0x40, k=0, st=1, pad=0, ih=op["ih"], iw=op["iw"],
                               ic=op["ic"], oc=op["oc"], src=0, dst=0))
            rec = dict(id=oid, kind="add", name=op["name"], k=0, stride=1, pad=0,
                       ic=op["ic"], oc=op["ic"], ic_pad=pad8(op["ic"]), oc_pad=pad8(op["ic"]),
                       ih=op["ih"], iw=op["iw"], oh=op["oh"], ow=op["ow"], act=op["act"],
                       macs=words * 8, w_bytes=0, q_bytes=16, in_bytes=2 * b, out_bytes=b,
                       cycles=e["cycles"], blocks=words, n_oc_tile=1, w_tile_bytes=0,
                       prefetch_B_per_cyc=0.0, n_ic_split=1, n_oc_split=1, n_split_ops=1,
                       ins=list(op.get('ins', [])))
            for B in (1, 2, 4, 8):
                rec["band_B%d" % B] = ew_band(op, B)
            out.append(rec)
            oid += 1
        elif kind == "upsample":
            e = cycles_of(dict(op=2, flags=0x08, k=0, st=1, pad=0, ih=op["ih"], iw=op["iw"],
                               ic=op["ic"], oc=op["oc"], src=0, dst=0))
            rec = dict(id=oid, kind="upsample", name=op["name"], k=0, stride=2, pad=0,
                       ic=op["ic"], oc=op["ic"], ic_pad=pad8(op["ic"]), oc_pad=pad8(op["ic"]),
                       ih=op["ih"], iw=op["iw"], oh=op["oh"], ow=op["ow"], act="linear",
                       macs=0, w_bytes=0, q_bytes=0,
                       in_bytes=act_bytes(op["ih"], op["iw"], op["ic"]),
                       out_bytes=act_bytes(op["oh"], op["ow"], op["oc"]),
                       cycles=e["cycles"], blocks=e["blocks"], n_oc_tile=1, w_tile_bytes=0,
                       prefetch_B_per_cyc=0.0, n_ic_split=1, n_oc_split=1, n_split_ops=1,
                       ins=list(op.get('ins', [])))
            for B in (1, 2, 4, 8):
                rec["band_B%d" % B] = ew_band(op, B)
            out.append(rec)
            oid += 1
        elif kind == "concat":
            for t in range(2):
                b = act_bytes(op["oh"], op["ow"], op["ic"])
                e = cycles_of(dict(op=2, flags=0, k=0, st=1, pad=0, ih=op["ih"], iw=op["iw"],
                                   ic=op["ic"], oc=op["oc"], src=0, dst=0))
                rec = dict(id=oid, kind="copy", name="%s_copy%d" % (op["name"], t),
                           k=0, stride=1, pad=0, ic=op["ic"], oc=op["ic"],
                           ic_pad=pad8(op["ic"]), oc_pad=pad8(op["ic"]),
                           ih=op["ih"], iw=op["iw"], oh=op["oh"], ow=op["ow"], act="linear",
                           macs=0, w_bytes=0, q_bytes=0, in_bytes=b, out_bytes=b,
                           cycles=e["cycles"], blocks=e["blocks"], n_oc_tile=1,
                           w_tile_bytes=0, prefetch_B_per_cyc=0.0,
                           n_ic_split=1, n_oc_split=1, n_split_ops=1)
                for B in (1, 2, 4, 8):
                    rec["band_B%d" % B] = ew_band(op, B)
                out.append(rec)
                oid += 1
    return out


def arena_peak(ops, owner, input_bytes):
    name2idx = {o["name"]: i for i, o in enumerate(ops)}
    size = [act_bytes(o["oh"], o["ow"], o["oc"]) for o in ops]
    interval = [[i, i] for i in range(len(ops))]
    for i, o in enumerate(ops):
        for src in o.get("ins", []):
            j = owner.get(src)
            if j in name2idx:
                interval[name2idx[j]][1] = max(interval[name2idx[j]][1], i)
    peak, peak_at = 0, 0
    for i in range(len(ops)):
        live = sum(size[j] for j in range(len(ops)) if interval[j][0] <= i <= interval[j][1])
        if i == 0:
            live += input_bytes
        if live > peak:
            peak, peak_at = live, i
    return peak, peak_at


def stage_of(name):
    if "stem" in name:
        return "stem"
    for s in ("stage1", "stage2", "stage3", "stage4", "stage5"):
        if s in name:
            return s
    if "lateral" in name or "refine" in name:
        return "fpn"
    if "multi_scale_fusion" in name:
        return "fusion"
    if "tower" in name:
        return "towers"
    if "_head" in name:
        return "heads"
    return "elemwise"


def analyse(hw):
    model = build_model()
    n_param = sum(p.numel() for p in model.parameters())
    ops, owner = trace_ops(model, hw)
    npu = to_npu_ops(ops)

    tot_macs = sum(o["macs"] for o in npu)
    tot_w = sum(o["w_bytes"] for o in npu)
    tot_q = sum(o["q_bytes"] for o in npu if o["kind"] in ("conv", "dwconv"))
    cycles = sum(o["cycles"] for o in npu)
    read_ideal = sum(o["in_bytes"] for o in npu)
    write = sum(o["out_bytes"] for o in npu)
    naive = sum(o["in_bytes"] * (o["n_oc_tile"] if o["kind"] == "conv"
                                 else (o["oc_pad"] // 8 if o["kind"] == "dwconv" else 1))
                for o in npu)
    n_ops_split = sum(o["n_split_ops"] for o in npu)

    IBUF, OBUF = 32768, 24576
    dist, br, bw_, bip, bop = {}, 0, 0, 0, 0
    for o in npu:
        B = 1
        for cand in (8, 4, 2, 1):
            d = o["band_B%d" % cand]
            if d["in_band_max"] <= IBUF and d["out_band_max"] <= OBUF:
                B = cand
                break
        o["band_sel"] = B
        d = o["band_B%d" % B]
        dist[B] = dist.get(B, 0) + 1
        br += d["in_bytes"]
        bw_ += d["out_bytes"]
        bip = max(bip, d["in_band_max"])
        bop = max(bop, d["out_band_max"])

    tensors = [dict(name=o["name"], h=o["oh"], w=o["ow"], c=o["oc"],
                    bytes=act_bytes(o["oh"], o["ow"], o["oc"]))
               for o in npu if o["kind"] in ("conv", "dwconv", "upsample")]
    input_bytes = hw * hw * 3
    max_t = max(tensors, key=lambda t: t["bytes"])
    max_in = max(npu, key=lambda o: o["in_bytes"])
    max_out = max(npu, key=lambda o: o["out_bytes"])
    pair = max(npu, key=lambda o: o["in_bytes"] + o["out_bytes"])
    unique_sum = input_bytes + sum(t["bytes"] for t in tensors)
    arena, arena_at = arena_peak(npu, owner, input_bytes)
    hidden = set()
    for o in npu:
        if "_block_" in o["name"] and o["kind"] in ("conv", "dwconv"):
            if o["name"].rsplit("_", 1)[-1] in ("0", "1"):
                hidden.add(o["name"])
    boundary = [t for t in tensors if t["name"] not in hidden]
    max_b = max(boundary, key=lambda t: t["bytes"])

    w_ops = [o for o in npu if o["w_bytes"] > 0]
    max_lw = max(w_ops, key=lambda o: o["w_bytes"])
    pairs = []
    for i in range(len(npu) - 1):
        nxt = npu[i + 1]
        if nxt["w_bytes"] <= 0:
            continue
        rate = nxt["w_bytes"] / max(1, npu[i]["cycles"])
        pairs.append(dict(prev=npu[i]["name"], nxt=nxt["name"],
                          prev_cycles=npu[i]["cycles"], nxt_w_bytes=nxt["w_bytes"],
                          B_per_cyc=round(rate, 4), MBps_at_100MHz=round(rate * 100, 2)))
    pairs.sort(key=lambda d: -d["B_per_cyc"])
    usable_B = DDR3_USABLE_MBPS * 1e6 / CLK_HZ
    qspi_B = QSPI_USABLE_MBPS * 1e6 / CLK_HZ
    stall_ddr = sum(max(0.0, p["nxt_w_bytes"] / usable_B - p["prev_cycles"]) for p in pairs)
    stall_qspi = sum(max(0.0, p["nxt_w_bytes"] / qspi_B - p["prev_cycles"]) for p in pairs)
    worst_qspi = [p for p in pairs if p["B_per_cyc"] > qspi_B]
    over256 = [dict(name=o["name"], kind=o["kind"], ic=o["ic"], oc=o["oc"])
               for o in npu if o["kind"] in ("conv", "dwconv")
               and (o["ic"] > 256 or o["oc"] > 256)]
    stages = {}
    for o in npu:
        k = stage_of(o["name"])
        d = stages.setdefault(k, dict(ops=0, macs=0, w_bytes=0, in_bytes=0, out_bytes=0,
                                      cycles=0, q_bytes=0))
        d["ops"] += 1
        for f in ("macs", "w_bytes", "in_bytes", "out_bytes", "cycles", "q_bytes"):
            d[f] += o[f]
    for k, d in stages.items():
        d["macs_M"] = round(d["macs"] / 1e6, 2)
        d["w_KiB"] = round(d["w_bytes"] / 1024, 1)
        d["cycles_k"] = round(d["cycles"] / 1e3, 1)
        d["ms_at_100MHz"] = round(d["cycles"] / 1e5, 2)
        d["pct_macs"] = round(100.0 * d["macs"] / max(1, tot_macs), 2)

    return dict(
        input_hw=hw, param_count=n_param, param_match=(n_param == 2048721),
        npu_ops=len(npu), npu_ops_after_channel_split=n_ops_split,
        ops_by_kind={k: sum(1 for o in npu if o["kind"] == k)
                     for k in ("conv", "dwconv", "add", "copy", "upsample", "pool")},
        macs=tot_macs, macs_M=round(tot_macs / 1e6, 2),
        weight_bytes=tot_w, weight_KiB=round(tot_w / 1024, 1),
        q_bytes=tot_q, q_KiB=round(tot_q / 1024, 1),
        cycles=cycles, ms_at_100MHz=round(cycles / 1e5, 2),
        fps_at_100MHz=round(100e6 / cycles, 2),
        ms_at_122_22MHz=round(cycles / CLK_HZ_MAX * 1e3, 2),
        fps_at_122_22MHz=round(CLK_HZ_MAX / cycles, 2),
        mac_per_cycle=round(tot_macs / cycles, 1),
        mac_bound_cycles=round(tot_macs / NPU_MAC_PER_CYCLE),
        mac_bound_fps_at_100MHz=round(100e6 / (tot_macs / NPU_MAC_PER_CYCLE), 2),
        input_tensor_bytes=input_bytes, unique_tensor_bytes=unique_sum,
        arena_peak_bytes=arena, arena_peak_ref=npu[arena_at]["name"],
        max_single_tensor=dict(name=max_t["name"], h=max_t["h"], w=max_t["w"],
                               c=max_t["c"], bytes=max_t["bytes"]),
        max_in_tensor=dict(name=max_in["name"], bytes=max_in["in_bytes"]),
        max_out_tensor=dict(name=max_out["name"], bytes=max_out["out_bytes"]),
        max_inout_pair=dict(name=pair["name"], in_bytes=pair["in_bytes"],
                            out_bytes=pair["out_bytes"], bytes=pair["in_bytes"] + pair["out_bytes"]),
        max_boundary_tensor=dict(name=max_b["name"], h=max_b["h"], w=max_b["w"],
                                 c=max_b["c"], bytes=max_b["bytes"]),
        act_read_ideal=read_ideal, act_write=write, act_read_naive=naive,
        act_read_banded=br, act_write_banded=bw_,
        band_dist=dist, band_in_peak=bip, band_out_peak=bop,
        total_bands=sum(o["band_B%d" % o["band_sel"]]["bands"] for o in npu),
        frame_bytes_streamed=tot_w + read_ideal + write,
        frame_bytes_current_sched=tot_w + naive + write,
        frame_bytes_banded=tot_w + br + bw_,
        max_layer=dict(name=max_lw["name"], kind=max_lw["kind"], ic=max_lw["ic"],
                       oc=max_lw["oc"], k=max_lw["k"], bytes=max_lw["w_bytes"]),
        top_prefetch_pairs=pairs[:10], max_prefetch=dict(
            B_per_cyc=pairs[0]["B_per_cyc"], MBps_at_100MHz=pairs[0]["MBps_at_100MHz"],
            ref="%s -> %s" % (pairs[0]["prev"], pairs[0]["nxt"])),
        prefetch_stall_ddr_cycles=round(stall_ddr),
        prefetch_stall_qspi_cycles=round(stall_qspi),
        qspi_not_covered=len(worst_qspi),
        channel_over_256=over256, stages=stages, ops=npu,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", type=str, default="56,64,96,112,128,160,192,224")
    ap.add_argument("--fps", type=str, default="2.5,5,10,30")
    args = ap.parse_args()
    sizes = [int(s) for s in args.sizes.split(",")]
    fpss = [float(s) for s in args.fps.split(",")]

    by_size, main_res, res112 = {}, None, None
    for hw in sizes:
        r = analyse(hw)
        print("[hw=%3d] ops=%3d(split %3d) MACs=%8.1fM W=%6.0fKiB cyc=%10s (%6.1fms@100M "
              "=%5.2ffps) peakT=%9s maxPair=%9s arena=%10s"
              % (hw, r["npu_ops"], r["npu_ops_after_channel_split"], r["macs_M"],
                 r["weight_KiB"], "{:,}".format(r["cycles"]), r["ms_at_100MHz"],
                 r["fps_at_100MHz"], "{:,}".format(r["max_single_tensor"]["bytes"]),
                 "{:,}".format(r["max_inout_pair"]["bytes"]),
                 "{:,}".format(r["arena_peak_bytes"])))
        if hw == 224:
            main_res = r
        if hw == 112:
            res112 = r
        by_size[hw] = {k: v for k, v in r.items() if k != "ops"}
    if main_res is None:
        main_res = analyse(224)
    if res112 is None:
        res112 = analyse(112)

    def fbw(fb, fps):
        return round(fb * fps / 1e6, 2)
    bw = {}
    for f in fpss:
        bw["%gfps" % f] = dict(weights_MBps=fbw(main_res["weight_bytes"], f),
                               streamed_MBps=fbw(main_res["frame_bytes_streamed"], f),
                               banded_MBps=fbw(main_res["frame_bytes_banded"], f),
                               current_sched_MBps=fbw(main_res["frame_bytes_current_sched"], f),
                               util_pct_of_1600=round(fbw(main_res["frame_bytes_banded"], f) / 16.0, 2))
    for f in (main_res["fps_at_100MHz"], main_res["fps_at_122_22MHz"]):
        bw["@%.2ffps_actual" % f] = dict(
            banded_MBps=fbw(main_res["frame_bytes_banded"], f),
            util_pct_of_1600=round(fbw(main_res["frame_bytes_banded"], f) / 16.0, 2))
    r112_bw = dict(frame_cycles=res112["cycles"], frame_ms_at_100MHz=res112["ms_at_100MHz"],
                   fps_at_100MHz=res112["fps_at_100MHz"],
                   weights_per_frame_MB=round(res112["weight_bytes"] / 1e6, 3),
                   required_MBps_if_1frame_1pass=round(
                       res112["weight_bytes"] * (100e6 / res112["cycles"]) / 1e6, 2),
                   qspi_usable_MBps=QSPI_USABLE_MBPS,
                   qspi_hideable=(res112["weight_bytes"] * (100e6 / res112["cycles"]) / 1e6)
                                 < QSPI_USABLE_MBPS)

    max_lw = main_res["max_layer"]["bytes"]
    w_bank = 320 * 1024 // 2
    usable_B = DDR3_USABLE_MBPS * 1e6 / CLK_HZ
    qspi_B = QSPI_USABLE_MBPS * 1e6 / CLK_HZ
    out = dict(
        meta=dict(model="EnhancedNutAnchorFree(num_classes=4, fpn_channels=72, backbone_width=0.55)",
                  model_src="tools/bottlecap/model_src/nut_detector/enhanced_anchor_free.py:30-148",
                  run_config="tools/bottlecap/model_src/run_config.json (parameter_count=2048721)",
                  generator="results/bottlecap/ddr3/gen_budget.py",
                  cycle_formula_ref="results/ai-accel/proto/engine/calc_cycles_v3.py "
                                    "(BASE=8, W_RD_LAT=2, DRN=4, NEXT=2; 50/50 TB case 实测==公式)",
                  layout_ref="CONTRACT.md §6/§8",
                  caveat="cycles=NPU 纯计算口径（不含 DDR3/QSPI 预取等待）；预取缺口另列。",
                  constants=dict(npu_mac_per_cycle=NPU_MAC_PER_CYCLE, clk_hz=CLK_HZ,
                                 clk_hz_max_verified=CLK_HZ_MAX,
                                 ddr3_theory_MBps=DDR3_THEORY_MBPS,
                                 ddr3_usable_MBps=DDR3_USABLE_MBPS,
                                 qspi_x4_50MHz_MBps=QSPI_X4_50MHZ_MBPS,
                                 qspi_usable_MBps=QSPI_USABLE_MBPS,
                                 bram_bytes_per_tile=BRAM_BYTES_PER_TILE,
                                 bram_tiles_total=BRAM_TILES_TOTAL, ch_limit=CH_LIMIT)),
        main=dict(stages=main_res.pop("stages"),
                  **{k: v for k, v in main_res.items() if k != "ops"}),
        per_size={str(k): v for k, v in by_size.items()},
        weight_streaming=dict(max_layer=main_res["max_layer"],
                              w_region_bytes=320 * 1024, w_region_tiles=80,
                              double_bank_bytes=w_bank,
                              fits_double_buffer=(2 * max_lw <= 320 * 1024),
                              headroom_bytes=320 * 1024 - 2 * max_lw,
                              max_layer_share_pct=round(100.0 * max_lw / (320 * 1024), 1),
                              prefetch_rate=main_res["max_prefetch"],
                              top_prefetch_pairs=main_res["top_prefetch_pairs"],
                              usable_ddr_B_per_cycle=round(usable_B, 3),
                              qspi_B_per_cycle=round(qspi_B, 3),
                              stall_cycles_ddr=main_res["prefetch_stall_ddr_cycles"],
                              stall_cycles_qspi=main_res["prefetch_stall_qspi_cycles"],
                              qspi_not_covered_pairs=main_res["qspi_not_covered"]),
        bandwidth=dict(ddr3_theory=dict(x32_400MTps_MBps=DDR3_THEORY_MBPS,
                                        usable_70pct_MBps=DDR3_USABLE_MBPS,
                                        ref="P3-DDR3-TILECACHE.md §3.2"),
                       per_fps=bw, r1_streaming_112=r112_bw),
        onchip=dict(band_config=dict(ibuf_bytes=32768, obuf_bytes=24576),
                    band_distribution=main_res["band_dist"],
                    band_in_peak=main_res["band_in_peak"],
                    band_out_peak=main_res["band_out_peak"],
                    max_weight_tile_bytes=max(o["w_tile_bytes"] for o in main_res["ops"]),
                    q_total_bytes=main_res["q_bytes"]),
        arena=dict(unique_tensor_bytes=main_res["unique_tensor_bytes"],
                   peak_concurrent_bytes=main_res["arena_peak_bytes"],
                   peak_at=main_res["arena_peak_ref"],
                   max_single_tensor=main_res["max_single_tensor"],
                   max_inout_pair=main_res["max_inout_pair"],
                   max_boundary_tensor=main_res["max_boundary_tensor"]),
        npu_ops_detail=main_res["ops"],
    )
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "bandwidth_budget.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    with open(os.path.join(here, "layers_224.csv"), "w", encoding="utf-8", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["id", "stage", "kind", "name", "k", "stride", "pad", "ic", "oc",
                     "ih", "iw", "oh", "ow", "act", "macs", "w_bytes", "q_bytes",
                     "in_bytes", "out_bytes", "cycles", "w_tile_bytes",
                     "prefetch_B_per_cyc", "band_sel", "n_split_ops"])
        for o in main_res["ops"]:
            wr.writerow([o["id"], stage_of(o["name"]), o["kind"], o["name"], o["k"],
                         o["stride"], o["pad"], o["ic"], o["oc"], o["ih"], o["iw"],
                         o["oh"], o["ow"], o["act"], o["macs"], o["w_bytes"],
                         o["q_bytes"], o["in_bytes"], o["out_bytes"], o["cycles"],
                         o["w_tile_bytes"], o["prefetch_B_per_cyc"],
                         o.get("band_sel", ""), o["n_split_ops"]])

    print("\n== stages (hw=224) ==")
    for k, v in out["main"]["stages"].items():
        print("  %-9s ops=%3d MACs=%8.1fM W=%7.1fKiB cyc=%8.1fk (%6.1fms)"
              % (k, v["ops"], v["macs_M"], v["w_KiB"], v["cycles"] / 1e3, v["cycles"] / 1e5))
    print("\nmax layer weight: %s %d B (%.1f KiB)"
          % (main_res["max_layer"]["name"], max_lw, max_lw / 1024))
    print("W double buffer 2x%.0fKiB vs max layer %.1fKiB fits=%s headroom=%d"
          % (w_bank / 1024, max_lw / 1024, 2 * max_lw <= 320 * 1024, 320 * 1024 - 2 * max_lw))
    print("prefetch stall cycles: DDR=%d  QSPI=%d  (of %d)"
          % (main_res["prefetch_stall_ddr_cycles"], main_res["prefetch_stall_qspi_cycles"],
             main_res["cycles"]))
    print("112: cycles=%d (%.1fms@100M, %.2ffps) need=%.2f MB/s qspi_hideable=%s"
          % (res112["cycles"], res112["ms_at_100MHz"], res112["fps_at_100MHz"],
             r112_bw["required_MBps_if_1frame_1pass"], r112_bw["qspi_hideable"]))
    print("112: peakT=%d maxPair=%d arena=%d maxBoundary=%d"
          % (res112["max_single_tensor"]["bytes"], res112["max_inout_pair"]["bytes"],
             res112["arena_peak_bytes"], res112["max_boundary_tensor"]["bytes"]))
    print("band dist:", main_res["band_dist"], "total bands:", main_res["total_bands"])


if __name__ == "__main__":
    main()
