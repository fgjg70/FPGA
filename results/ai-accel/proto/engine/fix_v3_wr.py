# -*- coding: utf-8 -*-
"""v3 写口改造: b_addr 16B 对齐 + b_wstrb 移位; dense 16-lane tile 每像素 2 个 8B beat。
   (与 nn_mem v0.7 "128b 写 + 字节 strobe, 低 4 位忽略" 口径一致)"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


# ---- 1) 声明: out_lo/out_hi 替代 out_word ----
rep("""  logic [127:0]       out_word;""",
    """  logic [63:0]        out_lo [0:PX-1];   // 每像素 requant 低 8B (lane 0..7)
  logic [63:0]        out_hi [0:PX-1];   // 每像素 requant 高 8B (lane 8..15)""")

# ---- 2) REQ 周期数: act_l==16 时 2 beat/像素 ----
rep("""  wire [15:0] q_tot = qb_w + qm_w + 16'd1;      // + tail 1 字""",
    """  wire [15:0] q_tot = qb_w + qm_w + 16'd1;      // + tail 1 字
  // dense 16-lane tile: 每像素 2 个 8B 写 beat; 其余 1 beat
  wire [15:0] req_beats = (dense && (act_l == 16'd16)) ? 16'd16 : 16'd8;
  wire [15:0] reqn_w    = 16'd5 + req_beats + 16'd2;   // 5 拍流水 + beats + NEXT""")
rep("""  localparam int REQN  = 13;
  localparam int DRNN  = 3;""",
    """  localparam int DRNN  = 3;""")

# ---- 3) 端口块: 默认 b_wdata 0; S_REQ / S_PPACK / S_CP_WR / S_AD_WR 改为对齐+移位 ----
rep("""    b_we_c    = 1'b0;
    b_addr_c  = wpx;
    b_wdata_c = out_word;
    b_wstrb_c = 16'h0000;""",
    """    b_we_c    = 1'b0;
    b_addr_c  = {wpx[23:4], 4'h0};
    b_wdata_c = 128'd0;
    b_wstrb_c = 16'h0000;""")

rep("""      S_REQ: begin
        if ((c_p >= 16'd5) && (c_p <= 16'd12) && ((ox0 + (c_p - 16'd5)) < ow_w)) begin
          b_we_c    = 1'b1;
          b_addr_c  = wpx;
          b_wdata_c = out_word;
          for (int i = 0; i < 16; i++)
            b_wstrb_c[i] = ((c_ocb * ocw_r + 16'(i)) < oc8_r);
        end
      end""",
    """      S_REQ: begin
        begin : req_wr
          logic [15:0] beat;
          logic [15:0] px;
          logic        half;
          logic [63:0] pay;
          logic [3:0]  sh;
          beat = c_p - 16'd5;
          if (dense && (act_l == 16'd16)) begin
            px   = beat >> 1;
            half = beat[0];
          end
          else begin
            px   = beat;
            half = 1'b0;
          end
          if ((c_p >= 16'd5) && (c_p <= (16'd4 + req_beats)) && ((ox0 + px) < ow_w)) begin
            pay = half ? out_hi[px[2:0]] : out_lo[px[2:0]];
            sh  = wpx[3:0];
            b_we_c    = 1'b1;
            b_addr_c  = {wpx[23:4], 4'h0};
            b_wdata_c = (sh == 4'd8) ? {pay, 64'd0} : {64'd0, pay};
            b_wstrb_c = (sh == 4'd8) ? 16'hFF00 : 16'h00FF;
          end
        end
      end""")

rep("""      S_PPACK: begin
        if ((ox0 + c_p) < ow_w) begin
          b_we_c    = 1'b1;
          b_addr_c  = wpx;
          b_wdata_c = pool_pack;
          for (int i = 0; i < 8; i++)
            b_wstrb_c[i] = ((c_ocb * 16'd8 + 16'(i)) < ic8_r);
        end
      end""",
    """      S_PPACK: begin
        begin : pp_wr
          logic [63:0] pay;
          logic [15:0] stb;
          logic [3:0]  sh;
          pay = pool_pack[63:0];
          stb = 16'h0000;
          for (int i = 0; i < 8; i++)
            stb[i] = ((c_ocb * 16'd8 + 16'(i)) < ic8_r);
          sh = wpx[3:0];
          if ((ox0 + c_p) < ow_w) begin
            b_we_c    = 1'b1;
            b_addr_c  = {wpx[23:4], 4'h0};
            b_wdata_c = (sh == 4'd8) ? {pay, 64'd0} : {64'd0, pay};
            b_wstrb_c = (sh == 4'd8) ? (stb << 8) : stb;
          end
        end
      end""")

