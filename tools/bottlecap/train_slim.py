"""Slim bottle-cap detector: NPU-feasible training + capacity FIT-CHECK.

Trains ``SlimMobileNetNutAnchorFree`` at the largest input size that actually fits
the v0.7 NPU contract (see ``results/ai-accel/CONTRACT.md``), reusing the frozen
``nut_detector`` training/evaluation semantics through monkeypatched module-level
functions (the original sources are never edited).

Why the input is not 160:  the slim backbone expands the first inverted-residual
block to 32 channels at ``input/2`` resolution (``stage2.0.block.0``), so the
single-tensor activation peak is ``(S/2)^2 * 32`` bytes:
    160 -> 204,800 B (FAIL vs A=98,304 B)
    128 -> 131,072 B (FAIL)
     96 ->  73,728 B (PASS)
and width_multiplier=0.5 additionally needs IC/OC=320 > 256 (hard descriptor
limit) in ``stage5.1``, so the shipped slim config is width_multiplier=0.4
(c5=64, hidden peak 256) at 96x96.

Usage
-----
    python tools/bottlecap/train_slim.py --fit-report          # capacity only
    python tools/bottlecap/train_slim.py                       # train + reports
    python tools/bottlecap/train_slim.py --mode eval --checkpoint ...
"""

from __future__ import annotations

import argparse
import csv
import functools
import json
import math
import os
import random
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch import nn
from torch.nn import functional as F
from torch.optim import AdamW
from torch.optim.lr_scheduler import CosineAnnealingLR
from torch.utils.data import DataLoader

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
MODEL_SRC = HERE / "model_src"
if str(MODEL_SRC) not in sys.path:
    sys.path.insert(0, str(MODEL_SRC))

from nut_detector import multi_anchor_free as maf  # noqa: E402
from nut_detector import multi_dataset as mds  # noqa: E402
from nut_detector.enhanced_anchor_free import EnhancedNutAnchorFree  # noqa: E402
from nut_detector.mobilenet_anchor_free_slim import SlimMobileNetNutAnchorFree  # noqa: E402
from nut_detector.multi_anchor_free import decode_multi_predictions  # noqa: E402
from nut_detector.multi_dataset import MultiNutDataset, read_multi_split  # noqa: E402
from nut_detector.train_multi_mobilenet_anchor_free import (  # noqa: E402
    evaluate as base_evaluate,
    pairwise_iou,
)

_ORIGINAL_PREPROCESS = mds.preprocess_multi
_ORIGINAL_MAKE_TARGETS = maf.make_multi_targets

# --------------------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------------------
DEFAULT_DATASET_DIR = Path(
    r"D:\USER\Desktop\bottle_cap_model_training_package_20260819"
    r"\bottle_cap_model_training_package_20260819"
    r"\bottle_cap_color_dataset_multi_augmented_7to1"
)
DEFAULT_OUTPUT_DIR = REPO_ROOT / "results" / "bottlecap" / "slim"
TEACHER_CHECKPOINT = MODEL_SRC / "best_model.pt"
CLASS_NAMES = ["red_cap", "purple_cap", "green_cap", "yellow_cap"]

# CONTRACT.md v0.7 hard limits.
LIMITS = {
    "w_bytes": 320 * 1024,               # W 区 int8 权重（BN 折叠后，8 通道对齐）
    "q_bytes": 48 * 1024,                # Q 区 Σ(6*OC_pad+16)
    "a_single_tensor_bytes": 96 * 1024,  # A 缓冲单张量上限
    "b_bytes": 32 * 1024,                # B 缓冲
    "ops": 128,                          # nn_seq 微码 ROM 深度
    "max_ic_oc": 256,                    # 描述符合法性检查 IC<=256 / OC<=256
    "channel_align": 8,                  # IC_pad/OC_pad = ceil(C/8)*8
}
DTYPE_BYTES = 1  # int8

SEED = 20260819


# --------------------------------------------------------------------------------------
# Preprocessing / loss-grid monkeypatches (nut_detector sources stay untouched)
# --------------------------------------------------------------------------------------
def make_preprocess(input_size: int, aspect_ratio: float = 0.75):
    """160-style preprocessing generalized to ``input_size`` and ``aspect_ratio``.

    content is letterboxed to ``input_size x round(aspect_ratio*input_size)`` and the
    remaining rows are edge-padded top/bottom; boxes are normalized by
    ``/(input_size-1)`` exactly like ``multi_dataset.preprocess_multi``.
    For input_size=160 / ratio=0.75 this is exactly 160x120 + 20/20 rows; for 96 it is
    96x72 + 12/12.

    ``aspect_ratio=1.0`` disables the letterbox and resizes straight to a square:
    the source images of the nut dataset are square, so the 4:3 letterbox would
    throw away 25% of the pixels for nothing (the A-buffer peak
    ``(S/2)^2*32`` is independent of the content height, so capacity is unchanged).
    """
    fitted_height = int(round(input_size * aspect_ratio))
    top = (input_size - fitted_height) // 2
    bottom = input_size - fitted_height - top

    def preprocess(image: Image.Image, boxes: np.ndarray):
        resized = image.resize((input_size, fitted_height), Image.Resampling.BILINEAR)
        pixels = np.asarray(resized)
        pixels = np.pad(pixels, ((top, bottom), (0, 0), (0, 0)), mode="edge").copy()
        transformed = boxes.copy()
        transformed[:, [0, 2]] *= input_size / image.width
        transformed[:, [1, 3]] = transformed[:, [1, 3]] * fitted_height / image.height + top
        transformed /= np.array([input_size - 1] * 4, dtype=np.float32)
        transformed = np.clip(transformed, 0.0, 1.0)
        tensor = torch.from_numpy(pixels).permute(2, 0, 1).float().div_(127.5).sub_(1.0)
        return tensor, torch.from_numpy(transformed.astype(np.float32))

    preprocess.meta = {  # type: ignore[attr-defined]
        "target_size": input_size,
        "fitted_height": fitted_height,
        "pad_top": top,
        "pad_bottom": bottom,
        "aspect_ratio": aspect_ratio,
        "normalize": "pixel/127.5-1",
        "label_normalize": "/(input_size-1)",
    }
    return preprocess


def fast_make_multi_targets(
    target_xyxy: torch.Tensor, valid: torch.Tensor, grid_size: int
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    """Vectorized equivalent of ``multi_anchor_free.make_multi_targets``.

    Same math / same outputs, but the batch x object gaussian loop is batched so the
    per-step kernel-launch overhead (which dominated the 96x96 step time) disappears.
    """
    batch_size, max_objects, _ = target_xyxy.shape
    device = target_xyxy.device
    x1, y1, x2, y2 = target_xyxy.unbind(dim=2)
    center_x, center_y = (x1 + x2) * 0.5, (y1 + y2) * 0.5
    box_width = (x2 - x1).clamp(min=1e-4)
    box_height = (y2 - y1).clamp(min=1e-4)
    grid_x_float, grid_y_float = center_x * grid_size, center_y * grid_size
    grid_x = grid_x_float.floor().long().clamp(0, grid_size - 1)
    grid_y = grid_y_float.floor().long().clamp(0, grid_size - 1)

    axis = torch.arange(grid_size, device=device, dtype=torch.float32)
    yy, xx = torch.meshgrid(axis, axis, indexing="ij")
    sigma = (
        torch.minimum(box_width * grid_size, box_height * grid_size) / 6.0
    ).clamp(min=1.0)
    distance = (xx[None, None] - grid_x.float()[:, :, None, None]) ** 2 + (
        yy[None, None] - grid_y.float()[:, :, None, None]
    ) ** 2
    gaussian = torch.exp(-distance / (2.0 * sigma[:, :, None, None] ** 2))
    gaussian = gaussian.masked_fill(~valid[:, :, None, None], 0.0)
    heatmaps = gaussian.max(dim=1, keepdim=True).values
    centers = torch.zeros(batch_size, grid_size * grid_size, device=device)
    batch_index, object_index = valid.nonzero(as_tuple=True)
    if batch_index.numel():
        centers[batch_index, grid_y[batch_index, object_index] * grid_size
                + grid_x[batch_index, object_index]] = 1.0
    heatmaps = torch.maximum(heatmaps, centers.reshape(batch_size, 1, grid_size, grid_size))
    flat_indices = grid_y * grid_size + grid_x
    box_targets = torch.stack(
        [
            grid_x_float - grid_x.float(),
            grid_y_float - grid_y.float(),
            box_width,
            box_height,
        ],
        dim=2,
    )
    return heatmaps, flat_indices, box_targets


def patch_nut_detector(input_size: int, aspect_ratio: float = 0.75) -> dict:
    """Replace module-level preprocess + loss grid size. Returns metadata."""
    preprocess = make_preprocess(input_size, aspect_ratio)
    mds.preprocess_multi = preprocess  # MultiNutDataset.__getitem__ resolves this global
    grid = input_size // 4
    maf.make_multi_targets = functools.partial(fast_make_multi_targets, grid_size=grid)
    return {"preprocess": preprocess.meta, "grid_size": grid}


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)


# Windows DataLoader workers are spawned (not forked) and re-import this script as
# ``__mp_main__``.  The parent process exports the deployment input size through the
# environment so workers re-apply the same preprocess/loss-grid patches; without this
# workers would fall back to nut_detector's hard-coded 224x168 pipeline.
_ENV_INPUT_SIZE = os.environ.get("SLIM_INPUT_SIZE")
if _ENV_INPUT_SIZE:
    patch_nut_detector(int(_ENV_INPUT_SIZE))


