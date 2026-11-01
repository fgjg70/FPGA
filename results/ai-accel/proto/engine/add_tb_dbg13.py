# -*- coding: utf-8 -*-
"""TB 探针: packed3 MAC 次数 + win_sel 非零次数 + a_pipe 探针。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  integer band_cnt;""",
    """  integer mac_cyc, win_nz;
  always @(posedge clk) begin
    if (u_eng.state == u_eng.S_MAC) mac_cyc <= mac_cyc + 1;
    if (u_eng.mac_issue && (u_eng.win_sel[1] != 64'd0)) win_nz <= win_nz + 1;
  end
  integer band_cnt;""")
rep("""        $display("TBDBG6 %s p3_ld=%0d are=%0d ldret=%0d flags=%02x", nm, p3_ld_cyc, are_cnt, ldret_cnt, u_eng.d_flags);""",
    """        $display("TBDBG6 %s p3_ld=%0d are=%0d ldret=%0d flags=%02x mac=%0d win_nz=%0d",
                 nm, p3_ld_cyc, are_cnt, ldret_cnt, u_eng.d_flags, mac_cyc, win_nz);""")
rep("""    p3_ld_cyc = 0; are_cnt = 0; ldret_cnt = 0; p3_emit_seen = 0; band_cnt = 0;""",
    """    p3_ld_cyc = 0; are_cnt = 0; ldret_cnt = 0; p3_emit_seen = 0; band_cnt = 0;
    mac_cyc = 0; win_nz = 0;""")
io.open(P, "w", encoding="utf-8").write(s)
print("mac probe added")
