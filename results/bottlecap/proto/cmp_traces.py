#!/usr/bin/env python3
"""cmp_traces.py -- compare our banded-TB port trace with ddr3-feas stock trace.

Both files use lines: # TRC <n> a_re=.. a_sel=.. a_addr=.. a_rdata=.. w_re=..
w_addr=.. w_rdata=.. q_re=.. q_addr=.. q_rdata=.. b_we=.. b_addr=.. b_wdata=..
b_wstrb=..
ASCII only.
"""

import re
import sys

KV = re.compile(r"(\w+)=([0-9a-fx]+)")


def parse(path):
    rows = []
    for line in open(path, "r", encoding="ascii", errors="replace"):
        if not line.startswith("# TRC"):
            continue
        m = re.match(r"# TRC (\d+)\s+(.*)", line.strip())
        if not m:
            continue
        kv = dict(KV.findall(m.group(2)))
        rows.append(kv)
    return rows


def events(rows, re_key, addr_key, data_key, width=8):
    """Return list of (idx, addr, data) for cycles where re_key is 1."""
    out = []
    for i, r in enumerate(rows):
        if int(r.get(re_key, "0"), 16) != 0:
            addr = int(r.get(addr_key, "0"), 16)
            # data is expected 1 cycle later for a/q, 2 for w; show both cycles
            nxt = []
            for d in (0, 1, 2):
                if i + d < len(rows):
                    nxt.append(rows[i + d].get(data_key, "0"))
            out.append((i, addr, nxt))
    return out


def first_diff(label, ev_a, ev_b):
    n = min(len(ev_a), len(ev_b))
    for i in range(n):
        if ev_a[i][1] != ev_b[i][1] or ev_a[i][2] != ev_b[i][2]:
            print(f"[cmp] {label}: first divergence at beat {i}")
            print(f"      ours  : idx={ev_a[i][0]} addr={ev_a[i][1]:x} data={ev_a[i][2]}")
            print(f"      stock : idx={ev_b[i][0]} addr={ev_b[i][1]:x} data={ev_b[i][2]}")
            return False
    print(f"[cmp] {label}: first {n} beats identical "
          f"(ours {len(ev_a)} events, stock {len(ev_b)})")
    return True


def main():
    ours = parse(sys.argv[1])
    stock = parse(sys.argv[2])
    print(f"[cmp] rows ours={len(ours)} stock={len(stock)}")
    for label, rk, ak, dk in (("a", "a_re", "a_addr", "a_rdata"),
                              ("w", "w_re", "w_addr", "w_rdata"),
                              ("q", "q_re", "q_addr", "q_rdata"),
                              ("b", "b_we", "b_addr", "b_wdata")):
        ea = events(ours, rk, ak, dk)
        eb = events(stock, rk, ak, dk)
        print(f"[cmp] ---- port {label}: ours {len(ea)} events, stock {len(eb)}")
        first_diff(label, ea, eb)
    return 0


if __name__ == "__main__":
    sys.exit(main())
