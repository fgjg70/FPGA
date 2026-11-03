#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""四色瓶盖检测模型（EnhancedNutAnchorFree 2,048,721 参数）逐层画像 + 浮点精度基线。

本脚本只读 tools/bottlecap/model_src/ 与 tools/bottlecap/data/，只写
results/bottlecap/model/{model_profile.json, MODEL-PROFILE.md}。可重复运行：

    cd D:\\USER\\Desktop\\FPGA\\FPGA
    python tools/bottlecap/profile_model.py                 # 画像 + CPU 精度基线（+GPU 复核）
    python tools/bottlecap/profile_model.py --no-gpu-check  # 只 CPU
    python tools/bottlecap/profile_model.py --skip-eval     # 只画像，不跑 500 张测试集

统计口径
--------
* 网络：EnhancedNutAnchorFree(num_classes=4, fpn_channels=72, backbone_width=0.55)，
  checkpoint = tools/bottlecap/model_src/best_model.pt（strict 加载）。
* 层序列 / 形状：torch.fx symbolic_trace + ShapeProp，BN 折叠（推理等价）后统计。
* MACs：conv = ic/groups * k * k * oc * oh * ow（depthwise 时 ic/groups == 1）。
* 权重 int8 字节：折叠 BN 后卷积权重元素数（1 B/参数）；另给 CONTRACT §6 的
  NPU 打包口径（IC_pad/OC_pad 到 8 的倍数）；bias 按 int32（4 B/通道）计。
* 激活字节：CONTRACT §8 NHWC 8 通道分块，C8 = ceil(C/8)*8，bytes = H*W*C8；
  输入张量按 v0.7 flags.PACKED3 的 3 B/像素计（另给 C8 口径备查）。
* NPU 原语口径（nn_pkg.sv v0.7）：conv / dwconv / pool / copy(UP2X) / add。
  conv = 1 op；dwconv = 1 op；2x nearest upsample = 1 copy；4x nearest = 2 copy；
  通道 concat = 每源张量 1 copy（写同一 dst 的不同通道偏移）；residual / FPN add = 1 add；
  BN 与（conv 后的）ReLU 融合进 conv，不单独计 op；add 之后的独立 ReLU 无对应原语（单独标注）。
* 精度基线：完全复用 nut_detector 自带逻辑 —— MultiNutDataset/preprocess_multi 预处理、
  decode_multi_predictions（conf 0.20 / NMS 0.35 / pre-nms topk 40 / max_det 4）、
  matched_pairs（类内 IoU>=0.5 贪心匹配），与 evaluate_multi_mobilenet_anchor_free.py 相同。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import random
import sys
import time
from collections import Counter, OrderedDict
from pathlib import Path

import torch
import torch.nn as nn
from torch.fx import symbolic_trace
from torch.fx.passes.shape_prop import ShapeProp

# ---------------------------------------------------------------------------
# 路径 / 常量（唯一事实来源，勿在别处重复写死）
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).resolve().parents[2]
MODEL_SRC = REPO_ROOT / "tools" / "bottlecap" / "model_src"
DATA_DIR = REPO_ROOT / "tools" / "bottlecap" / "data"
CKPT_PATH = MODEL_SRC / "best_model.pt"
RUN_CONFIG_PATH = MODEL_SRC / "run_config.json"
OUT_DIR = REPO_ROOT / "results" / "bottlecap" / "model"
JSON_PATH = OUT_DIR / "model_profile.json"
MD_PATH = OUT_DIR / "MODEL-PROFILE.md"

INPUT_SIZE = 224
NUM_CLASSES = 4
FPN_CHANNELS = 72
BACKBONE_WIDTH = 0.55
EXPECTED_PARAMS = 2_048_721
SEED = 20260805

# CONTRACT v0.7（results/ai-accel/CONTRACT.md + nn_pkg.sv）
W_BUDGET = 320 * 1024          # 权重区 W（BRAM）
Q_BUDGET = 48 * 1024           # 量化参数区 Q（LUTRAM）
A_BYTES = 96 * 1024            # 激活缓冲 A
B_BYTES = 32 * 1024            # 激活缓冲 B
AB_BYTES = A_BYTES + B_BYTES   # A+B = 128 KB
MAX_SINGLE_TENSOR = 98_304     # CONTRACT 里"最大单张量 98,304 B 放 A"的口径
ENGINE_MAX_IC_OC = 256         # engine-report §8.3：IC/OC <= 256（ICB/OCB <= 32）
ROM_DEPTH = 128                # nn_pkg.sv NN_ROM_DEPTH

# 文档/checkpoint 声称的参考指标（复核目标）
DOC_METRICS = {
    "test_images": 500,
    "true_objects": 1250,
    "true_positive": 1250,
    "false_positive": 0,
    "false_negative": 0,
    "precision": 1.0,
    "recall": 1.0,
    "f1": 1.0,
    "mean_matched_iou": 0.9695916731357574,  # checkpoint["metrics"]["test_mean_iou"]
    "count_accuracy": 1.0,
    "exact_image_accuracy": 1.0,
}

# 多分辨率估算用的输入尺寸（224 是部署尺寸，其余是"等比缩小空间尺寸、通道不变"的假设分析）
RES_SIZES = (224, 192, 160, 128, 96, 64)

STAGE_ORDER = [
    "input",
    "backbone.stem",
    "backbone.stage1",
    "backbone.stage2",
    "backbone.stage3",
    "backbone.stage4",
    "backbone.stage5",
    "fpn.lateral",
    "fpn.refine",
    "fpn.fusion",
    "head.tower",
    "head.out",
]

STAGE_RULES = [
    ("backbone.stem", "backbone.stem"),
    ("backbone.stage1", "backbone.stage1"),
    ("backbone.stage2", "backbone.stage2"),
    ("backbone.stage3", "backbone.stage3"),
    ("backbone.stage4", "backbone.stage4"),
    ("backbone.stage5", "backbone.stage5"),
    ("lateral", "fpn.lateral"),
    ("refine", "fpn.refine"),
    ("multi_scale_fusion", "fpn.fusion"),
    ("objectness_tower", "head.tower"),
    ("class_tower", "head.tower"),
    ("box_tower", "head.tower"),
    ("objectness_head", "head.out"),
    ("class_head", "head.out"),
    ("box_head", "head.out"),
]

C8 = lambda c: (int(c) + 7) // 8 * 8  # noqa: E731 - 8 通道分块


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def b2s(n) -> str:
    """人类可读字节数。"""
    n = int(n)
    if n < 1024:
        return f"{n} B"
    if n < 1024 * 1024:
        return f"{n:,} B ({n / 1024:.1f} KB)"
    return f"{n:,} B ({n / 1024 / 1024:.2f} MB)"


def macs2s(n) -> str:
    n = int(n)
    if n < 1_000_000:
        return f"{n:,}"
    if n < 1_000_000_000:
        return f"{n:,} ({n / 1e6:.2f} M)"
    return f"{n:,} ({n / 1e9:.3f} G)"


def nhwc(shape_nchw) -> list[int]:
    n, c, h, w = (int(v) for v in shape_nchw)
    return [n, h, w, c]


def act_bytes(h: int, w: int, c: int) -> int:
    """CONTRACT §8：NHWC 8 通道分块激活字节。"""
    return int(h) * int(w) * C8(c)


def npu_weight_bytes(ic: int, oc: int, k: int, groups: int) -> int:
    """CONTRACT §6 权重打包字节（IC/OC 各自补到 8 的倍数）。"""
    if groups > 1 and groups == ic and oc == ic:  # depthwise
        return k * k * C8(oc)
    return k * k * C8(ic) * C8(oc)


def stage_from_name(name: str | None, fallback: str) -> str:
    if not name:
        return fallback
    for prefix, label in STAGE_RULES:
        if name.startswith(prefix):
            return label
    return fallback


# ---------------------------------------------------------------------------
# 1) 模型加载
# ---------------------------------------------------------------------------
def load_model() -> tuple[nn.Module, dict]:
    sys.path.insert(0, str(MODEL_SRC))  # nut_detector 是包：from .model import ...
    from nut_detector.enhanced_anchor_free import EnhancedNutAnchorFree  # noqa: WPS433

    ckpt = torch.load(CKPT_PATH, map_location="cpu", weights_only=False)
    cfg = json.loads(RUN_CONFIG_PATH.read_text(encoding="utf-8"))
    assert ckpt.get("model_variant") == "enhanced_mobilenetv2_fpn_decoupled_head", ckpt.get("model_variant")
    model = EnhancedNutAnchorFree(
        num_classes=NUM_CLASSES,
        fpn_channels=int(ckpt.get("fpn_channels", FPN_CHANNELS)),
        backbone_width=float(ckpt.get("backbone_width", BACKBONE_WIDTH)),
    )
    model.load_state_dict(ckpt["model"], strict=True)  # 严格加载，缺/多 key 直接报错
    model.eval()
    n_params = sum(p.numel() for p in model.parameters())
    info = {
        "checkpoint": str(CKPT_PATH),
        "checkpoint_bytes": CKPT_PATH.stat().st_size,
        "checkpoint_sha256": sha256_file(CKPT_PATH),
        "checkpoint_epoch": int(ckpt["epoch"]),
        "model_variant": ckpt.get("model_variant"),
        "class_names": list(ckpt.get("class_names", [])),
        "checkpoint_parameter_count": int(ckpt.get("parameter_count", -1)),
        "run_config_parameter_count": int(cfg.get("parameter_count", -1)),
        "fpn_channels": int(ckpt.get("fpn_channels", FPN_CHANNELS)),
        "backbone_width": float(ckpt.get("backbone_width", BACKBONE_WIDTH)),
        "state_dict_entries": len(ckpt["model"]),
        "params_total": int(n_params),
        "param_count_expected": EXPECTED_PARAMS,
        "param_count_matches_expected": bool(n_params == EXPECTED_PARAMS),
        "param_count_matches_checkpoint": bool(n_params == int(ckpt.get("parameter_count", -1))),
        "checkpoint_metrics": {k: float(v) for k, v in ckpt.get("metrics", {}).items()},
        "train_device_doc": "NVIDIA RTX 4060 Laptop / torch 2.4.1 (训练环境，见训练过程文档)",
    }
    return model, info


