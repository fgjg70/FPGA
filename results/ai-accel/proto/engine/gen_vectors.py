#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================================
# gen_vectors.py — T-accel 阶段 A 独立参考向量生成器 (不进 RTL 清单)
# ----------------------------------------------------------------------------
# 语义唯一来源: results/ai-accel/CONTRACT.md (§5 量化 / §6 权重布局 /
#   §7 Q 区变长布局 / §8 激活布局 / §11 引擎精确语义)
#
# 【独立性的纪律】本脚本**不使用任何 RTL 的输出**来生成期望值; 全部用 Python
#   int 做逐位整数运算 (acc/bias 用 int, 乘法不截断, 右移用 Python `>>` = floor)。
#   TB 的期望值只来自这里。
#
# 【R1 纪律】地址/容量常量**从 nn_pkg.sv 现场解析**, 不手写死 —— 布局一改
#   (v0.3 A/B 64KB → v0.4 A=96KB/B=32KB) 向量必须跟着重生成, 这里自动同步。
#
# 输出目录: results/ai-accel/proto/engine/vec/
#   manifest.txt        每个 case 一行: name op flags ks st pad ih iw ic oc src dst woff qoff
#   <name>.wq.wr        WQ 写列表: <窗口字节偏移> <32 位字>
#   <name>.a.wr / .b.wr A/B 初始装载: <64 位字索引> <hi32> <lo32>
#   <name>.aexp.wr/.bexp.wr 期望终值: 同上
# ============================================================================
import os
import random
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PKG = os.path.join(_HERE, "..", "..", "..", "..", "nn_pkg.sv")
_PKG = os.path.abspath(_PKG)
_src = open(_PKG, "r", encoding="utf-8", errors="ignore").read()


def _pint(name):
    m = re.search(r"localparam\s+(?:logic\s*\[31:0\]\s+|int\s+unsigned\s+)" + name +
                  r"\s*=\s*(32'h[0-9A-Fa-f_]+|[0-9]+\*1024|[0-9]+)", _src)
    if not m:
        raise SystemExit("gen_vectors: cannot parse %s from nn_pkg.sv" % name)
    tok = m.group(1).replace("_", "")
    if tok.startswith("32'h"):
        return int(tok[4:], 16)
    if "*" in tok:
        a, b = tok.split("*")
        return int(a) * int(b)
    return int(tok)


NN_W_OFF = _pint("NN_W_OFF")
NN_Q_OFF = _pint("NN_Q_OFF")
NN_A_OFF = _pint("NN_A_OFF")
NN_B_OFF = _pint("NN_B_OFF")
NN_W_BYTES = _pint("NN_W_BYTES")
NN_Q_BYTES = _pint("NN_Q_BYTES")
NN_A_BYTES = _pint("NN_A_BYTES")
NN_B_BYTES = _pint("NN_B_BYTES")
NN_WQ_BYTES = NN_W_BYTES + NN_Q_BYTES           # 368 KB
WQ_WORDS = NN_WQ_BYTES // 4
A_END = NN_A_OFF + NN_A_BYTES
B_END = NN_B_OFF + NN_B_BYTES

# 注: 缓冲初值统一为 0 (与 nn_mem 上电初值一致); TB 通过 CPU 窗口逐字写区域,
#     因此"区域外是否为 0"不参与比较, 但区域内所有字都会被显式写/读 (确定性)。
ZP_OUT_DEFAULT = 0


