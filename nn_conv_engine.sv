`timescale 1ns/1ps

// ============================================================================
// nn_conv_engine.sv — int8 卷积引擎 (64 MAC/拍 = 8 像素 x 8 输出通道)
// ----------------------------------------------------------------------------
// 契约: results/ai-accel/CONTRACT.md v0.3 (§5 量化 / §6 权重布局 / §7 Q 区
//       (变长紧凑布局) / §8 激活布局 / §9.2 端口 / §11 op 精确语义)
//
// 支持 op (v1):
//   CONV : 普通卷积 / depthwise 卷积, K=1/3/5, stride=1/2, pad<=K/2, leaky 可选
//   POOL : maxpool, K=2/3/5/9, stride=1/2 (窗口越界视为 -128; 不做 requant)
//   COPY : 8 通道字逐字拷贝 / 2x 最近邻上采样 (flags.UP2X)
//   ADD  : dst = clamp(dst + src, -128, 127) (int8 饱和)
//
// ----------------------------------------------------------------------------
// 【数据流】output-stationary + 像素并行
//   PE 阵列: 8 像素 lane (PX_LANES) x 8 输出通道 lane (OC_LANES) = 64 MAC/拍
//   - 权重: w 口 64 位/拍 = 一个 (tap, ic) 的 8 个输出通道 int8, 每拍 1 字
//   - 激活: a 口 128 位/拍 = 2 个连续 64 位字; 本引擎一次只用其中 1 个 64 位字
//           (一个像素的 8 通道), 用 a_addr[3] 选低/高半字
//   - 转置: 激活按"像素主序"搬进 band 寄存器组 abuf[band_idx] = {8 通道};
//           再用移位寄存器 bshift 抽出"当前 kx 的 8 个像素窗口", 广播到 8 个
//           输出通道 lane (dense: 取同一字节广播; depthwise/pool: 逐字节对应)
//   - 累加: acc[8 像素][8 通道] int32; 写回前 requant
//   - MAC 流水: issue(读权重) -> prod(8x8 有符号乘, 寄存) -> acc(加), 每拍 1 个
//     (tap,ic); 输出块结束有 2 拍 drain.
//
// 【requant】(CONTRACT §5 v0.3, 全整数, 右移 = floor)
//   Q 区只存 M_pos int16; 引擎在 OC tile 装载阶段现算:
//       M_neg[oc] = leaky_en ? (M_pos[oc]*3277 + 16384) >>> 15 : M_pos[oc]
//   y64 = (acc >= 0 ? acc*M_pos : acc*M_neg)          // 64 位有符号乘积
//   out = clamp((y64 >>> SHIFT) + zp_out, -128, 127)  // 算术右移 = floor
//   受 8 个宽乘法器限制, 8 个像素分 8 拍串行; 打包/写回与乘法重叠,
//   requant+write 共 9 拍/输出块 (c_p = 0..8).
//
// 【Q 区读取】(v0.3 变长布局; w 口绝对窗口偏移, 8 字节对齐, 小端)
//   +0x000        bias_adj[OC_pad] int32  4x64b (8 个)
//   +4*OC_pad     M_pos[OC_pad]    int16  2x64b (8 个)
//   +6*OC_pad     tail 16B: [0]=zp_out [1]=zp_in [2]=leaky_en [3]=SHIFT
//   每个 OC tile: 7 次 w 读 + 1 拍算 M_neg.
//
// 【周期公式】每输出块 = 8 像素 x 8 输出通道; OC_pad=ceil(OC/8)*8 etc.
//   dense conv: sum_{ky,icb}[ (7*stride+ks+1) + (ks>1?1:0) + 8*ks ] + 2 + 9
//   depthwise : sum_{ky}      [ (7*stride+ks+1) + 1 + ks ]      + 2 + 9
//   maxpool   : 1 + sum_{ky}  [ (7*stride+ks+1) + 1 + ks ]      + 8
//   copy      : ih*iw*IC_pad/8 * (UPS2X ? 5 : 2)      (每字 1 读 + 1/4 写)
//   add       : ih*iw*IC_pad/8 * 3                    (读 src + 读 dst + 写)
//   每个 OC tile 额外 Q 装载 10 拍 (amortized 到该 tile 的所有输出块)
//
// 【寄存器预算】abuf 24x64 + bshift 15x64 + acc 64x32 + a_pipe 64x8
//   + prod 64x16 + prod64 8x64 + mx 64x8 + Q 参数 ~800b + 计数/流水
//   ≈ 8.2K FF (任务上限 10K).
// 【DSP】64 (MAC) + 8 (M_neg) + 8 个宽 requant 乘法 (Vivado 约 3~4 DSP/个)
//   ≈ 96~104 / 240.
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
  output logic         done,          // 单拍脉冲
  output logic [31:0]  cycles,        // done 拍为最终值
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
  localparam int BANDW = 24;         // band 字数上限 = 7*2+9 = 23 (+1 富余)
  localparam int WINW  = 15;         // bshift 字数 = 7*stride+1 (stride=2)

  typedef enum logic [4:0] {
    S_IDLE, S_INIT, S_Q, S_QLOAD, S_BI, S_LD, S_LDCAP, S_WI, S_MAC, S_DRN,
    S_REQ, S_NEXT, S_PINIT, S_PMAX, S_PPACK,
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
  logic [2:0]  d_pad;          // v0.4: 3 位 (pool K=9 的 pad=4)
  logic [15:0] d_ih, d_iw, d_ic, d_oc;
  logic [31:0] d_src, d_dst, d_woff, d_qoff;

  wire is_conv = (d_op == NN_OP_CONV);
  wire is_pool = (d_op == NN_OP_POOL);
  wire is_copy = (d_op == NN_OP_COPY);
  wire is_add  = (d_op == NN_OP_ADD);
  wire f_dw    = d_flags[NN_F_DEPTHWISE];
  wire f_leaky = d_flags[NN_F_LEAKY];
  wire f_up2x  = d_flags[NN_F_UP2X];

  wire [15:0] ic8   = (d_ic + 16'd7) & 16'hFFF8;
  wire [15:0] oc8   = (d_oc + 16'd7) & 16'hFFF8;
  wire [5:0]  icb_n = ic8[8:3];
  wire [5:0]  ocb_n = oc8[8:3];

  wire [15:0] ks16 = {12'd0, d_ks};
  wire [15:0] st16 = {14'd0, d_st};

  // 【v0.4】desc.pad 已加宽到 3 位 (pool K=9 的 pad=4), 主路径直接用 desc.pad。
  // 防御性 workaround (v0.3 遗留): 若 pool 的 pad==0, 按 darknet 语义取 (K-1)/2
  //   (K=2->0, 3->1, 5->2, 9->4), 防止"2 位截断"回归时静默算错输出尺寸。
  // conv 仍严格用 desc.pad (0/1/2)。
  wire [2:0] pad_eff = (is_pool && (d_pad == 3'd0))
      ? (({2'b0, d_ks} - 4'd1) >> 1)
      : d_pad;

  logic [15:0] oh_w, ow_w;
  always_comb begin
    int num;
    if (is_copy) begin
      oh_w = f_up2x ? (d_ih << 1) : d_ih;
      ow_w = f_up2x ? (d_iw << 1) : d_iw;
    end
    else if (is_add) begin
      oh_w = d_ih;
      ow_w = d_iw;
    end
    else begin
      num = int'(d_ih) + 2 * int'(pad_eff) - int'(d_ks);
      if (num < 0) num = 0;
      oh_w = 16'((d_st == 2'd2) ? (num >> 1) : num) + 16'd1;
      num = int'(d_iw) + 2 * int'(pad_eff) - int'(d_ks);
      if (num < 0) num = 0;
      ow_w = 16'((d_st == 2'd2) ? (num >> 1) : num) + 16'd1;
    end
  end

  // a_sel / b_sel 默认由 desc.src / desc.dst 的地址段决定 (CONTRACT §11);
  // ADD 的 dst 读例外, 在端口组合逻辑里按 S_AD_R2 覆写 a_sel。
  assign b_sel = (d_dst >= NN_B_OFF) ? 2'd1 : 2'd0;

  // 描述符合法性 (S_INIT 拍检查)
  logic [7:0] init_err;
  always_comb begin
    init_err = 8'h00;
    if (is_conv) begin
      if (!(d_ks == 4'd1 || d_ks == 4'd3 || d_ks == 4'd5))          init_err = 8'h11;
      else if (!(d_st == 2'd1 || d_st == 2'd2))                       init_err = 8'h12;
      else if ({14'd0, d_pad} > (ks16 >> 1))                          init_err = 8'h13;
      else if (d_ic == 16'd0 || d_oc == 16'd0)                        init_err = 8'h14;
      else if (d_ih == 16'd0 || d_iw == 16'd0)                        init_err = 8'h15;
      else if (f_dw && (d_oc != d_ic))                                init_err = 8'h16;
    end
    else if (is_pool) begin
      if (!(d_ks == 4'd2 || d_ks == 4'd3 || d_ks == 4'd5 || d_ks == 4'd9))
                                                                      init_err = 8'h21;
      else if (!(d_st == 2'd1 || d_st == 2'd2))                       init_err = 8'h22;
      else if ({14'd0, d_pad} > (ks16 >> 1))                          init_err = 8'h23;
      else if (d_ic == 16'd0)                                         init_err = 8'h24;
      else if (d_ih == 16'd0 || d_iw == 16'd0)                        init_err = 8'h25;
    end
    else if (is_copy) begin
      if (d_ic == 16'd0 || d_oc == 16'd0)                             init_err = 8'h31;
      else if (d_ih == 16'd0 || d_iw == 16'd0)                        init_err = 8'h32;
      else if (icb_n > ocb_n)                                         init_err = 8'h33;
    end
    else begin
      if (d_ic == 16'd0)                                              init_err = 8'h41;
      else if (d_ih == 16'd0 || d_iw == 16'd0)                        init_err = 8'h42;
      else if (d_oc != d_ic)                                          init_err = 8'h43;
    end
    if ((init_err == 8'h00) && !is_copy &&
        (((d_ih + (d_pad << 1)) < d_ks) || ((d_iw + (d_pad << 1)) < d_ks)))
      init_err = 8'h18;
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
  logic        ld_ret_v, ld_fill_d, ld_half_d;
  logic [4:0]  ld_j_d;
  logic [7:0]  ld_fillbyte_d;
  logic [63:0] cp_word_q;      // COPY: 读回锁存的源字 (a_rdata 只保 1 拍)
  logic        mac_v1, mac_v2;
  logic        rd_half_s, rd_half_d;
  logic [63:0] src_word_q;

  // ==========================================================================
  // 数据寄存器
  // ==========================================================================
  logic [63:0] abuf  [0:BANDW-1];
  logic [63:0] bshift[0:WINW-1];

  logic signed [31:0] acc    [0:PX-1][0:OCL-1];
  logic signed [7:0]  a_pipe [0:PX-1][0:OCL-1];
  logic signed [15:0] prod   [0:PX-1][0:OCL-1];
  logic signed [63:0] prod64 [0:OCL-1];

  logic signed [31:0] bias_q [0:OCL-1];
  logic signed [15:0] mpos_q [0:OCL-1];
  logic signed [31:0] mneg_q [0:OCL-1];
  logic signed [7:0]  zp_out, zp_in;
  logic [7:0]         shift_q;
  logic               leaky_q;

  logic signed [7:0]  mx [0:PX-1][0:OCL-1];

  wire [15:0] ox0 = c_oxg << 3;

  // ==========================================================================
  // band 装载参数
  // ==========================================================================
  wire [15:0] ld_count  = (is_conv && !f_dw && (d_ks == 4'd1)) ? 16'd8
                         : (7 * st16 + ks16);
  wire [15:0] ld_dx     = (is_conv && !f_dw && (d_ks == 4'd1)) ? st16 : 16'd1;
  wire [7:0]  ld_fill   = is_pool ? 8'h80 : zp_in;
  wire [15:0] ld_cblock = (f_dw || is_pool) ? c_ocb : c_icb;

  wire signed [17:0] ld_y  = $signed({2'b0, c_oy}) * $signed({2'b0, st16})
                             + $signed({2'b0, c_ky}) - $signed({15'd0, pad_eff});
  wire signed [17:0] ld_x0 = $signed({2'b0, ox0}) * $signed({2'b0, st16})
                             - $signed({15'd0, pad_eff});
  wire signed [17:0] ld_x  = ld_x0 + $signed({2'b0, c_ld}) * $signed({2'b0, ld_dx});
  wire ld_inb = (ld_y >= 0) && (ld_y < $signed({2'b0, d_ih})) &&
                (ld_x >= 0) && (ld_x < $signed({2'b0, d_iw}));
  wire [31:0] ld_lin   = ({16'd0, ld_y[15:0]} * {16'd0, d_iw}) + {16'd0, ld_x[15:0]};
  wire [31:0] ld_widx  = (ld_lin * {26'd0, icb_n}) + {26'd0, ld_cblock};
  wire [31:0] ld_bytes = d_src + (ld_widx << 3);

  // ==========================================================================
  // 权重地址 (全用 32 位中间量, 防乘法位宽截断)
  // ==========================================================================
  wire [15:0] cur_kx_dense = c_m >> 3;
  wire [15:0] cur_kx       = (is_conv && !f_dw) ? cur_kx_dense : c_m;
  wire [31:0] cur_tap32    = {16'd0, c_ky} * {16'd0, ks16} + {16'd0, cur_kx};
  wire [31:0] cur_ic32     = {16'd0, c_icb} * 16'd8 + {29'd0, c_m[2:0]};
  wire [31:0] dense_waddr  = ((cur_tap32 * {16'd0, ic8} + cur_ic32) * {16'd0, oc8})
                             + {16'd0, c_ocb} * 16'd8;
  wire [31:0] dw_waddr     = (cur_tap32 * {16'd0, oc8}) + {16'd0, c_ocb} * 16'd8;

  // ==========================================================================
  // 输出地址
  // ==========================================================================
  wire [15:0] req_px    = (c_p >= 16'd1) ? (c_p - 16'd1) : 16'd0;
  wire [31:0] out_lin   = ({16'd0, c_oy} * {16'd0, ow_w}) + {16'd0, ox0} + {16'd0, req_px};
  wire [31:0] out_word  = out_lin * {26'd0, ocb_n} + {26'd0, c_ocb};
  wire [31:0] req_addr  = d_dst + (out_word << 3);
  wire [31:0] pool_lin  = ({16'd0, c_oy} * {16'd0, ow_w}) + {16'd0, ox0} + {16'd0, c_p};
  wire [31:0] pool_word = pool_lin * {26'd0, icb_n} + {26'd0, c_ocb};
  wire [31:0] pool_addr = d_dst + (pool_word << 3);

  // ==========================================================================
  // copy / add 地址
  // ==========================================================================
  wire [15:0] cp_dst_ow  = f_up2x ? (d_iw << 1) : d_iw;
  wire [31:0] cp_src_pix = {16'd0, c_iy} * {16'd0, d_iw} + {16'd0, c_ix};
  wire [31:0] cp_dst_pix = f_up2x
      ? ((({16'd0, c_iy} * 16'd2 + {31'd0, c_wr[1]}) * {16'd0, cp_dst_ow})
         + {16'd0, c_ix} * 16'd2 + {31'd0, c_wr[0]})
      : cp_src_pix;
  wire [31:0] cp_src_word = cp_src_pix * {26'd0, icb_n} + {26'd0, c_cb};
  wire [31:0] cp_dst_word = cp_dst_pix * {26'd0, ocb_n} + {26'd0, c_cb};
  wire [31:0] cp_src_addr = d_src + (cp_src_word << 3);
  wire [31:0] cp_dst_addr = d_dst + (cp_dst_word << 3);
  wire [31:0] ad_src_addr = d_src + ((cp_src_pix * {26'd0, icb_n} + {26'd0, c_cb}) << 3);
  wire [31:0] ad_dst_addr = d_dst + ((cp_src_pix * {26'd0, ocb_n} + {26'd0, c_cb}) << 3);

  // ==========================================================================
  // A 操作数选择 (当前 kx 的 8 像素窗口字)
  // ==========================================================================
  logic [63:0] win_sel [0:PX-1];
  always_comb begin
    for (int px = 0; px < PX; px++) begin
      if (is_conv && !f_dw && (d_ks == 4'd1))
        win_sel[px] = abuf[px];                          // K=1: 直接按像素索引
      else
        win_sel[px] = (d_st == 2'd2) ? bshift[2*px] : bshift[px];
    end
  end

  wire [5:0] sel_byte_base = {c_m[2:0], 3'b000};

  wire win_adv = (state == S_MAC)
      ? ( (is_conv && !f_dw)
            ? ((c_m[2:0] == 3'd7) && ((cur_kx_dense + 16'd1) < ks16))
            : ((c_m + 16'd1) < ks16) )
      : ((state == S_PMAX) ? ((c_m + 16'd1) < ks16) : 1'b0);

  wire mac_issue = (state == S_MAC);

  // 权重字节 (16 位符号扩展, 保证 8x8 乘法不截位)
  logic signed [15:0] wbyte [0:OCL-1];
  always_comb begin
    for (int oc = 0; oc < OCL; oc++) wbyte[oc] = $signed(w_rdata[oc*8 +: 8]);
  end

  // ==========================================================================
  // requant 打包
  // ==========================================================================
  logic [63:0] rq_pack;
  always_comb begin
    logic signed [63:0] y64, y2;
    logic [7:0] bb;
    rq_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      y64 = prod64[l] >>> shift_q;
      y2  = y64 + {{56{zp_out[7]}}, zp_out};
      if (y2 > 64'sd127)       bb = 8'h7F;
      else if (y2 < -64'sd128) bb = 8'h80;
      else                     bb = y2[7:0];
      if ((c_ocb * 16'd8 + l) >= d_oc) bb = zp_out;   // 输出 padding 通道 = zp_out
      rq_pack[l*8 +: 8] = bb;
    end
  end

  // ==========================================================================
  // maxpool 打包 (padding 通道写 0)
  // ==========================================================================
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

  // ==========================================================================
  // ADD 饱和打包
  // ==========================================================================
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

  // ==========================================================================
  // 端口组合逻辑
  // ==========================================================================
  logic [31:0] w_addr_t, a_addr_t, b_addr_t;
  always_comb begin
    w_re     = 1'b0;
    w_addr_t = 32'd0;
    a_re     = 1'b0;
    a_addr_t = 32'd0;
    a_sel    = (d_src >= NN_B_OFF) ? 2'd1 : 2'd0;
    b_we     = 1'b0;
    b_addr_t = 32'd0;
    b_wdata  = 64'd0;
    case (state)
      S_Q: begin
        if (q_iss <= 4'd6) begin
          w_re = 1'b1;
          if (q_iss <= 4'd3)
            w_addr_t = d_qoff + c_ocb * 16'd32 + {28'd0, q_iss} * 16'd8;
          else if (q_iss <= 4'd5)
            w_addr_t = d_qoff + ({16'd0, oc8} << 2) + c_ocb * 16'd16
                       + {28'd0, (q_iss - 4'd4)} * 16'd8;
          else
            w_addr_t = d_qoff + {16'd0, oc8} * 16'd6;
        end
      end
      S_MAC: begin
        w_re     = 1'b1;
        w_addr_t = d_woff + ((is_conv && !f_dw) ? dense_waddr : dw_waddr);
      end
      S_LD: begin
        if (ld_inb) begin
          a_re     = 1'b1;
          a_addr_t = {ld_bytes[23:4], 4'b0000};
        end
      end
      S_CP_RD, S_AD_R1, S_AD_R2: begin
        a_re     = 1'b1;
        a_addr_t = (state == S_CP_RD) ? {cp_src_addr[23:4], 4'b0000}
                 : (state == S_AD_R1) ? {ad_src_addr[23:4], 4'b0000}
                                      : {ad_dst_addr[23:4], 4'b0000};
        // 【注意】ADD 的 dst 读必须切到 dst 所在的 buffer: a_sel 是"本拍 a_addr
        // 归属哪块"的选择位, nn_mem 对"sel 与地址归属不一致"会返回 0。
        // 对 conv/pool/copy 本拍地址都属于 desc.src, 与契约 §11 的规则一致;
        // 只有 ADD 的第二次读属于 desc.dst, 必须给 1。
        if (state == S_AD_R2) a_sel = (d_dst >= NN_B_OFF) ? 2'd1 : 2'd0;
      end
      S_CP_WR: begin
        // nn_mem 的 a_rdata 只在 a_re 的下一拍有效 (之后回 0):
        //   c_wr=0 那拍直接用 a_rdata; 后续 3 份 (upsample) 用锁存字 cp_word_q。
        b_we     = 1'b1;
        b_addr_t = cp_dst_addr;
        b_wdata  = (c_wr == 2'd0) ? (rd_half_s ? a_rdata[127:64] : a_rdata[63:0])
                                  : cp_word_q;
      end
      S_AD_WR: begin
        b_we     = 1'b1;
        b_addr_t = ad_dst_addr;
        b_wdata  = ad_pack;
      end
      S_REQ: begin
        if ((c_p >= 16'd1) && ((ox0 + req_px) < ow_w)) begin
          b_we     = 1'b1;
          b_addr_t = req_addr;
          b_wdata  = rq_pack;
        end
      end
      S_PPACK: begin
        if ((ox0 + c_p) < ow_w) begin
          b_we     = 1'b1;
          b_addr_t = pool_addr;
          b_wdata  = pool_pack;
        end
      end
      default: ;
    endcase
  end

  assign w_addr = w_addr_t[23:0];
  assign a_addr = a_addr_t[23:0];
  assign b_addr = b_addr_t[23:0];

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
      mac_v1   <= 1'b0;
      mac_v2   <= 1'b0;
      q_iss    <= 4'd0;
      c_ocb <= 16'd0; c_oy  <= 16'd0; c_oxg <= 16'd0; c_ky  <= 16'd0;
      c_icb <= 16'd0; c_m   <= 16'd0; c_ld  <= 16'd0; c_p   <= 16'd0;
      c_iy  <= 16'd0; c_ix  <= 16'd0; c_cb  <= 16'd0;
      c_drn <= 3'd0;  c_wr  <= 2'd0;
      rd_half_s <= 1'b0; rd_half_d <= 1'b0;
      src_word_q <= 64'd0;
      cp_word_q  <= 64'd0;
    end
    else begin
      done_r   <= 1'b0;
      ld_ret_v <= 1'b0;

      // ---- 忙周期计数 (IDLE/FIN 不计) ----
      if ((state != S_IDLE) && (state != S_FIN)) cycles_r <= cycles_r + 32'd1;

      // ---- COPY: 在读返回那一拍 (S_CP_WR 且 c_wr==0) 锁存源字 ----
      if ((state == S_CP_WR) && (c_wr == 2'd0))
        cp_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];

      // ---- band 装载返回 ----
      if (ld_ret_v) begin
        if (ld_fill_d) abuf[ld_j_d] <= {8{ld_fillbyte_d}};
        else           abuf[ld_j_d] <= ld_half_d ? a_rdata[127:64] : a_rdata[63:0];
      end

      // ---- MAC 流水: issue -> prod -> acc ----
      mac_v1 <= mac_issue;
      mac_v2 <= mac_v1;
      if (mac_issue) begin
        for (int px = 0; px < PX; px++)
          for (int oc = 0; oc < OCL; oc++)
            a_pipe[px][oc] <= (is_conv && !f_dw)
                              ? win_sel[px][sel_byte_base +: 8]
                              : win_sel[px][oc*8 +: 8];
      end
      if (mac_v1) begin
        for (int px = 0; px < PX; px++)
          for (int oc = 0; oc < OCL; oc++)
            prod[px][oc] <= $signed(a_pipe[px][oc]) * wbyte[oc];
      end
      if (mac_v2) begin
        for (int px = 0; px < PX; px++)
          for (int oc = 0; oc < OCL; oc++)
            acc[px][oc] <= acc[px][oc] + {{16{prod[px][oc][15]}}, prod[px][oc]};
      end

      // ---- bshift 移位 (换 kx) ----
      if (win_adv) begin
        for (int i = 0; i < WINW-1; i++) bshift[i] <= bshift[i+1];
        bshift[WINW-1] <= abuf[15 + cur_kx[3:0]];
      end

      // ---- requant 乘法 ----
      if ((state == S_REQ) && (c_p <= 16'd7)) begin
        for (int l = 0; l < OCL; l++) begin
          if (acc[c_p[2:0]][l] < 0)
            prod64[l] <= $signed(acc[c_p[2:0]][l]) * mneg_q[l];
          else
            prod64[l] <= $signed(acc[c_p[2:0]][l]) * ({{16{mpos_q[l][15]}}, mpos_q[l]});
        end
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
        S_INIT: begin
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
            if (is_conv) begin
              q_iss <= 4'd0;
              state <= S_Q;
            end
            else if (is_pool) state <= S_PINIT;
            else if (is_copy) state <= S_CP_RD;
            else              state <= S_AD_R1;
          end
        end
        // ------------------------------------------------------- Q 参数装载
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
                         leaky_q <= w_rdata[16];       // tail[2] 的 bit0
                         shift_q <= w_rdata[31:24];    // tail[3] = SHIFT
                       end
            endcase
          end
          if (q_iss == 4'd7) state <= S_QLOAD;
        end
        S_QLOAD: begin
          for (int l = 0; l < OCL; l++) begin
            logic signed [31:0] mp;
            mp = {{16{mpos_q[l][15]}}, mpos_q[l]};
            mneg_q[l] <= leaky_q ? ((mp * 32'sd3277 + 32'sd16384) >>> 15) : mp;
          end
          state <= S_BI;
        end
        // ------------------------------------------------------ 累加器初始化
        S_BI: begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              acc[px][oc] <= bias_q[oc];
          c_ky  <= 16'd0;
          c_icb <= 16'd0;
          c_m   <= 16'd0;
          c_ld  <= 16'd0;
          state <= S_LD;
        end
        // ---------------------------------------------------------- band 装载
        S_LD: begin
          ld_j_d        <= c_ld[4:0];
          ld_fill_d     <= ~ld_inb;
          ld_half_d     <= ld_bytes[3];
          ld_fillbyte_d <= ld_fill;
          ld_ret_v      <= 1'b1;
          if (c_ld >= (ld_count - 16'd1)) begin
            state <= S_LDCAP;
            c_ld  <= 16'd0;
          end
          else c_ld <= c_ld + 16'd1;
        end
        S_LDCAP: begin
          c_m   <= 16'd0;
          if (is_conv && !f_dw && (d_ks == 4'd1)) state <= S_MAC;
          else                                    state <= S_WI;
        end
        S_WI: begin
          for (int i = 0; i < WINW; i++) bshift[i] <= abuf[i];
          c_m   <= 16'd0;
          state <= is_pool ? S_PMAX : S_MAC;   // pool 走 max 路径, conv/dw 走 MAC
        end
        // -------------------------------------------------------------- MAC
        S_MAC: begin
          if (is_conv && !f_dw) begin
            c_m <= c_m + 16'd1;
            if (c_m == ((ks16 << 3) - 16'd1)) begin
              c_m <= 16'd0;
              if ({10'd0, c_icb} + 16'd1 < {10'd0, icb_n}) begin
                c_icb <= c_icb + 16'd1;
                c_ld  <= 16'd0;
                state <= S_LD;
              end
              else if (c_ky + 16'd1 < ks16) begin
                c_ky  <= c_ky + 16'd1;
                c_icb <= 16'd0;
                c_ld  <= 16'd0;
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
          if (c_drn == 3'd1) begin
            c_p   <= 16'd0;
            state <= S_REQ;
          end
          else c_drn <= c_drn + 3'd1;
        end
        // ---------------------------------------------------------- requant
        S_REQ: begin
          if (c_p == 16'd8) begin
            c_p   <= 16'd0;
            state <= S_NEXT;
          end
          else c_p <= c_p + 16'd1;
        end
        // ------------------------------------------------------ 输出块推进
        S_NEXT: begin
          if ((ox0 + 16'd8) < ow_w) begin
            c_oxg <= c_oxg + 16'd1;
            state <= is_pool ? S_PINIT : S_BI;
          end
          else begin
            c_oxg <= 16'd0;
            if ((c_oy + 16'd1) < oh_w) begin
              c_oy  <= c_oy + 16'd1;
              state <= is_pool ? S_PINIT : S_BI;
            end
            else begin
              c_oy  <= 16'd0;
              c_ocb <= c_ocb + 16'd1;
              if ((c_ocb + 16'd1) < (is_pool ? {10'd0, icb_n} : {10'd0, ocb_n})) begin
                if (is_pool) state <= S_PINIT;
                else begin
                  q_iss <= 4'd0;
                  state <= S_Q;
                end
              end
              else state <= S_FIN;
            end
          end
        end
        // ---------------------------------------------------------- maxpool
        S_PINIT: begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              mx[px][oc] <= -8'sd128;
          c_ky  <= 16'd0;
          c_m   <= 16'd0;
          c_ld  <= 16'd0;
          c_p   <= 16'd0;
          state <= S_LD;
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
        // -------------------------------------------------------------- copy
        S_CP_RD: begin
          rd_half_s<= cp_src_addr[3];
          c_wr     <= 2'd0;
          state    <= S_CP_WR;
        end
        S_CP_WR: begin
          if (f_up2x && (c_wr != 2'd3)) begin
            c_wr <= c_wr + 2'd1;
          end
          else begin
            c_wr <= 2'd0;
            if (({10'd0, c_cb} + 16'd1) < {10'd0, icb_n}) begin
              c_cb  <= c_cb + 16'd1;
              state <= S_CP_RD;
            end
            else if ((c_ix + 16'd1) < d_iw) begin
              c_cb  <= 16'd0;
              c_ix  <= c_ix + 16'd1;
              state <= S_CP_RD;
            end
            else if ((c_iy + 16'd1) < d_ih) begin
              c_cb  <= 16'd0;
              c_ix  <= 16'd0;
              c_iy  <= c_iy + 16'd1;
              state <= S_CP_RD;
            end
            else state <= S_FIN;
          end
        end
        // --------------------------------------------------------------- add
        S_AD_R1: begin
          rd_half_s <= ad_src_addr[3];
          state     <= S_AD_R2;
        end
        S_AD_R2: begin
          rd_half_d  <= ad_dst_addr[3];
          src_word_q <= rd_half_s ? a_rdata[127:64] : a_rdata[63:0];
          state      <= S_AD_WR;
        end
        S_AD_WR: begin
          if (({10'd0, c_cb} + 16'd1) < {10'd0, icb_n}) begin
            c_cb  <= c_cb + 16'd1;
            state <= S_AD_R1;
          end
          else if ((c_ix + 16'd1) < d_iw) begin
            c_cb  <= 16'd0;
            c_ix  <= c_ix + 16'd1;
            state <= S_AD_R1;
          end
          else if ((c_iy + 16'd1) < d_ih) begin
            c_cb  <= 16'd0;
            c_ix  <= 16'd0;
            c_iy  <= c_iy + 16'd1;
            state <= S_AD_R1;
          end
          else state <= S_FIN;
        end
        // -------------------------------------------------------------- FIN
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
