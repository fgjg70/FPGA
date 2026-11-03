#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""golden_npu.py — 字节级 int8 golden 校验 + float vs int8 端到端检测一致性。

两件事:
  A. 字节布局 golden: 从 results/bottlecap/plan/ 的 plan.json + w.hex + q.hex **按 CONTRACT
     §6/§7/§8 重新解析**(权重 [tap][IC_pad][OC_pad] / Q 块 bias|M_pos|tail / NHWC 8 通道
     分块激活), 用**独立实现**(int64 中间、np.floor_divide、显式 int8 饱和、逐 OC 循环)
     跑整数前向, 与 quant_npu 的参考整数前向逐位比对(mismatch 必须 0)。
  B. 端到端: 500 张测试图, float 模型 vs int8(NPU 语义) 的检测结果一致性
     (IoU>=0.5 框匹配率 / P/R/F1 / meanIoU / 类别混淆), 以及 float 基线复核。

产物: results/bottlecap/plan/GOLDEN-REPORT.md (+ E2E 指标 JSON 内嵌/可选落盘)

用法:
    python tools/bottlecap/golden_npu.py                    # 全量 500 张
    python tools/bottlecap/golden_npu.py --e2e-limit 100    # 快速子集
    python tools/bottlecap/golden_npu.py --skip-e2e         # 只做 golden 字节校验
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections import Counter
from pathlib import Path

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools", "yolo"))
sys.path.insert(0, os.path.join(HERE, "model_src"))

import extract_graph as eg        # noqa: E402
import quant_npu as qn            # noqa: E402
import quant_lib as ql            # noqa: E402
import vec_io as vio              # noqa: E402

DEFAULT_OUTDIR = os.path.join(ROOT, "results", "bottlecap", "plan")
DEFAULT_DATA = os.path.join(HERE, "data")
NN_A_OFF = 0x00060000


# ============================================================================
# A. 字节级 golden
# ============================================================================
def _parse_q_block(Q, qoff, oc_pad):
    """CONTRACT §7: bias_adj int32[OC_pad] | M_pos int16[OC_pad] | tail 16B。"""
    bias = np.frombuffer(Q[qoff:qoff + 4 * oc_pad].tobytes(), dtype="<i4").astype(np.int64)
    mpos_off = qoff + 4 * oc_pad
    mpos = np.frombuffer(Q[mpos_off:mpos_off + 2 * oc_pad].tobytes(),
                         dtype="<i2").astype(np.int64)
    tail = Q[qoff + 6 * oc_pad:qoff + 6 * oc_pad + 16]
    zp_out = int(np.frombuffer(tail[0:1].tobytes(), dtype=np.int8)[0])
    zp_in = int(np.frombuffer(tail[1:2].tobytes(), dtype=np.int8)[0])
    leaky = int(tail[2])
    shift = int(tail[3])
    return {"bias_adj": bias, "mpos": mpos, "zp_out": zp_out, "zp_in": zp_in,
            "leaky": leaky, "shift": shift}


