#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Vector/checksum file I/O for CONTRACT §10 deliverables.

Formats (all little-endian byte packing):
  * int8  hex : one byte per line, 2 hex digits, two's complement
  * int32 hex : one 32-bit word per line, 8 hex digits
  * 64-bit hex: one 64-bit word per line, 16 hex digits
  * FNV-1a 32 : h=2166136261; for b in bytes: h ^= b; h = (h*16777619) & 0xFFFFFFFF
"""
import numpy as np


def fnv1a_bytes(bs):
    h = 2166136261
    for b in bs:
        h ^= b
        h = (h * 16777619) & 0xFFFFFFFF
    return h


def fnv1a_int8(arr):
    """FNV-1a over a C-contiguous int8 array in logical (y,x,c) byte order."""
    a = np.ascontiguousarray(arr, dtype=np.int8)
    return fnv1a_bytes(a.tobytes())


def write_i8_hex(arr, path):
    a = np.ascontiguousarray(arr, dtype=np.int8).ravel()
    buf = np.empty(a.size * 3, dtype=np.uint8)
    lut = np.frombuffer(b"0123456789abcdef", dtype=np.uint8)
    buf[0::3] = lut[(a.view(np.uint8) >> 4) & 0xF]
    buf[1::3] = lut[a.view(np.uint8) & 0xF]
    buf[2::3] = 0x0A
    with open(path, "wb") as f:
        f.write(buf.tobytes())


def write_u32_hex(words, path):
    a = np.ascontiguousarray(words, dtype="<u4").ravel()
    lines = "".join("%08x\n" % int(w) for w in a)
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write(lines)


def write_u64_hex(words, path):
    a = np.ascontiguousarray(words, dtype="<u8").ravel()
    lines = "".join("%016x\n" % int(w) for w in a)
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write(lines)


def bytes_to_u32_le(bs):
    """Pack a little-endian byte stream into 32-bit words (CONTRACT §10)."""
    b = np.frombuffer(bs, dtype=np.uint8)
    assert b.size % 4 == 0, "byte stream not 4B aligned: %d" % b.size
    return (b[0::4].astype(np.uint32)
            | (b[1::4].astype(np.uint32) << 8)
            | (b[2::4].astype(np.uint32) << 16)
            | (b[3::4].astype(np.uint32) << 24))


def u32_le_to_bytes(words):
    w = np.ascontiguousarray(words, dtype="<u4")
    b = np.empty(w.size * 4, dtype=np.uint8)
    b[0::4] = (w & 0xFF).astype(np.uint8)
    b[1::4] = ((w >> 8) & 0xFF).astype(np.uint8)
    b[2::4] = ((w >> 16) & 0xFF).astype(np.uint8)
    b[3::4] = ((w >> 24) & 0xFF).astype(np.uint8)
    return b


def read_u32_hex(path):
    vals = []
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            line = line.strip()
            if line:
                vals.append(int(line, 16))
    return np.asarray(vals, dtype=np.uint32)
