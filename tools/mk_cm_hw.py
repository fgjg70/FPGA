#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mk_cm_hw.py -- 重新构建上板跑分镜像 sim/prog/cm_hw.hex。

【为什么需要它】tools/fpga_workflow.py 里印的"配方"缺了 FLAGS_STR，照抄会编译失败；
而 FLAGS_STR 的引号在 PowerShell 里会被吃掉。这里用 subprocess 的**列表**
形式传参（与 tools/run_coremark.py 完全相同的写法），一次成功。

【为什么要重调 ITERATIONS】CoreMark 的有效成绩要求运行 >= 10 秒。
本核变快后会跌破 10 秒（实测去掉那个冗余 IF/ID 寄存器把它从 10.16 s 拉到 9.91 s；
注意本核**始终是 5 级**，见 core.sv 头部口径说明），
所以**每次性能提升都要重算 ITERATIONS**：

    ITERATIONS_new = ceil(ITERATIONS_old * 10.0 / 实测秒数 * 1.05)   # 留 5% 余量

用法:
    python tools/mk_cm_hw.py 1300
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PY = sys.executable

CM_SRC = ["core_main.c", "core_list_join.c", "core_matrix.c",
          "core_state.c", "core_util.c", "core_portme.c", "ee_printf.c"]


def main():
    if len(sys.argv) > 1:
        iters = int(sys.argv[1])
    else:
        iters = 1300
    opt = "-Os"
    march = "rv32im"
    out = os.path.join(REPO, "sim", "prog", "cm_hw.hex")

    cmd = [PY, os.path.join(HERE, "build_sw.py")]
    # 与 run_coremark.py 的 CM_SRC **完全一致** (少一个 core_portme.c 就会
    # 报 undefined reference to seedN_volatile)
    for f in CM_SRC:
        p = os.path.join(REPO, "sw", "coremark", f)
        if os.path.exists(p):
            cmd.append(p)
        else:
            print("  [BLOCK] 缺源文件 %s" % p)
            return 1
    cmd += ["--include=" + os.path.join(REPO, "sw", "coremark"),
            "-D", "ITERATIONS=%d" % iters,
            # 必须是**一个** argv 元素, 且内含双引号 —— 这是 shell 里做不到的部分
            "-D", 'FLAGS_STR="%s -march=%s -mabi=ilp32"' % (opt, march),
            "--march=" + march, "--opt=" + opt, "-o", out]

    print("[mk_cm_hw] ITERATIONS=%d opt=%s march=%s" % (iters, opt, march))
    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-2000:])
        print(r.stderr[-2000:])
        print("BUILD FAILED")
        return 1
    for line in (r.stdout or "").splitlines():
        if "[cc]" in line or "imem" in line or "dmem" in line:
            print("  " + line)
    for f in ("cm_hw.hex", "cm_hw.dmem.hex"):
        p = os.path.join(REPO, "sim", "prog", f)
        print("  %-18s %s" % (f, "OK" if os.path.exists(p) else "MISSING"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