def pad8(c):
    return ((c + 7) // 8) * 8


def clamp8(v):
    if v < -128:
        return -128
    if v > 127:
        return 127
    return v


def mneg_from_mpos(mpos, leaky):
    """CONTRACT v0.3: M_neg = (M_pos*3277 + 16384) >> 15 (无 leaky 时 M_neg=M_pos)."""
    if not leaky:
        return mpos
    return (mpos * 3277 + 16384) >> 15


def rand_i8(rng):
    return rng.randint(-128, 127)


def rand_w(rng):
    return rng.randint(-127, 127)


class Vec:
    """一个独立测试向量: 窗口字节镜像 + 张量放置 + golden 运算."""

    def __init__(self, name, op, flags, ks, st, pad, ih, iw, ic, oc,
                 src, dst, woff, qoff):
        self.name = name
        self.op = op
        self.flags = flags
        self.ks = ks
        self.st = st
        self.pad = pad
        self.ih = ih
        self.iw = iw
        self.ic = ic
        self.oc = oc
        self.src = src
        self.dst = dst
        self.woff = woff
        self.qoff = qoff
        self.a = bytearray(NN_A_BYTES)         # 初值 0
        self.b = bytearray(NN_B_BYTES)
        self.aexp = bytearray(NN_A_BYTES)      # 期望终值
        self.bexp = bytearray(NN_B_BYTES)
        self.wq = bytearray(NN_WQ_BYTES)       # W/Q 未用区 = 0
        self.winfo = []                         # (byte_offset, bytes)
        self.regions = []                       # [(buf, byte_off, nbytes)] 参与比较的区域

    def add_region(self, off, nbytes):
        base, which = self.base_of(off)
        assert nbytes % 8 == 0
        self.regions.append((which, off - base, nbytes))

    # ---- 缓冲/窗口映射 ----
    @staticmethod
    def base_of(off):
        if NN_A_OFF <= off < A_END:
            return NN_A_OFF, 'a'
        if NN_B_OFF <= off < B_END:
            return NN_B_OFF, 'b'
        raise ValueError("offset 0x%X not in A/B" % off)

    def _limit(self, which):
        return NN_A_BYTES if which == 'a' else NN_B_BYTES

    def _buf(self, off):
        base, which = self.base_of(off)
        return (self.a if which == 'a' else self.b), off - base

    def _expbuf(self, off):
        base, which = self.base_of(off)
        return (self.aexp if which == 'a' else self.bexp), off - base

    def put_tensor(self, off, data):
        buf, pos = self._buf(off)
        base, which = self.base_of(off)
        assert pos + len(data) <= self._limit(which), self.name
        buf[pos:pos + len(data)] = data
        exp, _ = self._expbuf(off)
        exp[pos:pos + len(data)] = data

    def put_tensor_exp(self, off, data):
        buf, pos = self._expbuf(off)
        base, which = self.base_of(off)
        assert pos + len(data) <= self._limit(which), self.name
        buf[pos:pos + len(data)] = data

    def get_tensor_bytes(self, off, nbytes):
        buf, pos = self._buf(off)
        return bytes(buf[pos:pos + nbytes])

    # ---- 权重/Q 区写入 ----
    def put_w(self, data, rel=0):
        self.wq[self.woff - NN_W_OFF + rel:self.woff - NN_W_OFF + rel + len(data)] = data
        self.winfo = (rel, bytes(data))

    def put_q(self, data, rel=0):
        self.wq[self.qoff - NN_Q_OFF + rel:self.qoff - NN_Q_OFF + rel + len(data)] = data


# ---------------------------------------------------------------------------
# 张量打包 / 解包 (NHWC, 8 通道分块, 64 位字) — CONTRACT §8
# ---------------------------------------------------------------------------
def pack_nhwc8(t, h, w, c8):
    """t[y][x][c] -> bytes, pixel stride = c8 字节."""
    out = bytearray(h * w * c8)
    for y in range(h):
        for x in range(w):
            base = (y * w + x) * c8
            for c in range(c8):
                out[base + c] = t[y][x][c] & 0xFF
    return bytes(out)


def unpack_nhwc8(data, h, w, c8):
    t = [[[0] * c8 for _ in range(w)] for _ in range(h)]
    for y in range(h):
        for x in range(w):
            base = (y * w + x) * c8
            for c in range(c8):
                v = data[base + c]
                t[y][x][c] = v - 256 if v >= 128 else v
    return t


# ---------------------------------------------------------------------------
# golden 运算 (全整数, 与 CONTRACT v0.3 §5/§11 逐位一致)
# ---------------------------------------------------------------------------
def golden_conv(v, inp, wq, bias, mpos, zp_in, zp_out, shift, leaky, dw=False):
    """返回 out[y][x][oc8] (int, 含 padding 通道 = zp_out)."""
    k, st, pad = v.ks, v.st, v.pad
    ic, oc = v.ic, v.oc
    C8 = pad8(ic)
    OC8 = pad8(oc)
    ih, iw = v.ih, v.iw
    oh = (ih + 2 * pad - k) // st + 1
    ow = (iw + 2 * pad - k) // st + 1
    w = wq                    # dense: w[oc][ic][tap]; dw: w[oc][tap]
    mneg = [mneg_from_mpos(m, leaky) for m in mpos]
    out = [[[0] * OC8 for _ in range(ow)] for _ in range(oh)]
    for oy in range(oh):
        for ox in range(ow):
            for ocn in range(OC8):
                if ocn >= oc:
                    out[oy][ox][ocn] = zp_out
                    continue
                acc = bias[ocn]
                if dw:
                    # depthwise: 输出通道 ocn 只用输入通道 ocn (每个通道独立卷积)
                    for ky in range(k):
                        for kx in range(k):
                            iy = oy * st + ky - pad
                            ix = ox * st + kx - pad
                            av = inp[iy][ix][ocn] if (0 <= iy < ih and 0 <= ix < iw) else zp_in
                            acc += av * w[ocn][ky * k + kx]
                else:
                    for ky in range(k):
                        for kx in range(k):
                            iy = oy * st + ky - pad
                            ix = ox * st + kx - pad
                            tap = ky * k + kx
                            for icn in range(ic):
                                if 0 <= iy < ih and 0 <= ix < iw:
                                    av = inp[iy][ix][icn]
                                else:
                                    av = zp_in
                                acc += av * w[ocn][icn][tap]
                m = mpos[ocn] if acc >= 0 else mneg[ocn]
                y = (acc * m) >> shift          # floor (Python int >> 对负数=算术右移)
                out[oy][ox][ocn] = clamp8(y + zp_out)
    return out, oh, ow


def golden_pool(v, inp, oh, ow, zp_out_unused=0):
    k, st, pad = v.ks, v.st, v.pad
    ih, iw, ic = v.ih, v.iw, v.ic
    C8 = pad8(ic)
    out = [[[0] * C8 for _ in range(ow)] for _ in range(oh)]
    for oy in range(oh):
        for ox in range(ow):
            for c in range(C8):
                if c >= ic:
                    out[oy][ox][c] = 0          # 引擎定义: pool 输出 padding 通道 = 0
                    continue
                best = -128
                for ky in range(k):
                    for kx in range(k):
                        iy = oy * st + ky - pad
                        ix = ox * st + kx - pad
                        if 0 <= iy < ih and 0 <= ix < iw:
                            if inp[iy][ix][c] > best:
                                best = inp[iy][ix][c]
                out[oy][ox][c] = best
    return out


# ---------------------------------------------------------------------------
# 生成各个 case
# ---------------------------------------------------------------------------
def wq_dense_bytes(w, ic, oc, k):
    ic8, oc8 = pad8(ic), pad8(oc)
    out = bytearray(k * k * ic8 * oc8)
    p = 0
    for tap in range(k * k):
        for icn in range(ic8):
            for ocn in range(oc8):
                out[p] = (w[ocn][icn][tap] & 0xFF) if (ocn < oc and icn < ic) else 0
                p += 1
    assert p == len(out)
    return bytes(out)


def wq_dw_bytes(w, ic, oc, k):
    oc8 = pad8(oc)
    out = bytearray(k * k * oc8)
    p = 0
    for tap in range(k * k):
        for ocn in range(oc8):
            out[p] = (w[ocn][tap] & 0xFF) if ocn < ic else 0
            p += 1
    assert p == len(out)
    return bytes(out)


def q_block_bytes(bias, mpos, zp_out, zp_in, leaky, shift):
    oc8 = len(bias)
    assert len(mpos) == oc8
    out = bytearray(6 * oc8 + 16)
    p = 0
    for x in bias:
        out[p:p + 4] = int(x & 0xFFFFFFFF).to_bytes(4, 'little')
        p += 4
    for x in mpos:
        out[p:p + 2] = int(x & 0xFFFF).to_bytes(2, 'little')
        p += 2
    assert p == 6 * oc8
    out[p + 0] = zp_out & 0xFF
    out[p + 1] = zp_in & 0xFF
    out[p + 2] = 1 if leaky else 0
    out[p + 3] = shift & 0xFF
    return bytes(out)


def make_conv(name, ih, iw, ic, oc, k, st, pad, leaky, seed, dw=False,
              mpos_mode='small', shift=16, src_off_extra=0, src_in_a=True,
              qoff_extra=0, zp=None, bias_scale=1):
    rng = random.Random(seed)
    ic8, oc8 = pad8(ic), pad8(oc)
    oh = (ih + 2 * pad - k) // st + 1
    ow = (iw + 2 * pad - k) // st + 1
    flags = 0
    if dw:
        flags |= 1 << 0
    if leaky:
        flags |= 1 << 1
    src_base = NN_A_OFF if src_in_a else NN_B_OFF
    dst_base = NN_B_OFF if src_in_a else NN_A_OFF
    src = src_base + src_off_extra
    dst = dst_base + 64
    woff = (0x1000 * (seed % 7) + 0x4000 * (seed % 5)) & 0x3F000
    qoff = NN_Q_OFF + (0x400 * (seed % 8)) + qoff_extra
    v = Vec(name, 0, flags, k, st, pad, ih, iw, ic, oc, src, dst, woff, qoff)

    if zp is None:
        zp_in = rng.randint(-20, 20)
        zp_out = rng.randint(-20, 20)
    else:
        zp_in, zp_out = zp

    # ---- 输入张量 ----
    C8 = ic8
    inp = [[[0] * C8 for _ in range(iw)] for _ in range(ih)]
    for y in range(ih):
        for x in range(iw):
            for c in range(C8):
                if c < ic:
                    inp[y][x][c] = rand_i8(rng)
                else:
                    inp[y][x][c] = zp_in      # CONTRACT §8: 未用通道填 zp_a
    v.put_tensor(src, pack_nhwc8(inp, ih, iw, C8))

    # ---- 权重 ----
    if dw:
        assert oc == ic
        w = [[rand_w(rng) for _ in range(k * k)] for _ in range(oc8)]
        wbytes = wq_dw_bytes(w, ic, oc, k)
    else:
        w = [[[rand_w(rng) for _ in range(k * k)] for _ in range(ic8)]
             for _ in range(oc8)]
        wbytes = wq_dense_bytes(w, ic, oc, k)
    v.put_w(wbytes)

    # ---- Q 参数 ----
    if mpos_mode == 'small':
        mpos = [rng.randint(20, 400) for _ in range(oc8)]
    elif mpos_mode == 'large':
        mpos = [rng.randint(20000, 32767) for _ in range(oc8)]
    elif mpos_mode == 'mix':
        mpos = [rng.randint(1, 32767) for _ in range(oc8)]
    else:
        raise ValueError(mpos_mode)
    bias = [rng.randint(-(1 << 20) * bias_scale, (1 << 20) * bias_scale) for _ in range(oc8)]
    for i in range(oc, oc8):
        bias[i] = 0
        mpos[i] = 0
    v.put_q(q_block_bytes(bias, mpos, zp_out, zp_in, leaky, shift))

    # ---- golden ----
    out, oh2, ow2 = golden_conv(v, inp, w, bias, mpos, zp_in, zp_out, shift, leaky, dw)
    assert (oh2, ow2) == (oh, ow)
    out_bytes = pack_nhwc8(out, oh, ow, oc8)
    v.put_tensor_exp(dst, out_bytes)
    v.add_region(src, ih * iw * ic8)
    v.add_region(dst, oh * ow * oc8)
    v.expect = dict(oh=oh, ow=ow, ic8=ic8, oc8=oc8)
    return v


def make_pool(name, ih, iw, ic, k, st, pad, seed, src_in_a=True, flags_extra=0):
    rng = random.Random(seed)
    C8 = pad8(ic)
    oh = (ih + 2 * pad - k) // st + 1
    ow = (iw + 2 * pad - k) // st + 1
    src_base = NN_A_OFF if src_in_a else NN_B_OFF
    dst_base = NN_B_OFF if src_in_a else NN_A_OFF
    src = src_base + 8
    dst = dst_base + 32
    qoff = NN_Q_OFF + 0x1000
    v = Vec(name, 1, 1 << 4 | flags_extra, k, st, pad, ih, iw, ic, ic, src, dst, 0, qoff)
    inp = [[[rand_i8(rng) for _ in range(C8)] for _ in range(iw)] for _ in range(ih)]
    v.put_tensor(src, pack_nhwc8(inp, ih, iw, C8))
    out = golden_pool(v, inp, oh, ow)
    v.put_tensor_exp(dst, pack_nhwc8(out, oh, ow, C8))
    v.add_region(src, ih * iw * C8)
    v.add_region(dst, oh * ow * C8)
    v.expect = dict(oh=oh, ow=ow, c8=C8)
    return v


def make_copy(name, ih, iw, ic, oc, seed, upsample=False, src_in_a=True):
    rng = random.Random(seed)
    C8 = pad8(ic)
    OC8 = pad8(oc)
    src_base = NN_A_OFF if src_in_a else NN_B_OFF
    dst_base = NN_B_OFF if src_in_a else NN_A_OFF
    src = src_base + 64
    dst = dst_base + 128
    flags = (1 << 3) if upsample else 0
    v = Vec(name, 2, flags, 1, 1, 0, ih, iw, ic, oc, src, dst, 0, NN_Q_OFF + 0x2000)
    inp = [[[rand_i8(rng) for _ in range(C8)] for _ in range(iw)] for _ in range(ih)]
    v.put_tensor(src, pack_nhwc8(inp, ih, iw, C8))
    oh = ih * 2 if upsample else ih
    ow = iw * 2 if upsample else iw
    # expected 以 dst 区初值为底 (未写通道保持 poison, 靠 TB 全镜像比较抓越界写)
    init_dst = v.get_tensor_bytes(dst, oh * ow * OC8)
    out = bytearray(init_dst)
    icb = C8 // 8
    for y in range(ih):
        for x in range(iw):
            for cb in range(icb):
                src_word = bytes([inp[y][x][cb * 8 + i] & 0xFF for i in range(8)])
                positions = []
                if upsample:
                    for dy in range(2):
                        for dx in range(2):
                            oy, ox = 2 * y + dy, 2 * x + dx
                            positions.append((oy, ox))
                else:
                    positions.append((y, x))
                for (oy, ox) in positions:
                    dbase = (oy * ow + ox) * OC8 + cb * 8
                    if dbase + 8 <= len(out):
                        out[dbase:dbase + 8] = src_word
    v.put_tensor_exp(dst, bytes(out))
    v.add_region(src, ih * iw * C8)
    v.add_region(dst, oh * ow * OC8)
    v.expect = dict(oh=oh, ow=ow, oc8=OC8)
    return v


def make_add(name, ih, iw, ic, seed, src_in_a=True, dst_in_a=None):
    rng = random.Random(seed)
    C8 = pad8(ic)
    src_base = NN_A_OFF if src_in_a else NN_B_OFF
    dst_base = NN_B_OFF if src_in_a else NN_A_OFF
    if dst_in_a is not None:
        dst_base = NN_A_OFF if dst_in_a else NN_B_OFF
    src = src_base + 64
    dst = dst_base + 64
    if src_base == dst_base:
        # 同一 buffer 内: 两个区域必须分开 (否则 dst 初值覆盖 src, 测试自相矛盾)
        dst = src + ((ih * iw * C8 + 63) // 64) * 64
    v = Vec(name, 3, 0, 1, 1, 0, ih, iw, ic, ic, src, dst, 0, NN_Q_OFF + 0x3000)
    s = [[[rand_i8(rng) for _ in range(C8)] for _ in range(iw)] for _ in range(ih)]
    d = [[[rand_i8(rng) for _ in range(C8)] for _ in range(iw)] for _ in range(ih)]
    v.put_tensor(src, pack_nhwc8(s, ih, iw, C8))
    v.put_tensor(dst, pack_nhwc8(d, ih, iw, C8))
    out = [[[0] * C8 for _ in range(iw)] for _ in range(ih)]
    for y in range(ih):
        for x in range(iw):
            for c in range(C8):
                out[y][x][c] = clamp8(s[y][x][c] + d[y][x][c])
    v.put_tensor_exp(dst, pack_nhwc8(out, ih, iw, C8))
    v.add_region(src, ih * iw * C8)
    v.add_region(dst, ih * iw * C8)
    v.expect = dict(oh=ih, ow=iw, c8=C8)
    return v


# ---------------------------------------------------------------------------
# 发射文件 (TB 用 CPU 窗口逐字装载/读回; 命令行格式见各 emit_* 注释)
# ---------------------------------------------------------------------------
def _wq_words(v):
    """返回 [(byte_off, word32)]: W 区 + Q 块的全部 32 位字."""
    out = []
    if v.op == 0:
        wlen = len(v.winfo[1])
        for off in range(v.woff, v.woff + wlen, 4):
            i = off - NN_W_OFF
            w = v.wq[i] | (v.wq[i+1] << 8) | (v.wq[i+2] << 16) | (v.wq[i+3] << 24)
            out.append((off, w))
        qlen = 6 * pad8(v.oc) + 16
        for off in range(v.qoff, v.qoff + qlen, 4):
            i = off - NN_Q_OFF
            w = v.wq[i] | (v.wq[i+1] << 8) | (v.wq[i+2] << 16) | (v.wq[i+3] << 24)
            out.append((off, w))
    return out


def emit_wq_writes(path, words):
    """每行: <窗口字节偏移 hex> <32 位字 hex>"""
    with open(path, "w", encoding="ascii") as f:
        for (off, w) in words:
            f.write("%x %08x\n" % (off, w & 0xFFFFFFFF))


def _region_words(v, which, exp):
    """缓冲区 which 的参与区域 -> 有序去重的 (word_idx, 64 位值) 列表."""
    buf = (v.aexp if exp else v.a) if which == 'a' else (v.bexp if exp else v.b)
    idx = set()
    for (bw, start, nbytes) in v.regions:
        if bw != which:
            continue
        assert start % 8 == 0 and nbytes % 8 == 0
        for k in range(start // 8, (start + nbytes) // 8):
            idx.add(k)
    out = []
    for k in sorted(idx):
        val = int.from_bytes(buf[k*8:k*8+8], 'little')
        out.append((k, val))
    return out


def emit_buf_words(path, words):
    """每行: <64 位字索引 hex> <hi32 hex> <lo32 hex>"""
    with open(path, "w", encoding="ascii") as f:
        for (k, val) in words:
            f.write("%x %08x %08x\n" % (k, (val >> 32) & 0xFFFFFFFF, val & 0xFFFFFFFF))


def emit_manifest_line(v):
    return "%s %d %d %d %d %d %d %d %d %d %d %d %d %d" % (
        v.name, v.op, v.flags, v.ks, v.st, v.pad, v.ih, v.iw, v.ic, v.oc,
        v.src, v.dst, v.woff, v.qoff)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    outdir = os.path.join(here, "vec")
    os.makedirs(outdir, exist_ok=True)
    for fn in os.listdir(outdir):
        os.remove(os.path.join(outdir, fn))

    cases = []
    # ---------------- conv dense ----------------
    cases.append(make_conv("conv1x1_s1", 8, 10, 8, 8, 1, 1, 0, True, 1))
    cases.append(make_conv("conv1x1_s1_i3o5", 6, 7, 3, 5, 1, 1, 0, True, 2))
    cases.append(make_conv("conv1x1_s2", 12, 12, 8, 8, 1, 2, 0, False, 3))
    cases.append(make_conv("conv1x1_oc24", 5, 20, 8, 24, 1, 1, 0, True, 4))
    cases.append(make_conv("conv1x1_i13o13", 6, 6, 13, 13, 1, 1, 0, True, 5))
    cases.append(make_conv("conv3x3_s1p1", 9, 10, 8, 8, 3, 1, 1, True, 6))
    cases.append(make_conv("conv3x3_s1p0", 7, 5, 8, 8, 3, 1, 0, False, 7))
    cases.append(make_conv("conv3x3_s2p1", 14, 13, 8, 16, 3, 2, 1, True, 8))
    cases.append(make_conv("conv3x3_s2p0", 12, 11, 16, 8, 3, 2, 0, True, 9))
    cases.append(make_conv("conv3x3_i13o13", 8, 9, 13, 13, 3, 1, 1, True, 10))
    cases.append(make_conv("conv5x5_s1p2", 9, 8, 8, 8, 5, 1, 2, True, 11))
    cases.append(make_conv("conv5x5_s2p2", 14, 13, 8, 8, 5, 2, 2, False, 12))
    cases.append(make_conv("conv5x5_i16o16", 8, 8, 16, 16, 5, 1, 2, True, 13))
    cases.append(make_conv("conv1x1_bigM", 5, 5, 8, 8, 1, 1, 0, True, 14, mpos_mode='large'))
    cases.append(make_conv("conv1x1_mixM", 6, 6, 8, 8, 1, 1, 0, True, 15, mpos_mode='mix'))
    cases.append(make_conv("conv3x3_shift10", 7, 7, 8, 8, 3, 1, 1, True, 16, shift=10))
    cases.append(make_conv("conv1x1_srcoff8", 5, 6, 8, 8, 1, 1, 0, False, 17, src_off_extra=8))
    cases.append(make_conv("conv1x1_srcB", 6, 6, 8, 8, 1, 1, 0, True, 18, src_in_a=False))
    cases.append(make_conv("conv3x3_srcB", 8, 8, 16, 8, 3, 1, 1, False, 19, src_in_a=False))
    cases.append(make_conv("conv1x1_bigbias", 5, 5, 8, 8, 1, 1, 0, True, 20,
                           mpos_mode='large', bias_scale=8))
    # ---------------- depthwise ----------------
    cases.append(make_conv("dw3x3_c8", 9, 10, 8, 8, 3, 1, 1, True, 21, dw=True))
    cases.append(make_conv("dw3x3_c16", 8, 8, 16, 16, 3, 1, 1, True, 22, dw=True))
    cases.append(make_conv("dw3x3_c24", 6, 7, 24, 24, 3, 1, 1, True, 23, dw=True))
    cases.append(make_conv("dw3x3_c13", 7, 8, 13, 13, 3, 1, 0, False, 24, dw=True))
    cases.append(make_conv("dw3x3_s2", 12, 11, 8, 8, 3, 2, 1, True, 25, dw=True))
    cases.append(make_conv("dw5x5_c8", 9, 8, 8, 8, 5, 1, 2, True, 26, dw=True))
    cases.append(make_conv("dw5x5_c16", 8, 9, 16, 16, 5, 1, 2, False, 27, dw=True))
    cases.append(make_conv("dw5x5_s2", 14, 13, 8, 8, 5, 2, 2, True, 28, dw=True))
    # ---------------- maxpool ----------------
    cases.append(make_pool("pool2_s2p0", 8, 8, 8, 2, 2, 0, 31))
    cases.append(make_pool("pool2_s2p1", 8, 7, 8, 2, 2, 1, 32))
    cases.append(make_pool("pool3_s1p1", 7, 9, 8, 3, 1, 1, 33))
    cases.append(make_pool("pool3_s2p1", 12, 13, 8, 3, 2, 1, 34))
    cases.append(make_pool("pool5_s1p2", 8, 8, 16, 5, 1, 2, 35))
    cases.append(make_pool("pool9_s1p4", 12, 11, 8, 9, 1, 4, 36))
    cases.append(make_pool("pool9_c13", 10, 10, 13, 9, 1, 4, 37))
    cases.append(make_pool("pool2_s2_c24", 9, 9, 24, 2, 2, 0, 38))
    cases.append(make_pool("pool3_srcB", 7, 7, 8, 3, 1, 1, 39, src_in_a=False))
    # ---------------- copy / upsample ----------------
    cases.append(make_copy("copy", 7, 6, 8, 8, 41))
    cases.append(make_copy("copy_c16", 5, 6, 16, 16, 42))
    cases.append(make_copy("copy_oc16", 4, 5, 8, 16, 43))
    cases.append(make_copy("ups2x", 5, 4, 8, 8, 44, upsample=True))
    cases.append(make_copy("ups2x_c16", 4, 5, 16, 16, 45, upsample=True, src_in_a=False))
    # ---------------- residual add ----------------
    cases.append(make_add("add", 6, 7, 8, 51))
    cases.append(make_add("add_c24", 5, 5, 24, 52))
    cases.append(make_add("add_srcB", 6, 6, 8, 53, src_in_a=False))
    cases.append(make_add("add_same_buf", 5, 6, 16, 54, dst_in_a=True))

    # ---------------- 发射 ----------------
    man = []
    for v in cases:
        assert v.regions, v.name
        emit_wq_writes(os.path.join(outdir, v.name + ".wq.wr"), _wq_words(v))
        for which, tag in (('a', 'a'), ('b', 'b')):
            emit_buf_words(os.path.join(outdir, v.name + "." + tag + ".wr"),
                           _region_words(v, which, exp=False))
            emit_buf_words(os.path.join(outdir, v.name + "." + tag + "exp.wr"),
                           _region_words(v, which, exp=True))
        man.append(emit_manifest_line(v))
    with open(os.path.join(outdir, "manifest.txt"), "w", encoding="ascii") as f:
        f.write("\n".join(man) + "\n")

    print("generated %d cases -> %s" % (len(cases), outdir))
    for v in cases:
        extra = ""
        if hasattr(v, 'expect'):
            extra = " oh=%d ow=%d" % (v.expect.get('oh', 0), v.expect.get('ow', 0))
        print("  %-18s op=%d k=%d st=%d pad=%d ih=%d iw=%d ic=%d oc=%d%s" % (
            v.name, v.op, v.ks, v.st, v.pad, v.ih, v.iw, v.ic, v.oc, extra))


if __name__ == "__main__":
    main()
