#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""extract_graph.py — PyTorch 检测模型 -> NPU 线性执行图 (graph.json)。

唯一语义来源: results/ai-accel/CONTRACT.md + tools/yolo/quant_lib.py。
本脚本只做"结构翻译"(BN 折叠 -> 线性 op 序列 + 张量表), 不做量化/地址分配。

用法:
    python tools/bottlecap/extract_graph.py                        # 224 原模型
    python tools/bottlecap/extract_graph.py --input-size 160        # 160 输入
    python tools/bottlecap/extract_graph.py --arch slim \\
        --checkpoint results/bottlecap/slim/best_model.pt --input-size 160

产物: results/bottlecap/plan/graph.json

与 CONTRACT 对齐的翻译规则:
  * conv: k∈{1,3,5}, stride∈{1,2}, pad=k//2, groups∈{1,ic}; BN 折叠进 conv(§5)。
  * ReLU 不是独立硬件 op: 由 per-tensor 非对称量化 [min=0, zp=-128] 的底部饱和精确表达
    (负 pre-act -> y<0 -> y+zp_out<-128 -> saturate -128 -> 反量化 0)。故 leaky flag 全 0。
    v0.8 起 plan 每个 op 显式给 act("relu"/"none"), 并在 flags bit4 置 RELU(双保险)。
  * 残差/FPN add 一律映射为 ADD_R; 依据"目标域 + 是否后接 ReLU"选择被写回的操作数(dst):
      - type A residual_relu: F.relu(x + conv2(x)) -> dst=x(relu 域), 底部饱和即 ReLU;
      - type B linear:        x + conv(x) 无激活 -> dst=卷积分支输出(线性域), x 作 src;
      - type C fpn_sum:       两个操作数都是 relu 域 -> 和必 >=0, dst=其中一个。
  * concat: 展开为"每个源张量一条 copy op(通道偏移写进同一目标张量)"(§10.1 紧凑布局)。
  * nearest 2x upsample: 独立 upsample op(NN_OP_COPY + UP2X, ic==oc)。
    (引擎 UP2X 通道偏移路径要求 ic8==oc8, 所以 concat 的上采样先独立上采样再 copy,
     与 sim/prog/yolo 的既有 upsample+copy 口径一致。)
  * 每个 op 额外给 wlen(int8 权重字节, 8 通道对齐后实际字节) 与
    qlen(Q 块字节: conv=6*OC_pad+16, add=16, 其它=0) —— v0.8 ROM / DDR3 预取字段。
