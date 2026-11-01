# -*- coding: utf-8 -*-
"""TB 探针: 首个 S_MAC 拍打印 w_addr/w_re 与下一拍 w_rdata; 打印 w_mem[0x1000]。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  integer mac_cyc, win_nz, wre_cnt, prod_nz, wby_nz, ap2_nz;""",
    """  integer mac_cyc, win_nz, wre_cnt, prod_nz, wby_nz, ap2_nz, mac_seen;
  always @(posedge clk) begin
    if ((u_eng.state == u_eng.S_MAC) && (mac_seen < 2) && $test$plusargs("dbgv")) begin
      mac_seen <= mac_seen + 1;
      $display("TBMAC addr=%06x wre=%b wdata_now=%032x wmem1000=%08x",
               w_addr, w_re, w_rdata, u_mem.w_mem[17'h1000]);
    end
  end""")
rep("""    mac_cyc = 0; win_nz = 0; wre_cnt = 0; prod_nz = 0; wby_nz = 0; ap2_nz = 0;""",
    """    mac_cyc = 0; win_nz = 0; wre_cnt = 0; prod_nz = 0; wby_nz = 0; ap2_nz = 0; mac_seen = 0;""")
io.open(P, "w", encoding="utf-8").write(s)
print("mac probe2 added")
