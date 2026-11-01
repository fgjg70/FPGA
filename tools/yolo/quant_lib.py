#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""int8 PTQ + bit-exact integer inference for YOLO-Fastest v1.1.

Implements CONTRACT v0.3.1:
  * conv weights: per-OC symmetric int8, BN folded first;
    w_q = clamp(round(W'/s_w), -127, 127), s_w[oc] = max|W'[oc]|/127
  * activations: per-tensor(=per linked group) int8;
    s_a = (max-min)/255, zp_a = -128 - round(min/s_a)   (q range [-128,127])
    groups joined by pool / upsample / add / cpu_concat share (s_a, zp_a)
  * accumulation: acc = sum(a_q*w_q) + bias_adj,  int64
    bias_adj[oc] = round(b'/(s_a_in*s_w)) - zp_in*sum(w_q)
  * requant (per layer SHIFT, floor):
      M_pos[oc] = round(s_a_in*s_w/s_a_out * 2**SHIFT)          (int16)
      M_neg[oc] = (M_pos*3277 + 16384) >> 15                    (engine computes)
      y = (acc>=0 ? acc*M_pos : acc*M_neg) >> SHIFT ; out = clip(y + zp_out)
    linear layers use M_pos for both branches.
  * Q payload (v0.3.1): bias_adj int32[OC_pad] | M_pos int16[OC_pad] | tail 16B
    = 6*OC_pad+16 bytes, 16B-aligned variable offsets (plan.json qoff)
  * conv padding pixels = zp_in (CONTRACT §11)

`int8_forward` is the vectorised reference model (used by quantize.py/plan-gen),
`golden_forward` is an independently coded integer forward (per-ic / per-oc
scalar-vector loops, floor_divide instead of shift) that must match it bit
exactly (mismatch == 0).
"""
import json

import numpy as np

from darknet_lib import SHIFT, cos_sim

Q_TAIL_BYTES = 16


def rnd(x):
    """round-half-up (floor(x+0.5)); bit-exact counterpart to __? in HW."""
    return np.floor(np.asarray(x, dtype=np.float64) + 0.5)


# ----------------------------------------------------------------------------
# activation groups (share s_a / zp_a)
# ----------------------------------------------------------------------------
def build_groups(plan):
    n = len(plan["tensors"])
    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    add_pairs = []
    for op in plan["ops"]:
        k = op["kind"]
        if k in ("pool", "upsample", "copy"):
            # exact int8 transfer / max => both sides must share (s_a, zp_a)
            union(op["src"], op["dst"])
        elif k in ("add", "cpu_add"):
            # v0.6 ADD_R: src/dst keep their OWN per-tensor scale/zp; the
            # per-tensor source requant scalar R maps src domain -> dst.
            add_pairs.append((op["src"], op["dst"]))
        elif k == "cpu_concat":
            for s in op["sources"]:
                union(s["t"], op["dst"])
    roots = [find(t) for t in range(n)]
    # v0.5: cpu_add maps src->dst with a per-tensor requant scalar, so the two
    # operands do NOT need a shared/symmetric quantisation domain anymore.
    add_roots = set()
    groups = {}
    for t in range(n):
        groups.setdefault(roots[t], []).append(t)
    return {"roots": roots, "groups": groups, "add_roots": add_roots}


# ----------------------------------------------------------------------------
# calibration
# ----------------------------------------------------------------------------
def calibrate_groups(net, folded, plan, images, collect_values=False):
    """images: list of (H,W,3) float32 in [0,1] (letterboxed).

    collect_values=True keeps all activation samples per group so that
    percentile-clipped calibration ranges can be used (heavy-tailed leaky
    activations make raw min/max quantisation very coarse).
    """
    from darknet_lib import forward_float_torch
    g = build_groups(plan)
    rmin = {}
    rmax = {}
    vals = {}

    def upd(root, o):
        vals.setdefault(root, []).append(np.asarray(o, dtype=np.float32).ravel())
        rmin[root] = min(rmin.get(root, np.inf), float(o.min()))
        rmax[root] = max(rmax.get(root, -np.inf), float(o.max()))

    input_tid = plan["input_tensor"]
    for img in images:
        upd(g["roots"][input_tid], img)
        outs = forward_float_torch(net, folded, img)
        for op in plan["ops"]:
            o = outs[op["layer_idx"]]
            upd(g["roots"][op["dst"]], o)
    cal = {"groups": g, "min": rmin, "max": rmax}
    if collect_values:
        cal["values"] = {r: np.concatenate(v) for r, v in vals.items()}
    return cal


def choose_group_quants(cal, verbose=True, clip_pct=100.0):
    """Pick (s_a, zp_a) per activation group (CONTRACT v0.3.1 §5).

    clip_pct < 100 clips the calibration range to that percentile before
    computing s_a (outliers are saturated by the int8 clamp at requant time).
    """
    g = cal["groups"]
    gq = {}
    zero_range = 0
    vals = cal.get("values")
    for root in g["groups"]:
        if vals is not None and clip_pct < 100.0:
            v = vals[root]
            lo_p = (100.0 - clip_pct) / 2.0
            mn = float(np.percentile(v, lo_p))
            mx = float(np.percentile(v, 100.0 - lo_p))
            if mx <= mn:
                mn, mx = cal["min"].get(root, 0.0), cal["max"].get(root, 1.0)
        else:
            mn = cal["min"].get(root, 0.0)
            mx = cal["max"].get(root, 1.0)
        if root in g["add_roots"]:
            # raw int8 add needs both operands' zp == 0 -> symmetric quant
            m = max(abs(mn), abs(mx))
            s = m / 127.0 if m > 0 else 1.0
            zp = 0
        else:
            rng = mx - mn
            if rng <= 0:
                zero_range += 1
                s = (abs(mx) / 127.0) if mx != 0 else 1.0
                zp = 0
            else:
                s = rng / 255.0
                zp = int(np.clip(-128 - int(rnd(mn / s)), -128, 127))
        gq[root] = (float(s), int(zp))
    if verbose:
        print("choose_group_quants: %d groups (%d add-linked symmetric, %d zero-range)"
              % (len(gq), len(g["add_roots"]), zero_range))
    return gq


# ----------------------------------------------------------------------------
# weight quantisation + Q payload
# ----------------------------------------------------------------------------
def pad_weight_layout(wq, op):
    """Return the CONTRACT §6 padded weight byte array for one conv op.

    dense : [tap][IC_pad][OC_pad]     dw: [tap][OC_pad]
    """
    k = op["k"]
    k2 = k * k
    oc = op["oc"]
    oc_pad = (oc + 7) // 8 * 8
    if op["depthwise"]:
        out = np.zeros((k2, oc_pad), dtype=np.int8)
        for tap in range(k2):
            out[tap, :oc] = wq[:, tap]
        return out
    ic_pad = (op["ic"] + 7) // 8 * 8
    out = np.zeros((k2, ic_pad, oc_pad), dtype=np.int8)
    icg = wq.shape[1]
    for tap in range(k2):
        ky, kx = divmod(tap, k)
        out[tap, :icg, :oc] = wq[:, :, ky, kx].T  # (icg, oc)
    return out


def quantize_model(net, folded, plan, cal, gq, verbose=True, w_clip_pct=100.0):
    """Compute per-conv int8 weights, bias_adj, M_pos, per-layer SHIFT.

    Returns dict: {'ops': {op_id: params...}, 'groups': {...}, 'stats': {...}}
    """
    g = cal["groups"]
    roots = g["roots"]
    out_ops = {}
    stats = {"mpos_max": 0, "mpos_min_nonzero": 1 << 60, "shifts": {},
             "bias_max": 0, "mzero": 0, "neg_zero": 0, "zps": set()}
    for op_id, op in enumerate(plan["ops"]):
        if op["kind"] not in ("conv", "dwconv", "cpu_conv0"):
            continue
        L = folded[op["layer_idx"]]
        W = L["W"].astype(np.float64)      # (oc, icg, k, k)
        b = L["b"].astype(np.float64)      # (oc,)
        oc = op["oc"]
        oc_pad = (oc + 7) // 8 * 8
        # per-OC symmetric weight scale
        Wabs = np.abs(W).reshape(oc, -1)
        if w_clip_pct < 100.0:
            absmax = np.percentile(Wabs, w_clip_pct, axis=1)
        else:
            absmax = Wabs.max(axis=1)
        s_w = np.where(absmax > 0, absmax / 127.0, 1.0)
        wq_f = rnd(W / s_w[:, None, None, None])
        wq = np.clip(wq_f, -127, 127).astype(np.int8)
        if op["depthwise"]:
            wq_layout = pad_weight_layout(wq.reshape(oc, op["k"] * op["k"]), op)
        else:
            wq_layout = pad_weight_layout(wq, op)
        s_in, zp_in = gq[roots[op["src"]]]
        s_out, zp_out = gq[roots[op["dst"]]]
        # ---- bias_adj (CONTRACT v0.3.1 §5) ----
        sum_w = wq.astype(np.int64).reshape(oc, -1).sum(axis=1)   # per oc
        bias_adj_f = b / (s_in * s_w)
        bias_adj = (rnd(bias_adj_f).astype(np.int64) - int(zp_in) * sum_w)
        if bias_adj.size:
            imax = int(np.abs(bias_adj).max())
            stats["bias_max"] = max(stats["bias_max"], imax)
        bias_pad = np.zeros(oc_pad, dtype=np.int64)
        bias_pad[:oc] = bias_adj
        if np.any(np.abs(bias_pad) >= (1 << 31)):
            raise ValueError("bias_adj overflows int32 at op %d" % op_id)
        # ---- per-layer SHIFT + M_pos (int16) ----
        # v0.3.1 allows a per-layer SHIFT (tail[3]).  Choose the LARGEST SHIFT
        # that still fits M_pos in int16: more fractional bits => the per-OC
        # requant multiplier rounding error (0.5/M) becomes negligible even for
        # layers whose weights/activation ranges make M tiny at SHIFT=16.
        # acc*M stays well inside int64 (acc <= 2^25, M <= 2^15).
        shift = SHIFT
        while shift < 24:
            m_next = rnd(s_in * s_w / s_out * float(1 << (shift + 1))).astype(np.int64)
            if int(m_next.max()) > 32767:
                break
            shift += 1
        mpos = rnd(s_in * s_w / s_out * float(1 << shift)).astype(np.int64)
        if int(mpos.max()) > 32767 or int(mpos.max()) <= 0:
            raise ValueError("cannot fit M_pos in int16 for op %d (max %d)"
                             % (op_id, int(mpos.max())))
        if np.any(mpos == 0):
            stats["mzero"] += int((mpos == 0).sum())
        nz = mpos[mpos > 0]
        if nz.size:
            stats["mpos_min_nonzero"] = min(stats["mpos_min_nonzero"], int(nz.min()))
        if mpos.size:
            stats["mpos_max"] = max(stats["mpos_max"], int(mpos.max()))
        stats["shifts"][shift] = stats["shifts"].get(shift, 0) + 1
        leaky = int(op["leaky"])
        mneg = ((mpos * 3277 + 16384) >> 15).astype(np.int64)
        if leaky and np.any(mneg[mpos > 0] == 0):
            stats["neg_zero"] += 1
        mpos_pad = np.zeros(oc_pad, dtype=np.int64)
        mpos_pad[:oc] = mpos
        # ---- Q payload bytes (v0.3.1) ----
        tail = np.zeros(Q_TAIL_BYTES, dtype=np.uint8)
        tail[0] = zp_out & 0xFF
        tail[1] = zp_in & 0xFF
        tail[2] = leaky
        tail[3] = shift
        payload = (bias_pad.astype("<i4").tobytes()
                   + mpos_pad.astype("<i2").tobytes()
                   + tail.tobytes())
        assert len(payload) == 6 * oc_pad + 16
        out_ops[op_id] = {
            "op_id": op_id, "layer_idx": op["layer_idx"], "kind": op["kind"],
            "wq": wq_layout, "wq_real": wq, "bias_adj": bias_pad,
            "mpos": mpos_pad, "mpos_real": mpos, "mneg_real": mneg,
            "shift": shift, "leaky": leaky,
            "s_in": s_in, "zp_in": int(zp_in), "s_out": s_out, "zp_out": int(zp_out),
            "s_w": s_w, "oc": oc, "oc_pad": oc_pad,
            "ic": op["ic"], "ic_pad": (op["ic"] + 7) // 8 * 8,
            "k": op["k"], "stride": op["stride"], "pad": op["pad"],
            "depthwise": op["depthwise"], "payload": np.frombuffer(payload, dtype=np.uint8).copy(),
        }

    # ---- v0.6 ADD_R: per-tensor source-requant scalar R = round(s_s/s_d*2^K) --
    adds = {}
    for op_id, op in enumerate(plan["ops"]):
        if op["kind"] not in ("add", "cpu_add"):
            continue
        src, dst = op["src"], op["dst"]
        s_s, zp_s = gq[roots[src]]
        s_d, zp_d = gq[roots[dst]]
        ratio = s_s / s_d
        k = 15
        while k < 24 and int(rnd(ratio * (1 << k))) < 256:
            k += 1
        while k > 8 and int(rnd(ratio * (1 << k))) > (1 << 20):
            k -= 1
        r = int(rnd(ratio * (1 << k)))
        if r < 1:
            raise ValueError("cpu_add op %d: R rounds to 0 (ratio %.3g)" % (op_id, ratio))
        if r > (1 << 20):
            raise ValueError("cpu_add op %d: R %d > 2^20" % (op_id, r))
        # v0.7 ADD_R Q block (16 B, CONTRACT §12.3):
        #   [0]=zp_s [1]=zp_d(debug) [2:3]=R u16 LE [4]=KADD [5:15]=0
        if r > 0xFFFF:
            raise ValueError("add op %d: R=%d does not fit u16" % (op_id, r))
        payload = np.zeros(16, dtype=np.uint8)
        payload[0] = int(zp_s) & 0xFF
        payload[1] = int(zp_d) & 0xFF
        payload[2:4] = np.frombuffer(np.uint16(r).tobytes(), dtype=np.uint8)
        payload[4] = int(k) & 0xFF
        adds[op_id] = {"r_scale": r, "k_add": int(k), "zp_s": int(zp_s),
                       "zp_d": int(zp_d), "s_s": float(s_s), "s_d": float(s_d),
                       "ratio": float(ratio), "payload": payload}
        stats.setdefault("adds", []).append((op_id, r, int(k), int(zp_s),
                                             int(zp_d)))
        if verbose:
            print("  add op%-3d R=%-7d K=%-2d zp_s=%-4d zp_d=%-4d s_s=%.6g s_d=%.6g"
                  % (op_id, r, k, zp_s, zp_d, s_s, s_d))

    if verbose:
        print("quantize_model: %d conv ops, SHIFT histogram %s, M_pos max %d, "
              "min nonzero %d, bias|max| %d"
              % (len(out_ops), stats["shifts"], stats["mpos_max"],
                 stats["mpos_min_nonzero"], stats["bias_max"]))
        if stats["mzero"]:
            print("  WARNING: %d M_pos values rounded to 0" % stats["mzero"])
    return {"ops": out_ops, "adds": adds, "groups": g, "gq": gq,
            "stats": stats}


# ----------------------------------------------------------------------------
# integer forward: vectorised reference (quantize.py / plan generation)
# ----------------------------------------------------------------------------
def _xp_pad(x, pad, zp_in):
    if pad == 0:
        return x
    return np.pad(x, ((pad, pad), (pad, pad), (0, 0)), constant_values=zp_in)


def _requant_vec(acc, mpos, mneg, shift, leaky, zp_out):
    pos = np.right_shift(acc * mpos[None, None, :], shift)
    if leaky:
        neg = np.right_shift(acc * mneg[None, None, :], shift)
        y = np.where(acc >= 0, pos, neg)
    else:
        y = pos
    return np.clip(y + zp_out, -128, 127).astype(np.int8)


def _conv_vec(x, p, zp_in):
    """x: (H,W,ic_pad) int8 -> (oh,ow,oc_pad) int8."""
    k, s, pad = p["k"], p["stride"], p["pad"]
    k2 = k * k
    H, W, ic_pad = x.shape
    oc_pad = p["oc_pad"]
    xp = _xp_pad(x, pad, zp_in)
    oh = (H + 2 * pad - k) // s + 1
    ow = (W + 2 * pad - k) // s + 1
    if p["depthwise"]:
        acc = np.zeros((oh, ow, oc_pad), dtype=np.int64)
        for tap in range(k2):
            ky, kx = divmod(tap, k)
            patch = xp[ky:ky + (oh - 1) * s + 1:s, kx:kx + (ow - 1) * s + 1:s, :]
            acc += patch.astype(np.int64) * p["wq"][tap][None, None, :].astype(np.int64)
    else:
        acc_f = np.zeros((oh * ow, oc_pad), dtype=np.int64)
        for tap in range(k2):
            ky, kx = divmod(tap, k)
            patch = xp[ky:ky + (oh - 1) * s + 1:s, kx:kx + (ow - 1) * s + 1:s, :]
            acc_f += patch.reshape(oh * ow, ic_pad).astype(np.int64) @ p["wq"][tap].astype(np.int64)
        acc = acc_f.reshape(oh, ow, oc_pad)
    acc += p["bias_adj"][None, None, :]
    mneg = ((p["mpos"] * 3277 + 16384) >> 15) if p["leaky"] else p["mpos"]
    return _requant_vec(acc, p["mpos"], mneg, p["shift"], p["leaky"], p["zp_out"])


def _pool_vec(x, op, zp):
    k, s, pad = op["k"], op["stride"], op["pad"]
    H, W, C = x.shape
    xp = np.pad(x, ((pad, pad), (pad, pad), (0, 0)), constant_values=-128)
    oh = (H + 2 * pad - k) // s + 1
    ow = (W + 2 * pad - k) // s + 1
    out = np.full((oh, ow, C), -128, dtype=np.int8)
    for tap in range(k * k):
        ky, kx = divmod(tap, k)
        patch = xp[ky:ky + (oh - 1) * s + 1:s, kx:kx + (ow - 1) * s + 1:s, :]
        out = np.maximum(out, patch)
    return out



def int8_forward(plan, q, x_packed):
    """Vectorised integer forward over a plan v0.6.

    x_packed: (H,W,ic) int8 input image (3 bytes/pixel, packed; conv0=PACKED3).
    Returns (store, op_out): store[tid] = padded int8 tensor, op_out[op_id] =
    real-channel output of that op (H,W,C); for `copy` ops it is the written
    channel slice (H,W,ic).
    """
    tensors = plan["tensors"]
    ops = plan["ops"]
    store = {}
    itid = plan["input_tensor"]
    store[itid] = x_packed
    op_out = {}
    roots = q["groups"]["roots"]
    gq = q["gq"]
    for op_id, op in enumerate(ops):
        kind = op["kind"]
        flags = int(op.get("flags", 0))
        if kind in ("conv", "dwconv", "cpu_conv0"):
            p = q["ops"][op_id]
            src = store[op["src"]]
            packed = (kind == "cpu_conv0") or (flags & 4) or bool(op.get("packed3"))
            if packed:
                H, W, ic = src.shape
                ic_pad = (ic + 7) // 8 * 8
                x = np.full((H, W, ic_pad), p["zp_in"], dtype=np.int8)
                x[:, :, :ic] = src
            else:
                x = src
            y = _conv_vec(x, p, p["zp_in"])
            dst_t = tensors[op["dst"]]
            out = np.full((dst_t.H, dst_t.W, dst_t.C8), p["zp_out"], dtype=np.int8)
            out[:, :, :op["oc"]] = y[:, :, :op["oc"]]
        elif kind == "pool":
            y = _pool_vec(store[op["src"]], op, gq[roots[op["dst"]]][1])
            dst_t = tensors[op["dst"]]
            out = y[:, :, :dst_t.C8].copy()
        elif kind == "upsample":
            s = store[op["src"]]
            out = np.repeat(np.repeat(s, 2, axis=0), 2, axis=1)
        elif kind in ("add", "cpu_add"):
            # ADD_R: out = clamp(q_d + (((q_s-zp_s)*R) >> KADD), -128, 127)
            a = q["adds"][op_id]
            cur = store[op["dst"]]
            src = store[op["src"]]
            out = cur.copy()
            c = op["ic"]
            qi = src[:, :, :c].astype(np.int64) - int(a["zp_s"])
            d = np.right_shift(qi * int(a["r_scale"]), int(a["k_add"]))
            out[:, :, :c] = np.clip(cur[:, :, :c].astype(np.int64) + d,
                                    -128, 127).astype(np.int8)
        elif kind == "copy":
            src = store[op["src"]]
            dst_t = tensors[op["dst"]]
            if op["dst"] in store:
                out = store[op["dst"]].copy()
            else:
                out = np.full((dst_t.H, dst_t.W, dst_t.C8),
                              gq[roots[op["dst"]]][1], dtype=np.int8)
            cs = int(op.get("c_src", 0))
            cd = int(op.get("c_dst", 0))
            c = op["ic"]
            out[:, :, cd:cd + c] = src[:, :, cs:cs + c]
        elif kind == "cpu_concat":
            dst_t = tensors[op["dst"]]
            out = np.full((dst_t.H, dst_t.W, dst_t.C8),
                          gq[roots[op["dst"]]][1], dtype=np.int8)
            coff = 0
            for s in op["sources"]:
                c = s["c"]
                out[:, :, coff:coff + c] = store[s["t"]][:, :, :c]
                coff += c
        else:
            raise ValueError(kind)
        store[op["dst"]] = out
        if kind == "copy":
            cd = int(op.get("c_dst", 0))
            c = op["ic"]
            op_out[op_id] = out[:, :, cd:cd + c]
        else:
            op_out[op_id] = out[:, :, :tensors[op["dst"]].C]
    return store, op_out


def _conv_golden(x, p, zp_in):
    k, s, pad = p["k"], p["stride"], p["pad"]
    k2 = k * k
    H, W, ic_pad = x.shape
    oc_pad = p["oc_pad"]
    oc = p["oc"]
    xp = np.full((H + 2 * pad, W + 2 * pad, ic_pad), zp_in, dtype=np.int8)
    xp[pad:pad + H, pad:pad + W, :] = x
    oh = (H + 2 * pad - k) // s + 1
    ow = (W + 2 * pad - k) // s + 1
    acc = np.zeros((oh, ow, oc_pad), dtype=np.int64)
    if p["depthwise"]:
        for tap in range(k2):
            ky, kx = divmod(tap, k)
            patch = xp[ky:ky + (oh - 1) * s + 1:s, kx:kx + (ow - 1) * s + 1:s, :]
            w_tap = p["wq"][tap]
            for c in range(oc_pad):
                acc[:, :, c] += patch[:, :, c].astype(np.int64) * int(w_tap[c])
    else:
        for tap in range(k2):
            ky, kx = divmod(tap, k)
            patch = xp[ky:ky + (oh - 1) * s + 1:s, kx:kx + (ow - 1) * s + 1:s, :]
            w_tap = p["wq"][tap]
            for icc in range(ic_pad):
                col = patch[:, :, icc].reshape(oh, ow, 1).astype(np.int64)
                acc += col * w_tap[icc][None, None, :].astype(np.int64)
    for c in range(oc_pad):
        acc[:, :, c] += int(p["bias_adj"][c])
    mpos = p["mpos"]
    mneg = ((p["mpos"] * 3277 + 16384) >> 15) if p["leaky"] else p["mpos"]
    y = np.empty((oh, ow, oc_pad), dtype=np.int64)
    den = 1 << p["shift"]
    for c in range(oc_pad):
        prod_pos = acc[:, :, c] * int(mpos[c])
        prod_neg = acc[:, :, c] * int(mneg[c])
        y[:, :, c] = np.where(acc[:, :, c] >= 0,
                              np.floor_divide(prod_pos, den),
                              np.floor_divide(prod_neg, den))
    y += int(p["zp_out"])
    y = np.clip(y, -128, 127).astype(np.int8)
    out = np.full((oh, ow, oc_pad), p["zp_out"], dtype=np.int8)
    out[:, :, :oc] = y[:, :, :oc]
    return out


def _pool_golden(x, op):
    k, s, pad = op["k"], op["stride"], op["pad"]
    H, W, C = x.shape
    xp = np.full((H + 2 * pad, W + 2 * pad, C), -128, dtype=np.int8)
    xp[pad:pad + H, pad:pad + W, :] = x
    oh = (H + 2 * pad - k) // s + 1
    ow = (W + 2 * pad - k) // s + 1
    out = np.full((oh, ow, C), -128, dtype=np.int8)
    for yyy in range(oh):
        for xxx in range(ow):
            blk = xp[yyy * s:yyy * s + k, xxx * s:xxx * s + k, :]
            out[yyy, xxx, :] = blk.reshape(-1, C).max(axis=0)
    return out



def golden_forward(plan, q, x_packed):
    """Independent integer golden forward (plan v0.6: PACKED3 / ADD_R / copy).

    Deliberately coded differently from int8_forward (per-channel loops +
    np.floor_divide for ADD_R; explicit numpy copyto for copy).
    """
    tensors = plan["tensors"]
    ops = plan["ops"]
    store = {plan["input_tensor"]: x_packed}
    op_out = {}
    roots = q["groups"]["roots"]
    gq = q["gq"]
    for op_id, op in enumerate(ops):
        kind = op["kind"]
        flags = int(op.get("flags", 0))
        if kind in ("conv", "dwconv", "cpu_conv0"):
            p = q["ops"][op_id]
            src = store[op["src"]]
            packed = (kind == "cpu_conv0") or (flags & 4) or bool(op.get("packed3"))
            if packed:
                H, W, ic = src.shape
                ic_pad = (ic + 7) // 8 * 8
                x = np.full((H, W, ic_pad), p["zp_in"], dtype=np.int8)
                x[:, :, :ic] = src
            else:
                x = src
            out = _conv_golden(x, p, p["zp_in"])
        elif kind == "pool":
            out = _pool_golden(store[op["src"]], op)
        elif kind == "upsample":
            s = store[op["src"]]
            out = np.repeat(np.repeat(s, 2, axis=0), 2, axis=1)
        elif kind in ("add", "cpu_add"):
            a = q["adds"][op_id]
            cur = store[op["dst"]]
            src = store[op["src"]]
            out = cur.copy()
            R = int(a["r_scale"])
            K = int(a["k_add"])
            zps = int(a["zp_s"])
            den = 1 << K
            for c in range(op["ic"]):
                qi = src[:, :, c].astype(np.int64) - zps
                d = np.floor_divide(qi * R, den)   # independent of the >> path
                out[:, :, c] = np.clip(cur[:, :, c].astype(np.int64) + d,
                                       -128, 127).astype(np.int8)
        elif kind == "copy":
            src = store[op["src"]]
            dst_t = tensors[op["dst"]]
            if op["dst"] in store:
                out = store[op["dst"]].copy()
            else:
                out = np.full((dst_t.H, dst_t.W, dst_t.C8),
                              gq[roots[op["dst"]]][1], dtype=np.int8)
            cs = int(op.get("c_src", 0))
            cd = int(op.get("c_dst", 0))
            c = op["ic"]
            for ch in range(c):
                np.copyto(out[:, :, cd + ch], src[:, :, cs + ch])
        elif kind == "cpu_concat":
            dst_t = tensors[op["dst"]]
            out = np.full((dst_t.H, dst_t.W, dst_t.C8),
                          gq[roots[op["dst"]]][1], dtype=np.int8)
            coff = 0
            for s in op["sources"]:
                for ch in range(s["c"]):
                    np.copyto(out[:, :, coff + ch], store[s["t"]][:, :, ch])
                coff += s["c"]
        else:
            raise ValueError(kind)
        store[op["dst"]] = out
        if kind == "copy":
            cd = int(op.get("c_dst", 0))
            c = op["ic"]
            op_out[op_id] = out[:, :, cd:cd + c]
        else:
            op_out[op_id] = out[:, :, :tensors[op["dst"]].C]
    return store, op_out



def dequantize(q_arr, s, zp):
    return s * (q_arr.astype(np.float64) - float(zp))


def op_real_shape(op, tensor):
    """Real (H,W,C) shape of an op's output (copy = the written channel slice)."""
    k = op["kind"]
    if k in ("conv", "dwconv", "cpu_conv0"):
        return (op["oh"], op["ow"], op["oc"])
    if k == "pool":
        return (op["oh"], op["ow"], op["ic"])
    if k == "upsample":
        return (op["oh"], op["ow"], op["ic"])
    if k in ("add", "cpu_add"):
        return (op["ih"], op["iw"], op["ic"])
    if k == "copy":
        return (op["ih"], op["iw"], op["ic"])
    if k in ("cpu_concat", "cpu_copy"):
        return (op["ih"], op["iw"], op.get("oc_tensor", op["oc"]))
    raise ValueError(k)