"""
from __future__ import annotations

import argparse
import json
import operator
import os
import sys
from collections import Counter, OrderedDict

import numpy as np
import torch
import torch.fx as fx
import torch.nn.functional as F
from torch import nn

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MODEL_SRC = os.path.join(HERE, "model_src")
if MODEL_SRC not in sys.path:
    sys.path.insert(0, MODEL_SRC)

DEFAULT_CKPT = os.path.join(HERE, "model_src", "best_model.pt")
DEFAULT_OUTDIR = os.path.join(ROOT, "results", "bottlecap", "plan")

# plan flags 约定(T-model 侧; tools/nn_gen_rom.py / nn_gen_sw.py 映射到 nn_pkg 位位置)
FLAG_DEPTHWISE, FLAG_LEAKY, FLAG_PACKED3, FLAG_ADD_R = 1, 2, 4, 8
FLAG_RELU = 16      # v0.8: plan flags bit4 -> nn_pkg::NN_F_RELU (Lead 2026-11-03)

# DOMAIN: "relu"   = 值域 >=0 且 ReLU 语义靠 zp=-128 的底部饱和实现;
#         "linear" = 有符号域(普通非对称量化)。
DOM_RELU, DOM_LINEAR = "relu", "linear"
# op 级激活名(写进 plan.json 的 act 字段)
ACT_RELU, ACT_NONE = "relu", "none"


# ----------------------------------------------------------------------------
# checkpoint / model
# ----------------------------------------------------------------------------
def _cfg_get(ck, key, default=None):
    if key in ck:
        return ck[key]
    cfg = ck.get("config") or {}
    return cfg.get(key, default)


def detect_arch(ck):
    if _cfg_get(ck, "model_variant") == "enhanced_mobilenetv2_fpn_decoupled_head":
        return "enhanced"
    if _cfg_get(ck, "width_multiplier") is not None:
        return "slim"
    return "enhanced"


def build_model(ckpt_path, arch=None, num_classes=4):
    """构造模型并 strict 加载; 返回 (model, ckpt, arch)。"""
    ck = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    arch = arch or detect_arch(ck)
    if arch == "enhanced":
        from nut_detector.enhanced_anchor_free import EnhancedNutAnchorFree
        m = EnhancedNutAnchorFree(
            num_classes=num_classes,
            fpn_channels=int(_cfg_get(ck, "fpn_channels", 72)),
            backbone_width=float(_cfg_get(ck, "backbone_width", 0.55)))
    elif arch == "slim":
        from nut_detector.mobilenet_anchor_free_slim import SlimMobileNetNutAnchorFree
        m = SlimMobileNetNutAnchorFree(
            num_classes=num_classes,
            width_multiplier=float(_cfg_get(ck, "width_multiplier", 0.5)),
            fpn_channels=int(_cfg_get(ck, "fpn_channels", 32)))
    else:
        raise SystemExit("unknown --arch %r (enhanced|slim)" % arch)
    m.load_state_dict(ck["model"], strict=True)
    m.eval()
    return m, ck, arch


def conv_bn_fuse(conv, bn):
    """Conv2d(+可选 bias) + BatchNorm2d -> (W', b'), float64, CONTRACT §5。"""
    W = conv.weight.detach().double().numpy().copy()
    b = (conv.bias.detach().double().numpy().copy() if conv.bias is not None
         else np.zeros(W.shape[0], dtype=np.float64))
    gamma = bn.weight.detach().double().numpy()
    beta = bn.bias.detach().double().numpy()
    mean = bn.running_mean.detach().double().numpy()
    var = bn.running_var.detach().double().numpy()
    scale = gamma / np.sqrt(var + float(bn.eps))
    W = W * scale[:, None, None, None]
    b = b * scale + (beta - mean * scale)
    return np.ascontiguousarray(W), np.ascontiguousarray(b)


# ----------------------------------------------------------------------------
# FX 图执行: 记录每个节点的真实输出(拿 shape / 浮点参考)
# ----------------------------------------------------------------------------
class RecordingInterpreter(fx.Interpreter):
    def __init__(self, module):
        super().__init__(module)
        self.outputs = OrderedDict()

    def run_node(self, n):
        out = super().run_node(n)
        self.outputs[n.name] = out
        return out


def trace_and_record(model, input_size, seed=12345):
    """symbolic_trace + 用确定性输入真跑一遍, 返回 (graph, interp, x, out_tuple)。"""
    g = fx.symbolic_trace(model)
    gm = fx.GraphModule(model, g.graph)
    gen = torch.Generator().manual_seed(seed)
    x = (torch.rand(1, 3, input_size, input_size, generator=gen) * 2.0 - 1.0)
    interp = RecordingInterpreter(gm)
    with torch.no_grad():
        outs = interp.run(x)
    return g, interp, x, outs


# ----------------------------------------------------------------------------
# graph -> linear ops
# ----------------------------------------------------------------------------
def linearize(model, input_size, seed=12345, verbose=True):
    """FX 图 -> (tensors, ops, folded, final_tids, run_meta)。"""
    g, interp, example, out_tuple = trace_and_record(model, input_size, seed)
    gm = fx.GraphModule(model, g.graph)
    nodes = list(g.graph.nodes)

    consumers = {n.name: [] for n in nodes}
    for n in nodes:
        for a in list(n.args) + list(n.kwargs.values()):
            items = a if isinstance(a, (list, tuple)) else [a]
            for it in items:
                if isinstance(it, fx.Node):
                    consumers[it.name].append(n)

    def resolve(target):
        return gm.get_submodule(str(target))

    def is_relu_node(n):
        if n.op == "call_module":
            return isinstance(resolve(n.target), nn.ReLU)
        return n.op == "call_function" and n.target is F.relu

    def out_shape(name):
        o = interp.outputs[name]
        if isinstance(o, (tuple, list)):
            raise SystemExit("node %s produced tuple, tensor expected" % name)
        return tuple(int(v) for v in o.shape)

    tensors, ops, folded = [], [], []

    def add_tensor(name, h, w, c, domain, packed=False, role=""):
        tid = len(tensors)
        c8 = int(c) if packed else ((int(c) + 7) // 8) * 8
        tensors.append({
            "tid": tid, "name": str(name), "h": int(h), "w": int(w), "c": int(c),
            "c8": int(c8), "bytes": int(h) * int(w) * int(c8),
            "domain": domain, "packed": bool(packed),
            "producer_op": -1, "last_writer_op": -1,
            "final": False, "role": role,
        })
        return tid

    def dom(tid):
        return tensors[tid]["domain"]

    def has_relu_consumer(node):
        return any(is_relu_node(c) for c in consumers[node.name])

    def only_node_args(node):
        return [a for a in node.args if isinstance(a, fx.Node)]

    def finish_op(op):
        """补 v0.8 的 wlen/qlen 字段, 保证 act=relu 时 flags bit4 置位, 然后登记。"""
        if op["kind"] in ("conv", "dwconv"):
            op["wlen"] = int(op["weight_bytes"])
            op["qlen"] = int(6 * op["oc_pad"] + 16)
        elif op["kind"] == "add":
            op["wlen"] = 0
            op["qlen"] = 16
        else:
            op["wlen"] = 0
            op["qlen"] = 0
        if op["act"] == ACT_RELU and not (op["flags"] & FLAG_RELU):
            op["flags"] |= FLAG_RELU
        ops.append(op)

    env = {}              # fx node name -> tensor id
    upsample_cache = {}   # (src_tid, ratio) -> 已生成的上采样张量 id (CSE)
    input_tid = add_tensor("input", input_size, input_size, 3, DOM_LINEAR,
                           packed=True, role="input")

    for node in nodes:
        if node.op == "placeholder":
            env[node.name] = input_tid
            continue
        if node.op in ("getattr", "getitem"):
            continue
        if node.op == "output":
            continue

        # ---------------- call_module ----------------
        if node.op == "call_module":
            mod = resolve(node.target)
            if isinstance(mod, nn.Conv2d):
                bn_node = None
                for c in consumers[node.name]:
                    if c.op == "call_module" and isinstance(resolve(c.target), nn.BatchNorm2d):
                        bn_node = c
                        break
                if bn_node is not None:
                    W, b = conv_bn_fuse(mod, resolve(bn_node.target))
                    mod_name = "%s+bn" % node.target
                    out_node = bn_node
                else:
                    W = mod.weight.detach().double().numpy().copy()
                    b = (mod.bias.detach().double().numpy().copy() if mod.bias is not None
                         else np.zeros(W.shape[0], dtype=np.float64))
                    mod_name = str(node.target)
                    out_node = node
                src_nodes = only_node_args(node)
                if len(src_nodes) != 1:
                    raise SystemExit("conv %s has %d inputs" % (node.target, len(src_nodes)))
                src_tid = env[src_nodes[0].name]
                oc, icg, k, k2 = W.shape
                if k != k2 or k not in (1, 3, 5):
                    raise SystemExit("unsupported kernel %dx%d @ %s" % (k, k2, mod_name))
                groups = int(mod.groups[0]) if isinstance(mod.groups, tuple) else int(mod.groups)
                depthwise = groups > 1 and icg == 1 and oc == groups
                if groups > 1 and not depthwise:
                    raise SystemExit("non-depthwise grouped conv unsupported @ %s" % mod_name)
                ic = icg * groups
                if not isinstance(mod.stride, tuple):
                    stride = int(mod.stride)
                else:
                    assert mod.stride[0] == mod.stride[1]
                    stride = int(mod.stride[0])
                pad = int(mod.padding[0]) if isinstance(mod.padding, tuple) else int(mod.padding)
                if pad != k // 2:
                    raise SystemExit("pad %d != k//2 @ %s" % (pad, mod_name))
                ih, iw = tensors[src_tid]["h"], tensors[src_tid]["w"]
                _, _, oh, ow = out_shape(out_node.name)
                if (oh, ow) != ((ih + 2 * pad - k) // stride + 1,
                                (iw + 2 * pad - k) // stride + 1):
                    raise SystemExit("shape formula mismatch @ %s" % mod_name)
                domain = DOM_RELU if has_relu_consumer(out_node) else DOM_LINEAR
                dst_tid = add_tensor(mod_name, oh, ow, oc, domain, role="conv")
                ic_pad, oc_pad = ((ic + 7) // 8) * 8, ((oc + 7) // 8) * 8
                op = {
                    "id": len(ops), "kind": "dwconv" if depthwise else "conv",
                    "layer_idx": len(folded), "module": mod_name,
                    "k": int(k), "stride": stride, "pad": pad, "groups": groups,
                    "depthwise": bool(depthwise),
                    "ic": int(ic), "oc": int(oc),
                    "ic_pad": int(ic_pad), "oc_pad": int(oc_pad),
                    "ih": int(ih), "iw": int(iw), "oh": int(oh), "ow": int(ow),
                    "act": ACT_RELU if domain == DOM_RELU else ACT_NONE,
                    "domain": domain, "leaky": 0, "flags": 0,
                    "src": int(src_tid), "dst": int(dst_tid),
                    "weight_bytes": (k * k * oc_pad) if depthwise else (k * k * ic_pad * oc_pad),
                    "macs_real": int((k * k) * oc * oh * ow) if depthwise
                                 else int((k * k) * ic * oc * oh * ow),
                    "macs_padded": int((k * k) * oc_pad * oh * ow) if depthwise
                                   else int((k * k) * ic_pad * oc_pad * oh * ow),
                }
                if depthwise:
                    op["flags"] |= FLAG_DEPTHWISE
                    assert op["ic"] == op["oc"], "depthwise ic!=oc @ %s" % mod_name
                if src_tid == input_tid:
                    if not (ic <= 8 and k == 3 and not depthwise):
                        raise SystemExit("PACKED3 constraint violated @ %s" % mod_name)
                    op["flags"] |= FLAG_PACKED3
                if op["act"] == ACT_RELU:
                    op["flags"] |= FLAG_RELU
                folded.append({"W": W, "b": b, "name": mod_name})
                finish_op(op)
                env[node.name] = dst_tid
                if bn_node is not None:
                    env[bn_node.name] = dst_tid
                tensors[dst_tid]["producer_op"] = op["id"]
                tensors[dst_tid]["last_writer_op"] = op["id"]
                continue
            if isinstance(mod, nn.BatchNorm2d):
                if node.name not in env:
                    raise SystemExit("unfused BatchNorm @ %s" % node.target)
                continue
            if isinstance(mod, nn.ReLU):
                env[node.name] = env[only_node_args(node)[0].name]
                continue
            raise SystemExit("unsupported module %s @ %s"
                             % (type(mod).__name__, node.target))

        # ---------------- call_function ----------------
        target = node.target
        if target is getattr or target is operator.getitem:
            # 形状访问(x.shape / x.shape[-2:])只为 F.interpolate 提供 size;
            # 目标形状直接取 interp 实际输出 shape, 无需建模。
            continue
        if target is F.relu:
            env[node.name] = env[only_node_args(node)[0].name]
            continue
        if target is operator.add:
            a0, a1 = only_node_args(node)
            t0, t1 = env[a0.name], env[a1.name]
            _, C, H, W = out_shape(node.name)
            post_relu = has_relu_consumer(node)
            d0, d1 = dom(t0), dom(t1)
            if post_relu:
                if d0 == DOM_RELU:
                    dst, src, add_type = t0, t1, "residual_relu"
                elif d1 == DOM_RELU:
                    dst, src, add_type = t1, t0, "residual_relu"
                else:
                    raise SystemExit("relu(add) with no relu-domain operand")
                assert dom(dst) == DOM_RELU
            elif d0 == DOM_LINEAR and d1 == DOM_RELU:
                dst, src, add_type = t0, t1, "linear"
            elif d0 == DOM_RELU and d1 == DOM_LINEAR:
                dst, src, add_type = t1, t0, "linear"
            elif d0 == DOM_RELU and d1 == DOM_RELU:
                dst, src, add_type = t0, t1, "fpn_sum"
            else:
                dst, src, add_type = t0, t1, "linear"
            t = tensors[dst]
            if (t["h"], t["w"], t["c"]) != (H, W, C):
                raise SystemExit("add dst shape mismatch @ %s" % node.name)
            if (tensors[src]["h"], tensors[src]["w"], tensors[src]["c"]) != (H, W, C):
                raise SystemExit("add src shape mismatch @ %s" % node.name)
            act = DOM_RELU if dom(dst) == DOM_RELU else DOM_LINEAR
            op = {
                "id": len(ops), "kind": "add", "layer_idx": -1, "module": str(node.name),
                "k": 0, "stride": 1, "pad": 0, "groups": 1, "depthwise": False,
                "ic": int(C), "oc": int(C),
                "ic_pad": ((C + 7) // 8) * 8, "oc_pad": ((C + 7) // 8) * 8,
                "ih": int(H), "iw": int(W), "oh": int(H), "ow": int(W),
                "act": ACT_RELU if act == DOM_RELU else ACT_NONE,
                "domain": act, "leaky": 0,
                "flags": FLAG_ADD_R | (FLAG_RELU if act == DOM_RELU else 0),
                "src": int(src), "dst": int(dst), "add_type": add_type,
                "post_relu": bool(post_relu),
                "weight_bytes": 0, "macs_real": 0, "macs_padded": 0,
            }
            finish_op(op)
            env[node.name] = dst
            t["last_writer_op"] = op["id"]
            continue
        if target is F.interpolate:
            src_nodes = only_node_args(node)
            if len(src_nodes) != 1:
                raise SystemExit("interpolate with %d tensor args" % len(src_nodes))
            src_tid = env[src_nodes[0].name]
            _, C, H, W = out_shape(node.name)
            ih, iw = tensors[src_tid]["h"], tensors[src_tid]["w"]
            if H % ih or W % iw or H // ih != W // iw:
                raise SystemExit("non-integer upsample %dx%d -> %dx%d" % (ih, iw, H, W))
            ratio = H // ih
            if ratio not in (2, 4):
                raise SystemExit("only 2x/4x nearest upsample supported (got %dx)" % ratio)
            mode = node.kwargs.get("mode", "nearest")
            if mode != "nearest":
                raise SystemExit("only nearest upsample supported (got %r)" % mode)
            # 4x 最近邻 == 两次 2x 最近邻(2 的幂); 引擎只有 2x, 展开成链。
            # CSE: 同源同倍率的上采样链只算一次(纯数据搬运, 语义不变)。
            cache_key = (int(src_tid), int(ratio))
            if cache_key in upsample_cache:
                env[node.name] = upsample_cache[cache_key]
                continue
            cur = src_tid
            for step in range(1, int(np.log2(ratio)) + 1):
                th, tw = tensors[cur]["h"] * 2, tensors[cur]["w"] * 2
                domain = dom(cur)
                dtid = add_tensor("%s_up%d" % (node.name, step), th, tw, C, domain,
                                  role="upsample")
                op = {
                    "id": len(ops), "kind": "upsample", "layer_idx": -1,
                    "module": "%s(up2x#%d)" % (node.name, step),
                    "k": 2, "stride": 2, "pad": 0, "groups": 1, "depthwise": False,
                    "ic": int(C), "oc": int(C),
                    "ic_pad": ((C + 7) // 8) * 8, "oc_pad": ((C + 7) // 8) * 8,
                    "ih": int(tensors[cur]["h"]), "iw": int(tensors[cur]["w"]),
                    "oh": int(th), "ow": int(tw),
                    "act": ACT_NONE, "domain": DOM_LINEAR, "leaky": 0, "flags": 0,
                    "src": int(cur), "dst": int(dtid),
                    "weight_bytes": 0, "macs_real": 0, "macs_padded": 0,
                }
                finish_op(op)
                tensors[dtid]["producer_op"] = op["id"]
                tensors[dtid]["last_writer_op"] = op["id"]
                cur = dtid
            upsample_cache[cache_key] = cur
            env[node.name] = cur
            continue
        if target is torch.cat:
            nodes_in = [a for a in node.args[0] if isinstance(a, fx.Node)]
            dim = node.kwargs.get("dim", node.args[1] if len(node.args) > 1 else 0)
            if int(dim) not in (1, -3):
                raise SystemExit("concat only supports channel dim, got %r" % (dim,))
            src_tids = [env[a.name] for a in nodes_in]
            _, C, H, W = out_shape(node.name)
            domains = {dom(t) for t in src_tids}
            if len(domains) != 1:
                raise SystemExit("concat inputs must share quant domain (exact copy): %s"
                                 % domains)
            domain = domains.pop()
            dst_tid = add_tensor(node.name, H, W, C, domain, role="concat")
            coff = 0
            for st in src_tids:
                ci = tensors[st]["c"]
                op = {
                    "id": len(ops), "kind": "copy", "layer_idx": -1,
                    "module": str(node.name), "k": 0, "stride": 1, "pad": 0,
                    "groups": 1, "depthwise": False,
                    "ic": int(ci), "oc": int(C),
                    "ic_pad": ((ci + 7) // 8) * 8, "oc_pad": ((C + 7) // 8) * 8,
                    "ih": int(H), "iw": int(W), "oh": int(H), "ow": int(W),
                    "act": ACT_NONE, "domain": DOM_LINEAR, "leaky": 0, "flags": 0,
                    "src": int(st), "dst": int(dst_tid),
                    "c_src": 0, "c_dst": int(coff),
                    "weight_bytes": 0, "macs_real": 0, "macs_padded": 0,
                }
                if coff % 8:
                    raise SystemExit("concat channel offset %d not 8-aligned" % coff)
                finish_op(op)
                coff += ci
            if coff != C:
                raise SystemExit("concat channels %d != %d" % (coff, C))
            env[node.name] = dst_tid
            tensors[dst_tid]["producer_op"] = ops[-len(src_tids)]["id"]
            tensors[dst_tid]["last_writer_op"] = ops[-1]["id"]
            continue
        raise SystemExit("unsupported call_function %r" % (target,))

    # ---------------- final tensors ----------------
    out_node = nodes[-1]
    assert out_node.op == "output"
    final_tids = [env[n.name] for n in out_node.args[0]]
    if len(final_tids) != 3:
        raise SystemExit("expected 3 head tensors, got %d" % len(final_tids))
    for tid, role in zip(final_tids, ("objectness", "class", "box")):
        tensors[tid]["final"] = True
        tensors[tid]["role"] = "head"
        tensors[tid]["name"] = "%s_logits(%s)" % (role, tensors[tid]["name"])

    if verbose:
        print("[graph] ops=%d kinds=%s tensors=%d"
              % (len(ops), dict(Counter(o["kind"] for o in ops)), len(tensors)))
    return tensors, ops, folded, final_tids, {
        "example_input": example, "interp": interp, "out_tuple": out_tuple, "graph": g}


# ----------------------------------------------------------------------------
# 浮点参考前向(基于线性 op 序列 + BN 已折叠权重) —— quant_npu/golden_npu 复用
# ----------------------------------------------------------------------------
def float_forward(ops, tensors, folded, x_nhwc):
    """按 op 序列做 float 前向(numpy, 慢但直观; 调试/交叉验证用)。

    x_nhwc: (H,W,3) float; 返回 (store, op_out): store[tid]=(H,W,C8) float64;
    op_out[op_id]=该 op 执行当时的输出(真实通道, NHWC; copy 为写入的通道切片)。
    """
    store, op_out = {}, {}
    it = next(t for t in tensors if t["role"] == "input")["tid"]
    store[it] = np.asarray(x_nhwc, dtype=np.float64)
    for op in ops:
        kind = op["kind"]
        dst_t = tensors[op["dst"]]
        if kind in ("conv", "dwconv"):
            p = folded[op["layer_idx"]]
            W, b = p["W"], p["b"]
            x = store[op["src"]]
            k, s, pad = op["k"], op["stride"], op["pad"]
            ic, oc, ic_pad = op["ic"], op["oc"], op["ic_pad"]
            H, Wd = x.shape[0], x.shape[1]
            xp = np.zeros((H + 2 * pad, Wd + 2 * pad, ic_pad), dtype=np.float64)
            xp[pad:pad + H, pad:pad + Wd, :ic] = x
            oh, ow = op["oh"], op["ow"]
            if op["depthwise"]:
                acc = np.zeros((oh, ow, oc), dtype=np.float64)
                for tap in range(k * k):
                    ky, kx = divmod(tap, k)
                    patch = xp[ky:ky + (oh - 1) * s + 1:s,
                               kx:kx + (ow - 1) * s + 1:s, :oc]
                    acc += patch * W[:, 0, ky, kx][None, None, :]
            else:
                icg = W.shape[1]
                acc_f = np.zeros((oh * ow, oc), dtype=np.float64)
                for tap in range(k * k):
                    ky, kx = divmod(tap, k)
                    patch = xp[ky:ky + (oh - 1) * s + 1:s,
                               kx:kx + (ow - 1) * s + 1:s, :icg]
                    acc_f += patch.reshape(oh * ow, icg) @ W[:, :, ky, kx].T
                acc = acc_f.reshape(oh, ow, oc)
            acc += b[None, None, :]
            out = np.zeros((oh, ow, dst_t["c"]), dtype=np.float64)
            out[:, :, :oc] = np.maximum(acc, 0.0) if op["act"] == ACT_RELU else acc
        elif kind == "upsample":
            out = np.repeat(np.repeat(store[op["src"]], 2, axis=0), 2, axis=1)
        elif kind == "add":
            c = op["ic"]
            cur = store[op["dst"]]
            out = cur.copy()
            out[:, :, :c] = cur[:, :, :c] + store[op["src"]][:, :, :c]
            if op["act"] == ACT_RELU:
                out = np.maximum(out, 0.0)
        elif kind == "copy":
            cs, cd, c = int(op.get("c_src", 0)), int(op.get("c_dst", 0)), op["ic"]
            out = (store[op["dst"]].copy() if op["dst"] in store
                   else np.zeros((dst_t["h"], dst_t["w"], dst_t["c8"])))
            out[:, :, cd:cd + c] = store[op["src"]][:, :, cs:cs + c]
        else:
            raise SystemExit("unknown kind %r" % kind)
        store[op["dst"]] = out
        if kind == "copy":
            cd, c = int(op.get("c_dst", 0)), op["ic"]
            op_out[op["id"]] = out[:, :, cd:cd + c]
        else:
            op_out[op["id"]] = out[:, :, :dst_t["c"]]
    return store, op_out


def float_forward_torch(ops, tensors, folded, x_nhwc):
    """float_forward 的 torch 版本(快, 给校准/500 张用)。

    返回 (t_store, op_out): t_store[tid]=(1,C,H,W) torch; op_out[op_id]=执行当时
    的输出(真实通道, NHWC numpy) —— 残差 add 是原地写, 必须当时取快照。
    """
    t_store, op_out = {}, {}
    x = torch.from_numpy(np.ascontiguousarray(x_nhwc, dtype=np.float32))
    it = next(t for t in tensors if t["role"] == "input")["tid"]
    t_store[it] = x.permute(2, 0, 1).unsqueeze(0).contiguous()   # (1,C,H,W)
    for op in ops:
        kind = op["kind"]
        if kind in ("conv", "dwconv"):
            p = folded[op["layer_idx"]]
            y = F.conv2d(t_store[op["src"]],
                         torch.from_numpy(p["W"]).float(),
                         torch.from_numpy(p["b"]).float(),
                         stride=op["stride"], padding=op["pad"], groups=op["groups"])
            if op["act"] == ACT_RELU:
                y = torch.relu(y)
        elif kind == "upsample":
            y = F.interpolate(t_store[op["src"]], scale_factor=2, mode="nearest")
        elif kind == "add":
            c = op["ic"]
            cur = t_store[op["dst"]]
            y = cur.clone()
            y[:, :c] = cur[:, :c] + t_store[op["src"]][:, :c]
            if op["act"] == ACT_RELU:
                y = torch.relu(y)
        elif kind == "copy":
            cs, cd, c = int(op.get("c_src", 0)), int(op.get("c_dst", 0)), op["ic"]
            dst_t = tensors[op["dst"]]
            if op["dst"] in t_store:
                y = t_store[op["dst"]].clone()
            else:
                y = torch.zeros((1, dst_t["c8"], dst_t["h"], dst_t["w"]))
            y[:, cd:cd + c] = t_store[op["src"]][:, cs:cs + c]
        else:
            raise SystemExit("unknown kind %r" % kind)
        t_store[op["dst"]] = y
        if kind == "copy":
            cs, cd, c = int(op.get("c_src", 0)), int(op.get("c_dst", 0)), op["ic"]
            op_out[op["id"]] = y[:, cd:cd + c][0].permute(1, 2, 0).numpy()
        else:
            dt = tensors[op["dst"]]
            op_out[op["id"]] = y[:, :dt["c"]][0].permute(1, 2, 0).numpy()
    return t_store, op_out


# ----------------------------------------------------------------------------
# 图像预处理(与 nut_detector.multi_dataset.preprocess_multi 同口径, 尺寸参数化)
# ----------------------------------------------------------------------------
def preprocess_image(img, target_size=224):
    """PIL RGB -> NHWC float32 [-1,1]: target x round(target*0.75) + 上下 edge pad。

    严格复刻 multi_dataset.preprocess_multi(224x168 + 上下各 28 行, /127.5-1);
    160 输入 => 160x120 + 上下各 20 行。
    """
    from PIL import Image
    fitted_h = round(target_size * 168 / 224)
    resized = img.resize((target_size, fitted_h), Image.Resampling.BILINEAR)
    pixels = np.asarray(resized)
    top = (target_size - fitted_h) // 2
    bottom = target_size - fitted_h - top
    pixels = np.pad(pixels, ((top, bottom), (0, 0), (0, 0)), mode="edge").copy()
    return (pixels.astype(np.float32) / 127.5 - 1.0)


def preprocess_boxes(boxes_px, image_size, target_size=224):
    """(N,4) 原图像素框 -> 归一化 letterbox 坐标(/ (target-1)); 与 preprocess_multi 一致。"""
    fitted_h = round(target_size * 168 / 224)
    top = (target_size - fitted_h) // 2
    w, h = image_size
    b = np.asarray(boxes_px, dtype=np.float32).copy()
    b[:, [0, 2]] *= target_size / w
    b[:, [1, 3]] = b[:, [1, 3]] * fitted_h / h + top
    b /= np.array([target_size - 1] * 4, dtype=np.float32)
    return np.clip(b, 0.0, 1.0)


# ----------------------------------------------------------------------------
# 汇总 / 交叉校验
# ----------------------------------------------------------------------------
def summarize(tensors, ops):
    kinds = Counter(o["kind"] for o in ops)
    w_bytes = sum(o["weight_bytes"] for o in ops)
    q_bytes = sum(o.get("qlen", 0) for o in ops)
    macs_real = sum(o["macs_real"] for o in ops)
    max_tensor = max(tensors, key=lambda t: t["bytes"])
    return {
        "ops": len(ops),
        "kinds": {k: int(v) for k, v in sorted(kinds.items())},
        "conv_ops": int(kinds.get("conv", 0) + kinds.get("dwconv", 0)),
        "n_tensors": len(tensors),
        "weight_bytes": int(w_bytes),
        "weight_MB": round(w_bytes / 1e6, 4),
        "q_bytes": int(q_bytes),
        "macs_real": int(macs_real),
        "macs_real_G": round(macs_real / 1e9, 4),
        "unique_tensor_bytes": int(sum(t["bytes"] for t in tensors)),
        "max_tensor": {"tid": int(max_tensor["tid"]), "name": max_tensor["name"],
                       "h": max_tensor["h"], "w": max_tensor["w"],
                       "c": max_tensor["c"], "c8": max_tensor["c8"],
                       "bytes": int(max_tensor["bytes"])},
    }


def check_float_equivalence(ops, tensors, folded, x_nhwc, out_tuple):
    """线性 op 图 + 折叠权重 的 float 前向 vs torch 原模型: 三个 head 最大绝对差。"""
    store, _ = float_forward_torch(ops, tensors, folded, x_nhwc)
    final = [t["tid"] for t in tensors if t["final"]]
    diffs = []
    for tid, ref in zip(final, out_tuple):
        got = store[tid]
        r = ref.detach().numpy() if isinstance(ref, torch.Tensor) else np.asarray(ref)
        d = np.abs(r.astype(np.float64) - got.numpy().astype(np.float64))
        diffs.append({"max_abs": float(d.max()),
                      "mean_abs": float(d.mean()),
                      "ref_absmax": float(np.abs(r).max())})
    return diffs


def profile_cross_check(profile_path, summary, params):
    """与 model-profile 队友的画像交叉校验(只读; 不一致只报告)。"""
    if not profile_path or not os.path.exists(profile_path):
        return {"path": profile_path, "status": "NOT_PRESENT"}
    try:
        prof = json.load(open(profile_path, encoding="utf-8"))
        ps = prof.get("summary", {})
        ours = {
            "npu_ops_total": summary["ops"],
            "conv_layers": summary["kinds"].get("conv", 0) + summary["kinds"].get("dwconv", 0),
            "dwconv": summary["kinds"].get("dwconv", 0),
            "add_ops": summary["kinds"].get("add", 0),
            "weights_int8_bytes_npu_packed": summary["weight_bytes"],
            "total_macs": summary["macs_real"],
            "params_total": int(params),
            "peak_activation_bytes": summary["max_tensor"]["bytes"],
        }
        pairs = [
            ("npu_ops_total", "npu_ops_total_after_cse"),
            ("conv_layers", "conv_layers"),
            ("dwconv", "dwconv_layers"),
            ("add_ops", "add_ops"),
            ("weights_int8_bytes_npu_packed", "weights_int8_bytes_npu_packed"),
            ("total_macs", "total_macs"),
            ("params_total", "params_total"),
            ("peak_activation_bytes", "peak_activation_bytes"),
        ]
        mismatch = []
        for mine, theirs in pairs:
            if theirs in ps and int(ps[theirs]) != int(ours[mine]):
                mismatch.append({"field": theirs, "profile": int(ps[theirs]),
                                 "ours": int(ours[mine])})
        return {"path": os.path.relpath(profile_path, ROOT).replace("\\", "/"),
                "compared": {k: ours[k] for k in ours}, "mismatch": mismatch,
                "status": "PASS" if not mismatch else "MISMATCH"}
    except Exception as e:  # pragma: no cover
        return {"path": profile_path, "status": "ERROR", "error": str(e)}


def main():
    ap = argparse.ArgumentParser(description="PyTorch -> NPU linear op graph")
    ap.add_argument("--checkpoint", default=DEFAULT_CKPT)
    ap.add_argument("--arch", default=None, choices=[None, "enhanced", "slim"])
    ap.add_argument("--input-size", type=int, default=224)
    ap.add_argument("--out", default=os.path.join(DEFAULT_OUTDIR, "graph.json"))
    ap.add_argument("--seed", type=int, default=12345)
    ap.add_argument("--profile", default=os.path.join(ROOT, "results", "bottlecap",
                                                      "model", "model_profile.json"))
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    model, ck, arch = build_model(args.checkpoint, args.arch)
    params = int(sum(p.numel() for p in model.parameters()))
    tensors, ops, folded, final_tids, run = linearize(
        model, args.input_size, seed=args.seed, verbose=not args.quiet)

    x_check = run["example_input"][0].permute(1, 2, 0).numpy()
    fcheck = check_float_equivalence(ops, tensors, folded, x_check, run["out_tuple"])
    summ = summarize(tensors, ops)
    fitted_h = round(args.input_size * 168 / 224)
    meta = {
        "format": "bottlecap-npu-graph-v1",
        "source": {
            "checkpoint": os.path.relpath(os.path.abspath(args.checkpoint), ROOT)
                          .replace("\\", "/"),
            "arch": arch,
            "model_variant": _cfg_get(ck, "model_variant"),
            "input_size": int(args.input_size),
            "parameter_count": params,
            "checkpoint_epoch": ck.get("epoch"),
            "class_names": list(ck.get("class_names") or []),
            "fpn_channels": _cfg_get(ck, "fpn_channels"),
            "width_multiplier_or_backbone_width":
                _cfg_get(ck, "width_multiplier", _cfg_get(ck, "backbone_width")),
            "preprocess": {"target_size": int(args.input_size),
                           "fitted_height": fitted_h,
                           "edge_pad_rows": int((args.input_size - fitted_h) // 2),
                           "normalize": "/127.5 - 1"},
        },
        "input": {"tid": next(t["tid"] for t in tensors if t["role"] == "input"),
                  "h": int(args.input_size), "w": int(args.input_size), "c": 3,
                  "packed": True, "domain": DOM_LINEAR},
        "final_tensors": [int(t) for t in final_tids],
        "final_ops": [int(tensors[t]["producer_op"]) for t in final_tids],
        "summary": summ,
        "float_check": fcheck,
        "profile_cross_check": profile_cross_check(args.profile, summ, params),
        "tensors": tensors,
        "ops": ops,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)

    if not args.quiet:
        print("[graph] params=%d (%s) input=%dx%d"
              % (params, arch, args.input_size, args.input_size))
        print("[graph] ops=%d %s" % (summ["ops"], summ["kinds"]))
        print("[graph] conv_ops=%d weight_bytes=%d (%.3f MB) q_bytes=%d MACs=%.3f G"
              % (summ["conv_ops"], summ["weight_bytes"], summ["weight_MB"],
                 summ["q_bytes"], summ["macs_real_G"]))
        print("[graph] tensors=%d unique=%.3f MB max_tensor=%s (%d B)"
              % (summ["n_tensors"], summ["unique_tensor_bytes"] / 1e6,
                 summ["max_tensor"]["name"], summ["max_tensor"]["bytes"]))
        print("[graph] float_check head max|diff| = %s"
              % ["%.3g" % d["max_abs"] for d in fcheck])
        print("[graph] profile_cross_check: %s"
              % meta["profile_cross_check"].get("status"))
        print("[graph] wrote %s" % args.out)


if __name__ == "__main__":
    main()
