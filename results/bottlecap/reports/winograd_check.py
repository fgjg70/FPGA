# -*- coding: utf-8 -*-
"""P3a: Winograd F(2x2,3x3) int8 离线精度实验（task-12 item 3）。

取 plan 里 2 个 56x56/72ch/3x3 代表层（op83 refine2.conv1、op95 objectness_tower.0.0）：
  * 权重：直接取 results/bottlecap/plan/w.hex 里该层的 int8 权重（converter 已量化）
  * 激活：真实图像（tools/bottlecap/data/test）按 dataset.preprocess_224 预处理
          -> float 模型 -> hook 该层 Conv2d 输入 -> 按 CONTRACT §5 per-tensor 量化成 int8
  * 对比：int8-direct（精确 int32 累加） vs int8-Winograd（3 个中间位宽变体）
  * 判据（Lead 定）：逐层 int8 输出 cos 均值 >= 0.97、最小 >= 0.93

用法: python results/bottlecap/reports/winograd_check.py
输出: results/bottlecap/reports/winograd_check.json + 控制台表
依赖: numpy / torch / PIL；不联网、不改模型源码。
"""
from __future__ import annotations

import io
import json
import os
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "bottlecap", "model_src"))

from nut_detector.enhanced_anchor_free import EnhancedNutAnchorFree  # noqa: E402

PLAN = os.path.join(ROOT, "results", "bottlecap", "plan", "plan.json")
WHEX = os.path.join(ROOT, "results", "bottlecap", "plan", "w.hex")
CKPT = os.path.join(ROOT, "tools", "bottlecap", "model_src", "best_model.pt")
IMGDIR = os.path.join(ROOT, "tools", "bottlecap", "data", "test")
OUTJSON = os.path.join(HERE, "winograd_check.json")

TARGETS = {83: "refine2.conv1.0", 95: "objectness_tower.0.0"}

BT = np.array([[1, 0, -1, 0],
               [0, 1, 1, 0],
               [0, -1, 1, 0],
               [0, 1, 0, -1]], dtype=np.int64)
G4 = np.array([[4, 0, 0],
               [2, 2, 2],
               [2, -2, 2],
               [0, 0, 4]], dtype=np.int64)      # = 4*G（使变换后仍是整数）
AT = np.array([[1, 1, 1, 0],
               [0, 1, -1, -1]], dtype=np.int64)


# ---------------------------------------------------------------------------
def load_plan():
    return json.load(io.open(PLAN, encoding="utf-8"))


def load_weight_image():
    """w.hex = 每行 8 hex（32bit 字，小端）-> 字节数组（= int8 权重镜像）。"""
    txt = io.open(WHEX, encoding="utf-8").read().split()
    words = np.array([int(t, 16) for t in txt], dtype=np.uint32)
    return words.view(np.uint8).reshape(-1, 4).reshape(-1)


def layer_weights(wbytes, op):
    """[tap][ic_pad][oc_pad] int8（CONTRACT §6A）。"""
    off, ln = op["woff"], op["wlen"]
    raw = wbytes[off:off + ln].astype(np.int8)
    k, ic, oc = op["k"], op["ic_pad"], op["oc_pad"]
    assert raw.size == k * k * ic * oc, (raw.size, k, ic, oc)
    return raw.reshape(k, k, ic, oc)


def load_float_activation(module_path, img_path):
    """按 dataset.preprocess_224 的口径跑 float 模型，hook 目标 Conv2d 的输入。"""
    ckpt = torch.load(CKPT, map_location="cpu", weights_only=False)
    sd = ckpt.get("model", ckpt.get("state_dict", ckpt)) if isinstance(ckpt, dict) else ckpt
    model = EnhancedNutAnchorFree(num_classes=4, fpn_channels=72, backbone_width=0.55)
    model.load_state_dict(sd, strict=False)
    model.eval()

    target = model
    for part in module_path.split("."):
        target = target[int(part)] if part.isdigit() else getattr(target, part)
    assert isinstance(target, torch.nn.Conv2d), type(target)

    cap = {}
    h = target.register_forward_hook(lambda _m, inp, _o: cap.__setitem__("x", inp[0].clone()))
    from PIL import Image
    im = Image.open(img_path).convert("RGB")
    resized = im.resize((224, 168), Image.Resampling.BILINEAR)
    px = np.asarray(resized)
    top = (224 - 168) // 2
    px = np.pad(px, ((top, 224 - 168 - top), (0, 0), (0, 0)), mode="edge")
    x = torch.from_numpy(px).permute(2, 0, 1).float().div_(127.5).sub_(1.0)[None]
    with torch.no_grad():
        model(x)
    h.remove()
    return cap["x"]


