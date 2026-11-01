#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""YOLO-Fastest v1.1 (darknet) core library.

Contains, in one place, everything that defines the *model*:

  * darknet cfg parser + layer shape inference (darknet semantics: pad=1 means
    size/2, maxpool padding = (size-1)/2, [dropout] occupies a layer index,
    [route]/[shortcut] layer indices are resolved relative to the current
    layer index);
  * official .weights reader (fp32 stream; per conv: bias, then BN
    scales/mean/var, then weights) with a hard byte-count assertion;
  * BN folding to (W', b');
  * primitive-level execution plan (per CONTRACT §10.1) + buffer allocation
    into A/B (128 KB each) + W/Q byte offsets (CONTRACT §6/§7);
  * float reference forward in PyTorch AND an independent numpy float64
    forward (used to cross-check the re-implementation, cos >= 0.9999);
  * MAC / weight-byte / peak-activation accounting.

The int8 quantisation lives in quant_lib.py; this file is resolution
parametric (build_net(cfg, in_h, in_w)).
"""
import math
import os

import numpy as np

BN_EPS = 1e-5          # darknet default for batch_normalize
SHIFT = 16             # CONTRACT §5
Q_BASE = 0x50000       # CONTRACT v0.3.1 §3: Q 区起始绝对偏移 (W 320KB)
Q_BYTES = 48 * 1024    # v0.3.1: Q 区 48KB（packed 变长 qoff, 16B 对齐）
W_BYTES = 0x50000      # 320 KB
A_BASE = 0x60000       # CONTRACT v0.3.1 §3
B_BASE = 0x78000       # v0.3.2 proposal: A=96KB(0x60000..0x78000), B=32KB
A_SIZE = 96 * 1024     # v0.3.2 proposal: A must hold the 24ch@64x64 tensor
B_SIZE = 32 * 1024     # (98,304 B) of layer 9 at 128x128 input


# ----------------------------------------------------------------------------
# cfg parsing
# ----------------------------------------------------------------------------
def parse_cfg(path):
    """Return list of dicts: {'type': str, 'params': {k: v}}; [net] first."""
    out = []
    cur = None
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith(";"):
                continue
            if line.startswith("["):
                if cur is not None:
                    out.append(cur)
                cur = {"type": line.strip("[] ").strip().lower(), "params": {}}
            else:
                if cur is None:
                    continue
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cur["params"][k.strip()] = v.strip()
    if cur is not None:
        out.append(cur)
    return out


def _pi(p, key, default=0):
    return int(p[key]) if key in p else default


def _ps(p, key, default="linear"):
    return p[key] if key in p else default


def build_net(cfg_path, in_h, in_w):
    """Parse cfg and infer every layer's shape at the given input size.

    Returns dict with:
      cfg_path, input (h,w,c=3), layers: list of dicts with idx and shapes
      (ic/ih/iw/oc/oh/ow, k, stride, pad, groups, depthwise, bn, activation,
      out=(C,H,W)), plus type-specific fields.
    """
    raw = parse_cfg(cfg_path)
    if not raw or raw[0]["type"] != "net":
        raise ValueError("cfg must start with [net]")
    netp = raw[0]["params"]
    train_h = _pi(netp, "height", 320)
    train_w = _pi(netp, "width", 320)
    layers = []
    prev_shape = (3, in_h, in_w)
    for i, r in enumerate(raw[1:]):
        typ = r["type"]
        p = r["params"]
        L = {"idx": i, "type": typ, "params": p, "prev": i - 1}
        if typ == "convolutional":
            oc = _pi(p, "filters")
            k = _pi(p, "size", 1)
            stride = _pi(p, "stride", 1)
            padflag = _pi(p, "pad", 0)
            pad = k // 2 if padflag else 0
            groups = _pi(p, "groups", 1)
            bn = _pi(p, "batch_normalize", 0)
            act = _ps(p, "activation")
            ic, ih, iw = prev_shape
            oh = (ih + 2 * pad - k) // stride + 1
            ow = (iw + 2 * pad - k) // stride + 1
            if oh <= 0 or ow <= 0:
                raise ValueError("layer %d degenerate output shape" % i)
            dw = (groups == ic == oc and groups > 1)
            if not dw:
                assert ic % groups == 0, "layer %d: ic %% groups != 0" % i
            L.update(ic=ic, oc=oc, ih=ih, iw=iw, oh=oh, ow=ow, k=k,
                     stride=stride, pad=pad, groups=groups, bn=bn,
                     depthwise=dw, activation=act)
            L["out"] = (oc, oh, ow)
        elif typ == "maxpool":
            size = _pi(p, "size", 1)
            stride = _pi(p, "stride", size)
            pad = (size - 1) // 2          # darknet default
            ic, ih, iw = prev_shape
            oh = (ih + 2 * pad - size) // stride + 1
            ow = (iw + 2 * pad - size) // stride + 1
            L.update(ic=ic, oc=ic, ih=ih, iw=iw, oh=oh, ow=ow, k=size,
                     stride=stride, pad=pad, groups=1, depthwise=False,
                     bn=0, activation="linear")
            L["out"] = (ic, oh, ow)
        elif typ == "upsample":
            stride = _pi(p, "stride", 2)
            ic, ih, iw = prev_shape
            L.update(ic=ic, oc=ic, ih=ih, iw=iw, oh=ih * stride, ow=iw * stride,
                     k=0, stride=stride, pad=0, groups=1, depthwise=False,
                     bn=0, activation="linear")
            L["out"] = (ic, ih * stride, iw * stride)
        elif typ == "route":
            targets = [int(x) for x in p["layers"].replace(" ", "").split(",") if x != ""]
            resolved = []
            for t in targets:
                resolved.append(i + t if t < 0 else t)
            assert "groups" not in p, "route groups unsupported in this model"
            refs = [layers[j] for j in resolved]
            for rr in refs:
                assert (rr["out"][1], rr["out"][2]) == (refs[0]["out"][1], refs[0]["out"][2]), \
                    "route layer %d refs spatial mismatch" % i
            oc = sum(rr["out"][0] for rr in refs)
            L.update(ic=prev_shape[0], oc=oc, ih=prev_shape[1], iw=prev_shape[2],
                     oh=prev_shape[1], ow=prev_shape[2], k=0, stride=1, pad=0,
                     groups=1, depthwise=False, bn=0, activation="linear",
                     input_layers=resolved)
            L["out"] = (oc, prev_shape[1], prev_shape[2])
        elif typ == "shortcut":
            fr = int(p["from"])
            resolved = i + fr if fr < 0 else fr
            assert 0 <= resolved < i
            ref = layers[resolved]
            assert ref["out"] == prev_shape, "shortcut %d shape mismatch" % i
            act = _ps(p, "activation")
            assert act == "linear", "shortcut activation must be linear here"
            L.update(ic=prev_shape[0], oc=prev_shape[0], ih=prev_shape[1], iw=prev_shape[2],
                     oh=prev_shape[1], ow=prev_shape[2], k=0, stride=1, pad=0,
                     groups=1, depthwise=False, bn=0, activation=act,
                     from_layer=resolved)
            L["out"] = prev_shape
        elif typ == "dropout":
            L.update(ic=prev_shape[0], oc=prev_shape[0], ih=prev_shape[1], iw=prev_shape[2],
                     oh=prev_shape[1], ow=prev_shape[2], k=0, stride=1, pad=0,
                     groups=1, depthwise=False, bn=0, activation="linear")
            L["out"] = prev_shape
        elif typ == "yolo":
            cls = _pi(p, "classes", 80)
            num = _pi(p, "num", 3)
            mask = [int(x) for x in p.get("mask", "").replace(" ", "").split(",") if x]
            anchors = [float(x) for x in p.get("anchors", "").replace(" ", "").split(",") if x]
            n_eff = len(mask)
            assert prev_shape[0] == n_eff * (cls + 5), "yolo layer %d channel mismatch" % i
            L.update(ic=prev_shape[0], oc=prev_shape[0], ih=prev_shape[1], iw=prev_shape[2],
                     oh=prev_shape[1], ow=prev_shape[2], k=0, stride=1, pad=0,
                     groups=1, depthwise=False, bn=0, activation="linear",
                     classes=cls, num=num, mask=mask, anchors=anchors,
                     scale_x_y=float(p.get("scale_x_y", 1.0)))
            L["out"] = prev_shape
        else:
            raise ValueError("unsupported layer type %s at %d" % (typ, i))
        layers.append(L)
        prev_shape = L["out"]
    return {"cfg_path": cfg_path, "input": (in_h, in_w, 3),
            "train_size": (train_h, train_w), "layers": layers}


# ----------------------------------------------------------------------------
# weights
# ----------------------------------------------------------------------------
def conv_layers(net):
    return [L for L in net["layers"] if L["type"] == "convolutional"]


def weight_float_counts(net):
    """Total fp32 floats in the official .weights stream + per-layer spec."""
    total = 0
    specs = []
    for L in conv_layers(net):
        oc, icg, k2 = L["oc"], L["ic"] // L["groups"], L["k"] * L["k"]
        n = oc
        if L["bn"]:
            n += 3 * oc
        n += oc * icg * k2
        specs.append((L["idx"], n))
        total += n
    return total, specs


def load_weights(net, path):
    """Read official .weights (fp32 little-endian raw stream).

    Order per conv layer: bias[oc] (always), then if batch_normalize:
    scales[oc], rolling_mean[oc], rolling_var[oc], then weights
    (oc, ic/groups, k, k) in darknet layout [oc][ic][ky][kx].
    Hard-fails unless the byte count exactly consumes the file.
    """
    size = os.path.getsize(path)
    need, specs = weight_float_counts(net)
    # AlexeyAB darknet .weights files may start with a 20-byte header:
    #   int32 major, int32 minor, int32 revision, uint64 seen
    with open(path, "rb") as fh:
        head = fh.read(20)
    major, minor, revision = np.frombuffer(head[:12], dtype="<i4")
    seen = int(np.frombuffer(head[12:20], dtype="<u8")[0])
    header_bytes = 0
    if 0 <= major < 1000 and 0 <= minor < 1000 and (major * 10 + minor) >= 2:
        header_bytes = 20
        print("weights header: major=%d minor=%d revision=%d seen=%d (skip 20 B)"
              % (major, minor, revision, seen))
    assert size - header_bytes == need * 4, \
        "weights size mismatch: file %d B (header %d), cfg says %d floats = %d B" % (
            size, header_bytes, need, need * 4)
    buf = np.fromfile(path, dtype="<f4")[header_bytes // 4:]
    raw = {}
    off = 0
    for L in conv_layers(net):
        oc, icg, k2 = L["oc"], L["ic"] // L["groups"], L["k"] * L["k"]
        r = {}
        r["bias"] = np.array(buf[off:off + oc], dtype=np.float32)
        off += oc
        if L["bn"]:
            r["gamma"] = np.array(buf[off:off + oc], dtype=np.float32); off += oc
            r["mean"] = np.array(buf[off:off + oc], dtype=np.float32); off += oc
            r["var"] = np.array(buf[off:off + oc], dtype=np.float32); off += oc
        r["w"] = np.array(buf[off:off + oc * icg * k2], dtype=np.float32).reshape(oc, icg, L["k"], L["k"])
        off += oc * icg * k2
        raw[L["idx"]] = r
    assert off == need
    return raw


# NOTE: darknet .weights for a BN conv stores: biases(=BN beta), scales(=gamma),
# rolling_mean, rolling_var.  There is no separate conv bias in the file.
def fold_bn(net, raw):
    folded = {}
    bn_beta_is_bias = True
    for L in conv_layers(net):
        r = raw[L["idx"]]
        w = r["w"].astype(np.float64)
        if L["bn"]:
            gamma = r["gamma"].astype(np.float64)
            mean = r["mean"].astype(np.float64)
            var = r["var"].astype(np.float64)
            beta = r["bias"].astype(np.float64)   # BN beta
            inv = gamma / np.sqrt(var + BN_EPS)
            w = w * inv[:, None, None, None]
            b = beta - mean * inv
        else:
            b = r["bias"].astype(np.float64)
            bn_beta_is_bias = bn_beta_is_bias and False
        folded[L["idx"]] = {"W": w.astype(np.float32), "b": b.astype(np.float32)}
    return folded


# ----------------------------------------------------------------------------
# execution plan (CONTRACT §10.1)
# ----------------------------------------------------------------------------
class Tensor:
    __slots__ = ("id", "H", "W", "C", "C8", "nbytes", "def_op", "last_use",
                 "region", "off", "group", "packed", "freed")

    def __init__(self, tid, H, W, C, packed=False):
        self.id = tid
        self.H = H
        self.W = W
        self.C = C
        self.packed = packed
        self.C8 = C if packed else (C + 7) // 8 * 8
        self.nbytes = H * W * self.C8
        self.def_op = -1
        self.last_use = -1
        self.region = None
        self.off = None
        self.group = tid
        self.freed = False



def plan_ops(net, input_is_A0=True):
    """Build the primitive-level op list and tensor graph (plan v0.6, all hardware).

    Ops: conv | dwconv | pool | upsample | add | copy   (**no CPU-executed op**)

      * conv0: kind "conv" + flags bit2 (PACKED3) reads the 3B/px packed input
        tensor; weights stay dense (IC_pad=8, the 5 extra IC weights are 0);
      * shortcut: kind "add" + flags bit3 (ADD_R) = engine per-tensor residual
        add: out = clamp(q_d + (((q_s-zp_s)*R)>>KADD), -128,127); Q block 16 B
        (numerically identical to the v0.5 CPU `cpu_add`);
      * route/concat: expanded into one `copy` op per source tensor.  Engine
        copy semantics: ic = source channels, oc = target total channels; the
        src/dst **byte** offsets already include the 8-channel block offset.

    flags (4 bit, mirrors SPEC-SPECIALIZED.md §1):
      bit0 depthwise, bit1 leaky, bit2 PACKED3, bit3 ADD_R.
    """
    tensors = []
    layer_tensor = {}
    ops = []
    final_ops = []

    def new_tensor(H, W, C, packed=False):
        t = Tensor(len(tensors), H, W, C, packed=packed)
        tensors.append(t)
        return t.id

    in_h, in_w, in_c = net["input"]
    in_tid = new_tensor(in_h, in_w, in_c, packed=True)
    tensors[in_tid].region = "A"
    tensors[in_tid].off = 0
    tensors[in_tid].def_op = -1
    input_tensor = in_tid

    def prev_tid(i):
        return layer_tensor[i - 1] if i > 0 else input_tensor

    for L in net["layers"]:
        i = L["idx"]
        typ = L["type"]
        if typ == "convolutional":
            src = prev_tid(i)
            dst = new_tensor(L["oh"], L["ow"], L["oc"])
            kind = "dwconv" if L["depthwise"] else "conv"
            packed3 = (i == 0)
            flags = (1 if L["depthwise"] else 0) | \
                    (2 if L["activation"] == "leaky" else 0) | \
                    (4 if packed3 else 0)
            op = {"kind": kind, "layer_idx": i, "src": src, "dst": dst,
                  "k": L["k"], "stride": L["stride"], "pad": L["pad"],
                  "leaky": 1 if L["activation"] == "leaky" else 0,
                  "ih": L["ih"], "iw": L["iw"], "ic": L["ic"],
                  "oh": L["oh"], "ow": L["ow"], "oc": L["oc"],
                  "depthwise": bool(L["depthwise"]), "flags": flags,
                  "packed3": bool(packed3)}
            ops.append(op)
            tensors[dst].def_op = len(ops) - 1
            layer_tensor[i] = dst
        elif typ == "maxpool":
            src = prev_tid(i)
            dst = new_tensor(L["oh"], L["ow"], L["oc"])
            op = {"kind": "pool", "layer_idx": i, "src": src, "dst": dst,
                  "k": L["k"], "stride": L["stride"], "pad": L["pad"],
                  "leaky": 0, "ih": L["ih"], "iw": L["iw"], "ic": L["ic"],
                  "oh": L["oh"], "ow": L["ow"], "oc": L["oc"],
                  "depthwise": False, "flags": 0}
            ops.append(op)
            tensors[dst].def_op = len(ops) - 1
            layer_tensor[i] = dst
        elif typ == "upsample":
            src = prev_tid(i)
            dst = new_tensor(L["oh"], L["ow"], L["oc"])
            op = {"kind": "upsample", "layer_idx": i, "src": src, "dst": dst,
                  "k": 2, "stride": 2, "pad": 0, "leaky": 0,
                  "ih": L["ih"], "iw": L["iw"], "ic": L["ic"],
                  "oh": L["oh"], "ow": L["ow"], "oc": L["oc"],
                  "depthwise": False, "flags": 0}
            ops.append(op)
            tensors[dst].def_op = len(ops) - 1
            layer_tensor[i] = dst
        elif typ == "route":
            refs = [layer_tensor[j] for j in L["input_layers"]]
            if len(refs) == 1:
                # single-source route: pure alias, no data movement
                layer_tensor[i] = refs[0]
            else:
                # v0.6: concat = one hardware `copy` op per source tensor
                dst = new_tensor(L["oh"], L["ow"], L["oc"])
                c_dst = 0
                first = True
                for j in L["input_layers"]:
                    tid = layer_tensor[j]
                    c = tensors[tid].C
                    op = {"kind": "copy", "layer_idx": i, "src": tid, "dst": dst,
                          "c_src": 0, "c_dst": c_dst,
                          "k": 0, "stride": 1, "pad": 0, "leaky": 0,
                          "ih": L["ih"], "iw": L["iw"], "ic": c,
                          "oh": L["oh"], "ow": L["ow"], "oc": L["oc"],
                          "depthwise": False, "flags": 0}
                    ops.append(op)
                    if first:
                        tensors[dst].def_op = len(ops) - 1
                        first = False
                    c_dst += c
                layer_tensor[i] = dst
        elif typ == "shortcut":
            src = prev_tid(i)
            dst = layer_tensor[L["from_layer"]]
            op = {"kind": "add", "layer_idx": i, "src": src, "dst": dst,
                  "k": 0, "stride": 1, "pad": 0, "leaky": 0,
                  "ih": L["ih"], "iw": L["iw"], "ic": L["ic"],
                  "oh": L["oh"], "ow": L["ow"], "oc": L["oc"],
                  "depthwise": False, "flags": 8}
            ops.append(op)
            layer_tensor[i] = dst
        elif typ == "dropout":
            layer_tensor[i] = prev_tid(i)
        elif typ == "yolo":
            head_tid = prev_tid(i)
            final_ops.append(tensors[head_tid].def_op)
            L["head_tensor"] = head_tid
        else:
            raise ValueError(typ)
    for k, op in enumerate(ops):
        if op.get("src") is not None:
            tensors[op["src"]].last_use = max(tensors[op["src"]].last_use, k)
        else:
            for s in op.get("sources", []):
                tensors[s["t"]].last_use = max(tensors[s["t"]].last_use, k)
        if op["kind"] in ("add", "cpu_add"):
            tensors[op["dst"]].last_use = max(tensors[op["dst"]].last_use, k)
    tensors[input_tensor].last_use = max(tensors[input_tensor].last_use, 0)
    return {"tensors": tensors, "ops": ops, "input_tensor": input_tensor,
            "final_ops": final_ops, "input": net["input"]}


def allocate(plan, a_size=A_SIZE, b_size=B_SIZE, align=16, mode="longB"):
    """Greedy lifetime allocator into A/B regions; returns (ok, info)."""
    tensors = plan["tensors"]
    ops = plan["ops"]
    regions = {"A": a_size, "B": b_size}
    # (offset, size) busy intervals per region
    busy = {"A": [], "B": []}
    tensors[plan["input_tensor"]].region = "A"
    tensors[plan["input_tensor"]].off = 0
    busy["A"].append((0, tensors[plan["input_tensor"]].nbytes))
    peak = {"A": tensors[plan["input_tensor"]].nbytes, "B": 0}
    peak_total = peak["A"]
    alloc_fail = None

    def try_place(region, size):
        size = (size + align - 1) // align * align
        used = sorted(busy[region])
        pos = 0
        for (o, s) in used:
            if pos + size <= o:
                return pos
            pos = max(pos, o + s)
        if pos + size <= regions[region]:
            return pos
        return None

    for k, op in enumerate(ops):
        # free dead tensors (last_use < k); keep region/off for the emitted plan
        for t in tensors:
            if t.off is not None and not t.freed and t.last_use >= 0 and t.last_use < k:
                busy[t.region] = [(o, s) for (o, s) in busy[t.region] if not (o == t.off and s == ((t.nbytes + align - 1) // align * align))]
                t.freed = True
        dst = op["dst"]
        if op["kind"] not in ("add", "cpu_add") and tensors[dst].off is None:
            t = tensors[dst]
            # v0.3.2: place into the SMALLEST region that can hold the tensor
            # (B is 32KB and A 96KB).  This keeps long-lived small tensors such
            # as the residual branch inputs out of A's big-tensor space; the
            # 128-input plan needs exactly 98,304 + 32,768 live bytes at op 8.
            cand = []
            for region in ("A", "B"):
                pos = try_place(region, t.nbytes)
                if pos is not None:
                    cand.append((region, pos))
            placed = None
            if cand:
                span = t.last_use - k
                preferB = (mode == "longB" and span >= 3)
                if preferB:
                    for (region, pos) in cand:
                        if region == "B":
                            placed = (region, pos)
                if placed is None:
                    # smallest region first (B) so big tensors keep A's space
                    order = {"B": 0, "A": 1} if mode == "smallB" else {"A": 0, "B": 1}
                    cand.sort(key=lambda rp: (order[rp[0]], rp[1]))
                    placed = cand[0]
            if placed is None:
                alloc_fail = "op %d tensor %d (%d B) does not fit A/B" % (k, dst, t.nbytes)
                break
            t.region, t.off = placed
            busy[placed[0]].append((t.off, (t.nbytes + align - 1) // align * align))
            used = sum(s for (o, s) in busy[placed[0]])
            peak[placed[0]] = max(peak[placed[0]], used)
            peak_total = max(peak_total, sum(sum(s for (o, s) in busy[r]) for r in "AB"))
        if op["kind"] in ("add", "cpu_add"):
            used = sum(sum(s for (o, s) in busy[r]) for r in "AB")
            peak_total = max(peak_total, used)
    info = {"ok": alloc_fail is None, "fail": alloc_fail, "peak_A": peak["A"],
            "peak_B": peak["B"], "peak_total": peak_total}
    return info



def assign_wq_offsets(plan, q_base=Q_BASE):
    """Assign W byte offsets (CONTRACT §6) and v0.6 Q offsets.

    Q layout v0.6 = pass 1 conv blocks (identical order/sizes to v0.5, so all
    conv qoff values and the whole W region are unchanged), then pass 2 one
    16 B ADD_R block per add op:
        [0]=zp_d, [1]=zp_s, [4:7]=R int32 LE, [8]=KADD, [9:15]=0
    """
    ops = plan["ops"]
    w_off = 0
    # v0.7: qoff is **Q-region relative** (Q lives in its own LUTRAM); the
    # caller may pass q_base=Q_BASE only to assemble the historical flat WQ
    # archive image.  Default is a pure relative Q offset.
    q_cur = 0
    q_index = 0
    for k, op in enumerate(ops):
        if op["kind"] in ("conv", "dwconv", "cpu_conv0"):
            oc, ic, k2 = op["oc"], op["ic"], op["k"] * op["k"]
            oc_pad = (oc + 7) // 8 * 8
            ic_pad = (ic + 7) // 8 * 8 if not op["depthwise"] else oc_pad
            nbytes = k2 * ic_pad * oc_pad if not op["depthwise"] else k2 * oc_pad
            op["w_off"] = w_off
            op["w_bytes"] = nbytes
            w_off += nbytes
            payload = 6 * oc_pad + 16
            op["q_off"] = q_cur
            op["q_index"] = q_index
            op["q_payload"] = payload
            op["q_layout"] = {"oc_pad": oc_pad, "bias": 0,
                              "mpos": 4 * oc_pad, "tail": 6 * oc_pad,
                              "bytes": payload}
            q_cur = ((q_cur + payload + 15) // 16) * 16
            q_index += 1
    q_conv_end = q_cur
    n_conv = q_index
    n_add = 0
    for k, op in enumerate(ops):
        kind = op["kind"]
        if kind in ("conv", "dwconv", "cpu_conv0"):
            continue
        op["w_off"] = -1
        op["w_bytes"] = 0
        if kind in ("add", "cpu_add"):
            op["q_off"] = q_cur
            op["q_payload"] = 16
            op["q_index"] = -1
            q_cur = ((q_cur + 16 + 15) // 16) * 16
            n_add += 1
        else:
            op["q_off"] = -1
            op["q_payload"] = 0
            op["q_index"] = -1
    plan["w_total"] = w_off
    plan["n_conv"] = n_conv
    plan["n_add"] = n_add
    plan["q_base"] = q_base
    plan["q_conv_end"] = q_conv_end
    plan["q_total_payload"] = q_cur
    plan["q_index"] = n_conv
    plan["q_region_bytes"] = Q_BYTES
    return plan


def macs_per_resolution(net, input_hw):
    """Total MACs for a given input resolution (weights are resolution-free)."""
    net_r = build_net(net["cfg_path"], input_hw[0], input_hw[1])
    total = 0
    per_layer = []
    for L in net_r["layers"]:
        if L["type"] == "convolutional":
            m = L["oh"] * L["ow"] * L["oc"] * (L["ic"] // L["groups"]) * L["k"] * L["k"]
            per_layer.append((L["idx"], m))
            total += m
        else:
            per_layer.append((L["idx"], 0))
    return total, per_layer, net_r


# ----------------------------------------------------------------------------
# float reference forward (PyTorch)
# ----------------------------------------------------------------------------
def forward_float_torch(net, folded, x_nhwc, need_ops=False):
    """x_nhwc: (H,W,3) float32 in [0,1]. Returns dict layer_idx -> np.ndarray(CHW).

    Uses torch CPU; all activations kept as float32 numpy for later analysis.
    """
    import torch
    import torch.nn.functional as F

    torch.set_grad_enabled(False)
    # NHWC -> NCHW
    x = torch.from_numpy(np.ascontiguousarray(x_nhwc.transpose(2, 0, 1)[None])).float()
    out = {}
    for L in net["layers"]:
        i = L["idx"]
        typ = L["type"]
        if typ == "convolutional":
            f = folded[i]
            w = torch.from_numpy(f["W"])
            b = torch.from_numpy(f["b"])
            y = F.conv2d(x, w, b, stride=L["stride"], padding=L["pad"],
                         groups=L["groups"])
            if L["activation"] == "leaky":
                y = F.leaky_relu(y, 0.1)
            x = y
        elif typ == "maxpool":
            x = F.max_pool2d(x, kernel_size=L["k"], stride=L["stride"], padding=L["pad"])
        elif typ == "upsample":
            x = F.interpolate(x, scale_factor=L["stride"], mode="nearest")
        elif typ == "route":
            refs = [out[j] for j in L["input_layers"]]
            x = torch.cat(refs, dim=1)
        elif typ == "shortcut":
            x = x + out[L["from_layer"]]
            if L["activation"] == "leaky":
                x = F.leaky_relu(x, 0.1)
        elif typ == "dropout":
            pass
        elif typ == "yolo":
            pass
        out[i] = x.clone()
    return {k: v[0].numpy() for k, v in out.items()}


# ----------------------------------------------------------------------------
# independent numpy float64 forward (cross-check of the torch path)
# ----------------------------------------------------------------------------
def conv2d_np(x, w, b, stride=1, pad=0, groups=1):
    """x NHWC float64, w (OC, ICg, K, K) float64 -> NHWC float64."""
    H, W, C = x.shape
    OC, ICg, K, _ = w.shape
    xp = np.pad(x, ((pad, pad), (pad, pad), (0, 0))) if pad else x
    oh = (H + 2 * pad - K) // stride + 1
    ow = (W + 2 * pad - K) // stride + 1
    out = np.zeros((oh, ow, OC), dtype=np.float64)
    ocg = OC // groups
    for g in range(groups):
        xg = xp[:, :, g * ICg:(g + 1) * ICg]
        for ky in range(K):
            for kx in range(K):
                patch = xg[ky:ky + (oh - 1) * stride + 1:stride,
                           kx:kx + (ow - 1) * stride + 1:stride, :]
                out[:, :, g * ocg:(g + 1) * ocg] += np.tensordot(
                    patch, w[g * ocg:(g + 1) * ocg, :, ky, kx], axes=([2], [1]))
    out += b
    return out


def forward_float_numpy(net, folded, x_nhwc):
    """Independent float64 numpy forward: returns dict layer_idx -> CHW ndarray."""
    x = x_nhwc.astype(np.float64)
    out = {}
    for L in net["layers"]:
        i = L["idx"]
        typ = L["type"]
        if typ == "convolutional":
            f = folded[i]
            y = conv2d_np(x, f["W"].astype(np.float64), f["b"].astype(np.float64),
                          stride=L["stride"], pad=L["pad"], groups=L["groups"])
            if L["activation"] == "leaky":
                y = np.where(y > 0, y, 0.1 * y)
            x = y
        elif typ == "maxpool":
            K, s, p = L["k"], L["stride"], L["pad"]
            H, W, C = x.shape
            oh, ow = L["oh"], L["ow"]
            xp = np.full((H + 2 * p, W + 2 * p, C), -np.inf)
            xp[p:p + H, p:p + W, :] = x
            y = np.full((oh, ow, C), -np.inf)
            for ky in range(K):
                for kx in range(K):
                    y = np.maximum(y, xp[ky:ky + (oh - 1) * s + 1:s,
                                          kx:kx + (ow - 1) * s + 1:s, :])
            x = y
        elif typ == "upsample":
            x = np.repeat(np.repeat(x, L["stride"], axis=0), L["stride"], axis=1)
        elif typ == "route":
            x = np.concatenate([out[j] for j in L["input_layers"]], axis=2)
        elif typ == "shortcut":
            x = x + out[L["from_layer"]]
            if L["activation"] == "leaky":
                x = np.where(x > 0, x, 0.1 * x)
        elif typ == "dropout":
            pass
        elif typ == "yolo":
            pass
        out[i] = x.copy()
    return out


def to_chw(x_nhwc):
    return np.ascontiguousarray(np.transpose(x_nhwc, (2, 0, 1)))


def cos_sim(a, b):
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    na = np.linalg.norm(a)
    nb = np.linalg.norm(b)
    if na == 0 or nb == 0:
        return 1.0 if na == nb else 0.0
    return float(np.dot(a, b) / (na * nb))


if __name__ == "__main__":
    import sys
    here = os.path.dirname(os.path.abspath(__file__))
    cfg = os.path.join(here, "data", "yolo-fastest-1.1.cfg")
    wpath = os.path.join(here, "data", "yolo-fastest-1.1.weights")
    net = build_net(cfg, 128, 128)
    need, specs = weight_float_counts(net)
    print("layers:", len(net["layers"]))
    print("conv layers:", len(conv_layers(net)), "depthwise:", sum(1 for L in conv_layers(net) if L["depthwise"]))
    print("weight floats (incl bias/BN):", need, "=> bytes:", need * 4)
    if os.path.exists(wpath):
        raw = load_weights(net, wpath)
        folded = fold_bn(net, raw)
        print("weights loaded OK, file bytes:", os.path.getsize(wpath))
        plan = plan_ops(net)
        assign_wq_offsets(plan)
        info = allocate(plan)
        print("W bytes:", plan["w_total"], "q layers:", plan["n_conv"],
              "Q payload bytes:", plan["q_total_payload"])
        print("alloc@128:", info)
        for hw in (320, 160, 128, 96):
            m, _, _ = macs_per_resolution(net, (hw, hw))
            n2 = build_net(cfg, hw, hw)
            p2 = assign_wq_offsets(plan_ops(n2))
            i2 = allocate(plan_ops(n2))
            print("res %4d: MACs %10d  alloc_ok %s peak_A %7d peak_B %7d peak_tot %7d"
                  % (hw, m, i2["ok"], i2["peak_A"], i2["peak_B"], i2["peak_total"]))
