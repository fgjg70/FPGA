# -*- coding: utf-8 -*-
"""v3 时序/资源修法 (Lead 批准):
   ① q_re/q_addr 打拍输出 (Q 读引擎侧 2 拍; S_Q +1 拍/tile)
   ② requant 乘法 32x16 拆两个 DSP (acc_hi/acc_lo 各一个 16x16), DSP 128+32=160
   ③ prod64 >>> SHIFT 拆为固定 >>16 + 4-bit 变量移位
   ④ dense 16-lane tile 且 OC8%16==0 且 dst 16B 对齐时, requant 每像素 1 个 16B beat
"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


# ---------- 声明: q 打拍 + 新 requant 中间量 ----------
rep("""  logic signed [31:0] acc_sel [0:OCL-1];
  logic signed [31:0] m_sel   [0:OCL-1];
  logic signed [63:0] prod64  [0:OCL-1];
  logic signed [47:0] y64_q   [0:OCL-1];""",
    """  logic signed [31:0] acc_sel [0:OCL-1];
  logic signed [15:0] m_sel   [0:OCL-1];
  logic signed [16:0] acc_hi  [0:OCL-1];
  logic signed [16:0] acc_lo  [0:OCL-1];
  (* use_dsp = "yes" *) logic signed [31:0] prod_hi [0:OCL-1];
  (* use_dsp = "yes" *) logic signed [31:0] prod_lo [0:OCL-1];
  logic signed [47:0] prod64  [0:OCL-1];
  logic signed [47:0] y64_q   [0:OCL-1];""")
rep("""  logic signed [31:0] bias_q [0:OCL-1];
  logic signed [15:0] mpos_q [0:OCL-1];
  logic signed [31:0] mneg_q [0:OCL-1];""",
    """  logic signed [31:0] bias_q [0:OCL-1];
  logic signed [15:0] mpos_q [0:OCL-1];
  logic signed [15:0] mneg_q [0:OCL-1];""")

# ---------- q 口打拍 ----------
rep("""  logic        w_re_c, q_re_c, a_re_c, b_we_c;""",
    """  logic        w_re_c, q_re_c, a_re_c, b_we_c;
  logic        q_re_q;
  logic [12:0] q_addr_q;""")
rep("""  assign q_addr    = q_addr_c;
  assign q_re      = q_re_c;""",
    """  assign q_addr    = q_addr_q;
  assign q_re      = q_re_q;""")
rep("""      b_we_q    <= b_we_c;
      b_addr_q  <= b_addr_c;
      b_wdata_q <= b_wdata_c;
      b_wstrb_q <= b_wstrb_c;""",
    """      b_we_q    <= b_we_c;
      b_addr_q  <= b_addr_c;
      b_wdata_q <= b_wdata_c;
      b_wstrb_q <= b_wstrb_c;
      q_re_q    <= q_re_c;
      q_addr_q  <= q_addr_c;""")
rep("""      b_we_q   <= 1'b0; b_addr_q <= 24'd0; b_wdata_q <= 128'd0; b_wstrb_q <= 16'd0;""",
    """      b_we_q   <= 1'b0; b_addr_q <= 24'd0; b_wdata_q <= 128'd0; b_wstrb_q <= 16'd0;
      q_re_q   <= 1'b0; q_addr_q <= 13'd0;""")

# ---------- S_Q: 捕获延后到 q_iss>=2, 结束 q_tot+1 ----------
rep("""          if (16'(q_iss) < q_tot) q_iss <= q_iss + 5'd1;
          if ((q_iss >= 5'd1) && (16'(q_iss) <= q_tot)) begin
            if ((q_iss - 5'd1) < qb_w) begin
              bias_q[2*q_iss - 2] <= $signed(q_rdata[31:0]);
              bias_q[2*q_iss - 1] <= $signed(q_rdata[63:32]);
            end
            else if ((q_iss - 5'd1) < (qb_w + qm_w)) begin
              mpos_q[4*(q_iss-1-qb_w) + 0] <= $signed(q_rdata[15:0]);
              mpos_q[4*(q_iss-1-qb_w) + 1] <= $signed(q_rdata[31:16]);
              mpos_q[4*(q_iss-1-qb_w) + 2] <= $signed(q_rdata[47:32]);
              mpos_q[4*(q_iss-1-qb_w) + 3] <= $signed(q_rdata[63:48]);
            end
            else begin
              zp_out  <= q_rdata[7:0];
              zp_in   <= q_rdata[15:8];
              leaky_q <= q_rdata[16];
              shift_q <= q_rdata[31:24];
            end
          end
          if (16'(q_iss) == q_tot) state <= S_QLOAD;""",
    """          if (16'(q_iss) < q_tot) q_iss <= q_iss + 5'd1;
          // q_addr 打拍后: 引擎侧 Q 数据在发出后第 2 拍有效 -> idx = q_iss-2
          if ((q_iss >= 5'd2) && (q_iss <= (q_tot + 16'd1))) begin
            if ((q_iss - 5'd2) < qb_w) begin
              bias_q[2*(q_iss-5'd2)]     <= $signed(q_rdata[31:0]);
              bias_q[2*(q_iss-5'd2) + 1] <= $signed(q_rdata[63:32]);
            end
            else if ((q_iss - 5'd2) < (qb_w + qm_w)) begin
              mpos_q[4*(q_iss-2-qb_w) + 0] <= $signed(q_rdata[15:0]);
              mpos_q[4*(q_iss-2-qb_w) + 1] <= $signed(q_rdata[31:16]);
              mpos_q[4*(q_iss-2-qb_w) + 2] <= $signed(q_rdata[47:32]);
              mpos_q[4*(q_iss-2-qb_w) + 3] <= $signed(q_rdata[63:48]);
            end
            else begin
              zp_out  <= q_rdata[7:0];
              zp_in   <= q_rdata[15:8];
              leaky_q <= q_rdata[16];
              shift_q <= q_rdata[31:24];
            end
          end
          if (16'(q_iss) == (q_tot + 16'd1)) state <= S_QLOAD;""")

# ---------- m_sel/requant: 32x16 两 DSP ----------
rep("""            m_sel[l]   <= (acc[c_p[2:0]][l] < 0) ? mneg_q[l]
                                                 : {{16{mpos_q[l][15]}}, mpos_q[l]};""",
    """            m_sel[l]   <= (acc[c_p[2:0]][l] < 0) ? mneg_q[l] : mpos_q[l];""")
rep("""        if ((c_p >= 16'd1) && (c_p <= 16'd8)) begin
          for (int l = 0; l < OCL; l++)
            prod64[l] <= $signed(acc_sel[l]) * $signed(m_sel[l]);
        end
        if ((c_p >= 16'd2) && (c_p <= 16'd9)) begin
          for (int l = 0; l < OCL; l++) y64_q[l] <= prod64[l] >>> shift_q;
        end""",
    """        if ((c_p >= 16'd1) && (c_p <= 16'd8)) begin
          for (int l = 0; l < OCL; l++) begin
            acc_hi[l] <= $signed(acc_sel[l][31:16]);
            acc_lo[l] <= $signed({1'b0, acc_sel[l][15:0]});
            prod_hi[l] <= $signed(acc_sel[l][31:16]) * $signed(m_sel[l]);
            prod_lo[l] <= $signed({1'b0, acc_sel[l][15:0]}) * $signed(m_sel[l]);
          end
        end
        if ((c_p >= 16'd2) && (c_p <= 16'd9)) begin
          logic signed [47:0] ph;
          for (int l = 0; l < OCL; l++) begin
            ph = $signed({{16{prod_hi[l][31]}}, prod_hi[l]}) <<< 16;
            prod64[l] <= ph + $signed({{16{prod_lo[l][31]}}, prod_lo[l]});
            if (shift_q >= 8'd16)
              y64_q[l] <= (prod64[l] >>> 16) >>> shift_q[3:0];
            else
              y64_q[l] <= prod64[l] >>> shift_q[3:0];
          end
        end""")

# ---------- reset: 新寄存器 ----------
rep("""        y64_q[l] <= 48'sd0; y2_q[l] <= 48'sd0; bias_q[l] <= 32'sd0;
        mpos_q[l] <= 16'sd0; mneg_q[l] <= 32'sd0; mpos32[l] <= 32'sd0;
        mtmp[l] <= 32'sd0; acc_sel[l] <= 32'sd0; m_sel[l] <= 32'sd0;
        prod64[l] <= 64'sd0; wby_r[l] <= 16'sd0;""",
    """        y64_q[l] <= 48'sd0; y2_q[l] <= 48'sd0; bias_q[l] <= 32'sd0;
        mpos_q[l] <= 16'sd0; mneg_q[l] <= 16'sd0; mpos32[l] <= 32'sd0;
        mtmp[l] <= 32'sd0; acc_sel[l] <= 32'sd0; m_sel[l] <= 16'sd0;
        acc_hi[l] <= 17'sd0; acc_lo[l] <= 17'sd0;
        prod_hi[l] <= 32'sd0; prod_lo[l] <= 32'sd0;
        prod64[l] <= 48'sd0; wby_r[l] <= 16'sd0;""")
# mneg/mpos32 计算: mneg 16bit
rep("""            for (int l = 0; l < OCL; l++)
              mneg_q[l] <= leaky_q ? ((mtmp[l] + 32'sd16384) >>> 15) : mpos32[l];""",
    """            for (int l = 0; l < OCL; l++)
              mneg_q[l] <= leaky_q ? 16'((mtmp[l] + 32'sd16384) >>> 15) : mpos_q[l];""")

# ---------- ④ 16-lane/OC8%16==0/dst 对齐 -> 每像素 1 个 16B beat ----------
rep("""  wire [15:0] req_beats = (dense && (act_l == 16'd16)) ? 16'd16 : 16'd8;""",
    """  wire single16 = (dense && (act_l == 16'd16) && (oc8_r[3:0] == 4'd0) &&
                   (d_dst[3:0] == 4'd0));
  wire [15:0] req_beats = (dense && (act_l == 16'd16))
                          ? (single16 ? 16'd8 : 16'd16) : 16'd8;""")

rep("""          beat = c_p - 16'd5;
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
          end""",
    """          beat = c_p - 16'd5;
          if (dense && (act_l == 16'd16) && !single16) begin
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
            if (single16) begin
              b_wdata_c = {out_hi[px[2:0]], out_lo[px[2:0]]};
              b_wstrb_c = 16'hFFFF;
            end
            else begin
              b_wdata_c = (sh == 4'd8) ? {pay, 64'd0} : {64'd0, pay};
              b_wstrb_c = (sh == 4'd8) ? 16'hFF00 : 16'h00FF;
            end
          end""")

rep("""          if (dense && (act_l == 16'd16))
            wpx <= wpx + (c_p[0] ? 24'd8 : (px_bytes - 24'd8));
          else
            wpx <= wpx + px_bytes;""",
    """          if (dense && (act_l == 16'd16) && !single16)
            wpx <= wpx + (c_p[0] ? 24'd8 : (px_bytes - 24'd8));
          else
            wpx <= wpx + px_bytes;""")

io.open(P, "w", encoding="utf-8").write(s)
print("v3 timing/resource fixes applied")