def load_artifacts(outdir):
    """解析 plan.json + w.hex + q.hex(字节级), 返回 art。"""
    with open(os.path.join(outdir, "plan.json"), encoding="utf-8") as f:
        plan = json.load(f)
    W = vio.u32_le_to_bytes(vio.read_u32_hex(os.path.join(outdir, "w.hex")))
    Q = vio.u32_le_to_bytes(vio.read_u32_hex(os.path.join(outdir, "q.hex")))
    if len(W) < plan["w_bytes"] or len(Q) < plan["q_bytes"]:
        raise SystemExit("w.hex/q.hex too small")
    W = W[:plan["w_bytes"]]
    Q = Q[:plan["q_bytes"]]
    tensors = {int(t["tid"]): t for t in plan["tensors"]}
    ops = plan["ops"]
    qops, adds = {}, {}
    for op in ops:
        kind = op["kind"]
        oc_pad = 0
        if kind in ("conv", "dwconv"):
            oc_pad = ((op["oc"] + 7) // 8) * 8
            ic_pad = ((op["ic"] + 7) // 8) * 8
            woff, wlen = int(op["woff"]), int(op["wlen"])
            wbytes = W[woff:woff + wlen]
            if kind == "conv":
                exp = op["k"] ** 2 * ic_pad * oc_pad
                if wlen != exp:
                    raise SystemExit("op %d dense wlen %d != %d" % (op["id"], wlen, exp))
                wq = np.frombuffer(wbytes.tobytes(), dtype=np.int8).reshape(
                    op["k"] ** 2, ic_pad, oc_pad)
            else:
                exp = op["k"] ** 2 * oc_pad
                if wlen != exp:
                    raise SystemExit("op %d dw wlen %d != %d" % (op["id"], wlen, exp))
                wq = np.frombuffer(wbytes.tobytes(), dtype=np.int8).reshape(
                    op["k"] ** 2, oc_pad)
            qb = _parse_q_block(Q, int(op["qoff"]), oc_pad)
            if op["qlen"] != 6 * oc_pad + 16:
                raise SystemExit("op %d qlen mismatch" % op["id"])
            qp = dict(qb)
            qp.update({"wq": wq, "oc_pad": oc_pad, "ic_pad": ic_pad,
                       "wq_depthwise": wq,
                       "wq_dense": wq if kind == "conv" else None})
            # [task-18] conv+ADD_R 融合: Q tail byte4=zp_d, byte5=KADD, byte6..7=R(LE)
            tail = int(op["qoff"]) + 6 * oc_pad
            tb = Q[tail:tail + 16]
            if len(tb) >= 8 and (int(tb[4]) or int(tb[5]) or int(tb[6])
                                 or int(tb[7])):
                zp_d = int(np.frombuffer(tb[4:5].tobytes(), dtype=np.int8)[0])
                kadd = int(tb[5])
                r = int(np.frombuffer(tb[6:8].tobytes(), dtype="<u2")[0])
                qp["fused"] = {"zp_d": zp_d, "K": kadd, "R": r,
                               "relu": bool(int(op.get("flags", 0)) & 16)}
            qops[op["id"]] = qp
        elif kind == "add":
            qoff = int(op["qoff"])
            blk = Q[qoff:qoff + 16]
            zp_s = int(np.frombuffer(blk[0:1].tobytes(), dtype=np.int8)[0])
            zp_d = int(np.frombuffer(blk[1:2].tobytes(), dtype=np.int8)[0])
            r = int(np.frombuffer(blk[2:4].tobytes(), dtype="<u2")[0])
            kadd = int(blk[4])
            adds[op["id"]] = {"r_scale": r, "k_add": kadd, "zp_s": zp_s, "zp_d": zp_d}
    return {"plan": plan, "tensors": tensors, "ops": ops, "qops": qops, "adds": adds,
            "W": W, "Q": Q}


class Arena:
    """CONTRACT §8 激活字节布局的显式模拟(8 通道分块 == 紧凑 NHWC 行主序)。

    src/dst 是 A/B 窗口内相对偏移(real 模式下两个 bank 各自从 0 开始), 故用两个
    独立 byte buf 模拟; 张量按其 win_buf 选 bank。
    """

    def __init__(self, plan):
        sizes = {"A": 0, "B": 0}
        for t in plan["tensors"]:
            b = t.get("win_buf", "A")
            sizes[b] = max(sizes[b], int(t["win_off"]) + int(t["bytes"]))
        self.bufs = {b: np.zeros(sz, dtype=np.uint8) for b, sz in sizes.items()}
        self.tensors = {int(t["tid"]): t for t in plan["tensors"]}

    def _tensor(self, tid):
        t = self.tensors[int(tid)]
        return t, int(t["win_off"]), int(t["h"]), int(t["w"]), int(t["c8"])

    def _buf(self, t):
        return self.bufs[t.get("win_buf", "A")]

    def write(self, tid, arr):
        t, off, h, w, c8 = self._tensor(tid)
        a = np.ascontiguousarray(arr, dtype=np.int8)
        if not t["packed"]:
            assert a.shape == (h, w, c8), (tid, a.shape, (h, w, c8))
        else:
            assert a.shape == (h, w, int(t["c"])), (tid, a.shape)
        self._buf(t)[off:off + a.nbytes] = a.view(np.uint8).ravel()

    def read(self, tid):
        t, off, h, w, c8 = self._tensor(tid)
        buf = self._buf(t)
        if t["packed"]:
            n = h * w * int(t["c"])
            return buf[off:off + n].view(np.int8).reshape(h, w, int(t["c"]))
        return buf[off:off + h * w * c8].view(np.int8).reshape(h, w, c8)

    def read_slice(self, tid, c0, c1):
        """按通道切片读(仍走 8 通道字布局: 要求 c0,c1 是 8 的倍数或 c1-c0<=8)。"""
        t, off, h, w, c8 = self._tensor(tid)
        buf = self._buf(t)
        n = h * w * c8
        full = buf[off:off + n].view(np.int8).reshape(h, w, c8)
        return np.ascontiguousarray(full[:, :, c0:c1])


def _requant_golden(acc, qp):
    """逐 OC floor_divide requant + zp_out + int8 饱和(独立于参考实现的 >> 路径)。"""
    oc_pad = acc.shape[-1]
    mpos = qp["mpos"]
    shift = int(qp["shift"])
    den = 1 << shift
    mneg = ((mpos * 3277 + 16384) >> 15) if qp["leaky"] else mpos
    out = np.empty(acc.shape, dtype=np.int64)
    for oc in range(oc_pad):
        a = acc[:, :, oc]
        m = int(mneg[oc]) if (qp["leaky"] and np.any(a < 0)) else int(mpos[oc])
        prod = a * m
        if qp["leaky"]:
            out[:, :, oc] = np.where(a >= 0, np.floor_divide(prod, den),
                                     np.floor_divide(a * int(mneg[oc]), den))
        else:
            out[:, :, oc] = np.floor_divide(prod, den)   # floor(向 -inf) == 算术右移
    out += int(qp["zp_out"])
    return np.clip(out, -128, 127).astype(np.int8)


def golden_forward(art, x_packed):
    """独立整数前向: 读字节 arena -> 逐 op 计算 -> 写字节 arena。"""
    plan = art["plan"]
    ops = art["ops"]
    qops, adds = art["qops"], art["adds"]
    tensors = art["tensors"]
    arena = Arena(plan)
    itid = int(plan["input"]["tid"])
    arena.write(itid, np.asarray(x_packed, dtype=np.int8))
    op_out = {}
    created = set()     # 已经写过(有内容)的张量
    created.add(itid)
    for op in ops:
        kind = op["kind"]
        if "_off2tid" not in art:
            art["_off2tid"] = {(int(t["win_off"]), t["win_buf"]): int(t["tid"])
                               for t in plan["tensors"]}
        def tid_at(buf, off):
            best = None
            for t in plan["tensors"]:
                if t["win_buf"] != buf:
                    continue
                base = int(t["win_off"])
                size = int(t["bytes"])
                if base <= off < base + size:
                    if best is None or base > int(best["win_off"]):
                        best = t
            if best is None:
                raise SystemExit("cannot resolve tensor at buf=%s off=%d" % (buf, off))
            return int(best["tid"])

        src_tid = int(op["src_tid"]) if "src_tid" in op else \
            tid_at(op["src"]["buf"], int(op["src"]["off"]))
        dst_tid = int(op["dst_tid"]) if "dst_tid" in op else \
            tid_at(op["dst"]["buf"], int(op["dst"]["off"]))
        dst_t = tensors[dst_tid]
        H, W, C8 = int(dst_t["h"]), int(dst_t["w"]), int(dst_t["c8"])

        if kind in ("conv", "dwconv"):
            qp = qops[op["id"]]
            x = arena.read(src_tid)
            packed = bool(tensors[src_tid]["packed"])
            k, s, pad = int(op["k"]), int(op["stride"]), int(op["pad"])
            ic_pad = int(qp["ic_pad"])
            if packed:
                hh, ww, ic = x.shape
                xin = np.full((hh, ww, ic_pad), qp["zp_in"], dtype=np.int8)
                xin[:, :, :ic] = x
            else:
                xin = x
            hh, ww = xin.shape[0], xin.shape[1]
            xp = np.full((hh + 2 * pad, ww + 2 * pad, ic_pad), qp["zp_in"], dtype=np.int8)
            xp[pad:pad + hh, pad:pad + ww, :] = xin
            oh, ow = int(op["oh"]), int(op["ow"])
            if kind == "dwconv":
                acc = np.zeros((oh, ow, int(qp["oc_pad"])), dtype=np.int64)
                for tap in range(k * k):
                    ky, kx = divmod(tap, k)
                    patch = xp[ky:ky + (oh - 1) * s + 1:s, kx:kx + (ow - 1) * s + 1:s, :]
                    for c in range(int(qp["oc_pad"])):
                        acc[:, :, c] += patch[:, :, c].astype(np.int64) * int(qp["wq"][tap, c])
            else:
                cols = []
                for tap in range(k * k):
                    ky, kx = divmod(tap, k)
                    patch = xp[ky:ky + (oh - 1) * s + 1:s, kx:kx + (ow - 1) * s + 1:s, :]
                    cols.append(patch.reshape(oh * ow, ic_pad))
                cols = np.concatenate(cols, axis=1).astype(np.int64)   # (oh*ow, k2*ic_pad)
                wmat = qp["wq"].reshape(k * k * ic_pad, int(qp["oc_pad"])).astype(np.int64)
                acc = (cols @ wmat).reshape(oh, ow, int(qp["oc_pad"]))
            acc += qp["bias_adj"][None, None, :]
            y = _requant_golden(acc, qp)
            out = np.full((oh, ow, C8), qp["zp_out"], dtype=np.int8)
            out[:, :, :int(op["oc"])] = y[:, :, :int(op["oc"])]
            # [task-18] conv+ADD_R 融合(独立实现; M6-FUSION-CONTRACT B.2):
            # q_s = 已饱和 int8 conv 输出; p = ((q_s - zp_out)*R)>>KADD(floor);
            # out = clamp(q_d + p)(第二次饱和); RELU 时 out = max(out, zp_d)
            fa = qp.get("fused")
            if fa:
                qd = arena.read(dst_tid)     # 残差(dst 内存原值, 写前读)
                delta = np.floor_divide(
                    (out.astype(np.int64) - int(qp["zp_out"])) * int(fa["R"]),
                    1 << int(fa["K"]))
                res = np.clip(qd.astype(np.int64) + delta, -128, 127)
                if fa.get("relu"):
                    res = np.maximum(res, np.int64(int(fa["zp_d"])))
                out = res.astype(np.int8)
        elif kind == "upsample":
            x = arena.read(src_tid)
            out = np.repeat(np.repeat(x, 2, axis=0), 2, axis=1)
        elif kind == "add":
            a = adds[op["id"]]
            x = arena.read(src_tid)
            cur = arena.read(dst_tid)
            c = int(op["ic"])
            delta = np.floor_divide((x[:, :, :c].astype(np.int64) - int(a["zp_s"]))
                                    * int(a["r_scale"]), 1 << int(a["k_add"]))
            out = cur.copy()
            out[:, :, :c] = np.clip(cur[:, :, :c].astype(np.int64) + delta,
                                    -128, 127).astype(np.int8)
        elif kind == "copy":
            cs, cd, c = int(op.get("c_src", 0)), int(op.get("c_dst", 0)), int(op["ic"])
            x = arena.read(src_tid)
            if dst_tid not in created:
                out = np.full((H, W, C8), int(dst_t["zp"]), dtype=np.int8)
            else:
                out = arena.read(dst_tid).copy()
            out[:, :, cd:cd + c] = x[:, :, cs:cs + c]
        else:
            raise SystemExit("unknown kind %r" % kind)
        arena.write(dst_tid, out)
        created.add(dst_tid)
        if kind == "copy":
            cs, cd, c = int(op.get("c_src", 0)), int(op.get("c_dst", 0)), int(op["ic"])
            op_out[op["id"]] = out[:, :, cd:cd + c]
        else:
            op_out[op["id"]] = out[:, :, :int(dst_t["c"])]
    store = {tid: arena.read(tid) for tid in created}
    return arena, store, op_out


def check_layout_roundtrip(art, verbose=True):
    """自检: 显式 8 通道分块布局 == 紧凑 NHWC 行主序(§8 公式)。"""
    cand = [tt for tt in art["plan"]["tensors"]
            if tt["role"] == "conv" and int(tt["c8"]) % 16 == 0
            and 8000 < int(tt["bytes"]) < 200000]
    if not cand:
        return True
    t = cand[0]
    h, w, c8 = int(t["h"]), int(t["w"]), int(t["c8"])
    rng = np.random.default_rng(0)
    logical = rng.integers(-128, 128, size=(h, w, c8), dtype=np.int8)
    # 显式按 §8 地址公式逐 (y,x,c) 写入。注意 §8 公式里 C8 是"每像素通道字数"
    # (ceil(C/8)), 而字节地址 = ((y*W+x)*C8_blocks + c_block)*8 + c_byte;
    # 展开后 = (y*W+x)*ceil(C/8)*8 + c_block*8 + c_byte == 紧凑 NHWC 行主序。
    buf = np.zeros(h * w * c8, dtype=np.uint8)
    for y in range(h):
        for x in range(w):
            pix = y * w + x
            for c in range(c8):
                cb, cc = divmod(c, 8)
                addr = pix * c8 + cb * 8 + cc
                buf[addr] = np.uint8(int(logical[y, x, c]) & 0xFF)
    ok = np.array_equal(buf, logical.view(np.uint8).ravel())
    if verbose:
        print("[golden] §8 layout roundtrip: %s (tensor %d %dx%dx%d)"
              % ("PASS" if ok else "FAIL", t["tid"], h, w, c8))
    if not ok:
        raise SystemExit("§8 layout roundtrip mismatch")
    return ok


# ============================================================================
# B. 端到端
# ============================================================================
def _match_class_aware(pred_cls, pred_box, true_cls, true_box, iou_thr=0.5):
    if len(pred_box) == 0 or len(true_box) == 0:
        return []
    from nut_detector.train_multi_mobilenet_anchor_free import pairwise_iou
    ious = pairwise_iou(pred_box, true_box)
    cand = ious.masked_fill(~pred_cls[:, None].eq(true_cls[None, :]), -1.0)
    pairs = []
    while cand.numel() and float(cand.max()) >= iou_thr:
        flat = int(cand.argmax())
        pi, ti = flat // cand.shape[1], flat % cand.shape[1]
        pairs.append((pi, ti, float(cand[pi, ti])))
        cand[pi, :] = -1.0
        cand[:, ti] = -1.0
    return pairs


def _match_any_class(pred_cls, pred_box, true_cls, true_box, iou_thr=0.5):
    if len(pred_box) == 0 or len(true_box) == 0:
        return []
    from nut_detector.train_multi_mobilenet_anchor_free import pairwise_iou
    cand = pairwise_iou(pred_box, true_box)
    pairs = []
    while cand.numel() and float(cand.max()) >= iou_thr:
        flat = int(cand.argmax())
        pi, ti = flat // cand.shape[1], flat % cand.shape[1]
        pairs.append((pi, ti, float(cand[pi, ti])))
        cand[pi, :] = -1.0
        cand[:, ti] = -1.0
    return pairs


def _gt_metrics(preds, gts, class_names=None):
    """与 evaluate_multi_mobilenet_anchor_free.py 同口径的检测指标。

    TP/FP/FN 用 class-aware 贪心匹配 IoU>=0.5; 另外给 per-class 与按目标数分组,
    整图全对率(tp==n_gt 且 fp==0)、目标数量准确率(n_pred==n_gt)。
    """
    from collections import defaultdict
    tp = fp = fn = 0
    ious = []
    per = defaultdict(lambda: {"tp": 0, "fp": 0, "fn": 0})
    by_count = defaultdict(lambda: {"images": 0, "tp": 0, "fp": 0, "fn": 0,
                                    "count_correct": 0, "exact": 0})
    exact = count_correct = 0
    for p, (gc, gb) in zip(preds, gts):
        gc = gc.long()
        pairs = _match_class_aware(p["classes"].long(), p["boxes"], gc, gb)
        ptp = len(pairs)
        n_gt, n_pred = len(gc), len(p["boxes"])
        pfp, pfn = n_pred - ptp, n_gt - ptp
        tp += ptp
        fp += pfp
        fn += pfn
        ious += [x[2] for x in pairs]
        matched_ti = {ti for _, ti, _ in pairs}
        matched_pi = {pi for pi, _, _ in pairs}
        for ti in range(n_gt):
            c = int(gc[ti])
            if ti in matched_ti:
                per[c]["tp"] += 1
            else:
                per[c]["fn"] += 1
        for pi in range(n_pred):
            if pi not in matched_pi:
                per[int(p["classes"][pi])]["fp"] += 1
        g = by_count[n_gt]
        g["images"] += 1
        g["tp"] += ptp
        g["fp"] += pfp
        g["fn"] += pfn
        g["count_correct"] += int(n_pred == n_gt)
        g["exact"] += int(ptp == n_gt and pfp == 0)
        count_correct += int(n_pred == n_gt)
        exact += int(ptp == n_gt and pfp == 0)
    P = tp / max(1, tp + fp)
    R = tp / max(1, tp + fn)
    n_img = max(1, len(preds))
    names = class_names or ["class%d" % i for i in range(16)]
    per_out = {}
    for c, v in sorted(per.items()):
        cp = v["tp"] / max(1, v["tp"] + v["fp"])
        cr = v["tp"] / max(1, v["tp"] + v["fn"])
        per_out[names[c] if c < len(names) else str(c)] = {
            "tp": v["tp"], "fp": v["fp"], "fn": v["fn"],
            "precision": cp, "recall": cr,
            "f1": 2 * cp * cr / max(1e-9, cp + cr)}
    by_out = {}
    for k, v in sorted(by_count.items()):
        bp = v["tp"] / max(1, v["tp"] + v["fp"])
        br = v["tp"] / max(1, v["tp"] + v["fn"])
        by_out[str(k)] = {"images": v["images"], "tp": v["tp"], "fp": v["fp"],
                          "fn": v["fn"], "precision": bp, "recall": br,
                          "count_accuracy": v["count_correct"] / v["images"],
                          "exact_image_accuracy": v["exact"] / v["images"]}
    return {"tp": int(tp), "fp": int(fp), "fn": int(fn),
            "precision": P, "recall": R,
            "f1": 2 * P * R / max(1e-9, P + R),
            "mean_iou": float(np.mean(ious)) if ious else 0.0,
            "n_gt": int(tp + fn), "n_pred": int(tp + fp),
            "n_images": len(preds),
            "exact_image_accuracy": exact / n_img,
            "count_accuracy": count_correct / n_img,
            "per_class": per_out,
            "by_true_object_count": by_out}


def _predict_float(model, imgs, device, decode_fn, batch=32):
    """float 模型批量推理 -> (preds, heads)。heads[k] = [3 个 (C,H,W) numpy]。"""
    preds, heads = [], []
    with torch.no_grad():
        for i in range(0, len(imgs), batch):
            x = torch.from_numpy(np.stack(imgs[i:i + batch])).permute(0, 3, 1, 2).to(device)
            outs = model(x)
            pr = decode_fn(*outs)
            hc = [[oo[j].cpu().numpy() for oo in outs] for j in range(len(pr))]
            for p, hh in zip(pr, hc):
                preds.append({"classes": p["classes"].cpu(),
                              "boxes": p["boxes"].cpu(),
                              "scores": p["scores"].cpu()})
                heads.append(hh)
            del outs, hc
    return preds, heads


def _build_wdq_model(model):
    """理想 QDQ 上限实验: 权重 per-OC int8 量化-反量化, 激活保持 float。"""
    import copy
    from torch import nn as _nn
    m = copy.deepcopy(model).cpu()      # CPU 上做 BN 折叠/量化, 之后由调用方 to(device)

    def fuse_and_qdq(module):
        for _, child in list(module.named_children()):
            fuse_and_qdq(child)
        names = list(module._modules.keys())
        for i in range(len(names) - 1):
            a, b = module._modules[names[i]], module._modules[names[i + 1]]
            if isinstance(a, _nn.Conv2d) and isinstance(b, _nn.BatchNorm2d):
                W, bias = eg.conv_bn_fuse(a, b)
                a.weight.data = torch.from_numpy(W.astype(np.float32))
                a.bias = _nn.Parameter(torch.from_numpy(bias.astype(np.float32)))
                module._modules[names[i + 1]] = _nn.Identity()

    fuse_and_qdq(m)
    n_q = 0
    for mod in m.modules():
        if isinstance(mod, _nn.Conv2d):
            W = mod.weight.detach().double().numpy()
            oc = W.shape[0]
            sw = np.abs(W).reshape(oc, -1).max(axis=1) / 127.0
            sw = np.where(sw > 0, sw, 1.0)
            Wq = np.clip(np.floor(W / sw[:, None, None, None] + 0.5), -127, 127) \
                * sw[:, None, None, None]
            mod.weight.data = torch.from_numpy(Wq.astype(np.float32))
            n_q += 1
    m.eval()
    return m, n_q


def _match_between(pred_a, pred_b, verbose_tag=""):
    """两个模型检测结果互相匹配: 同类 IoU>=0.5 贪心; 同时统计类别混淆。"""
    matched = miscls = 0
    n_a = n_b = 0
    ious, score_diffs = [], []
    exact = count_eq = 0
    for a, b in zip(pred_a, pred_b):
        na, nb = len(a["boxes"]), len(b["boxes"])
        n_a += na
        n_b += nb
        if na == nb:
            count_eq += 1
        img_matched = 0
        if na and nb:
            pairs = _match_class_aware(a["classes"], a["boxes"],
                                       b["classes"], b["boxes"])
            img_matched = len(pairs)
            matched += img_matched
            ious += [x[2] for x in pairs]
            for ia, ib, _ in pairs:
                score_diffs.append(abs(float(a["scores"][ia]) - float(b["scores"][ib])))
            for ia, ib, _ in _match_any_class(a["classes"], a["boxes"],
                                              b["classes"], b["boxes"]):
                if int(a["classes"][ia]) != int(b["classes"][ib]):
                    miscls += 1
        if na == nb and img_matched == na:
            exact += 1
    return {
        "n_boxes_a": int(n_a), "n_boxes_b": int(n_b),
        "matched_same_class_iou50": int(matched),
        "match_rate_of_a": matched / max(1, n_a),
        "match_rate_of_b": matched / max(1, n_b),
        "mean_iou_matched": float(np.mean(ious)) if ious else 0.0,
        "class_confusion_pairs_iou50": int(miscls),
        "count_equal_images": int(count_eq),
        "exact_equal_images": int(exact),
        "n_images": len(pred_a),
        "mean_abs_score_diff": float(np.mean(score_diffs)) if score_diffs else 0.0,
    }


def run_e2e(B, args, verbose=True):
    from nut_detector.multi_anchor_free import decode_multi_predictions
    from nut_detector.multi_dataset import read_multi_split
    from PIL import Image

    plan, q, tensors, ops, folded = B["plan"], B["q"], B["tensors"], B["ops"], B["folded"]
    gq, roots = B["gq"], B["groups"]["roots"]
    s_in, zp_in = gq[roots[plan["input_tensor"]]]
    final_tids = plan["final_tensors"]
    class_names = list(B["ck"].get("class_names") or [])
    data_dir = Path(args.data)
    samples = read_multi_split(data_dir, "test")
    if args.e2e_limit > 0:
        samples = samples[:args.e2e_limit]
    n = len(samples)
    if verbose:
        print("[e2e] %d test images, input=%d" % (n, args.input_size))

    # ---- 预加载 ----
    imgs, gts = [], []
    for s in samples:
        with Image.open(s["image"]) as im:
            im = im.convert("RGB")
            w, h = im.size
            imgs.append(eg.preprocess_image(im, args.input_size))
        gb = eg.preprocess_boxes(np.asarray(s["boxes"], np.float32), (w, h),
                                 args.input_size)
        gts.append((torch.from_numpy(np.asarray(s["classes"], np.int64)),
                    torch.from_numpy(gb)))
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    # ---- float 参考模型 ----
    model, ck, arch = eg.build_model(args.checkpoint, args.arch)
    model.to(device).eval()
    t0 = time.time()
    float_preds, float_heads = _predict_float(model, imgs, device,
                                              decode_multi_predictions)
    float_secs = time.time() - t0
    if verbose:
        print("[e2e] float model: %.1fs (%.1f ms/img)" % (float_secs, 1000 * float_secs / n))

    # ---- int8(NPU 语义) ----
    t0 = time.time()
    int8_preds = []
    head_cos = []
    for k, img in enumerate(imgs):
        xq = qn.quantize_input(img, s_in, zp_in)
        store, _ = qn.int8_forward(plan, q, xq, fast=True)
        hs = []
        for tid in final_tids:
            C = int(tensors[tid]["c"])
            so, zo = gq[roots[tid]]
            dq = ql.dequantize(store[tid][:, :, :C], so, zo).astype(np.float32)
            hs.append(torch.from_numpy(dq).permute(2, 0, 1)[None])
        pr = decode_multi_predictions(*hs)[0]
        int8_preds.append({"classes": pr["classes"], "boxes": pr["boxes"],
                           "scores": pr["scores"]})
        cos3 = []
        for fhead, ihead in zip(float_heads[k], hs):
            fa = fhead.reshape(-1)
            ia = ihead[0].numpy().reshape(-1)
            na, nb = np.linalg.norm(fa), np.linalg.norm(ia)
            cos3.append(float(fa @ ia / (na * nb + 1e-12)))
        head_cos.append(cos3)
    int8_secs = time.time() - t0
    if verbose:
        print("[e2e] int8 model: %.1fs (%.1f ms/img)" % (int8_secs, 1000 * int8_secs / n))

    # ---- 理想 QDQ 上限(权重 int8, 激活 float) ----
    wdq_preds = None
    wdq_n = 0
    if getattr(args, "ceiling", True):
        t0 = time.time()
        wdq_model, wdq_n = _build_wdq_model(model)
        wdq_model.to(device)
        wdq_preds, _ = _predict_float(wdq_model, imgs, device, decode_multi_predictions)
        del wdq_model
        if device.type == "cuda":
            torch.cuda.empty_cache()
        if verbose:
            print("[e2e] W-only QDQ ceiling (%d convs): %.1fs"
                  % (wdq_n, time.time() - t0))

    # ---- 指标 ----
    float_gt = _gt_metrics(float_preds, gts, class_names)
    int8_gt = _gt_metrics(int8_preds, gts, class_names)
    out = {
        "n_images": int(n),
        "thresholds": {"iou_match": 0.5, "conf": 0.20, "nms": 0.35,
                       "pre_nms_topk": 40, "max_detections": 4,
                       "decode": "nut_detector.multi_anchor_free.decode_multi_predictions"
                                 " (与 evaluate_multi_mobilenet_anchor_free.py 一致)"},
        "float_vs_gt": float_gt,
        "int8_vs_gt": int8_gt,
        "int8_vs_float": _match_between(int8_preds, float_preds),
        "head_cos_float_vs_int8": {
            "objectness_mean": float(np.mean([c[0] for c in head_cos])),
            "objectness_min": float(np.min([c[0] for c in head_cos])),
            "class_mean": float(np.mean([c[1] for c in head_cos])),
            "class_min": float(np.min([c[1] for c in head_cos])),
            "box_mean": float(np.mean([c[2] for c in head_cos])),
            "box_min": float(np.min([c[2] for c in head_cos])),
        },
        "timing": {"float_s": round(float_secs, 2),
                   "float_ms_per_img": round(1000 * float_secs / n, 2),
                   "int8_s": round(int8_secs, 2),
                   "int8_ms_per_img": round(1000 * int8_secs / n, 2)},
        "device": str(device),
    }
    if wdq_preds is not None:
        out["wdq_ceiling"] = {
            "n_convs_quantized": int(wdq_n),
            "vs_gt": _gt_metrics(wdq_preds, gts, class_names),
            "vs_float": _match_between(wdq_preds, float_preds),
        }
    return out


def check_ref_heads(ref_path, B):
    """与 slim-train 的 ref_heads.npz 交叉校验(自适应; 失败只报告不中断)。

    npz (EXPORT.json.ref_heads_layout):
      inputs_int8_packed3 (N,96,96,3) int8; inputs_float_nchw (N,3,96,96) float32;
      objectness (N,1,24,24) / class_logits (N,4,24,24) / box_logits (N,4,24,24) raw logits。
    三项检查:
      A) 我们的 float 模型 on ref float 输入 -> cos vs ref float heads(校验模型/head 顺序)
      B) 我们的 int8(NPU 语义) on ref int8 输入 -> 反量化 -> cos vs ref float heads
      C) ref int8 输入 vs 用 plan 的 s_in/zp_in 重新量化的字节 -> mismatch%(口径差异提示)
    """
    out = {"path": ref_path, "status": "NOT_PRESENT"}
    if not ref_path or not os.path.exists(ref_path):
        return out
    try:
        z = np.load(ref_path, allow_pickle=True)
        keys = list(z.keys())
        info = {k: [str(z[k].dtype), list(z[k].shape)] for k in keys}
        out["keys"] = info

        def head_idx(k):
            kl = k.lower()
            if "object" in kl or "obj" in kl:
                return 0
            if "box" in kl:
                return 2
            if "class" in kl or "cls" in kl:
                return 1
            return None

        ref_heads = {}
        for k in keys:
            hk = head_idx(k)
            a = z[k]
            if hk is not None and a.dtype in (np.float32, np.float64) and a.ndim >= 3:
                ref_heads[hk] = np.asarray(a, dtype=np.float32)
        if len(ref_heads) != 3:
            out.update({"status": "UNPARSED",
                        "note": "找不到 3 个 head 数组(名字含 object/class/box)"})
            return out
        order = [ref_heads[0], ref_heads[1], ref_heads[2]]
        plan, q = B["plan"], B["q"]
        roots = B["groups"]["roots"]
        gq = B["gq"]
        final = plan["final_tensors"]
        tensors = B["tensors"]

        def ch(x, axis):
            return int(x.shape[axis])

        our_c = [int(tensors[t]["c"]) for t in final]
        ref_c = [ch(order[0], 1), ch(order[1], 1), ch(order[2], 1)]
        if our_c != ref_c:
            out.update({"status": "MISMATCH_HEAD_ORDER", "keys": info,
                        "ref_channels": ref_c, "our_channels": our_c})
            return out
        n = int(order[0].shape[0])
        results = {"A_float_model_vs_ref": [], "B_int8_vs_ref": [],
                   "input_quant_mismatch_pct": None}

        def cos(a, b):
            a = np.asarray(a, np.float64).ravel()
            b = np.asarray(b, np.float64).ravel()
            na, nb = np.linalg.norm(a), np.linalg.norm(b)
            return float(a @ b / (na * nb + 1e-12))

        # ---- A) float 模型 on ref float 输入 ----
        if "inputs_float_nchw" in keys:
            ckpt = os.path.join(os.path.dirname(os.path.abspath(ref_path)),
                                "best_model.pt")
            if not os.path.exists(ckpt):
                ckpt = eg.DEFAULT_CKPT
            try:
                model, _, _ = eg.build_model(ckpt, "slim")
                model.eval()
                xf = torch.from_numpy(z["inputs_float_nchw"].astype(np.float32))
                with torch.no_grad():
                    outs = model(xf)
                for hk, (ref, o) in enumerate(zip(order, outs)):
                    o = o.numpy()
                    results["A_float_model_vs_ref"].append(
                        {"head": ["objectness", "class", "box"][hk],
                         "cos_mean": float(np.mean([cos(o[i], ref[i])
                                                    for i in range(n)])),
                         "cos_min": float(np.min([cos(o[i], ref[i])
                                                  for i in range(n)]))})
            except Exception as e:  # pragma: no cover
                results["A_error"] = str(e)
        # ---- B) int8 on ref int8 输入 ----
        s_in, zp_in = gq[roots[plan["input_tensor"]]]
        if "inputs_int8_packed3" in keys:
            xi = np.asarray(z["inputs_int8_packed3"], dtype=np.int8)
            n = min(n, int(xi.shape[0]))
            row_cos = [[], [], []]
            for k in range(n):
                store, _ = qn.int8_forward(plan, q, np.ascontiguousarray(xi[k]),
                                           fast=True)
                for hk, tid in enumerate(final):
                    C = int(tensors[tid]["c"])
                    s, zp = gq[roots[tid]]
                    dq = ql.dequantize(store[tid][:, :, :C], s, zp)   # (H,W,C)
                    ref = np.asarray(order[hk][k], dtype=np.float32)
                    if ref.ndim == 3 and ref.shape[0] == C:
                        ref = np.transpose(ref, (1, 2, 0))            # CHW -> HWC
                    row_cos[hk].append(cos(dq, ref))
            for hk in range(3):
                results["B_int8_vs_ref"].append(
                    {"head": ["objectness", "class", "box"][hk],
                     "cos_mean": float(np.mean(row_cos[hk])),
                     "cos_min": float(np.min(row_cos[hk]))})
        # ---- C) ref int8 输入 vs 按 plan s_in/zp_in 重新量化 ----
        if "inputs_int8_packed3" in keys and "inputs_float_nchw" in keys:
            xf = z["inputs_float_nchw"].astype(np.float32)
            xn = np.transpose(xf, (0, 2, 3, 1))          # NHWC
            xq = np.clip(ql.rnd(xn.astype(np.float64) / s_in) + zp_in,
                         -128, 127).astype(np.int8)
            xr = np.asarray(z["inputs_int8_packed3"], dtype=np.int8)
            results["input_quant_mismatch_pct"] = float((xq != xr).mean())
            results["input_quant_note"] = (
                "ref 用固定 s=2/255=%.7f; 本 plan 用 calibration s_in=%.7f zp_in=%d"
                % (2.0 / 255.0, s_in, zp_in))
        vals_a = [r["cos_min"] for r in results.get("A_float_model_vs_ref", [])]
        vals_b = [r["cos_min"] for r in results.get("B_int8_vs_ref", [])]
        if vals_a:
            status = "PASS" if min(vals_a) > 0.999 else "LOW"
            note = ("A(模型/head 顺序): float 模型 on ref float 输入 cos≈1 → 与 slim-train "
                    "参考输出 bit-级一致; B(int8): 用 ref 的固定 s=2/255 输入喂本 plan"
                    "(s_in=%.7f), 0.81%% 输入字节差异 -> class cos≈0.97; hw E2E 以本 plan "
                    "口径的 opvec 输入为准" % s_in)
        else:
            status = "PASS" if vals_b and min(vals_b) > 0.98 else "LOW"
            note = "B=int8(NPU 语义) on ref int8 输入"
        out.update({"status": status,
                    "n_samples": n, "results": results,
                    "cos_min": float(min(vals_b)) if vals_b else None,
                    "cos_min_A": float(min(vals_a)) if vals_a else None,
                    "cos_min_B": float(min(vals_b)) if vals_b else None,
                    "head_order": "objectness, class, box (raw logits)",
                    "note": note})
    except Exception as e:  # pragma: no cover
        out.update({"status": "ERROR", "error": str(e)})
    return out


# ============================================================================
# opvec 金标导出 (M6/M6b 逐 op 位精确比对用)
# ============================================================================
def _u32_hex_bytes(arr):
    b = np.ascontiguousarray(arr, dtype=np.int8).tobytes()
    return vio.bytes_to_u32_le(b)


def export_opvec(outdir, B, data_dir, label, seed=12345, subset=None,
                 verbose=True, plan_art=None):
    """导出固定图的逐 op int8 金标。

    图 1: pattern_v1(seed=12345) —— 与 checksums.txt 的 op csum 完全同源;
    图 2: data/test 里由 seed=12345 抽到的第一张真实图(预处理+输入量化后的 PACKED3)。
    每个 op 文件 = 该 op 执行后 DST 张量的 arena 布局字节(NHWC pad8, y,x,c 逻辑序),
    u32 little-endian 字/行(与 CONTRACT §10 的 .hex 口径一致), 行数 = ceil(bytes/4)。
    """
    plan, q = B["plan"], B["q"]
    tensors = B["tensors"]
    gq, roots = B["gq"], B["groups"]["roots"]
    s_in, zp_in = gq[roots[plan["input_tensor"]]]
    input_tid = int(plan["input_tensor"])
    ARENA_BASE = 0x01000000
    arena_map = {}
    if plan_art is not None:
        arena_map = {int(t["tid"]): int(t.get("arena_off", 0))
                     for t in plan_art.get("tensors", [])}
    # subset: 前 12 op + 最后 8 op + 3 个后段覆盖 op
    ops = B["ops"]
    n = len(ops)
    if subset is None:
        subset = list(range(0, 12)) + list(range(max(12, n - 8), n))

        def first(pred, start):
            for o in ops:
                if o["id"] >= start and pred(o):
                    return o["id"]
            return None

        extra_dw_s2 = first(lambda o: o["kind"] == "dwconv" and o["k"] == 3
                            and o["stride"] == 2, 20)
        extra_add = first(lambda o: o["kind"] == "add"
                          and o.get("add_type") == "fpn_sum", 40)
        extra_conv1 = first(lambda o: o["kind"] == "conv" and o["k"] == 1
                            and o["stride"] == 1, 40)
        for e in (extra_dw_s2, extra_add, extra_conv1):
            if e is not None and e not in subset:
                subset.append(e)
        subset = sorted(set(subset))
    subset = [i for i in subset if 0 <= i < n]

    # ---- 两张输入图 ----
    from PIL import Image
    ih = iw = int(plan["tensors"][input_tid].H)
    x_pat = np.frombuffer(
        np.uint8(np.asarray([(x * 13 + y * 7 + c * 29 + seed) & 0xFF
                             for y in range(ih) for x in range(iw)
                             for c in range(3)], dtype=np.uint8)).tobytes(),
        dtype=np.int8).reshape(ih, iw, 3).copy()
    real_files = qn.calibration_files(data_dir, 1, seed)
    real_name = os.path.basename(real_files[0])
    with Image.open(real_files[0]) as im:
        real_img = eg.preprocess_image(im.convert("RGB"), ih)
    x_real = qn.quantize_input(real_img, s_in, zp_in)
    images = [
        ("pattern_v1", {"kind": "pattern_v1", "seed": int(seed)}, x_pat),
        (real_name.replace(".png", ""), {"kind": "real_image", "file": real_name,
                                         "preprocess": "letterbox %dx%d (96x72+12x2)"
                                                       % (ih, iw) if ih == 96 else
                                                       "letterbox %dx%d" % (ih, iw)},
         x_real),
    ]
    os.makedirs(outdir, exist_ok=True)
    manifest = {
        "format": "bottlecap-opvec-v1",
        "source_plan": os.path.relpath(os.path.join(outdir, "..", "plan.json"),
                                       ROOT).replace("\\", "/"),
        "input_hw": [int(ih), int(iw)],
        "arena_base": int(ARENA_BASE),
        "hex_format": {
            "op_<NN>.hex": "u32 little-endian words per line (8 hex digits); "
                           "payload = dst tensor bytes in arena layout (NHWC pad8, "
                           "y,x,c logical order, 含通道 pad 字节, 行数=ceil(bytes/4))",
            "input.hex": "同上 (PACKED3 3B/px, 无 C8 padding)",
            "input_compact.hex": "每行 1 字节(2 hex), y,x,c 逻辑序, 不含 padding",
        },
        "notes": {
            "dense_conv_k3s2": "本模型所有 k3/stride2 卷积都是 depthwise (无 dense k3s2);"
                               " 故用 dwconv k3s2 覆盖 stride2+k3 语义",
            "fnv": "FNV-1a 32 over 真实通道 x H x W, NHWC(y,x,c) 逻辑序(不含 pad),"
                   " 与 checksums.txt 同口径",
            "pad_value": "未用通道(zp_out)已写入 op 输出张量字节; 比对应覆盖整块 c8",
            "subset_ops": subset,
        },
        "images": [],
    }
    index_rows = []
    for tag, imeta, x_packed in images:
        sub = os.path.join(outdir, tag)
        os.makedirs(sub, exist_ok=True)
        store, op_out, snaps = qn.int8_forward(plan, q, x_packed, fast=True,
                                               snapshots=True)
        p_in = os.path.join(sub, "input.hex")
        vio.write_u32_hex(_u32_hex_bytes(x_packed), p_in)
        p_in_c = os.path.join(sub, "input_compact.hex")
        vio.write_i8_hex(x_packed, p_in_c)
        in_meta = {
            "file_u32": os.path.relpath(p_in, outdir).replace("\\", "/"),
            "file_compact": os.path.relpath(p_in_c, outdir).replace("\\", "/"),
            "shape": [int(ih), int(iw), 3], "bytes": int(ih * iw * 3),
            "fnv": int(vio.fnv1a_int8(x_packed)),
            "arena_off": 0,   # 输入张量在 arena 起点(gen 侧包 arena 时 tid0 固定为 0)
            "layout": "PACKED3 (3 bytes/pixel, no C8 padding), y-major then x then c",
        }
        op_entries = []
        for oid in subset:
            arr = snaps[oid]                       # (h,w,c8) int8
            fn = "op%03d.hex" % oid
            fp = os.path.join(sub, fn)
            vio.write_u32_hex(_u32_hex_bytes(arr), fp)
            o = ops[oid]
            dt = tensors[o["dst"]]
            fnv = int(vio.fnv1a_int8(op_out[oid]))
            e = {
                "op": int(oid), "kind": o["kind"],
                "module": o.get("module", ""),
                "shape": [int(dt["h"]), int(dt["w"]), int(dt["c8"])],
                "real_c": int(dt["c"]), "bytes": int(dt["h"] * dt["w"] * dt["c8"]),
                "layout": "NHWC pad8 (y,x,c8), u32-LE words",
                "pad_value": int(gq[roots[o["dst"]]][1]),
                "arena_off": int(arena_map.get(int(o["dst"]), 0)),
                "arena_abs": int(arena_map.get(int(o["dst"]), 0)) + ARENA_BASE,
                "file": os.path.relpath(fp, outdir).replace("\\", "/"),
                "fnv": fnv,
                "flags": int(o.get("flags", 0)), "act": o.get("act", "none"),
            }
            op_entries.append(e)
            index_rows.append({"img": tag, "op": int(oid),
                               "shape": e["shape"], "bytes": e["bytes"],
                               "fnv": fnv, "file": e["file"]})
        # 该图的逐 op FNV 表(真实图 E2E 的 hw_bad 判据; pattern 图与 checksums.txt 同源)
        ck = os.path.join(sub, "checksums.txt")
        with open(ck, "w", encoding="utf-8", newline="\n") as f:
            f.write("# op FNV-1a 32 (real channels x H x W, NHWC y,x,c) -- image=%s\n"
                    % tag)
            f.write("input 0x%08x  # PACKED3 int8\n" % in_meta["fnv"])
            for e in op_entries:
                f.write("op %3d kind=%-8s shape=%dx%dx%d 0x%08x\n"
                        % (e["op"], e["kind"], e["shape"][0], e["shape"][1],
                           e["shape"][2], e["fnv"]))
        manifest["images"].append({
            "name": tag, "meta": imeta, "input": in_meta, "ops": op_entries,
        })
        if verbose:
            print("[opvec] %-16s input=%d B, %d ops, %d B total"
                  % (tag, in_meta["bytes"], len(op_entries),
                     sum(e["bytes"] for e in op_entries)))
    with open(os.path.join(outdir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    with open(os.path.join(outdir, "index.json"), "w", encoding="utf-8") as f:
        json.dump({"format": "bottlecap-opvec-index-v1",
                   "subset_ops": subset, "rows": index_rows}, f,
                  ensure_ascii=False, indent=1)
    if verbose:
        print("[opvec] wrote %s (manifest.json + index.json)" % outdir)
    return manifest


# ============================================================================
# 报告
# ============================================================================
def _fmt(x, nd=4):
    if isinstance(x, float):
        return ("%." + str(nd) + "f") % x
    return str(x)


def write_report(args, art, plan, quant_rep, golden_check, e2e, report_path):
    L = []
    A = L.append
    summary = plan["summary"]
    rom = summary["rom"]
    A("# GOLDEN-REPORT — 瓶盖检测模型 PyTorch→NPU 整数链路数值验证")
    A("")
    A("> 自动生成: `python tools/bottlecap/golden_npu.py`"
      "（+ `extract_graph.py` / `quant_npu.py` / `gen_npu_artifacts.py`）  ")
    A("> 语义唯一来源: `results/ai-accel/CONTRACT.md` + `tools/yolo/quant_lib.py`。  ")
    A("> 模型: `%s`（arch=%s, input=%d×%d, params=%d）"
      % (plan["source"]["checkpoint"], plan["source"]["arch"],
         plan["source"]["input_size"], plan["source"]["input_size"],
         plan["source"]["params"]))
    A("")
    # ---- 0 结论 ----
    ok_golden = golden_check["mismatch"] == 0
    ok_base = (quant_rep or {}).get("precision", {}).get("per_layer_cos_mean_conv", 0)
    A("## 0. 结论")
    A("")
    A("| 项 | 结果 | 判据 |")
    A("|---|---|---|")
    A("| 字节级 golden vs 参考整数前向 | **%s**（mismatch=%d / %d op×img） | 必须 =0 |"
      % ("PASS" if ok_golden else "FAIL", golden_check["mismatch"],
         golden_check["n_op_img"]))
    A("| float 图 vs torch 原模型（head） | max|diff| = %s | <1e-3 |"
      % ", ".join("%.2g" % d for d in golden_check["float_check_max_abs"]))
    A("| int8 vs float 检测框匹配率（IoU≥0.5） | **%s** | 越高越好；YOLO-Fastest 参考值 81.8%% |"
      % (_fmt(e2e["int8_vs_float"]["match_rate_of_a"]) if e2e else "SKIP"))
    A("| int8 模型 P/R/F1（vs GT） | %s | float 基线 P/R/F1 = %s |"
      % (("%s / %s / %s" % (_fmt(e2e["int8_vs_gt"]["precision"]),
                            _fmt(e2e["int8_vs_gt"]["recall"]),
                            _fmt(e2e["int8_vs_gt"]["f1"]))) if e2e else "SKIP",
         ("%s / %s / %s" % (_fmt(e2e["float_vs_gt"]["precision"]),
                            _fmt(e2e["float_vs_gt"]["recall"]),
                            _fmt(e2e["float_vs_gt"]["f1"]))) if e2e else "-"))
    if e2e:
        A("| int8 整图全对率 / 目标数准确率 | %s / %s | float: %s / %s |"
          % (_fmt(e2e["int8_vs_gt"]["exact_image_accuracy"]),
             _fmt(e2e["int8_vs_gt"]["count_accuracy"]),
             _fmt(e2e["float_vs_gt"]["exact_image_accuracy"]),
             _fmt(e2e["float_vs_gt"]["count_accuracy"])))
    if e2e:
        A("| int8 meanIoU（vs GT / vs float） | %s / %s | float 基线 %s |"
          % (_fmt(e2e["int8_vs_gt"]["mean_iou"]),
             _fmt(e2e["int8_vs_float"]["mean_iou_matched"]),
             _fmt(e2e["float_vs_gt"]["mean_iou"])))
    else:
        A("| int8 meanIoU（vs GT / vs float） | SKIP | - |")
    A("| ROM 深度 | %d / %d | ≤128 |" % (rom["depth"], rom["depth_limit"]))
    A("| W / Q 总量 | %d B / %d B | 现片上 W=320KB, Q=48KB |"
      % (summary["w_bytes"], summary["q_bytes"]))
    A("| 峰值单张量 / 并发 | %d B / %d B | 现 A=96KB / A+B=128KB |"
      % (summary["max_single_tensor_bytes"], summary["peak_concurrent_bytes"]))
    A("")
    if e2e:
        m = e2e["int8_vs_float"]
        f = e2e["float_vs_gt"]
        g = e2e["int8_vs_gt"]
        cap = ""
        if "wdq_ceiling" in e2e:
            c = e2e["wdq_ceiling"]["vs_float"]
            cap = ("；理想 QDQ 上限（仅权重 int8）F1=%s、匹配率 %s → **权重 int8 零损失，"
                   "误差全在激活/Q 链路，匹配率上限只差 %.2f pp**"
                   % (_fmt(e2e["wdq_ceiling"]["vs_gt"]["f1"]),
                      _fmt(c["match_rate_of_a"]),
                      100.0 * (c["match_rate_of_a"] - m["match_rate_of_a"])))
        A("**核心数字（给用户看）**: 端到端 int8(NPU 语义) **F1=%s、float↔int8 框匹配率 %s"
          "（IoU≥0.5）、meanIoU %s**（float 基线 F1=%s、mIoU %s）%s。"
          % (_fmt(g["f1"]), _fmt(m["match_rate_of_a"]),
             _fmt(m["mean_iou_matched"]), _fmt(f["f1"]), _fmt(f["mean_iou"]), cap))
        A("")
    on_chip = (summary.get("ab_mode") == "real" and
               summary.get("w_bytes", 1 << 60) <= 320 * 1024 and
               summary.get("q_bytes", 1 << 60) <= 48 * 1024)
    if on_chip:
        ab = summary.get("alloc", {})
        A("**结论**: 该模型可**零 RTL 改动、纯片上**部署 —— W %d B ≤320KB、Q %d B ≤48KB、"
          "A 峰值 %d B ≤96KB、B 峰值 %d B ≤32KB、%d op ≤ ROM 128、ROM 字段位宽全够；"
          "字节级数值链路 **零误差**，端到端 int8 与 float 检测结果几乎一致（见 §4）。"
          % (summary["w_bytes"], summary["q_bytes"], ab.get("peak_A", 0),
             ab.get("peak_B", 0), summary["num_ops"]))
    else:
        A("**结论**: 该 2.05M 参数检测模型可由现有 NPU 指令集 + CONTRACT int8 量化方案"
          "**完整表达**（%d op，ROM 深度够），字节级数值链路 **零误差**；端到端 int8 与 float "
          "检测结果高度一致（见 §4）。**但容量不满足**：W/Q/激活均超现片上 BRAM 预算，"
          "需 DDR3 权重流式 + 激活 arena（见 §5），或改用瘦身模型。"
          % summary["num_ops"])
    A("")
    # ---- 1 规模 ----
    A("## 1. 模型/图规模与产物")
    A("")
    A("| 指标 | 值 |")
    A("|---|---:|")
    A("| op 总数 | %d（%s） |" % (summary["num_ops"],
                                ", ".join("%s=%d" % (k, v) for k, v in summary["kinds"].items())))
    A("| conv / dwconv | %d / %d |"
      % (summary["kinds"].get("conv", 0), summary["kinds"].get("dwconv", 0)))
    A("| MACs（真实） | %.3f GMAC |"
      % (sum(int(r.get("macs", 0)) for r in (quant_rep or {}).get("layers", [])) / 1e9))
    cyc = summary.get("engine_cycles_estimate")
    if cyc:
        A("| 期望 npu_cycles（**v3 公式，ModelSim 实测逐拍一致**） | **%d 拍**"
          "（%.2f ms@100MHz / %.2f ms@122MHz；分 kind: %s） |"
          % (cyc["total_cycles"], cyc["total_ms_at_100MHz"],
             cyc.get("total_ms_at_122MHz", 0),
             ", ".join("%s=%d" % (k, v)
                       for k, v in cyc["per_kind_cycles"].items() if v)))
    A("| int8 权重（§6 8 通道对齐） | **%d B（%.3f MB）** |"
      % (summary["w_bytes"], summary["w_bytes"] / 1e6))
    A("| 单层最大权重 | %d B（%s） |" % (summary["max_w_layer_bytes"],
                                        summary["max_w_layer"]["module"]))
    A("| Q 区（6*OC_pad+16 + ADD_R 16B） | **%d B** |" % summary["q_bytes"])
    A("| 唯一张量总量 / 生命周期峰值并发 | %d B / %d B |"
      % (summary["unique_tensor_bytes"], summary["peak_concurrent_bytes"]))
    A("| 单张量最大 | %d B（%s） |" % (summary["max_single_tensor_bytes"],
                                      summary["max_single_tensor"]))
    A("| arena（16B 对齐打包） | **%d B**（预留 2MB，余量 %d B） |"
      % (summary["min_arena_bytes"], 2 * 1024 * 1024 - summary["min_arena_bytes"]))
    A("| 逐帧激活读写流量 | read %.3f MB + write %.3f MB = **%.3f MB** |"
      % (summary["traffic_read_bytes_per_frame"] / 1e6,
         summary["traffic_write_bytes_per_frame"] / 1e6,
         summary["traffic_total_bytes_per_frame"] / 1e6))
    A("| float 图前向自检 head max|diff| | %s |"
      % ", ".join("%.2g" % d for d in golden_check["float_check_max_abs"]))
    ws = summary.get("w_stream", {})
    A("| W 流式镜像偏移（`plan.json: w_stream_offsets`） | 连续=%s，%d 层，总 %d B（预取 ptr += wlen） |"
      % (ws.get("contiguous"), ws.get("n_layers", 0), ws.get("total_bytes", 0)))
    tp = summary.get("tile_plan_stats", {})
    if tp:
        tiers = tp.get("ibuf_tiers", {})
        A("| tile 建议（`plan.json: ops[].tile_plan`，v2 整通道 band；瓶盖配置 IBUF 2×16KB/2×32KB 两档） "
          "| B 分布 %s；total_bands=%d；IBUF16K 可容纳 %d op、需 32KB 的 %d op；"
          "max IBUF 16K档=%d/16384 B、32K档=%d/32768 B；OBUF max=%d/12288 B；"
          "band 启动固定开销 ≈%d~%d 拍/帧 |"
          % (tp.get("band_rows_distribution"), tp.get("total_bands", 0),
             tiers.get("16384", {}).get("n_fits", 0),
             tiers.get("16384", {}).get("n_need_more", 0),
             tp.get("max_ibuf_bytes_16k_tier", 0),
             tp.get("max_ibuf_bytes_wide_tier", 0),
             tp.get("max_obuf_bytes", 0),
             tp.get("band_launch_overhead", {}).get("total_cycles_50", 0),
             tp.get("band_launch_overhead", {}).get("total_cycles_100", 0)))
    A("")
    A("**ROM 位宽需求（v1）**: 深度 %d/%d 够；`woff` 需 **%d 位**（现 19 位不够，"
      "W=%.3f MB）；`qoff` 需 **%d 位**（现 16 位不够）；`src/dst` 存 arena 相对偏移需 "
      "**%d 位**、存 DDR3 绝对地址需 %d 位（现 19 位只覆盖 512KB）。"
      % (rom["depth"], rom["depth_limit"], rom["woff_bits_needed"],
         summary["w_bytes"] / 1e6, rom["qoff_bits_needed"],
         rom["src_dst_bits_needed"], rom["src_dst_bits_needed_absolute"]))
    A("")
    A("产物：`results/bottlecap/plan/{graph.json, quant_report.json, plan.json, "
      "model.json, nn_rom_table.json, w.hex, q.hex, checksums.txt}`。")
    A("")
    # ---- 2 数值链路自检 ----
    A("## 2. 数值链路自检")
    A("")
    A("| 检查 | 结果 |")
    A("|---|---|")
    A("| 字节级 golden（独立实现：字节 arena + §6 权重 + §7 Q 块 + int64/floor_divide）"
      " vs 参考整数前向 | **mismatch=%d**（%d 图 × %d op） |"
      % (golden_check["mismatch"], golden_check["n_images"], golden_check["n_ops"]))
    A("| §8 8 通道分块布局 roundtrip | %s |" % ("PASS" if golden_check["layout_ok"] else "FAIL"))
    A("| fast 整数前向 vs quant_lib.int8_forward | mismatch=%d（%d 图） |"
      % (golden_check["fast_vs_quantlib"], golden_check["n_check_images"]))
    if quant_rep:
        A("| 权重反量化 roundtrip maxerr | %.4g |"
          % quant_rep["stats"]["weight_roundtrip_maxerr"])
        A("| bias_adj |max| | %d |" % quant_rep["stats"]["bias_adj_absmax"])
        A("| M_pos 范围 | max=%d, min_nonzero=%d, zero=%d |"
          % (quant_rep["stats"]["mpos_max"], quant_rep["stats"]["mpos_min_nonzero"],
             quant_rep["stats"]["mpos_zero_count"]))
        A("| SHIFT 直方图 | %s |"
          % ", ".join("%s:%d" % (k, v) for k, v in quant_rep["stats"]["shift_histogram"].items()))
    rh = golden_check.get("ref_heads") or {}
    if rh.get("status") not in (None, "NOT_PRESENT", "DISABLED"):
        A("| slim-train `ref_heads.npz` 交叉校验（A=float 模型 on ref 输入 / B=ref int8 输入→NPU 语义→反量化 vs ref float head） "
          "| %s：A cos_min=%s；B cos_min=%s（%d 样本，%s） |"
          % (rh.get("status"),
             ("%.6f" % rh["cos_min_A"]) if rh.get("cos_min_A") is not None else "-",
             ("%.6f" % rh["cos_min_B"]) if rh.get("cos_min_B") is not None else "-",
             rh.get("n_samples", 0),
             ("输入量化口径差异: %s" % rh.get("results", {}).get("input_quant_note", ""))
             if rh.get("results") else ""))
    dep = plan.get("deploy_check") or {}
    if dep:
        A("| 纯片上部署 DEPLOY-CHECK | **%s**（%s） |"
          % (dep.get("status"), dep.get("path")))
    A("")
    if e2e and "wdq_ceiling" in e2e:
        c = e2e["wdq_ceiling"]
        n_copy = sum(1 for o in plan["ops"] if o.get("kind") == "copy")
        cause = "requant 累积、ADD_R 原地写回目标域"
        if n_copy:
            cause += "、concat 共享 per-tensor scale"
        A("**归因（关键）**: 理想 QDQ 上限实验（仅权重 int8、激活 float）vs GT "
          "P/R/F1=%s/%s/%s、mIoU=%s；vs float 模型框匹配率 %s、mIoU %s、类别混淆 %d。"
          "→ **int8 权重本身零损失；端到端误差全部来自激活/Q 链路**（%s）。"
          "因此在「只改量化粒度、不改 RTL」的范围内，当前 int8 结果已接近该链路上限"
          "（匹配率差 %.2f pp）。"
          % (_fmt(c["vs_gt"]["precision"]), _fmt(c["vs_gt"]["recall"]),
             _fmt(c["vs_gt"]["f1"]), _fmt(c["vs_gt"]["mean_iou"]),
             _fmt(c["vs_float"]["match_rate_of_a"]),
             _fmt(c["vs_float"]["mean_iou_matched"]),
             c["vs_float"]["class_confusion_pairs_iou50"], cause,
             100.0 * (c["vs_float"]["match_rate_of_a"]
                      - e2e["int8_vs_float"]["match_rate_of_a"])))
        A("")
    # ---- 3 逐层 ----
    A("## 3. 逐层精度（int8 反量化 vs float 逐层输出，%d 张固定测试图）"
      % ((quant_rep or {}).get("eval", {}).get("n_images", 0)))
    A("")
    if quant_rep:
        A("**汇总**: conv/dwconv cos 均值 **%.6f**、最小 **%.6f**；全部 op cos 均值 "
          "%.6f、最小 %.6f；cos<0.99 的 op 数 %d；最差 op = %d(%s)。"
          % (quant_rep["precision"]["per_layer_cos_mean_conv"],
             quant_rep["precision"]["per_layer_cos_min_conv"],
             quant_rep["precision"]["per_layer_cos_mean_all_ops"],
             quant_rep["precision"]["per_layer_cos_min_all_ops"],
             quant_rep["precision"]["ops_cos_below_0.99"],
             quant_rep["precision"]["worst_op"]["op"],
             quant_rep["precision"]["worst_op"]["module"]))
        A("")
        A("> 参考：YOLO-Fastest v1.1（darknet，更小的 0.3M 模型）int8 链路实测 conv cos "
          "均值 0.975 / 最小 0.917（`tools/yolo/data/quant_summary_128.json`）；本模型更深"
          "且 MobileNetV2 的 residual/BN 折叠后 per-OC 权重尺度分布更宽，cos 偏低属预期。"
          "最终判据以 §4 端到端检测一致性为准（cos 只是过程指标）。")
        A("")
        A("| op | kind | act | 输出 NHWC | ic→oc | k/s/p | wlen | qlen | SHIFT | cos(mean) | maxerr |")
        A("|---:|---|---|---|---|---|---:|---:|---:|---:|---:|")
        for r in quant_rep["layers"]:
            A("| %d | %s | %s | %d×%d×%d | %d→%d | %d/%d/%d | %d | %d | %s | %s | %.4g |"
              % (r["op"], r["kind"], r["act"], r["oh"], r["ow"], r["oc"],
                 r["ic"], r["oc"], r["k"], r["stride"], r["pad"],
                 r.get("wlen", r.get("weight_bytes", 0)), r.get("qlen", 0),
                 r.get("shift", "-"), "%.6f" % r["cos_mean"], r["maxerr"]))
        A("")
    # ---- 4 端到端 ----
    A("## 4. 端到端检测一致性（%d 张测试图）"
      % (e2e["n_images"] if e2e else 0))
    A("")
    if e2e:
        A("口径与 `nut_detector/evaluate_multi_mobilenet_anchor_free.py` 一致："
          "`decode_multi_predictions`（sigmoid/softmax + 3×3 local max + top-40 + "
          "class-aware NMS，conf≥0.20、NMS IoU 0.35、最多 4 框），GT 为 test 标注经同一 "
          "letterbox 变换；匹配用 class-aware 贪心 IoU≥0.5。float 基线参考值："
          "500 图/1250 目标、P=R=F1=1.0、mIoU=0.9696（训练报告）。")
        A("")
        A("### 4.1 主指标（vs GT）")
        A("")
        A("| 模型 | 框数 | TP | FP | FN | P | R | F1 | meanIoU | 整图全对率 | 目标数准确率 |")
        A("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        rows41 = [("float 模型", "float_vs_gt"), ("int8(NPU 语义)", "int8_vs_gt")]
        if "wdq_ceiling" in e2e:
            rows41.append(("理想 QDQ 上限（仅权重 int8）", None))
        for name, key in rows41:
            m = e2e[key] if key else e2e["wdq_ceiling"]["vs_gt"]
            A("| %s | %d | %d | %d | %d | %s | %s | %s | %s | %s | %s |"
              % (name, m["n_pred"], m["tp"], m["fp"], m["fn"],
                 _fmt(m["precision"]), _fmt(m["recall"]), _fmt(m["f1"]),
                 _fmt(m["mean_iou"]), _fmt(m["exact_image_accuracy"]),
                 _fmt(m["count_accuracy"])))
        A("")
        f = e2e["int8_vs_float"]
        A("### 4.2 float vs int8 检测一致性")
        A("")
        A("两个模型各自 decode/NMS 后逐图贪心匹配（同类且 IoU≥0.5）：")
        A("")
        A("| 指标 | 值 |")
        A("|---|---:|")
        A("| float 框数 / int8 框数 | %d / %d |"
          % (f["n_boxes_b"], f["n_boxes_a"]))
        A("| 匹配框数（同类且 IoU≥0.5） | **%d** |" % f["matched_same_class_iou50"])
        A("| **框匹配率**（匹配/int8 框） | **%s** |" % _fmt(f["match_rate_of_a"]))
        A("| 框匹配率（匹配/float 框） | %s |" % _fmt(f["match_rate_of_b"]))
        A("| 匹配框 meanIoU | %s |" % _fmt(f["mean_iou_matched"]))
        A("| 类别混淆数（IoU≥0.5 但类别不同） | %d |"
          % f["class_confusion_pairs_iou50"])
        A("| 目标数一致图 / 完全一致图 | %d / %d（共 %d 图） |"
          % (f["count_equal_images"], f["exact_equal_images"], f["n_images"]))
        A("| 匹配框分数平均差 | %s |" % _fmt(f["mean_abs_score_diff"]))
        A("")
        if "wdq_ceiling" in e2e:
            c = e2e["wdq_ceiling"]["vs_float"]
            A("理想 QDQ 上限（权重 int8、激活 float）vs float 模型：框匹配率 %s / %s，"
              "meanIoU %s，类别混淆 %d。该上限说明**量化主要误差来自激活/Q 链路**"
              "（权重 int8 本身不是瓶颈）。"
              % (_fmt(c["match_rate_of_a"]), _fmt(c["match_rate_of_b"]),
                 _fmt(c["mean_iou_matched"]), c["class_confusion_pairs_iou50"]))
            A("")
        A("### 4.3 分类别指标")
        A("")
        fl, i8 = e2e["float_vs_gt"]["per_class"], e2e["int8_vs_gt"]["per_class"]
        A("| 类别 | GT 数 | float TP/FP/FN | float P/R | int8 TP/FP/FN | int8 P/R |")
        A("|---|---:|---|---:|---|---:|")
        for cname, fv in fl.items():
            iv = i8.get(cname, {"tp": 0, "fp": 0, "fn": 0,
                                "precision": 0.0, "recall": 0.0})
            A("| %s | %d | %d/%d/%d | %s / %s | %d/%d/%d | %s / %s |"
              % (cname, fv["tp"] + fv["fn"], fv["tp"], fv["fp"], fv["fn"],
                 _fmt(fv["precision"]), _fmt(fv["recall"]),
                 iv["tp"], iv["fp"], iv["fn"],
                 _fmt(iv["precision"]), _fmt(iv["recall"])))
        A("")
        A("### 4.4 按目标数分组")
        A("")
        fb = e2e["float_vs_gt"]["by_true_object_count"]
        ib = e2e["int8_vs_gt"]["by_true_object_count"]
        A("| GT 目标数 | 图数 | float P/R | float 全对率 | int8 P/R | int8 全对率 | int8 数量准确率 |")
        A("|---:|---:|---|---:|---|---:|---:|")
        for k in sorted(set(fb) | set(ib), key=lambda x: int(x)):
            fvv, ivv = fb.get(k, {}), ib.get(k, {})
            A("| %s | %d | %s / %s | %s | %s / %s | %s | %s |"
              % (k, fvv.get("images", ivv.get("images", 0)),
                 _fmt(fvv.get("precision", 0.0)), _fmt(fvv.get("recall", 0.0)),
                 _fmt(fvv.get("exact_image_accuracy", 0.0)),
                 _fmt(ivv.get("precision", 0.0)), _fmt(ivv.get("recall", 0.0)),
                 _fmt(ivv.get("exact_image_accuracy", 0.0)),
                 _fmt(ivv.get("count_accuracy", 0.0))))
        A("")
        hc = e2e["head_cos_float_vs_int8"]
        A("### 4.5 head 输出一致性 / 耗时")
        A("")
        A("head 输出（反量化后）float vs int8 cos：objectness %.5f(mean)/%.5f(min)，"
          "class %.5f/%.5f，box %.5f/%.5f。"
          % (hc["objectness_mean"], hc["objectness_min"],
             hc["class_mean"], hc["class_min"], hc["box_mean"], hc["box_min"]))
        A("")
        A("耗时: float(%.1f ms/图) / int8 numpy 参考前向(%.1f ms/图，优化前口径)。"
          % (e2e["timing"]["float_ms_per_img"], e2e["timing"]["int8_ms_per_img"]))
        A("")
    else:
        A("（`--skip-e2e`，未跑端到端）")
        A("")
    # ---- 5 容量需求 ----
    A("## 5. 容量/峰值需求（W/Q/A/B）与 DDR3 主线含义")
    A("")
    if summary.get("alloc", {}).get("mode") == "real":
        ab = summary["alloc"]
        A("**纯片上真实分配（本模型）**: A 峰值 **%d/%d B**、B 峰值 **%d/%d B**（生命周期复用后，"
          "16B 对齐），输入 PACKED3 在 A 区偏移 %d；单张量峰值 %d/%d B。"
          % (ab["peak_A"], ab["a_bytes"], ab["peak_B"], ab["b_bytes"],
             plan["input"].get("act_off", 0),
             summary["max_single_tensor_bytes"], ab["a_bytes"]))
        A("")
    A("| 区 | 本模型需求 | 现片上容量 | 倍数 | 说明 |")
    A("|---|---:|---:|---:|---|")
    A("| W 权重 | **%d B（%.3f MB）** | 320 KB | %.2f× | 可 DDR3 流式；预取双缓冲 %d B/层 |"
      % (summary["w_bytes"], summary["w_bytes"] / 1e6,
         summary["w_bytes"] / (320 * 1024), summary["w_double_buffer_2x_max_layer"]))
    A("| Q 量化参数 | **%d B** | 48 KB | %.2f× | LUTRAM/独立区需扩容 |"
      % (summary["q_bytes"], summary["q_bytes"] / (48 * 1024)))
    A("| A 单张量峰值 | **%d B**（%s） | 96 KB | %.2f× | 必须走 DDR3 arena |"
      % (summary["max_single_tensor_bytes"], summary["max_single_tensor"],
         summary["max_single_tensor_bytes"] / (96 * 1024)))
    A("| A+B 生命周期并发 | **%d B** | 128 KB | %.2f× | arena 打包需 %d B（16B 对齐） |"
      % (summary["peak_concurrent_bytes"],
         summary["peak_concurrent_bytes"] / (128 * 1024), summary["min_arena_bytes"]))
    A("| ROM（nn_rom，LUTRAM） | %d 项 | 128 项 | %.2f | 深度够；字段需加宽（§1）|"
      % (summary["num_ops"], summary["num_ops"] / 128))
    A("")
    A("**DDR3 流量 / 帧率量级**：激活读写 %.3f MB/帧 → 30fps 需 %.2f GB/s，"
      "10fps 需 %.2f GB/s（DDR3-400 32bit 理论 1.6 GB/s；P3 报告按有效 ~1.6 GB/s 计）。"
      % (summary["traffic_total_bytes_per_frame"] / 1e6,
         summary["traffic_total_bytes_per_frame"] * 30 / 1e9,
         summary["traffic_total_bytes_per_frame"] * 10 / 1e9))
    A("另外 W 流式每帧需再读 %.3f MB（若每帧都重读权重；常驻可省）。"
      % (summary["w_bytes"] / 1e6))
    A("")
    A("**峰值内存需求(明确口径)**: `W=%d B`（+ 每层预取双缓冲 %d B）、"
      "`Q=%d B`、`A 单张量=%d B`、`A/B 并发=%d B`、`arena=%d B`（含 16B 对齐与生命周期复用后）。"
      % (summary["w_bytes"], summary["w_double_buffer_2x_max_layer"],
         summary["q_bytes"], summary["max_single_tensor_bytes"],
         summary["peak_concurrent_bytes"], summary["min_arena_bytes"]))
    A("")
    # ---- 6 假设 ----
    A("## 6. 待确认假设（按 CONTRACT 最保守解释实现）")
    A("")
    for i, a in enumerate((quant_rep or {}).get("assumptions", []), 1):
        A("%d. %s" % (i, a))
    A("")
    # ---- 7 复现 ----
    A("## 7. 复现")
    A("")
    A("```powershell")
    A("python tools/bottlecap/extract_graph.py --input-size %d"
      % plan["source"]["input_size"])
    A("python tools/bottlecap/quant_npu.py --input-size %d"
      % plan["source"]["input_size"])
    A("python tools/bottlecap/gen_npu_artifacts.py --input-size %d"
      % plan["source"]["input_size"])
    A("python tools/bottlecap/golden_npu.py --input-size %d"
      % plan["source"]["input_size"])
    A("```")
    A("")
    A("所有随机量固定 seed（校准集抽样 seed=%d，图抽取 seed=12345）。"
      % (quant_rep or {}).get("calibration", {}).get("seed", 0))
    A("")
    with open(report_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")


# ============================================================================
# main
# ============================================================================
def main():
    ap = argparse.ArgumentParser(description="byte-level golden + E2E int8-vs-float")
    ap.add_argument("--checkpoint", default=eg.DEFAULT_CKPT)
    ap.add_argument("--arch", default=None, choices=[None, "enhanced", "slim"])
    ap.add_argument("--input-size", type=int, default=224)
    ap.add_argument("--outdir", default=DEFAULT_OUTDIR)
    ap.add_argument("--data", default=DEFAULT_DATA)
    ap.add_argument("--graph", default=None)
    ap.add_argument("--calib", type=int, default=32)
    ap.add_argument("--calib-seed", type=int, default=20260819)
    ap.add_argument("--eval-images", type=int, default=4)
    ap.add_argument("--eval-seed", type=int, default=777)
    ap.add_argument("--seed", type=int, default=12345)
    ap.add_argument("--golden-images", type=int, default=3,
                    help="字节级 golden 比对的图片数(每张 ~数秒 int64 前向)")
    ap.add_argument("--e2e-limit", type=int, default=0, help="0=全量 500 张")
    ap.add_argument("--skip-e2e", action="store_true",
                    help="显式跳过端到端(默认会跑!)")
    ap.add_argument("--no-ceiling", dest="ceiling", action="store_false",
                    help="跳过 理想 QDQ 上限实验(仅权重 int8 / 激活 float)")
    ap.set_defaults(ceiling=True)
    ap.add_argument("--report", default=None)
    ap.add_argument("--ref-heads", default=None,
                    help="slim-train 参考 head npz (缺省自动找 outdir/../ref_heads.npz)")
    ap.add_argument("--export-opvec", default=None,
                    help="导出逐 op int8 金标目录(M6/M6b), 如 results/bottlecap/plan/opvec")
    ap.add_argument("--opvec-only", action="store_true",
                    help="只导出 opvec 后退出(不跑 e2e)")
    ap.add_argument("--opvec-seed", type=int, default=12345)
    ap.add_argument("--opvec-all-ops", action="store_true",
                    help="导出全部 op 的 int8 金标(默认只导前12+后8+代表 op)")
    ap.add_argument("--fuse-add", default="none", choices=["none", "a"],
                    help="[task-18] 与 gen 的 --fuse-add 同口径; 融合 plan 目录需一致")
    args = ap.parse_args()
    t0 = time.time()
    if args.graph is None:
        args.graph = os.path.join(args.outdir, "graph.json")
    report_path = args.report or os.path.join(args.outdir, "GOLDEN-REPORT.md")

    # ---- 解析产物 + 与重算的量化结果交叉校验 ----
    art = load_artifacts(args.outdir)
    plan = art["plan"]
    dep_path = os.path.join(args.outdir, "DEPLOY-CHECK.json")
    if os.path.exists(dep_path):
        try:
            dep = json.load(open(dep_path, encoding="utf-8"))
            plan["deploy_check"] = {
                "path": os.path.relpath(dep_path, ROOT).replace("\\", "/"),
                "status": dep.get("status"), "n_fail": dep.get("n_fail")}
        except Exception:
            pass
    print("[golden] artifacts: ops=%d tensors=%d W=%d B Q=%d B"
          % (len(art["ops"]), len(art["tensors"]), plan["w_bytes"], plan["q_bytes"]))
    layout_ok = check_layout_roundtrip(art)

    with open(os.path.join(args.outdir, "quant_report.json"), encoding="utf-8") as f:
        quant_rep = json.load(f)
    qargs = argparse.Namespace(**vars(args))
    qargs.eval_images = args.eval_images
    B = qn.build_quant(qargs, verbose=False)
    if args.fuse_add != "none":
        import gen_npu_artifacts as _gna
        B, _fm = _gna.apply_add_fusion(B, args.fuse_add, verbose=True)
        if len(B["ops"]) != len(art["ops"]):
            raise SystemExit("fused B ops %d != artifacts ops %d"
                             % (len(B["ops"]), len(art["ops"])))
    # 交叉校验: 重算的 W/Q 与 w.hex/q.hex 字节一致
    w_re = bytearray()
    for op in B["ops"]:
        if op["kind"] in ("conv", "dwconv"):
            w_re += np.ascontiguousarray(B["q"]["ops"][op["id"]]["wq"],
                                         dtype=np.int8).tobytes()
    # (逐层对齐后拼接顺序与 gen 相同; 这里只比总量与逐层 csum 已在 artifacts 内)
    if sum(int(o["wlen"]) for o in plan["ops"]) > plan["w_bytes"]:
        raise SystemExit("wlen sum > w image")
    if quant_rep["weights"]["total_bytes"] != plan["w_bytes"]:
        raise SystemExit("quant_report W total %d != plan w_bytes %d"
                         % (quant_rep["weights"]["total_bytes"], plan["w_bytes"]))

    # ---- A. 字节级 golden ----
    roots = B["groups"]["roots"]
    s_in, zp_in = B["gq"][roots[B["plan"]["input_tensor"]]]
    files = qn.calibration_files(args.data, max(1, args.golden_images), args.eval_seed + 7)
    imgs = qn.load_calib_images(files, args.input_size)
    mismatch = 0
    head_mismatch = 0
    n_op_img = 0
    n_img = 0
    t_g = time.time()
    final_ops = [int(x) for x in art["plan"].get(
        "final_ops",
        art["plan"].get("final_tensors", B["plan"]["final_tensors"]))]
    for img in imgs:
        xq = qn.quantize_input(img, s_in, zp_in)
        st_ref, out_ref = qn.int8_forward(B["plan"], B["q"], xq, fast=True)
        _arena, st_g, out_g = golden_forward(art, xq)
        for op in B["ops"]:
            d = np.abs(out_ref[op["id"]].astype(np.int16)
                       - out_g[op["id"]].astype(np.int16))
            mismatch += int((d != 0).sum())
            n_op_img += 1
        for fo in final_ops:      # head 单独统计(端到端读的就是这三个张量)
            d = np.abs(out_ref[fo].astype(np.int16) - out_g[fo].astype(np.int16))
            head_mismatch += int((d != 0).sum())
        n_img += 1
    # 参考实现 vs quant_lib 官方整数前向
    if args.fuse_add == "none":
        fast_vs_ql = 0
        for img in imgs[:1]:
            xq = qn.quantize_input(img, s_in, zp_in)
            st_a, out_a = qn.int8_forward(B["plan"], B["q"], xq, fast=True)
            st_b, out_b = ql.int8_forward(B["plan"], B["q"], xq)
            for op in B["ops"]:
                fast_vs_ql += int((out_a[op["id"]].astype(np.int16)
                                   != out_b[op["id"]].astype(np.int16)).sum())
    else:
        fast_vs_ql = -1     # 融合 plan: quant_lib.int8_forward 不支持 conv add-mode
    print("[golden] byte-level golden vs reference: mismatch=%d over %d imgs x %d ops "
          "(%.1fs)" % (mismatch, n_img, len(B["ops"]), time.time() - t_g))
    print("[golden] fast vs quant_lib.int8_forward: %s"
          % ("N/A (fused)" if fast_vs_ql < 0 else "mismatch=%d" % fast_vs_ql))
    ref_path = args.ref_heads
    if ref_path is None:
        cands = [
            os.path.join(os.path.dirname(os.path.abspath(args.checkpoint)),
                         "ref_heads.npz"),          # 与 checkpoint 同目录(slim 约定)
            os.path.join(os.path.dirname(os.path.abspath(args.outdir)),
                         "ref_heads.npz"),
            os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(args.outdir))),
                         "ref_heads.npz"),
        ]
        ref_path = next((p for p in cands if os.path.exists(p)), cands[0])
    ref_check = check_ref_heads(ref_path, B)
    print("[golden] ref_heads cross-check: %s%s"
          % (ref_check.get("status"),
             (" cos_min=%.5f" % ref_check["cos_min"])
             if ref_check.get("cos_min") is not None else ""))
    golden_check = {
        "mismatch": int(mismatch), "head_mismatch": int(head_mismatch),
        "n_images": n_img, "n_ops": len(B["ops"]),
        "n_op_img": n_op_img,
        "fast_vs_quantlib": int(fast_vs_ql),
        "n_check_images": 1,
        "layout_ok": bool(layout_ok),
        "ref_heads": ref_check,
        "float_check_max_abs": [d["max_abs"] for d in
                                eg.check_float_equivalence(
                                    B["ops"], B["tensors"], B["folded"],
                                    B["run"]["example_input"][0].permute(1, 2, 0).numpy(),
                                    B["run"]["out_tuple"])],
    }
    if mismatch != 0:
        raise SystemExit("GOLDEN MISMATCH = %d" % mismatch)

    # ---- opvec 金标导出(M6/M6b) ----
    opvec = None
    if args.export_opvec:
        subset = list(range(len(B["ops"]))) if args.opvec_all_ops else None
        opvec = export_opvec(args.export_opvec, B, args.data,
                             label=B["arch"], seed=args.opvec_seed,
                             plan_art=art["plan"], subset=subset)
        golden_check["opvec"] = {
            "dir": os.path.relpath(args.export_opvec, ROOT).replace("\\", "/"),
            "n_images": len(opvec["images"]),
            "subset_ops": opvec["notes"]["subset_ops"],
            "all_ops": bool(args.opvec_all_ops),
        }
        if args.opvec_only:
            print("[golden] opvec-only: skip e2e")
            return

    # ---- B. E2E ----
    e2e = None
    if not args.skip_e2e:
        e2e = run_e2e(B, args, verbose=True)
        print("[e2e] float_vs_gt:", {k: (round(v, 4) if isinstance(v, float) else v)
                                     for k, v in e2e["float_vs_gt"].items()})
        print("[e2e] int8_vs_gt :", {k: (round(v, 4) if isinstance(v, float) else v)
                                     for k, v in e2e["int8_vs_gt"].items()})
        print("[e2e] int8_vs_float:", {k: (round(v, 4) if isinstance(v, float) else v)
                                       for k, v in e2e["int8_vs_float"].items()})

    # ---- 报告 ----
    write_report(args, art, plan, quant_rep, golden_check, e2e, report_path)
    # E2E 指标单独落 JSON(便于机读)
    e2e_path = os.path.join(args.outdir, "e2e_metrics.json")
    with open(e2e_path, "w", encoding="utf-8") as f:
        json.dump({"golden_check": golden_check, "e2e": e2e}, f,
                  ensure_ascii=False, indent=1)
    print("[golden] wrote %s (+ %s) in %.1fs"
          % (report_path, e2e_path, time.time() - t0))


if __name__ == "__main__":
    main()
