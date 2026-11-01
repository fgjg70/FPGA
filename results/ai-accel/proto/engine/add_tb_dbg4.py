# -*- coding: utf-8 -*-
"""TB: +dbgv 追加引擎内部 Q/requant 探针。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""        $display("TBDBG %s post B+0x40=%08x_%08x B+0=%08x_%08x", nm, dbgv1, dbgv0, dbgv3, dbgv2);""",
    """        $display("TBDBG %s post B+0x40=%08x_%08x B+0=%08x_%08x", nm, dbgv1, dbgv0, dbgv3, dbgv2);
        $display("TBDBG2 %s zp_out=%0d zp_in=%0d mpos0=%0d bias0=%0d mneg0=%0d shift=%0d out_lo0=%016x out_hi0=%016x",
                 nm, u_eng.zp_out, u_eng.zp_in, u_eng.mpos_q[0], u_eng.bias_q[0],
                 u_eng.mneg_q[0], u_eng.shift_q, u_eng.out_lo[0], u_eng.out_hi[0]);""")
io.open(P, "w", encoding="utf-8").write(s)
print("dbg probe added")
