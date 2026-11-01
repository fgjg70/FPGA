# -*- coding: utf-8 -*-
"""给 v3 TB 加 +dbgv 调试打印：装载后 A0、运行后 B 若干字。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  task automatic run_case(input string nm, input int op, input int flags,""",
    """  logic [31:0] dbgv0, dbgv1, dbgv2, dbgv3;

  task automatic run_case(input string nm, input int op, input int flags,""")

rep("""      run_op(cyc, ecode, ok);""",
    """      if ($test$plusargs("dbgv")) begin
        cpu_rd32(NN_A_OFF + 32'd0, dbgv0);
        cpu_rd32(NN_A_OFF + 32'd4, dbgv1);
        $display("TBDBG %s pre  A0=%08x_%08x", nm, dbgv1, dbgv0);
      end
      run_op(cyc, ecode, ok);
      if ($test$plusargs("dbgv")) begin
        cpu_rd32(NN_B_OFF + 32'd64, dbgv0);
        cpu_rd32(NN_B_OFF + 32'd68, dbgv1);
        cpu_rd32(NN_B_OFF + 32'd0,  dbgv2);
        cpu_rd32(NN_B_OFF + 32'd4,  dbgv3);
        $display("TBDBG %s post B+0x40=%08x_%08x B+0=%08x_%08x", nm, dbgv1, dbgv0, dbgv3, dbgv2);
      end""")
io.open(P, "w", encoding="utf-8").write(s)
print("tb dbgv added")
