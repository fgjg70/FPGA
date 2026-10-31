#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Image pre-processing / darknet YOLO decode + NMS / IoU matching.

Shared by convert_yolo_fastest.py (float sanity detection) and evaluate.py
(float-vs-int8 end-to-end comparison).
"""
import numpy as np

try:
    import cv2
except Exception:  # pragma: no cover
    cv2 = None


# ----------------------------------------------------------------------------
# pre-processing (darknet letterbox, fill 0.5, RGB, [0,1], CHW)
# ----------------------------------------------------------------------------
def letterbox(rgb01, net_h, net_w, fill=0.5):
    """rgb01: HWC float32 in [0,1]. Returns (img NHWC float32, scale, dx, dy)."""
    h, w = rgb01.shape[:2]
    scale = min(net_h / h, net_w / w)
    nh, nw = int(round(h * scale)), int(round(w * scale))
    if cv2 is not None:
        interp = cv2.INTER_LINEAR
        resized = cv2.resize(rgb01, (nw, nh), interpolation=interp)
    else:  # nearest fallback
        yi = (np.arange(nh) / scale).astype(np.int64).clip(0, h - 1)
        xi = (np.arange(nw) / scale).astype(np.int64).clip(0, w - 1)
        resized = rgb01[yi][:, xi]
    img = np.full((net_h, net_w, 3), fill, dtype=np.float32)
    dx, dy = (net_w - nw) // 2, (net_h - nh) // 2
    img[dy:dy + nh, dx:dx + nw, :] = resized.astype(np.float32)
    return img, scale, dx, dy


def load_image(path, net_h, net_w):
    """Load image file -> letterboxed RGB [0,1] NHWC, plus mapping info."""
    if cv2 is not None:
        bgr = cv2.imread(path, cv2.IMREAD_COLOR)
        if bgr is None:
            raise IOError("cannot read image %s" % path)
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
    else:  # pragma: no cover
        from PIL import Image
        rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    img, scale, dx, dy = letterbox(rgb, net_h, net_w)
    return img, {"orig_h": rgb.shape[0], "orig_w": rgb.shape[1],
                 "scale": scale, "dx": dx, "dy": dy}


# ----------------------------------------------------------------------------
# deterministic synthetic input (CONTRACT plan.json "pattern_v1", seed 12345)
#   q[y][x][c] = int8( (x*13 + y*7 + c*29 + seed) & 0xFF )
# ----------------------------------------------------------------------------
def pattern_v1(h, w, c=3, seed=12345):
    """Return int8 image (H,W,c) and the packed 8-channel-padded byte image."""
    y = np.arange(h, dtype=np.int64)[:, None, None]
    x = np.arange(w, dtype=np.int64)[None, :, None]
    ci = np.arange(c, dtype=np.int64)[None, None, :]
    v = (x * 13 + y * 7 + ci * 29 + seed) & 0xFF
    q = v.astype(np.uint8)
    qi = q.astype(np.int8)  # two's complement reinterpretation
    return qi


def pattern_v1_padded(h, w, c=3, seed=12345, c8=None):
    if c8 is None:
        c8 = (c + 7) // 8 * 8
    out = np.zeros((h, w, c8), dtype=np.int8)
    out[:, :, :c] = pattern_v1(h, w, c, seed)
    return out


# ----------------------------------------------------------------------------
# darknet YOLO decode + NMS
# ----------------------------------------------------------------------------
def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def yolo_decode(heads, net_h, net_w, obj_thresh=0.25):
    """heads: list of (chw float32 logits (255,h,w), yolo_layer_cfg).

    Returns array (N,6): x1,y1,x2,y2 (normalised 0..1 of net input), score, class.
    """
    out = []
    for logits, L in heads:
        C, hh, ww = logits.shape
        cls = L["classes"]
        num = L["num"]
        anchors = np.asarray(L["anchors"], dtype=np.float64).reshape(-1, 2)
        mask = L["mask"]
        stride = net_h // hh
        n_eff = len(mask)
        t = logits.reshape(n_eff, 5 + cls, hh, ww)  # (3, 5+cls, h, w)
        for n in range(n_eff):
            a = anchors[mask[n]]
            tx = sigmoid(t[n, 0])
            ty = sigmoid(t[n, 1])
            tw = t[n, 2]
            th = t[n, 3]
            obj = sigmoid(t[n, 4])
            pr = sigmoid(t[n, 5:])
            yy, xx = np.meshgrid(np.arange(hh), np.arange(ww), indexing="ij")
            bx = (xx + tx) / ww
            by = (yy + ty) / hh
            bw = np.exp(np.clip(tw, -20, 20)) * a[0] / net_w
            bh = np.exp(np.clip(th, -20, 20)) * a[1] / net_h
            conf = obj
            best = pr.argmax(axis=0)
            bestp = pr.max(axis=0)
            score = conf * bestp
            sel = score >= obj_thresh
            if not sel.any():
                continue
            for i, j in zip(*np.nonzero(sel)):
                cx, cy = bx[i, j], by[i, j]
                out.append((cx - bw[i, j] / 2, cy - bh[i, j] / 2,
                            cx + bw[i, j] / 2, cy + bh[i, j] / 2,
                            float(score[i, j]), int(best[i, j])))
    if not out:
        return np.zeros((0, 6), dtype=np.float64)
    return np.asarray(out, dtype=np.float64)


def nms_boxes(boxes, iou_thresh=0.45):
    """Per-class greedy NMS. boxes: (N,6) x1,y1,x2,y2,score,cls."""
    if len(boxes) == 0:
        return boxes
    keep = []
    for c in np.unique(boxes[:, 5]).astype(int):
        idx = np.nonzero(boxes[:, 5] == c)[0]
        b = boxes[idx]
        order = np.argsort(-b[:, 4])
        while order.size:
            i = order[0]
            keep.append(idx[i])
            if order.size == 1:
                break
            rest = order[1:]
            ious = iou1(b[i], b[rest])
            order = rest[ious < iou_thresh]
    keep = np.asarray(sorted(set(keep)), dtype=int)
    return boxes[keep]


def iou1(box, others):
    """IoU of one box [x1,y1,x2,y2,...] against (N,4+). Both normalized."""
    x1 = np.maximum(box[0], others[:, 0])
    y1 = np.maximum(box[1], others[:, 1])
    x2 = np.minimum(box[2], others[:, 2])
    y2 = np.minimum(box[3], others[:, 3])
    iw = np.maximum(0.0, x2 - x1)
    ih = np.maximum(0.0, y2 - y1)
    inter = iw * ih
    a = (box[2] - box[0]) * (box[3] - box[1])
    b = (others[:, 2] - others[:, 0]) * (others[:, 3] - others[:, 1])
    return inter / np.maximum(1e-12, a + b - inter)


def iou_xyxy(a, b):
    x1 = max(a[0], b[0])
    y1 = max(a[1], b[1])
    x2 = min(a[2], b[2])
    y2 = min(a[3], b[3])
    iw, ih = max(0.0, x2 - x1), max(0.0, y2 - y1)
    inter = iw * ih
    ar = max(0.0, a[2] - a[0]) * max(0.0, a[3] - a[1])
    br = max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])
    return inter / max(1e-12, ar + br - inter)


def dets_to_image(dets, meta):
    """Map normalized net-input boxes back to original image pixel coords."""
    out = dets.copy()
    s, dx, dy = meta["scale"], meta["dx"], meta["dy"]
    out[:, [0, 2]] = (out[:, [0, 2]] * meta["net_w"] - dx) / s
    out[:, [1, 3]] = (out[:, [1, 3]] * meta["net_h"] - dy) / s
    return out


def match_dets(a, b, iou_thresh=0.5):
    """Greedy match of two det sets (same class required), score-ordered by a.

    Returns (n_matched, mean_iou)."""
    if len(a) == 0:
        return 0, 0.0
    used = np.zeros(len(b), dtype=bool)
    order = np.argsort(-a[:, 4])
    n = 0
    ious = []
    for i in order:
        best = -1
        best_iou = 0.0
        for j in range(len(b)):
            if used[j] or int(b[j, 5]) != int(a[i, 5]):
                continue
            v = iou_xyxy(a[i], b[j])
            if v > best_iou:
                best_iou, best = v, j
        if best >= 0 and best_iou >= iou_thresh:
            used[best] = True
            n += 1
            ious.append(best_iou)
    return n, (float(np.mean(ious)) if ious else 0.0)
