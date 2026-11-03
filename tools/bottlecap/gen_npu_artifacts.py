#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_npu_artifacts.py — graph+quant -> NPU 计划/镜像/ROM 表/checksums。

语义来源: results/ai-accel/CONTRACT.md §5/§6/§7/§8/§10/§12 + tools/yolo/make_vectors.py
(+ tools/yolo/gen_rom_table.py) 的产物格式。本脚本把 quant_npu 的确定性量化结果落成:

  results/bottlecap/plan/plan.json         执行计划(每个 op 的 src/dst/woff/qoff/wlen/qlen/
                                           act/flags/csum + 双地址口径 + arena/流量统计)
  results/bottlecap/plan/model.json        层表(model side, op 编码用 ROM kind 0..5)
  results/bottlecap/plan/nn_rom_table.json 微码 ROM 数据源(格式对齐 sim/prog/yolo)
  results/bottlecap/plan/w.hex             W 区 int8 权重镜像(32-bit 小端字/行)
  results/bottlecap/plan/q.hex             Q 区量化参数镜像(32-bit 小端字/行)
  results/bottlecap/plan/checksums.txt     FNV-1a 逐 op 输出 + 输入 + sha256

地址口径(Lead 2026-11-03 v0.8):
  * src/dst : A/B 窗口相对字节偏移(本模型超出 96KB/32KB, 这里按"虚拟无限 A 窗口 + 顺序
    bump 分配"给出顺序地址, 只用于表达 op 间数据依赖, 不是可部署的物理布局);
  * woff    : W 区扁平字节偏移(逐层 16B 对齐累加);
  * qoff    : Q 区扁平字节偏移(逐层 8B 对齐累加);
  * 额外给 arena 口径(供 DDR3 主线): tensors[].arena_off(唯一张量打包 arena 内 16B 对齐
    偏移) + ops[].src_arena_off/dst_arena_off(= arena_base + 偏移, 含 copy 通道偏移),
    arena_base = 0x0100_0000 (P3-320-ARENA 口径)。

用法:
    python tools/bottlecap/gen_npu_artifacts.py                     # 224 原模型
    python tools/bottlecap/gen_npu_artifacts.py --arch slim --input-size 160 \\
        --checkpoint results/bottlecap/slim/best_model.pt --outdir results/bottlecap/plan_slim
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools", "yolo"))

import extract_graph as eg        # noqa: E402
import quant_npu as qn            # noqa: E402
import quant_lib as ql            # noqa: E402
import vec_io as vio              # noqa: E402

ALIGN = 16
ARENA_BASE = 0x01000000          # DDR3 arena base (P3-320-ARENA.md)
NN_A_OFF = 0x00060000            # CONTRACT §3 A 区窗口偏移
W_ALIGN = 16
Q_ALIGN = 8
ROM_DEPTH = 128
# CONTRACT v0.7 片上容量
A_BYTES = 96 * 1024
B_BYTES = 32 * 1024
W_BYTES = 320 * 1024
Q_BYTES = 48 * 1024
NN_B_OFF = 0x00078000            # CONTRACT §3 B 区窗口偏移
# P3-DDR3-TILECACHE §4.2 方案 1: IBUF 2x16KB / OBUF 2x12KB (单 bank 预算, 见 §4.3 自适应规则)
IBUF_BYTES = 16384
IBUF_BYTES_WIDE = 32768          # 瓶盖配置: 17 个 dwconv 大通道层用 2x32KB IBUF
OBUF_BYTES = 12288
KIND_CODE = {"conv": 0, "dwconv": 1, "pool": 2, "upsample": 3, "add": 4, "copy": 5}
FLAG_DEPTHWISE, FLAG_LEAKY, FLAG_PACKED3, FLAG_ADD_R = 1, 2, 4, 8
FLAG_RELU = 16


def align_up(x, a):
    return (int(x) + a - 1) // a * a


def fnv1a_int8(arr):
    return vio.fnv1a_int8(np.asarray(arr, dtype=np.int8))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


# ----------------------------------------------------------------------------
# 虚拟地址分配
# ----------------------------------------------------------------------------
def allocate_sequential(tensors):
    """按张量出现顺序 bump 分配(虚拟无限 A 窗口, 16B 对齐)。src/dst 口径。"""
    off = 0
    for t in tensors:
        t["win_off"] = off
        t["win_buf"] = "A"
        off = align_up(off + t["bytes"], ALIGN)
    return off


def tensor_live_intervals(tensors, ops):
    """[def_op, last_use] 生命周期(含被读的最后一次), 用于 arena 打包/峰值统计。"""
    last = {}
    for op in ops:
        for key in ("src", "dst"):
            last[op[key]] = op["id"]
    for t in tensors:
        tid = t["tid"]
        if t["role"] == "input":
            t["def_op"], t["last_use"] = -1, last.get(tid, 0)
        else:
            t["def_op"] = int(t["producer_op"])
            t["last_use"] = int(last.get(tid, t["producer_op"]))
    return tensors


def _overlap(a, b):
    return not (a[1] < b[0] or b[1] < a[0])


def pack_arena(tensors, num_ops):
    """静态生命周期打包(按大小降序放到最低的不冲突 16B 偏移), 零碎片。"""
    placed = []                 # (off, size, interval, tid)
    off_of = {}
    high = 0
    for t in sorted(tensors, key=lambda x: (-x["bytes"], x["def_op"])):
        iv = (t["def_op"], t["last_use"] if t["last_use"] >= 0 else num_ops - 1)
        size = align_up(t["bytes"], ALIGN)
        cands = {0}
        for po, ps, piv, _ in placed:
            cands.add(align_up(po + ps, ALIGN))
        for o in sorted(cands):
            if all(o + size <= po or po + ps <= o or not _overlap(iv, piv)
                   for po, ps, piv, _ in placed):
                off_of[t["tid"]] = o
                placed.append((o, size, iv, t["tid"]))
                high = max(high, o + size)
                break
        else:  # pragma: no cover
            raise SystemExit("arena pack failed for tensor %d" % t["tid"])
    peak = 0
    for op_id in range(num_ops + 1):
        live = sum(align_up(t["bytes"], ALIGN) for t in tensors
                   if t["def_op"] <= op_id <= t["last_use"])
        peak = max(peak, live)
    return off_of, peak, high


# ----------------------------------------------------------------------------
# 镜像 (W / Q)
# ----------------------------------------------------------------------------
def build_w_image(plan, q, verbose=True):
    w_off_of = {}
    off = 0
    chunks = []
    for op in plan["ops"]:
        if op["kind"] not in ("conv", "dwconv"):
            op["woff"] = -1
            continue
        p = q["ops"][op["id"]]
        wb = np.ascontiguousarray(p["wq"], dtype=np.int8)
        if wb.nbytes != op["wlen"]:
            raise SystemExit("op %d wlen mismatch %d vs %d"
                             % (op["id"], wb.nbytes, op["wlen"]))
        off = align_up(off, W_ALIGN)
        w_off_of[op["id"]] = off
        op["woff"] = off
        chunks.append((off, wb))
        off += wb.nbytes
    total = off
    img = np.zeros(align_up(total, 4), dtype=np.uint8)
    for o, wb in chunks:
        img[o:o + wb.nbytes] = wb.view(np.uint8).ravel()
    return img, w_off_of, total


def build_q_image(plan, q, verbose=True):
    off = 0
    chunks = []
    q_off_of = {}
    for op in plan["ops"]:
        op["qoff"] = -1
        if op["kind"] in ("conv", "dwconv"):
            payload = np.ascontiguousarray(q["ops"][op["id"]]["payload"], dtype=np.uint8)
            if payload.size != op["qlen"]:
                raise SystemExit("op %d qlen mismatch %d vs %d"
                                 % (op["id"], payload.size, op["qlen"]))
        elif op["kind"] == "add":
            payload = np.ascontiguousarray(q["adds"][op["id"]]["payload"], dtype=np.uint8)
            if payload.size != 16:
                raise SystemExit("add op %d payload != 16B" % op["id"])
        else:
            continue
        off = align_up(off, Q_ALIGN)
        op["qoff"] = off
        q_off_of[op["id"]] = off
        chunks.append((off, payload))
        off += payload.size
    total = off
    img = np.zeros(align_up(total, 4), dtype=np.uint8)
    for o, payload in chunks:
        img[o:o + payload.size] = payload
    return img, total, q_off_of


# ----------------------------------------------------------------------------
# 流量 / 尺寸统计
# ----------------------------------------------------------------------------
def op_traffic(op, tensors):
    st, dt = tensors[op["src"]], tensors[op["dst"]]
    if op["kind"] in ("conv", "dwconv"):
        rd = st["h"] * st["w"] * st["c8"]
        wr = dt["h"] * dt["w"] * dt["c8"]
        if op.get("fused_add"):
            rd += dt["h"] * dt["w"] * dt["c8"]    # 融合: S_ADRD 读 dst(残差)
    elif op["kind"] == "upsample":
        rd = st["h"] * st["w"] * st["c8"]
        wr = dt["h"] * dt["w"] * dt["c8"]
    elif op["kind"] == "add":
        rd = 2 * st["h"] * st["w"] * st["c8"]       # 读 src + 读 dst(RMW)
        wr = dt["h"] * dt["w"] * dt["c8"]
    elif op["kind"] == "copy":
        rd = st["h"] * st["w"] * op["ic"]
        wr = dt["h"] * dt["w"] * op["ic"]
    else:
        rd = wr = 0
    return int(rd), int(wr)


def bits_for(n):
    return max(1, int(n - 1).bit_length()) if n > 0 else 1


def write_final_json(path, args, summary, plan_json, files, extra):
    """FINAL.json: 记录最终 checkpoint sha256 + 各产物 sha256 + 生成命令。"""
    import datetime
    meta = {
        "format": "bottlecap-plan-final-v1",
        "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "model": plan_json.get("source", {}),
        "checkpoint_sha256": sha256_file(os.path.abspath(args.checkpoint)),
        "label": args.label,
        "contract": "results/ai-accel/CONTRACT.md (v0.7 + v0.8 flags/RELU)",
        "counts": {
            "ops": summary["num_ops"], "w_bytes": summary["w_bytes"],
            "q_bytes": summary["q_bytes"],
            "max_single_tensor_bytes": summary["max_single_tensor_bytes"],
            "ab_mode": summary.get("ab_mode"),
            "peak_A": summary.get("alloc", {}).get("peak_A"),
            "peak_B": summary.get("alloc", {}).get("peak_B"),
            "total_bands": summary.get("tile_plan_stats", {}).get("total_bands"),
            "rom_depth": summary["rom"]["depth"],
        },
        "commands": {
            "extract_graph": "python tools/bottlecap/extract_graph.py --arch %s"
                             " --checkpoint %s --input-size %d --profile none --out %s"
                             % (args.arch or "auto", args.checkpoint, args.input_size,
                                os.path.join(args.outdir, "graph.json")),
            "quant_npu": "python tools/bottlecap/quant_npu.py --arch %s --checkpoint %s"
                         " --input-size %d --graph %s --out %s"
                         % (args.arch or "auto", args.checkpoint, args.input_size,
                            os.path.join(args.outdir, "graph.json"),
                            os.path.join(args.outdir, "quant_report.json")),
            "gen_npu_artifacts": "python tools/bottlecap/gen_npu_artifacts.py --arch %s"
                                 " --checkpoint %s --input-size %d --graph %s --outdir %s"
                                 " --ab-mode real --deploy-check %s --emit-deploy-bundle"
                                 " --emit-wq-merged --label %s --final-json %s"
                                 " --handoff-md %s"
                                 % (args.arch or "auto", args.checkpoint,
                                    args.input_size,
                                    os.path.join(args.outdir, "graph.json"),
                                    args.outdir,
                                    os.path.join(args.outdir, "DEPLOY-CHECK.json"),
                                    args.label,
                                    os.path.join(args.outdir, "FINAL.json"),
                                    os.path.join(args.outdir, "E2E-HANDOFF.md")),
            "golden_npu": "python tools/bottlecap/golden_npu.py --arch %s --checkpoint %s"
                          " --input-size %d --outdir %s --graph %s --export-opvec %s"
                          " --report %s"
                          % (args.arch or "auto", args.checkpoint, args.input_size,
                             args.outdir, os.path.join(args.outdir, "graph.json"),
                             os.path.join(args.outdir, "opvec"),
                             os.path.join(args.outdir, "GOLDEN-REPORT-SLIM.md")),
        },
        "files": {os.path.relpath(os.path.abspath(p), os.path.abspath(args.outdir))
                  .replace("\\", "/"):
                  {"bytes": os.path.getsize(p), "sha256": sha256_file(p)}
                  for p in files if p and os.path.exists(p)},
        "extra": extra,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
    return meta


def write_handoff(path, args, plan_json, summary, cyc, hashes, comm):
    """E2E-HANDOFF.md: 给 Lead 的 ModelSim E2E 输入清单(≤1 页)。"""
    s = summary
    ab = s.get("alloc", {})
    tp = s.get("tile_plan_stats", {})
    L = []
    A = L.append
    A("# E2E-HANDOFF — slim 模型 ModelSim 端到端（%d op，96×96，纯片上）" % s["num_ops"])
    A("")
    A("> 模型: `%s` (arch=%s, input=%d, params=%d)  " %
      (plan_json["source"]["checkpoint"], plan_json["source"]["arch"],
       plan_json["source"]["input_size"], plan_json["source"]["params"]))
    A("> checkpoint sha256: `%s`（FINAL.json 里为权威记录）  " % comm["ckpt_sha"])
    A("> 判定：MODE_AUTO 跑完 71 op 后逐 op checksum 对 `checksums.txt`，`hw_bad=0`；"
      "head 值对 `opvec/` 字节金标（如需）。")
    A("")
    A("## ① 运行 E2E 需要的输入文件（全部由 `gen_npu_artifacts.py` 生成）")
    A("")
    A("| 文件 | 说明 |")
    A("|---|---|")
    A("| `slim_plan.h` | tools/nn_gen_sw.py 生成（`--guard SLIM_PLAN_H`），C 侧 op 表；"
      "与 sw/ 一起编进 imem/dmem 镜像 |")
    A("| `nn_rom_pkg_slim.sv` | tools/nn_gen_rom.py 生成的微码 ROM 包，替换/并列 "
      "`nn_rom_pkg.sv`（由 Lead 决定 E2E 构建用哪个，**勿覆盖 YOLO 的包**） |")
    A("| `w.hex` / `q.hex` | W=%d B / Q=%d B，§6/§7 布局（32-bit 小端字/行）。"
      "**nn_mem 装载用分开的 `+nnw`/`+nnq`（自适应行数，slim: W 16,306×64b、"
      "Q 2,848×64b）——已实测正确** |" % (s["w_bytes"], s["q_bytes"]))
    A("| `%s_wq.hex` | W||Q 合并的 32-bit 镜像，%d 行（= (%d+%d)/4）。**仅供 DDR3 镜像/参考**；"
      "`+nnwq` 通道按 YOLO 固定行数拆分，**不适合 slim，勿用于 nn_mem 初始化** |"
      % (args.label, (s["w_bytes"] + s["q_bytes"]) // 4, s["w_bytes"], s["q_bytes"]))
    A("| `checksums.txt` | 输入 + 逐 op FNV-1a（真实通道×H×W，NHWC y,x,c；"
      "opvec/index.json 为逐 op 字节金标） |")
    A("")
    A("**W/Q 合并镜像命令（已由本脚本在 `--emit-wq-merged` 执行，可复现）**：")
    A("```powershell")
    A("# w.hex/q.hex 都是 32-bit little-endian 字/行；逐行拼接即为 W||Q 连续镜像")
    A("Get-Content w.hex, q.hex | Set-Content %s_wq.hex" % args.label)
    A("# 校验行数（必须 = (W+Q)/4 = %d）" % ((s["w_bytes"] + s["q_bytes"]) // 4))
    A("(Get-Content %s_wq.hex).Count" % args.label)
    A("```")
    A("")
    A("## ② 输入图（conv0 PACKED3，96×96×3）—— E2E 用真实图")
    A("")
    A("**首选（真实检测图）**：`opvec/<img>/input.hex`（E2E 用 8 张参考图之一，建议 img=%s）"
      "—— 96×72 letterbox + 上下 12 行 edge pad，`/127.5-1` 后按 plan 的 s_in/zp_in 量化为 "
      "int8 PACKED3，格式 = u32-LE words/行（6,912 行 = 27,648 B）。复制为仿真输入："
      % ("<首个真实图 name>" if False else "0349"))
    A("```powershell")
    A("Copy-Item opvec/0349/input.hex ..\\..\\..\\sim\\prog\\slim\\input_96.hex")
    A("# 或：1 字节/行 compact 版（便于 TB 逐像素比对）")
    A("Copy-Item opvec/0349/input_compact.hex ..\\..\\..\\sim\\prog\\slim\\input_96_compact.hex")
    A("```")
    A("（`input_compact.hex` = 每行 1 字节 2-hex 的 y,x,c 逻辑序 PACKED3，27,648 字节。）")
    A("")
    A("**备选（合成图，仅协议回归）**：`q[y][x][c] = int8((x*13 + y*7 + c*29 + seed) & 0xFF)`，"
      "seed=12345，存 packed 3B/像素(y-major,x,c)，A 区 offset=%d；该图对应 "
      "`checksums.txt`（plan/ROM 的 debug csum 就是它）。**真实检测精度必须用首选真实图**。"
      % plan_json["input"].get("act_off", 0))
    A("")
    A("## ③ 逐 op checksum / 金标位置（判 hw_bad=0）")
    A("")
    A("- **真实图（E2E 判据）**：`opvec/0349/checksums.txt`（71 op 逐 op FNV，"
      "真实通道×H×W、NHWC y,x,c 逻辑序；input FNV 同文件首行）+ "
      "`opvec/0349/op*.hex`（整块 int8 字节，u32-LE，NHWC pad8 含 pad 字节）。")
    A("- `checksums.txt`：pattern_v1 输入的逐 op FNV（ROM debug csum / MODE_AUTO 同源）。")
    A("- `opvec/manifest.json` / `opvec/index.json`：逐 op shape/bytes/fnv/arena_off 索引。")
    A("")
    A("## ④ 期望 npu_cycles（v3 公式，**与 ModelSim 实测逐拍一致**）")
    A("")
    A("- 合计 = **%d 拍**（= `results/ai-accel/proto/engine/calc_cycles_v3.py` 口径逐 op 求和；"
      "MODE_CPU 逐 op CYCLES 之和 = MODE_AUTO CYCLES = 该值，已实测 0 delta）"
      % cyc["total_cycles"])
    A("- 分 kind：%s。" %
      (", ".join("%s=%d" % (k, v) for k, v in cyc["per_kind_cycles"].items())))
    A("- 100MHz ≈ %.2f ms / 122MHz ≈ %.2f ms / 150MHz ≈ %.2f ms（=%.2f/%.2f fbs）。"
      % (cyc["total_ms_at_100MHz"], cyc["total_ms_at_122MHz"],
         cyc["total_ms_at_150MHz"], cyc.get("fps_at_100MHz", 0),
         cyc.get("fps_at_122MHz", 0)))
    A("- band 级启动固定开销（v2 tile，total_bands=%d）≈ %d~%d 拍/帧（相对上述总数 <0.2%%）。" %
      (tp.get("total_bands", 0),
       tp.get("band_launch_overhead", {}).get("total_cycles_50", 0),
       tp.get("band_launch_overhead", {}).get("total_cycles_100", 0)))
    A("")
    A("## ⑤ 与现有 tb_sw_nn_yolo / tb_sw.sv 的差异点")
    A("")
    A("1. plan 只有 **%d op**（YOLO 112）；ROM 深度 %d，`nn_rom_pkg_slim.sv` 与 YOLO 包二选一。"
      % (s["num_ops"], s["rom"]["depth"]))
    A("2. 输入 **96×96 PACKED3**（YOLO 128/320 同口径，但尺寸不同；A 区 offset=0）。")
    A("3. 激活只走 **A/B 两个 bank（real 分配）**：A 峰值 %d/98304 B、B 峰值 %d/32768 B；"
      "src/dst 为 A/B 窗口相对偏移（plan 里另有 arena 绝对口径字段，E2E 不需要）。"
      % (ab.get("peak_A", 0), ab.get("peak_B", 0)))
    A("4. flags v0.8：per-op 显式 `act=\"relu\"/\"none\"` + plan flags bit4（生成器映射到 "
      "nn_pkg bit7 RELU）；ADD_R 11 个、全部 per-tensor R≤65535。")
    A("5. 无 concat/copy op（YOLO 有 6 copy）；upsample 3 个（2x, ic==oc）；pool 0 个。")
    A("6. 与 `tb_sw_nn_yolo` 相同的是 MMIO 描述符逐 op 下发接口（MODE_CPU 回归）与 "
      "MODE_AUTO ROM 自主执行；不同点仅为上述 op/形状/ROM 内容，"
      "故 E2E 构建只需换 sw 头 + ROM 包 + plan 输入尺寸。")
    A("")
    A("## ⑥ 产物 sha256（权威记录见 FINAL.json）")
    A("")
    for k, v in hashes.items():
        A("- `%s`  %s" % (k, v))
    A("")
    A("## ⑦ 给 M6a / npu-spec 的口径确认（照抄即可，勿猜）")
    A("")
    A("**(a) 逐 op FNV 计算口径（与 opvec/0349/checksums.txt 完全一致）**：")
    A("```python")
    A("h = 2166136261")
    A("for byte_in_arr_compact:           # 只遍历「真实通道」的 y,x,c 逻辑序")
    A("    h ^= byte & 0xFF; h = (h * 16777619) & 0xFFFFFFFF")
    A("# 即：arr = op 输出张量 (H,W,C8) int8; for y in range(H): for x in range(W):")
    A("#       for c in range(real_C): fnv ^= arr[y,x,c]   # 不含 c>=real_C 的 pad 字节")
    A("# 输入图 FNV: 对 PACKED3 的 y,x,c(c<3) 逻辑序逐字节(a_q 已量化 int8)")
    A("```")
    A("（和 CONTRACT §10 / checksums.txt 同一口径；`opvec/<img>/checksums.txt` 已按此生成。）")
    A("")
    A("**(b) 输入图 `opvec/0349/input.hex` 加载方式（二选一，均与金标等价）**：")
    A("- 方式1（与 YOLO 相同的 `+pattern` 位置改为文件装载）：把 `input.hex` 按 u32 小端"
      "逐行解析为 27,648 字节，写入 NN 窗口 A 区偏移 `plan.input.act_off`（=0）开始的 "
      "27,648 B；不做任何反量化（这些字节就是 conv0 要读的 a_q）。")
    A("- 方式2（固件按 PACKED3 写）：固件自己从 `input_compact.hex`/原始图量化时，"
      "必须用 plan 的 `input.s_in/zp_in`（不是固定 2/255），按 "
      "`a_q = clip(round(x/s_in)+zp_in, -128,127)` 写 `addr = y*iw*3 + x*3 + c`。")
    A("- conv0 读取：engine PACKED3，`iw=96`，行步长 288 B，pad=1 → 边界行填 `zp_in`。")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")


def apply_add_fusion(B, stage="a", verbose=True):
    """[task-18] 把 add 融进 conv（引擎 v0.9 conv add-mode, M6-FUSION-CONTRACT.md）。

    stage="a": 仅 A 类 residual_relu（bit-exact；retarget host conv.dst := add.dst，
               使引擎读到的 q_d 就是残差；R/KADD/zp_d 用 add 参数，写回级两次饱和）。
    返回 (B2, fusion_map)：B2 只替换 tensors/ops/plan/q（folded/gq/groups/run 保留）。
    """
    ops0, tensors0 = B["ops"], B["tensors"]
    q0 = B["q"]
    tmap = {int(t["tid"]): t for t in tensors0}
    consumers = {}
    for o in ops0:
        consumers.setdefault(int(o["src"]), []).append(int(o["id"]))
    fused, drop_ops, drop_tids = {}, set(), set()
    fusion_map = []
    for o in ops0:
        if o["kind"] != "add":
            continue
        if not (int(o.get("flags", 0)) & FLAG_ADD_R):
            continue
        if stage == "a":
            if o.get("add_type") != "residual_relu" or o.get("act") != "relu":
                continue
        else:
            raise SystemExit("[fuse] unknown stage %r" % stage)
        src, dst = int(o["src"]), int(o["dst"])
        prods = [p for p in ops0 if int(p["dst"]) == src]
        if len(prods) != 1:
            continue
        host = prods[0]
        if host["kind"] != "conv":
            continue
        if int(host.get("flags", 0)) & (FLAG_DEPTHWISE | FLAG_PACKED3):
            continue
        if src == dst or dst == int(host["dst"]):
            continue
        if consumers.get(src) != [int(o["id"])]:
            continue
        # 残差张量必须由更早的 op 产出（引擎 q_d 读 dst 内存原值，写前读）
        if int(tmap[dst].get("def_op", -1)) >= int(host["id"]):
            continue
        a = q0["adds"][o["id"]]
        fused[int(host["id"])] = {"add": o, "r": int(a["r_scale"]),
                                  "k": int(a["k_add"]), "zp_s": int(a["zp_s"]),
                                  "zp_d": int(a["zp_d"])}
        drop_ops.add(int(o["id"]))
        drop_tids.add(src)
        fusion_map.append({
            "add_op": int(o["id"]), "host_conv_op": int(host["id"]),
            "add_type": o.get("add_type"), "module": host.get("module", ""),
            "shape": [int(host["ih"]), int(host["iw"]), int(host["ic"]),
                      int(host["oc"])],
            "src_tid_dropped": src, "residual_tid": dst,
            "r_scale": int(a["r_scale"]), "k_add": int(a["k_add"]),
            "zp_s": int(a["zp_s"]), "zp_d": int(a["zp_d"]),
            "relu": bool(int(o.get("flags", 0)) & FLAG_RELU),
            "op_bytes_saved": int(tmap[src]["bytes"] * 3
                                  + int(tmap[dst]["bytes"] * 0)),
        })
    if not fused:
        raise SystemExit("[fuse] 没有满足条件的 add (stage=%s)" % stage)
    new_ops, new2old = [], {}
    for o in ops0:
        if int(o["id"]) in drop_ops:
            continue
        no = dict(o)
        old_id = int(o["id"])
        if old_id in fused:
            fi = fused[old_id]
            ad = fi["add"]
            relu = bool(int(ad.get("flags", 0)) & FLAG_RELU)
            no["dst"] = int(ad["dst"])
            no["flags"] = (int(o.get("flags", 0)) | FLAG_ADD_R |
                           (FLAG_RELU if relu else 0))
            no["act"] = "none"
            no["fused_add"] = {"r": fi["r"], "k": fi["k"], "zp_s": fi["zp_s"],
                               "zp_d": fi["zp_d"], "relu": relu,
                               "from_add": int(ad["id"]),
                               "add_type": ad.get("add_type")}
            no["module"] = str(o.get("module", "")) + "+fused_add"
        no["id"] = len(new_ops)
        new2old[no["id"]] = old_id
        new_ops.append(no)
    # 保留全部张量(plan["tensors"] 以 tid 为列表下标, 不能删; 死张量标记空生命周期)
    new_tensors = [dict(t) for t in tensors0]
    for t in new_tensors:
        tid = int(t["tid"])
        if tid in drop_tids:
            t["def_op"] = -1
            t["last_use"] = -1
            t["dead"] = True
            continue
        wr = [o["id"] for o in new_ops if int(o["dst"]) == tid]
        rd = [o["id"] for o in new_ops if int(o["src"]) == tid]
        if wr:
            t["def_op"] = wr[0]
            t["last_use"] = max(wr + rd)
            t["producer_op"] = wr[-1]
        else:
            t["last_use"] = max(rd) if rd else -1
        t["name"] = t.get("name", "t%d" % tid)
    qops, adds = {}, {}
    for o in new_ops:
        old = new2old[o["id"]]
        if o["kind"] in ("conv", "dwconv"):
            p = dict(q0["ops"][old])
            if "fused_add" in o:
                payload = np.array(p["payload"], dtype=np.uint8, copy=True)
                tail = 6 * int(o["oc_pad"])
                fa = o["fused_add"]
                payload[tail + 4] = np.uint8(int(fa["zp_d"]) & 0xFF)
                payload[tail + 5] = np.uint8(int(fa["k"]) & 0xFF)
                payload[tail + 6] = np.uint8(int(fa["r"]) & 0xFF)
                payload[tail + 7] = np.uint8((int(fa["r"]) >> 8) & 0xFF)
                p["payload"] = payload
                p["fused"] = {k: fa[k] for k in ("r", "k", "zp_s", "zp_d",
                                                 "relu")}
            qops[o["id"]] = p
        elif o["kind"] == "add":
            adds[o["id"]] = q0["adds"][old]
    plan2 = qn.make_plan(new_tensors, new_ops, B["final_tids"])
    q2 = {"ops": qops, "adds": adds, "groups": q0["groups"], "gq": q0["gq"],
          "stats": q0.get("stats")}
    B2 = dict(B)
    B2.update({"tensors": new_tensors, "ops": new_ops, "plan": plan2, "q": q2,
               "fusion_map": fusion_map, "fuse_stage": stage})
    if verbose:
        print("[fuse] stage=%s: %d add -> conv, op %d -> %d"
              % (stage, len(fused), len(ops0), len(new_ops)))
    return B2, fusion_map


def estimate_engine_cycles(plan_ops):
    """v3 周期公式(npu-spec 的 calc_cycles_v3.py 口径)逐 op 求和。

    BASE=8, W_RD_LAT=2 -> DRN=4, NEXT=2, REQP=6, QPER8=11, QLOAD=2。
    **已在 ModelSim 上逐 case 验证**: slim 71 op 合计 = 799,520 拍(与 E2E 实测
    MODE_CPU=MODE_AUTO 完全一致); YOLO 112 op = 1,191,020 拍(同公式)。
    plan flags 需转成 nn_pkg 位: plan bit0=dw, bit2=PACKED3, bit3=ADD_R ->
    nn bit0 / bit5 / bit6; kind=upsample -> nn bit3 UP2X。
    """
    BASE, W_RD_LAT, NEXT, QPER8, REQP = 8, 2, 2, 11, 6
    DRN = W_RD_LAT + 2

    def ceil8(x):
        return ((int(x) + 7) // 8) * 8

    def q_cycles(act):
        return (act // 2 + act // 4 + 1) + 4

    def req_cyc(act, oc8, dst16):
        if act == 16:
            beats = 8 if (oc8 % 16 == 0 and dst16) else 16
        else:
            beats = 8
        return REQP + beats + 2

    per = {"conv": 0, "dwconv": 0, "add": 0, "upsample": 0, "copy": 0, "pool": 0}
    for o in plan_ops:
        kind = o["kind"]
        if kind not in per:
            continue
        pf = int(o.get("flags", 0))
        f_dw = 1 if (pf & FLAG_DEPTHWISE) else 0
        f_p3 = 1 if (pf & FLAG_PACKED3) else 0
        f_add_r = 1 if (pf & FLAG_ADD_R) else 0
        f_up2x = 1 if kind == "upsample" else 0
        k, st, pad = int(o["k"]), int(o["stride"]), int(o["pad"])
        ih, iw, ic, oc = int(o["ih"]), int(o["iw"]), int(o["ic"]), int(o["oc"])
        ic8, oc8 = ceil8(ic), ceil8(oc)
        ICB, OCB8 = ic8 // 8, oc8 // 8
        dst_abs = (NN_A_OFF if o["dst"]["buf"] == "A" else NN_B_OFF) + \
            int(o["dst"]["off"])
        dst16 = (dst_abs & 0xF) == 0
        if kind in ("conv", "dwconv"):
            oh = (ih + 2 * pad - k) // st + 1
            ow = (iw + 2 * pad - k) // st + 1
        elif kind == "upsample":
            oh, ow = ih * 2, iw * 2
        else:
            oh, ow = ih, iw
        if kind == "conv" and not f_dw:
            NB = oh * ((ow + 7) // 8)
            if k == 1:
                count, wi, sub = 8, 0, ICB
            else:
                count, wi, sub = 7 * st + k, 1, k * ICB
            load = (3 * count + 1) if f_p3 else (count + 1)
            per_cyc = load + wi + 8 * k
            tot = BASE
            n_tiles = (oc8 + 15) // 16
            for t in range(n_tiles):
                act = min(16, oc8 - 16 * t)
                tot += q_cycles(act)
                tot += NB * (1 + sub * per_cyc + DRN
                             + req_cyc(act, oc8, dst16) + NEXT)
            # [task-18] conv+ADD_R 融合: 每输出块(tile) +13 拍 (M6-FUSION-CONTRACT B.4:
            # S_ADRD 读 dst 10 拍 + 写回三级流水延后 3 拍)
            if o.get("fused_add"):
                tot += 13 * NB * n_tiles
            per["conv"] += tot
        elif kind == "dwconv":
            NB = oh * ((ow + 7) // 8)
            count = 7 * st + k
            per_cyc = count + 2 + k
            tot = BASE
            for t in range(OCB8):
                tot += QPER8
                tot += NB * (1 + k * per_cyc + DRN
                             + req_cyc(8, oc8, dst16) + NEXT)
            per["dwconv"] += tot
        elif kind == "pool":
            NB = ICB * oh * ((ow + 7) // 8)
            count = 7 * st + k
            per_cyc = count + 2 + k
            per["pool"] += BASE + NB * (1 + k * per_cyc + 8 + NEXT)
        elif kind in ("upsample", "copy"):
            words = ih * iw * ICB
            per[kind] += BASE + words * (5 if f_up2x else 2)
        elif kind == "add":
            words = ih * iw * ICB
            per["add"] += BASE + (1 if f_add_r else 0) + words * 5
    total = sum(per.values())
    return {
        "note": "v3 周期公式(calc_cycles_v3.py 同源): BASE=8/DRN=4/NEXT=2/REQP=6/"
                "QPER8=11; 已在 ModelSim 对 slim(799,520)与 YOLO(1,191,020) 逐 case 验证",
        "per_kind_cycles": {k: int(v) for k, v in per.items()},
        "total_cycles": int(total),
        "total_cycles_range": [int(total), int(total)],
        "total_ms_at_100MHz": round(total / 1e5, 3),
        "total_ms_at_122MHz": round(total / 1.22e5, 3),
        "total_ms_at_150MHz": round(total / 1.5e5, 3),
        "fps_at_100MHz": round(1e8 / max(1, total), 3),
        "fps_at_122MHz": round(1.22e8 / max(1, total), 3),
    }


def allocate_ab(tensors, ops, a_bytes=A_BYTES, b_bytes=B_BYTES):
    """把张量静态分配到真实 A/B 缓冲(生命周期不重叠才可共用字节, 16B 对齐)。

    贪心: 张量按大小降序, 依次尝试 A/B 两个 bank 的最低可行偏移(候选=0 或已占用块末尾);
    区间 [def_op, last_use] 重叠的张量不得共用字节。
    返回 {"ok", "assign": {tid: (buf, off)}, "peak_A", "peak_B", "fail"}。
    """
    order = sorted(tensors, key=lambda t: (-t["bytes"], t["def_op"], t["tid"]))
    placed = {"A": [], "B": []}      # (off, size, interval, tid)
    assign = {}
    for t in order:
        iv = (t["def_op"], t["last_use"] if t["last_use"] >= 0 else len(ops) - 1)
        size = align_up(t["bytes"], ALIGN)
        best = None
        for buf, cap in (("A", a_bytes), ("B", b_bytes)):
            cands = {0}
            for po, ps, piv, _ in placed[buf]:
                cands.add(align_up(po + ps, ALIGN))
            for o in sorted(cands):
                if o + size > cap:
                    continue
                ok = True
                for po, ps, piv, _ in placed[buf]:
                    byte_overlap = not (o + size <= po or po + ps <= o)
                    if byte_overlap and _overlap(iv, piv):
                        ok = False
                        break
                if ok:
                    cand = (o, 0 if buf == "A" else 1, buf)
                    if best is None or cand < best:
                        best = cand
                    break
        if best is None:
            peak_A = max([po + ps for po, ps, _, _ in placed["A"]] or [0])
            peak_B = max([po + ps for po, ps, _, _ in placed["B"]] or [0])
            return {"ok": False, "assign": assign, "peak_A": peak_A,
                    "peak_B": peak_B,
                    "fail": "tensor %d(%s %dB) 放不进 A(%dB)/B(%dB)"
                            % (t["tid"], t["name"], t["bytes"], a_bytes, b_bytes)}
        o, _, buf = best
        assign[t["tid"]] = (buf, int(o))
        placed[buf].append((int(o), size, iv, t["tid"]))
    peak_A = max([po + ps for po, ps, _, _ in placed["A"]] or [0])
    peak_B = max([po + ps for po, ps, _, _ in placed["B"]] or [0])
    return {"ok": True, "assign": assign, "peak_A": peak_A, "peak_B": peak_B,
            "fail": ""}


def buffer_abs(buf, off):
    return (NN_A_OFF if buf == "A" else NN_B_OFF) + int(off)


def deploy_check(plan_json, plan_ops, tensors, summary):
    """CONTRACT v0.7 部署自检: 逐项 PASS/FAIL(任何 FAIL 都不静默修)。"""
    items = []

    def add(name, ok, actual, limit, evidence=""):
        items.append({"item": name, "pass": bool(ok), "actual": actual,
                      "limit": limit, "evidence": evidence})

    kinds = {o["kind"] for o in plan_ops}
    conv_ops = [o for o in plan_ops if o["kind"] in ("conv", "dwconv")]
    max_ic = max((o["ic"] for o in plan_ops), default=0)
    max_oc = max((o["oc"] for o in plan_ops), default=0)
    add("W 区容量", summary["w_bytes"] <= W_BYTES,
        "%d B" % summary["w_bytes"], "%d B" % W_BYTES)
    add("Q 区容量", summary["q_bytes"] <= Q_BYTES,
        "%d B" % summary["q_bytes"], "%d B" % Q_BYTES)
    add("A 缓冲单张量峰值", summary["max_single_tensor_bytes"] <= A_BYTES,
        "%d B" % summary["max_single_tensor_bytes"], "%d B" % A_BYTES,
        summary["max_single_tensor"])
    ab = summary.get("alloc", {})
    if summary.get("ab_mode") == "real":
        add("A/B 真实分配(A 峰值)", ab.get("peak_A", 0) <= A_BYTES,
            "%d B" % ab.get("peak_A", 0), "%d B" % A_BYTES)
        add("A/B 真实分配(B 峰值)", ab.get("peak_B", 0) <= B_BYTES,
            "%d B" % ab.get("peak_B", 0), "%d B" % B_BYTES)
    else:
        add("A/B 真实分配", False, "虚拟窗口(未分配)", "必须 real",
            "ab_mode=virtual; 该模型需 DDR3 arena")
    add("ROM 深度", len(plan_ops) <= ROM_DEPTH,
        "%d op" % len(plan_ops), "%d op" % ROM_DEPTH)
    add("引擎 IC/OC 上限(≤1023)", max_ic <= 1023 and max_oc <= 1023,
        "max IC=%d OC=%d" % (max_ic, max_oc), "≤1023")
    add("nn_subsys 现状 IC/OC 检查(≤256)", max_ic <= 256 and max_oc <= 256,
        "max IC=%d OC=%d" % (max_ic, max_oc), "≤256",
        "CONTRACT §4 现状; v0.8 引擎支持到 1023, RTL 正在修")
    align_bad = [o["id"] for o in plan_ops
                 if o["ic_pad"] % 8 or o["oc_pad"] % 8]
    add("8 通道对齐(ic_pad/oc_pad)", not align_bad, "%d 个违例" % len(align_bad),
        "0 违例")
    off_bad = [o["id"] for o in plan_ops
               if o["kind"] == "copy" and ((o.get("c_src", 0) % 8) or
                                           (o.get("c_dst", 0) % 8))]
    add("copy 通道偏移 8 对齐", not off_bad, "%d 个违例" % len(off_bad), "0 违例")
    relu_bad = [o["id"] for o in plan_ops
                if (o["act"] == "relu") != bool(o["flags"] & FLAG_RELU)]
    add("act=relu <-> flags bit4(v0.8 RELU)", not relu_bad,
        "%d 个不一致" % len(relu_bad), "0")
    leaky_bad = [o["id"] for o in plan_ops if o.get("leaky", 0)]
    add("leaky 全 0(本模型用 RELU/linear)", not leaky_bad,
        "%d 个 leaky" % len(leaky_bad), "0")
    kind_bad = [o["id"] for o in plan_ops if o["kind"] not in
                ("conv", "dwconv", "pool", "upsample", "add", "copy")]
    add("op kind 全为硬件 op(无 cpu_*)", not kind_bad, "%d 个违例" % len(kind_bad), "0")
    conv_bad = []
    for o in plan_ops:
        if o["kind"] not in ("conv", "dwconv"):
            continue
        if o["k"] not in (1, 3, 5) or o["stride"] not in (1, 2) or o["pad"] > 2:
            conv_bad.append(o["id"])
        if o["pad"] != o["k"] // 2:
            conv_bad.append(o["id"])
        if o["kind"] == "dwconv" and o["ic"] != o["oc"]:
            conv_bad.append(o["id"])
    add("conv 参数域(k∈{1,3,5},st∈{1,2},pad=k//2,dw ic==oc)", not conv_bad,
        "%d 个违例" % len(set(conv_bad)), "0")
    up_bad = [o["id"] for o in plan_ops
              if o["kind"] == "upsample" and (o["ic"] != o["oc"] or
                                              o["oh"] != 2 * o["ih"] or
                                              o["ow"] != 2 * o["iw"])]
    add("upsample 语义(2x, ic==oc)", not up_bad, "%d 个违例" % len(up_bad), "0")
    cp_bad = [o["id"] for o in plan_ops
              if o["kind"] == "copy" and ((o["ic"] + 7) // 8 * 8 >
                                          (o["oc"] + 7) // 8 * 8)]
    add("copy 语义(ic8<=oc8, 8ch 字拷贝)", not cp_bad, "%d 个违例" % len(cp_bad), "0")
    add_bad = [o["id"] for o in plan_ops if o["kind"] == "add" and (
        o["ic"] != o["oc"] or not (0 < o.get("r_scale", 0) <= 0xFFFF)
        or not (0 <= o.get("k_add", 0) <= 15))]
    add("ADD_R 语义(ic==oc, R≤u16, KADD≤15)", not add_bad,
        "%d 个违例" % len(add_bad), "0")
    packed = [o for o in plan_ops if o["flags"] & FLAG_PACKED3]
    pk_ok = (len(packed) == 1 and packed[0]["id"] == 0 and
             packed[0]["kind"] == "conv" and packed[0]["ic"] <= 8 and
             packed[0]["k"] == 3)
    add("PACKED3 仅 conv0(ic≤8,k=3,non-dw)", pk_ok,
        "%d 个 PACKED3 op" % len(packed), "仅 op0")
    add("输入 PACKED3 张量", bool(plan_json["input"].get("packed")),
        "packed=%s" % plan_json["input"].get("packed"), "True")
    rom = summary["rom"]
    add("woff 字段位宽", rom["woff_bits_needed"] <= rom["woff_field_current_bits"],
        "%d 位" % rom["woff_bits_needed"], "≤%d 位" % rom["woff_field_current_bits"])
    add("qoff 字段位宽", rom["qoff_bits_needed"] <= rom["qoff_field_current_bits"],
        "%d 位" % rom["qoff_bits_needed"], "≤%d 位" % rom["qoff_field_current_bits"])
    add("src/dst 字段位宽(A/B 窗口)",
        summary.get("alloc", {}).get("ok") and
        max(rom["src_dst_bits_needed"], 17) <= rom["src_dst_field_current_bits"],
        "%d 位" % rom["src_dst_bits_needed"],
        "≤%d 位" % rom["src_dst_field_current_bits"])
    ws = summary.get("w_stream", {})
    add("W 流式偏移连续(ptr+=wlen)", bool(ws.get("contiguous")),
        "gaps=%d" % len(ws.get("gaps", [])), "0")
    tp = summary.get("tile_plan_stats", {})
    add("tile 方案在 IBUF/OBUF 预算内", tp.get("n_overflow_ops", 1) == 0,
        "overflow=%d" % tp.get("n_overflow_ops", -1), "0",
        "IBUF=%d/OBUF=%d B" % (tp.get("ibuf_budget_bytes", 0),
                               tp.get("obuf_budget_bytes", 0)))
    add("op 总数 ≤ ROM 深度", len(plan_ops) <= ROM_DEPTH,
        "%d" % len(plan_ops), str(ROM_DEPTH))
    fails = [it for it in items if not it["pass"]]
    return {
        "format": "bottlecap-deploy-check-v1",
        "contract": "results/ai-accel/CONTRACT.md (v0.7 + v0.8 flags/RELU)",
        "model": plan_json.get("source", {}),
        "summary": {
            "ops": len(plan_ops), "w_bytes": summary["w_bytes"],
            "q_bytes": summary["q_bytes"],
            "max_single_tensor_bytes": summary["max_single_tensor_bytes"],
            "ab_mode": summary.get("ab_mode"),
            "peak_A": ab.get("peak_A"), "peak_B": ab.get("peak_B"),
            "rom_depth": len(plan_ops), "rom_field_bits": {
                "woff": rom["woff_bits_needed"], "qoff": rom["qoff_bits_needed"],
                "src_dst": rom["src_dst_bits_needed"]},
            "max_ic": max_ic, "max_oc": max_oc,
        },
        "checks": items,
        "n_checks": len(items),
        "n_fail": len(fails),
        "status": "PASS" if not fails else "FAIL",
        "failures": fails,
    }


def tile_plan_for_op(op, tensors):
    """v2「整通道 band」tile 建议 (rtl-stream nn_tilecache v1 口径, Lead 2026-11-03)。

    引擎自带 IC block / OC lane 内层循环, tilecache 只按"输出行带 × 全宽 × 全通道"切:
      band_rows B: 从 16 往下试, 满足
          in_rows(B)*in_row_bytes <= IBUF(16384)
          B*out_row_bytes      <= OBUF(12288)
      即选该 B; 都不满足时 B=1 并标 fits=False(报告所需 IBUF/OBUF)。
      in_rows(B): conv/dwconv=(B-1)*stride+k; upsample 2x=B//2+1; add/copy=B。
      in_row_bytes = iw*pad8(ic)(PACKED3 = iw*3); out_row_bytes = ow*pad8(oc)。
    字段: band_rows / n_bands / in_rows / in_row_bytes / out_row_bytes /
          band_in_base(输入张量 arena_off, 硬件按 band 自行加偏移) / pad_top。
    """
    kind = op["kind"]
    ih, iw, oh, ow = int(op["ih"]), int(op["iw"]), int(op["oh"]), int(op["ow"])
    ic_pad, oc_pad = int(op["ic_pad"]), int(op["oc_pad"])
    k, stride = int(op["k"]), int(op["stride"])
    packed = bool(op.get("flags", 0) & FLAG_PACKED3)
    st, dt = tensors[op["src"]], tensors[op["dst"]]

    def in_rows_of(B):
        if kind in ("conv", "dwconv"):
            return (B - 1) * stride + k
        if kind == "upsample":
            return max(1, B // 2 + 1)
        return B                       # add / copy: 1:1

    in_row_bytes = iw * (3 if packed else ic_pad)
    out_row_bytes = ow * oc_pad
    chosen, why = None, ""
    for B in range(16, 0, -1):
        r = in_rows_of(B)
        ibuf, obuf = r * in_row_bytes, B * out_row_bytes
        if ibuf <= IBUF_BYTES and obuf <= OBUF_BYTES:
            chosen = (B, r, ibuf, obuf, IBUF_BYTES)
            break
    if chosen is None:
        # 瓶盖配置允许这些层用 2×32KB IBUF (Lead 2026-11-04 决策): 重新按 32KB 选带
        for B in range(16, 0, -1):
            r = in_rows_of(B)
            ibuf, obuf = r * in_row_bytes, B * out_row_bytes
            if ibuf <= IBUF_BYTES_WIDE and obuf <= OBUF_BYTES:
                chosen = (B, r, ibuf, obuf, IBUF_BYTES_WIDE)
                break
    if chosen is None:
        B = 1
        r = in_rows_of(B)
        ibuf, obuf = r * in_row_bytes, B * out_row_bytes
        chosen = (B, r, ibuf, obuf, IBUF_BYTES_WIDE)
        why = "even B=1 exceeds budget (need IBUF>=%d B / OBUF>=%d B)" % (ibuf, obuf)
    B, r, ibuf, obuf, ibuf_cfg = chosen
    return {
        "version": "v2-whole-channel-band",
        "band_rows": int(B),
        "n_bands": int((oh + B - 1) // B),
        "in_rows": int(r),
        "in_row_bytes": int(in_row_bytes),
        "out_row_bytes": int(out_row_bytes),
        "ibuf_bytes": int(ibuf),
        "obuf_bytes": int(obuf),
        "ibuf_budget_bytes": int(ibuf_cfg),
        "obuf_budget_bytes": int(OBUF_BYTES),
        "buf_config": {"ibuf_bytes": int(ibuf_cfg), "obuf_bytes": int(OBUF_BYTES)},
        "fits_at_16384": bool(ibuf <= IBUF_BYTES),
        "band_in_base": int(st["arena_off"]),
        "band_in_base_abs": int(ARENA_BASE + st["arena_off"]),
        "band_in_base_win": int(st["win_off"]),
        "pad_top": int(op.get("pad", 0)) if kind in ("conv", "dwconv") else 0,
        "fits": bool(not why),
        "overflow": bool(why),
        "note": why,
        "rule": "v2: B=16..1 自适应; 优先 IBUF=16KB, 装不下时(瓶盖配置)用 IBUF=32KB; "
                "in_rows*in_row_bytes<=IBUF 且 B*out_row_bytes<=OBUF",
    }


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="bottlecap NPU artifact generator")
    ap.add_argument("--checkpoint", default=eg.DEFAULT_CKPT)
    ap.add_argument("--arch", default=None, choices=[None, "enhanced", "slim"])
    ap.add_argument("--input-size", type=int, default=224)
    ap.add_argument("--graph", default=os.path.join(ROOT, "results", "bottlecap",
                                                    "plan", "graph.json"))
    ap.add_argument("--data", default=qn.DEFAULT_DATA)
    ap.add_argument("--calib", type=int, default=32)
    ap.add_argument("--calib-seed", type=int, default=20260819)
    ap.add_argument("--eval-images", type=int, default=4)
    ap.add_argument("--eval-seed", type=int, default=777)
    ap.add_argument("--check-images", type=int, default=1)
    ap.add_argument("--seed", type=int, default=12345)
    ap.add_argument("--outdir", default=os.path.join(ROOT, "results", "bottlecap", "plan"))
    ap.add_argument("--ab-mode", default="auto", choices=["auto", "real", "virtual"],
                    help="A/B 地址: real=必须真实装入 96KB/32KB; virtual=虚拟顺序窗口"
                         "(2M 模型); auto=能 real 就 real")
    ap.add_argument("--deploy-check", default=None,
                    help="写 DEPLOY-CHECK.json 的路径(slim 纯片上部署自检)")
    ap.add_argument("--emit-deploy-bundle", action="store_true",
                    help="调用 tools/nn_gen_rom.py + tools/nn_gen_sw.py 生成 ROM/软件头")
    ap.add_argument("--label", default="bottlecap",
                    help="bundle 文件名前缀 (slim -> slim_plan.h / nn_rom_pkg_slim.sv)")
    ap.add_argument("--emit-wq-merged", action="store_true",
                    help="输出 <label>_wq.hex = W||Q 合并的 32-bit 小端镜像(nn_mem/DDR3)")
    ap.add_argument("--final-json", default=None,
                    help="写 FINAL.json(checkpoint/产物 sha256 + 生成命令)")
    ap.add_argument("--handoff-md", default=None,
                    help="写 E2E-HANDOFF.md(ModelSim E2E 输入清单)")
    ap.add_argument("--guard", default=None,
                    help="nn_gen_sw.py 头文件 guard 名(默认 <LABEL>_PLAN_H)")
    ap.add_argument("--fuse-add", default="none", choices=["none", "a"],
                    help="[task-18] add 融合进 conv: a = A 类 residual_relu 5 个"
                         " (bit-exact, 101 op); none = 未融合 106 op")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    verbose = not args.quiet
    t0 = time.time()

    # 1) 确定性地重算 graph + quant (quant_report 由 quant_npu.py 单独落盘)
    qargs = argparse.Namespace(**vars(args))
    qargs.out = os.path.join(args.outdir, "quant_report.json")
    B = qn.build_quant(qargs, verbose=verbose)
    fusion_map = []
    if args.fuse_add != "none":
        B, fusion_map = apply_add_fusion(B, args.fuse_add, verbose=verbose)
    tensors, ops, folded = B["tensors"], B["ops"], B["folded"]
    plan, q = B["plan"], B["q"]
    gq, roots = B["gq"], B["groups"]["roots"]
    final_tids = B["final_tids"]
    s_in, zp_in = gq[roots[plan["input_tensor"]]]

    # 2) 地址: 优先真实 A/B 分配(纯片上模型); 装不下则虚拟顺序窗口(DDR3 主线)
    tensor_live_intervals(tensors, ops)
    ab_try = allocate_ab(tensors, ops, A_BYTES, B_BYTES)
    if ab_try["ok"] and args.ab_mode in ("auto", "real"):
        for t in tensors:
            t["win_buf"], t["win_off"] = ab_try["assign"][t["tid"]]
        win_bytes = max(t["win_off"] + t["bytes"] for t in tensors)
        ab_mode = "real"
    elif args.ab_mode == "real":
        raise SystemExit("[art] A/B 真实分配失败: %s (peak_A=%d peak_B=%d)"
                         % (ab_try["fail"], ab_try["peak_A"], ab_try["peak_B"]))
    else:
        win_bytes = allocate_sequential(tensors)
        ab_mode = "virtual"
    arena_off, peak_concurrent, arena_bytes = pack_arena(tensors, len(ops))
    for t in tensors:
        t["arena_off"] = int(arena_off[t["tid"]])
    unique_tensor_bytes = int(sum(t["bytes"] for t in tensors))
    total_aligned = int(sum(align_up(t["bytes"], ALIGN) for t in tensors))
    peak_A = max([t["win_off"] + t["bytes"] for t in tensors if t["win_buf"] == "A"]
                 or [0])
    peak_B = max([t["win_off"] + t["bytes"] for t in tensors if t["win_buf"] == "B"]
                 or [0])

    # 3) W/Q 镜像
    w_img, w_off_of, w_bytes = build_w_image(plan, q, verbose)
    q_img, q_bytes, q_off_of = build_q_image(plan, q, verbose)
    for op in ops:                     # 把扁平偏移同步回 graph op(B["ops"] 是 graph 侧对象)
        op["woff"] = int(w_off_of.get(op["id"], -1))
        op["qoff"] = int(q_off_of.get(op["id"], -1))

    # DDR 权重镜像流式偏移 (rtl-stream 预取引擎按 ptr += wlen 走, 必须严格单调连续)
    w_stream = []
    cur = 0
    prev_end = 0
    gaps = []
    for op in ops:
        if op["kind"] not in ("conv", "dwconv"):
            continue
        woff, wlen = int(op["woff"]), int(op["wlen"])
        if woff != prev_end:
            gaps.append({"prev_end": prev_end, "next_woff": woff,
                         "gap_bytes": woff - prev_end})
        w_stream.append({"op": int(op["id"]), "woff": woff, "wlen": wlen,
                         "ddr_off": cur, "ddr_end": cur + wlen})
        cur += wlen
        prev_end = woff + wlen
    w_stream_contiguous = (len(gaps) == 0)
    # 4) 逐 op 地址/流量/csum (golden int8 前向, 确定性 pattern_v1 输入)
    ih = iw = args.input_size
    x_pat = np.frombuffer(
        np.uint8(np.asarray([(x * 13 + y * 7 + c * 29 + args.seed) & 0xFF
                             for y in range(ih) for x in range(iw) for c in range(3)],
                            dtype=np.uint8)).tobytes(), dtype=np.int8
    ).reshape(ih, iw, 3).copy()
    input_csum = fnv1a_int8(x_pat)
    store, op_out = qn.int8_forward(plan, q, x_pat, fast=True)
    op_csum = {op["id"]: fnv1a_int8(op_out[op["id"]]) for op in ops}
    head_csum = {int(t): fnv1a_int8(store[int(t)][:, :, :tensors[int(t)]["c"]])
                 for t in final_tids}

    # 5) plan ops 条目
    #    量化报告逐层行(供 tile_zp_in 权威取值与自检); 缺失时回退到 group zp
    qrows = {}
    try:
        _qp = os.path.join(args.outdir, "quant_report.json")
        if os.path.isfile(_qp):
            with open(_qp, "r", encoding="utf-8") as f:
                for r in (json.load(f).get("layers") or []):
                    qrows[int(r["op"])] = r
    except Exception:
        qrows = {}
    plan_ops = []
    total_rd = total_wr = 0
    for op in ops:
        st, dt = tensors[op["src"]], tensors[op["dst"]]
        rd, wr = op_traffic(op, tensors)
        total_rd += rd
        total_wr += wr
        src_off = int(st["win_off"])
        dst_off = int(dt["win_off"])
        src_arena = ARENA_BASE + int(st["arena_off"])
        dst_arena = ARENA_BASE + int(dt["arena_off"])
        if op["kind"] == "copy":
            src_off += int(op.get("c_src", 0))
            dst_off += int(op.get("c_dst", 0))
            src_arena += int(op.get("c_src", 0))
            dst_arena += int(op.get("c_dst", 0))
        # tile_zp_in: 该 op 输入张量的 zero-point (conv/dwconv: 前层输出量化域 zp;
        # conv0: 输入图 zp)。权威来源 = 每张量 group zp (= quant_report zp_in);
        # 融合 plan 的 op id 已重排, 这里统一用 group zp, 未融合时另与 quant_report 对账。
        tzp = int(gq[roots[int(op["src"])]][1])
        if args.fuse_add == "none":
            tzp = int(qrows.get(int(op["id"]), {}).get("zp_in", tzp))
        d = {
            "id": int(op["id"]), "kind": op["kind"], "layer_idx": int(op.get("layer_idx", -1)),
            "module": op["module"],
            "flags": int(op.get("flags", 0)), "act": op.get("act", "none"),
            "tile_zp_in": int(tzp),
            "tile_mode": ("whole" if (int(op.get("flags", 0)) & FLAG_PACKED3) else "band"),
            "k": int(op["k"]), "stride": int(op["stride"]), "pad": int(op["pad"]),
            "leaky": int(op.get("leaky", 0)),
            "ih": int(op["ih"]), "iw": int(op["iw"]),
            "ic": int(op["ic"]), "oc": int(op["oc"]),
            "ic_pad": int(op.get("ic_pad", ((op["ic"] + 7) // 8) * 8)),
            "oc_pad": int(op.get("oc_pad", ((op["oc"] + 7) // 8) * 8)),
            "oh": int(op["oh"]), "ow": int(op["ow"]),
            "woff": int(op.get("woff", -1)), "qoff": int(op.get("qoff", -1)),
            "wlen": int(op.get("wlen", 0)), "qlen": int(op.get("qlen", 0)),
            "src": {"buf": st["win_buf"], "off": int(src_off)},
            "dst": {"buf": dt["win_buf"], "off": int(dst_off)},
            "src_tid": int(st["tid"]), "dst_tid": int(dt["tid"]),
            "src_arena_off": int(src_arena), "dst_arena_off": int(dst_arena),
            "in_bytes": int(rd), "out_bytes": int(wr),
            "traffic_read": int(rd), "traffic_write": int(wr),
            "csum": int(op_csum[op["id"]]),
            "tile_plan": tile_plan_for_op(op, tensors),
        }
        if op["kind"] in ("add",):
            a = q["adds"][op["id"]]
            d.update({"r_scale": int(a["r_scale"]), "k_add": int(a["k_add"]),
                      "zp_s": int(a["zp_s"]), "zp_d": int(a["zp_d"])})
        if op.get("fused_add"):
            d["fused_add"] = dict(op["fused_add"])       # [task-18] conv add-mode
        if op["kind"] == "copy":
            d["c_src"] = int(op.get("c_src", 0))
            d["c_dst"] = int(op.get("c_dst", 0))
        plan_ops.append(d)

    # 6) 逐层权重字节表(Lead 要求: 每层 int8 权重字节 + 单层最大 + 累计)
    w_layers = []
    cum = 0
    for op in ops:
        if op["kind"] not in ("conv", "dwconv"):
            continue
        w_layers.append({
            "op": int(op["id"]), "module": op["module"], "kind": op["kind"],
            "woff": int(op["woff"]), "wlen": int(op["wlen"]),
            "weight_bytes_real": int(op["ic"] * op["oc"] * op["k"] * op["k"])
                                 if op["kind"] == "conv" else
                                 int(op["oc"] * op["k"] * op["k"]),
            "cumulative_end": int(op["woff"] + op["wlen"]),
            "qoff": int(op["qoff"]), "qlen": int(op["qlen"]),
        })
        cum = max(cum, op["woff"] + op["wlen"])
    max_w_layer = max(w_layers, key=lambda r: r["wlen"]) if w_layers else None

    # 7) 位宽需求 (P3/v0.8 ROM v1)
    woff_max = max((o["woff"] + o["wlen"] for o in plan_ops
                    if o["woff"] >= 0), default=0)
    qoff_max = max((o["qoff"] + o["qlen"] for o in plan_ops
                    if o["qoff"] >= 0), default=0)
    rom_req = {
        "depth": len(plan_ops), "depth_limit": ROM_DEPTH,
        "depth_ok": bool(len(plan_ops) <= ROM_DEPTH),
        "woff_bits_needed": bits_for(woff_max), "woff_bytes": int(woff_max),
        "woff_field_current_bits": 19,
        "woff_field_ok_19b": bool(woff_max <= (1 << 19)),
        "qoff_bits_needed": bits_for(qoff_max), "qoff_bytes": int(qoff_max),
        "qoff_field_current_bits": 16,
        "qoff_field_ok_16b": bool(qoff_max <= (1 << 16)),
        "src_dst_bits_needed": bits_for(arena_bytes),
        "src_dst_bits_needed_absolute": bits_for(ARENA_BASE + arena_bytes),
        "src_dst_field_current_bits": 19,
        "src_dst_note": "src/dst 若存 arena 内相对偏移需 %d 位(arena=%d B); 若存 DDR3 绝对"
                        "地址(arena_base=0x1000000)则需 %d 位; 现 19b 只覆盖 512KB"
                        % (bits_for(arena_bytes), arena_bytes,
                           bits_for(ARENA_BASE + arena_bytes)),
        "arena_bytes": int(arena_bytes),
        "rom_entry_bits_estimate": 208,
        "conclusion": "ROM 深度 %d/%d 够; woff 需 %d 位(现 19), qoff 需 %d 位(现 16), "
                      "src/dst: arena 相对 %d 位 / DDR3 绝对 %d 位(现 19)" % (
                          len(plan_ops), ROM_DEPTH, bits_for(woff_max),
                          bits_for(qoff_max), bits_for(arena_bytes),
                          bits_for(ARENA_BASE + arena_bytes)),
    }

    summary = {
        "num_ops": len(plan_ops),
        "num_tensors": len(tensors),
        "kinds": {k: sum(1 for o in plan_ops if o["kind"] == k)
                  for k in sorted({o["kind"] for o in plan_ops})},
        "unique_tensor_bytes": int(unique_tensor_bytes),
        "unique_tensor_bytes_16B_aligned": int(total_aligned),
        "peak_concurrent_bytes": int(peak_concurrent),
        "min_arena_bytes": int(arena_bytes),
        "min_arena_bytes_16B_aligned": int(align_up(arena_bytes, ALIGN)),
        "max_single_tensor": max(tensors, key=lambda t: t["bytes"])["name"],
        "max_single_tensor_bytes": int(max(t["bytes"] for t in tensors)),
        "w_bytes": int(w_bytes),
        "w_bytes_aligned": int(len(w_img)),
        "q_bytes": int(q_bytes),
        "q_bytes_aligned": int(len(q_img)),
        "max_w_layer_bytes": int(max_w_layer["wlen"]) if max_w_layer else 0,
        "max_w_layer": max_w_layer,
        "w_double_buffer_2x_max_layer": int(2 * max_w_layer["wlen"]) if max_w_layer else 0,
        "traffic_read_bytes_per_frame": int(total_rd),
        "traffic_write_bytes_per_frame": int(total_wr),
        "traffic_total_bytes_per_frame": int(total_rd + total_wr),
        "traffic_total_MB_per_frame": round((total_rd + total_wr) / 1e6, 4),
        "win_sequential_bytes": int(win_bytes),
        "ab_mode": ab_mode,
        "alloc": {
            "ok": bool(ab_try["ok"]), "mode": ab_mode,
            "a_bytes": A_BYTES, "b_bytes": B_BYTES,
            "peak_A": int(peak_A), "peak_B": int(peak_B),
            "peak_A_flag": int(ab_try["peak_A"]), "peak_B_flag": int(ab_try["peak_B"]),
            "fail": ab_try["fail"],
        },
        "rom": rom_req,
        "w_stream": {
            "contiguous": bool(w_stream_contiguous),
            "gaps": gaps[:20],
            "n_layers": len(w_stream),
            "total_bytes": int(cur),
            "note": "DDR 权重镜像流式偏移 = woff(扁平累加); 预取引擎 ptr += wlen 可直接用"
                    " (contiguous=true 表示无空洞)",
        },
        "tile_plan_stats": {
            "version": "v2-whole-channel-band",
            "ibuf_budget_bytes": IBUF_BYTES, "obuf_budget_bytes": OBUF_BYTES,
            "band_rows_distribution": {str(b): sum(
                1 for op in plan_ops if op["tile_plan"]["band_rows"] == b)
                for b in sorted({op["tile_plan"]["band_rows"] for op in plan_ops})},
            "total_bands": int(sum(op["tile_plan"]["n_bands"] for op in plan_ops)),
            "n_ops_band_rows_1": int(sum(
                1 for op in plan_ops if op["tile_plan"]["band_rows"] == 1)),
            "ops_band_rows_1": [int(op["id"]) for op in plan_ops
                                if op["tile_plan"]["band_rows"] == 1],
            "max_ibuf_bytes": max(op["tile_plan"]["ibuf_bytes"] for op in plan_ops),
            "max_obuf_bytes": max(op["tile_plan"]["obuf_bytes"] for op in plan_ops),
            "max_ibuf_bytes_16k_tier": max(
                [op["tile_plan"]["ibuf_bytes"] for op in plan_ops
                 if op["tile_plan"]["fits_at_16384"]] or [0]),
            "max_ibuf_bytes_wide_tier": max(
                [op["tile_plan"]["ibuf_bytes"] for op in plan_ops
                 if not op["tile_plan"]["fits_at_16384"]] or [0]),
            "n_overflow_ops": int(sum(1 for op in plan_ops
                                      if op["tile_plan"]["overflow"])),
            "overflow_ops": [{
                "op": int(op["id"]), "kind": op["kind"],
                "shape": [op["ih"], op["iw"], op["ic"]],
                "required_ibuf_bytes": int(op["tile_plan"]["ibuf_bytes"]),
                "required_obuf_bytes": int(op["tile_plan"]["obuf_bytes"]),
            } for op in plan_ops if op["tile_plan"]["overflow"]],
            "buf_config_policy": "首选 IBUF=2x16KB; 装不下的层(瓶盖配置)用 IBUF=2x32KB",
            "ibuf_tiers": {
                "16384": {
                    "n_fits": int(sum(1 for op in plan_ops
                                      if op["tile_plan"]["fits_at_16384"])),
                    "n_need_more": int(sum(1 for op in plan_ops
                                           if not op["tile_plan"]["fits_at_16384"])),
                },
                "32768": {
                    "n_fits": int(sum(1 for op in plan_ops
                                      if op["tile_plan"]["fits"])),
                    "n_overflow": int(sum(1 for op in plan_ops
                                          if op["tile_plan"]["overflow"])),
                },
            },
            "ops_need_32k_ibuf": [{
                "op": int(op["id"]), "kind": op["kind"],
                "module": op.get("module", ""),
                "shape": [op["ih"], op["iw"], op["ic"]],
                "required_ibuf_bytes": int(op["tile_plan"]["ibuf_bytes"]),
                "band_rows": op["tile_plan"]["band_rows"],
            } for op in plan_ops if not op["tile_plan"]["fits_at_16384"]],
            "band_launch_overhead": {
                "per_band_cycles": "50..100 (估算)",
                "total_cycles_50": int(50 * sum(op["tile_plan"]["n_bands"]
                                                for op in plan_ops)),
                "total_cycles_100": int(100 * sum(op["tile_plan"]["n_bands"]
                                                  for op in plan_ops)),
            },
        },
    }
    cyc = estimate_engine_cycles(plan_ops)
    summary["engine_cycles_estimate"] = cyc
    if fusion_map:
        summary["fusion"] = {
            "stage": args.fuse_add,
            "n_ops_before": len(ops) + len(fusion_map),
            "n_ops_after": len(ops),
            "fused_adds": len(fusion_map),
            "mappings": fusion_map,
            "semantics": "M6-FUSION-CONTRACT.md B.2: q_s=conv requant(int8,饱和1); "
                         "p=((q_s-zp_out)*R)>>KADD; out=clamp(q_d+p)(饱和2); "
                         "RELU 时 out=max(out,zp_d)",
        }

    # 6b) band_plan.json (v2 整通道 band 划分, rtl-stream nn_tilecache M6b 直接消费)
    tp2 = summary["tile_plan_stats"]
    band_plan = {
        "format": "bottlecap-band-plan-v1",
        "generated_by": "tools/bottlecap/gen_npu_artifacts.py",
        "source_plan": os.path.relpath(os.path.join(args.outdir, "plan.json"),
                                       ROOT).replace("\\", "/"),
        "rule": "每 op: band_rows B=16..1 自适应, 使 in_rows(B)*in_row_bytes<=IBUF 且 "
                "B*out_row_bytes<=OBUF; IBUF 首选 2x16KB, 装不下时(瓶盖配置)该层用 2x32KB",
        "ibuf_bytes": int(IBUF_BYTES), "obuf_bytes": int(OBUF_BYTES),
        "ibuf_bytes_wide": int(IBUF_BYTES_WIDE),
        "buf_config_policy": "首选 IBUF=2x16KB; 装不下的层(瓶盖配置)用 IBUF=2x32KB",
        "in_row_bytes_formula": "iw*pad8(ic) (PACKED3: iw*3)",
        "out_row_bytes_formula": "ow*pad8(oc)",
        "band_in_base_units": "arena_off (DDR3 arena 相对); band_in_base_abs=0x1000000+off;"
                              " band_in_base_win=A/B 窗口相对(纯片上模式)",
        "summary": {
            "total_bands": tp2.get("total_bands"),
            "n_ops": len(plan_ops),
            "band_rows_distribution": tp2.get("band_rows_distribution"),
            "n_ops_band_rows_1": tp2.get("n_ops_band_rows_1"),
            "ops_band_rows_1": tp2.get("ops_band_rows_1"),
            "n_overflow_ops": tp2.get("n_overflow_ops"),
            "overflow_ops": tp2.get("overflow_ops"),
            "ibuf_tiers": tp2.get("ibuf_tiers"),
            "ops_need_32k_ibuf": tp2.get("ops_need_32k_ibuf"),
            "max_ibuf_bytes": tp2.get("max_ibuf_bytes"),
            "max_obuf_bytes": tp2.get("max_obuf_bytes"),
            "band_launch_overhead": tp2.get("band_launch_overhead"),
            "note": "IBUF=16KB 放不下的层按瓶盖配置切到 2x32KB(见 ops_need_32k_ibuf), "
                    "其余层仍 2x16KB; 两档的 B/n_bands 已分别按对应预算选取",
        },
        "ops": [{
            "op": int(o["id"]), "kind": o["kind"],
            "ih": o.get("ih"), "iw": o.get("iw"),
            "ic_pad": o.get("ic_pad"), "oc_pad": o.get("oc_pad"),
            "oh": o.get("oh"), "ow": o.get("ow"),
            "k": o.get("k"), "stride": o.get("stride"), "pad": o.get("pad"),
            "band_rows": o["tile_plan"]["band_rows"],
            "n_bands": o["tile_plan"]["n_bands"],
            "in_rows": o["tile_plan"]["in_rows"],
            "in_row_bytes": o["tile_plan"]["in_row_bytes"],
            "out_row_bytes": o["tile_plan"]["out_row_bytes"],
            "band_in_base": o["tile_plan"]["band_in_base"],
            "band_in_base_abs": o["tile_plan"]["band_in_base_abs"],
            "band_in_base_win": o["tile_plan"]["band_in_base_win"],
            "pad_top": o["tile_plan"]["pad_top"],
            "buf_config": o["tile_plan"]["buf_config"],
            "fits_at_16384": o["tile_plan"]["fits_at_16384"],
            "fits": o["tile_plan"]["fits"],
            "required_ibuf_bytes": (None if o["tile_plan"]["fits"]
                                    else o["tile_plan"]["ibuf_bytes"]),
            "required_obuf_bytes": (None if o["tile_plan"]["fits"]
                                    else o["tile_plan"]["obuf_bytes"]),
        } for o in plan_ops],
    }
    p_band = os.path.join(args.outdir, "band_plan.json")
    os.makedirs(args.outdir, exist_ok=True)
    with open(p_band, "w", encoding="utf-8") as f:
        json.dump(band_plan, f, ensure_ascii=False, indent=1)

    plan_json = {
        "format": "bottlecap-enhanced-mobilenetv2-fpn-int8-plan-v0.8",
        "source": {
            "checkpoint": os.path.relpath(os.path.abspath(args.checkpoint), ROOT)
                          .replace("\\", "/"),
            "arch": B["arch"], "input_size": int(args.input_size),
            "model_variant": eg._cfg_get(B["ck"], "model_variant"),
            "params": int(B["params"]),
        },
        "input": {"tid": int(next(t["tid"] for t in tensors if t["role"] == "input")),
                  "ih": int(ih), "iw": int(iw), "ic": 3,
                  "act_off": int(next(t["win_off"] for t in tensors
                                      if t["role"] == "input")),
                  "packed": True,
                  "layout": "PACKED3 (3B/pixel, no C8 padding)",
                  "gen": {"kind": "pattern_v1", "seed": int(args.seed)},
                  "csum": int(input_csum),
                  "s_in": float(s_in), "zp_in": int(zp_in),
                  "quant": "float[-1,1] -> int8: clip(round(x/s_in)+zp_in)"},
        "woff_units": "w_region_relative",
        "qoff_units": "q_region_relative",
        "a_base": int(NN_A_OFF), "b_base": int(NN_B_OFF),
        "ab_mode": ab_mode,
        "alloc": summary["alloc"],
        "src_dst_units": ("A/B window relative (real alloc: A=%d B=%d bytes)"
                          % (A_BYTES, B_BYTES) if ab_mode == "real" else
                          "A/B window relative (virtual sequential bump; not a"
                          " deployable physical map)"),
        "w_bytes": int(w_bytes), "q_bytes": int(q_bytes),
        "arena_base": int(ARENA_BASE),
        "arena_units": "DDR3 absolute byte address = arena_base + tensor.arena_off",
        "n_ops": len(plan_ops),
        "kinds": summary["kinds"],
        "final_ops": [int(tensors[t]["producer_op"]) for t in final_tids],
        "final_tensors": [int(t) for t in final_tids],
        "summary": summary,
        "tensors": [{
            "tid": int(t["tid"]), "name": t["name"],
            "h": int(t["h"]), "w": int(t["w"]), "c": int(t["c"]), "c8": int(t["c8"]),
            "bytes": int(t["bytes"]), "packed": bool(t["packed"]),
            "domain": t["domain"], "role": t["role"],
            "s": float(gq[roots[t["tid"]]][0]),
            "zp": int(gq[roots[t["tid"]]][1]),
            "win_off": int(t["win_off"]), "win_buf": t["win_buf"],
            "arena_off": int(t["arena_off"]),
            "arena_abs": int(ARENA_BASE + t["arena_off"]),
            "def_op": int(t["def_op"]), "last_use": int(t["last_use"]),
        } for t in tensors],
        "ops": plan_ops,
        "w_layer_table": w_layers,
        "w_stream_offsets": w_stream,
        "q_layer_bytes": int(q_bytes),
        "assumptions": qn.ASSUMPTIONS,
    }

    # 8) model.json (model side; op 编码用 ROM kind 0..5)
    model_layers = []
    for op in plan_ops:
        model_layers.append({
            "idx": op["id"], "op": KIND_CODE[op["kind"]], "kind": op["kind"],
            "flags": op["flags"], "act": op["act"],
            "k": op["k"], "stride": op["stride"], "pad": op["pad"],
            "ic": op["ic"], "oc": op["oc"],
            "ih": op["ih"], "iw": op["iw"], "oh": op["oh"], "ow": op["ow"],
            "w_off": op["woff"], "q_off": op["qoff"],
            "wlen": op["wlen"], "qlen": op["qlen"],
            "src": buffer_abs(op["src"]["buf"], op["src"]["off"]),
            "dst": buffer_abs(op["dst"]["buf"], op["dst"]["off"]),
            "src_arena_off": op["src_arena_off"], "dst_arena_off": op["dst_arena_off"],
            "tile_zp_in": int(op.get("tile_zp_in", 0)),
            "tile_mode": op.get("tile_mode", "band"),
        })
    model_json = {
        "format": "bottlecap-enhanced-mobilenetv2-fpn-int8-v0.8",
        "input_h": int(ih), "input_w": int(iw),
        "w_bytes": int(w_bytes), "q_bytes": int(q_bytes),
        "layers": model_layers,
        "checksums": {"input": int(input_csum),
                      "per_op": {str(k): int(v) for k, v in op_csum.items()},
                      "head": {str(k): int(v) for k, v in head_csum.items()}},
    }

    # 9) nn_rom_table.json (对齐 sim/prog/yolo/nn_rom_table.json 格式)
    entries = []
    for op in plan_ops:
        icb = (op["ic"] + 7) // 8
        ocb = (op["oc"] + 7) // 8
        if op["kind"] in ("add",):
            aux0, aux1 = op.get("r_scale", 0), op.get("k_add", 0)
        elif op["kind"] == "copy":
            aux0, aux1 = op.get("c_src", 0), op.get("c_dst", 0)
        elif op["kind"] in ("conv", "dwconv"):
            # [M6c] conv/dwconv 的 aux0[7:0] = tile_zp_in (band fill 物化 pad 行用)
            aux0, aux1 = int(op.get("tile_zp_in", 0)) & 0xFF, 0
        else:
            aux0 = aux1 = 0
        entries.append({
            "op": op["id"], "layer": op["layer_idx"], "kind": KIND_CODE[op["kind"]],
            "kind_name": op["kind"], "flags": op["flags"], "act": op["act"],
            "pad": op["pad"], "stride": op["stride"],
            "icb": icb, "ocb": ocb, "ih": op["ih"], "iw": op["iw"],
            "ohop": 0, "owop": 0,
            "woff": max(op["woff"], 0), "qoff": max(op["qoff"], 0),
            "wlen": op["wlen"], "qlen": op["qlen"],
            "csum": op["csum"], "aux0": aux0, "aux1": aux1,
            "tile_zp_in": int(op.get("tile_zp_in", 0)),
            "tile_mode": op.get("tile_mode", "band"),
            "src": buffer_abs(op["src"]["buf"], op["src"]["off"]),
            "dst": buffer_abs(op["dst"]["buf"], op["dst"]["off"]),
            "src_arena_off": op["src_arena_off"], "dst_arena_off": op["dst_arena_off"],
        })
    rom_table = {
        "format": "nn_rom_table-v0.8-bottlecap",
        "source_plan": "results/bottlecap/plan/plan.json",
        "hw": int(ih),
        "input": {"ih": int(ih), "iw": int(iw), "ic": 3, "packed": True,
                  "csum": int(input_csum)},
        "w_bytes": int(w_bytes), "q_bytes": int(q_bytes),
        "woff_units": "w_region_relative",
        "qoff_units": "q_region_relative",
        "src_dst_units": "A/B window absolute (A=0x%08x / B=0x%08x + off); "
                         "另有 src_arena_off/dst_arena_off 为 DDR3 arena 绝对地址"
                         % (NN_A_OFF, NN_B_OFF),
        "aux_encoding": {"add": "aux0=R (u16), aux1=KADD",
                          "copy": "aux0=source channel offset, aux1=destination channel offset",
                          "other": "0"},
        "depth": len(entries), "depth_limit": ROM_DEPTH,
        "kinds": summary["kinds"],
        "field_width_needs": rom_req,
        "entries": entries,
    }

    # 10) 落盘
    os.makedirs(args.outdir, exist_ok=True)
    def wj(name, obj):
        p = os.path.join(args.outdir, name)
        with open(p, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=1)
        return p
    p_plan = wj("plan.json", plan_json)
    p_model = wj("model.json", model_json)
    p_rom = wj("nn_rom_table.json", rom_table)
    p_w = os.path.join(args.outdir, "w.hex")
    p_q = os.path.join(args.outdir, "q.hex")
    vio.write_u32_hex(vio.bytes_to_u32_le(w_img), p_w)
    vio.write_u32_hex(vio.bytes_to_u32_le(q_img), p_q)

    # 11) checksums.txt (FNV-1a; 口径: 真实通道 x H x W, NHWC 逻辑序)
    sha_plan = sha256_file(p_plan)
    lines = [
        "# bottlecap-E2E int8 golden checksums (plan v0.8, %dx%d, %s)"
        % (ih, iw, B["arch"]),
        "# FNV-1a 32: h=2166136261; for b: h^=b; h=(h*16777619)&0xFFFFFFFF",
        "# scope: real channels x H x W, compact NHWC logical order (y,x,c);"
        " channel padding bytes NOT included",
        "# input: PACKED3 int8, pattern_v1 seed=%d" % args.seed,
        "# w_bytes=%d q_bytes=%d arena_bytes=%d arena_base=0x%08x"
        % (w_bytes, q_bytes, arena_bytes, ARENA_BASE),
        "input 0x%08x  # pattern_v1 packed 3B/pixel" % input_csum,
    ]
    for op in plan_ops:
        lines.append("op %3d kind=%-8s act=%-4s flags=0x%02x 0x%08x"
                     % (op["id"], op["kind"], op["act"], op["flags"], op["csum"]))
    for tid, csum in head_csum.items():
        lines.append("head tid=%-3d 0x%08x  # %s" % (tid, csum,
                                                   tensors[tid]["name"]))
    lines += [
        "sha256 plan.json %s" % sha_plan,
        "sha256 w.hex %s" % sha256_file(p_w),
        "sha256 q.hex %s" % sha256_file(p_q),
        "sha256 model.json %s" % sha256_file(p_model),
        "sha256 nn_rom_table.json %s" % sha256_file(p_rom),
    ]
    p_ck = os.path.join(args.outdir, "checksums.txt")
    with open(p_ck, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    # 11b) FUSION-MAP.json ([task-18] 融合 plan 的映射与语义)
    p_fm = None
    if fusion_map:
        p_fm = os.path.join(args.outdir, "FUSION-MAP.json")
        fm = {
            "format": "bottlecap-fusion-map-v1",
            "stage": args.fuse_add,
            "source_plan": os.path.relpath(p_plan, ROOT).replace("\\", "/"),
            "unfused_plan": "results/bottlecap/plan/plan.json (106 op, M6 E2E 基线)",
            "semantics_reference": "results/bottlecap/reports/M6-FUSION-CONTRACT.md "
                                   "(B.1 Q tail byte4..7 / B.2 写回级两次饱和 / B.3 可融条件)",
            "n_ops_before": int(summary["fusion"]["n_ops_before"]),
            "n_ops_after": int(summary["fusion"]["n_ops_after"]),
            "fused_adds": int(summary["fusion"]["fused_adds"]),
            "w_bytes": int(w_bytes), "q_bytes": int(q_bytes),
            "q_bytes_saved_by_fusion": int(16 * len(fusion_map)),
            "mappings": fusion_map,
            "notes": [
                "A 类 residual_relu: retarget host conv.dst := add.dst(残差 buffer),"
                " 引擎 q_d=残差, q_s=conv requant, 与未融合逐字节一致",
                "B 类 shortcut 本轮不融(引擎只从 dst 读 q_d, 残差在 src 侧且多消费者),"
                " 待引擎扩展",
                "copy(concat) 不融(需要 src 跨张量段读, 当前 RTL 不支持)",
            ],
        }
        with open(p_fm, "w", encoding="utf-8") as f:
            json.dump(fm, f, ensure_ascii=False, indent=1)
        if verbose:
            print("[fuse] FUSION-MAP.json: %d 融合映射, op %d -> %d"
                  % (len(fusion_map), fm["n_ops_before"], fm["n_ops_after"]))

    # 12) 自检
    checks = {
        "rom_depth_ok": len(entries) <= ROM_DEPTH,
        "w_image_size_ok": len(w_img) == align_up(w_bytes, 4),
        "q_image_size_ok": len(q_img) == align_up(q_bytes, 4),
        "woff_8B_aligned": all(op["woff"] % 8 == 0 for op in plan_ops if op["woff"] >= 0),
        "qoff_8B_aligned": all(op["qoff"] % 8 == 0 for op in plan_ops if op["qoff"] >= 0),
        "wlen_matches_6layout": all(
            op["wlen"] == 0 or op["wlen"] == (
                op["k"] ** 2 * op["oc_pad"] if op["kind"] == "dwconv"
                else op["k"] ** 2 * op["ic_pad"] * op["oc_pad"])
            for op in plan_ops),
        "ops_act_valid": all(op["act"] in ("relu", "none", "leaky") for op in plan_ops),
        "tile_zp_in_range": all(-128 <= int(op["tile_zp_in"]) <= 127
                                for op in plan_ops),
        "tile_zp_in_matches_quant": (
            all((int(qrows.get(op["id"], {}).get("zp_in", op["tile_zp_in"]))
                 == int(op["tile_zp_in"])) for op in plan_ops)
            if args.fuse_add == "none" else True),
        "tile_mode_ok": all(
            (op["tile_mode"] == "whole") == bool(op["flags"] & FLAG_PACKED3)
            for op in plan_ops),
        "tile_zp_in_in_rom_aux0": (all(
            (op["kind"] not in ("conv", "dwconv")) or
            ((int(op["tile_zp_in"]) & 0xFF) == int(entry["aux0"]))
            for op, entry in zip(plan_ops, entries)) if entries else True),
        "relu_flag_set": all((op["act"] != "relu") or (op["flags"] & FLAG_RELU)
                             for op in plan_ops),
        "arena_16B_aligned": all(t["arena_off"] % 16 == 0 for t in tensors),
        "src_arena_8B_aligned": all(op["src_arena_off"] % 8 == 0 for op in plan_ops),
        "dst_arena_8B_aligned": all(op["dst_arena_off"] % 8 == 0 for op in plan_ops),
        "w_stream_contiguous": bool(w_stream_contiguous),
        "w_stream_total_matches": bool(cur == sum(o["wlen"] for o in plan_ops
                                                  if o["kind"] in ("conv", "dwconv"))),
    }
    # 纯片上(real)模式的额外硬判据: 必须真装进 A/B; tile 方案必须全 fits
    if ab_mode == "real":
        checks["ab_real_alloc_ok"] = bool(ab_try["ok"])
        checks["ab_peak_within_caps"] = (peak_A <= A_BYTES and peak_B <= B_BYTES)
        checks["tile_plan_fits_budget"] = all(
            not op["tile_plan"]["overflow"] for op in plan_ops)

    # 12b) DEPLOY-CHECK.json (纯片上部署逐项自检; slim 用)
    dep = None
    if args.deploy_check:
        dep = deploy_check(plan_json, plan_ops, tensors, summary)
        os.makedirs(os.path.dirname(os.path.abspath(args.deploy_check)), exist_ok=True)
        with open(args.deploy_check, "w", encoding="utf-8") as f:
            json.dump(dep, f, ensure_ascii=False, indent=1)
        if verbose:
            print("[art] DEPLOY-CHECK: %s (%d checks, %d fail) -> %s"
                  % (dep["status"], dep["n_checks"], dep["n_fail"],
                     args.deploy_check))

    # 12c) ROM 包 + 软件头 (tools/nn_gen_rom.py / tools/nn_gen_sw.py)
    bundle = {}
    if args.emit_deploy_bundle:
        if ab_mode != "real":
            raise SystemExit("[art] --emit-deploy-bundle 需要 --ab-mode real"
                             " (否则 src/dst 超出 A/B 窗口)")
        rom_sv = os.path.join(args.outdir, "nn_rom_pkg_%s.sv" % args.label)
        rom_tbl = os.path.join(args.outdir, "nn_rom_table_%s.json" % args.label)
        sw_h = os.path.join(args.outdir, "%s_plan.h" % args.label)
        guard = args.guard or ("%s_PLAN_H" % args.label.upper())
        cmds = [
            [sys.executable, os.path.join(ROOT, "tools", "nn_gen_rom.py"),
             "--plan", os.path.abspath(p_plan), "-o", os.path.abspath(rom_sv),
             "--table", os.path.abspath(rom_tbl)],
            [sys.executable, os.path.join(ROOT, "tools", "nn_gen_sw.py"),
             "--plan", os.path.abspath(p_plan), "-o", os.path.abspath(sw_h),
             "--guard", guard],
        ]
        for ci, cmd in enumerate(cmds):
            r = subprocess.run(cmd, capture_output=True, text=True)
            out = (r.stdout or "") + (r.stderr or "")
            if r.returncode != 0 and ci == 1 and "unrecognized" in out.lower():
                cmd = cmd[:-2]           # 旧版 nn_gen_sw.py 无 --guard, 回退
                r = subprocess.run(cmd, capture_output=True, text=True)
                out = (r.stdout or "") + (r.stderr or "")
            bundle[os.path.basename(cmd[1])] = {
                "cmd": " ".join(os.path.basename(c) for c in cmd),
                "rc": r.returncode, "output": out.strip()[-2000:],
            }
            if verbose:
                print("[art] %s rc=%d: %s"
                      % (os.path.basename(cmd[1]), r.returncode,
                         out.strip().splitlines()[-1] if out.strip() else ""))
            if r.returncode != 0:
                raise SystemExit("[art] bundle 生成失败: %s\n%s" % (cmd, out))
        bundle["files"] = [os.path.basename(rom_sv), os.path.basename(rom_tbl),
                           os.path.basename(sw_h)]
        bundle["guard"] = guard

    # 12d) W||Q 合并镜像 (nn_mem / DDR3 权重镜像; yolo_wq.hex 口径)
    wq_path = None
    if args.emit_wq_merged:
        if (len(w_img) + len(q_img)) % 4 != 0:
            raise SystemExit("[art] W+Q 不是 4B 对齐, 不能直接合并为 32-bit 镜像")
        wq_path = os.path.join(args.outdir, "%s_wq.hex" % args.label)
        wq = np.concatenate([w_img, q_img])
        vio.write_u32_hex(vio.bytes_to_u32_le(wq), wq_path)
        if verbose:
            print("[art] %s: %d lines x 32-bit (= W %d B || Q %d B)"
                  % (os.path.basename(wq_path), len(wq) // 4, len(w_img), len(q_img)))
    plan_json["deploy_check"] = ({"path": os.path.relpath(args.deploy_check, ROOT)
                                  .replace("\\", "/"), "status": dep["status"]}
                                 if dep else None)
    plan_json["deploy_bundle"] = bundle or None
    # 注意: plan.json 已在上面落盘且其 sha256 已写进 checksums.txt; 这里不再改写
    # plan.json(避免 checksum 失配), deploy 信息以 DEPLOY-CHECK.json / bundle 文件为准。

    # 12e) FINAL.json + E2E-HANDOFF.md
    cyc = summary["engine_cycles_estimate"]
    if args.final_json or args.handoff_md:
        cand_files = [os.path.join(args.outdir, n) for n in
                      ("graph.json", "quant_report.json", "plan.json", "model.json",
                       "nn_rom_table.json", "w.hex", "q.hex", "checksums.txt",
                       "DEPLOY-CHECK.json", "band_plan.json",
                       "%s_wq.hex" % args.label,
                       "nn_rom_pkg_%s.sv" % args.label, "%s_plan.h" % args.label,
                       os.path.join("opvec", "manifest.json"),
                       os.path.join("opvec", "index.json"),
                       "GOLDEN-REPORT-SLIM.md", "e2e_metrics.json",
                       "FUSION-MAP.json", "FUSION-REPORT.md",
                       "E2E-HANDOFF-FUSED.md")]
        import glob as _glob
        for _pat in ("nn_rom_pkg_*.sv", "nn_rom_table_*.json"):
            cand_files += sorted(_glob.glob(os.path.join(args.outdir, _pat)))
        files = [p for p in cand_files if p and os.path.isfile(p)]
        hashes = {os.path.relpath(p, args.outdir).replace("\\", "/"):
                  sha256_file(p)[:16] for p in files}
        ckpt_sha = sha256_file(os.path.abspath(args.checkpoint))
        comm = {"ckpt_sha": ckpt_sha}
        if args.final_json:
            med = write_final_json(os.path.abspath(args.final_json), args, summary,
                                   plan_json, files, {"engine_cycles": cyc,
                                                      "bundle": bundle,
                                                      "wq_hex": os.path.basename(wq_path)
                                                      if wq_path else None})
            if verbose:
                print("[art] FINAL.json: ckpt sha256=%s..., %d 产物"
                      % (ckpt_sha[:16], len(med["files"])))
        if args.handoff_md:
            write_handoff(os.path.abspath(args.handoff_md), args, plan_json, summary,
                          cyc, hashes, comm)
            if verbose:
                print("[art] E2E-HANDOFF.md wrote %s" % args.handoff_md)
    if verbose:
        print("[art] W=%d B (%d lines)  Q=%d B (%d lines)  ops=%d"
              % (len(w_img), len(w_img) // 4, len(q_img), len(q_img) // 4, len(plan_ops)))
        print("[art] max W layer=%d B (%s)  2x double buffer=%d B"
              % (summary["max_w_layer_bytes"],
                 summary["max_w_layer"]["module"] if summary["max_w_layer"] else "-",
                 summary["w_double_buffer_2x_max_layer"]))
        print("[art] tensors=%d unique=%.3f MB peak_concurrent=%d B arena=%d B"
              % (len(tensors), unique_tensor_bytes / 1e6, peak_concurrent, arena_bytes))
        print("[art] traffic/frame: read=%.3f MB write=%.3f MB total=%.3f MB"
              % (total_rd / 1e6, total_wr / 1e6, (total_rd + total_wr) / 1e6))
        print("[art] rom: depth=%d/%d woff_bits=%d qoff_bits=%d src_dst_bits=%d"
              % (rom_req["depth"], ROM_DEPTH, rom_req["woff_bits_needed"],
                 rom_req["qoff_bits_needed"], rom_req["src_dst_bits_needed"]))
        tp = summary["tile_plan_stats"]
        print("[art] w_stream: contiguous=%s total=%d B; tile_plan: B dist=%s "
              "max IBUF=%d/OBUF=%d overflow=%d"
              % (w_stream_contiguous, cur,
                 tp["band_rows_distribution"], tp["max_ibuf_bytes"],
                 tp["max_obuf_bytes"], tp["n_overflow_ops"]))
        print("[art] checks: %s" % (all(checks.values())))
        print("[art] wrote %s (%s, %s, %s, %s, %s, %s)"
              % (args.outdir, "plan.json", "model.json", "nn_rom_table.json",
                 "w.hex", "q.hex", "checksums.txt"))
        print("[art] total %.1fs" % (time.time() - t0))

    bad = [k for k, v in checks.items() if not v]
    if bad:
        raise SystemExit("[art] SELF-CHECK FAILED: %s" % bad)


def hoff_ok(n, bits):
    return n <= (1 << bits)


if __name__ == "__main__":
    main()
