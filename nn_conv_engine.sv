`timescale 1ns/1ps

// ============================================================================
// nn_conv_engine.sv —— v3 (T-accel-R3)
//   128 MAC/拍 (16 OC lanes × 8 px) + 独立 Q 读口 + PACKED3 / ADD_R 模式。
//
// 与 v2 的关系: 端口按 CONTRACT v0.7 §12.3/§12.6 变更
//   - w_rdata[127:0]  (每拍 16 个 OC 字节)
//   - b_wdata[127:0] + b_wstrb[15:0]  (16 lane 写回, 字节 strobe)
//   - 新增 q_re/q_addr[12:0]/q_rdata[63:0] (Q 区 LUTRAM, 64b 字索引)
//   - desc (nn_desc_t, flags 7 位) 语义不变; 数值公式/floor/leaky/zp/饱和一律不变。
//
// 通道分块:
//   - dense conv: OC tile = 16 lane (权重按 [tap][IC8][OC8] 布局, 读 16 连续字节);
//   - depthwise / pool / copy / add: 沿用 v2 的 8 通道粒度 (只激活 lane 0..7);
//   - PACKED3 (conv0): 激活 3B/像素 packed 输入, 权重仍 dense (IC8=8, 后 5 ic 权重为 0);
//   - ADD_R (shortcut add): out=clamp(q_d + (((q_s-zp_s)*R)>>KADD),-128,127),
//     参数来自 Q 区 16B 块: [0]=zp_s [1]=zp_d [2:3]=R(u16 LE) [4]=KADD。
//
// 周期: 见 results/ai-accel/engine-report.md §0.6 (BASE=8, Q=按 tile active lane 数,
//       DRN=3, REQ=13, NEXT=2; 46+ case 逐 case 必须与公式相等)。
// ============================================================================

module nn_conv_engine
  import nn_pkg::*;
#(
  parameter int OC_LANES = 16,
  parameter int PX_LANES = 8,
  parameter int W_RD_LAT = 2        // W 读有效时延: 2=配 wpipe mem (根默认); 1=旧 mem 兼容
)(
  input  logic         clk,
  input  logic         rst,
  input  nn_pkg::nn_desc_t desc,
  input  logic         start,
  output logic         busy,
  output logic         done,
  output logic [31:0]  cycles,
  output logic [7:0]   err_code,
  // ---- 权重读口 (128 位/拍 = 16 OC 字节) ----
  output logic         w_re,
  output logic [23:0]  w_addr,
  input  logic [127:0] w_rdata,
  // ---- Q 读口 (64 位/拍, 64b 字索引) ----
  output logic         q_re,
  output logic [12:0]  q_addr,
  input  logic [63:0]  q_rdata,
  // ---- 激活读口 (128 位/拍) ----
  output logic [1:0]   a_sel,
  output logic         a_re,
  output logic [23:0]  a_addr,
  input  logic [127:0] a_rdata,
  // ---- 激活写口 (128 位/拍 + 字节 strobe) ----
  output logic [1:0]   b_sel,
  output logic         b_we,
  output logic [23:0]  b_addr,
  output logic [127:0] b_wdata_128,
  output logic [15:0]  b_wstrb
);

  localparam int PX    = PX_LANES;   // 8
  localparam int OCL   = OC_LANES;   // 16
  localparam int BANDW = 24;
  localparam int WINW  = 15;
  localparam bit LAT2  = (W_RD_LAT >= 2);
  localparam int DRNN  = LAT2 ? 4 : 3;

  typedef enum logic [4:0] {
    S_IDLE, S_INIT, S_VCHK, S_CPREP, S_Q, S_QLOAD, S_BI, S_LD, S_LDCAP,
    S_WI, S_MAC, S_DRN, S_REQ, S_NEXT, S_NEXT2, S_PINIT, S_PMAX, S_PPACK,
    S_CP_RD, S_CP_WR, S_AD_Q, S_AD_R1, S_AD_R2, S_AD_WR, S_AD_WR2, S_AD_WR3, S_FIN
  } state_e;

  state_e state;

  // ==========================================================================
  // 描述符锁存 + one-hot
  // ==========================================================================
  logic [1:0]  d_op;
  logic [6:0]  d_flags;
  logic [3:0]  d_ks;
  logic [1:0]  d_st;
  logic [2:0]  d_pad;
  logic [15:0] d_ih, d_iw, d_ic, d_oc;
  logic [31:0] d_src, d_dst, d_woff, d_qoff;

  logic is_conv, is_pool, is_copy, is_add;
  logic f_dw, f_leaky, f_up2x, f_p3, f_add_r;
  wire dense = is_conv && !f_dw;

  wire [2:0] pad_eff = (is_pool && (d_pad == 3'd0))
      ? (({1'b0, d_ks} - 4'd1) >> 1) : d_pad;

  wire [15:0] ks16 = {12'd0, d_ks};
  wire [15:0] st16 = {14'd0, d_st};

  logic [15:0] oh_w, ow_w;   // 输出尺寸 (S_CPREP 寄存)
  logic [2:0]  pad_r;
  logic        st2_r;

  wire [15:0] ic8 = (d_ic + 16'd7) & 16'hFFF8;
  wire [15:0] oc8 = (d_oc + 16'd7) & 16'hFFF8;
  wire [15:0] icb_n = {10'd0, ic8[8:3]};      // IC8/8
  wire [15:0] ld_count = (dense && (d_ks == 4'd1))
                         ? 16'd8 : (7 * st16 + ks16);

  // ==========================================================================
  // 描述符检查 (2 级)
  // ==========================================================================
  logic cr_ks_bad, cr_st_bad, cr_pad_bad, cr_ic_bad, cr_ih_bad, cr_dw_bad;
  logic cr_p3_bad;
  logic pl_ks_bad, pl_st_bad, pl_pad_bad, pl_ic_bad;
  logic cp_ic_bad, cp_hw_bad, cp_cn_bad;
  logic ad_ic_bad, ad_hw_bad, ad_oc_bad, ad_r_bad;
  logic d_oh_bad;

  always_comb begin
    cr_ks_bad = !(d_ks == 4'd1 || d_ks == 4'd3 || d_ks == 4'd5);
    cr_st_bad = !(d_st == 2'd1 || d_st == 2'd2);
    cr_pad_bad= (d_pad > (ks16 >> 1));
    cr_ic_bad = (d_ic == 16'd0 || d_oc == 16'd0);
    cr_ih_bad = (d_ih == 16'd0 || d_iw == 16'd0);
    cr_dw_bad = f_dw && (d_oc != d_ic);
    cr_p3_bad = f_p3 && (!is_conv || f_dw || (d_ic > 16'd8) || (d_ks != 4'd3));
    pl_ks_bad = !(d_ks == 4'd2 || d_ks == 4'd3 || d_ks == 4'd5 || d_ks == 4'd9);
    pl_st_bad = !(d_st == 2'd1 || d_st == 2'd2);
    pl_pad_bad= (d_pad > (ks16 >> 1));
    pl_ic_bad = (d_ic == 16'd0 || d_ih == 16'd0 || d_iw == 16'd0);
    cp_ic_bad = (d_ic == 16'd0 || d_oc == 16'd0);
    cp_hw_bad = (d_ih == 16'd0 || d_iw == 16'd0);
    cp_cn_bad = (ic8 > oc8);
    ad_ic_bad = (d_ic == 16'd0);
    ad_hw_bad = (d_ih == 16'd0 || d_iw == 16'd0);
    ad_oc_bad = (d_oc != d_ic);
    ad_r_bad  = f_add_r && !is_add;
    d_oh_bad  = (({1'b0, d_ih} + (pad_eff << 1)) < {13'd0, d_ks}) ||
                (({1'b0, d_iw} + (pad_eff << 1)) < {13'd0, d_ks});
  end

  logic cr_ks_f, cr_st_f, cr_pad_f, cr_ic_f, cr_ih_f, cr_dw_f, cr_p3_f;
  logic pl_ks_f, pl_st_f, pl_pad_f, pl_ic_f;
  logic cp_ic_f, cp_hw_f, cp_cn_f, ad_ic_f, ad_hw_f, ad_oc_f, ad_r_f, d_oh_f;
  logic [7:0] init_err;

  always_comb begin
    init_err = 8'h00;
    if (is_conv) begin
      if (cr_ks_f)       init_err = 8'h11;
      else if (cr_st_f)  init_err = 8'h12;
      else if (cr_pad_f) init_err = 8'h13;
      else if (cr_ic_f)  init_err = 8'h14;
      else if (cr_ih_f)  init_err = 8'h15;
      else if (cr_dw_f)  init_err = 8'h16;
      else if (cr_p3_f)  init_err = 8'h17;
      else if (d_oh_f)   init_err = 8'h18;
    end
    else if (is_pool) begin
      if (pl_ks_f)       init_err = 8'h21;
      else if (pl_st_f)  init_err = 8'h22;
      else if (pl_pad_f) init_err = 8'h23;
      else if (pl_ic_f)  init_err = 8'h24;
      else if (d_oh_f)   init_err = 8'h25;
    end
    else if (is_copy) begin
      if (cp_ic_f)       init_err = 8'h31;
      else if (cp_hw_f)  init_err = 8'h32;
      else if (cp_cn_f)  init_err = 8'h33;
    end
    else begin
      if (ad_ic_f)       init_err = 8'h41;
      else if (ad_hw_f)  init_err = 8'h42;
      else if (ad_oc_f)  init_err = 8'h43;
      else if (ad_r_f)   init_err = 8'h44;
    end
  end

  // ==========================================================================
  // 计数器 / 控制
  // ==========================================================================
  logic [31:0] cycles_r;
  logic [7:0]  err_r;
  logic        done_r;
  logic [15:0] c_ocb, c_oy, c_oxg, c_ky, c_icb, c_m, c_ld, c_p, c_iy, c_ix, c_cb;
  logic [2:0]  c_drn;
  logic [4:0]  q_iss;
  logic [1:0]  c_wr;
  logic        c_ql;
  logic [1:0]  p3_ph;              // PACKED3 装载子拍 0/1/2
  logic        ld_ret_v, ld_fill_d, ld_half_d;
  logic [4:0]  ld_j_d;
  logic [7:0]  ld_fillbyte_d;
  logic        mac_v1, mac_v2, mac_v3, mac_v4;
  logic signed [15:0] wby_r [0:OCL-1];
  logic        rd_half_s, rd_half_d;
  logic [63:0] src_word_q;
  logic [63:0] cp_word_q;

  // ==========================================================================
  // 数据寄存器
  // ==========================================================================
  logic [63:0] abuf  [0:BANDW-1];
  logic [63:0] bshift[0:WINW-1];

  logic signed [31:0] acc    [0:PX-1][0:OCL-1];
  logic signed [7:0]  a_pipe [0:PX-1][0:OCL-1];
  logic signed [7:0]  a_pipe1[0:PX-1][0:OCL-1];   // LAT2: 中间级 (对齐 2 拍 W 时延)
  logic signed [7:0]  a_pipe2[0:PX-1][0:OCL-1];
  logic signed [15:0] prod   [0:PX-1][0:OCL-1];

  logic signed [31:0] bias_q [0:OCL-1];
  logic signed [15:0] mpos_q [0:OCL-1];
  logic signed [15:0] mneg_q [0:OCL-1];
  logic signed [31:0] mpos32 [0:OCL-1];
  (* use_dsp = "no" *) logic signed [31:0] mtmp   [0:OCL-1];
  logic signed [7:0]  zp_out, zp_in;
  logic [7:0]         shift_q;
  logic               leaky_q;
  logic signed [7:0]  zp_s_r, zp_d_r;     // ADD_R 参数
  logic [15:0]        add_r_r;
  logic [7:0]         kadd_r;

  logic signed [7:0]  mx [0:PX-1][0:OCL-1];

  logic signed [31:0] acc_sel [0:OCL-1];
  logic signed [15:0] m_sel   [0:OCL-1];
  logic signed [16:0] acc_hi  [0:OCL-1];
  logic signed [16:0] acc_lo  [0:OCL-1];
  (* use_dsp = "yes" *) logic signed [31:0] prod_hi [0:OCL-1];
  (* use_dsp = "yes" *) logic signed [31:0] prod_lo [0:OCL-1];
  logic signed [47:0] prod64  [0:OCL-1];
  logic signed [47:0] y64_q   [0:OCL-1];
  logic signed [47:0] y2_q    [0:OCL-1];
  logic [63:0]        out_lo [0:PX-1];   // 每像素 requant 低 8B (lane 0..7)
  logic [63:0]        out_hi [0:PX-1];   // 每像素 requant 高 8B (lane 8..15)

  // PACKED3 两级窗口
  logic [127:0] p3w0, p3w1;

  // ==========================================================================
  // 预计算常量
  // ==========================================================================
  logic [15:0] ic8_r, oc8_r, ocw_r, oc_limit_r, icb_n_r;
  logic [4:0]  q_tot_r, qb_w_r, qm_w_r;     // Q 装载拍数/字数 (寄存器)
  logic        icb_more_r;                  // (c_icb+1 < icb_n) 预打拍
  logic [15:0] rem_ch;                      // 当前 tile 之后剩余通道数 (增量)
  logic [12:0] q_bias_w, q_mpos_w, q_tail_w; // Q 三段 64b 字索引 (寄存器)
  logic [23:0] row_step_a, oy_step_a, ox_step_a, band_step_a, band_ky_step, base0_a;
  logic [23:0] row_step_w, ox_step_w, px_bytes;
  logic [23:0] w_p2, w_dgrp, w_sub;
  logic [23:0] p1, p1_2, p1_3, p1_4;
  logic [23:0] base0_t, base0_t2;
  logic [23:0] d_row_step, d_row_step2, d_x_step, up_px_row, ups_dx, cp_dst_pix;
  logic [15:0] dx_r;
  logic [15:0] ld_count_r, ld_m1_r;

  // PACKED3 地址步长
  logic [23:0] p3_row, p3_oy, p3_ox;

  // 地址寄存器
  logic [23:0] wa_r, qa_r;
  logic [23:0] row_base_a, blk_base, band_base, la;
  logic [23:0] row_base_w, wr_base, wpx;
  logic [23:0] src_la, dst_la;
  logic [23:0] row_base_a_n, row_base_w_n;
  logic [1:0]  nxt_sel;
  logic        sel_a_src, sel_b_dst;

  // 装载 in-bounds 追踪
  logic signed [15:0] x_ld, x0_ld, y_ld;
  logic               y_ok_r;

  // ==========================================================================
  // 组合端口
  // ==========================================================================
  logic        w_re_c, q_re_c, a_re_c, b_we_c;
  logic        q_re_q;
  logic [12:0] q_addr_q;
  logic [23:0] w_addr_c, a_addr_c, b_addr_c;
  logic [12:0] q_addr_c;
  logic [127:0] b_wdata_c;
  logic [15:0]  b_wstrb_c;

  logic        b_we_q;
  logic [23:0] b_addr_q;
  logic [127:0] b_wdata_q;
  logic [15:0]  b_wstrb_q;

  wire [15:0] ox0 = c_oxg << 3;
  wire signed [15:0] x0_c  = $signed(ox0) * (st2_r ? 16'sd2 : 16'sd1)
                             - $signed({13'd0, pad_r});
  wire signed [15:0] y_ky0 = $signed(c_oy) * (st2_r ? 16'sd2 : 16'sd1)
                             - $signed({13'd0, pad_r});

  // 本 OC tile 的有效 lane 数 (按 OC8 补零块计)
  wire [15:0] act_l = {{10{1'b0}}, qb_w_r, 1'b0};      // 2*qb_w_r (寄存器)
  wire [15:0] oc_base_w = oc8_r - act_l - rem_ch;     // 当前 tile 起始 OC 通道 (加法, 无乘法)
  wire [15:0] qb_w  = {11'd0, qb_w_r};          // bias 64b 字数 (2 lane/字)
  wire [15:0] qm_w  = {11'd0, qm_w_r};          // mpos 64b 字数 (4 lane/字)
  wire [15:0] q_tot = {11'd0, q_tot_r};         // 总字数
  // dense 16-lane tile: 每像素 2 个 8B 写 beat; 其余 1 beat
  wire single16 = (dense && (act_l == 16'd16) && (oc8_r[3:0] == 4'd0) &&
                   (d_dst[3:0] == 4'd0));
  wire wr_dense16 = dense && (act_l == 16'd16);
  wire [15:0] req_beats = wr_dense16 ? (single16 ? 16'd8 : 16'd16) : 16'd8;
  // S_DRN 打拍的控制 (避免 ocw_r -> b_wdata mux 长路径)
  logic        wr16_r, wrs16_r;
  logic [15:0] wrbeats_r;
  wire [15:0] reqn_w    = 16'd6 + wrbeats_r + 16'd2;   // 6 拍流水 + beats + NEXT

  // Q 三段的 64b 字索引 (寄存器)
  wire [12:0] q_bias_base = q_bias_w;
  wire [12:0] q_mpos_base = q_mpos_w;
  wire [12:0] q_tail_base = q_tail_w;

  // band in-bounds
  wire ld_inb = y_ok_r && (x_ld >= 0) && (x_ld < $signed(d_iw));
  wire [7:0] ld_fill = is_pool ? 8'h80 : zp_in;

  // 权重地址增量
  wire [23:0] w_delta = (c_m == ((ks16 << 3) - 16'd1))
                        ? ((c_icb + 16'd1 < icb_n_r) ? w_sub : w_p2)
                        : (((c_m[2:0] == 3'd7) && ((c_m[7:3] + 16'd1) < ks16))
                           ? w_dgrp : w_p2);

  // ---------------------------------------------------------------- requant 打包
  logic [127:0] rq_pack;
  always_comb begin
    logic signed [47:0] y2;
    logic [7:0] bb;
    logic fits;
    rq_pack = 128'd0;
    for (int l = 0; l < OCL; l++) begin
      y2   = y2_q[l];
      fits = (&y2[47:7]) || (~|y2[47:7]);
      if (fits) bb = y2[7:0];
      else      bb = y2[47] ? 8'h80 : 8'h7F;
      if ((oc_base_w + 16'(l)) >= d_oc) bb = zp_out;
      rq_pack[l*8 +: 8] = bb;
    end
  end

  // ---------------------------------------------------------------- pool 打包 (8 lane)
  logic [127:0] pool_pack;
  always_comb begin
    logic [7:0] bb;
    pool_pack = 128'd0;
    for (int l = 0; l < OCL; l++) begin
      if (l < 8) begin
        bb = mx[c_p[2:0]][l];
        if ((c_ocb * 16'd8 + l) >= d_ic) bb = 8'h00;
        pool_pack[l*8 +: 8] = bb;
      end
    end
  end

  // ---------------------------------------------------------------- ADD 打包
  wire [63:0] ad_dst_word = rd_half_d ? a_rdata[127:64] : a_rdata[63:0];
  logic [63:0] ad_pack;
  logic [63:0] ad_pack_q;
  logic signed [8:0] ad_delta [0:7];
  logic signed [8:0] ad_qq [0:7];
  logic signed [7:0] ad_qs [0:7];
  (* use_dsp = "no" *) logic signed [31:0] ad_mul [0:7];
  logic [63:0] ad_dst_q;
  always_comb begin
    logic signed [8:0]  s;
    logic signed [31:0] p;
    logic signed [7:0]  qs, qd;
    ad_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      if (l < 8) begin
        if (f_add_r) begin
          qs = $signed(src_word_q[l*8 +: 8]);
          qd = $signed(ad_dst_word[l*8 +: 8]);
          p  = ($signed(qs) - $signed(zp_s_r)) * $signed({1'b0, add_r_r});
          p  = p >>> kadd_r;
          p  = p + {{24{qd[7]}}, qd};
          if (p > 32'sd127)       ad_pack[l*8 +: 8] = 8'h7F;
          else if (p < -32'sd128) ad_pack[l*8 +: 8] = 8'h80;
          else                    ad_pack[l*8 +: 8] = p[7:0];
        end
        else begin
          s = $signed({src_word_q[l*8 + 7], src_word_q[l*8 +: 8]})
            + $signed({ad_dst_word[l*8 + 7], ad_dst_word[l*8 +: 8]});
          if (s > 9'sd127)       ad_pack[l*8 +: 8] = 8'h7F;
          else if (s < -9'sd128) ad_pack[l*8 +: 8] = 8'h80;
          else                   ad_pack[l*8 +: 8] = s[7:0];
        end
      end
    end
  end

  // ---------------------------------------------------------------- A 窗口
  logic [63:0] win_sel [0:PX-1];
  always_comb begin
    for (int px = 0; px < PX; px++) begin
      if (dense && (d_ks == 4'd1))
        win_sel[px] = abuf[px];
      else
        win_sel[px] = st2_r ? bshift[2*px] : bshift[px];
    end
  end
  logic [63:0] ad_pack2;
  always_comb begin
    logic signed [9:0] s2;
    logic signed [7:0] qd2;
    ad_pack2 = 64'd0;
    for (int l = 0; l < 8; l++) begin
      qd2 = $signed(ad_dst_q[l*8 +: 8]);
      s2  = $signed({qd2[7], qd2}) + $signed(ad_delta[l]);
      if (s2 > 10'sd127)       ad_pack2[l*8 +: 8] = 8'h7F;
      else if (s2 < -10'sd128) ad_pack2[l*8 +: 8] = 8'h80;
      else                     ad_pack2[l*8 +: 8] = s2[7:0];
    end
  end

  wire [63:0] ad_src_word = rd_half_s ? a_rdata[127:64] : a_rdata[63:0];

  wire [5:0] sel_byte_base = {c_m[2:0], 3'b000};
  wire [3:0] cur_kx = dense ? c_m[7:3] : c_m[3:0];
  wire win_adv = (state == S_MAC)
      ? (dense ? ((c_m[2:0] == 3'd7) && ((c_m[7:3] + 16'd1) < ks16))
               : ((c_m + 16'd1) < ks16))
      : ((state == S_PMAX) ? ((c_m + 16'd1) < ks16) : 1'b0);
  wire mac_issue = (state == S_MAC);

  // ==========================================================================
  // 端口组合驱动
  // ==========================================================================
  always_comb begin
    w_re      = 1'b0;
    w_addr_c  = wa_r;
    q_re_c    = 1'b0;
    q_addr_c  = 13'd0;
    a_re      = 1'b0;
    a_addr_c  = la;
    a_sel     = sel_a_src ? 2'd1 : 2'd0;
    b_we_c    = 1'b0;
    b_addr_c  = {wpx[23:4], 4'h0};
    b_wdata_c = 128'd0;
    b_wstrb_c = 16'h0000;

    if (state == S_Q) begin
      q_re_c   = (16'(q_iss) < q_tot);
      q_addr_c = (q_iss < qb_w) ? (q_bias_base + 13'(q_iss))
               : (16'(q_iss) < (qb_w + qm_w))
                   ? (q_mpos_base + 13'(q_iss - qb_w))
                   : (q_tail_base + 13'(q_iss - qb_w - qm_w));
    end
    else if (state == S_MAC) begin
      w_re     = 1'b1;
      w_addr_c = wa_r;
    end

    case (state)
      S_LD: begin
        if (f_p3) begin
          a_re     = ld_inb && (p3_ph != 2'd2);
          a_addr_c = (p3_ph == 2'd0) ? (la & ~24'd15) : ((la & ~24'd15) + 24'd16);
        end
        else begin
          a_re     = ld_inb;
          a_addr_c = la;
        end
      end
      S_CP_RD: begin
        a_re     = 1'b1;
        a_addr_c = src_la;
      end
      S_AD_R1: begin
        a_re     = 1'b1;
        a_addr_c = src_la;
      end
      S_AD_R2: begin
        a_re     = 1'b1;
        a_addr_c = dst_la;
        a_sel    = sel_b_dst ? 2'd1 : 2'd0;
      end
      S_AD_Q: begin
        q_re_c   = 1'b1;
        q_addr_c = 13'(d_qoff >> 3);
      end
      S_REQ: begin
        begin : req_wr
          logic [15:0] beat;
          logic [15:0] px;
          logic        half;
          logic [63:0] pay;
          logic [3:0]  sh;
          beat = c_p - 16'd6;
          if (wr16_r && !wrs16_r) begin
            px   = beat >> 1;
            half = beat[0];
          end
          else begin
            px   = beat;
            half = 1'b0;
          end
          if ((c_p >= 16'd6) && (c_p <= (16'd5 + wrbeats_r)) && ((ox0 + px) < ow_w)) begin
            pay = half ? out_hi[px[2:0]] : out_lo[px[2:0]];
            sh  = wpx[3:0];
            b_we_c    = 1'b1;
            b_addr_c  = {wpx[23:4], 4'h0};
            if (wrs16_r) begin
              b_wdata_c = {out_hi[px[2:0]], out_lo[px[2:0]]};
              b_wstrb_c = 16'hFFFF;
            end
            else begin
              b_wdata_c = (sh == 4'd8) ? {pay, 64'd0} : {64'd0, pay};
              b_wstrb_c = (sh == 4'd8) ? 16'hFF00 : 16'h00FF;
            end
          end
        end
      end
      S_PPACK: begin
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
      end
      S_CP_WR: begin
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
      end
      S_AD_WR3: begin
        begin : ad_wr
          logic [3:0] sh;
          sh = dst_la[3:0];
          b_we_c    = 1'b1;
          b_addr_c  = {dst_la[23:4], 4'h0};
          b_wdata_c = (sh == 4'd8) ? {ad_pack2, 64'd0} : {64'd0, ad_pack2};
          b_wstrb_c = (sh == 4'd8) ? 16'hFF00 : 16'h00FF;
        end
      end
      default: ;
    endcase
  end

  assign a_addr    = a_addr_c;
  assign w_addr    = w_addr_c;
  assign q_addr    = q_addr_q;
  assign q_re      = q_re_q;
  assign b_we      = b_we_q;
  assign b_addr    = b_addr_q;
  assign b_sel     = sel_b_dst ? 2'd1 : 2'd0;
  assign b_wdata_128 = b_wdata_q;
  assign b_wstrb   = b_wstrb_q;

  // ==========================================================================
  // 主时序块
  // ==========================================================================
  always @(posedge clk) begin
    if (rst) begin
      state    <= S_IDLE;
      cycles_r <= 32'd0;
      err_r    <= 8'h00;
      done_r   <= 1'b0;
      ld_ret_v <= 1'b0;
      b_we_q   <= 1'b0; b_addr_q <= 24'd0; b_wdata_q <= 128'd0; b_wstrb_q <= 16'd0;
      q_re_q   <= 1'b0; q_addr_q <= 13'd0;
      x_ld <= 16'sd0; x0_ld <= 16'sd0; dx_r <= 16'd1; y_ok_r <= 1'b0;
      y_ld <= 16'sd0;
      p3_ph <= 2'd0; p3w0 <= 128'd0; p3w1 <= 128'd0;
      mac_v1 <= 1'b0; mac_v2 <= 1'b0; mac_v3 <= 1'b0; mac_v4 <= 1'b0;
      q_iss  <= 5'd0;
      is_conv <= 1'b0; is_pool <= 1'b0; is_copy <= 1'b0; is_add <= 1'b0;
      f_dw <= 1'b0; f_leaky <= 1'b0; f_up2x <= 1'b0; f_p3 <= 1'b0; f_add_r <= 1'b0;
      c_ocb <= 16'd0; c_oy <= 16'd0; c_oxg <= 16'd0; c_ky <= 16'd0;
      c_icb <= 16'd0; c_m <= 16'd0; c_ld <= 16'd0; c_p <= 16'd0;
      c_iy  <= 16'd0; c_ix <= 16'd0; c_cb <= 16'd0;
      c_drn <= 3'd0; c_wr <= 2'd0; c_ql <= 1'b0;
      rd_half_s <= 1'b0; rd_half_d <= 1'b0;
      src_word_q <= 64'd0; cp_word_q <= 64'd0;
      wa_r <= 24'd0; qa_r <= 24'd0;
      row_base_a <= 24'd0; blk_base <= 24'd0; band_base <= 24'd0; la <= 24'd0;
      row_base_w <= 24'd0; wr_base <= 24'd0; wpx <= 24'd0;
      src_la <= 24'd0; dst_la <= 24'd0;
      row_base_a_n <= 24'd0; row_base_w_n <= 24'd0; nxt_sel <= 2'd0;
      sel_a_src <= 1'b0; sel_b_dst <= 1'b0;
      ic8_r <= 16'd0; oc8_r <= 16'd0; ocw_r <= 16'd8; oc_limit_r <= 16'd0;
      q_tot_r <= 5'd0; qb_w_r <= 5'd0; qm_w_r <= 5'd0;
      q_bias_w <= 13'd0; q_mpos_w <= 13'd0; q_tail_w <= 13'd0; rem_ch <= 16'd0;
      icb_n_r <= 16'd0; ld_count_r <= 16'd0; ld_m1_r <= 16'd0;
      row_step_a <= 24'd0; oy_step_a <= 24'd0; ox_step_a <= 24'd0;
      band_step_a <= 24'd0; band_ky_step <= 24'd0; base0_a <= 24'd0;
      row_step_w <= 24'd0; ox_step_w <= 24'd0; px_bytes <= 24'd0;
      w_p2 <= 24'd0; w_dgrp <= 24'd0; w_sub <= 24'd0;
      p1 <= 24'd0; p1_2 <= 24'd0; p1_3 <= 24'd0; p1_4 <= 24'd0;
      base0_t <= 24'd0; base0_t2 <= 24'd0;
      d_row_step <= 24'd0; d_row_step2 <= 24'd0;
      d_x_step <= 24'd0; up_px_row <= 24'd0; ups_dx <= 24'd0; cp_dst_pix <= 24'd0;
      p3_row <= 24'd0; p3_oy <= 24'd0; p3_ox <= 24'd0;
      pad_r <= 3'd0; oh_w <= 16'd0; ow_w <= 16'd0; st2_r <= 1'b0;
      zp_out <= 8'sd0; zp_in <= 8'sd0; shift_q <= 8'd0; leaky_q <= 1'b0;
      zp_s_r <= 8'sd0; zp_d_r <= 8'sd0; add_r_r <= 16'd0; kadd_r <= 8'd0;
      ad_pack_q <= 64'd0; ad_dst_q <= 64'd0;
      for (int l = 0; l < 8; l++) begin
        ad_delta[l] <= 9'sd0; ad_qq[l] <= 9'sd0; ad_mul[l] <= 32'sd0; ad_qs[l] <= 8'sd0;
      end
      wr16_r <= 1'b0; wrs16_r <= 1'b0; wrbeats_r <= 16'd8;
      for (int px = 0; px < PX; px++) begin
        out_lo[px] <= 64'sd0; out_hi[px] <= 64'sd0;
      end
      for (int l = 0; l < OCL; l++) begin
        y64_q[l] <= 48'sd0; y2_q[l] <= 48'sd0; bias_q[l] <= 32'sd0;
        mpos_q[l] <= 16'sd0; mneg_q[l] <= 16'sd0; mpos32[l] <= 32'sd0;
        mtmp[l] <= 32'sd0; acc_sel[l] <= 32'sd0; m_sel[l] <= 16'sd0;
        acc_hi[l] <= 17'sd0; acc_lo[l] <= 17'sd0;
        prod_hi[l] <= 32'sd0; prod_lo[l] <= 32'sd0;
        prod64[l] <= 48'sd0; wby_r[l] <= 16'sd0;
        for (int px = 0; px < PX; px++) begin
          acc[px][l] <= 32'sd0; a_pipe[px][l] <= 8'sd0;
          a_pipe1[px][l] <= 8'sd0;
          a_pipe2[px][l] <= 8'sd0; prod[px][l] <= 16'sd0; mx[px][l] <= -8'sd128;
        end
      end
      cr_ks_f <= 1'b0; cr_st_f <= 1'b0; cr_pad_f <= 1'b0; cr_ic_f <= 1'b0;
      cr_ih_f <= 1'b0; cr_dw_f <= 1'b0; cr_p3_f <= 1'b0;
      pl_ks_f <= 1'b0; pl_st_f <= 1'b0; pl_pad_f <= 1'b0; pl_ic_f <= 1'b0;
      cp_ic_f <= 1'b0; cp_hw_f <= 1'b0; cp_cn_f <= 1'b0;
      ad_ic_f <= 1'b0; ad_hw_f <= 1'b0; ad_oc_f <= 1'b0; ad_r_f <= 1'b0; d_oh_f <= 1'b0;
    end
    else begin
      done_r   <= 1'b0;
      ld_ret_v <= 1'b0;

      if ((state != S_IDLE) && (state != S_FIN)) cycles_r <= cycles_r + 32'd1;

      b_we_q    <= b_we_c;
      b_addr_q  <= b_addr_c;
      b_wdata_q <= b_wdata_c;
      b_wstrb_q <= b_wstrb_c;
      q_re_q    <= q_re_c;
      q_addr_q  <= q_addr_c;

      // ---------------- 地址/基址递增 ----------------
      if (state == S_LD && !f_p3) la <= la + band_step_a;
      if (state == S_MAC) wa_r <= wa_r + w_delta;

      if (state == S_REQ) begin
        if (c_p == 16'd5) wpx <= wr_base;
        else if ((c_p >= 16'd6) && (c_p < (16'd6 + wrbeats_r))) begin
          if (wr16_r && !wrs16_r)
            wpx <= wpx + (c_p[0] ? (px_bytes - 24'd8) : 24'd8);
          else
            wpx <= wpx + px_bytes;
        end
      end
      if (state == S_PMAX && (c_m == (ks16 - 16'd1))) wpx <= wr_base;
      if (state == S_PPACK) wpx <= wpx + px_bytes;

      // ---------------- band 装载返回 (标准路径) ----------------
      if (ld_ret_v) begin
        if (ld_fill_d) abuf[ld_j_d] <= {8{ld_fillbyte_d}};
        else           abuf[ld_j_d] <= ld_half_d ? a_rdata[127:64] : a_rdata[63:0];
      end

      // ---------------- MAC 流水 ----------------
      mac_v1 <= mac_issue;
      mac_v2 <= mac_v1;
      mac_v3 <= mac_v2;
      mac_v4 <= mac_v3;
      if (mac_issue) begin
        for (int px = 0; px < PX; px++)
          for (int oc = 0; oc < OCL; oc++) begin
            if (dense)
              a_pipe[px][oc] <= win_sel[px][sel_byte_base +: 8];
            else
              a_pipe[px][oc] <= (oc < 8) ? win_sel[px][oc*8 +: 8] : 8'sd0;
          end
      end
      if (LAT2) begin : g_wlat2
        if (mac_v1) begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              a_pipe1[px][oc] <= a_pipe[px][oc];
        end
        if (mac_v2) begin
          for (int oc = 0; oc < OCL; oc++)
            wby_r[oc] <= (dense || (oc < 8)) ? $signed(w_rdata[oc*8 +: 8]) : 16'sd0;
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              a_pipe2[px][oc] <= a_pipe1[px][oc];
        end
        if (mac_v3) begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              prod[px][oc] <= $signed(a_pipe2[px][oc]) * wby_r[oc];
        end
        if (mac_v4) begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              acc[px][oc] <= acc[px][oc] + {{16{prod[px][oc][15]}}, prod[px][oc]};
        end
      end
      else begin : g_wlat1
        if (mac_v1) begin
          for (int oc = 0; oc < OCL; oc++)
            wby_r[oc] <= (dense || (oc < 8)) ? $signed(w_rdata[oc*8 +: 8]) : 16'sd0;
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              a_pipe2[px][oc] <= a_pipe[px][oc];
        end
        if (mac_v2) begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              prod[px][oc] <= $signed(a_pipe2[px][oc]) * wby_r[oc];
        end
        if (mac_v3) begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              acc[px][oc] <= acc[px][oc] + {{16{prod[px][oc][15]}}, prod[px][oc]};
        end
      end

      if (win_adv) begin
        for (int i = 0; i < WINW-1; i++) bshift[i] <= bshift[i+1];
        bshift[WINW-1] <= abuf[15 + cur_kx[3:0]];
      end

      // ---------------- requant 5 级流水 ----------------
      if (state == S_REQ) begin
        if (c_p <= 16'd7) begin
          for (int l = 0; l < OCL; l++) begin
            acc_sel[l] <= acc[c_p[2:0]][l];
            m_sel[l]   <= (acc[c_p[2:0]][l] < 0) ? mneg_q[l] : mpos_q[l];
          end
        end
        if ((c_p >= 16'd1) && (c_p <= 16'd8)) begin
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
          end
        end
        if ((c_p >= 16'd3) && (c_p <= 16'd10)) begin
          for (int l = 0; l < OCL; l++)
            if (shift_q >= 8'd16)
              y64_q[l] <= (prod64[l] >>> 16) >>> shift_q[3:0];
            else
              y64_q[l] <= prod64[l] >>> shift_q[3:0];
        end
        if ((c_p >= 16'd4) && (c_p <= 16'd11)) begin
          for (int l = 0; l < OCL; l++) y2_q[l] <= y64_q[l] + {{40{zp_out[7]}}, zp_out};
        end
        if ((c_p >= 16'd5) && (c_p <= 16'd12)) begin
          out_lo[c_p[2:0] - 3'd5] <= rq_pack[63:0];
          out_hi[c_p[2:0] - 3'd5] <= rq_pack[127:64];
        end
      end

      // ================= FSM =================
      case (state)
        S_IDLE: begin
          if (start) begin
            d_op <= desc.op; d_flags <= desc.flags; d_ks <= desc.ks;
            d_st <= desc.stride; d_pad <= desc.pad;
            d_ih <= desc.ih; d_iw <= desc.iw; d_ic <= desc.ic; d_oc <= desc.oc;
            d_src <= desc.src; d_dst <= desc.dst;
            d_woff <= desc.woff; d_qoff <= desc.qoff;
            is_conv <= (desc.op == NN_OP_CONV);
            is_pool <= (desc.op == NN_OP_POOL);
            is_copy <= (desc.op == NN_OP_COPY);
            is_add  <= (desc.op == NN_OP_ADD);
            f_dw    <= desc.flags[NN_F_DEPTHWISE];
            f_leaky <= desc.flags[NN_F_LEAKY];
            f_up2x  <= desc.flags[NN_F_UP2X];
            f_p3    <= desc.flags[NN_F_PACKED3];
            f_add_r <= desc.flags[NN_F_ADD_R];
            cycles_r <= 32'd0; err_r <= 8'h00; q_iss <= 5'd0;
            state <= S_INIT;
          end
        end
        S_INIT: begin
          cr_ks_f <= cr_ks_bad; cr_st_f <= cr_st_bad; cr_pad_f <= cr_pad_bad;
          cr_ic_f <= cr_ic_bad; cr_ih_f <= cr_ih_bad; cr_dw_f <= cr_dw_bad;
          cr_p3_f <= cr_p3_bad;
          pl_ks_f <= pl_ks_bad; pl_st_f <= pl_st_bad; pl_pad_f <= pl_pad_bad;
          pl_ic_f <= pl_ic_bad;
          cp_ic_f <= cp_ic_bad; cp_hw_f <= cp_hw_bad; cp_cn_f <= cp_cn_bad;
          ad_ic_f <= ad_ic_bad; ad_hw_f <= ad_hw_bad; ad_oc_f <= ad_oc_bad;
          ad_r_f  <= ad_r_bad;
          d_oh_f  <= d_oh_bad;
          state   <= S_VCHK;
        end
        S_VCHK: begin
          if (init_err != 8'h00) begin
            err_r <= init_err;
            state <= S_FIN;
          end
          else begin
            c_ocb <= 16'd0; c_oy <= 16'd0; c_oxg <= 16'd0;
            c_ky <= 16'd0; c_icb <= 16'd0; c_m <= 16'd0;
            c_ld <= 16'd0; c_p <= 16'd0;
            c_iy <= 16'd0; c_ix <= 16'd0; c_cb <= 16'd0;
            c_drn <= 3'd0; c_wr <= 2'd0; p3_ph <= 2'd0;
            state <= S_CPREP;
          end
        end
        // ---- 常量预计算 (6 拍) ----
        S_CPREP: begin
          case (c_p)
            16'd0: begin
              pad_r <= pad_eff;
              ic8_r <= ic8;
              oc8_r <= oc8;
              st2_r <= (d_st == 2'd2);
              ocw_r <= dense ? 16'd16 : 16'd8;
            end
            16'd1: begin
              icb_n_r <= ic8_r >> 3;
              oc_limit_r <= is_pool  ? (ic8_r >> 3)
                          : dense    ? ((oc8_r + 16'd15) >> 4)
                                     : (oc8_r >> 3);
              if (is_copy) begin
                oh_w <= f_up2x ? (d_ih << 1) : d_ih;
                ow_w <= f_up2x ? (d_iw << 1) : d_iw;
              end
              else if (is_add) begin
                oh_w <= d_ih; ow_w <= d_iw;
              end
              else begin
                oh_w <= ((({1'b0, d_ih} + {13'd0, pad_r} + {13'd0, pad_r}) >= {12'd0, d_ks})
                         ? ((({1'b0, d_ih} + {13'd0, pad_r} + {13'd0, pad_r} - {12'd0, d_ks})
                             >> (st2_r ? 1 : 0)) + 16'd1) : 16'd1);
                ow_w <= ((({1'b0, d_iw} + {13'd0, pad_r} + {13'd0, pad_r}) >= {12'd0, d_ks})
                         ? ((({1'b0, d_iw} + {13'd0, pad_r} + {13'd0, pad_r} - {12'd0, d_ks})
                             >> (st2_r ? 1 : 0)) + 16'd1) : 16'd1);
              end
            end
            16'd2: begin
              row_step_a <= {8'd0, d_iw} * {8'd0, ic8_r};
              row_step_w <= ow_w * {8'd0, oc8_r};
              d_row_step <= {8'd0, d_iw} * {8'd0, oc8_r};
              px_bytes   <= is_pool ? {8'd0, ic8_r} : {8'd0, oc8_r};
            end
            16'd3: begin
              oy_step_a   <= st2_r ? (row_step_a << 1) : row_step_a;
              ox_step_a   <= st2_r ? ({8'd0, ic8_r} << 4) : ({8'd0, ic8_r} << 3);
              band_step_a <= (dense && (d_ks == 4'd1))
                             ? (st2_r ? ({8'd0, ic8_r} << 1) : {8'd0, ic8_r})
                             : {8'd0, ic8_r};
              band_ky_step<= (dense && (d_ks != 4'd1))
                             ? (row_step_a - {8'd0, ic8_r} + 24'd8) : row_step_a;
              base0_t     <= {21'd0, pad_r} * row_step_a;
              base0_t2    <= {21'd0, pad_r} * {8'd0, ic8_r};
              ox_step_w   <= px_bytes << 3;
              up_px_row   <= d_row_step << 1;
              ups_dx      <= {8'd0, oc8_r};
              w_p2        <= {8'd0, oc8_r};
              p1          <= {8'd0, ic8_r} * {8'd0, oc8_r};
              dx_r        <= (dense && (d_ks == 4'd1))
                             ? (st2_r ? 16'd2 : 16'd1) : 16'd1;
              ld_count_r  <= (dense && (d_ks == 4'd1)) ? 16'd8 : (7 * st16 + ks16);
              ld_m1_r     <= ((dense && (d_ks == 4'd1)) ? 16'd8 : (7 * st16 + ks16)) - 16'd1;
              // PACKED3 步长 (3B/像素): row = iw*3, oy = st*row, ox = 8*st*3
              p3_row      <= ({8'd0, d_iw} << 1) + {8'd0, d_iw};   // *3
            end
            16'd4: begin
              base0_a     <= d_src[23:0] - base0_t - base0_t2;
              cp_dst_pix  <= ({8'd0, oc8_r} - {8'd0, ic8_r}) + 24'd8;
              d_row_step2 <= (d_row_step << 1) + {8'd0, oc8_r} + 24'd8;
              d_x_step    <= {8'd0, oc8_r} + 24'd8;
              p1_2        <= p1 << 1;
              p1_3        <= p1 + (p1 << 1);
              p1_4        <= p1 << 2;
              w_dgrp      <= p1 - (({8'd0, oc8_r} << 3) - {8'd0, oc8_r});
              p3_oy       <= st2_r ? (p3_row << 1) : p3_row;
              p3_ox       <= st2_r ? 24'd48 : 24'd24;   // 8 px * stride * 3B
            end
            16'd5: begin
              // 首个 OC tile (c_ocb=0) 的 Q 参数打拍
              begin : qc0
                logic [15:0] a0;
                a0 = (oc8_r >= ocw_r) ? ocw_r : oc8_r;
                qb_w_r   <= 5'(a0 >> 1);
                qm_w_r   <= 5'(a0 >> 2);
                q_tot_r  <= 5'((a0 >> 1) + (a0 >> 2) + 16'd1);
                q_bias_w <= 13'(d_qoff[15:0] >> 3);
                q_mpos_w <= 13'((d_qoff[15:0] + (oc8_r << 2)) >> 3);
                q_tail_w <= 13'((d_qoff[15:0] + (oc8_r << 2) + (oc8_r << 1)) >> 3);
                rem_ch   <= (oc8_r > ocw_r) ? (oc8_r - ocw_r) : 16'd0;
              end
              w_sub       <= {8'd0, oc8_r}
                             - ((d_ks == 4'd1) ? 24'd0 :
                                (d_ks == 4'd2) ? p1 :
                                (d_ks == 4'd3) ? p1_2 :
                                (d_ks == 4'd4) ? p1_3 : p1_4);
              // PACKED3: 把 band 步长/行步长切到 packed 口径; base0 = src - pad*(row+3)
              row_base_a  <= f_p3 ? (d_src[23:0] - ({21'd0, pad_r} * (p3_row + 24'd3)))
                                  : base0_a;
              blk_base    <= f_p3 ? (d_src[23:0] - ({21'd0, pad_r} * (p3_row + 24'd3)))
                                  : base0_a;
              row_base_w  <= d_dst[23:0];
              wr_base     <= d_dst[23:0];
              src_la      <= d_src[23:0];
              dst_la      <= d_dst[23:0];
              sel_a_src   <= (d_src >= NN_B_OFF);
              sel_b_dst   <= (d_dst >= NN_B_OFF);
              c_p         <= 16'd0;
              if (is_conv) begin
                q_iss <= 5'd0;
                state <= S_Q;
              end
              else if (is_pool) state <= S_PINIT;
              else if (is_copy) state <= S_CP_RD;
              else              state <= f_add_r ? S_AD_Q : S_AD_R1;
            end
            default: ;
          endcase
          if (c_p != 16'd5) c_p <= c_p + 16'd1;
        end
        // ---- Q 参数装载 (q 口: 64b 字索引) ----
        S_Q: begin
          if (q_iss == 5'd0) begin
            for (int l = 0; l < OCL; l++) begin
              bias_q[l] <= 32'sd0;
              mpos_q[l] <= 16'sd0;
            end
          end
          if (16'(q_iss) < (q_tot + 16'd2)) q_iss <= q_iss + 5'd1;
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
          if (16'(q_iss) == (q_tot + 16'd1)) state <= S_QLOAD;
        end
        S_QLOAD: begin
          if (!c_ql) begin
            for (int l = 0; l < OCL; l++) begin
              mpos32[l] <= {{16{mpos_q[l][15]}}, mpos_q[l]};
              mtmp[l]   <= {{16{mpos_q[l][15]}}, mpos_q[l]} * 32'sd3277;
            end
            c_ql <= 1'b1;
          end
          else begin
            for (int l = 0; l < OCL; l++)
              mneg_q[l] <= leaky_q ? 16'((mtmp[l] + 32'sd16384) >>> 15) : mpos_q[l];
            c_ql  <= 1'b0;
            state <= S_BI;
          end
        end
        // ---- 累加器初始化 + 权重/激活基址 ----
        S_BI: begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              acc[px][oc] <= bias_q[oc];
          c_ky   <= 16'd0;
          c_icb  <= 16'd0;
          c_m    <= 16'd0;
          c_ld   <= 16'd0;
          p3_ph  <= 2'd0;
          icb_more_r <= (16'd1 < icb_n_r);
          wa_r   <= d_woff[23:0] + {8'd0, oc_base_w};
          if (f_p3) begin
            band_base <= blk_base;
            la        <= blk_base;
          end
          else begin
            band_base <= f_dw ? (blk_base + (c_ocb << 3)) : blk_base;
            la        <= f_dw ? (blk_base + (c_ocb << 3)) : blk_base;
          end
          x_ld   <= x0_c;
          x0_ld  <= x0_c;
          y_ld   <= y_ky0;
          y_ok_r <= (y_ky0 >= 0) && (y_ky0 < $signed(d_ih));
          state  <= S_LD;
        end
        // ---- band 装载 ----
        S_LD: begin
          if (f_p3) begin
            case (p3_ph)
              2'd0: begin
                p3_ph <= 2'd1;
              end
              2'd1: begin
                p3w0  <= a_rdata;
                p3_ph <= 2'd2;
              end
              default: begin
                p3w1 <= a_rdata;
                // 从 32B 窗口取 3 字节 (offset = la[3:0])
                begin : p3_emit
                  logic [7:0]  b0, b1, b2;
                  logic [4:0]  o5;
                  logic [7:0]  w32 [0:31];
                  for (int k = 0; k < 8; k++) begin
                    w32[k]      = p3w0[k*8 +: 8];
                    w32[k + 8]  = p3w0[(k+8)*8 +: 8];
                    w32[k + 16] = a_rdata[k*8 +: 8];        // A1 = 本拍读回
                    w32[k + 24] = a_rdata[(k+8)*8 +: 8];
                  end
                  o5 = {1'b0, la[3:0]};
                  b0 = w32[o5];
                  b1 = w32[o5 + 5'd1];
                  b2 = w32[o5 + 5'd2];
                  if (!ld_inb)
                    abuf[c_ld[4:0]] <= {5{ld_fill}};
                  else
                    abuf[c_ld[4:0]] <= {zp_in, zp_in, zp_in, zp_in, zp_in, b2, b1, b0};
                end
                la    <= la + 24'd3;
                x_ld  <= x_ld + $signed({15'd0, dx_r});
                c_ld  <= c_ld + 16'd1;
                p3_ph <= 2'd0;
                if (c_ld == ld_m1_r) state <= S_LDCAP;
              end
            endcase
          end
          else begin
            ld_j_d        <= c_ld[4:0];
            ld_fill_d     <= ~ld_inb;
            ld_half_d     <= la[3];
            ld_fillbyte_d <= ld_fill;
            ld_ret_v      <= 1'b1;
            x_ld          <= x_ld + $signed({15'd0, dx_r});
            if (c_ld == ld_m1_r) begin
              c_ld  <= 16'd0;
              state <= S_LDCAP;
            end
            else c_ld <= c_ld + 16'd1;
          end
        end
        S_LDCAP: begin
          c_m   <= 16'd0;
          c_ld  <= 16'd0;
          p3_ph <= 2'd0;
          if (f_p3) begin
            if (c_ky + 16'd1 < ks16) begin
              band_base <= band_base + p3_row;
              la        <= band_base + p3_row;
            end
            else begin
              band_base <= band_base;
              la        <= band_base;
            end
          end
          else if (dense && icb_more_r) begin
            band_base <= band_base + 24'd8;
            la        <= band_base + 24'd8;
          end
          else begin
            band_base <= band_base + band_ky_step;
            la        <= band_base + band_ky_step;
          end
          if (dense && (d_ks == 4'd1)) state <= S_MAC;
          else                        state <= S_WI;
        end
        S_WI: begin
          for (int i = 0; i < WINW; i++) bshift[i] <= abuf[i];
          c_m   <= 16'd0;
          state <= is_pool ? S_PMAX : S_MAC;
        end
        // ---- MAC ----
        S_MAC: begin
          if (dense) begin
            c_m <= c_m + 16'd1;
            if (c_m == ((ks16 << 3) - 16'd1)) begin
              c_m <= 16'd0;
              if (c_icb + 16'd1 < icb_n_r) begin
                c_icb <= c_icb + 16'd1;
                icb_more_r <= ((c_icb + 16'd2) < icb_n_r);
                c_ld  <= 16'd0;
                x_ld  <= x0_ld;
                y_ok_r <= (y_ld >= 0) && (y_ld < $signed(d_ih));
                state <= S_LD;
              end
              else if (c_ky + 16'd1 < ks16) begin
                c_ky  <= c_ky + 16'd1;
                c_icb <= 16'd0;
                icb_more_r <= (16'd1 < icb_n_r);
                c_ld  <= 16'd0;
                x_ld  <= x0_ld;
                y_ld  <= y_ld + 16'sd1;
                y_ok_r <= ((y_ld + 16'sd1) >= 0) && ((y_ld + 16'sd1) < $signed(d_ih));
                state <= S_LD;
              end
              else begin
                c_drn <= 3'd0;
                state <= S_DRN;
              end
            end
          end
          else begin
            c_m <= c_m + 16'd1;
            if (c_m == (ks16 - 16'd1)) begin
              c_m <= 16'd0;
              if (c_ky + 16'd1 < ks16) begin
                c_ky  <= c_ky + 16'd1;
                c_ld  <= 16'd0;
                x_ld  <= x0_ld;
                y_ld  <= y_ld + 16'sd1;
                y_ok_r <= ((y_ld + 16'sd1) >= 0) && ((y_ld + 16'sd1) < $signed(d_ih));
                state <= S_LD;
              end
              else begin
                c_drn <= 3'd0;
                state <= S_DRN;
              end
            end
          end
        end
        S_DRN: begin
          if (c_drn == 16'd0) begin
            wr16_r    <= wr_dense16;
            wrs16_r   <= single16;
            wrbeats_r <= req_beats;
          end
          if (c_drn == (DRNN - 1)) begin
            c_drn <= 3'd0;
            c_p   <= 16'd0;
            state <= S_REQ;
          end
          else c_drn <= c_drn + 3'd1;
        end
        S_REQ: begin
          if (c_p == (reqn_w - 16'd1)) begin
            c_p   <= 16'd0;
            state <= S_NEXT;
          end
          else c_p <= c_p + 16'd1;
        end
        // ---- 输出块推进 ----
        S_NEXT: begin
          row_base_a_n <= row_base_a + (f_p3 ? p3_oy : oy_step_a);
          row_base_w_n <= row_base_w + row_step_w;
          if ((ox0 + 16'd8) < ow_w)                nxt_sel <= 2'd0;
          else if ((c_oy + 16'd1) < oh_w)          nxt_sel <= 2'd1;
          else                                     nxt_sel <= 2'd2;
          state <= S_NEXT2;
        end
        S_NEXT2: begin
          case (nxt_sel)
            2'd0: begin
              c_oxg    <= c_oxg + 16'd1;
              blk_base <= blk_base + (f_p3 ? p3_ox : ox_step_a);
              wr_base  <= wr_base + ox_step_w;
              state    <= is_pool ? S_PINIT : S_BI;
            end
            2'd1: begin
              c_oxg      <= 16'd0;
              c_oy       <= c_oy + 16'd1;
              row_base_a <= row_base_a_n;
              blk_base   <= row_base_a_n;
              row_base_w <= row_base_w_n;
              wr_base    <= row_base_w_n;
              state      <= is_pool ? S_PINIT : S_BI;
            end
            default: begin
              c_oy  <= 16'd0;
              c_oxg <= 16'd0;
              c_ocb <= c_ocb + 16'd1;
              if (c_ocb + 16'd1 < oc_limit_r) begin
                row_base_a <= f_p3 ? (d_src[23:0] - ({21'd0, pad_r} * (p3_row + 24'd3)))
                                   : base0_a;
                blk_base   <= f_p3 ? (d_src[23:0] - ({21'd0, pad_r} * (p3_row + 24'd3)))
                                   : base0_a;
                row_base_w <= d_dst[23:0] + ((c_ocb + 16'd1) * ocw_r);
                wr_base    <= d_dst[23:0] + ((c_ocb + 16'd1) * ocw_r);
                begin : qc1
                  logic [15:0] rem_n, a_n;
                  a_n   = (rem_ch >= ocw_r) ? ocw_r : rem_ch;
                  rem_n = (rem_ch > a_n) ? (rem_ch - a_n) : 16'd0;
                  rem_ch   <= rem_n;
                  qb_w_r   <= 5'(a_n >> 1);
                  qm_w_r   <= 5'(a_n >> 2);
                  q_tot_r  <= 5'((a_n >> 1) + (a_n >> 2) + 16'd1);
                  q_bias_w <= q_bias_w + 13'(ocw_r >> 1);
                  q_mpos_w <= q_mpos_w + 13'(ocw_r >> 2);
                end
                if (is_pool) state <= S_PINIT;
                else begin
                  q_iss <= 5'd0;
                  state <= S_Q;
                end
              end
              else state <= S_FIN;
            end
          endcase
        end
        // ---- maxpool (8 lane) ----
        S_PINIT: begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              mx[px][oc] <= -8'sd128;
          c_ky   <= 16'd0;
          c_m    <= 16'd0;
          c_ld   <= 16'd0;
          c_p    <= 16'd0;
          band_base <= blk_base + (c_ocb << 3);
          la        <= blk_base + (c_ocb << 3);
          x_ld      <= x0_c;
          x0_ld     <= x0_c;
          y_ld      <= y_ky0;
          y_ok_r    <= (y_ky0 >= 0) && (y_ky0 < $signed(d_ih));
          state  <= S_LD;
        end
        S_PMAX: begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              if (oc < 8)
                if ($signed(win_sel[px][oc*8 +: 8]) > mx[px][oc])
                  mx[px][oc] <= $signed(win_sel[px][oc*8 +: 8]);
          c_m <= c_m + 16'd1;
          if (c_m == (ks16 - 16'd1)) begin
            c_m <= 16'd0;
            if (c_ky + 16'd1 < ks16) begin
              c_ky  <= c_ky + 16'd1;
              c_ld  <= 16'd0;
              x_ld  <= x0_ld;
              y_ld  <= y_ld + 16'sd1;
              y_ok_r <= ((y_ld + 16'sd1) >= 0) && ((y_ld + 16'sd1) < $signed(d_ih));
              state <= S_LD;
            end
            else begin
              c_p   <= 16'd0;
              state <= S_PPACK;
            end
          end
        end
        S_PPACK: begin
          if (c_p == 16'd7) begin
            c_p   <= 16'd0;
            state <= S_NEXT;
          end
          else c_p <= c_p + 16'd1;
        end
        // ---- COPY ----
        S_CP_RD: begin
          rd_half_s <= src_la[3];
          c_wr      <= 2'd0;
          state     <= S_CP_WR;
        end
        S_CP_WR: begin
          if (c_wr == 2'd0) cp_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];
          if (f_up2x && (c_wr != 2'd3)) begin
            c_wr <= c_wr + 2'd1;
          end
          else begin
            c_wr <= 2'd0;
            if (c_cb + 16'd1 < icb_n_r) begin
              c_cb   <= c_cb + 16'd1;
              src_la <= src_la + 24'd8;
              dst_la <= dst_la + 24'd8;
              state  <= S_CP_RD;
            end
            else if (c_ix + 16'd1 < d_iw) begin
              c_cb   <= 16'd0;
              c_ix   <= c_ix + 16'd1;
              src_la <= src_la + 24'd8;
              dst_la <= dst_la + (f_up2x ? d_x_step : cp_dst_pix);
              state  <= S_CP_RD;
            end
            else if (c_iy + 16'd1 < d_ih) begin
              c_cb   <= 16'd0;
              c_ix   <= 16'd0;
              c_iy   <= c_iy + 16'd1;
              src_la <= src_la + 24'd8;
              dst_la <= dst_la + (f_up2x ? d_row_step2 : cp_dst_pix);
              state  <= S_CP_RD;
            end
            else state <= S_FIN;
          end
        end
        // ---- ADD / ADD_R ----
        S_AD_Q: begin
          state <= S_AD_R1;
        end
        S_AD_R1: begin
          rd_half_s <= src_la[3];
          state <= S_AD_R2;
        end
        S_AD_R2: begin
          rd_half_d  <= dst_la[3];
          src_word_q <= ad_src_word;
          for (int l = 0; l < 8; l++)
            ad_qs[l] <= $signed(ad_src_word[l*8 +: 8]);
          // q 口打拍后: S_AD_Q 发出 -> 第 2 拍(本拍)数据有效
          if (f_add_r && (c_iy == 16'd0) && (c_ix == 16'd0) && (c_cb == 16'd0)) begin
            zp_s_r  <= q_rdata[7:0];
            zp_d_r  <= q_rdata[15:8];
            add_r_r <= {q_rdata[31:24], q_rdata[23:16]};
            kadd_r  <= q_rdata[39:32];
          end
          state      <= S_AD_WR;
        end
        S_AD_WR: begin
          begin : ad_qq_calc
            logic signed [7:0] qs;
            logic [63:0]       dword;
            dword = rd_half_d ? a_rdata[127:64] : a_rdata[63:0];
            ad_dst_q <= dword;
            for (int l = 0; l < 8; l++) begin
              qs = ad_qs[l];
              ad_qq[l]  <= (qs - zp_s_r);
              ad_mul[l] <= ($signed(qs) - $signed(zp_s_r)) * $signed({1'b0, add_r_r});
            end
          end
          state <= S_AD_WR2;
        end
        S_AD_WR2: begin
          begin : ad_delta_calc
            logic signed [31:0] p;
            for (int l = 0; l < 8; l++) begin
              if (f_add_r) begin
                p = ad_mul[l] >>> kadd_r;
                ad_delta[l] <= 9'(p[8:0]);
              end
              else begin
                ad_delta[l] <= ad_qq[l];
              end
            end
          end
          state <= S_AD_WR3;
        end
        S_AD_WR3: begin
          if (c_cb + 16'd1 < icb_n_r) begin
            c_cb   <= c_cb + 16'd1;
            src_la <= src_la + 24'd8;
            dst_la <= dst_la + 24'd8;
            state  <= S_AD_R1;
          end
          else if (c_ix + 16'd1 < d_iw) begin
            c_cb   <= 16'd0;
            c_ix   <= c_ix + 16'd1;
            src_la <= src_la + 24'd8;
            dst_la <= dst_la + 24'd8;
            state  <= S_AD_R1;
          end
          else if (c_iy + 16'd1 < d_ih) begin
            c_cb   <= 16'd0;
            c_ix   <= 16'd0;
            c_iy   <= c_iy + 16'd1;
            src_la <= src_la + 24'd8;
            dst_la <= dst_la + 24'd8;
            state  <= S_AD_R1;
          end
          else state <= S_FIN;
        end
        S_FIN: begin
          done_r <= 1'b1;
          state  <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  assign busy     = (state != S_IDLE);
  assign done     = done_r;
  assign cycles   = cycles_r;
  assign err_code = err_r;

endmodule
