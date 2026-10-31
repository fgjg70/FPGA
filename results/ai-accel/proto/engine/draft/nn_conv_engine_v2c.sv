`timescale 1ns/1ps

// ============================================================================
// nn_conv_engine.sv — int8 卷积引擎 (64 MAC/拍) —— **v2: 时序流水化 (T-accel-R2)**
// ----------------------------------------------------------------------------
// 契约: results/ai-accel/CONTRACT.md v0.4 (§5 量化 / §6 权重布局 / §7 Q 区 /
//       §8 激活布局 / §9.2 端口 / §11 op 精确语义)。
// **端口 / 权重-Q 布局 / 数值语义与 v1 完全一致**; v2 只改内部流水与地址生成。
//
// 【v2 为什么改】v1 在 150MHz 全实现里最差路径 24.5ns:
//   d_ks_reg → 32 位乘加 ((tap*ic8+ic)*oc8 等) → nn_mem BRAM 地址 (17 CARRY4 + 2 DSP);
//   次差: requant 的 8x8 acc 行选择 mux + 64 位乘/右移/饱和 全在一拍。
// v2 的拆法:
//   1) 权重地址 = 递增计数器: w += OC8 (普通拍) / OC8*(IC8-7) (kx 组边界) /
//      8*OC8 (换 icb) / OC8*(IC8*(K-1)+8) (换 ky); 这些步长在 S_CPREP 一次算好寄器。
//   2) 激活读地址 = 递增计数器: la += dx*IC8; band 基址 blk_base/band_base 由
//      S_NEXT / S_LDCAP / S_BI 里的小步进 (行步长/通道步长) 维护, 不再每拍乘。
//   3) 目的写地址 = 递增计数器 wpx, 基址 wr_base 由 S_NEXT 维护。
//   4) copy/add 的源/目的地址 = src_la/dst_la 递增计数器 (+8 / 行步长)。
//   5) Q 地址 = qa 计数器 + 两个预计算表头 qmb/qtb。
//   6) requant 拆 3 级流水: [acc 行选择 + M 选择] -> [32x32 乘] -> [右移+zp+饱和打包],
//      第 4 拍从寄存字驱动写口 (8 像素仍逐拍串行)。
//   7) 描述符合法性检查拆 2 级 (S_INIT 打 flag, S_VCHK 合并), 消掉 d_* → state 长链。
//
// 【v2 周期公式增量】(vs v1, 公式见 results/ai-accel/engine-report.md §3)
//   每个 op +6 拍 (S_VCHK 1 + S_CPREP 5; v1 的 S_INIT 仍保留);
//   每个 conv/dw 输出块 +2 拍 (requant 9 -> 11 拍)。
//
// 【数据流】(与 v1 相同)
//   PE 阵列: 8 像素 lane x 8 输出通道 lane = 64 MAC/拍
//   band 寄存器组 abuf (像素主序, 每字 = 像素的 8 通道) + bshift 移位窗口按 kx 抽出 8 像素
//   MAC 流水: issue(读权重) -> prod(8x8 乘寄存) -> acc(加), 2 拍延迟
//   requant: M_neg = leaky ? (M_pos*3277+16384)>>>15 : M_pos; out = clamp((acc*M)>>>SHIFT+zp_out)
// ============================================================================

module nn_conv_engine
  import nn_pkg::*;
#(
  parameter int OC_LANES = 8,
  parameter int PX_LANES = 8
)(
  input  logic         clk,
  input  logic         rst,
  input  nn_pkg::nn_desc_t desc,
  input  logic         start,
  output logic         busy,
  output logic         done,
  output logic [31:0]  cycles,
  output logic [7:0]   err_code,
  output logic         w_re,
  output logic [23:0]  w_addr,
  input  logic [63:0]  w_rdata,
  output logic [1:0]   a_sel,
  output logic         a_re,
  output logic [23:0]  a_addr,
  input  logic [127:0] a_rdata,
  output logic [1:0]   b_sel,
  output logic         b_we,
  output logic [23:0]  b_addr,
  output logic [63:0]  b_wdata
);

  localparam int PX    = PX_LANES;   // 8
  localparam int OCL   = OC_LANES;   // 8
  localparam int BANDW = 24;         // band 字数上限
  localparam int WINW  = 15;         // bshift 字数 = 7*stride+1 (stride=2)
  localparam int REQN  = 13;         // requant+write 拍数 (v2: 5 级流水 + 写尾)

  typedef enum logic [4:0] {
    S_IDLE, S_INIT, S_VCHK, S_CPREP, S_Q, S_QLOAD, S_BI, S_LD, S_LDCAP,
    S_WI, S_MAC, S_DRN, S_REQ, S_NEXT, S_NEXT2, S_PINIT, S_PMAX, S_PPACK,
    S_CP_RD, S_CP_WR, S_AD_R1, S_AD_R2, S_AD_WR, S_FIN
  } state_e;

  state_e state;

  // ==========================================================================
  // 锁存描述符 + 派生
  // ==========================================================================
  logic [1:0]  d_op;
  logic [4:0]  d_flags;
  logic [3:0]  d_ks;
  logic [1:0]  d_st;
  logic [2:0]  d_pad;
  logic [15:0] d_ih, d_iw, d_ic, d_oc;
  logic [31:0] d_src, d_dst, d_woff, d_qoff;

  wire is_conv = (d_op == NN_OP_CONV);
  wire is_pool = (d_op == NN_OP_POOL);
  wire is_copy = (d_op == NN_OP_COPY);
  wire is_add  = (d_op == NN_OP_ADD);
  wire f_dw    = d_flags[NN_F_DEPTHWISE];
  wire f_leaky = d_flags[NN_F_LEAKY];
  wire f_up2x  = d_flags[NN_F_UP2X];

  // 有效 pad (v0.4: desc.pad 3 位; pool 的 pad==0 时按 (K-1)/2 防御)
  wire [2:0] pad_eff = (is_pool && (d_pad == 3'd0))
      ? (({1'b0, d_ks} - 4'd1) >> 1) : d_pad;

  wire [15:0] ks16 = {12'd0, d_ks};
  wire [15:0] st16 = {14'd0, d_st};

  // 输出尺寸/pad: 打成寄存器 (S_CPREP c_p==1 用 pad_r 算)。
  // v2 综合实测: d_* -> pad_eff -> 共享加法器 -> ow_w -> DSP 乘法 -> 地址 曾是一条
  // 12.7ns 的链; 现在断成 [pad_r] -> [oh/ow] -> [*IC8/*OC8] 三级流水。
  logic [15:0] oh_w, ow_w;
  logic [2:0]  pad_r;
  logic        st2_r;   // stride==2, 打一拍给数据通路

  wire [15:0] ic8 = (d_ic + 16'd7) & 16'hFFF8;
  wire [15:0] oc8 = (d_oc + 16'd7) & 16'hFFF8;
  wire [15:0] icb_n = {10'd0, ic8[8:3]};      // IC8/8
  wire [15:0] ocb_n = {10'd0, oc8[8:3]};      // OC8/8
  wire [15:0] ld_count = (is_conv && !f_dw && (d_ks == 4'd1))
                         ? 16'd8 : (7 * st16 + ks16);
  wire        dense  = is_conv && !f_dw;

  // ==========================================================================
  // 描述符检查 (2 级流水)
  // ==========================================================================
  logic cr_ks_bad, cr_st_bad, cr_pad_bad, cr_ic_bad, cr_ih_bad, cr_dw_bad;
  logic pl_ks_bad, pl_st_bad, pl_pad_bad, pl_ic_bad;
  logic cp_ic_bad, cp_hw_bad, cp_cn_bad;
  logic ad_ic_bad, ad_hw_bad, ad_oc_bad;
  logic d_oh_bad;

  always_comb begin
    cr_ks_bad = !(d_ks == 4'd1 || d_ks == 4'd3 || d_ks == 4'd5);
    cr_st_bad = !(d_st == 2'd1 || d_st == 2'd2);
    cr_pad_bad= (d_pad > (ks16 >> 1));
    cr_ic_bad = (d_ic == 16'd0 || d_oc == 16'd0);
    cr_ih_bad = (d_ih == 16'd0 || d_iw == 16'd0);
    cr_dw_bad = f_dw && (d_oc != d_ic);
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
    d_oh_bad  = (({1'b0, d_ih} + (pad_eff << 1)) < {13'd0, d_ks}) ||
                (({1'b0, d_iw} + (pad_eff << 1)) < {13'd0, d_ks});
  end

  logic cr_ks_f, cr_st_f, cr_pad_f, cr_ic_f, cr_ih_f, cr_dw_f;
  logic pl_ks_f, pl_st_f, pl_pad_f, pl_ic_f;
  logic cp_ic_f, cp_hw_f, cp_cn_f, ad_ic_f, ad_hw_f, ad_oc_f, d_oh_f;
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
  logic [3:0]  q_iss;
  logic [1:0]  c_wr;
  logic        c_ql;                 // S_QLOAD 2 拍阶段
  logic        ld_ret_v, ld_fill_d, ld_half_d;
  logic [4:0]  ld_j_d;
  logic [7:0]  ld_fillbyte_d;
  logic        mac_v1, mac_v2, mac_v3;
  logic signed [15:0] wby_r [0:OCL-1];   // 权重字节打一拍 (BRAM 输出 -> DSP 之间)
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
  logic signed [7:0]  a_pipe2[0:PX-1][0:OCL-1];   // 与 wby_r 对齐的 A 操作数
  logic signed [15:0] prod   [0:PX-1][0:OCL-1];

  logic signed [31:0] bias_q [0:OCL-1];
  logic signed [15:0] mpos_q [0:OCL-1];
  logic signed [31:0] mneg_q [0:OCL-1];
  logic signed [31:0] mpos32 [0:OCL-1];
  logic signed [31:0] mtmp   [0:OCL-1];
  logic signed [7:0]  zp_out, zp_in;
  logic [7:0]         shift_q;
  logic               leaky_q;

  logic signed [7:0]  mx [0:PX-1][0:OCL-1];

  // requant 3 级流水
  logic signed [31:0] acc_sel [0:OCL-1];
  logic signed [31:0] m_sel   [0:OCL-1];
  logic signed [63:0] prod64  [0:OCL-1];
  // v2c (草稿): |acc*M| < 2^46 (acc int32 x M int16), 右移只减不增, 所以 48 位足够;
  // 用 48 位代替 64 位, 归约/比较/寄存器都变窄。
  logic signed [47:0] y64_q   [0:OCL-1];      // 右移后 (第 3 级)
  logic signed [47:0] y2_q    [0:OCL-1];      // +zp 后 (第 4 级)
  logic [63:0]        out_word;

  // ==========================================================================
  // 预计算步长 (S_CPREP 5 拍算好, 之后只做递增)
  // ==========================================================================
  logic [15:0] ic8_r, oc8_r;
  logic [15:0] oc_limit_r;           // 通道块数 = (pool? IC8/8 : OC8/8) 打一拍
  logic [23:0] row_step_a;    // 激活行步长 = iw*IC8
  logic [23:0] oy_step_a;     // 激活输出行步长 = stride*row_step_a
  logic [23:0] ox_step_a;     // 激活输出 x 组步长 = 8*stride*IC8
  logic [23:0] band_step_a;   // band 内每字步长 = dx*IC8
  logic [23:0] band_ky_step;  // 换 ky 时 band 基址增量 (dense: row_step-IC8+8; 其它: row_step)
  logic [23:0] base0_a;       // blk_base 初值 (oy=oxg=0)
  logic [23:0] row_step_w;    // 目的行步长 = ow*px_bytes
  logic [23:0] ox_step_w;     // 目的 x 组步长 = 8*px_bytes
  logic [23:0] px_bytes;      // conv/dw: OC8; pool: IC8
  logic [23:0] w_p2, w_dgrp, w_sub;
  logic [23:0] p1;            // IC8*OC8 (一次乘法, 其余步长用加/移位)
  logic [23:0] p1_2, p1_3, p1_4;
  logic [23:0] d_row_step;    // copy/add 目的行步长 = iw*OC8
  logic [23:0] d_row_step2;   // upsample 目的行步长 (跨 2 行) = 2*iw*OC8
  logic [23:0] d_x_step;      // upsample 目的 x 步长 (下一源像素) = OC8+8
  logic [23:0] cp_dst_pix;    // copy 目的像素步长 = OC8-IC8+8
  logic [23:0] up_px_row;     // upsample 写 dy 偏移 = 2*iw*OC8
  logic [23:0] ups_dx;        // upsample 写 dx 偏移 = OC8

  // 地址计数器 / 基址
  logic [23:0] wa_r;                 // 权重读地址
  logic [23:0] qa_r, qmb_r, qtb_r;   // Q 当前地址 / M_pos 表头 / tail 表头
  logic [23:0] row_base_a;           // 激活行基址 (oxg=0)
  logic [23:0] blk_base;             // 当前输出块激活基址 (oxg 组)
  logic [23:0] band_base;            // 当前 band 基址
  logic [23:0] la;                   // 激活读地址计数器
  logic [23:0] row_base_w;           // 目的行基址 (oxg=0, 含 ocb 通道偏移)
  logic [23:0] wr_base;              // 当前输出块目的基址
  logic [23:0] wpx;                  // 目的写地址计数器
  logic [23:0] src_la, dst_la;       // copy/add 源/目的地址计数器
  logic [23:0] row_base_a_n, row_base_w_n;  // S_NEXT 预加 (S_NEXT2 用)
  logic [1:0]  nxt_sel;                     // 0=换 x 组 1=换行 2=换 oc tile/结束
  logic        sel_a_src, sel_b_dst; // a_sel/b_sel

  // ==========================================================================
  // 组合请求 (源全部是寄存器, 无乘法)
  // ==========================================================================
  logic        w_re_c, a_re_c, b_we_c;
  logic        b_we_q;                 // 写口打一拍 (缩短 valid/地址 -> BRAM 的链)
  logic [23:0] b_addr_q;
  logic [63:0] b_wdata_q;
  logic [23:0] w_addr_c, a_addr_c, b_addr_c;
  logic [63:0] b_wdata_c;

  wire [15:0] ox0 = c_oxg << 3;

  // band 装载当前索引的合法性 (路径: 计数器 -> 小加/比较 -> a_re, 约 5 级)
  // band 装载位置: x 用递增计数器 (每拍 +dx_r), y 是否在界内用寄存标志 y_ok_r。
  // 旧写法每拍算 (y*iw+x) 的 18 位乘法/加法再比较, 综合出 8ns 的链; 现在
  // a_re/fill 只依赖 [x_ld FF] -> 比较 -> a_re, 2~3 级。
  logic signed [15:0] x_ld;          // 当前 band 当前字的输入 x
  logic signed [15:0] x0_ld;         // 每个 band 的起始 x
  logic [15:0]        dx_r;          // x 步长 (1 或 stride)
  logic               y_ok_r;        // 当前 band 的 y 是否在张量内
  logic signed [15:0] y_ld;          // 当前 band 的 y (每换一行 +1)

  wire signed [15:0] x0_c = $signed({3'd0, ox0}) * (st2_r ? 16'sd2 : 16'sd1)
                            - $signed({13'd0, pad_r});
  wire signed [15:0] y_ky0 = $signed({2'b0, c_oy}) * (st2_r ? 16'sd2 : 16'sd1)
                             - $signed({13'd0, pad_r});
  wire signed [15:0] y_1 = y_ld + 16'sd1;

  function automatic logic y_ok_of(input logic signed [15:0] yv,
                                   input logic [15:0] ihv);
    y_ok_of = (yv >= 0) && (yv < $signed(ihv));
  endfunction

  wire ld_inb = y_ok_r && (x_ld >= 0) && (x_ld < $signed(d_iw));
  wire [7:0] ld_fill = is_pool ? 8'h80 : zp_in;

  // 权重地址增量
  // 权重地址增量 (地址 = ((ky*K+kx)*IC8 + icb*8 + c)*OC8 + woff + ocb*8):
  //   · 普通拍/kx 组内: +OC8
  //   · kx 组边界 (kx->kx+1, ic 回到 icb*8): +OC8*(IC8-7)
  //   · 子块边界 (c_m==8K-1):
  //       icb+1 < ICB : 回到本 ky 的 tap0/icb+1: +OC8*(1-(K-1)*IC8)  (可为负)
  //       否则换 ky   : +OC8
  wire [23:0] w_delta = (c_m == ((ks16 << 3) - 16'd1))
                        ? ((c_icb + 16'd1 < icb_n) ? w_sub : w_p2)
                        : (((c_m[2:0] == 3'd7) && ((c_m[7:3] + 16'd1) < ks16))
                           ? w_dgrp : w_p2);

  // requant 打包 (第 4 级): 对已右移的 y64_q 做 +zp / 饱和 / 打包
  logic [63:0] rq_pack;
  always_comb begin
    logic signed [47:0] y2;
    logic [7:0] bb;
    logic fits;
    rq_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      y2   = y2_q[l];
      // |y2| < 2^47  =>  bits[63:47] 是 sign extension, 只判 [47:7] 全相等即可
      fits = (&y2[47:7]) || (~|y2[47:7]);
      if (fits) bb = y2[7:0];
      else      bb = y2[47] ? 8'h80 : 8'h7F;
      if ((c_ocb * 16'd8 + l) >= d_oc) bb = zp_out;
      rq_pack[l*8 +: 8] = bb;
    end
  end

  // maxpool 打包
  logic [63:0] pool_pack;
  always_comb begin
    logic [7:0] bb;
    pool_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      bb = mx[c_p[2:0]][l];
      if ((c_ocb * 16'd8 + l) >= d_ic) bb = 8'h00;
      pool_pack[l*8 +: 8] = bb;
    end
  end

  // ADD 饱和打包
  wire [63:0] ad_dst_word = rd_half_d ? a_rdata[127:64] : a_rdata[63:0];
  logic [63:0] ad_pack;
  always_comb begin
    logic signed [8:0] s;
    ad_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      s = $signed({src_word_q[l*8 + 7], src_word_q[l*8 +: 8]})
        + $signed({ad_dst_word[l*8 + 7], ad_dst_word[l*8 +: 8]});
      if (s > 9'sd127)       ad_pack[l*8 +: 8] = 8'h7F;
      else if (s < -9'sd128) ad_pack[l*8 +: 8] = 8'h80;
      else                   ad_pack[l*8 +: 8] = s[7:0];
    end
  end

  // A 操作数窗口
  logic [63:0] win_sel [0:PX-1];
  always_comb begin
    for (int px = 0; px < PX; px++) begin
      if (dense && (d_ks == 4'd1))
        win_sel[px] = abuf[px];
      else
        win_sel[px] = st2_r ? bshift[2*px] : bshift[px];
    end
  end
  wire [5:0] sel_byte_base = {c_m[2:0], 3'b000};
  wire [3:0] cur_kx = dense ? c_m[7:3] : c_m[3:0];
  wire win_adv = (state == S_MAC)
      ? (dense ? ((c_m[2:0] == 3'd7) && ((c_m[7:3] + 16'd1) < ks16))
               : ((c_m + 16'd1) < ks16))
      : ((state == S_PMAX) ? ((c_m + 16'd1) < ks16) : 1'b0);
  wire mac_issue = (state == S_MAC);


  // ==========================================================================
  // 端口组合驱动 (无乘法; 路径 = 寄存器 -> 少量 mux/add -> 端口)
  // ==========================================================================
  always_comb begin
    w_re     = 1'b0;
    w_addr_c = wa_r;
    a_re     = 1'b0;
    a_addr_c = la;
    a_sel    = sel_a_src ? 2'd1 : 2'd0;
    b_we_c   = 1'b0;
    b_addr_c = wpx;
    b_wdata_c= out_word;

    if (state == S_Q) begin
      w_re     = (q_iss <= 4'd6);
      w_addr_c = qa_r;
    end
    else if (state == S_MAC) begin
      w_re     = 1'b1;
      w_addr_c = wa_r;
    end

    case (state)
      S_LD: begin
        a_re     = ld_inb;
        a_addr_c = la;
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
      S_REQ: begin
        if ((c_p >= 16'd5) && (c_p <= 16'd12) && ((ox0 + (c_p - 16'd5)) < ow_w)) begin
          b_we_c    = 1'b1;
          b_addr_c  = wpx;
          b_wdata_c = out_word;
        end
      end
      S_PPACK: begin
        if ((ox0 + c_p) < ow_w) begin
          b_we_c    = 1'b1;
          b_addr_c  = wpx;
          b_wdata_c = pool_pack;
        end
      end
      S_CP_WR: begin
        b_we_c    = 1'b1;
        b_addr_c  = dst_la;
        b_wdata_c = (c_wr == 2'd0)
                    ? (rd_half_s ? a_rdata[127:64] : a_rdata[63:0]) : cp_word_q;
        if (f_up2x)
          b_addr_c = dst_la + (c_wr[1] ? up_px_row : 24'd0)
                            + (c_wr[0] ? ups_dx   : 24'd0);
      end
      S_AD_WR: begin
        b_we_c    = 1'b1;
        b_addr_c  = dst_la;
        b_wdata_c = ad_pack;
      end
      default: ;
    endcase
  end

  assign a_addr  = a_addr_c;
  assign w_addr  = w_addr_c;
  assign b_we    = b_we_q;
  assign b_addr  = b_addr_q;
  assign b_sel   = sel_b_dst ? 2'd1 : 2'd0;
  assign b_wdata = b_wdata_q;

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
      b_we_q <= 1'b0; b_addr_q <= 24'd0; b_wdata_q <= 64'd0;
      x_ld <= 16'sd0; x0_ld <= 16'sd0; dx_r <= 16'd1; y_ok_r <= 1'b0;
      y_ld <= 16'sd0;
      mac_v1   <= 1'b0;
      mac_v2   <= 1'b0;
      mac_v3   <= 1'b0;
      q_iss    <= 4'd0;
      c_ocb <= 16'd0; c_oy  <= 16'd0; c_oxg <= 16'd0; c_ky  <= 16'd0;
      c_icb <= 16'd0; c_m   <= 16'd0; c_ld  <= 16'd0; c_p   <= 16'd0;
      c_iy  <= 16'd0; c_ix  <= 16'd0; c_cb  <= 16'd0;
      c_drn <= 3'd0;  c_wr  <= 2'd0;  c_ql <= 1'b0;
      rd_half_s <= 1'b0; rd_half_d <= 1'b0;
      src_word_q <= 64'd0; cp_word_q <= 64'd0;
      wa_r <= 24'd0; qa_r <= 24'd0; qmb_r <= 24'd0; qtb_r <= 24'd0;
      row_base_a <= 24'd0; blk_base <= 24'd0; band_base <= 24'd0; la <= 24'd0;
      row_base_w <= 24'd0; wr_base <= 24'd0; wpx <= 24'd0;
      src_la <= 24'd0; dst_la <= 24'd0;
      row_base_a_n <= 24'd0; row_base_w_n <= 24'd0; nxt_sel <= 2'd0;
      sel_a_src <= 1'b0; sel_b_dst <= 1'b0;
      ic8_r <= 16'd0; oc8_r <= 16'd0; oc_limit_r <= 16'd0;
      row_step_a <= 24'd0; oy_step_a <= 24'd0; ox_step_a <= 24'd0;
      band_step_a<= 24'd0; band_ky_step <= 24'd0; base0_a <= 24'd0;
      row_step_w <= 24'd0; ox_step_w <= 24'd0; px_bytes <= 24'd0;
      w_p2 <= 24'd0; w_dgrp <= 24'd0; w_sub <= 24'd0;
      p1 <= 24'd0; p1_2 <= 24'd0; p1_3 <= 24'd0; p1_4 <= 24'd0;
      d_row_step <= 24'd0; d_row_step2 <= 24'd0;
      d_x_step <= 24'd0; up_px_row <= 24'd0; ups_dx <= 24'd0; cp_dst_pix <= 24'd0;
      pad_r <= 3'd0; oh_w <= 16'd0; ow_w <= 16'd0; st2_r <= 1'b0;
      for (int l = 0; l < OCL; l++) begin y64_q[l] <= 48'sd0; y2_q[l] <= 48'sd0; end
      cr_ks_f <= 1'b0; cr_st_f <= 1'b0; cr_pad_f <= 1'b0; cr_ic_f <= 1'b0;
      cr_ih_f <= 1'b0; cr_dw_f <= 1'b0;
      pl_ks_f <= 1'b0; pl_st_f <= 1'b0; pl_pad_f <= 1'b0; pl_ic_f <= 1'b0;
      cp_ic_f <= 1'b0; cp_hw_f <= 1'b0; cp_cn_f <= 1'b0;
      ad_ic_f <= 1'b0; ad_hw_f <= 1'b0; ad_oc_f <= 1'b0; d_oh_f <= 1'b0;
    end
    else begin
      done_r   <= 1'b0;
      ld_ret_v <= 1'b0;

      if ((state != S_IDLE) && (state != S_FIN)) cycles_r <= cycles_r + 32'd1;

      // 写口打一拍 (写延迟 1 拍对 FSM 不可见; 写落在下一拍, S_FIN 时已落地)
      b_we_q    <= b_we_c;
      b_addr_q  <= b_addr_c;
      b_wdata_q <= b_wdata_c;

      // ---------------- 地址/基址递增 ----------------
      if (state == S_LD) la <= la + band_step_a;
      if (state == S_MAC) wa_r <= wa_r + w_delta;

      if (state == S_Q) begin
        case (q_iss)
          4'd0, 4'd1, 4'd2: qa_r <= qa_r + 24'd8;
          4'd3:             qa_r <= qmb_r;
          4'd4:             qa_r <= qa_r + 24'd8;
          4'd5:             qa_r <= qtb_r;
          default:          qa_r <= qa_r;
        endcase
      end

      if (state == S_REQ) begin
        if (c_p == 16'd4) wpx <= wr_base;
        if ((c_p >= 16'd5) && (c_p <= 16'd12)) wpx <= wpx + px_bytes;
      end
      if (state == S_PMAX && (c_m == (ks16 - 16'd1))) wpx <= wr_base;
      if (state == S_PPACK) wpx <= wpx + px_bytes;

      // ---------------- band 装载返回 ----------------
      if (ld_ret_v) begin
        if (ld_fill_d) abuf[ld_j_d] <= {8{ld_fillbyte_d}};
        else           abuf[ld_j_d] <= ld_half_d ? a_rdata[127:64] : a_rdata[63:0];
      end

      // ---------------- MAC 流水 ----------------
      mac_v1 <= mac_issue;
      mac_v2 <= mac_v1;
      mac_v3 <= mac_v2;
      if (mac_issue) begin
        for (int px = 0; px < PX; px++)
          for (int oc = 0; oc < OCL; oc++)
            a_pipe[px][oc] <= dense ? win_sel[px][sel_byte_base +: 8]
                                    : win_sel[px][oc*8 +: 8];
      end
      if (mac_v1) begin
        for (int oc = 0; oc < OCL; oc++) wby_r[oc] <= $signed(w_rdata[oc*8 +: 8]);
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

      if (win_adv) begin
        for (int i = 0; i < WINW-1; i++) bshift[i] <= bshift[i+1];
        bshift[WINW-1] <= abuf[15 + cur_kx[3:0]];
      end

      // ---------------- requant 3 级流水 ----------------
      if (state == S_REQ) begin
        if (c_p <= 16'd7) begin
          for (int l = 0; l < OCL; l++) begin
            acc_sel[l] <= acc[c_p[2:0]][l];
            m_sel[l]   <= (acc[c_p[2:0]][l] < 0) ? mneg_q[l]
                                                 : {{16{mpos_q[l][15]}}, mpos_q[l]};
          end
        end
        if ((c_p >= 16'd1) && (c_p <= 16'd8)) begin
          for (int l = 0; l < OCL; l++)
            prod64[l] <= $signed(acc_sel[l]) * $signed(m_sel[l]);
        end
        if ((c_p >= 16'd2) && (c_p <= 16'd9)) begin
          for (int l = 0; l < OCL; l++)
            y64_q[l] <= prod64[l] >>> shift_q;
        end
        if ((c_p >= 16'd3) && (c_p <= 16'd10)) begin
          for (int l = 0; l < OCL; l++)
            y2_q[l] <= y64_q[l] + {{40{zp_out[7]}}, zp_out};
        end
        if ((c_p >= 16'd4) && (c_p <= 16'd11)) out_word <= rq_pack;
      end

      // ================= FSM =================
      case (state)
        S_IDLE: begin
          if (start) begin
            d_op    <= desc.op;
            d_flags <= desc.flags;
            d_ks    <= desc.ks;
            d_st    <= desc.stride;
            d_pad   <= desc.pad;
            d_ih    <= desc.ih;
            d_iw    <= desc.iw;
            d_ic    <= desc.ic;
            d_oc    <= desc.oc;
            d_src   <= desc.src;
            d_dst   <= desc.dst;
            d_woff  <= desc.woff;
            d_qoff  <= desc.qoff;
            cycles_r<= 32'd0;
            err_r   <= 8'h00;
            q_iss   <= 4'd0;
            state   <= S_INIT;
          end
        end
        // ---- 检查第 1 级: 逐条打 flag ----
        S_INIT: begin
          cr_ks_f <= cr_ks_bad; cr_st_f <= cr_st_bad; cr_pad_f <= cr_pad_bad;
          cr_ic_f <= cr_ic_bad; cr_ih_f <= cr_ih_bad; cr_dw_f <= cr_dw_bad;
          pl_ks_f <= pl_ks_bad; pl_st_f <= pl_st_bad; pl_pad_f <= pl_pad_bad;
          pl_ic_f <= pl_ic_bad;
          cp_ic_f <= cp_ic_bad; cp_hw_f <= cp_hw_bad; cp_cn_f <= cp_cn_bad;
          ad_ic_f <= ad_ic_bad; ad_hw_f <= ad_hw_bad; ad_oc_f <= ad_oc_bad;
          d_oh_f  <= d_oh_bad;
          state   <= S_VCHK;
        end
        // ---- 检查第 2 级: 合并 + 决定 ----
        S_VCHK: begin
          if (init_err != 8'h00) begin
            err_r <= init_err;
            state <= S_FIN;
          end
          else begin
            c_ocb <= 16'd0; c_oy  <= 16'd0; c_oxg <= 16'd0;
            c_ky  <= 16'd0; c_icb <= 16'd0; c_m   <= 16'd0;
            c_ld  <= 16'd0; c_p   <= 16'd0;
            c_iy  <= 16'd0; c_ix  <= 16'd0; c_cb  <= 16'd0;
            c_drn <= 3'd0;  c_wr  <= 2'd0;
            state <= S_CPREP;
          end
        end
        // ---- 常量预计算 (6 拍流水; c_p 当阶段计数) ----
        // 每拍只做"一步"运算: 小比较/加法 -> 一级乘法 -> 加法 -> 乘法 -> 组合 -> 初值,
        // 保证 d_* 到任何常量寄存器最多 1 个乘法器 + 1 个加法器。
        S_CPREP: begin
          case (c_p)
            16'd0: begin
              pad_r <= pad_eff;              // d_pad/d_ks -> FF (2 级)
              ic8_r <= ic8;
              oc8_r <= oc8;
              st2_r <= (d_st == 2'd2);
            end
            16'd1: begin
              oc_limit_r <= is_pool ? (ic8_r >> 3) : (oc8_r >> 3);
              // 输出尺寸 (pad_r 已寄存, 这里只有加法/移位/比较)
              if (is_copy) begin
                oh_w <= f_up2x ? (d_ih << 1) : d_ih;
                ow_w <= f_up2x ? (d_iw << 1) : d_iw;
              end
              else if (is_add) begin
                oh_w <= d_ih;
                ow_w <= d_iw;
              end
              else begin
                oh_w <= ((({1'b0, d_ih} + {13'd0, pad_r} + {13'd0, pad_r}) >=
                          {12'd0, d_ks})
                         ? ((({1'b0, d_ih} + {13'd0, pad_r} + {13'd0, pad_r} - {12'd0, d_ks})
                             >> (st2_r ? 1 : 0)) + 16'd1) : 16'd1);
                ow_w <= ((({1'b0, d_iw} + {13'd0, pad_r} + {13'd0, pad_r}) >=
                          {12'd0, d_ks})
                         ? ((({1'b0, d_iw} + {13'd0, pad_r} + {13'd0, pad_r} - {12'd0, d_ks})
                             >> (st2_r ? 1 : 0)) + 16'd1) : 16'd1);
              end
            end
            16'd2: begin
              // 一级乘法 (2 个 DSP 并行)
              row_step_a  <= {8'd0, d_iw} * {8'd0, ic8_r};
              row_step_w  <= ow_w * {8'd0, oc8_r};
              d_row_step  <= {8'd0, d_iw} * {8'd0, oc8_r};
              px_bytes    <= is_pool ? {8'd0, ic8_r} : {8'd0, oc8_r};
            end
            16'd3: begin
              // 只有移位/加法
              oy_step_a   <= st2_r ? (row_step_a << 1) : row_step_a;
              ox_step_a   <= st2_r ? ({8'd0, ic8_r} << 4) : ({8'd0, ic8_r} << 3);
              band_step_a <= (dense && (d_ks == 4'd1))
                             ? (st2_r ? ({8'd0, ic8_r} << 1) : {8'd0, ic8_r})
                             : {8'd0, ic8_r};
              band_ky_step<= (dense && (d_ks != 4'd1))
                             ? (row_step_a - {8'd0, ic8_r} + 24'd8) : row_step_a;
              base0_a     <= d_src[23:0]
                             - ({21'd0, pad_r} * (row_step_a + {8'd0, ic8_r}));
              ox_step_w   <= px_bytes << 3;
              up_px_row   <= d_row_step << 1;
              ups_dx      <= {8'd0, oc8_r};
              w_p2        <= {8'd0, oc8_r};
              p1          <= {8'd0, ic8_r} * {8'd0, oc8_r};
              dx_r        <= (dense && (d_ks == 4'd1))
                             ? (st2_r ? 16'd2 : 16'd1) : 16'd1;
            end
            16'd4: begin
              // 再一级乘法 (与地址无关的常量)
              cp_dst_pix  <= ({8'd0, oc8_r} - {8'd0, ic8_r}) + 24'd8;
              d_row_step2 <= (d_row_step << 1) + {8'd0, oc8_r} + 24'd8;
              d_x_step    <= {8'd0, oc8_r} + 24'd8;
              p1_2        <= p1 << 1;
              p1_3        <= p1 + (p1 << 1);
              p1_4        <= p1 << 2;
              w_dgrp      <= p1 - (({8'd0, oc8_r} << 3) - {8'd0, oc8_r});
            end
            16'd5: begin
              // w_sub = OC8*(1-(K-1)*IC8) (24 位补码, 加法回绕即可) + 初值
              w_sub       <= {8'd0, oc8_r}
                             - ((d_ks == 4'd1) ? 24'd0 :
                                (d_ks == 4'd2) ? p1 :
                                (d_ks == 4'd3) ? p1_2 :
                                (d_ks == 4'd4) ? p1_3 : p1_4);
              row_base_a  <= base0_a;
              blk_base    <= base0_a;
              row_base_w  <= d_dst[23:0];
              wr_base     <= d_dst[23:0];
              src_la      <= d_src[23:0];
              dst_la      <= d_dst[23:0];
              sel_a_src   <= (d_src >= NN_B_OFF);
              sel_b_dst   <= (d_dst >= NN_B_OFF);
              qa_r        <= d_qoff[23:0];
              qmb_r       <= d_qoff[23:0] + ({8'd0, oc8_r} << 2);
              qtb_r       <= d_qoff[23:0] + ({8'd0, oc8_r} << 2)
                                            + ({8'd0, oc8_r} << 1);
              c_p         <= 16'd0;
              if (is_conv) begin
                q_iss <= 4'd0;
                state <= S_Q;
              end
              else if (is_pool) state <= S_PINIT;
              else if (is_copy) state <= S_CP_RD;
              else              state <= S_AD_R1;
            end
            default: ;
          endcase
          if (c_p != 16'd5) c_p <= c_p + 16'd1;
        end
        // ---- Q 参数装载 (8 拍) ----
        S_Q: begin
          if (q_iss <= 4'd6) q_iss <= q_iss + 4'd1;
          if ((q_iss >= 4'd1) && (q_iss <= 4'd7)) begin
            case (q_iss - 4'd1)
              4'd0: begin bias_q[0] <= $signed(w_rdata[31:0]);
                         bias_q[1] <= $signed(w_rdata[63:32]); end
              4'd1: begin bias_q[2] <= $signed(w_rdata[31:0]);
                         bias_q[3] <= $signed(w_rdata[63:32]); end
              4'd2: begin bias_q[4] <= $signed(w_rdata[31:0]);
                         bias_q[5] <= $signed(w_rdata[63:32]); end
              4'd3: begin bias_q[6] <= $signed(w_rdata[31:0]);
                         bias_q[7] <= $signed(w_rdata[63:32]); end
              4'd4: begin mpos_q[0] <= $signed(w_rdata[15:0]);
                         mpos_q[1] <= $signed(w_rdata[31:16]);
                         mpos_q[2] <= $signed(w_rdata[47:32]);
                         mpos_q[3] <= $signed(w_rdata[63:48]); end
              4'd5: begin mpos_q[4] <= $signed(w_rdata[15:0]);
                         mpos_q[5] <= $signed(w_rdata[31:16]);
                         mpos_q[6] <= $signed(w_rdata[47:32]);
                         mpos_q[7] <= $signed(w_rdata[63:48]); end
              default: begin
                         zp_out  <= w_rdata[7:0];
                         zp_in   <= w_rdata[15:8];
                         leaky_q <= w_rdata[16];
                         shift_q <= w_rdata[31:24];
                       end
            endcase
          end
          if (q_iss == 4'd7) state <= S_QLOAD;
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
              mneg_q[l] <= leaky_q ? ((mtmp[l] + 32'sd16384) >>> 15) : mpos32[l];
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
          wa_r   <= d_woff[23:0] + ({5'd0, c_ocb} << 3);
          band_base <= f_dw ? (blk_base + ({5'd0, c_ocb} << 3)) : blk_base;
          la        <= f_dw ? (blk_base + ({5'd0, c_ocb} << 3)) : blk_base;
          x_ld      <= x0_c;
          x0_ld     <= x0_c;
          y_ld      <= y_ky0;
          y_ok_r    <= y_ok_of(y_ky0, d_ih);
          state  <= S_LD;
        end
        // ---- band 装载 (count 拍) ----
        S_LD: begin
          ld_j_d        <= c_ld[4:0];
          ld_fill_d     <= ~ld_inb;
          ld_half_d     <= la[3];
          ld_fillbyte_d <= ld_fill;
          ld_ret_v      <= 1'b1;
          x_ld          <= x_ld + $signed({15'd0, dx_r});
          if (c_ld == (ld_count - 16'd1)) begin
            c_ld  <= 16'd0;
            state <= S_LDCAP;
          end
          else c_ld <= c_ld + 16'd1;
        end
        // ---- band 末: 预计算下一个 band 基址 (1 拍) ----
        S_LDCAP: begin
          c_m   <= 16'd0;
          if (dense && (c_icb + 16'd1 < icb_n)) begin
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
              if (c_icb + 16'd1 < icb_n) begin
                c_icb <= c_icb + 16'd1;
                c_ld  <= 16'd0;
                x_ld   <= x0_ld;
                y_ld   <= y_ld;
                y_ok_r <= y_ok_of(y_ld, d_ih);
                state <= S_LD;
              end
              else if (c_ky + 16'd1 < ks16) begin
                c_ky  <= c_ky + 16'd1;
                c_icb <= 16'd0;
                c_ld  <= 16'd0;
                x_ld   <= x0_ld;
                y_ld   <= y_1;
                y_ok_r <= y_ok_of(y_1, d_ih);
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
                x_ld   <= x0_ld;
                y_ld   <= y_1;
                y_ok_r <= y_ok_of(y_1, d_ih);
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
          if (c_drn == 3'd2) begin
            c_drn <= 3'd0;
            c_p   <= 16'd0;
            state <= S_REQ;
          end
          else c_drn <= c_drn + 3'd1;
        end
        S_REQ: begin
          if (c_p == (REQN - 1)) begin
            c_p   <= 16'd0;
            state <= S_NEXT;
          end
          else c_p <= c_p + 16'd1;
        end
        // ---- 输出块推进 (拆 2 拍: NEXT 只做"预加 + 决策", NEXT2 只做"选择写入") ----
        S_NEXT: begin
          row_base_a_n <= row_base_a + oy_step_a;
          row_base_w_n <= row_base_w + row_step_w;
          if ((ox0 + 16'd8) < ow_w)                       nxt_sel <= 2'd0;
          else if ((c_oy + 16'd1) < oh_w)                 nxt_sel <= 2'd1;
          else                                            nxt_sel <= 2'd2;
          state <= S_NEXT2;
        end
        S_NEXT2: begin
          case (nxt_sel)
            2'd0: begin
              c_oxg    <= c_oxg + 16'd1;
              blk_base <= blk_base + ox_step_a;
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
                row_base_a <= base0_a;
                blk_base   <= base0_a;
                row_base_w <= d_dst[23:0] + ((c_ocb + 16'd1) << 3);
                wr_base    <= d_dst[23:0] + ((c_ocb + 16'd1) << 3);
                if (is_pool) state <= S_PINIT;
                else begin
                  q_iss <= 4'd0;
                  qa_r  <= d_qoff[23:0] + ((c_ocb + 16'd1) << 5);
                  qmb_r <= d_qoff[23:0] + ((c_ocb + 16'd1) << 4)
                           + ({8'd0, oc8_r} << 2);
                  qtb_r <= d_qoff[23:0] + ({8'd0, oc8_r} << 2)
                           + ({8'd0, oc8_r} << 1);
                  state <= S_Q;
                end
              end
              else state <= S_FIN;
            end
          endcase
        end
        // ---- maxpool ----
        S_PINIT: begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              mx[px][oc] <= -8'sd128;
          c_ky   <= 16'd0;
          c_m    <= 16'd0;
          c_ld   <= 16'd0;
          c_p    <= 16'd0;
          band_base <= blk_base + ({5'd0, c_ocb} << 3);
          la        <= blk_base + ({5'd0, c_ocb} << 3);
          x_ld      <= x0_c;
          x0_ld     <= x0_c;
          y_ld      <= y_ky0;
          y_ok_r    <= y_ok_of(y_ky0, d_ih);
          state  <= S_LD;
        end
        S_PMAX: begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              if ($signed(win_sel[px][oc*8 +: 8]) > mx[px][oc])
                mx[px][oc] <= $signed(win_sel[px][oc*8 +: 8]);
          c_m <= c_m + 16'd1;
          if (c_m == (ks16 - 16'd1)) begin
            c_m <= 16'd0;
            if (c_ky + 16'd1 < ks16) begin
              c_ky  <= c_ky + 16'd1;
              c_ld  <= 16'd0;
              x_ld   <= x0_ld;
              y_ld   <= y_1;
              y_ok_r <= y_ok_of(y_1, d_ih);
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
            if (c_cb + 16'd1 < icb_n) begin
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
        // ---- ADD ----
        S_AD_R1: begin
          rd_half_s <= src_la[3];
          state     <= S_AD_R2;
        end
        S_AD_R2: begin
          rd_half_d  <= dst_la[3];
          src_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];
          state      <= S_AD_WR;
        end
        S_AD_WR: begin
          if (c_cb + 16'd1 < icb_n) begin
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
