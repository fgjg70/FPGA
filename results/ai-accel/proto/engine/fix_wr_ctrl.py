# -*- coding: utf-8 -*-
"""把写回模式控制 (dense16/single16/beats/reqn) 在 S_DRN 拍打拍, 修 OOC 最差路径
   ocw_r -> b_wdata_q (b_wdata 的 mux 选择来自 ocw_r 组合)。"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:250]
    s = s.replace(old, new, 1)


# 1) 声明
rep("""  wire single16 = (dense && (act_l == 16'd16) && (oc8_r[3:0] == 4'd0) &&
                   (d_dst[3:0] == 4'd0));
  wire [15:0] req_beats = (dense && (act_l == 16'd16))
                          ? (single16 ? 16'd8 : 16'd16) : 16'd8;""",
    """  wire single16 = (dense && (act_l == 16'd16) && (oc8_r[3:0] == 4'd0) &&
                   (d_dst[3:0] == 4'd0));
  wire wr_dense16 = dense && (act_l == 16'd16);
  wire [15:0] req_beats = wr_dense16 ? (single16 ? 16'd8 : 16'd16) : 16'd8;
  // S_DRN 打拍的控制 (避免 ocw_r -> b_wdata mux 长路径)
  logic        wr16_r, wrs16_r;
  logic [15:0] wrbeats_r;""")
rep("""  wire [15:0] reqn_w    = 16'd6 + req_beats + 16'd2;   // 6 拍流水 + beats + NEXT""",
    """  wire [15:0] reqn_w    = 16'd6 + wrbeats_r + 16'd2;   // 6 拍流水 + beats + NEXT""")

# 2) S_DRN c_drn==0 打拍
rep("""        S_DRN: begin
          if (c_drn == (DRNN - 1)) begin""",
    """        S_DRN: begin
          if (c_drn == 16'd0) begin
            wr16_r    <= wr_dense16;
            wrs16_r   <= single16;
            wrbeats_r <= req_beats;
          end
          if (c_drn == (DRNN - 1)) begin""")

# 3) 端口块 S_REQ/写步进 用寄存器版
rep("""          if (dense && (act_l == 16'd16) && !single16) begin
            px   = beat >> 1;
            half = beat[0];
          end""",
    """          if (wr16_r && !wrs16_r) begin
            px   = beat >> 1;
            half = beat[0];
          end""")
rep("""          if ((c_p >= 16'd6) && (c_p <= (16'd5 + req_beats)) && ((ox0 + px) < ow_w)) begin""",
    """          if ((c_p >= 16'd6) && (c_p <= (16'd5 + wrbeats_r)) && ((ox0 + px) < ow_w)) begin""")
rep("""            if (single16) begin
              b_wdata_c = {out_hi[px[2:0]], out_lo[px[2:0]]};
              b_wstrb_c = 16'hFFFF;
            end""",
    """            if (wrs16_r) begin
              b_wdata_c = {out_hi[px[2:0]], out_lo[px[2:0]]};
              b_wstrb_c = 16'hFFFF;
            end""")
rep("""          if (dense && (act_l == 16'd16) && !single16)
            wpx <= wpx + (c_p[0] ? (px_bytes - 24'd8) : 24'd8);
          else
            wpx <= wpx + px_bytes;""",
    """          if (wr16_r && !wrs16_r)
            wpx <= wpx + (c_p[0] ? (px_bytes - 24'd8) : 24'd8);
          else
            wpx <= wpx + px_bytes;""")
rep("""        else if ((c_p >= 16'd6) && (c_p < (16'd6 + req_beats))) begin""",
    """        else if ((c_p >= 16'd6) && (c_p < (16'd6 + wrbeats_r))) begin""")

# 4) reset
rep("""      ad_pack_q <= 64'd0;""",
    """      ad_pack_q <= 64'd0;
      wr16_r <= 1'b0; wrs16_r <= 1'b0; wrbeats_r <= 16'd8;""")

io.open(P, "w", encoding="utf-8").write(s)
print("write-mode controls registered")
