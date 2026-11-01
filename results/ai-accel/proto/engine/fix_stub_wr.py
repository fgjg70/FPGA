# -*- coding: utf-8 -*-
"""修 stub: A/B 写按 b_addr 的 16B 内字节偏移放置 strobe (原来忽略低 4 位 -> oc_pad=8 写错半字)。"""
import io

P = "nn_mem_v07_stub.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""  wire [12:0] a_idx = act_idx(a_sel, a_addr, ACT_WORDS);
  wire [12:0] b_idx = act_idx(b_sel, b_addr, ACT_WORDS);""",
    """  // A/B 窗口内平坦字节偏移 (A/B 连续阵列)
  function automatic logic [31:0] act_flat(input logic [1:0] sel, input logic [23:0] addr);
    begin
      if (sel == 2'd1) act_flat = 32'(addr) - NN_B_OFF + A_BYTES;
      else             act_flat = 32'(addr) - NN_A_OFF;
    end
  endfunction

  function automatic logic act_ok(input logic [1:0] sel, input logic [23:0] addr);
    begin
      act_ok = (sel == 2'd1)
               ? ((32'(addr) >= NN_B_OFF) && (32'(addr) < NN_B_OFF + B_BYTES))
               : ((32'(addr) >= NN_A_OFF) && (32'(addr) < NN_A_OFF + A_BYTES));
    end
  endfunction

  wire [31:0] a_flat = act_flat(a_sel, a_addr);
  wire [31:0] b_flat = act_flat(b_sel, b_addr);
  wire        a_ok   = act_ok(a_sel, a_addr);
  wire        b_ok   = act_ok(b_sel, b_addr);
  wire [12:0] a_idx  = 13'(a_flat >> 4);
  wire [12:0] b_idx  = 13'(b_flat >> 4);
  wire [3:0]  b_boff = 4'(b_flat[3:0]);""")

rep("""  always @(posedge clk) begin
    if (!a_re) a_rdata_r <= 128'd0;
    else       a_rdata_r <= act_mem[a_idx];
  end""",
    """  always @(posedge clk) begin
    if (!a_re || !a_ok) a_rdata_r <= 128'd0;
    else                a_rdata_r <= act_mem[a_idx];
  end""")

rep("""    if (b_we) begin
      for (int i = 0; i < 16; i++) begin
        if (b_wstrb[i]) act_mem[b_idx][i*8 +: 8] <= b_wdata[i*8 +: 8];
      end
    end""",
    """    if (b_we && b_ok) begin
      for (int i = 0; i < 16; i++) begin
        if (b_wstrb[i] && ((16'(b_boff) + 16'(i)) < 16))
          act_mem[b_idx][(b_boff + i[3:0])*8 +: 8] <= b_wdata[i*8 +: 8];
      end
    end""")
io.open(P, "w", encoding="utf-8").write(s)
print("stub act write offset fixed")
