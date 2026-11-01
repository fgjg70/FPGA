# -*- coding: utf-8 -*-
"""修 q_iss 计数: 打拍后 S_Q 需要 q_iss 走到 q_tot+1 (原来只到 q_tot -> 死循环 watchdog)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""          if (16'(q_iss) < q_tot) q_iss <= q_iss + 5'd1;
          // q_addr 打拍后: 引擎侧 Q 数据在发出后第 2 拍有效 -> idx = q_iss-2""",
    """          if (16'(q_iss) < (q_tot + 16'd2)) q_iss <= q_iss + 5'd1;
          // q_addr 打拍后: 引擎侧 Q 数据在发出后第 2 拍有效 -> idx = q_iss-2""")
io.open(P, "w", encoding="utf-8").write(s)
print("q_iss fix applied")