def quantize_activation(x_f):
    """CONTRACT §5：s=(max-min)/255, zp=-128-round(min/s), a_q=clip(round(a/s)+zp)。"""
    a = x_f[0].numpy()
    amax, amin = float(a.max()), float(a.min())
    s = (amax - amin) / 255.0 if amax > amin else 1.0
    zp = int(-128 - round(amin / s))
    aq = np.clip(np.round(a / s) + zp, -128, 127).astype(np.int8)
    return np.transpose(aq, (1, 2, 0)), dict(scale=s, zp=zp, min=amin, max=amax)


def direct_conv(xq, wq, pad):
    x = torch.from_numpy(xq.astype(np.float64)).permute(2, 0, 1)[None]
    w = torch.from_numpy(wq.astype(np.float64))
    y = torch.nn.functional.conv2d(x, w, padding=pad)
    acc = y[0].permute(1, 2, 0).numpy()
    assert np.allclose(acc, np.round(acc))
    return np.round(acc).astype(np.int64)


def winograd_conv(xq, wq, variant, pad):
    """F(2,3)；variant: exact / vclip8（V 截到 int8）/ mclip16（M 截到 int16）。"""
    OH, OW, IC = xq.shape
    OC = wq.shape[0]
    assert OH % 2 == 0 and OW % 2 == 0 and pad == 1
    xp = np.zeros((OH + 2, OW + 2, IC), dtype=np.int64)
    xp[1:1 + OH, 1:1 + OW, :] = xq
    TH, TW = OH // 2, OW // 2

    tiles = np.empty((TH * TW, 4, 4, IC), dtype=np.int64)
    t = 0
    for ty in range(TH):
        for tx in range(TW):
            tiles[t] = xp[2 * ty:2 * ty + 4, 2 * tx:2 * tx + 4, :]
            t += 1
    V = np.einsum("ij,tjkc,lk->tilc", BT, tiles, BT)          # [t,4,4,IC]
    if variant == "vclip8":
        V = np.clip(V, -128, 127)

    g = wq.astype(np.int64)                                    # [OC,IC,K,K]
    U4 = np.einsum("ij,ocjl,ml->ocim", G4, g, G4)            # [OC,IC,4,4]
    M = np.einsum("tcij,ocij->toij", np.transpose(V, (0, 3, 1, 2)), U4,
                  optimize=True)                               # [t,OC,4,4]
    if variant == "mclip16":
        M = np.clip(M, -32768, 32767)
    Y4 = np.einsum("ia,toab,mb->toim", AT, M, AT)            # [t,OC,2,2]
    # U4 = (4G) g (4G)^T = 16 * (GgG^T)  => Y4 = 16*y；exact 变体必须整除（整数精确）
    if variant == "exact":
        assert np.all(Y4 % 16 == 0), "exact variant must divide by 16"
        y = Y4 // 16
    else:
        y = np.rint(Y4 / 16.0).astype(np.int64)

    acc = np.empty((OH, OW, OC), dtype=np.int64)
    t = 0
    for ty in range(TH):
        for tx in range(TW):
            acc[2 * ty:2 * ty + 2, 2 * tx:2 * tx + 2, :] = np.transpose(y[t], (1, 2, 0))
            t += 1
    return acc


def requant_i8(acc, scale):
    return np.clip(np.round(acc * scale), -128, 127).astype(np.int8)


def cos_sim(a, b):
    a = a.astype(np.float64).ravel()
    b = b.astype(np.float64).ravel()
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if na == 0 or nb == 0:
        return 1.0 if na == nb else 0.0
    return float(a @ b / (na * nb))


