# -*- coding: utf-8 -*-
"""+dbgv2: 捕获第一次 NPU 写 (b_we/b_sel/b_addr/b_idx/b_wstrb) 并在 case 结束后打印。"""
import io

P = "tb_nn_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""  logic [31:0] dbgv0, dbgv1, dbgv2, dbgv3;""",
    """  logic [31:0] dbgv0, dbgv1, dbgv2, dbgv3;
  logic        cap_seen;
  logic [23:0] cap_addr;  logic [1:0] cap_sel;  logic [15:0] cap_strb;
  logic [12:0] cap_idx;   logic [127:0] cap_data;

  always @(posedge clk) begin
    if (b_we && !cap_seen) begin
      cap_seen <= 1'b1;
      cap_addr <= b_addr;
      cap_sel  <= b_sel;
      cap_strb <= b_wstrb;
      cap_idx  <= u_mem.b_idx;
      cap_data <= b_wdata;
    end
  end""")

rep("""      if ($test$plusargs("dbgv")) begin
        cpu_rd32(NN_B_OFF + 32'd64, dbgv0);""",
    """      if ($test$plusargs("dbgv")) begin
        $display("TBDBG %s WR1 seen=%b addr=%06x sel=%b idx=%0d strb=%04x data=%032x",
                 nm, cap_seen, cap_addr, cap_sel, cap_idx, cap_strb, cap_data);
        cpu_rd32(NN_B_OFF + 32'd64, dbgv0);""")

rep("""    g_mis_a = 0; g_mis_b = 0;""",
    """    g_mis_a = 0; g_mis_b = 0;
    cap_seen = 1'b0; cap_addr = 24'd0; cap_sel = 2'd0; cap_strb = 16'd0;
    cap_idx = 13'd0; cap_data = 128'd0;""")
io.open(P, "w", encoding="utf-8").write(s)
print("dbgv2 added")
