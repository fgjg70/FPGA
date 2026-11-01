#!/usr/bin/env python3
# ============================================================================
# cmp_engine_cycles.py -- 比较两份 tb_nn_engine 日志的逐 case 周期 (E1 前后回归)
# ----------------------------------------------------------------------------
# ASCII only (tool script rule). 用法:
#   python cmp_engine_cycles.py <baseline.log> <new.log> [--json out.json]
# 解析 tb_nn_engine 的 "CASE <name> op=... : cyc=<N> ..." 行, 比较同名 case 的 cyc;
# 输出: 每个 case 的 cyc 差异 (应为 0 才说明 E1 是纯结构改动、零周期代价),
#       以及总 cyc 差、不一致 case 数。
# 退出码: 0 = 全部一致 (或 baseline 缺失); 1 = 有差异。
# ============================================================================
import argparse
import io
import json
import re
import sys

CASE_RE = re.compile(r"CASE\s+(\S+)\s+op=\d+.*?:\s*cyc=(\d+)\s+misA=(\d+)\s+misB=(\d+)")


def _read_text(path):
    raw = io.open(path, "rb").read()
    if raw.startswith(b"\xff\xfe") or (len(raw) > 1 and raw[0] == 0 and raw[1] != 0):
        return raw.decode("utf-16", errors="replace")
    if raw.startswith(b"\xfe\xff"):
        return raw.decode("utf-16-be", errors="replace")
    return raw.decode("utf-8", errors="replace")


def parse(path):
    d = {}
    if True:
        for line in _read_text(path).splitlines():
            m = CASE_RE.search(line)
            if m:
                d[m.group(1)] = dict(cyc=int(m.group(2)),
                                     misA=int(m.group(3)),
                                     misB=int(m.group(4)))
    return d


def main() -> int:
    ap = argparse.ArgumentParser(description="Compare tb_nn_engine per-case cycles")
    ap.add_argument("baseline")
    ap.add_argument("new")
    ap.add_argument("--json", default=None, help="write per-case diff json")
    args = ap.parse_args()

    base = parse(args.baseline)
    new = parse(args.new)
    if not base:
        print("WARN: no CASE lines in baseline: %s" % args.baseline)
        return 0

    common = sorted(set(base) & set(new))
    only_base = sorted(set(base) - set(new))
    only_new = sorted(set(new) - set(base))
    diffs = []
    bad = 0
    tot_b = tot_n = 0
    for name in common:
        b = base[name]["cyc"]
        n = new[name]["cyc"]
        tot_b += b
        tot_n += n
        if b != n or base[name]["misA"] != new[name]["misA"] or base[name]["misB"] != new[name]["misB"]:
            bad += 1
            diffs.append(dict(case=name, base_cyc=b, new_cyc=n, delta=n - b,
                              base_misA=base[name]["misA"], new_misA=new[name]["misA"],
                              base_misB=base[name]["misB"], new_misB=new[name]["misB"]))
            print("DIFF %-18s cyc %d -> %d (delta %+d)" % (name, b, n, n - b))
    print("cases common=%d differ=%d total_cyc %d -> %d (delta %+d)"
          % (len(common), bad, tot_b, tot_n, tot_n - tot_b))
    if only_base:
        print("only in baseline: %s" % ", ".join(only_base))
    if only_new:
        print("only in new: %s" % ", ".join(only_new))
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="\n") as f:
            json.dump(dict(common=len(common), differ=bad, total_base=tot_b,
                           total_new=tot_n, diffs=diffs), f, indent=1)
        print("json -> %s" % args.json)
    print("ENGINE_CYCLES: %s" % ("SAME" if bad == 0 else "DIFF"))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