# ---------------------------------------------------------------------------
def main():
    plan = load_plan()
    ops = {o["id"]: o for o in plan["ops"]}
    wbytes = load_weight_image()
    imgs = sorted(f for f in os.listdir(IMGDIR) if f.lower().endswith(".png"))[:4]

    details = []
    for op_id, mod_path in TARGETS.items():
        op = ops[op_id]
        w_kk = layer_weights(wbytes, op)                       # [K,K,IC,OC]
        wq = np.ascontiguousarray(np.transpose(w_kk, (3, 2, 0, 1)), dtype=np.int8)  # [OC,IC,K,K]
        for im in imgs:
            x_f = load_float_activation(mod_path, os.path.join(IMGDIR, im))
            xq, qmeta = quantize_activation(x_f)
            acc_dir = direct_conv(xq, wq, op["pad"])
            sc = 127.0 / max(1.0, float(np.percentile(np.abs(acc_dir), 99.9)))
            for variant in ("exact", "vclip8", "mclip16"):
                acc_wg = winograd_conv(xq, wq, variant, op["pad"])
                diff = acc_wg - acc_dir
                details.append(dict(
                    op=op_id, module=op["module"], img=im, variant=variant,
                    shape=dict(ic=op["ic_pad"], oc=op["oc_pad"], oh=op["oh"], ow=op["ow"]),
                    quant=qmeta,
                    max_abs_diff=int(np.abs(diff).max()),
                    rms_diff=round(float(np.sqrt((diff.astype(np.float64) ** 2).mean())), 4),
                    cos_acc=round(cos_sim(acc_dir, acc_wg), 6),
                    cos_i8=round(cos_sim(requant_i8(acc_dir, sc), requant_i8(acc_wg, sc)), 6),
                    exact=int(np.abs(diff).max()) == 0))

    summ = {}
    for v in ("exact", "vclip8", "mclip16"):
        sel = [d for d in details if d["variant"] == v]
        ci = [d["cos_i8"] for d in sel]
        ca = [d["cos_acc"] for d in sel]
        summ[v] = dict(n=len(sel),
                       cos_i8_mean=round(float(np.mean(ci)), 6),
                       cos_i8_min=round(float(np.min(ci)), 6),
                       cos_acc_mean=round(float(np.mean(ca)), 6),
                       cos_acc_min=round(float(np.min(ca)), 6),
                       max_abs_diff=int(max(d["max_abs_diff"] for d in sel)),
                       all_exact=all(d["exact"] for d in sel),
                       verdict="PASS" if (np.mean(ci) >= 0.97 and np.min(ci) >= 0.93) else "FAIL")

    out = dict(meta=dict(plan=PLAN, weights=WHEX, ckpt=CKPT, imgs=imgs,
                         targets={str(k): v for k, v in TARGETS.items()},
                         thresholds=dict(cos_i8_mean_ge=0.97, cos_i8_min_ge=0.93),
                         note="cos_i8 用两路径共用的 per-tensor requant；误差只来自 Winograd 中间域"),
               summary=summ, details=details)
    json.dump(out, io.open(OUTJSON, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    print("== Winograd F(2x2,3x3) int8 精度实验（真实权重 + 真实图像激活）==")
    for d in details:
        print("  op%-3d %-22s %-8s cos_acc=%.6f cos_i8=%.6f max|d|=%d%s"
              % (d["op"], d["module"][:22], d["variant"], d["cos_acc"], d["cos_i8"],
                 d["max_abs_diff"], "  EXACT" if d["exact"] else ""))
    print("\n== 汇总（判据：cos_i8 mean>=0.97, min>=0.93）==")
    for v, s in summ.items():
        print("  %-8s cos_acc mean=%.6f min=%.6f | cos_i8 mean=%.6f min=%.6f | "
              "max|d|=%d | %s" % (v, s["cos_acc_mean"], s["cos_acc_min"],
                                  s["cos_i8_mean"], s["cos_i8_min"],
                                  s["max_abs_diff"], s["verdict"]))
    print("\nwrote %s" % OUTJSON)


if __name__ == "__main__":
    main()