rep("""      S_CP_WR: begin
        b_we_c    = 1'b1;
        b_addr_c  = dst_la;
        b_wdata_c = {64'd0,
                     (c_wr == 2'd0)
                     ? (rd_half_s ? a_rdata[127:64] : a_rdata[63:0]) : cp_word_q};
        b_wstrb_c = 16'h00FF;
        if (f_up2x)
          b_addr_c = dst_la + (c_wr[1] ? up_px_row : 24'd0)
                            + (c_wr[0] ? ups_dx   : 24'd0);
      end""",
    """      S_CP_WR: begin
        begin : cp_wr
          logic [63:0] pay;
          logic [23:0] adr;
          logic [3:0]  sh;
          pay = (c_wr == 2'd0)
                ? (rd_half_s ? a_rdata[127:64] : a_rdata[63:0]) : cp_word_q;
          adr = dst_la;
          if (f_up2x)
            adr = dst_la + (c_wr[1] ? up_px_row : 24'd0)
                         + (c_wr[0] ? ups_dx   : 24'd0);
          sh  = adr[3:0];
          b_we_c    = 1'b1;
          b_addr_c  = {adr[23:4], 4'h0};
          b_wdata_c = (sh == 4'd8) ? {pay, 64'd0} : {64'd0, pay};
          b_wstrb_c = (sh == 4'd8) ? 16'hFF00 : 16'h00FF;
        end
      end""")

rep("""      S_AD_WR: begin
        b_we_c    = 1'b1;
        b_addr_c  = dst_la;
        b_wdata_c = {64'd0, ad_pack};
        b_wstrb_c = 16'h00FF;
      end""",
    """      S_AD_WR: begin
        begin : ad_wr
          logic [3:0] sh;
          sh = dst_la[3:0];
          b_we_c    = 1'b1;
          b_addr_c  = {dst_la[23:4], 4'h0};
          b_wdata_c = (sh == 4'd8) ? {ad_pack, 64'd0} : {64'd0, ad_pack};
          b_wstrb_c = (sh == 4'd8) ? 16'hFF00 : 16'h00FF;
        end
      end""")

# ---- 4) 时序块: wpx 步进 (2 beat/像素) + out_lo/out_hi 寄存 ----
rep("""      if (state == S_REQ) begin
        if (c_p == 16'd4) wpx <= wr_base;
        if ((c_p >= 16'd5) && (c_p <= 16'd12)) wpx <= wpx + px_bytes;
      end""",
    """      if (state == S_REQ) begin
        if (c_p == 16'd4) wpx <= wr_base;
        else if ((c_p >= 16'd5) && (c_p < (16'd5 + req_beats))) begin
          if (dense && (act_l == 16'd16))
            wpx <= wpx + (c_p[0] ? (px_bytes - 24'd8) : 24'd8);
          else
            wpx <= wpx + px_bytes;
        end
      end""")

rep("""        if ((c_p >= 16'd4) && (c_p <= 16'd11)) out_word <= rq_pack;""",
    """        if ((c_p >= 16'd4) && (c_p <= 16'd11)) begin
          out_lo[c_p[2:0]] <= rq_pack[63:0];
          out_hi[c_p[2:0]] <= rq_pack[127:64];
        end""")

rep("""        if (c_p == (REQN - 1)) begin""",
    """        if (c_p == (reqn_w - 16'd1)) begin""")

# ---- 5) reset: out_lo/out_hi ----
rep("""      for (int l = 0; l < OCL; l++) begin
        y64_q[l] <= 48'sd0; y2_q[l] <= 48'sd0; bias_q[l] <= 32'sd0;""",
    """      for (int px = 0; px < PX; px++) begin
        out_lo[px] <= 64'sd0; out_hi[px] <= 64'sd0;
      end
      for (int l = 0; l < OCL; l++) begin
        y64_q[l] <= 48'sd0; y2_q[l] <= 48'sd0; bias_q[l] <= 32'sd0;""")

io.open(P, "w", encoding="utf-8").write(s)
print("v3 write path reworked")
