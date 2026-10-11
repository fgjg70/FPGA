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

【2026-10-09 系统时钟 50 -> 70 MHz（MMCM 原语）后的取整】
R35 的公式按">=10 s"给下限；但**时钟变快不影响拍数**，只压缩墙钟时间：
    ticks(3000) = 536,943,384 / 1300 * 3000 = 1,239,100,117 拍（外推值，以实测为准）
    t(70 MHz)   = 1,239,100,117 / 70e6     = 17.70 s   （50 MHz 下同一镜像要 24.8 s）
所以 3000 迭代与频率无关地满足 >= 10 s，并且给未来继续提速留了很大余量。
**上界**：上板 tick 是 31 位计数器（见 mmio_subsys.sv），上限 2^31-1 = 2,147,483,647 拍
    => ITERATIONS_max = 1300 * 2,147,483,647 / 536,943,384 = 5,199 次
    => 3000 次用掉 57.7% 量程，安全。

用法:
    python tools/mk_cm_hw.py 3000
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PY = sys.executable

CM_SRC = ["core_main.c", "core_list_join.c", "core_matrix.c",
          "core_state.c", "core_util.c", "core_portme.c", "ee_printf.c"]


def read_clk_hz() -> int:
    """从 `fpga/top_a100t.sv` 的 `.CLK_HZ(<N>)` 读真实系统时钟 —— **单一事实来源**。

    【为什么必须读而不是写 70_000_000】(W-02)
    `sw/coremark/core_portme.h` 的 CLOCKS_PER_SEC 曾经停在 50 MHz (MMCM 之前的值),
    于是硬件侧"必须跑满 10 秒才算有效成绩"的判定**宽了 1.4 倍**
    (1300 迭代 @70 MHz 真实 7.67 s 会被算成 10.74 s 并判合法)。
    现在上板/评分构建靠 `-D HW_CLK_HZ=<真实频率>` 打开时长自证; 如果这里的频率与
    `top_a100t.sv` 的 MMCM 配置不一致, 自证就变成自欺。所以两处必须同源。
    """
    p = os.path.join(REPO, "fpga", "top_a100t.sv")
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            m = re.search(r"\.CLK_HZ\s*\(\s*([\d_]+)\s*\)", f.read())
        if m:
            return int(m.group(1).replace("_", ""))
    except OSError:
        pass
    print("  [warn] 读不到 top_a100t.sv 的 .CLK_HZ(...) —— 退回 70 MHz")
    return 70_000_000


def main():
    if len(sys.argv) > 1:
        iters = int(sys.argv[1])
    else:
        iters = 3000
    opt = "-Os"
    march = "rv32im"
    clk_hz = read_clk_hz()
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
            # 【W-02 配套, 必须传】定义 HW_CLK_HZ => core_portme.h 把它当作
            # CLOCKS_PER_SEC 并打开 CM_MIN_SECS_CHECK(>=10 s 自证)。不传 = 硬件侧
            # 的时长门静默失效, 而打印出来的秒数还会按 50 MHz 算 (少报 1.4 倍)。
            "-D", "HW_CLK_HZ=%d" % clk_hz,
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

    # ------------------------------------------------------------------
    # 【X-09 单一来源】把"这个 ITERATIONS 对应的预期 tick / 等待秒数 / 时钟"
    # 写成一份小 JSON, 供 build.tcl / build_ila.tcl / ila_cap_done.tcl / cmd_hw 读取。
    # 在此之前这三个数散落在三处**手工同步**的魔数里:
    #   ila_cap_done.tcl 的 `after 22000`、fpga_workflow.py 的 `--expect-tick`、
    #   build_ila.tcl 注释里的 "17.70 s" —— R35 要求每次提速后重算 ITERATIONS,
    #   而三处只要漏改一处, 抓取就会落在程序跑完之前 (读到 score_result=0)。
    # 该文件被 .gitignore 忽略 (sim/prog/*.build.json), 是**构建产物**不是源码。
    # ------------------------------------------------------------------
    clk_hz = clk_hz                     # 与编译期 -D HW_CLK_HZ 同源 (见 read_clk_hz)
    # 预期拍数按实测基准外推 (1300 迭代 = 536,943,384 拍); 以实测为准, 这里只做等待窗口
    expect_tick = int(round(536_943_384 / 1300 * iters))
    # 必须 > 实际运行时间: int(17.70) + 5 = 22 s, 与 build-repo 的契约一致
    wait_seconds = int(expect_tick / clk_hz) + 5
    build_json = {
        "prog": "cm_hw", "iterations": iters,
        "expect_tick": expect_tick, "wait_seconds": wait_seconds,
        "clk_hz": clk_hz, "generated_by": "tools/mk_cm_hw.py",
    }
    jp = os.path.join(REPO, "sim", "prog", "cm_hw.build.json")
    with open(jp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(build_json, f, indent=2, ensure_ascii=False)
    print("  %-18s %s" % ("cm_hw.build.json", "OK"))
    print("  [build.json] ITERATIONS=%d expect_tick=%d wait_seconds=%ds clk=%dHz"
          % (iters, expect_tick, wait_seconds, clk_hz))
    return 0


if __name__ == "__main__":
    sys.exit(main())