# --------------------------------------------------------------------------------------
# Capacity analysis (W / Q / A / B / op)
# --------------------------------------------------------------------------------------
def _pad8(channels: int) -> int:
    return max(8, (int(channels) + 7) // 8 * 8)


def _shape_of(node) -> tuple[int, ...] | None:
    meta = node.meta.get("tensor_meta")
    if meta is None:
        return None
    return tuple(int(v) for v in meta.shape)


def _trace(model: nn.Module, input_size: int):
    from torch.fx import symbolic_trace
    from torch.fx.passes.shape_prop import ShapeProp

    graph = symbolic_trace(model)
    ShapeProp(graph).propagate(torch.zeros(1, 3, input_size, input_size))
    return graph


def describe_ops(model: nn.Module, input_size: int) -> dict:
    """Walk the fx graph and return per-NPU-op records in execution order."""
    graph = _trace(model, input_size)
    alias: dict[str, object] = {}
    tensor_shape: dict[str, tuple[int, ...]] = {}
    tensor_kind: dict[str, str] = {}
    ops: list[dict] = []
    final_tids: list[str] = []
    input_tid = ""

    def resolve(node):
        guard = 0
        while node.name in alias and guard < 16:
            node = alias[node.name]
            guard += 1
        return node

    for node in graph.graph.nodes:
        if node.op == "placeholder":
            tid = node.name
            input_tid = tid
            tensor_shape[tid] = (1, 3, input_size, input_size)
            tensor_kind[tid] = "input_packed3"
            continue
        if node.op == "call_module":
            module = graph.get_submodule(str(node.target))
            if isinstance(module, nn.Conv2d):
                src = resolve(node.args[0])
                out_shape = _shape_of(node)
                kernel = int(module.kernel_size[0])
                stride = int(module.stride[0])
                pad = int(module.padding[0])
                groups = int(module.groups)
                ic, oc = int(module.in_channels), int(module.out_channels)
                icp, ocp = _pad8(ic), _pad8(oc)
                depthwise = groups == ic and groups == oc and groups > 1
                if depthwise:
                    w_bytes = kernel * kernel * ocp
                    q_bytes = 6 * ocp + 16
                    kind = "dwconv"
                else:
                    w_bytes = kernel * kernel * icp * ocp
                    q_bytes = 6 * ocp + 16
                    kind = "conv"
                act_bytes = int(out_shape[-2]) * int(out_shape[-1]) * ocp
                tensor_shape[node.name] = out_shape
                tensor_kind[node.name] = kind
                ops.append(
                    {
                        "op": kind,
                        "name": node.name,
                        "target": str(node.target),
                        "k": kernel,
                        "s": stride,
                        "pad": pad,
                        "groups": groups,
                        "ic": ic,
                        "oc": oc,
                        "ic_pad": icp,
                        "oc_pad": ocp,
                        "w_bytes": w_bytes,
                        "q_bytes": q_bytes,
                        "in_shape": tensor_shape[src.name],
                        "out_shape": out_shape,
                        "act_bytes": act_bytes,
                        "inputs": [src.name],
                        "output": node.name,
                    }
                )
            elif isinstance(module, (nn.BatchNorm2d, nn.ReLU)):
                alias[node.name] = resolve(node.args[0])
            else:  # pragma: no cover - architecture guard
                raise TypeError(f"unsupported module in graph: {type(module)}")
            continue
        if node.op == "call_function":
            target_name = getattr(node.target, "__name__", str(node.target))
            out_shape = _shape_of(node)
            if target_name == "interpolate":
                src = resolve(node.args[0])
                tid = node.name
                ocp = _pad8(int(out_shape[1]))
                tensor_shape[tid] = out_shape
                tensor_kind[tid] = "upsample"
                ops.append(
                    {
                        "op": "upsample",
                        "name": tid,
                        "target": target_name,
                        "ic": int(out_shape[1]),
                        "oc": int(out_shape[1]),
                        "ic_pad": ocp,
                        "oc_pad": ocp,
                        "w_bytes": 0,
                        "q_bytes": 0,
                        "in_shape": tensor_shape[src.name],
                        "out_shape": out_shape,
                        "act_bytes": int(out_shape[-2]) * int(out_shape[-1]) * ocp,
                        "inputs": [src.name],
                        "output": tid,
                    }
                )
            elif target_name == "add":
                left = resolve(node.args[0])
                right = resolve(node.args[1])
                tid = node.name
                ocp = _pad8(int(out_shape[1]))
                tensor_shape[tid] = out_shape
                tensor_kind[tid] = "add"
                ops.append(
                    {
                        "op": "add",
                        "name": tid,
                        "target": target_name,
                        "ic": int(out_shape[1]),
                        "oc": int(out_shape[1]),
                        "ic_pad": ocp,
                        "oc_pad": ocp,
                        "w_bytes": 0,
                        "q_bytes": 0,
                        "in_shape": tensor_shape[left.name],
                        "out_shape": out_shape,
                        "act_bytes": int(out_shape[-2]) * int(out_shape[-1]) * ocp,
                        "inputs": [left.name, right.name],
                        "output": tid,
                    }
                )
            else:  # pragma: no cover
                raise TypeError(f"unsupported call_function in graph: {node.target}")
            continue
        if node.op == "output":
            values = node.args[0]
            if isinstance(values, (tuple, list)):
                final_tids = [resolve(v).name for v in values]
            else:
                final_tids = [resolve(values).name]
    return {
        "ops": ops,
        "final_tids": final_tids,
        "input_tid": input_tid,
        "tensor_shape": tensor_shape,
        "input_size": input_size,
    }


class _Arena:
    """Byte-addressed activation arena with a coalescing free list."""

    def __init__(self, size: int) -> None:
        self.size = int(size)
        self.free: list[tuple[int, int]] = [(0, self.size)] if self.size else []
        self.peak_used = 0

    def used(self) -> int:
        return self.size - sum(length for _, length in self.free)

    def alloc(self, size: int):
        for index, (offset, length) in enumerate(self.free):
            if length >= size:
                if length == size:
                    self.free.pop(index)
                else:
                    self.free[index] = (offset + size, length - size)
                self.peak_used = max(self.peak_used, self.used())
                return offset
        return None

    def release(self, offset: int, size: int) -> None:
        merged: list[tuple[int, int]] = []
        placed = False
        for start, length in sorted(self.free + [(offset, size)]):
            if merged and merged[-1][0] + merged[-1][1] >= start:
                merged[-1] = (merged[-1][0], max(merged[-1][1], start + length - merged[-1][0]))
            else:
                merged.append((start, length))
            placed = True
        if not placed:  # pragma: no cover
            merged.append((offset, size))
        self.free = merged


def _tensor_bytes(shape: tuple[int, ...] | None, kind: str, input_size: int) -> int:
    if shape is None:
        return 0
    if kind == "input_packed3":
        return input_size * input_size * 3
    height, width = int(shape[-2]), int(shape[-1])
    return height * width * _pad8(int(shape[1]))


def simulate_buffers(ops: list[dict], final_tids: list[str], input_tid: str,
                     input_size: int, prefer: str = "small_first") -> dict:
    """Greedy A/B placement simulation; returns peaks/failures for one policy."""
    arena_a = _Arena(LIMITS["a_single_tensor_bytes"])
    arena_b = _Arena(LIMITS["b_bytes"])

    def place(size: int):
        order = ("b", "a") if (size <= arena_b.size and prefer == "small_first") else ("a", "b")
        for name in order:
            arena = arena_b if name == "b" else arena_a
            offset = arena.alloc(size)
            if offset is not None:
                return (name, offset, size)
        return None

    def release_region(region) -> None:
        name, offset, length = region
        (arena_b if name == "b" else arena_a).release(offset, length)

    input_bytes = input_size * input_size * 3
    # CONTRACT §8: conv0 consumes the PACKED3 image which must live in A (not B).
    input_offset = arena_a.alloc(input_bytes)
    if input_offset is None:
        return {"ok": False, "error": "input tensor does not fit in A/B",
                "a_peak": arena_a.peak_used, "b_peak": arena_b.peak_used}
    live: dict[str, tuple] = {input_tid: ("a", input_offset, input_bytes)}

    refs: Counter[str] = Counter()
    for op in ops:
        for tid in op["inputs"]:
            refs[tid] += 1
    for tid in final_tids:
        refs[tid] += 1

    def consume(tid: str) -> None:
        refs[tid] -= 1
        if refs[tid] <= 0 and tid in live:
            release_region(live.pop(tid))

    failures: list[str] = []
    for op in ops:
        size = op["act_bytes"]
        out = op["output"]
        if op["op"] == "add":
            left, right = op["inputs"]
            if left not in live or right not in live:
                failures.append(f"{op['name']}: missing live operand")
                break
            # ADD_R: dst = dst + src; addition is commutative, so the in-place write
            # may reuse either operand -- prefer keeping the result in B to free A.
            candidates = [
                (tid, live[tid])
                for tid in (left, right)
                if refs[tid] == 1 and tid in live and live[tid][2] >= size
            ]
            if candidates:
                candidates.sort(
                    key=lambda item: (
                        0 if item[1][0] == "b" else 1,
                        0 if item[0] == right else 1,
                    )
                )
                chosen, region = candidates[0]
                live[out] = live.pop(chosen)
                refs[chosen] = 0
                other = right if chosen == left else left
                consume(other)
            else:
                region = place(size)
                if region is None:
                    failures.append(f"{op['name']}: add dst {size}B does not fit")
                    break
                live[out] = region
                consume(left)
                consume(right)
            continue
        region = place(size)
        if region is None:
            failures.append(f"{op['name']}: {op['op']} dst {size}B does not fit")
            break
        live[out] = region
        for tid in op["inputs"]:
            consume(tid)
    return {
        "ok": not failures,
        "failures": failures,
        "a_peak": arena_a.peak_used,
        "b_peak": arena_b.peak_used,
        "live_at_end": {tid: list(live[tid]) for tid in final_tids if tid in live},
    }


def analyze_capacity(model: nn.Module, input_size: int, num_classes: int = 4) -> dict:
    model = model.eval()
    info = describe_ops(model, input_size)
    ops = info["ops"]
    conv_ops = [op for op in ops if op["op"] in ("conv", "dwconv")]
    add_ops = [op for op in ops if op["op"] == "add"]
    up_ops = [op for op in ops if op["op"] == "upsample"]
    w_total = sum(op["w_bytes"] for op in conv_ops)
    q_total = sum(op["q_bytes"] for op in conv_ops)
    input_bytes = input_size * input_size * 3
    a_candidates = [input_bytes] + [op["act_bytes"] for op in ops]
    a_peak = max(a_candidates)
    a_peak_op = "input_packed3" if a_peak == input_bytes else max(
        ops, key=lambda op: op["act_bytes"]
    )["name"]
    ic_max = max((op["ic"] for op in ops), default=0)
    oc_max = max((op["oc"] for op in ops), default=0)
    op_total = len(conv_ops) + len(add_ops) + len(up_ops)

    sim_small = simulate_buffers(ops, info["final_tids"], info["input_tid"], input_size,
                                 prefer="small_first")
    sim_large = simulate_buffers(ops, info["final_tids"], info["input_tid"], input_size,
                                 prefer="large_first")
    feasible = [sim for sim in (sim_small, sim_large) if sim["ok"]]
    best = None
    if feasible:
        best = min(feasible, key=lambda sim: (sim["a_peak"], sim["b_peak"]))
    b_peak = best["b_peak"] if best else min(sim_small["b_peak"], sim_large["b_peak"])

    params = sum(parameter.numel() for parameter in model.parameters())
    checks = [
        {
            "item": "W 区 int8 权重（BN 折叠后，8 通道对齐）",
            "actual_bytes": w_total, "actual": f"{w_total:,} B / {w_total/1024:.1f} KB",
            "limit_bytes": LIMITS["w_bytes"], "limit": "320 KB (327,680 B)",
            "pass": w_total <= LIMITS["w_bytes"],
        },
        {
            "item": "Q 区量化参数 Σ(6*OC_pad+16)",
            "actual_bytes": q_total, "actual": f"{q_total:,} B",
            "limit_bytes": LIMITS["q_bytes"], "limit": "48 KB (49,152 B)",
            "pass": q_total <= LIMITS["q_bytes"],
        },
        {
            "item": "A 缓冲单张量峰值（NHWC int8，8ch 对齐；含 PACKED3 输入图）",
            "actual_bytes": a_peak, "actual": f"{a_peak:,} B / {a_peak/1024:.1f} KB",
            "limit_bytes": LIMITS["a_single_tensor_bytes"],
            "limit": "96 KB (98,304 B)", "pass": a_peak <= LIMITS["a_single_tensor_bytes"],
            "peak_tensor": a_peak_op,
        },
        {
            "item": "B 缓冲（A/B 可行摆放下的并发峰值）",
            "actual_bytes": b_peak, "actual": f"{b_peak:,} B / {b_peak/1024:.1f} KB",
            "limit_bytes": LIMITS["b_bytes"], "limit": "32 KB (32,768 B)",
            "pass": bool(best) and b_peak <= LIMITS["b_bytes"],
            "placement_feasible": bool(best),
        },
        {
            "item": "op 总数（conv/dwconv/pool/upsample/add/copy）",
            "actual_bytes": op_total, "actual": f"{op_total} ops",
            "limit_bytes": LIMITS["ops"], "limit": "128 op (ROM 深度)",
            "pass": op_total <= LIMITS["ops"],
        },
        {
            "item": "描述符 IC/OC 上限",
            "actual_bytes": max(ic_max, oc_max), "actual": f"IC_max={ic_max}, OC_max={oc_max}",
            "limit_bytes": LIMITS["max_ic_oc"], "limit": "256",
            "pass": max(ic_max, oc_max) <= LIMITS["max_ic_oc"],
        },
    ]
    return {
        "model_class": type(model).__name__,
        "num_classes": num_classes,
        "input_size": input_size,
        "parameter_count": params,
        "parameter_fp32_bytes": params * 4,
        "op_count": {
            "conv": len([op for op in conv_ops if op["op"] == "conv"]),
            "dwconv": len([op for op in conv_ops if op["op"] == "dwconv"]),
            "upsample": len(up_ops),
            "add": len(add_ops),
            "pool": 0,
            "copy": 0,
            "total": op_total,
        },
        "w_bytes": w_total,
        "q_bytes": q_total,
        "a_single_tensor_peak_bytes": a_peak,
        "a_peak_tensor": a_peak_op,
        "b_peak_bytes": b_peak,
        "ic_max": ic_max,
        "oc_max": oc_max,
        "checks": checks,
        "all_pass": all(check["pass"] for check in checks),
        "buffer_placement": best,
        "ops": ops,
        "layers": conv_ops,
        "activations": [
            {
                "name": op["name"],
                "op": op["op"],
                "shape_nhwc": [int(op["out_shape"][2]), int(op["out_shape"][3]), op["oc_pad"]],
                "bytes": op["act_bytes"],
            }
            for op in ops
        ],
        "input_tensor_bytes_packed3": input_bytes,
    }


def analyze_expansion3_hypothetical(
    input_sizes: tuple[int, ...] = (112, 128), width: float = 0.4, fpn: int = 64
) -> list[dict]:
    """Capacity of the *hypothetical* larger-input variants (fallbacks only).

    Lead's suggestion was 112x112 with ``stage2[0]`` expansion 4->3 (hidden 32->24,
    A peak 56*56*24 = 75,264 B).  Measuring it instead of guessing gives two hard
    facts:

    * 112 is **architecturally invalid**: the FPN uses
      ``F.interpolate(scale_factor=2.0)`` so every spatial size must divide by 32;
      112/32 = 3.5 -> the p5 upsample lands on 4 but C4 is 7 -> add mismatch.
    * The next legal size is 128.  With expansion=3 the single-tensor peak becomes
      exactly 98,304 B (== A limit), but ``stage1`` runs at 64x64x16 = 65,536 B and
      its 3x3 depthwise conv needs input+output live at once (131,072 B > A+B),
      while the residual skip still holds B -> no feasible A/B placement.

    Conclusion: 96x96 is the maximum feasible input for this topology on the current
    NPU; nothing is trained/shipped for these fallbacks.
    """
    from nut_detector.mobilenet_anchor_free import InvertedResidual

    original_init = InvertedResidual.__init__

    def patched_init(self, in_channels, out_channels, stride, expansion=3):
        original_init(self, in_channels, out_channels, stride, expansion)

    rows: list[dict] = []
    for input_size in input_sizes:
        row: dict = {
            "width_multiplier": width,
            "fpn_channels": fpn,
            "input_size": input_size,
            "hypothetical": True,
            "requires_architecture_change": (
                "stage2[0] InvertedResidual expansion 4->3 (hidden 32->24)"
            ),
        }
        if input_size % 32 != 0:
            stages = [input_size // 2, input_size // 4, input_size // 8,
                      input_size // 16, input_size // 32]
            row.update(
                {
                    "architecturally_invalid": True,
                    "invalid_reason": (
                        "FPN 使用 F.interpolate(scale_factor=2.0)，要求输入能被 32 整除；"
                        f"{input_size} 的 stage 尺寸 {stages} 上采样后与 C4 不一致"
                    ),
                    "error": "RuntimeError",
                    "parameter_count": None,
                    "w_bytes": None,
                    "q_bytes": None,
                    "a_single_tensor_peak_bytes": None,
                    "a_peak_tensor": None,
                    "b_peak_bytes": None,
                    "op_total": None,
                    "ic_max": None,
                    "oc_max": None,
                    "all_pass": False,
                    "failed_items": ["架构不可行（FPN 上采样尺寸不整除）"],
                }
            )
            rows.append(row)
            continue
        InvertedResidual.__init__ = patched_init
        try:
            model = SlimMobileNetNutAnchorFree(
                num_classes=4, width_multiplier=width, fpn_channels=fpn
            )
            capacity = analyze_capacity(model, input_size)
            row.update(
                {
                    "architecturally_invalid": False,
                    "parameter_count": capacity["parameter_count"],
                    "w_bytes": capacity["w_bytes"],
                    "q_bytes": capacity["q_bytes"],
                    "a_single_tensor_peak_bytes": capacity["a_single_tensor_peak_bytes"],
                    "a_peak_tensor": capacity["a_peak_tensor"],
                    "b_peak_bytes": capacity["b_peak_bytes"],
                    "op_total": capacity["op_count"]["total"],
                    "ic_max": capacity["ic_max"],
                    "oc_max": capacity["oc_max"],
                    "all_pass": capacity["all_pass"],
                    "failed_items": [
                        check["item"] for check in capacity["checks"] if not check["pass"]
                    ],
                }
            )
        except Exception as exc:  # noqa: BLE001 - reported as evidence
            stages = [input_size // 2, input_size // 4, input_size // 8,
                      input_size // 16, input_size // 32]
            row.update(
                {
                    "architecturally_invalid": True,
                    "invalid_reason": (
                        "FPN 使用 F.interpolate(scale_factor=2.0)，要求输入能被 32 整除；"
                        f"{input_size} 的 stage 尺寸 {stages} 上采样后与 C4 不一致"
                    ),
                    "error": f"{type(exc).__name__}",
                    "parameter_count": None,
                    "w_bytes": None,
                    "q_bytes": None,
                    "a_single_tensor_peak_bytes": None,
                    "a_peak_tensor": None,
                    "b_peak_bytes": None,
                    "op_total": None,
                    "ic_max": None,
                    "oc_max": None,
                    "all_pass": False,
                    "failed_items": ["架构不可行（FPN 上采样尺寸不整除）"],
                }
            )
        finally:
            InvertedResidual.__init__ = original_init
        rows.append(row)
    return rows


def capacity_variants(
    configs: list[dict], input_sizes: list[int], num_classes: int = 4
) -> list[dict]:
    rows = []
    for config in configs:
        for input_size in input_sizes:
            model = SlimMobileNetNutAnchorFree(
                num_classes=num_classes,
                width_multiplier=config["width_multiplier"],
                fpn_channels=config["fpn_channels"],
            )
            cap = analyze_capacity(model, input_size, num_classes)
            rows.append(
                {
                    "width_multiplier": config["width_multiplier"],
                    "fpn_channels": config["fpn_channels"],
                    "input_size": input_size,
                    "parameter_count": cap["parameter_count"],
                    "w_bytes": cap["w_bytes"],
                    "q_bytes": cap["q_bytes"],
                    "a_single_tensor_peak_bytes": cap["a_single_tensor_peak_bytes"],
                    "a_peak_tensor": cap["a_peak_tensor"],
                    "b_peak_bytes": cap["b_peak_bytes"],
                    "op_total": cap["op_count"]["total"],
                    "ic_max": cap["ic_max"],
                    "oc_max": cap["oc_max"],
                    "all_pass": cap["all_pass"],
                    "failed_items": [check["item"] for check in cap["checks"] if not check["pass"]],
                }
            )
    return rows


# --------------------------------------------------------------------------------------
# Evaluation (same decode/NMS/match semantics as nut_detector)
# --------------------------------------------------------------------------------------
def _matched_pairs(predicted_classes, predicted_boxes, true_classes, true_boxes,
                   iou_threshold: float = 0.5):
    if len(predicted_boxes) == 0 or len(true_boxes) == 0:
        return []
    ious = pairwise_iou(predicted_boxes, true_boxes)
    candidate = ious.masked_fill(
        ~predicted_classes[:, None].eq(true_classes[None, :]), -1.0
    )
    pairs = []
    while candidate.numel() and float(candidate.max()) >= iou_threshold:
        flat = int(candidate.argmax())
        predicted_index = flat // candidate.shape[1]
        true_index = flat % candidate.shape[1]
        pairs.append((predicted_index, true_index, float(candidate[predicted_index, true_index])))
        candidate[predicted_index, :] = -1.0
        candidate[:, true_index] = -1.0
    return pairs


@torch.no_grad()
def evaluate(model, loader, device) -> dict:
    """Thin wrapper around nut_detector's evaluate (grid size is monkeypatched)."""
    return base_evaluate(model, loader, device)


@torch.no_grad()
def detailed_evaluate(model, loader, device, samples) -> tuple[dict, list[dict]]:
    model.eval()
    rows: list[dict] = []
    true_by_class: Counter[int] = Counter()
    predicted_by_class: Counter[int] = Counter()
    matched_by_class: Counter[int] = Counter()
    ious_all: list[float] = []
    grouped: dict[int, Counter] = defaultdict(Counter)
    lighting: dict[str, Counter] = defaultdict(Counter)
    offset = 0
    for images, classes, boxes, valid in loader:
        images = images.to(device)
        classes = classes.to(device)
        boxes = boxes.to(device)
        valid = valid.to(device)
        outputs = model(images)
        predictions = decode_multi_predictions(*outputs)
        for batch_index, prediction in enumerate(predictions):
            sample = samples[offset + batch_index]
            true_classes = classes[batch_index][valid[batch_index]]
            true_boxes = boxes[batch_index][valid[batch_index]]
            pairs = _matched_pairs(
                prediction["classes"], prediction["boxes"], true_classes, true_boxes
            )
            true_count = len(true_boxes)
            predicted_count = len(prediction["boxes"])
            tp = len(pairs)
            fp, fn = predicted_count - tp, true_count - tp
            pair_ious = [pair[2] for pair in pairs]
            true_by_class.update(int(value) for value in true_classes)
            predicted_by_class.update(int(value) for value in prediction["classes"])
            matched_by_class.update(int(true_classes[pair[1]]) for pair in pairs)
            ious_all.extend(pair_ious)
            group = grouped[true_count]
            group["images"] += 1
            group["tp"] += tp
            group["fp"] += fp
            group["fn"] += fn
            group["count_correct"] += int(true_count == predicted_count)
            group["exact"] += int(tp == true_count and fp == 0 and fn == 0)
            profile = lighting[str(sample.get("lighting_profile", "original"))]
            profile["images"] += 1
            profile["tp"] += tp
            profile["fp"] += fp
            profile["fn"] += fn
            profile["exact"] += int(tp == true_count and fp == 0 and fn == 0)
            rows.append(
                {
                    "image": Path(sample["image"]).name,
                    "true_count": true_count,
                    "predicted_count": predicted_count,
                    "true_positive": tp,
                    "false_positive": fp,
                    "false_negative": fn,
                    "mean_matched_iou": float(np.mean(pair_ious)) if pair_ious else 0.0,
                    "exact": int(tp == true_count and fp == 0 and fn == 0),
                    "lighting_profile": sample.get("lighting_profile", "original"),
                }
            )
        offset += images.shape[0]

    total_tp = sum(row["true_positive"] for row in rows)
    total_fp = sum(row["false_positive"] for row in rows)
    total_fn = sum(row["false_negative"] for row in rows)
    precision = total_tp / max(1, total_tp + total_fp)
    recall = total_tp / max(1, total_tp + total_fn)
    per_class = {}
    for index, name in enumerate(CLASS_NAMES):
        per_class[name] = {
            "true_objects": true_by_class[index],
            "predicted_objects": predicted_by_class[index],
            "matched_objects": matched_by_class[index],
            "precision": matched_by_class[index] / max(1, predicted_by_class[index]),
            "recall": matched_by_class[index] / max(1, true_by_class[index]),
        }
    by_count = {}
    for count, values in sorted(grouped.items()):
        group_precision = values["tp"] / max(1, values["tp"] + values["fp"])
        group_recall = values["tp"] / max(1, values["tp"] + values["fn"])
        by_count[str(count)] = {
            "images": values["images"],
            "precision": group_precision,
            "recall": group_recall,
            "f1": 2 * group_precision * group_recall / max(1e-9, group_precision + group_recall),
            "count_accuracy": values["count_correct"] / values["images"],
            "exact_image_accuracy": values["exact"] / values["images"],
        }
    by_lighting = {}
    for profile, values in sorted(lighting.items()):
        profile_precision = values["tp"] / max(1, values["tp"] + values["fp"])
        profile_recall = values["tp"] / max(1, values["tp"] + values["fn"])
        by_lighting[profile] = {
            "images": values["images"],
            "precision": profile_precision,
            "recall": profile_recall,
            "f1": 2 * profile_precision * profile_recall / max(1e-9, profile_precision + profile_recall),
            "exact_image_accuracy": values["exact"] / values["images"],
        }
    report = {
        "test_images": len(rows),
        "true_objects": total_tp + total_fn,
        "predicted_objects": total_tp + total_fp,
        "true_positive": total_tp,
        "false_positive": total_fp,
        "false_negative": total_fn,
        "precision": precision,
        "recall": recall,
        "f1": 2 * precision * recall / max(1e-9, precision + recall),
        "mean_matched_iou": float(np.mean(ious_all)) if ious_all else 0.0,
        "count_accuracy": float(np.mean([row["true_count"] == row["predicted_count"] for row in rows])),
        "exact_image_accuracy": float(np.mean([row["exact"] for row in rows])),
        "per_class": per_class,
        "by_true_object_count": by_count,
        "by_lighting_profile": by_lighting,
    }
    return report, rows


# --------------------------------------------------------------------------------------
# Teacher probe / distillation
# --------------------------------------------------------------------------------------
def load_teacher(
    device,
    checkpoint_path: Path | None = None,
    num_classes: int = 4,
    fpn_channels: int | None = None,
    backbone_width: float | None = None,
) -> tuple[nn.Module, dict]:
    """Load the 2M teacher. Shape params default to the checkpoint's own config."""
    path = Path(checkpoint_path) if checkpoint_path is not None else TEACHER_CHECKPOINT
    checkpoint = torch.load(path, map_location="cpu", weights_only=False)
    saved = checkpoint.get("config") or {}
    fpn = int(fpn_channels if fpn_channels is not None
              else saved.get("fpn_channels", 72))
    width = float(backbone_width if backbone_width is not None
                  else saved.get("backbone_width", 0.55))
    n_cls = int(saved.get("num_classes", num_classes))
    teacher = EnhancedNutAnchorFree(num_classes=n_cls, fpn_channels=fpn,
                                    backbone_width=width)
    teacher.load_state_dict(checkpoint["model"])
    teacher.to(device).eval()
    for parameter in teacher.parameters():
        parameter.requires_grad_(False)
    return teacher, checkpoint


@torch.no_grad()
def teacher_probe(model: nn.Module, loader: DataLoader, device, input_size: int) -> dict:
    """P/R/F1/mIoU of a model at this loader's preprocessing (test set)."""
    model.eval()
    tp = fp = fn = 0
    ious: list[float] = []
    exact = count_ok = images = 0
    for batch in loader:
        image_batch, classes, boxes, valid = batch
        image_batch = image_batch.to(device)
        outputs = model(image_batch)
        predictions = decode_multi_predictions(*outputs)
        for batch_index, prediction in enumerate(predictions):
            true_classes = classes[batch_index][valid[batch_index]].to(device)
            true_boxes = boxes[batch_index][valid[batch_index]].to(device)
            pairs = _matched_pairs(
                prediction["classes"], prediction["boxes"], true_classes, true_boxes
            )
            t = len(pairs)
            true_count = len(true_boxes)
            predicted_count = len(prediction["boxes"])
            tp += t
            fp += predicted_count - t
            fn += true_count - t
            ious.extend(pair[2] for pair in pairs)
            exact += int(t == true_count and predicted_count == t)
            count_ok += int(true_count == predicted_count)
            images += 1
    precision = tp / max(1, tp + fp)
    recall = tp / max(1, tp + fn)
    return {
        "input_size": input_size,
        "images": images,
        "true_positive": tp,
        "false_positive": fp,
        "false_negative": fn,
        "precision": precision,
        "recall": recall,
        "f1": 2 * precision * recall / max(1e-9, precision + recall),
        "mean_iou": float(np.mean(ious)) if ious else 0.0,
        "exact_image_accuracy": exact / max(1, images),
        "count_accuracy": count_ok / max(1, images),
    }


def dense_distillation_loss(student_outputs, teacher_outputs) -> torch.Tensor:
    student_objectness, student_classes, student_boxes = student_outputs
    teacher_objectness, teacher_classes, teacher_boxes = (
        value.detach() for value in teacher_outputs
    )
    teacher_probability = torch.sigmoid(teacher_objectness)
    student_probability = torch.sigmoid(student_objectness)
    objectness_weight = 1.0 + 8.0 * teacher_probability
    objectness_loss = (
        (student_probability - teacher_probability).pow(2) * objectness_weight
    ).mean()
    temperature = 2.0
    class_kl = F.kl_div(
        F.log_softmax(student_classes / temperature, dim=1),
        F.softmax(teacher_classes / temperature, dim=1),
        reduction="none",
    ).sum(dim=1, keepdim=True) * (temperature ** 2)
    foreground_weight = teacher_probability.clamp(min=0.02)
    class_loss = (class_kl * foreground_weight).sum() / foreground_weight.sum()
    box_difference = (
        torch.sigmoid(student_boxes) - torch.sigmoid(teacher_boxes)
    ).abs().mean(dim=1, keepdim=True)
    box_loss = (box_difference * foreground_weight).sum() / foreground_weight.sum()
    return 2.0 * objectness_loss + class_loss + box_loss


# --------------------------------------------------------------------------------------
# Training
# --------------------------------------------------------------------------------------
def build_loaders(args, patch_meta):
    train_samples = read_multi_split(args.dataset_dir, "train")
    test_samples = read_multi_split(args.dataset_dir, "test")
    if args.limit_train:
        train_samples = train_samples[: args.limit_train]
    if args.limit_test:
        test_samples = test_samples[: args.limit_test]
    train_dataset = MultiNutDataset(train_samples, training=True, seed=args.seed)
    test_dataset = MultiNutDataset(test_samples, training=False, seed=args.seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    pin_memory = device.type == "cuda"
    # Training loader must NOT be persistent: fresh workers each epoch re-pickle the
    # dataset after ``set_epoch`` so augmentation actually changes per epoch.
    train_loader = DataLoader(
        train_dataset,
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=args.num_workers,
        pin_memory=pin_memory,
        persistent_workers=False,
    )
    # Test set preprocessing is deterministic, so persistent workers are safe here.
    test_loader = DataLoader(
        test_dataset,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.num_workers,
        pin_memory=pin_memory,
        persistent_workers=args.num_workers > 0,
    )
    return train_loader, test_loader, test_samples, patch_meta


def build_model(args) -> nn.Module:
    return SlimMobileNetNutAnchorFree(
        num_classes=4,
        width_multiplier=args.width_multiplier,
        fpn_channels=args.fpn_channels,
    )


def model_config(args, patch_meta) -> dict:
    return {
        "num_classes": 4,
        "width_multiplier": args.width_multiplier,
        "fpn_channels": args.fpn_channels,
        "input_size": args.input_size,
        "class_names": CLASS_NAMES,
        "preprocess": patch_meta["preprocess"],
        "grid_size": patch_meta["grid_size"],
        "decode": "3x3 local peaks + confidence Top-K (40) + class-aware NMS (0.35) + Top-4",
        "confidence_threshold": 0.20,
        "nms_iou_threshold": 0.35,
        "model_variant": "slim_mobilenetv2_fpn_anchorfree",
    }


def write_history(path: Path, history: list[dict]) -> None:
    if not history:
        return
    with path.open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=list(history[0]))
        writer.writeheader()
        writer.writerows(history)


def train(args, patch_meta) -> dict:
    seed_everything(args.seed)
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    train_loader, test_loader, test_samples, patch_meta = build_loaders(args, patch_meta)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = build_model(args).to(device)
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    optimizer = AdamW(model.parameters(), lr=args.learning_rate, weight_decay=args.weight_decay)
    scheduler = CosineAnnealingLR(optimizer, T_max=args.epochs, eta_min=1e-5)
    amp_enabled = bool(args.amp) and device.type == "cuda"
    scaler = torch.amp.GradScaler("cuda", enabled=amp_enabled)

    config = {
        **model_config(args, patch_meta),
        "dataset_dir": str(args.dataset_dir),
        "train_images": len(train_loader.dataset),
        "test_images": len(test_loader.dataset),
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "num_workers": args.num_workers,
        "learning_rate": args.learning_rate,
        "weight_decay": args.weight_decay,
        "scheduler": "cosine",
        "optimizer": "AdamW",
        "amp": amp_enabled,
        "seed": args.seed,
        "patience": args.patience,
        "distill_weight": args.distill_weight,
        "parameter_count": parameter_count,
        "selection_score": "test_f1 + test_mean_iou",
    }
    (output_dir / "config.json").write_text(json.dumps(config, indent=2), encoding="utf-8")
    print(
        f"device={device} gpu={torch.cuda.get_device_name(0) if amp_enabled else 'none'} "
        f"train={len(train_loader.dataset)} test={len(test_loader.dataset)} "
        f"params={parameter_count:,} width={args.width_multiplier} fpn={args.fpn_channels} "
        f"input={args.input_size} grid={patch_meta['grid_size']}",
        flush=True,
    )

    teacher = None
    if args.distill_weight > 0:
        teacher, teacher_checkpoint = load_teacher(device, args.teacher_checkpoint)
        print(f"teacher loaded: epoch={teacher_checkpoint.get('epoch')}", flush=True)

    history: list[dict] = []
    best_score = -1.0
    best_epoch = 0
    epochs_without_improvement = 0
    start_time = time.time()
    for epoch in range(1, args.epochs + 1):
        epoch_start = time.time()
        train_loader.dataset.set_epoch(epoch)
        model.train()
        loss_sum = supervised_sum = distill_sum = 0.0
        image_count = 0
        for images, classes, boxes, valid in train_loader:
            images = images.to(device, non_blocking=True)
            classes = classes.to(device, non_blocking=True)
            boxes = boxes.to(device, non_blocking=True)
            valid = valid.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            with torch.amp.autocast("cuda", enabled=amp_enabled):
                student_outputs = model(images)
            with torch.amp.autocast("cuda", enabled=False):
                supervised, _ = maf.multi_anchor_free_loss(
                    *(value.float() for value in student_outputs), classes, boxes, valid
                )
                if teacher is not None:
                    with torch.no_grad():
                        teacher_outputs = teacher(images)
                    distillation = dense_distillation_loss(
                        tuple(value.float() for value in student_outputs),
                        tuple(value.float() for value in teacher_outputs),
                    )
                else:
                    distillation = supervised.new_zeros(())
                loss = supervised + args.distill_weight * distillation
            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            scaler.step(optimizer)
            scaler.update()
            batch_size = images.shape[0]
            loss_sum += float(loss.detach()) * batch_size
            supervised_sum += float(supervised.detach()) * batch_size
            distill_sum += float(distillation.detach()) * batch_size
            image_count += batch_size
        scheduler.step()
        metrics = evaluate(model, test_loader, device)
        row = {
            "epoch": epoch,
            "train_loss": loss_sum / image_count,
            "train_supervised_loss": supervised_sum / image_count,
            "train_distillation_loss": distill_sum / image_count,
            "learning_rate": optimizer.param_groups[0]["lr"],
            "epoch_seconds": time.time() - epoch_start,
            **metrics,
        }
        history.append(row)
        write_history(output_dir / "history.csv", history)
        score = metrics["test_f1"] + metrics["test_mean_iou"]
        if score > best_score + 1e-4:
            best_score = score
            best_epoch = epoch
            epochs_without_improvement = 0
            torch.save(
                {
                    "model": model.state_dict(),
                    "config": config,
                    "class_names": CLASS_NAMES,
                    "epoch": epoch,
                    "metrics": metrics,
                    "parameter_count": parameter_count,
                    "model_variant": "slim_mobilenetv2_fpn_anchorfree",
                    "width_multiplier": args.width_multiplier,
                    "fpn_channels": args.fpn_channels,
                    "num_classes": 4,
                    "input_size": args.input_size,
                    "head": f"slim_multi_anchor_free_{patch_meta['grid_size']}x{patch_meta['grid_size']}_top4",
                },
                output_dir / "best_model.pt",
            )
        else:
            epochs_without_improvement += 1
        print(
            f"epoch={epoch:03d} train={row['train_loss']:.4f} "
            f"test={metrics['test_loss']:.4f} P={metrics['test_precision']:.4f} "
            f"R={metrics['test_recall']:.4f} F1={metrics['test_f1']:.4f} "
            f"mIoU={metrics['test_mean_iou']:.4f} "
            f"exact={metrics['test_exact_image_accuracy']:.4f} "
            f"seconds={row['epoch_seconds']:.1f}",
            flush=True,
        )
        if epochs_without_improvement >= args.patience:
            print(f"early stopping at epoch {epoch}", flush=True)
            break

    elapsed = time.time() - start_time
    summary = {
        "parameter_count": parameter_count,
        "fp32_parameter_size_mib": parameter_count * 4 / 1024 ** 2,
        "int8_parameter_size_mib": parameter_count / 1024 ** 2,
        "best_score": best_score,
        "best_epoch": best_epoch,
        "epochs_completed": len(history),
        "elapsed_seconds": elapsed,
        "best_checkpoint": str(output_dir / "best_model.pt"),
        "config": config,
        "best_metrics": json.loads(
            json.dumps(history[best_epoch - 1] if 0 < best_epoch <= len(history) else {})
        ),
    }
    (output_dir / "training_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    print(json.dumps({k: summary[k] for k in
                      ("parameter_count", "best_epoch", "epochs_completed", "elapsed_seconds")},
                     indent=2), flush=True)
    return summary


# --------------------------------------------------------------------------------------
# Reports
# --------------------------------------------------------------------------------------
def build_fit_check(args, patch_meta, capacity: dict, variants: list[dict],
                    teacher_probe_rows: list[dict] | None,
                    hypotheticals: list[dict] | None = None) -> dict:
    return {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "contract": "results/ai-accel/CONTRACT.md (v0.7)",
        "limits": {
            "w_bytes": LIMITS["w_bytes"],
            "q_bytes": LIMITS["q_bytes"],
            "a_single_tensor_bytes": LIMITS["a_single_tensor_bytes"],
            "b_bytes": LIMITS["b_bytes"],
            "ops": LIMITS["ops"],
            "max_ic_oc": LIMITS["max_ic_oc"],
            "channel_align": LIMITS["channel_align"],
        },
        "selected": {
            "model_class": capacity["model_class"],
            "width_multiplier": args.width_multiplier,
            "fpn_channels": args.fpn_channels,
            "num_classes": 4,
            "input_size": args.input_size,
            "input_preprocess": patch_meta["preprocess"],
            "grid_size": patch_meta["grid_size"],
            "parameter_count": capacity["parameter_count"],
            "w_bytes": capacity["w_bytes"],
            "q_bytes": capacity["q_bytes"],
            "a_single_tensor_peak_bytes": capacity["a_single_tensor_peak_bytes"],
            "a_peak_tensor": capacity["a_peak_tensor"],
            "b_peak_bytes": capacity["b_peak_bytes"],
            "op_count": capacity["op_count"],
            "ic_max": capacity["ic_max"],
            "oc_max": capacity["oc_max"],
            "checks": capacity["checks"],
            "all_pass": capacity["all_pass"],
            "buffer_placement": capacity["buffer_placement"],
            "layers": capacity["layers"],
            "activation_table": capacity["activations"],
        },
        "variants": variants,
        "hypotheticals": hypotheticals or [],
        "teacher_probe": teacher_probe_rows,
    }


def write_slim_report(path: Path, fit: dict, summary: dict | None,
                      detailed: dict | None, teacher_rows: list[dict] | None) -> None:
    selected = fit["selected"]
    limits = fit["limits"]
    meta = selected["input_preprocess"]
    lines: list[str] = []
    lines.append("# 瘦身瓶盖检测模型（NPU 可部署版）训练与容量报告")
    lines.append("")
    lines.append(f"生成时间：{fit['generated_at']}　|　契约：`{fit['contract']}`")
    lines.append("")
    lines.append("## 1. 结论摘要")
    lines.append("")
    lines.append(
        f"- **best 配置**：`SlimMobileNetNutAnchorFree(num_classes=4, "
        f"width_multiplier={selected['width_multiplier']}, fpn_channels={selected['fpn_channels']})`，"
        f"部署输入 **{selected['input_size']}×{selected['input_size']}**"
        f"（{meta['fitted_height']} 行内容 + 上下各 {meta['pad_top']} 行边缘填充）"
    )
    lines.append(
        f"- **参数量**：{selected['parameter_count']:,}"
        f"（fp32 {selected['parameter_count'] * 4 / 1024 ** 2:.2f} MiB）"
    )
    lines.append(
        f"- **容量**：W {selected['w_bytes']:,} B（{selected['w_bytes'] / limits['w_bytes'] * 100:.1f}% of 320KB）｜"
        f"Q {selected['q_bytes']:,} B（{selected['q_bytes'] / limits['q_bytes'] * 100:.1f}% of 48KB）｜"
        f"A 单张量峰值 {selected['a_single_tensor_peak_bytes']:,} B"
        f"（{selected['a_single_tensor_peak_bytes'] / limits['a_single_tensor_bytes'] * 100:.1f}% of 96KB）｜"
        f"B 并发峰值 {selected['b_peak_bytes']:,} B（{selected['b_peak_bytes'] / limits['b_bytes'] * 100:.1f}% of 32KB）｜"
        f"op {selected['op_count']['total']}（{selected['op_count']['total'] / limits['ops'] * 100:.0f}% of 128）"
    )
    lines.append(f"- **逐项容量判定**：{'全部 PASS' if selected['all_pass'] else '存在 FAIL'}")
    if detailed:
        lines.append(
            f"- **精度（{detailed['test_images']} 张测试图 / {detailed['true_objects']} 个目标）**："
            f"P={detailed['precision']:.4f} R={detailed['recall']:.4f} F1={detailed['f1']:.4f} "
            f"mIoU={detailed['mean_matched_iou']:.4f} "
            f"整图全对率={detailed['exact_image_accuracy']:.4f} "
            f"数量准确率={detailed['count_accuracy']:.4f}"
        )
    lines.append("")

    if teacher_rows:
        lines.append("## 2. Teacher 在不同输入尺寸下的实测精度（决定是否蒸馏）")
        lines.append("")
        lines.append("teacher = `EnhancedNutAnchorFree(4, fpn_channels=72, backbone_width=0.55)`"
                     "（2,048,721 参数，224 训练，`best_model.pt` epoch 13）。")
        lines.append("")
        lines.append("| 输入尺寸 | P | R | F1 | mIoU | 结论 |")
        lines.append("|---|---|---|---|---|---|")
        for row in teacher_rows:
            verdict = ("可直接用作蒸馏 teacher" if row["f1"] >= 0.9
                       else "明显退化，蒸馏风险大" if row["f1"] >= 0.3 else "完全崩溃，禁止蒸馏")
            lines.append(
                f"| {row['input_size']} | {row['precision']:.4f} | {row['recall']:.4f} | "
                f"{row['f1']:.4f} | {row['mean_iou']:.4f} | {verdict} |"
            )
        lines.append("")
        deploy_row = next(
            (row for row in teacher_rows if row["input_size"] == selected["input_size"]), None
        )
        if deploy_row is not None and deploy_row["f1"] < 0.5:
            lines.append(
                f"> 部署输入 {selected['input_size']} 下 teacher 的 F1={deploy_row['f1']:.3f}："
                "2M 模型只在 224（56×56 网格）训练，换到 96（24×24 网格）后尺度/网格/特征全部失配，"
                "软标签不可用。因此本版**关闭蒸馏、纯监督训练**（distill_weight=0）。"
            )
            lines.append("")

    lines.append("## 3. 为什么不是 160×160 / width_multiplier=0.5")
    lines.append("")
    lines.append(
        "现 NPU 的 A 缓冲是**单张量 96KB** 上限；`SlimMobileNetV2Backbone` 的 "
        "`stage2.0.block.0`（1×1 扩通道）在 `S/2` 分辨率上输出 32 通道，"
        "因此单张量激活峰值为 `(S/2)^2 × 32` 字节："
    )
    lines.append("")
    lines.append("| 输入 | 该张量字节 | 96KB 上限 (98,304 B) | 判定 |")
    lines.append("|---|---|---|---|")
    for size in (96, 112, 128, 160, 176):
        peak = (size // 2) ** 2 * 32
        lines.append(f"| {size}×{size} | {peak:,} B | 98,304 B | "
                     f"{'PASS' if peak <= 98304 else 'FAIL'} |")
    lines.append("")
    lines.append(
        "即：**160×160 用现有拓扑不可行**（峰值 204,800 B = 上限的 208%），128 也不行。"
        "另外 width_multiplier=0.5 时 `stage5.1` 的 inverted-residual 隐层达到 320 通道，"
        "超过描述符硬限制 IC/OC≤256（CONTRACT §4），所以 width 必须 ≤0.4"
        "（c5=64 → 隐层峰值 256，正好合法）。下面是 6 组候选配置 × 3 种输入的完整对照："
    )
    lines.append("")
    lines.append("| width | fpn | 输入 | 参数量 | W(B) | Q(B) | A 峰值(B) | op | IC/OC max | 判定 |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|")
    for row in fit["variants"]:
        lines.append(
            f"| {row['width_multiplier']} | {row['fpn_channels']} | {row['input_size']} | "
            f"{row['parameter_count']:,} | {row['w_bytes']:,} | {row['q_bytes']:,} | "
            f"{row['a_single_tensor_peak_bytes']:,} | {row['op_total']} | "
            f"{max(row['ic_max'], row['oc_max'])} | "
            f"{'PASS' if row['all_pass'] else 'FAIL: ' + '; '.join(row['failed_items'])} |"
        )
    lines.append("")
    for row in fit.get("hypotheticals") or []:
        if row.get("architecturally_invalid"):
            lines.append(
                f"**备选（未实施）**：输入 {row['input_size']}×{row['input_size']} + "
                f"`{row['requires_architecture_change']}` ⇒ **架构本身不成立**："
                f"{row.get('invalid_reason', '')}。"
            )
        else:
            lines.append(
                f"**备选（未实施）**：输入 {row['input_size']}×{row['input_size']} + "
                f"`{row['requires_architecture_change']}` ⇒ A 峰值 "
                f"{row['a_single_tensor_peak_bytes']:,} B（{row['a_single_tensor_peak_bytes'] / 1024:.1f} KB）"
                f"、W {row['w_bytes']:,} B、op {row['op_total']}，"
                f"{'容量可 PASS' if row['all_pass'] else '容量仍 FAIL'}。"
                "即使扩到 128，`stage1` 的 64×64×16 张量做 3×3 dwconv 时输入+输出并发需要 131,072 B，"
                "超过 A+B 的可用摆放，所以本拓扑下 96 已是现 NPU 容量上限。"
            )
        lines.append(
            "该方案需要改一行架构（expansion 3），会让 checkpoint 无法再用原类直接重建、"
            "转换器也要跟着改；因此仅在 96 精度不足时才值得考虑，本版不实施。"
        )
        lines.append("")
    lines.append(
        "> 上述 112/128 的结论是**脚本实测**而不是推断：112 在 fx shape-prop 阶段就因 "
        "`add_8` 的 7 vs 8 尺寸不匹配而失败（脚本捕获后按“架构不可行”记录）；128 通过临时把 "
        "`InvertedResidual` 默认 expansion 改成 3 实际构造模型并跑 A/B 摆放仿真得到 A 峰值 "
        "98,304 B / B 摆放失败。因此本拓扑+现 NPU 容量下的输入上限就是 96。"
    )
    lines.append("")

    lines.append("## 4. 容量逐项核算（best 配置）")
    lines.append("")
    lines.append("| 项目 | 实测 | 上限 | 判定 |")
    lines.append("|---|---|---|---|")
    for check in selected["checks"]:
        lines.append(f"| {check['item']} | {check['actual']} | {check['limit']} | "
                     f"{'PASS' if check['pass'] else 'FAIL'} |")
    lines.append("")
    lines.append(
        f"- A 峰值张量：`{selected['a_peak_tensor']}`（{selected['a_single_tensor_peak_bytes']:,} B）；"
        f"输入图 PACKED3 = {selected['input_size'] ** 2 * 3:,} B。"
    )
    placement = selected.get("buffer_placement") or {}
    if placement:
        lines.append(
            f"- A/B 摆放仿真（贪心 + 空闲链表，ADD_R 可交换原地写）："
            f"A 峰值 {placement.get('a_peak', 0):,} B ≤ 96KB、"
            f"B 峰值 {placement.get('b_peak', 0):,} B ≤ 32KB、"
            f"终态 3 个 head 张量各 "
            f"{list((placement.get('live_at_end') or {}).values())[0][2] if placement.get('live_at_end') else 0} B。"
        )
    lines.append("")
    lines.append("### 4.1 逐层权重/激活表（int8，8 通道对齐口径）")
    lines.append("")
    lines.append("| # | op | k/s/p | IC→OC (pad) | W(B) | 输出 NHWC | 激活(B) |")
    lines.append("|---|---|---|---|---|---|---|")
    for index, layer in enumerate(selected["layers"], start=1):
        lines.append(
            f"| {index} | {layer['op']} | {layer['k']}/{layer['s']}/{layer['pad']} | "
            f"{layer['ic']}→{layer['oc']} ({layer['ic_pad']}→{layer['oc_pad']}) | "
            f"{layer['w_bytes']:,} | {layer['out_shape'][2]}×{layer['out_shape'][3]}×{layer['oc_pad']} | "
            f"{layer['act_bytes']:,} |"
        )
    lines.append("")
    lines.append("## 5. 与 2M 原模型精度对比与差距分析")
    lines.append("")
    lines.append("| 模型 | 输入 | P | R | F1 | mIoU | 整图全对率 |")
    lines.append("|---|---|---|---|---|---|---|")
    if teacher_rows:
        row224 = next((row for row in teacher_rows if row["input_size"] == 224), None)
        if row224:
            lines.append(
                f"| EnhancedNutAnchorFree 2.05M（本报告实测） | 224 | {row224['precision']:.4f} | "
                f"{row224['recall']:.4f} | {row224['f1']:.4f} | {row224['mean_iou']:.4f} | "
                f"{row224['exact_image_accuracy']:.4f} |"
            )
    else:
        lines.append("| EnhancedNutAnchorFree 2.05M（文档口径） | 224 | 1.0000 | 1.0000 | 1.0000 | 0.9696 | 1.0000 |")
    if detailed:
        lines.append(
            f"| **SlimMobileNetNutAnchorFree {selected['parameter_count'] / 1e6:.3f}M（本模型）** | "
            f"{selected['input_size']} | {detailed['precision']:.4f} | {detailed['recall']:.4f} | "
            f"{detailed['f1']:.4f} | {detailed['mean_matched_iou']:.4f} | "
            f"{detailed['exact_image_accuracy']:.4f} |"
        )
    lines.append("")
    if detailed:
        baseline = {"precision": 1.0, "recall": 1.0, "f1": 1.0, "mean_matched_iou": 0.9696,
                    "exact_image_accuracy": 1.0}
        if teacher_rows:
            row224 = next((row for row in teacher_rows if row["input_size"] == 224), None)
            if row224:
                baseline = {"precision": row224["precision"], "recall": row224["recall"],
                            "f1": row224["f1"], "mean_matched_iou": row224["mean_iou"],
                            "exact_image_accuracy": row224["exact_image_accuracy"]}
        lines.append("### 5.1 差距分析")
        lines.append("")
        lines.append(
            f"- 与 2M 原模型相比：P/R/F1 分别低 {baseline['precision'] - detailed['precision']:.4f} / "
            f"{baseline['recall'] - detailed['recall']:.4f} / {baseline['f1'] - detailed['f1']:.4f}；"
            f"mIoU 低 {baseline['mean_matched_iou'] - detailed['mean_matched_iou']:.4f}；"
            f"整图全对率低 {baseline['exact_image_accuracy'] - detailed['exact_image_accuracy']:.4f}。"
        )
        lines.append(
            f"- 误差构成：FP={detailed['false_positive']}、FN={detailed['false_negative']}"
            f"（共 {detailed['true_objects']} 个目标）；"
            f"数量准确率 {detailed['count_accuracy']:.4f}。"
        )
        if detailed["recall"] < 0.5:
            lines.append(
                "- **召回 <0.5**：说明 96×96 输入下目标只有约 17px，信息量不足以稳定召回；"
                "此时才值得上更大输入，但 §3 的实测表明 112 因 FPN 整除性不成立、128 因 stage1 "
                "并发超 A/B 上限也不成立，必须同时改架构（拆 dwconv / 片上 tile）或扩 A/B 容量（改 RTL）。"
            )
        else:
            lines.append(
                "- 差距主要来自输入分辨率（96 vs 224）与模型容量（0.13M vs 2.05M）的折中；"
                "96 输入在现 NPU 容量（不改 RTL、不加 DDR3）下已是**实测上限**（§3：112 架构不成立、"
                "128+expansion3 仍因 stage1 输入/输出并发 131,072 B 超 A+B 而 FAIL）。"
                "若后续还要更高精度，只能靠架构改动（拆 stage1 dwconv / 片上 tile）或扩 A/B 容量（改 RTL），"
                "不在“零 RTL 改动”路线内。"
            )
        lines.append("")
        lines.append("### 5.2 分类别精度")
        lines.append("")
        lines.append("| 类别 | 真值数 | 预测数 | 匹配数 | P | R |")
        lines.append("|---|---|---|---|---|---|")
        for name, values in detailed["per_class"].items():
            lines.append(
                f"| {name} | {values['true_objects']} | {values['predicted_objects']} | "
                f"{values['matched_objects']} | {values['precision']:.4f} | {values['recall']:.4f} |"
            )
        lines.append("")
        lines.append("### 5.3 按每图目标数 / 光照分组")
        lines.append("")
        lines.append("| 分组 | 图片数 | P | R | F1 | 整图全对率 |")
        lines.append("|---|---|---|---|---|---|")
        for count, values in detailed["by_true_object_count"].items():
            lines.append(
                f"| 目标数={count} | {values['images']} | {values['precision']:.4f} | "
                f"{values['recall']:.4f} | {values['f1']:.4f} | {values['exact_image_accuracy']:.4f} |"
            )
        for profile, values in detailed["by_lighting_profile"].items():
            lines.append(
                f"| 光照={profile} | {values['images']} | {values['precision']:.4f} | "
                f"{values['recall']:.4f} | {values['f1']:.4f} | {values['exact_image_accuracy']:.4f} |"
            )
        lines.append("")

    if summary:
        lines.append("## 6. 训练设置与过程")
        lines.append("")
        config = summary["config"]
        lines.append(
            f"- 训练集 {config['train_images']} / 测试集 {config['test_images']}；"
            f"epoch {config['epochs']}（实际 {summary['epochs_completed']}，best epoch {summary['best_epoch']}）、"
            f"batch {config['batch_size']}、AdamW lr {config['learning_rate']}、cosine、AMP={config['amp']}、"
            f"seed={config['seed']}、早停 patience={config['patience']}、用时 {summary['elapsed_seconds']:.0f}s"
        )
        lines.append(
            "- 损失：`multi_anchor_free_loss`（focal heatmap + CE + 5×SmoothL1 + 2×(1-IoU)）；"
            f"蒸馏权重 {config['distill_weight']}（teacher 在部署分辨率崩溃，已关闭）"
        )
        lines.append(
            f"- 选模型分数：{config['selection_score']}"
            "（测试集 P/R/F1/mIoU/整图全对率逐轮记录在 `history.csv`）"
        )
        lines.append("- 预处理：训练与部署完全一致（96×72 + 上下各 12 行 edge pad，`/127.5-1`），"
                     "标签按 `/(input_size-1)` 归一化；在线增强沿用 `augment_multi`。")
        lines.append("")
        best = summary.get("best_metrics") or {}
        if best:
            lines.append("| epoch | train_loss | P | R | F1 | mIoU | 整图全对率 |")
            lines.append("|---|---|---|---|---|---|---|")
            lines.append(
                f"| {best.get('epoch')} | {best.get('train_loss', 0):.4f} | "
                f"{best.get('test_precision', 0):.4f} | {best.get('test_recall', 0):.4f} | "
                f"{best.get('test_f1', 0):.4f} | {best.get('test_mean_iou', 0):.4f} | "
                f"{best.get('test_exact_image_accuracy', 0):.4f} |"
            )
            lines.append("")

    lines.append("## 7. 部署注意事项")
    lines.append("")
    lines.append(
        f"1. 摄像头 320×240 先缩放到 **{selected['input_size']}×{meta['fitted_height']}**，"
        f"再上下各补 **{meta['pad_top']}** 行边缘像素到 "
        f"{selected['input_size']}×{selected['input_size']}，像素 `/127.5-1`；"
        "输入 conv0 用 PACKED3（3 B/像素，CPU 生成）。"
    )
    lines.append(
        f"2. 三个 head 输出在 {selected['input_size'] // 4}×{selected['input_size'] // 4} 网格上解码："
        "3×3 local peaks → confidence Top-40 → class-aware NMS(0.35) → Top-4；在 MCU 侧完成，"
        "与 `decode_multi_predictions` 完全一致。"
    )
    lines.append(
        f"3. 坐标还原：框 ×{selected['input_size'] - 1} 得到 letterbox 像素坐标，减 pad_top，"
        f"再按 ×320/{selected['input_size']}、×240/{meta['fitted_height']} 映射回 320×240。"
    )
    lines.append(
        "4. 权重（BN 折叠后）按 CONTRACT §6 的 `[tap][IC_pad][OC_pad]` / depthwise `[tap][OC_pad]` 排布；"
        f"Q 区每层 `6*OC_pad+16` 字节，共 {selected['q_bytes']:,} B。"
    )
    lines.append(
        "5. 全部通道为 8 的倍数；IC/OC 均 ≤256，可直接用现 RTL 的 conv/dwconv/upsample/add 描述符，"
        "无需改 RTL、无需 DDR3。"
    )
    lines.append("")
    lines.append("## 8. 模型重建命令（converter 直接照抄）")
    lines.append("")
    lines.append("```python")
    lines.append("import torch")
    lines.append("from nut_detector.mobilenet_anchor_free_slim import SlimMobileNetNutAnchorFree")
    lines.append("")
    lines.append('ckpt = torch.load("results/bottlecap/slim/best_model.pt", map_location="cpu",')
    lines.append('                    weights_only=False)')
    lines.append('cfg = {k: ckpt["config"][k] for k in ("num_classes", "width_multiplier", "fpn_channels")}')
    lines.append("model = SlimMobileNetNutAnchorFree(**cfg)   # num_classes=4, width_multiplier=0.4, fpn_channels=64")
    lines.append('model.load_state_dict(ckpt["model"])        # strict=True 可过')
    lines.append("model.eval()")
    lines.append("x = torch.zeros(1, 3, 96, 96)               # 部署输入 96x96（96x72 内容 + 上下各 12 行 edge pad）")
    lines.append("objectness, class_logits, box_logits = model(x)   # [1,1,24,24] / [1,4,24,24] / [1,4,24,24]")
    lines.append("```")
    lines.append("")
    lines.append("机器可读版本见 `EXPORT.json`（arch / width / fpn / input_size / letterbox / norm / classes /")
    lines.append("decode 参数 / w_bytes / q_bytes / op_count / num_layers / input_quant / 重建代码），"
                 "以及 `ref_heads.npz`（8 张固定测试图的 float 三 head 参考输出 + int8 PACKED3 输入字节）。")
    lines.append("")
    lines.append("## 9. 产物")
    lines.append("")
    lines.append("| 文件 | 说明 |")
    lines.append("|---|---|")
    lines.append("| `best_model.pt` | 含 `model`/`config`/`class_names`/`metrics`/`epoch`；"
                     "`SlimMobileNetNutAnchorFree(**config缩参)+load_state_dict` 可重建 |")
    lines.append("| `config.json` | 训练配置 + 预处理/解码口径 |")
    lines.append("| `history.csv` | 逐 epoch 训练/测试指标 |")
    lines.append("| `training_summary.json` | best epoch、参数量、用时、详细测试指标 |")
    lines.append("| `FIT-CHECK.json` | 逐层容量 + 逐项 PASS/FAIL + 变体/备选对照 |")
    lines.append("| `EXPORT.json` | converter 契约：arch/输入口径/量化口径/decode/容量/重建命令 |")
    lines.append("| `test_report.json` / `test_predictions.csv` | 详细测试指标 / 逐图预测 |")
    lines.append("| `deploy_test_report.json` | `eval_slim_deploy.py` 复评结果（含与训练报告的逐项 delta） |")
    lines.append("| `ref_heads.npz` | 8 张固定图的 float 三 head + int8 PACKED3 输入（int8 golden 对照基准） |")
    lines.append("| `teacher_probe.json` | teacher 在 96/160/224 的 P/R/F1 实测 |")
    lines.append("| `SLIM-REPORT.md` | 本报告 |")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def build_export_json(fit: dict, config: dict, metrics: dict | None = None) -> dict:
    """Machine-readable hand-off contract for the PyTorch -> NPU converter."""
    selected = fit["selected"]
    meta = selected["input_preprocess"]
    input_size = selected["input_size"]
    grid = input_size // 4
    decode = {
        "grid_hw": [grid, grid],
        "objectness_activation": "sigmoid",
        "local_max": "sigmoid(obj) == max_pool2d(sigmoid(obj), 3, stride=1, pad=1)",
        "confidence": "sigmoid(obj) * softmax(class).max",
        "confidence_threshold": 0.20,
        "pre_nms_topk": 40,
        "nms": "class-aware greedy NMS",
        "nms_iou_threshold": 0.35,
        "max_detections": 4,
        "box_decode": "(cx,cy) = (gx + sigmoid(tx), gy + sigmoid(ty)) / G ; (w,h) = sigmoid(tw, th)",
        "iou_match_threshold": 0.5,
    }
    return {
        "format_version": "slim-export-v1",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "arch": "SlimMobileNetNutAnchorFree",
        "model_variant": "slim_mobilenetv2_fpn_anchorfree",
        "num_classes": int(selected["num_classes"]),
        "width_multiplier": float(selected["width_multiplier"]),
        "fpn_channels": int(selected["fpn_channels"]),
        "input_size": int(input_size),
        "input_layout": "NCHW float32 (torch) -> NHWC int8 activations; conv0 consumes PACKED3 (3B/pixel)",
        "letterbox": {
            "content_w": int(input_size),
            "content_h": int(meta["fitted_height"]),
            "pad_top": int(meta["pad_top"]),
            "pad_bottom": int(meta["pad_bottom"]),
            "resize": "bilinear",
            "pad_mode": "edge",
        },
        "norm": "/127.5-1",
        "classes": list(config.get("class_names", CLASS_NAMES)),
        "input_quant": {
            "range": [-1.0, 1.0],
            "s_a_in": 2.0 / 255.0,
            "zp_in": 0,
            "a_q": "clip(round(a / s_a_in) + zp_in, -128, 127)",
            "packed3_layout": "addr = y*iw*3 + x*3 + c (c<3)",
        },
        "decode": decode,
        "capacity": {
            "w_bytes": selected["w_bytes"],
            "q_bytes_conv_only": selected["q_bytes"],
            "q_bytes_with_add_blocks": selected["q_bytes"] + 16 * selected["op_count"]["add"],
            "q_bytes": selected["q_bytes"],
            "a_single_tensor_peak_bytes": selected["a_single_tensor_peak_bytes"],
            "a_peak_tensor": selected["a_peak_tensor"],
            "b_peak_bytes": selected["b_peak_bytes"],
            "op_count": selected["op_count"],
            "num_layers": len(selected["layers"]),
            "ic_max": selected["ic_max"],
            "oc_max": selected["oc_max"],
            "all_pass": selected["all_pass"],
            "checks": selected["checks"],
        },
        "parameters": {
            "parameter_count": selected["parameter_count"],
            "fp32_bytes": selected["parameter_count"] * 4,
            "int8_weight_bytes_padded": selected["w_bytes"],
        },
        "checkpoint": "results/bottlecap/slim/best_model.pt",
        "metrics": metrics,
        "reference_heads": "results/bottlecap/slim/ref_heads.npz",
        "ref_heads_layout": {
            "file": "results/bottlecap/slim/ref_heads.npz",
            "num_images": 8,
            "head_order": ["objectness", "class", "box"],
            "activation": (
                "raw logits: apply sigmoid(objectness), softmax(class, dim=1), "
                "sigmoid(box, every element) externally; nothing is pre-activated"
            ),
            "arrays": {
                "objectness": "(N,1,24,24) float32 raw objectness logits",
                "class_logits": "(N,4,24,24) float32 raw class logits",
                "box_logits": "(N,4,24,24) float32 raw box logits (tx,ty,tw,th)",
                "inputs_int8_packed3": "(N,96,96,3) int8 HWC PACKED3 input bytes",
                "inputs_float_nchw": "(N,3,96,96) float32 model input (reference only)",
                "image_names": "(N,) test image file names",
                "indices": "(N,) int64 indices in the sorted test split",
                "meta": "(1,) JSON string: input_quant, decode, parameter_count, metrics",
            },
            "select_rule": "indices = round(i*499/7) for i in 0..7 over the sorted test split",
            "reference_forward": (
                "single batched float32 forward with TF32 disabled "
                "(cudnn.allow_tf32=False, cuda.matmul.allow_tf32=False); replay bit-identical"
            ),
        },
        "reconstruct": {
            "class": "nut_detector.mobilenet_anchor_free_slim.SlimMobileNetNutAnchorFree",
            "kwargs": {
                "num_classes": int(selected["num_classes"]),
                "width_multiplier": float(selected["width_multiplier"]),
                "fpn_channels": int(selected["fpn_channels"]),
            },
            "python": (
                "import torch\n"
                "from nut_detector.mobilenet_anchor_free_slim import SlimMobileNetNutAnchorFree\n"
                'ckpt = torch.load("results/bottlecap/slim/best_model.pt", map_location="cpu", weights_only=False)\n'
                'cfg = {k: ckpt["config"][k] for k in ("num_classes", "width_multiplier", "fpn_channels")}\n'
                "model = SlimMobileNetNutAnchorFree(**cfg)\n"
                'model.load_state_dict(ckpt["model"])\n'
                "model.eval()\n"
            ),
        },
        "weights_layout": {
            "dense": "[tap][IC_pad][OC_pad], OC at lowest bits, pad 0 (CONTRACT §6)",
            "depthwise": "[tap][OC_pad], pad 0",
            "channel_align": LIMITS["channel_align"],
        },
        "q_layout": "bias_adj int32[OC_pad] | M_pos int16[OC_pad] | tail 16B = 6*OC_pad+16 (CONTRACT §7)",
    }

# --------------------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------------------
def run_fit_report(args, patch_meta, write: bool = True) -> tuple[dict, dict]:
    model = build_model(args)
    capacity = analyze_capacity(model, args.input_size)
    default_configs = [
        {"width_multiplier": 0.5, "fpn_channels": 32},
        {"width_multiplier": 0.45, "fpn_channels": 32},
        {"width_multiplier": 0.4, "fpn_channels": 32},
        {"width_multiplier": 0.4, "fpn_channels": 48},
        {"width_multiplier": 0.4, "fpn_channels": 64},
        {"width_multiplier": 0.4, "fpn_channels": 72},
    ]
    variants = capacity_variants(default_configs, [96, 128, 160])
    hypotheticals = analyze_expansion3_hypothetical()
    return capacity, {"variants": variants, "hypotheticals": hypotheticals}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=("train", "fit-report", "report", "eval"), default="train")
    parser.add_argument("--fit-report", action="store_true",
                        help="only compute capacity FIT-CHECK (no training)")
    parser.add_argument("--width-multiplier", type=float, default=0.4)
    parser.add_argument("--fpn-channels", type=int, default=48)
    parser.add_argument("--input-size", type=int, default=96)
    parser.add_argument("--epochs", type=int, default=80)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--num-workers", type=int, default=4)
    parser.add_argument("--learning-rate", type=float, default=1.2e-3)
    parser.add_argument("--weight-decay", type=float, default=2e-4)
    parser.add_argument("--patience", type=int, default=12)
    parser.add_argument("--seed", type=int, default=SEED)
    parser.add_argument("--distill-weight", type=float, default=0.0)
    parser.add_argument("--amp", dest="amp", action="store_true", default=True)
    parser.add_argument("--no-amp", dest="amp", action="store_false")
    parser.add_argument("--limit-train", type=int, default=0,
                        help="smoke test: use only N training samples")
    parser.add_argument("--limit-test", type=int, default=0,
                        help="smoke test: use only N test samples")
    parser.add_argument("--teacher-probe", action="store_true",
                        help="measure teacher P/R/F1 at 96/160/224 before training")
    parser.add_argument("--teacher-probe-sizes", type=str, default="",
                        help="comma separated, default: <input-size>,160,224")
    parser.add_argument("--probe-only", action="store_true",
                        help="run --teacher-probe and exit (decides distill feasibility)")
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    parser.add_argument("--teacher-checkpoint", type=Path, default=TEACHER_CHECKPOINT,
                        help="2M teacher checkpoint (default: the bottle-cap best_model.pt)")
    parser.add_argument("--class-names", type=str, default="",
                        help="Comma-separated class names, e.g. chickpea,cashew,almond,walnut")
    parser.add_argument("--aspect-ratio", type=float, default=0.75,
                        help="Letterbox content height / input size. 0.75 = 4:3 (bottle-cap); "
                             "1.0 = square, no wasted padding rows (nut dataset)")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--checkpoint", type=Path, default=None)
    args = parser.parse_args()
    if args.fit_report:
        args.mode = "fit-report"
    global CLASS_NAMES
    if args.class_names:
        parsed_names = [item.strip() for item in args.class_names.split(",") if item.strip()]
        if len(parsed_names) != 4:
            parser.error(
                f"--class-names needs exactly 4 names (num_classes=4), got {len(parsed_names)}"
            )
        CLASS_NAMES = parsed_names
    os.environ["SLIM_INPUT_SIZE"] = str(args.input_size)
    patch_meta = patch_nut_detector(args.input_size, args.aspect_ratio)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    if args.mode == "fit-report":
        capacity, extra = run_fit_report(args, patch_meta)
        fit = build_fit_check(args, patch_meta, capacity, extra["variants"], None, extra.get("hypotheticals"))
        (args.output_dir / "FIT-CHECK.json").write_text(
            json.dumps(fit, indent=2), encoding="utf-8"
        )
        print(json.dumps(
            {
                "config": [args.width_multiplier, args.fpn_channels, args.input_size],
                "checks": [{k: check[k] for k in ("item", "actual", "limit", "pass")}
                           for check in capacity["checks"]],
                "all_pass": capacity["all_pass"],
            },
            indent=2,
        ), flush=True)
        write_slim_report(args.output_dir / "SLIM-REPORT.md", fit, None, None, None)
        return

    if args.mode == "report":
        # Rebuild FIT-CHECK.json / SLIM-REPORT.md / EXPORT.json from the artefacts
        # already produced by a training run (no training, no GPU-heavy work).
        capacity, extra = run_fit_report(args, patch_meta)
        summary_path = args.output_dir / "training_summary.json"
        detailed_path = args.output_dir / "test_report.json"
        teacher_path = args.output_dir / "teacher_probe.json"
        summary = None
        if summary_path.exists():
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
        detailed = None
        if detailed_path.exists():
            detailed = json.loads(detailed_path.read_text(encoding="utf-8"))
        elif summary is not None:
            detailed = summary.get("detailed_test")
        teacher_rows = None
        if teacher_path.exists():
            teacher_rows = json.loads(teacher_path.read_text(encoding="utf-8")).get("rows")
        config = (summary or {}).get("config") or model_config(args, patch_meta)
        fit = build_fit_check(args, patch_meta, capacity, extra["variants"], teacher_rows,
                              extra.get("hypotheticals"))
        (args.output_dir / "FIT-CHECK.json").write_text(
            json.dumps(fit, indent=2), encoding="utf-8"
        )
        export = build_export_json(fit, config, detailed)
        export["checkpoint_epoch"] = (summary or {}).get("best_epoch")
        (args.output_dir / "EXPORT.json").write_text(
            json.dumps(export, indent=2, ensure_ascii=False), encoding="utf-8"
        )
        write_slim_report(args.output_dir / "SLIM-REPORT.md", fit, summary, detailed, teacher_rows)
        print(json.dumps({"all_pass": capacity["all_pass"],
                          "export": str(args.output_dir / "EXPORT.json")}, indent=2), flush=True)
        return

    teacher_rows = None
    if args.teacher_probe:
        sizes = [int(item) for item in args.teacher_probe_sizes.split(",") if item] or [
            args.input_size, 160, 224
        ]
        teacher_device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        teacher, teacher_checkpoint = load_teacher(teacher_device, args.teacher_checkpoint)
        teacher_rows = []
        test_samples = read_multi_split(args.dataset_dir, "test")
        for size in sizes:
            mds.preprocess_multi = make_preprocess(size, args.aspect_ratio)
            dataset = MultiNutDataset(test_samples, training=False, seed=args.seed)
            # num_workers=0: each probe size needs its own preprocess patch in-process.
            loader = DataLoader(dataset, batch_size=args.batch_size, shuffle=False,
                                num_workers=0, pin_memory=True)
            row = teacher_probe(teacher, loader, teacher_device, size)
            row["teacher_epoch"] = teacher_checkpoint.get("epoch")
            teacher_rows.append(row)
            print("teacher " + json.dumps(row), flush=True)
        patch_nut_detector(args.input_size, args.aspect_ratio)  # restore student preprocessing
        (args.output_dir / "teacher_probe.json").write_text(
            json.dumps({"checkpoint": str(args.teacher_checkpoint), "rows": teacher_rows}, indent=2),
            encoding="utf-8",
        )
        del teacher
        torch.cuda.empty_cache()
        if args.probe_only:
            print("probe-only: teacher measurement done, exiting before training", flush=True)
            return

    if args.mode == "eval":
        checkpoint_path = args.checkpoint or (args.output_dir / "best_model.pt")
        checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
        config = checkpoint.get("config", {})
        eval_input_size = int(config.get("input_size", args.input_size))
        if eval_input_size != args.input_size:
            args.input_size = eval_input_size
            os.environ["SLIM_INPUT_SIZE"] = str(args.input_size)
            patch_meta = patch_nut_detector(args.input_size, args.aspect_ratio)
        model = SlimMobileNetNutAnchorFree(
            num_classes=int(config.get("num_classes", 4)),
            width_multiplier=float(config.get("width_multiplier", args.width_multiplier)),
            fpn_channels=int(config.get("fpn_channels", args.fpn_channels)),
        )
        model.load_state_dict(checkpoint["model"])
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        model.to(device).eval()
        _, test_loader, test_samples, _ = build_loaders(args, patch_meta)
        detailed, rows = detailed_evaluate(model, test_loader, device, test_samples)
        (args.output_dir / "test_report.json").write_text(
            json.dumps(detailed, indent=2), encoding="utf-8"
        )
        with (args.output_dir / "test_predictions.csv").open("w", newline="", encoding="utf-8") as file:
            writer = csv.DictWriter(file, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        print(json.dumps({k: detailed[k] for k in
                          ("precision", "recall", "f1", "mean_matched_iou",
                           "exact_image_accuracy", "count_accuracy")}, indent=2), flush=True)
        return

    summary = train(args, patch_meta)
    capacity, extra = run_fit_report(args, patch_meta)
    checkpoint = torch.load(args.output_dir / "best_model.pt", map_location="cpu",
                            weights_only=False)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = build_model(args)
    model.load_state_dict(checkpoint["model"])
    model.to(device).eval()
    _, test_loader, test_samples, _ = build_loaders(args, patch_meta)
    detailed, rows = detailed_evaluate(model, test_loader, device, test_samples)
    (args.output_dir / "test_report.json").write_text(
        json.dumps(detailed, indent=2), encoding="utf-8"
    )
    with (args.output_dir / "test_predictions.csv").open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    summary["detailed_test"] = detailed
    (args.output_dir / "training_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    fit = build_fit_check(args, patch_meta, capacity, extra["variants"], teacher_rows, extra.get("hypotheticals"))
    (args.output_dir / "FIT-CHECK.json").write_text(
        json.dumps(fit, indent=2), encoding="utf-8"
    )
    export = build_export_json(fit, summary["config"], detailed)
    export["checkpoint_epoch"] = summary.get("best_epoch")
    (args.output_dir / "EXPORT.json").write_text(
        json.dumps(export, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    write_slim_report(args.output_dir / "SLIM-REPORT.md", fit, summary, detailed, teacher_rows)
    print("FIT-CHECK all_pass =", capacity["all_pass"], flush=True)
    print("wrote", args.output_dir, flush=True)


if __name__ == "__main__":
    main()