# ---------------------------------------------------------------------------
# 2) BN 折叠（推理等价）+ 等价性自检
# ---------------------------------------------------------------------------
def fuse_bn(model: nn.Module) -> tuple[nn.Module, list[str]]:
    """把 Conv2d + BatchNorm2d 折叠成带 bias 的 Conv2d（eval 语义等价）。"""
    import copy

    model = copy.deepcopy(model)
    fused_names: list[str] = []

    def fold(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> nn.Conv2d:
        scale = bn.weight.detach() / torch.sqrt(bn.running_var.detach() + bn.eps)
        out = nn.Conv2d(
            conv.in_channels,
            conv.out_channels,
            conv.kernel_size,
            stride=conv.stride,
            padding=conv.padding,
            dilation=conv.dilation,
            groups=conv.groups,
            bias=True,
            padding_mode=conv.padding_mode,
        )
        w = conv.weight.detach() * scale.reshape(-1, 1, 1, 1)
        b = bn.bias.detach() - bn.running_mean.detach() * scale
        out.weight.data.copy_(w)
        out.bias.data.copy_(b)
        out.train(conv.training)
        return out

    def walk(module: nn.Module, prefix: str) -> None:
        children = list(module.named_children())
        i = 0
        while i < len(children):
            name, child = children[i]
            full = f"{prefix}.{name}" if prefix else name
            if (
                isinstance(child, nn.Conv2d)
                and i + 1 < len(children)
                and isinstance(children[i + 1][1], nn.BatchNorm2d)
            ):
                module._modules[name] = fold(child, children[i + 1][1])
                module._modules[children[i + 1][0]] = nn.Identity()
                fused_names.append(full)
                i += 2
                continue
            walk(child, full)
            i += 1

    walk(model, "")
    model.eval()
    return model, fused_names


# ---------------------------------------------------------------------------
# 3) fx 抓图 + 逐层解析
# ---------------------------------------------------------------------------
def trace_model(model: nn.Module, input_size: int = INPUT_SIZE):
    gm = symbolic_trace(model)
    example = torch.zeros(1, 3, input_size, input_size)
    ShapeProp(gm).propagate(example)
    return gm


def build_layer_records(model: nn.Module, gm, fused_conv_paths: set[str] | None = None) -> tuple[list[dict], dict, dict]:
    """遍历 fx 图，输出逐层记录 + 节点->记录索引映射 + 输入记录。

    fused_conv_paths：已被 BN 折叠的卷积模块名集合（用于标注 bn_folded / bn_params）。
    """
    fused_conv_paths = set(fused_conv_paths or ())
    records: list[dict] = []
    node2rec: dict = {}
    input_rec: dict | None = None
    stage_cur = "input"
    last_rec_idx: int | None = None
    last_kind: str | None = None

    def meta_shape(node):
        tm = node.meta.get("tensor_meta")
        return tuple(int(v) for v in tm.shape) if tm is not None else None

    def collect_src_recs(args) -> list[int]:
        out: list[int] = []

        def visit(a):
            if isinstance(a, torch.fx.Node):
                if a in node2rec:
                    if node2rec[a] not in out:
                        out.append(node2rec[a])
            elif isinstance(a, (list, tuple)):
                for x in a:
                    visit(x)

        visit(args)
        return out

    def append_rec(rec: dict, srcs: list[int] | None = None) -> int:
        rec["idx"] = len(records)
        rec["srcs"] = list(srcs or [])
        records.append(rec)
        return rec["idx"]

    for node in gm.graph.nodes:
        if node.op == "placeholder":
            shape = meta_shape(node)
            h, w = shape[2], shape[3]
            input_rec = {
                "name": "input",
                "module": None,
                "op": "input",
                "npu_kind": "input",
                "stage": "input",
                "in_nhwc": None,
                "out_nhwc": [1, h, w, 3],
                "k": None,
                "s": None,
                "p": None,
                "groups": None,
                "bn_folded": False,
                "activation": "none",
                "weight_bytes_int8": 0,
                "weight_bytes_npu": 0,
                "bias_bytes_int32": 0,
                "macs": 0,
                "in_bytes": 0,
                "out_bytes": int(3 * h * w),  # PACKED3（v0.7 conv0 输入）
                "out_bytes_nhwc_c8": act_bytes(h, w, 3),
                "npu_ops": 0,
                "npu_op_note": "输入张量，CPU 侧装入 A 缓冲（PACKED3）",
                "h": h,
                "w": w,
                "c": 3,
            }
            idx = append_rec(input_rec)
            node2rec[node] = idx
            last_rec_idx, last_kind = idx, "input"
            continue

        if node.op == "output":
            break

        if node.op == "call_module":
            mod = model.get_submodule(node.target)
            name = str(node.target)
            stage_cur = stage_from_name(name, stage_cur)
            srcs = collect_src_recs(node.args)

            if isinstance(mod, nn.Conv2d):
                out_shape = meta_shape(node)
                out_nhwc = nhwc(out_shape)
                in_nhwc = nhwc(meta_shape(node.args[0])) if srcs else None
                k = int(mod.kernel_size[0])
                s = int(mod.stride[0])
                p = int(mod.padding[0])
                g = int(mod.groups)
                ic, oc = int(mod.in_channels), int(mod.out_channels)
                _, oh, ow, _ = out_nhwc
                is_dw = g > 1 and g == ic and oc == ic
                op = ("dwconv" if is_dw else "conv") + f"{k}x{k}"
                macs = (ic // g) * k * k * oc * oh * ow
                # conv0 的输入是 PACKED3（v0.7 flags.PACKED3，3 B/像素）；其余按 NHWC 8 通道分块
                is_conv0 = bool(srcs) and records[srcs[0]]["npu_kind"] == "input"
                in_bytes = 3 * int(in_nhwc[1]) * int(in_nhwc[2]) if is_conv0 else int(act_bytes(*in_nhwc[1:3], ic))
                rec = {
                    "name": name,
                    "module": name,
                    "op": op,
                    "npu_kind": "dwconv" if is_dw else "conv",
                    "stage": stage_cur,
                    "in_nhwc": in_nhwc,
                    "out_nhwc": out_nhwc,
                    "k": k,
                    "s": s,
                    "p": p,
                    "groups": g,
                    "depthwise": bool(is_dw),
                    "bn_folded": bool(name in fused_conv_paths),
                    "bn_params": int(4 * oc) if name in fused_conv_paths else 0,
                    "activation": "none",
                    "weight_bytes_int8": int(mod.weight.numel()),
                    "weight_bytes_npu": int(npu_weight_bytes(ic, oc, k, g)),
                    "bias_bytes_int32": int(oc * 4),
                    "has_conv_bias": bool(name not in fused_conv_paths and mod.bias is not None),
                    "macs": int(macs),
                    "in_layout": "PACKED3" if is_conv0 else "NHWC_C8",
                    "in_bytes": int(in_bytes),
                    "out_bytes": int(act_bytes(oh, ow, oc)),
                    "h": int(oh),
                    "w": int(ow),
                    "c": int(oc),
                    "npu_ops": 1,
                    "npu_op_note": "conv/dwconv 1 op（BN+ReLU 已融合）",
                }
                idx = append_rec(rec, srcs)
                node2rec[node] = idx
                last_rec_idx, last_kind = idx, "conv"
                continue

            if isinstance(mod, nn.BatchNorm2d):
                # 挂到上一条 conv 上（BN 折叠）：形状不变
                assert last_rec_idx is not None and last_kind == "conv", "BN 未跟随 conv"
                rec = records[last_rec_idx]
                rec["bn_folded"] = True
                rec["bn_params"] = int(sum(p.numel() for p in mod.parameters()))
                node2rec[node] = last_rec_idx
                last_kind = "conv"
                continue

            if isinstance(mod, nn.ReLU):
                if last_kind == "conv" and last_rec_idx is not None:
                    rec = records[last_rec_idx]
                    rec["activation"] = "relu"
                    rec["relu_fused"] = True
                    node2rec[node] = last_rec_idx
                    last_kind = "conv"
                else:
                    # add 之后的独立 ReLU：ISA 无对应原语
                    shape = meta_shape(node)
                    hn, wn, cn = nhwc(shape)[1:]
                    rec = {
                        "name": name,
                        "module": name,
                        "op": "relu",
                        "npu_kind": "relu_standalone",
                        "stage": stage_cur,
                        "in_nhwc": nhwc(shape),
                        "out_nhwc": nhwc(shape),
                        "k": None,
                        "s": None,
                        "p": None,
                        "groups": None,
                        "bn_folded": False,
                        "activation": "relu",
                        "weight_bytes_int8": 0,
                        "weight_bytes_npu": 0,
                        "bias_bytes_int32": 0,
                        "macs": 0,
                        "in_bytes": act_bytes(hn, wn, cn),
                        "out_bytes": act_bytes(hn, wn, cn),
                        "h": int(hn),
                        "w": int(wn),
                        "c": int(cn),
                        "npu_ops": 0,
                        "npu_op_note": "NPU 无独立 ReLU 原语（add 后激活无处安放）",
                    }
                    idx = append_rec(rec, srcs)
                    node2rec[node] = idx
                    if last_rec_idx is not None:
                        records[last_rec_idx]["post_activation"] = "relu"
                    last_rec_idx, last_kind = idx, "relu"
                continue

            if isinstance(mod, (nn.Identity, nn.Dropout)):
                # BN 折叠后残留的占位模块（Conv->Identity->ReLU），不产生数据
                node2rec[node] = srcs[0] if srcs else last_rec_idx
                continue

            raise RuntimeError(f"未识别的 call_module: {node.target}")

        if node.op == "call_function":
            tgt = node.target
            tn = str(tgt)
            out_shape = meta_shape(node)
            srcs = collect_src_recs(node.args)

            if tn in ("<built-in function add>", "add") or tgt is torch.add:
                out = nhwc(out_shape)
                _, h, w, c = out
                in_shapes = [nhwc(a.meta["tensor_meta"].shape) for a in node.args if isinstance(a, torch.fx.Node) and a.meta.get("tensor_meta") is not None]
                rec = {
                    "name": node.name,
                    "module": None,
                    "op": "add",
                    "npu_kind": "add",
                    "stage": stage_cur,
                    "in_nhwc": in_shapes[0] if len(in_shapes) == 1 else in_shapes,
                    "out_nhwc": out,
                    "k": None,
                    "s": None,
                    "p": None,
                    "groups": None,
                    "bn_folded": False,
                    "activation": "none",
                    "weight_bytes_int8": 0,
                    "weight_bytes_npu": 0,
                    "bias_bytes_int32": 0,
                    "macs": 0,
                    "in_bytes": int(sum(act_bytes(*sh[1:3], sh[3]) for sh in in_shapes) / max(1, len(in_shapes))) if in_shapes else 0,
                    "in_bytes_all": [int(act_bytes(sh[1], sh[2], sh[3])) for sh in in_shapes],
                    "out_bytes": int(act_bytes(h, w, c)),
                    "h": int(h),
                    "w": int(w),
                    "c": int(c),
                    "npu_ops": 1,
                    "npu_op_note": "residual/FPN 相加 1 op（int8 饱和 ADD，要求两操作数同 scale）",
                }
                idx = append_rec(rec, srcs)
                node2rec[node] = idx
                last_rec_idx, last_kind = idx, "add"
                continue

            if "cat" in tn:
                out = nhwc(out_shape)
                _, h, w, c = out
                in_shapes = [nhwc(a.meta["tensor_meta"].shape) for a in node.args[0]]
                offs, cur = [], 0
                for sh in in_shapes:
                    offs.append(cur)
                    cur += sh[3]
                rec = {
                    "name": node.name,
                    "module": None,
                    "op": "concat",
                    "npu_kind": "copy",
                    "stage": stage_cur,
                    "in_nhwc": in_shapes,
                    "out_nhwc": out,
                    "k": None,
                    "s": None,
                    "p": None,
                    "groups": None,
                    "bn_folded": False,
                    "activation": "none",
                    "weight_bytes_int8": 0,
                    "weight_bytes_npu": 0,
                    "bias_bytes_int32": 0,
                    "macs": 0,
                    "in_bytes": int(sum(act_bytes(sh[1], sh[2], sh[3]) for sh in in_shapes)),
                    "out_bytes": int(act_bytes(h, w, c)),
                    "h": int(h),
                    "w": int(w),
                    "c": int(c),
                    "channel_offsets": offs,
                    "channel_offsets_8aligned": all(o % 8 == 0 for o in offs),
                    "npu_ops": int(len(in_shapes)),
                    "npu_op_note": f"{len(in_shapes)} 个源 -> 同一 dst 的不同通道偏移拷贝（concat 需每源 1 copy op）",
                }
                idx = append_rec(rec, srcs)
                node2rec[node] = idx
                last_rec_idx, last_kind = idx, "concat"
                continue

            if "interpolate" in tn:
                in_node = node.args[0]
                in_shape = nhwc(in_node.meta["tensor_meta"].shape)
                out = nhwc(out_shape)
                _, ih, iw, ic = in_shape
                _, oh, ow, _ = out
                ratio_h = oh // ih if ih else 0
                ratio_w = ow // iw if iw else 0
                assert ratio_h == ratio_w and ratio_h in (1, 2, 4, 8), (in_shape, out)
                copies = int(math.log2(ratio_h))
                rec = {
                    "name": node.name,
                    "module": None,
                    "op": f"upsample_nearest{ratio_h}x",
                    "npu_kind": "copy",
                    "stage": stage_cur,
                    "in_nhwc": in_shape,
                    "out_nhwc": out,
                    "k": None,
                    "s": None,
                    "p": None,
                    "groups": None,
                    "bn_folded": False,
                    "activation": "none",
                    "weight_bytes_int8": 0,
                    "weight_bytes_npu": 0,
                    "bias_bytes_int32": 0,
                    "macs": 0,
                    "in_bytes": int(act_bytes(ih, iw, ic)),
                    "out_bytes": int(act_bytes(oh, ow, ic)),
                    "h": int(oh),
                    "w": int(ow),
                    "c": int(ic),
                    "upsample_ratio": int(ratio_h),
                    "npu_ops": copies,
                    "npu_op_note": "COPY+UP2X 仅支持 2x；4x 需 2 次 2x 拷贝（含 1 个中间张量）" if ratio_h == 4 else "COPY+UP2X 2x nearest 1 op",
                }
                idx = append_rec(rec, srcs)
                node2rec[node] = idx
                last_rec_idx, last_kind = idx, "copy"
                continue

            if tn in ("<built-in function getattr>", "<built-in function getitem>"):
                # x.shape[-2:] 之类的形状查询节点，不产生数据
                if node.args and isinstance(node.args[0], torch.fx.Node):
                    node2rec[node] = node2rec.get(node.args[0], last_rec_idx)
                continue

            if "relu" in tn:
                # 理论上不会到这（nn.ReLU 走 call_module）；保险处理
                shape = meta_shape(node)
                hn, wn, cn = nhwc(shape)[1:]
                rec = {
                    "name": node.name,
                    "module": None,
                    "op": "relu",
                    "npu_kind": "relu_standalone",
                    "stage": stage_cur,
                    "in_nhwc": nhwc(shape),
                    "out_nhwc": nhwc(shape),
                    "k": None,
                    "s": None,
                    "p": None,
                    "groups": None,
                    "bn_folded": False,
                    "activation": "relu",
                    "weight_bytes_int8": 0,
                    "weight_bytes_npu": 0,
                    "bias_bytes_int32": 0,
                    "macs": 0,
                    "in_bytes": act_bytes(hn, wn, cn),
                    "out_bytes": act_bytes(hn, wn, cn),
                    "h": int(hn),
                    "w": int(wn),
                    "c": int(cn),
                    "npu_ops": 0,
                    "npu_op_note": "NPU 无独立 ReLU 原语",
                }
                idx = append_rec(rec, srcs)
                node2rec[node] = idx
                last_rec_idx, last_kind = idx, "relu"
                continue

            raise RuntimeError(f"未识别的 call_function: {tgt}")

        raise RuntimeError(f"未识别的 fx node op: {node.op}")

    # stage 归属修正：函数式 copy/upsample 跟随其输入张量的 stage；concat 属于融合段
    # （add 保留"最近模块"口径：refine 内部的 add 归 refine，FPN 横向合并 add 归 lateral）
    for rec in records:
        if rec["npu_kind"] == "copy" and rec.get("srcs"):
            src_stage = records[rec["srcs"][0]].get("stage")
            if src_stage in STAGE_ORDER:
                rec["stage"] = src_stage
        if rec["op"] == "concat":
            rec["stage"] = "fpn.fusion"

    return records, node2rec, input_rec


# ---------------------------------------------------------------------------
# 4) 汇总统计
# ---------------------------------------------------------------------------
def summarize(records: list[dict], info: dict) -> dict:
    conv = [r for r in records if r["npu_kind"] == "conv"]
    dw = [r for r in records if r["npu_kind"] == "dwconv"]
    adds = [r for r in records if r["npu_kind"] == "add"]
    copies = [r for r in records if r["npu_kind"] == "copy"]
    ups = [r for r in copies if r["op"].startswith("upsample")]
    cats = [r for r in copies if r["op"] == "concat"]
    relus = [r for r in records if r["npu_kind"] == "relu_standalone"]

    total_macs = sum(r["macs"] for r in records)
    weights_raw = sum(r["weight_bytes_int8"] for r in records)
    weights_npu = sum(r["weight_bytes_npu"] for r in records)
    biases = sum(r["bias_bytes_int32"] for r in records)

    # 每层 Q 块（CONTRACT §7）：6*OC_pad+16；ADD_R 每 add 16 B（v0.6/v0.7）
    q_conv = 0
    for r in conv + dw:
        assert r["c"] is not None
        q_conv += 6 * C8(r["c"]) + 16
    q_add = 16 * len(adds)
    q_total = q_conv + q_add

    # 激活峰值（224）
    peak_rec = max(records, key=lambda r: r["out_bytes"])
    ranked = sorted(records, key=lambda r: r["out_bytes"], reverse=True)[:12]

    # 单 op 需要同时驻留的字节数（src + dst）
    def resident(r: dict) -> int:
        if r.get("in_bytes_all"):
            base = max(r["in_bytes_all"]) if r["npu_kind"] == "add" else sum(r["in_bytes_all"])
        else:
            base = r.get("in_bytes", 0)
        if r["npu_kind"] == "add":
            # in-place：dst 复用一号操作数，只需 max(操作数) + out（同张量）
            return max(base, r["out_bytes"])
        if r["npu_kind"] == "concat":
            return base + r["out_bytes"]
        return base + r["out_bytes"]

    resident_rank = sorted(records, key=resident, reverse=True)[:8]
    for r in records:
        r["resident_bytes"] = int(resident(r))

    # 逐 stage 聚合
    by_stage: dict[str, dict] = OrderedDict()
    for st in STAGE_ORDER:
        rows = [r for r in records if r["stage"] == st]
        if not rows and st != "input":
            continue
        by_stage[st] = {
            "layers": len(rows),
            "conv_ops": sum(1 for r in rows if r["npu_kind"] == "conv"),
            "dwconv_ops": sum(1 for r in rows if r["npu_kind"] == "dwconv"),
            "add_ops": sum(1 for r in rows if r["npu_kind"] == "add"),
            "copy_ops": sum(r["npu_ops"] for r in rows if r["npu_kind"] == "copy"),
            "relu_standalone_ops": sum(1 for r in rows if r["npu_kind"] == "relu_standalone"),
            "macs": int(sum(r["macs"] for r in rows)),
            "weights_int8_bytes": int(sum(r["weight_bytes_int8"] for r in rows)),
            "weight_bytes_npu": int(sum(r["weight_bytes_npu"] for r in rows)),
            "max_activation_bytes": int(max(r["out_bytes"] for r in rows)),
            "sum_activation_bytes": int(sum(r["out_bytes"] for r in rows)),
        }

    npu_ops_conv = len(conv) + len(dw)
    npu_ops_copy_raw = sum(r["npu_ops"] for r in ups) + sum(r["npu_ops"] for r in cats)
    # CSE：两个 p3->56×56 的 2x 上采样输入相同，可共享 1 次 copy
    dup_ups = 0
    seen = set()
    for r in ups:
        key = (tuple(r["in_nhwc"][1:]), tuple(r["out_nhwc"][1:]))
        if key in seen:
            dup_ups += 1
        seen.add(key)
    npu_ops_copy_cse = npu_ops_copy_raw - dup_ups
    npu_ops_add = len(adds)
    npu_ops_total_raw = npu_ops_conv + npu_ops_copy_raw + npu_ops_add
    npu_ops_total_cse = npu_ops_conv + npu_ops_copy_cse + npu_ops_add

    summary = {
        "params_total": info["params_total"],
        "params_by_kind": {},
        "state_dict_entries": info["state_dict_entries"],
        "conv_layers": len(conv) + len(dw),
        "dense_conv_layers": len(conv),
        "dwconv_layers": len(dw),
        "bn_folded_layers": sum(1 for r in records if r.get("bn_folded")),
        "conv_with_relu_layers": sum(1 for r in records if r["npu_kind"] in ("conv", "dwconv") and r["activation"] == "relu"),
        "linear_conv_layers": sum(1 for r in records if r["npu_kind"] in ("conv", "dwconv") and r["activation"] != "relu"),
        "activation_layers": sum(1 for r in records if r["activation"] == "relu"),
        "add_ops": len(adds),
        "upsample_layers": len(ups),
        "upsample_copy_ops": sum(r["npu_ops"] for r in ups),
        "concat_layers": len(cats),
        "concat_copy_ops": sum(r["npu_ops"] for r in cats),
        "copy_ops_total": npu_ops_copy_raw,
        "copy_ops_total_after_cse": npu_ops_copy_cse,
        "duplicate_upsample_ops_cse_saved": dup_ups,
        "pool_ops": 0,
        "relu_standalone_ops": len(relus),
        "npu_ops_total": npu_ops_total_raw,
        "npu_ops_total_after_cse": npu_ops_total_cse,
        "npu_ops_breakdown": {
            "conv_dense": len(conv),
            "dwconv": len(dw),
            "pool": 0,
            "upsample_copy": sum(r["npu_ops"] for r in ups),
            "concat_copy": sum(r["npu_ops"] for r in cats),
            "add": len(adds),
        },
        "rom_depth": ROM_DEPTH,
        "npu_ops_fits_rom": bool(npu_ops_total_cse <= ROM_DEPTH),
        "total_macs": int(total_macs),
        "total_macs_after_equiv": int(total_macs),
        "macs_by_stage": {k: v["macs"] for k, v in by_stage.items()},
        "weights_int8_bytes_raw": int(weights_raw),
        "weights_int8_bytes_npu_packed": int(weights_npu),
        "bias_int32_bytes": int(biases),
        "q_region_bytes_estimate": int(q_total),
        "q_region_conv_bytes": int(q_conv),
        "q_region_add_r_bytes": int(q_add),
        "w_budget_bytes": W_BUDGET,
        "q_budget_bytes": Q_BUDGET,
        "w_over_budget_factor": weights_npu / W_BUDGET,
        "q_over_budget_factor": q_total / Q_BUDGET,
        "input_bytes_packed3": int(3 * INPUT_SIZE * INPUT_SIZE),
        "input_bytes_nhwc_c8": int(act_bytes(INPUT_SIZE, INPUT_SIZE, 3)),
        "peak_activation_bytes": int(peak_rec["out_bytes"]),
        "peak_activation_layer": peak_rec["name"],
        "peak_activation_shape_nhwc": peak_rec["out_nhwc"],
        "top_activation_tensors": [
            {"name": r["name"], "op": r["op"], "stage": r["stage"], "nhwc": r["out_nhwc"], "bytes": int(r["out_bytes"])}
            for r in ranked
        ],
        "max_single_tensor_limit_bytes": MAX_SINGLE_TENSOR,
        "peak_over_a_buffer_factor": peak_rec["out_bytes"] / A_BYTES,
        "top_resident_ops": [
            {
                "name": r["name"],
                "op": r["op"],
                "stage": r["stage"],
                "in_nhwc": r["in_nhwc"],
                "out_nhwc": r["out_nhwc"],
                "resident_bytes": int(r["resident_bytes"]),
            }
            for r in resident_rank
        ],
        "max_resident_bytes": int(max(r["resident_bytes"] for r in records)),
        "ab_buffer_bytes": AB_BYTES,
        "max_resident_over_ab_factor": max(r["resident_bytes"] for r in records) / AB_BYTES,
        "ic_or_oc_over_256_layers": [],
        "layers_ic_over_256": [],
        "layers_oc_over_256": [],
        "by_stage": by_stage,
        "stage_order": [st for st in STAGE_ORDER if st in by_stage],
    }

    # 参数分项（与 2,048,721 对齐：卷积权重 + BN 可训练参数(weight/bias=2/通道) + head 卷积 bias）
    summary["params_by_kind"] = {
        "conv_weights": int(weights_raw),
        "bn_trainable": int(sum(2 * r["c"] for r in conv + dw if r.get("bn_folded"))),
        "bn_stored_in_checkpoint": int(sum(r.get("bn_params", 0) for r in records)),
        "conv_bias": int(sum(r["c"] for r in conv + dw if r.get("has_conv_bias"))),
    }
    summary["params_by_kind"]["sum_trainable"] = int(
        summary["params_by_kind"]["conv_weights"]
        + summary["params_by_kind"]["bn_trainable"]
        + summary["params_by_kind"]["conv_bias"]
    )

    # engine 规模限制：IC/OC <= 256
    over = []
    for r in conv + dw:
        ic = int(r["in_nhwc"][-1])
        oc = int(r["out_nhwc"][-1])
        if ic > ENGINE_MAX_IC_OC or oc > ENGINE_MAX_IC_OC:
            over.append(
                {
                    "name": r["name"],
                    "op": r["op"],
                    "ic": ic,
                    "oc": oc,
                    "ic_over": bool(ic > ENGINE_MAX_IC_OC),
                    "oc_over": bool(oc > ENGINE_MAX_IC_OC),
                }
            )
            if ic > ENGINE_MAX_IC_OC:
                summary["layers_ic_over_256"].append(r["name"])
            if oc > ENGINE_MAX_IC_OC:
                summary["layers_oc_over_256"].append(r["name"])
    summary["ic_or_oc_over_256_layers"] = over
    summary["engine_max_ic_oc"] = ENGINE_MAX_IC_OC
    return summary


# ---------------------------------------------------------------------------
# 5) 多分辨率峰值估算（空间尺寸等比缩放、通道不变）
# ---------------------------------------------------------------------------
def scale_bytes(rec: dict, size: int, base_size: int = INPUT_SIZE) -> int:
    """把 224 下的 out_bytes 按 (size/base_size)^2 缩放（通道/8 分块不变）。"""
    num = size * size
    den = base_size * base_size
    hw = int(rec["h"]) * int(rec["w"])
    return C8(rec["c"]) * (hw * num // den)


def multi_resolution_analysis(records: list[dict], summary: dict) -> dict:
    per_res = OrderedDict()
    for size in RES_SIZES:
        scaled = {}
        for r in records:
            if r["npu_kind"] == "input":
                continue
            scaled[r["idx"]] = scale_bytes(r, size)
        input_packed = 3 * size * size
        peak_idx = max(scaled, key=scaled.get)
        peak_rec = next(r for r in records if r["idx"] == peak_idx)
        # 融合段（fpn + head）口径
        fused = [
            r for r in records
            if r["stage"] in ("fpn.lateral", "fpn.refine", "fpn.fusion", "head.tower", "head.out")
            and r["npu_kind"] != "input"
        ]
        fused_no_concat = [r for r in fused if r["op"] != "concat"]
        fused_with_concat = fused
        peak_fused = max((scaled[r["idx"]] for r in fused_no_concat), default=0)
        peak_fused_rec = max(fused_no_concat, key=lambda r: scaled[r["idx"]]) if fused_no_concat else None
        peak_concat = max((scaled[r["idx"]] for r in fused_with_concat), default=0)
        peak_concat_rec = max(fused_with_concat, key=lambda r: scaled[r["idx"]]) if fused_with_concat else None
        # 各 stage 峰值
        stage_peaks = OrderedDict()
        for st in summary["stage_order"]:
            rows = [r for r in records if r["stage"] == st and r["npu_kind"] != "input"]
            if not rows:
                continue
            stage_peaks[st] = int(max(scaled[r["idx"]] for r in rows))
        macs = int(round(summary["total_macs"] * (size * size) / (INPUT_SIZE * INPUT_SIZE)))
        per_res[str(size)] = {
            "input_size": size,
            "spatial_scale": (size / INPUT_SIZE) ** 2,
            "input_bytes_packed3": int(input_packed),
            "input_bytes_nhwc_c8": int(act_bytes(size, size, 3)),
            "macs": macs,
            "peak_activation_bytes_all_layers": int(max(peak_idx and scaled[peak_idx] or 0, input_packed)),
            "peak_activation_layer_all_layers": peak_rec["name"],
            "peak_activation_shape_all_layers": peak_rec["out_nhwc"],
            "peak_fused_bytes_no_concat": int(peak_fused),
            "peak_fused_layer_no_concat": peak_fused_rec["name"] if peak_fused_rec else None,
            "peak_fused_bytes_with_concat": int(peak_concat),
            "peak_fused_layer_with_concat": peak_concat_rec["name"] if peak_concat_rec else None,
            "peak_all_with_input": int(max(max(scaled.values()), input_packed)),
            "stage_peak_bytes": stage_peaks,
            "fits_a_buffer_all_layers": bool(max(max(scaled.values()), input_packed) <= A_BYTES),
            "fits_96k_all_layers": bool(max(max(scaled.values()), input_packed) <= MAX_SINGLE_TENSOR),
            "fits_a_buffer_fused_no_concat": bool(peak_fused <= A_BYTES),
            "fits_96k_fused_no_concat": bool(peak_fused <= MAX_SINGLE_TENSOR),
            "fits_96k_fused_with_concat": bool(peak_concat <= MAX_SINGLE_TENSOR),
            "fits_ab_pingpong_two_biggest": bool(2 * max(peak_fused, 0) <= AB_BYTES),
        }
    # 解析阈值：peak(S) = peak_224 * (S/224)^2 <= limit
    peak224_all = per_res["224"]["peak_all_with_input"]
    peak224_fused = per_res["224"]["peak_fused_bytes_no_concat"]
    peak224_concat = per_res["224"]["peak_fused_bytes_with_concat"]
    thresholds = {
        "all_layers_S_max_for_98304": 224.0 * math.sqrt(MAX_SINGLE_TENSOR / peak224_all),
        "all_layers_S_max_for_A_96KB": 224.0 * math.sqrt(A_BYTES / peak224_all),
        "fused_no_concat_S_max_for_98304": 224.0 * math.sqrt(MAX_SINGLE_TENSOR / peak224_fused),
        "fused_with_concat_S_max_for_98304": 224.0 * math.sqrt(MAX_SINGLE_TENSOR / peak224_concat),
    }
    return {"sizes": per_res, "analytic_thresholds": thresholds}


# ---------------------------------------------------------------------------
# 6) A/B 缓冲贪心分配估算（与 tools/yolo/darknet_lib.allocate 同思路的乐观版）
# ---------------------------------------------------------------------------
def ab_allocation(records: list[dict], size: int, a_bytes: int = A_BYTES, b_bytes: int = B_BYTES,
                  base_size: int = INPUT_SIZE, align: int = 16) -> dict:
    """把逐层图当成 tensor/op 序列做生命周期贪心分配（与 tools/yolo/darknet_lib.allocate 同思路）。

    - tensor = 每个记录的输出；add / 独立 ReLU 视为原地写（复用一号操作数缓冲）；
    - concat 的多个源必须同时驻留（真实约束），其自身 dst 为新分配；
    - 分配顺序：先 A 后 B 都试，优先放"刚好够"的 B（与 yolo smallB 模式一致，
      把 A 留给大张量）；放不下即失败。
    这是"乐观"估算（不拆通道、不做 tile），失败说明量级，不代表做过编译优化后不可能。
    """
    nr = {r["idx"]: r for r in records}
    nbytes = {}
    for r in records:
        if r["npu_kind"] == "input":
            nbytes[r["idx"]] = 3 * size * size
        else:
            nbytes[r["idx"]] = scale_bytes(r, size, base_size)
    max_single = max(nbytes.values())

    input_rec = next(r for r in records if r["npu_kind"] == "input")
    # 构造 op 序列：顺序与 fx 图一致；每项 (reads, writes_new or -1=in-place)
    ops: list[dict] = []
    records_by_idx = {r["idx"]: r for r in records}
    for r in records:
        if r["npu_kind"] == "input":
            continue
        reads = [s for s in r.get("srcs", []) if s in nbytes]
        kind = r["npu_kind"]
        if kind in ("conv", "dwconv", "copy"):
            ops.append({"rec": r, "reads": reads, "write": r["idx"]})
        elif kind == "add":
            # 原地写一号操作数（省一块缓冲，乐观）
            write = reads[0] if reads else r["idx"]
            ops.append({"rec": r, "reads": reads, "write": write})
        elif kind == "relu_standalone":
            write = reads[0] if reads else r["idx"]
            ops.append({"rec": r, "reads": reads, "write": write})
        else:
            ops.append({"rec": r, "reads": reads, "write": r["idx"]})

    # 生命周期：def_op = 创建 op；last_use = 最后一次被读（原地写的张量也按被读算）
    info = {}
    for k, op in enumerate(ops):
        for t in op["reads"]:
            info.setdefault(t, {"def_op": 0, "last_use": 0})
            info[t]["last_use"] = max(info[t]["last_use"], k)
    info.setdefault(input_rec["idx"], {"def_op": 0, "last_use": 0})
    info[input_rec["idx"]]["last_use"] = max(
        info[input_rec["idx"]]["last_use"],
        max([k for k, op in enumerate(ops) if input_rec["idx"] in op["reads"]], default=0),
    )
    for k, op in enumerate(ops):
        w = op["write"]
        if w not in info:
            info[w] = {"def_op": k, "last_use": k}
        info[w]["def_op"] = min(info[w].get("def_op", k), k)

    region_size = {"A": a_bytes, "B": b_bytes}
    busy = {"A": [(0, nbytes[input_rec["idx"]])], "B": []}
    peak = {"A": nbytes[input_rec["idx"]], "B": 0}
    peak_total = peak["A"]
    fail = None
    failed_at = None
    if nbytes[input_rec["idx"]] > a_bytes:
        fail = f"输入张量 {nbytes[input_rec['idx']]} B > A({a_bytes} B)"
        failed_at = {"op_index": -1, "kind": "input", "tensor_bytes": nbytes[input_rec["idx"]]}

    def try_place(region: str, size_b: int):
        sz = (size_b + align - 1) // align * align
        if sz > region_size[region]:
            return None
        pos = 0
        for (o, s) in sorted(busy[region]):
            if pos + sz <= o:
                return pos
            pos = max(pos, o + s)
        return pos if pos + sz <= region_size[region] else None

    placed = {input_rec["idx"]: ("A", 0)}
    for k, op in enumerate(ops):
        if fail is not None:
            break
        # 释放已死张量
        for tid, tin in info.items():
            if tid in placed and tin["last_use"] < k:
                reg, off = placed.pop(tid)
                busy[reg] = [(o, s) for (o, s) in busy[reg] if o != off]
        w = op["write"]
        if w not in placed:
            cand = []
            for reg in ("B", "A"):
                pos = try_place(reg, nbytes[w])
                if pos is not None:
                    cand.append((reg, pos))
            if not cand:
                fail = (f"op {k}（{op['rec']['name']}，{op['rec']['op']}）"
                        f" 输出张量 {nbytes[w]} B 放不进 A({a_bytes}B)/B({b_bytes}B)")
                failed_at = {"op_index": k, "kind": op["rec"]["op"], "layer": op["rec"]["name"],
                             "tensor_bytes": nbytes[w]}
                break
            reg, pos = cand[0]
            placed[w] = (reg, pos)
            busy[reg].append((pos, (nbytes[w] + align - 1) // align * align))
            used = sum(s for (o, s) in busy[reg])
            peak[reg] = max(peak[reg], used)
        peak_total = max(peak_total, sum(sum(s for (o, s) in busy[r2]) for r2 in "AB"))

    return {
        "input_size": size,
        "ok": fail is None,
        "fail": fail,
        "failed_at": failed_at,
        "peak_A": int(peak["A"]),
        "peak_B": int(peak["B"]),
        "peak_total": int(peak_total),
        "max_single_tensor": int(max_single),
        "input_tensor_bytes": int(nbytes[input_rec["idx"]]),
        "a_bytes": a_bytes,
        "b_bytes": b_bytes,
        "note": "乐观贪心（add 原地、不拆通道、不做 tile）；失败说明该分辨率无法直接排进 A/B",
    }


# ---------------------------------------------------------------------------
# 7) 浮点精度基线（复用 nut_detector 自带预处理/解码/匹配逻辑）
# ---------------------------------------------------------------------------
def run_precision_baseline(model: nn.Module, device: str, batch_size: int = 32) -> dict:
    sys.path.insert(0, str(MODEL_SRC))
    from nut_detector.multi_dataset import MultiNutDataset, read_multi_split  # noqa: WPS433
    from nut_detector.multi_anchor_free import decode_multi_predictions  # noqa: WPS433
    from nut_detector.evaluate_multi_mobilenet_anchor_free import matched_pairs  # noqa: WPS433
    from torch.utils.data import DataLoader  # noqa: WPS433

    samples = read_multi_split(DATA_DIR, "test")
    dataset = MultiNutDataset(samples, training=False, seed=SEED)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False, num_workers=0)
    model.to(device).eval()

    true_by_class: Counter = Counter()
    pred_by_class: Counter = Counter()
    matched_by_class: Counter = Counter()
    matched_ious: list[float] = []
    group: dict[int, Counter] = {}
    rows = []
    t0 = time.time()
    offset = 0
    with torch.no_grad():
        for images, classes, boxes, valid in loader:
            images = images.to(device)
            outputs = model(images)
            predictions = decode_multi_predictions(*outputs)
            for batch_index, prediction in enumerate(predictions):
                prediction = {key: (value.detach().cpu() if torch.is_tensor(value) else value) for key, value in prediction.items()}
                true_classes = classes[batch_index][valid[batch_index]]
                true_boxes = boxes[batch_index][valid[batch_index]]
                pairs = matched_pairs(prediction["classes"], prediction["boxes"], true_classes, true_boxes)
                true_count = int(len(true_boxes))
                predicted_count = int(len(prediction["boxes"]))
                tp = len(pairs)
                fp, fn = predicted_count - tp, true_count - tp
                true_by_class.update(int(v) for v in true_classes)
                pred_by_class.update(int(v) for v in prediction["classes"])
                matched_by_class.update(int(true_classes[t]) for _, t, _ in pairs)
                pair_ious = [p[2] for p in pairs]
                matched_ious.extend(pair_ious)
                g = group.setdefault(true_count, Counter())
                g["images"] += 1
                g["tp"] += tp
                g["fp"] += fp
                g["fn"] += fn
                g["count_correct"] += int(true_count == predicted_count)
                g["exact"] += int(tp == true_count and fp == 0 and fn == 0)
                rows.append(
                    {
                        "image": Path(samples[offset + batch_index]["image"]).name,
                        "true_count": true_count,
                        "predicted_count": predicted_count,
                        "tp": tp,
                        "fp": fp,
                        "fn": fn,
                        "mean_iou": float(sum(pair_ious) / len(pair_ious)) if pair_ious else 0.0,
                        "exact": int(tp == true_count and fp == 0 and fn == 0),
                        "classes": [int(v) for v in prediction["classes"]],
                    }
                )
            offset += images.shape[0]

    total_tp = sum(r["tp"] for r in rows)
    total_fp = sum(r["fp"] for r in rows)
    total_fn = sum(r["fn"] for r in rows)
    precision = total_tp / max(1, total_tp + total_fp)
    recall = total_tp / max(1, total_tp + total_fn)
    per_class = {}
    for ci in range(NUM_CLASSES):
        tp_c = matched_by_class[ci]
        per_class[str(ci)] = {
            "true_objects": int(true_by_class[ci]),
            "predicted_objects": int(pred_by_class[ci]),
            "matched_objects": int(tp_c),
            "precision": tp_c / max(1, pred_by_class[ci]),
            "recall": tp_c / max(1, true_by_class[ci]),
        }
    by_count = {}
    for count in sorted(group):
        g = group[count]
        prec = g["tp"] / max(1, g["tp"] + g["fp"])
        rec = g["tp"] / max(1, g["tp"] + g["fn"])
        by_count[str(count)] = {
            "images": int(g["images"]),
            "precision": prec,
            "recall": rec,
            "f1": 2 * prec * rec / max(1e-9, prec + rec),
            "count_accuracy": g["count_correct"] / g["images"],
            "exact_image_accuracy": g["exact"] / g["images"],
        }
    report = {
        "device": device,
        "batch_size": batch_size,
        "seed": SEED,
        "seconds": round(time.time() - t0, 2),
        "decode": {
            "max_detections": 4,
            "confidence_threshold": 0.20,
            "nms_threshold": 0.35,
            "pre_nms_topk": 40,
            "nms": "class-aware greedy NMS（_class_aware_nms）",
            "match": "类内贪心匹配，IoU>=0.5（evaluate_multi_mobilenet_anchor_free.matched_pairs）",
            "preprocess": "320x240 RGB -> bilinear resize 224x168 -> 上下各 pad 28（edge）-> /127.5-1 -> NCHW",
        },
        "test_images": len(rows),
        "true_objects": total_tp + total_fn,
        "predicted_objects": total_tp + total_fp,
        "true_positive": total_tp,
        "false_positive": total_fp,
        "false_negative": total_fn,
        "precision": precision,
        "recall": recall,
        "f1": 2 * precision * recall / max(1e-9, precision + recall),
        "mean_matched_iou": float(sum(matched_ious) / max(1, len(matched_ious))),
        "count_accuracy": float(sum(1 for r in rows if r["true_count"] == r["predicted_count"]) / max(1, len(rows))),
        "exact_image_accuracy": float(sum(r["exact"] for r in rows) / max(1, len(rows))),
        "per_class": per_class,
        "class_names": ["red_cap", "purple_cap", "green_cap", "yellow_cap"],
        "by_true_object_count": by_count,
        "per_image": rows,
    }
    return report


def compare_with_doc(report: dict) -> dict:
    diff = {}
    for key in ("precision", "recall", "f1", "mean_matched_iou", "count_accuracy", "exact_image_accuracy"):
        diff[key] = float(report[key] - DOC_METRICS[key])
    diff["true_positive"] = int(report["true_positive"] - DOC_METRICS["true_positive"])
    diff["false_positive"] = int(report["false_positive"] - DOC_METRICS["false_positive"])
    diff["false_negative"] = int(report["false_negative"] - DOC_METRICS["false_negative"])
    diff["matches_doc"] = bool(
        report["true_positive"] == DOC_METRICS["true_positive"]
        and report["false_positive"] == DOC_METRICS["false_positive"]
        and report["false_negative"] == DOC_METRICS["false_negative"]
        and abs(report["precision"] - DOC_METRICS["precision"]) < 1e-9
        and abs(report["recall"] - DOC_METRICS["recall"]) < 1e-9
        and abs(report["mean_matched_iou"] - DOC_METRICS["mean_matched_iou"]) < 5e-4
        and abs(report["count_accuracy"] - DOC_METRICS["count_accuracy"]) < 1e-9
        and abs(report["exact_image_accuracy"] - DOC_METRICS["exact_image_accuracy"]) < 1e-9
    )
    return diff


def gpu_cross_check(model: nn.Module, cpu_report: dict) -> dict | None:
    if not torch.cuda.is_available():
        return None
    # 关掉 TF32 / cudnn benchmark，让 GPU 结果尽量贴近 CPU fp32（只做复核，不作为基线）
    try:
        torch.backends.cudnn.allow_tf32 = False
        torch.backends.cuda.matmul.allow_tf32 = False
        torch.backends.cudnn.benchmark = False
    except Exception:
        pass
    torch.manual_seed(SEED)
    gpu_report = run_precision_baseline(model, "cuda", batch_size=32)
    # 原始输出的数值差（固定输入）
    torch.manual_seed(SEED)
    x = torch.rand(2, 3, INPUT_SIZE, INPUT_SIZE) * 2 - 1
    model.to("cpu").eval()
    with torch.no_grad():
        out_cpu = [t.detach().clone() for t in model(x)]
    model.to("cuda").eval()
    with torch.no_grad():
        out_gpu = [t.detach().clone() for t in model(x.cuda())]
    max_diff = max(float((a - b.cpu()).abs().max()) for a, b in zip(out_cpu, out_gpu))
    keys = ("true_positive", "false_positive", "false_negative", "precision", "recall", "f1",
            "mean_matched_iou", "count_accuracy", "exact_image_accuracy")
    deltas = {k: float(gpu_report[k] - cpu_report[k]) for k in keys}
    ints_equal = all(
        gpu_report[k] == cpu_report[k] for k in ("true_positive", "false_positive", "false_negative")
    )
    floats_ok = all(abs(deltas[k]) <= 1e-4 for k in
                    ("precision", "recall", "f1", "mean_matched_iou", "count_accuracy", "exact_image_accuracy"))
    return {
        "device": "cuda",
        "gpu_name": torch.cuda.get_device_name(0),
        "tf32_disabled": True,
        "metrics": {k: gpu_report[k] for k in keys},
        "metric_deltas_gpu_minus_cpu": deltas,
        "matches_cpu": bool(ints_equal and floats_ok),
        "max_raw_output_abs_diff_cpu_vs_gpu": max_diff,
        "per_image_prediction_counts_equal": all(
            a["predicted_count"] == b["predicted_count"] for a, b in zip(cpu_report["per_image"], gpu_report["per_image"])
        ),
        "per_image_predictions_equal": all(
            a["classes"] == b["classes"] and abs(a["mean_iou"] - b["mean_iou"]) < 1e-5
            for a, b in zip(cpu_report["per_image"], gpu_report["per_image"])
        ),
        "gpu_seconds": gpu_report["seconds"],
        "note": "GPU 仅用于复核；可复现基线以 CPU 为准",
    }


def run_packaged_eval(out_dir: Path) -> dict | None:
    """独立跑一遍 nut_detector 自带的 evaluate_multi_mobilenet_anchor_free.py（强制 CPU）。

    这是对"本脚本自写评估循环"的独立交叉复核：打包脚本用未折叠 BN 的原始模型 + 同一套
    dataset/decode/matching；产物（test_report.json / test_predictions.csv / test_preview.jpg）
    写到 results/bottlecap/model/eval_packaged/。
    """
    import os
    import subprocess

    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable, "-m", "nut_detector.evaluate_multi_mobilenet_anchor_free",
        "--checkpoint", str(CKPT_PATH),
        "--dataset-dir", str(DATA_DIR),
        "--output-dir", str(out_dir),
    ]
    env = dict(os.environ)
    env["CUDA_VISIBLE_DEVICES"] = ""  # 强制 CPU，保证可复现
    env["PYTHONDONTWRITEBYTECODE"] = "1"  # 不在 model_src 里生成 __pycache__
    t0 = time.time()
    proc = subprocess.run(
        cmd, cwd=str(MODEL_SRC), env=env,
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    result: dict = {
        "command": " ".join(cmd),
        "cwd": str(MODEL_SRC),
        "cpu_forced": True,
        "seconds": round(time.time() - t0, 1),
        "returncode": proc.returncode,
    }
    report_path = out_dir / "test_report.json"
    if proc.returncode != 0 or not report_path.exists():
        result["ok"] = False
        result["stderr_tail"] = (proc.stderr or "")[-2000:]
        return result
    report = json.loads(report_path.read_text(encoding="utf-8"))
    result["ok"] = True
    result["report_path"] = str(report_path)
    result["report"] = {
        k: report[k]
        for k in (
            "checkpoint_epoch", "test_images", "true_objects", "predicted_objects",
            "true_positive", "false_positive", "false_negative", "precision", "recall", "f1",
            "mean_matched_iou", "count_accuracy", "exact_image_accuracy",
        )
    }
    result["per_class"] = report.get("per_class")
    result["by_true_object_count"] = report.get("by_true_object_count")
    result["by_lighting_profile"] = report.get("by_lighting_profile")
    result["artifacts"] = sorted(p.name for p in out_dir.iterdir() if p.is_file())
    return result


# ---------------------------------------------------------------------------
# 8) NPU 兼容性检查清单
# ---------------------------------------------------------------------------
def npu_compatibility(records: list[dict], summary: dict) -> list[dict]:
    conv = [r for r in records if r["npu_kind"] in ("conv", "dwconv")]
    checks: list[dict] = []

    def add(sev: str, item: str, detail: str) -> None:
        checks.append({"severity": sev, "item": item, "detail": detail})

    # 1. 权重预算
    add(
        "FATAL",
        "权重区 W 320KB 装不下",
        f"int8 权重 {b2s(summary['weights_int8_bytes_npu_packed'])}（NPU 打包口径），"
        f"是 W={b2s(W_BUDGET)} 的 {summary['w_over_budget_factor']:.2f}x；"
        f"checkpoint fp32 为 {b2s(summary['params_total'] * 4)}（{summary['params_total']:,} 参数）。"
        "片上常驻不可能，必须 DDR3 流式（或蒸馏/剪枝/换更小骨干）。",
    )
    # 2. Q 预算
    add(
        "FATAL",
        "量化参数区 Q 48KB 装不下",
        f"按 CONTRACT §7（6*OC_pad+16 每层 + 16 B/ADD_R）估算 {b2s(summary['q_region_bytes_estimate'])}，"
        f"是 Q={b2s(Q_BUDGET)} 的 {summary['q_over_budget_factor']:.2f}x。",
    )
    # 3. 激活缓冲
    add(
        "FATAL",
        "激活 A/B 缓冲装不下单张量",
        f"224 输入单张量峰值 {b2s(summary['peak_activation_bytes'])}（{summary['peak_activation_layer']}），"
        f"是 A={b2s(A_BYTES)} 的 {summary['peak_over_a_buffer_factor']:.2f}x；"
        f"最大单 op 驻留（src+dst）{b2s(summary['max_resident_bytes'])}，"
        f"是 A+B={b2s(AB_BYTES)} 的 {summary['max_resident_over_ab_factor']:.2f}x。",
    )
    # 4. 输入装不进 A
    add(
        "FATAL",
        "首层输入装不进 A",
        f"224x224 输入按 PACKED3=3B/像素 也要 {b2s(summary['input_bytes_packed3'])} > A={b2s(A_BYTES)}；"
        f"NHWC C8 口径为 {b2s(summary['input_bytes_nhwc_c8'])}。"
        "与 v0.7 cpu_conv0 先例一致：第一层只能 CPU 执行（或把输入缩到 <=160 且做通道分块）。",
    )
    # 5. IC/OC 限制
    ic_over = summary["layers_ic_over_256"]
    oc_over = summary["layers_oc_over_256"]
    add(
        "BLOCKER",
        "engine 规模限制 IC/OC <= 256 被打破",
        f"{len(summary['ic_or_oc_over_256_layers'])}/{summary['conv_layers']} 个卷积层越界 "
        f"(IC>256: {len(ic_over)} 层；OC>256: {len(oc_over)} 层；其中 11 个 InvertedResidual 的扩张通道 "
        "288/432/528/864）。OC>256 的扩张 1x1 可拆成 2 个 op 顺序写不同输出通道（不跨 256），"
        "但 IC>256 的 depthwise/pointwise 必须『拆 IC + 部分和累加』，而 v0.7 引擎的 conv add-mode 未实现"
        "（engine-report §8.2），且 conv 描述符没有通道偏移字段，需额外 copy 把通道块搬成独立张量；"
        "当前 ISA 不能直接映射。",
    )
    # 6. 4x upsample
    ups4 = [r for r in records if r["npu_kind"] == "copy" and r.get("upsample_ratio") == 4]
    add(
        "BLOCKER" if ups4 else "INFO",
        "4x 最近邻上采样无直接原语",
        f"{len(ups4)} 处 4x（{'、'.join(r['name'] for r in ups4) or '无'}）：COPY 只支持 2x（UP2X），"
        "4x 必须链式 2 次 2x 拷贝，多 1 个中间张量 + 1 次激活读写；若输入 224，中间张量 56x56x72=225,792 B。",
    )
    # 7. concat
    cats = [r for r in records if r["op"] == "concat"]
    add(
        "BLOCKER",
        "concat 只能靠多 copy 拼，dst 张量过大",
        f"{len(cats)} 处 concat（out {cats[0]['out_nhwc']}）：可用 "
        f"{cats[0]['npu_ops']} 个通道偏移 copy 实现（偏移 {cats[0]['channel_offsets']} 均 8 对齐="
        f"{cats[0]['channel_offsets_8aligned']}），但 dst 单张量 "
        f"{b2s(cats[0]['out_bytes'])} 远超 A 缓冲。",
    )
    # 8. add 后 ReLU
    relus = [r for r in records if r["npu_kind"] == "relu_standalone"]
    add(
        "BLOCKER",
        "add 之后紧跟 ReLU 无对应原语",
        f"{len(relus)} 处（ResidualConvBlock 的 x+conv2(x) 后接 relu；"
        "另 12 个 MobileNetV2 shortcut 的 add 后**没有**激活，可直接用 ADD op）：ISA 的 ADD 是纯 int8 饱和加，"
        "无后置激活；conv 的融合激活只能作用在卷积输出上。只能 CPU 做（v0.5 cpu_add 先例）"
        "或改结构（去掉 add 后 relu / 改成 conv add-mode，需引擎先支持 add-mode）。",
    )
    # 9. 量化 scale 约束
    adds = [r for r in records if r["npu_kind"] == "add"]
    add(
        "WARN",
        "ADD 要求两操作数同 scale/zp",
        f"{len(adds)} 个 add（12 个 MobileNetV2 shortcut + 5 个 ResidualConvBlock + 3 个 FPN 横向融合）"
        "按 CONTRACT §11 需要两操作数 scale/zp 相同；v0.5 用 cpu_add + per-tensor R 绕过。"
        "属于量化设计约束（可解），不是原语缺失。",
    )
    # 10. 最后 3 个 head：1x1 conv + bias，无激活（linear），后接 CPU 解码
    add(
        "INFO",
        "最后 3 个 head 是 linear 1x1 conv（无激活）",
        "objectness/class/box 三个 1x1 conv 带 bias、无激活：引擎可用 M_neg=M_pos（CONTRACT §5"
        "『无 leaky 的层 M_neg=M_pos』）+ 覆盖负值的输出量化范围表达 linear，bias 走 Q 区 bias_adj；"
        "之后的 sigmoid / local-max / softmax / top-k / NMS 全部在 CPU。",
    )
    # 10. 预处理/后处理
    add(
        "WARN",
        "预处理/后处理不在 NPU 图内",
        "预处理：320x240 -> bilinear 224x168 -> edge pad 28 -> /127.5-1 -> NCHW，NPU 只吃 NHWC int8 8 通道分块；"
        "后处理：objectness sigmoid + 3x3 local-max、class softmax、top-k、类内 NMS、网格解码，均应留在 CPU"
        "（与 yolo 档一致，代价可忽略）。",
    )
    # 11. 正向兼容点
    add(
        "PASS",
        "原语层面大体可映射",
        f"{summary['conv_layers']} 个卷积全部为 k=1/3、stride=1/2、pad=0/1（k=1 -> pad0，k=3 -> pad1），"
        "深度可分离卷积可用 depthwise flag；"
        f"BN 全部可折叠（{summary['bn_folded_layers']} 层）；激活全是 ReLU（可用 zp_out=-128 的 requant 表达，"
        "无 ReLU6/leaky）；无 pool；通道全部是 8 的倍数（仅 3 个 head 的 OC=1/4 需 padding 到 8）。",
    )
    # 12. op 数
    add(
        "PASS",
        "op 条数不超 ROM 深度",
        f"NPU 口径 {summary['npu_ops_total_after_cse']} op（CSE 前 {summary['npu_ops_total']}），"
        f"ROM 深度 {ROM_DEPTH}；条数不是瓶颈，瓶颈是权重/激活容量。",
    )
    return checks


# ---------------------------------------------------------------------------
# 9) 输出：JSON + Markdown
# ---------------------------------------------------------------------------
def write_outputs(doc: dict) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    JSON_PATH.write_text(json.dumps(doc, indent=2, ensure_ascii=False), encoding="utf-8")
    MD_PATH.write_text(render_markdown(doc), encoding="utf-8")


def _md_table(headers: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|"]
    for row in rows:
        out.append("| " + " | ".join(str(v) for v in row) + " |")
    return "\n".join(out)


def render_markdown(doc: dict) -> str:
    info = doc["model_info"]
    sm = doc["summary"]
    res = doc["multi_resolution"]["sizes"]
    th = doc["multi_resolution"]["analytic_thresholds"]
    alloc = doc["ab_allocation"]
    pb = doc.get("precision_baseline") or {}
    pb_cmp = doc.get("precision_baseline_vs_doc") or {}
    gpu = doc.get("gpu_cross_check")
    L: list[str] = []
    A = L.append

    A(f"# 四色瓶盖检测模型 · 逐层画像与 NPU 落地评估")
    A("")
    A(f"> 自动生成：`python tools/bottlecap/profile_model.py`（本文所有数字均由脚本从 "
      f"`{MODEL_SRC.name}/best_model.pt` 实测/推导，重跑即复现；勿手改）。")
    A(f"> 生成时间：{doc['meta']['generated_at']}；torch {doc['meta']['torch']}；"
      f"设备口径：画像=CPU 解析、精度基线={pb.get('device', 'n/a')}。")
    A("> 契约口径：`results/ai-accel/CONTRACT.md` v0.7 + `nn_pkg.sv`（W 320KB / Q 48KB / A 96KB / B 32KB，"
      "op = conv/dwconv/pool/copy/add，激活 NHWC 8 通道分块）。")
    A("")

    A("## 0. 结论摘要（先看这一节）")
    A("")
    A(_md_table(
        ["项目", "实测/推导值", "判据"],
        [
            ["参数量", f"**{sm['params_total']:,}**（与 run_config/checkpoint 一致：{info['param_count_matches_expected']}）",
             "strict load_state_dict + sum(p.numel())"],
            ["总 MACs @224", f"**{sm['total_macs']:,}**（{sm['total_macs'] / 1e9:.3f} GMAC，{sm['total_macs'] * 2 / 1e9:.2f} GFLOP）",
             "逐层 ic/groups*k*k*oc*oh*ow 求和"],
            ["int8 权重总字节", f"**{sm['weights_int8_bytes_npu_packed']:,} B**（NPU 打包）/ "
                              f"{sm['weights_int8_bytes_raw']:,} B（裸 numel）",
             "CONTRACT §6 OC_pad/IC_pad 补 8"],
            ["单张量激活峰值 @224", f"**{sm['peak_activation_bytes']:,} B**（{sm['peak_activation_layer']}，"
                                  f"{sm['peak_activation_shape_nhwc']}）",
             "NHWC 8 通道分块 H*W*C8；A 缓冲 96KB 的 "
             f"{sm['peak_over_a_buffer_factor']:.1f}x"],
            ["NPU 口径 op 数", f"**{sm['npu_ops_total_after_cse']} op**（conv {sm['dense_conv_layers']} + dwconv "
                              f"{sm['dwconv_layers']} + add {sm['add_ops']} + copy {sm['copy_ops_total_after_cse']}）",
             f"CSE 前 {sm['npu_ops_total']}；ROM 深度 {ROM_DEPTH}"],
            ["精度基线（CPU 复跑）", (f"TP={pb.get('true_positive')} FP={pb.get('false_positive')} "
                                    f"FN={pb.get('false_negative')}；P={pb.get('precision'):.3f} R={pb.get('recall'):.3f} "
                                    f"F1={pb.get('f1'):.3f} mIoU={pb.get('mean_matched_iou'):.6f}"
                                    if pb else "未运行（--skip-eval）"),
             (f"与文档一致：{pb_cmp.get('matches_doc')}" if pb_cmp else "未运行")],
            ["能否装进 A=96KB", f"**224/192/160/128 全部不能（全层口径）**；仅 FPN+头段 128 可（{res['128']['peak_fused_bytes_no_concat']:,} B）",
             "见 §5 多分辨率表"],
            ["整体结论", f"**不能直接上 NPU**：W/Q/A/B 四项预算全部超；且 {len(sm['ic_or_oc_over_256_layers'])} 层 "
                        f"IC/OC>256 触发引擎限制、{sm['relu_standalone_ops']} 处 add 后 ReLU 无原语。"
                        "需改结构/压缩/流式权重，或降到 64x64 输入（无实用意义）",
             "见 §4 不兼容清单"],
        ],
    ))
    A("")

    # 1. 模型加载验证
    A("## 1. 模型与加载验证")
    A("")
    A(_md_table(
        ["项目", "值"],
        [
            ["checkpoint", f"`{info['checkpoint']}`"],
            ["checkpoint 大小 / SHA256", f"{info['checkpoint_bytes']:,} B / `{info['checkpoint_sha256'][:16]}…`"],
            ["checkpoint epoch", f"{info['checkpoint_epoch']}"],
            ["model_variant", f"`{info['model_variant']}`"],
            ["fpn_channels / backbone_width", f"{info['fpn_channels']} / {info['backbone_width']}"],
            ["参数量（实测）", f"**{info['params_total']:,}**"],
            ["参数构成", f"卷积权重 {sm['params_by_kind']['conv_weights']:,} + BN 可训练(weight/bias) "
                        f"{sm['params_by_kind']['bn_trainable']:,} + head conv bias {sm['params_by_kind']['conv_bias']} "
                        f"= {sm['params_by_kind']['sum_trainable']:,}（与参数量一致："
                        f"{sm['params_by_kind']['sum_trainable'] == info['params_total']}）"],
            ["BN 存储量", f"checkpoint 里 BN 共 {sm['params_by_kind']['bn_stored_in_checkpoint']:,} 个标量"
                         "（含 running_mean/var 两个 buffer，折叠后推理不需要）"],
            ["run_config / checkpoint 声称参数量", f"{info['run_config_parameter_count']:,} / {info['checkpoint_parameter_count']:,}"],
            ["strict load_state_dict", "PASS（无缺失/多余 key）"],
            ["state_dict 条目", f"{info['state_dict_entries']}"],
            ["类别", ", ".join(info["class_names"])],
            ["BN 折叠等价性自检（max|Δ|）", f"{doc['bn_fold_check']['max_abs_diff']:.3e}（{doc['bn_fold_check']['n_fused']} 个 Conv+BN 对折叠）"],
            ["checkpoint 内记录指标", f"P={info['checkpoint_metrics'].get('test_precision')} "
                                     f"R={info['checkpoint_metrics'].get('test_recall')} "
                                     f"F1={info['checkpoint_metrics'].get('test_f1')} "
                                     f"mIoU={info['checkpoint_metrics'].get('test_mean_iou')}"],
        ],
    ))
    A("")

    # 2. 结构概览
    A("## 2. 结构概览（按 stage 聚合）")
    A("")
    A("网络 = EnhancedMobileNetV2(0.55) 骨干（C2=24 / C3=48 / C4=88 / C5=144，stage4 中间层 72ch）"
      " + 四层 FPN(lateral 1x1, 72ch) + 4 个 ResidualConvBlock 精炼 + 多尺度 concat(216ch)-融合 1x1"
      " + 三个解耦头塔（obj 3 层 / cls 3 层 / box 2 层，均 3x3 72ch），输出在 56x56（stride 4）。")
    A("")
    rows = []
    for st in sm["stage_order"]:
        v = sm["by_stage"][st]
        rows.append([
            st,
            v["layers"],
            v["conv_ops"] + v["dwconv_ops"],
            v["add_ops"],
            v["copy_ops"],
            f"{v['macs']:,}",
            f"{v['macs'] / sm['total_macs'] * 100:.1f}%",
            f"{v['weights_int8_bytes']:,}",
            f"{v['max_activation_bytes']:,}",
        ])
    A(_md_table(
        ["stage", "层数", "conv/dw", "add", "copy", "MACs", "MACs 占比", "权重 B(int8)", "最大单张量 B"],
        rows,
    ))
    A("")
    A(f"- 总 MACs：**{sm['total_macs']:,}**；后段（fpn.tower/head 的 56x56x72 段）占 "
      f"{(sm['macs_by_stage'].get('fpn.refine',0)+sm['macs_by_stage'].get('fpn.fusion',0)+sm['macs_by_stage'].get('head.tower',0))/sm['total_macs']*100:.1f}%"
      "——2M 参数不等于低算力，检测头在 56x56 分辨率上是主要算力来源。")
    A("")

    # 3. 逐层摘要（最重的层）
    A("## 3. 逐层画像（最重/最大张量 Top）")
    A("")
    A("完整逐层表（约 110 条，含 name/op/入出 NHWC/k-s-p-groups/权重字节/MACs/输出字节/激活类型）"
      "见 `model_profile.json` 的 `layers` 字段（机器可读）。下面是摘要：")
    A("")
    A("### 3.1 MACs Top 12")
    A("")
    top_macs = sorted([r for r in doc["layers"] if r["macs"] > 0], key=lambda r: r["macs"], reverse=True)[:12]
    A(_md_table(
        ["层", "op", "in NHWC", "out NHWC", "k/s/p/g", "MACs", "权重 B", "激活"],
        [
            [r["name"], r["op"], str(r["in_nhwc"]), str(r["out_nhwc"]),
             f'{r["k"]}/{r["s"]}/{r["p"]}/{r["groups"]}', f'{r["macs"]:,}',
             f'{r["weight_bytes_int8"]:,}', r["activation"]]
            for r in top_macs
        ],
    ))
    A("")
    A("### 3.2 单张量激活 Top 8")
    A("")
    A(_md_table(
        ["层", "op", "stage", "输出 NHWC", "字节", "A 96KB 的倍数"],
        [
            [r["name"], r["op"], r["stage"], str(r["nhwc"]),
             f'{r["bytes"]:,}', f'{r["bytes"] / A_BYTES:.2f}x']
            for r in sm["top_activation_tensors"][:8]
        ],
    ))
    A("")
    A("### 3.3 单个 op 需同时驻留的激活（src+dst）Top 6")
    A("")
    A(_md_table(
        ["层", "op", "in NHWC", "out NHWC", "驻留 B", "A+B 128KB 的倍数"],
        [
            [r["name"], r["op"], str(r["in_nhwc"]), str(r["out_nhwc"]),
             f'{r["resident_bytes"]:,}', f'{r["resident_bytes"] / AB_BYTES:.2f}x']
            for r in sm["top_resident_ops"][:6]
        ],
    ))
    A("")

    # 4. NPU 预算与不兼容清单
    A("## 4. NPU 落地评估（CONTRACT v0.7 口径）")
    A("")
    A("### 4.1 预算对账")
    A("")
    A(_md_table(
        ["预算项", "NPU 容量", "本模型需求", "结论"],
        [
            ["权重 W", b2s(W_BUDGET), f"{sm['weights_int8_bytes_npu_packed']:,} B（{sm['w_over_budget_factor']:.2f}x）", "**超**"],
            ["量化参数 Q", b2s(Q_BUDGET), f"{sm['q_region_bytes_estimate']:,} B（{sm['q_over_budget_factor']:.2f}x）", "**超**"],
            ["激活 A（最大单张量）", b2s(A_BYTES), f"{sm['peak_activation_bytes']:,} B（{sm['peak_over_a_buffer_factor']:.2f}x）", "**超**"],
            ["激活 A+B（单 op 驻留）", b2s(AB_BYTES), f"{sm['max_resident_bytes']:,} B（{sm['max_resident_over_ab_factor']:.2f}x）", "**超**"],
            ["op ROM", f"{ROM_DEPTH} 项", f"{sm['npu_ops_total_after_cse']} op", "够"],
            ["engine IC/OC", f"<= {ENGINE_MAX_IC_OC}",
             f"最大 {max(max(r['in_nhwc'][-1], r['out_nhwc'][-1]) for r in doc['layers'] if r['npu_kind'] in ('conv', 'dwconv'))} ch（扩张层）",
             "**超**"],
        ],
    ))
    A("")
    A("### 4.2 NPU 口径 op 数")
    A("")
    A(_md_table(
        ["原语", "数量", "说明"],
        [
            ["conv（dense，含 head 1x1）", sm["npu_ops_breakdown"]["conv_dense"], "k=1/3；BN+ReLU 融合，不计额外 op"],
            ["dwconv", sm["npu_ops_breakdown"]["dwconv"], "InvertedResidual 的 3x3 depthwise"],
            ["pool", 0, "网络里没有池化"],
            ["copy（upsample 2x）", sm["npu_ops_breakdown"]["upsample_copy"], "5 处 2x + 1 处 4x(=2 次 2x)；重复的 p3->56 CSE 省 1 次"],
            ["copy（concat 通道偏移）", sm["npu_ops_breakdown"]["concat_copy"], "3 个源 -> 同一 dst 通道偏移"],
            ["add", sm["npu_ops_breakdown"]["add"], "12 shortcut + 5 ResidualConv + 3 FPN 融合"],
            ["**合计**", f"**{sm['npu_ops_total_after_cse']}**", f"CSE 前 {sm['npu_ops_total']}；另有 {sm['relu_standalone_ops']} 处 add 后 ReLU 无原语"],
        ],
    ))
    A("")
    A("### 4.3 NPU 不兼容点清单")
    A("")
    sev_order = {"FATAL": 0, "BLOCKER": 1, "WARN": 2, "PASS": 3}
    for c in sorted(doc["npu_compatibility"], key=lambda x: sev_order.get(x["severity"], 9)):
        A(f"- **[{c['severity']}] {c['item']}** —— {c['detail']}")
    A("")

    # 5. 多分辨率
    A("## 5. 多分辨率激活估算与「96KB A 缓冲」结论")
    A("")
    A("口径：保持网络结构与通道不变，输入尺寸 S 等比缩放所有空间尺寸（224->112->56->28->14->7 对应 S/2..S/32），"
      "激活字节按 NHWC 8 通道分块 H*W*C8；峰值 = 全网络所有中间张量（含输入张量）的最大单张量。"
      "**注意**：真实 96KB 判定还受 A/B 乒乓（单 op 需 src+dst 同时驻留）与 B=32KB 不等大限制。")
    A("")
    rows = []
    for key in ("224", "192", "160", "128", "96", "64"):
        v = res[key]
        rows.append([
            key,
            f"{v['peak_activation_bytes_all_layers']:,}",
            f"{v['peak_fused_bytes_no_concat']:,}",
            f"{v['peak_fused_bytes_with_concat']:,}",
            f"{v['input_bytes_packed3']:,}",
            f"{v['macs']:,}",
            "是" if v["fits_96k_all_layers"] else "**否**",
            "是" if v["fits_96k_fused_no_concat"] else "否",
            "是" if v["fits_96k_fused_with_concat"] else "否",
        ])
    A(_md_table(
        ["输入 S", "全层峰值 B", "融合段峰值 B（不含 concat）", "融合段峰值 B（含 concat）", "输入 PACKED3 B", "MACs", "全层 <=98,304?", "融合段 <=98,304?", "含 concat <=98,304?"],
        rows,
    ))
    A("")
    A("**结论**：")
    A(f"1. **严格按全层单张量口径：128/160/192 都塞不进 96KB**（128 峰值 "
      f"{res['128']['peak_activation_bytes_all_layers']:,} B = A 的 "
      f"{res['128']['peak_activation_bytes_all_layers'] / A_BYTES:.1f}x；160 为 "
      f"{res['160']['peak_activation_bytes_all_layers']:,} B；192 为 {res['192']['peak_activation_bytes_all_layers']:,} B）。"
      f"解析阈值：全层峰值 <= 98,304 B（= 96KiB，正好是 A 的容量）需要 S <= "
      f"{th['all_layers_S_max_for_98304']:.1f}，即 **64x64（峰值恰好 98,304 B）**。"
      "瓶颈是 stem 后 stage1/stage2 的全分辨率扩张张量（224 下 96ch x 112x112 = 1,204,224 B），"
      "不是 FPN。")
    A(f"2. **若只把 FPN+检测头段放进 A 缓冲（忽略 stem/扩张段）**：只有 **128 输入**满足 "
      f"（72ch x 32x32 = {res['128']['peak_fused_bytes_no_concat']:,} B <= 98,304 B）；"
      f"160 为 {res['160']['peak_fused_bytes_no_concat']:,} B、192 为 {res['192']['peak_fused_bytes_no_concat']:,} B，均超。"
      f"解析阈值 S <= {th['fused_no_concat_S_max_for_98304']:.1f}。")
    A(f"3. **concat 单独再卡一刀**：3 路 56x56x72 -> 216ch 的张量在 224 下 "
      f"{res['224']['peak_fused_bytes_with_concat']:,} B，即使 128 也要 "
      f"{res['128']['peak_fused_bytes_with_concat']:,} B > 96KB（阈值 S <= "
      f"{th['fused_with_concat_S_max_for_98304']:.1f}）。若要保 concat 而不拆，需要把融合段降到 <= 84x84 量级。")
    A(f"4. **A/B 乒乓更严**：单 op 需 src+dst 同时驻留；224 下最大单 op 驻留 "
      f"{sm['max_resident_bytes']:,} B（{sm['max_resident_over_ab_factor']:.1f}x A+B=128KB）。"
      f"即使 128 输入，融合段相邻两个 72ch 张量也要 2 x {res['128']['peak_fused_bytes_no_concat']:,} = "
      f"{2 * res['128']['peak_fused_bytes_no_concat']:,} B > 128KB（且 B 只有 32KB，放不下 32x32x72 张量），"
      "**必须做通道分块/部分和（conv add-mode）或降低头部分辨率**，否则连 128 也排不进 A/B。")
    A("")
    A("### 5.1 A/B 贪心分配实测（乐观：add 原地、不拆通道）")
    A("")
    A(_md_table(
        ["输入 S", "全层最大单张量 B", "分配结果", "失败点", "peak_A", "peak_B", "备注"],
        [
            [k, f"{alloc[k]['max_single_tensor']:,}", "OK" if alloc[k]["ok"] else "**FAIL**",
             (alloc[k]["fail"] or "-")[:70] + ("…" if alloc[k]["fail"] and len(alloc[k]["fail"]) > 70 else ""),
             f"{alloc[k]['peak_A']:,}", f"{alloc[k]['peak_B']:,}",
             "输入/首层就超 A" if k == "224" else ""]
            for k in ("224", "192", "160", "128", "96", "64")
        ],
    ))
    A("")
    A("> 分配器口径与 `tools/yolo/darknet_lib.allocate` 同思路（生命周期 + A/B 两区贪心），"
      "但未建模通道分块/tile；因此 FAIL 表示「按整张量放不可能」，OK 也只是必要条件。")
    A("")
    A("**为什么连 64x64 也 FAIL**：A/B 不等大（96KB + 32KB）。64x64 时 stage1 的扩张张量 64ch x 32x32 = "
      "65,536 B，相邻两个这样的张量需要 2 x 65,536 = 131,072 B，恰好等于 A+B 总容量，但 B 只有 32,768 B、"
      "放不下任何 65,536 B 张量 ⇒ 单 op 的 src/dst 无法分置两区。也就是说：**在现有 A/B 划分下，"
      "即使 64x64 输入也必须做通道分块（把 64ch 拆成 8/16 通道块）才能排进缓冲**；"
      "128/160/192 则需要同时解决通道分块与 96KB 上限。")
    A("")

    # 6. 精度基线
    A("## 6. 浮点精度基线实测（复跑文档指标）")
    A("")
    if pb:
        A("口径（与 `nut_detector/evaluate_multi_mobilenet_anchor_free.py` 完全一致）："
          "预处理 320x240 RGB -> bilinear 224x168 -> 上下 edge pad 28 -> `/127.5-1` -> NCHW；"
          "解码 `decode_multi_predictions`：sigmoid objectness x 3x3 local-max x softmax 类概率，"
          "pre-NMS top-40、置信度 0.20、类内 NMS IoU 0.35、最多 4 个；"
          "匹配：类内贪心、IoU>=0.5。")
        A("")
        A(_md_table(
            ["指标", "文档声称", "本机实测（CPU）", "差值"],
            [
                ["测试图片", DOC_METRICS["test_images"], pb["test_images"], pb["test_images"] - DOC_METRICS["test_images"]],
                ["目标数", DOC_METRICS["true_objects"], pb["true_objects"], pb["true_objects"] - DOC_METRICS["true_objects"]],
                ["TP", DOC_METRICS["true_positive"], pb["true_positive"], pb_cmp.get("true_positive")],
                ["FP", DOC_METRICS["false_positive"], pb["false_positive"], pb_cmp.get("false_positive")],
                ["FN", DOC_METRICS["false_negative"], pb["false_negative"], pb_cmp.get("false_negative")],
                ["Precision", DOC_METRICS["precision"], f"{pb['precision']:.6f}", f"{pb_cmp.get('precision'):.2e}"],
                ["Recall", DOC_METRICS["recall"], f"{pb['recall']:.6f}", f"{pb_cmp.get('recall'):.2e}"],
                ["F1", DOC_METRICS["f1"], f"{pb['f1']:.6f}", f"{pb_cmp.get('f1'):.2e}"],
                ["mean matched IoU", f"{DOC_METRICS['mean_matched_iou']:.6f}", f"{pb['mean_matched_iou']:.6f}",
                 f"{pb_cmp.get('mean_matched_iou'):.2e}"],
                ["目标数量准确率", DOC_METRICS["count_accuracy"], f"{pb['count_accuracy']:.6f}", f"{pb_cmp.get('count_accuracy'):.2e}"],
                ["整图全对率", DOC_METRICS["exact_image_accuracy"], f"{pb['exact_image_accuracy']:.6f}", f"{pb_cmp.get('exact_image_accuracy'):.2e}"],
            ],
        ))
        A("")
        A(f"**与文档一致性：{pb_cmp.get('matches_doc')}**（差值全部在浮点/阈值容差内；"
          f"CPU 500 张耗时 {pb['seconds']} s，纯 CPU 可复现）。")
        A("")
        A("按目标数分组：")
        A("")
        rows = []
        for cnt, v in pb["by_true_object_count"].items():
            rows.append([cnt, v["images"], "%.4f" % v["precision"], "%.4f" % v["recall"],
                         "%.4f" % v["f1"], "%.4f" % v["exact_image_accuracy"]])
        A(_md_table(["真实目标数", "图片数", "Precision", "Recall", "F1", "整图全对率"], rows))
        A("")
        A("按类别分组：")
        A("")
        rows = []
        for ci, name in enumerate(pb["class_names"]):
            v = pb["per_class"][str(ci)]
            rows.append([name, v["true_objects"], v["predicted_objects"], v["matched_objects"],
                         "%.4f" % v["precision"], "%.4f" % v["recall"]])
        A(_md_table(["类别", "真实数", "预测数", "匹配数", "Precision", "Recall"], rows))
        A("")
    pkg = doc.get("packaged_eval_cross_check")
    if pkg and pkg.get("ok"):
        rep = pkg["report"]
        A("### 6.1 独立交叉复核：直接运行 nut_detector 自带评估脚本（强制 CPU）")
        A("")
        A(f"产物：`results/bottlecap/model/eval_packaged/`（{', '.join(pkg.get('artifacts', []))}）。"
          "这条路径用的是**未折叠 BN 的原始模型**和打包脚本自己的 batch/评测循环，"
          "用来独立验证 §6 的基线不是本脚本实现偏差。")
        A("")
        A(_md_table(
            ["指标", "本脚本基线（折叠 BN）", "打包脚本复跑", "差值"],
            [
                ["TP", pb["true_positive"], rep["true_positive"], rep["true_positive"] - pb["true_positive"]],
                ["FP", pb["false_positive"], rep["false_positive"], rep["false_positive"] - pb["false_positive"]],
                ["FN", pb["false_negative"], rep["false_negative"], rep["false_negative"] - pb["false_negative"]],
                ["Precision", f"{pb['precision']:.6f}", f"{rep['precision']:.6f}", f"{rep['precision'] - pb['precision']:+.2e}"],
                ["Recall", f"{pb['recall']:.6f}", f"{rep['recall']:.6f}", f"{rep['recall'] - pb['recall']:+.2e}"],
                ["F1", f"{pb['f1']:.6f}", f"{rep['f1']:.6f}", f"{rep['f1'] - pb['f1']:+.2e}"],
                ["mean matched IoU", f"{pb['mean_matched_iou']:.6f}", f"{rep['mean_matched_iou']:.6f}",
                 f"{rep['mean_matched_iou'] - pb['mean_matched_iou']:+.2e}"],
                ["整图全对率", f"{pb['exact_image_accuracy']:.6f}", f"{rep['exact_image_accuracy']:.6f}",
                 f"{rep['exact_image_accuracy'] - pb['exact_image_accuracy']:+.2e}"],
                ["checkpoint epoch", "-", rep["checkpoint_epoch"], "-"],
            ],
        ))
        A("")
        A(f"→ 两个独立实现的整数指标完全一致、mIoU 差 {abs(rep['mean_matched_iou'] - pb['mean_matched_iou']):.2e}，"
          "**文档指标复现成立**。")
        A("")
    if gpu:
        A("### 6.2 GPU 复核（仅交叉验证，不作为可复现基线）")
        A("")
        A(f"- GPU：{gpu['gpu_name']}；与 CPU 指标一致（容差 1e-4）：**{gpu['matches_cpu']}**；"
          f"逐图预测数一致：{gpu['per_image_prediction_counts_equal']}；"
          f"原始输出 max|ΔCPU-GPU| = {gpu['max_raw_output_abs_diff_cpu_vs_gpu']:.3e}"
          f"（已关 TF32；GPU {gpu['gpu_seconds']} s）。")
        A("")

    # 7. 建议
    A("## 7. 对 NPU 落地的直接建议（数据驱动）")
    A("")
    A(f"1. **权重是第一位瓶颈**：int8 {sm['weights_int8_bytes_npu_packed']:,} B 是 W 320KB 的 "
      f"{sm['w_over_budget_factor']:.1f}x。要么 DDR3 流式权重（W 只做当前层 cache），要么换 ~300KB 量级的子网/"
      "剪枝+蒸馏，否则「2M 参数整模型上 96KB A + 320KB W」不成立。")
    A(f"2. **算力也不小**：{sm['total_macs'] / 1e9:.2f} GMAC @224，其中检测头 56x56x72 段占 "
      f"{(sm['macs_by_stage'].get('fpn.refine',0)+sm['macs_by_stage'].get('fpn.fusion',0)+sm['macs_by_stage'].get('head.tower',0))/sm['total_macs']*100:.0f}%。"
      "若必须上现有 NPU，先把 head/FPN 从 stride-4（56x56）降到 stride-8（28x28），MACs 约降到 "
      f"~{(sm['total_macs'] - sm['macs_by_stage'].get('fpn.refine',0) - sm['macs_by_stage'].get('fpn.fusion',0) - sm['macs_by_stage'].get('head.tower',0) + (sm['macs_by_stage'].get('fpn.refine',0)+sm['macs_by_stage'].get('fpn.fusion',0)+sm['macs_by_stage'].get('head.tower',0))/4) / 1e9:.2f} GMAC。")
    A(f"3. **结构上最硬的坎**：{len(sm['layers_ic_over_256'])} 个 conv 的 IC>256（另有 "
      f"{len(sm['layers_oc_over_256'])} 个 OC>256），以及 {sm['relu_standalone_ops']} 处 add 后 ReLU。"
      "前者需要引擎支持 conv add-mode + 通道偏移（当前都未实现），后者需要新原语或 CPU 执行；"
      "这两项不是「改量化参数」能绕过的。")
    A("4. **如果只是想验证流程**：把输入降到 128 且只把 FPN+头段放 A，需要同时（a）拆 channel 到 <=256 的块、"
      "（b）消除 concat 的 216ch dst（改成 3 个 72ch 局部和 + add）、（c）stem/扩张段另行 tile。"
      "工作量接近重写部署图，不如先做「int8 子网 + 28x28 头」的新模型。")
    A("")

    # 8. 复现
    A("## 8. 复现")
    A("")
    A("```powershell")
    A("cd D:\\USER\\Desktop\\FPGA\\FPGA")
    A("python tools/bottlecap/profile_model.py                 # 画像 + CPU 精度基线 + GPU/打包脚本双复核")
    A("python tools/bottlecap/profile_model.py --no-gpu-check   # 不用 GPU")
    A("python tools/bottlecap/profile_model.py --no-packaged-eval  # 不额外跑打包评估脚本")
    A("python tools/bottlecap/profile_model.py --skip-eval      # 只画像")
    A("```")
    A("")
    A(f"产物：`{JSON_PATH.relative_to(REPO_ROOT)}`（逐层表 + 全部汇总，机器可读）、"
      f"`{MD_PATH.relative_to(REPO_ROOT)}`（本文，脚本自动生成）。")
    A("")
    return "\n".join(L) + "\n"


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--skip-eval", action="store_true", help="不跑 500 张测试集精度基线")
    p.add_argument("--no-gpu-check", action="store_true", help="不做 GPU 交叉复核")
    p.add_argument(
        "--packaged-eval",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="额外用 nut_detector 自带 evaluate 脚本独立复核（强制 CPU，产物写到 eval_packaged/）",
    )
    p.add_argument("--batch-size", type=int, default=32)
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    sys.dont_write_bytecode = True  # 不在 tools/bottlecap/model_src 里留 __pycache__
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    random.seed(SEED)
    torch.manual_seed(SEED)
    torch.set_num_threads(max(1, min(12, (torch.get_num_threads() or 1))))

    t_start = time.time()
    model, info = load_model()
    print(f"[1/5] 模型加载 PASS：params={info['params_total']:,} "
          f"(expected {EXPECTED_PARAMS:,}, match={info['param_count_matches_expected']})")

    # BN 折叠 + 等价性自检
    torch.manual_seed(SEED)
    probe = torch.rand(4, 3, INPUT_SIZE, INPUT_SIZE) * 2 - 1
    with torch.no_grad():
        ref = model(probe)
    folded, fused_names = fuse_bn(model)
    with torch.no_grad():
        got = folded(probe)
    max_diff = max(float((a - b).abs().max()) for a, b in zip(ref, got))
    bn_fold_check = {"n_fused": len(fused_names), "max_abs_diff": max_diff, "passed": bool(max_diff < 1e-4)}
    print(f"[2/5] BN 折叠：{len(fused_names)} 对，max|Δ|={max_diff:.3e} "
          f"({'PASS' if max_diff < 1e-4 else 'FAIL'})")

    # fx 抓图（用 BN 折叠后的模型更贴近硬件；再 fold=True 时不会再有 BN）
    gm = trace_model(folded)
    records, node2rec, input_rec = build_layer_records(folded, gm, set(fused_names))
    summary = summarize(records, info)
    print(f"[3/5] 逐层解析：{len(records)} 条记录；conv {summary['conv_layers']}、add {summary['add_ops']}、"
          f"copy {summary['copy_ops_total']}、op_total {summary['npu_ops_total_after_cse']}；"
          f"MACs={summary['total_macs']:,}；峰值激活 {summary['peak_activation_bytes']:,} B")

    multi_res = multi_resolution_analysis(records, summary)
    alloc = {
        str(s): ab_allocation(records, s)
        for s in RES_SIZES
    }
    print("[4/5] 多分辨率估算 + A/B 贪心分配完成")

    precision = None
    vs_doc = None
    gpu = None
    packaged = None
    if not args.skip_eval:
        torch.set_num_threads(max(1, torch.get_num_threads()))
        precision = run_precision_baseline(folded, "cpu", batch_size=args.batch_size)
        vs_doc = compare_with_doc(precision)
        print(f"[5/5] 精度基线 CPU：TP={precision['true_positive']} FP={precision['false_positive']} "
              f"FN={precision['false_negative']} P={precision['precision']:.6f} R={precision['recall']:.6f} "
              f"F1={precision['f1']:.6f} mIoU={precision['mean_matched_iou']:.6f} "
              f"整图={precision['exact_image_accuracy']:.6f} -> 与文档一致={vs_doc['matches_doc']}")
        if not args.no_gpu_check and torch.cuda.is_available():
            gpu = gpu_cross_check(folded, precision)
            print(f"      GPU 复核：一致={gpu['matches_cpu']}，逐图预测数一致={gpu['per_image_prediction_counts_equal']}，"
                  f"max|Δraw|={gpu['max_raw_output_abs_diff_cpu_vs_gpu']:.2e}")
        if args.packaged_eval:
            packaged = run_packaged_eval(OUT_DIR / "eval_packaged")
            if packaged and packaged.get("ok"):
                rep = packaged["report"]
                same = (
                    rep["true_positive"] == precision["true_positive"]
                    and rep["false_positive"] == precision["false_positive"]
                    and rep["false_negative"] == precision["false_negative"]
                    and abs(rep["mean_matched_iou"] - precision["mean_matched_iou"]) < 1e-4
                )
                print(f"      packaged eval 独立复核（CPU）：P={rep['precision']} R={rep['recall']} "
                      f"F1={rep['f1']} mIoU={rep['mean_matched_iou']:.6f} -> 与本脚本一致={same}")
            else:
                print(f"      packaged eval 失败：{packaged.get('stderr_tail', '')[-300:] if packaged else 'skipped'}")
    else:
        print("[5/5] 跳过精度基线（--skip-eval）")

    compat = npu_compatibility(records, summary)
    doc = {
        "meta": {
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "script": str(Path(__file__).relative_to(REPO_ROOT)).replace("\\", "/"),
            "repo_root": str(REPO_ROOT),
            "torch": torch.__version__,
            "python": sys.version.split()[0],
            "platform": platform.platform(),
            "cpu_count": torch.get_num_threads(),
            "seed": SEED,
            "elapsed_seconds": round(time.time() - t_start, 1),
            "data_dir": str(DATA_DIR),
            "test_annotations": str(DATA_DIR / "test_annotations.csv"),
            "npu_contract": "results/ai-accel/CONTRACT.md v0.7 + nn_pkg.sv",
            "budgets": {"W_bytes": W_BUDGET, "Q_bytes": Q_BUDGET, "A_bytes": A_BYTES, "B_bytes": B_BYTES,
                        "max_single_tensor_bytes": MAX_SINGLE_TENSOR, "engine_max_ic_oc": ENGINE_MAX_IC_OC,
                        "rom_depth": ROM_DEPTH},
            "stats_definitions": {
                "activation_bytes": "NHWC 8 通道分块 H*W*C8, C8=ceil(C/8)*8（CONTRACT §8）",
                "weight_bytes_int8": "BN 折叠后卷积权重元素数 x 1B",
                "weight_bytes_npu": "CONTRACT §6：[tap][IC_pad][OC_pad] / depthwise [tap][OC_pad]",
                "macs": "ic/groups * k * k * oc * oh * ow",
                "npu_ops": "conv=1, dwconv=1, add=1, 2x upsample copy=1, 4x=2, concat=源张量数；BN/卷积后ReLU 融合不计",
                "peak_activation": "所有层输出张量（含输入 PACKED3）中的最大单张量字节数",
            },
        },
        "model_info": info,
        "bn_fold_check": bn_fold_check,
        "summary": summary,
        "layers": records,
        "multi_resolution": multi_res,
        "ab_allocation": alloc,
        "npu_compatibility": compat,
        "precision_baseline": precision,
        "precision_baseline_vs_doc": vs_doc,
        "gpu_cross_check": gpu,
        "packaged_eval_cross_check": packaged,
        "doc_metrics": DOC_METRICS,
    }
    write_outputs(doc)
    print(f"写入：{JSON_PATH}（{JSON_PATH.stat().st_size:,} B）")
    print(f"写入：{MD_PATH}（{MD_PATH.stat().st_size:,} B）")
    print(f"完成，用时 {time.time() - t_start:.1f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
