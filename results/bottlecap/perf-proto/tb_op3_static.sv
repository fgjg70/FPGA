// tb_op3_static.sv — task-20 仲裁实验（静态存储版，绕过 nn_tilecache）
//
// 用"stock nn_mem 语义"的**大容量**静态存储给 nn_conv_engine 供 A/B/W/Q，
// 跑完整 op3（112x112x64 -> 112x112x16，A=802,816 B）并与 converter golden 逐字节比。
//
// 为什么不例化 nn_mem：nn_mem 的 A 窗口被 `a_in_a = addr >= A_OFF && addr < B_OFF`
//   硬卡在 96KB（nn_mem.sv:508），装不下 op3 的 802,816 B。本 TB 按同一端口契约实现
//   等价大容量存储：a 读延迟 1 拍（寄存地址 + 组合读）、W/Q 读延迟 2 拍、b_wstrb 逐字节写。
//
// plusargs: +adir=<复现包目录>
`timescale 1ns/1ps

import nn_pkg::*;

module tb_op3_static;

  localparam int A_OFF  = 'h060000;
  localparam int B_OFF  = 'h078000;
  localparam int A_WORDS = 200704;   // 802,816 B / 4
  localparam int G_WORDS = 50176;    // 200,704 B / 4
  localparam int W_WORDS = 256;      // 1,024 B / 4
  localparam int Q_WORDS = 28;       // 112 B / 4
  localparam int B_W128  = 12544;    // 200,704 B / 16

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1;

  logic [31:0]  a_words [0:A_WORDS-1];
  logic [31:0]  g_words [0:G_WORDS-1];
  logic [31:0]  w_words [0:W_WORDS-1];
  logic [31:0]  q_words [0:Q_WORDS-1];
  logic [127:0] b_mem   [0:B_W128-1];

  // ---- DUT 端口 ----
  nn_desc_t     desc;
  logic         start, busy, done;
  logic [31:0]  cycles;
  logic [7:0]   err_code;
  logic         w_re;
  logic [23:0]  w_addr;
  logic [127:0] w_rdata;
  logic         q_re;
  logic [12:0]  q_addr;
  logic [63:0]  q_rdata;
  logic [1:0]   a_sel;
  logic         a_re;
  logic [23:0]  a_addr;
  logic [127:0] a_rdata;
  logic [1:0]   b_sel;
  logic         b_we;
  logic [23:0]  b_addr;
  logic [127:0] b_wdata;
  logic [15:0]  b_wstrb;

  // ==========================================================================
  // W 读：w_re 后 2 拍 w_rdata 有效（= nn_mem wpipe 语义）
  // ==========================================================================
  logic        w_re_q;
  logic [23:0] w_addr_q;
  logic [31:0] w_wi;
  logic [127:0] w_comb;
  always_ff @(posedge clk) begin
    if (rst) begin w_re_q <= 1'b0; w_addr_q <= 24'd0; end
    else begin w_re_q <= w_re; w_addr_q <= w_addr; end
  end
  always_comb begin
    w_wi   = (w_addr_q >> 2);
    w_comb = (w_re_q && (w_wi + 3 < W_WORDS))
           ? {w_words[w_wi + 3], w_words[w_wi + 2], w_words[w_wi + 1], w_words[w_wi]}
           : 128'd0;
  end
  always_ff @(posedge clk) begin
    if (rst) w_rdata <= 128'd0;
    else     w_rdata <= w_comb;
  end

  // ==========================================================================
  // Q 读：q_re 后 2 拍 q_rdata 有效（q_addr = 64b 字索引）
  // ==========================================================================
  logic        q_re_q;
  logic [12:0] q_addr_q;
  logic [63:0] q_comb;
  always_ff @(posedge clk) begin
    if (rst) begin q_re_q <= 1'b0; q_addr_q <= 13'd0; end
    else begin q_re_q <= q_re; q_addr_q <= q_addr; end
  end
  always_comb begin
    q_comb = (q_re_q && (q_addr_q < 13'd14))
           ? {q_words[{q_addr_q[11:0], 1'b1}], q_words[{q_addr_q[11:0], 1'b0}]}
           : 64'd0;
  end
  always_ff @(posedge clk) begin
    if (rst) q_rdata <= 64'd0;
    else     q_rdata <= q_comb;
  end

  // ==========================================================================
  // A 读：a_re 后 1 拍 a_rdata 有效（16B 对齐窗口；a_sel 选 A/B 区）
  // ==========================================================================
  logic        a_re_q;
  logic [23:0] a_addr_q;
  logic [1:0]  a_sel_q;
  always_ff @(posedge clk) begin
    if (rst) begin a_re_q <= 1'b0; a_addr_q <= 24'd0; a_sel_q <= 2'd0; end
    else begin a_re_q <= a_re; a_addr_q <= a_addr; a_sel_q <= a_sel; end
  end
  logic [31:0] a_off, a_wi;
  always_comb begin
    a_off = (a_sel_q == 2'd0) ? (a_addr_q - 32'(A_OFF)) : (a_addr_q - 32'(B_OFF));
    a_wi  = (a_off >> 4) * 4;
  end
  assign a_rdata = (a_re_q && (a_sel_q == 2'd0) && (a_wi + 3 < A_WORDS))
                 ? {a_words[a_wi + 3], a_words[a_wi + 2], a_words[a_wi + 1], a_words[a_wi]}
                 : 128'd0;

  // ==========================================================================
  // B 写：b_we 当拍按 b_wstrb 逐字节写（16B 对齐窗口）
  // ==========================================================================
  always @(posedge clk) begin : b_wr
    logic [31:0] off, bi;
    off = b_addr - 32'(B_OFF);
    bi  = off >> 4;
    if (rst) begin
      for (int q = 0; q < B_W128; q++) b_mem[q] <= 128'd0;
    end else if (b_we && (b_sel == 2'd1) && (bi < B_W128)) begin
      for (int j = 0; j < 16; j++)
        if (b_wstrb[j]) b_mem[bi][j*8 +: 8] <= b_wdata[j*8 +: 8];
    end
  end

  // ==========================================================================
  // DUT
  // ==========================================================================
  nn_conv_engine #(.OC_LANES(16), .PX_LANES(8), .W_RD_LAT(2)) u_eng (
    .clk(clk), .rst(rst), .desc(desc), .start(start),
    .busy(busy), .done(done), .cycles(cycles), .err_code(err_code),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .q_re(q_re), .q_addr(q_addr), .q_rdata(q_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr),
    .b_wdata_128(b_wdata), .b_wstrb(b_wstrb)
  );

  // ==========================================================================
  // 主流程
  // ==========================================================================
  string  adir;
  integer fh, rc, i, mis, guard, dummy, rows, n_g, n_a;
  logic [31:0] got, gw;

  initial begin : main
    dummy = $value$plusargs("adir=%s", adir);
    dummy = $value$plusargs("rows=%d", rows);
    if (rows <= 0) rows = 112;
    n_g = (rows * 112 * 16) / 4;
    n_a = (rows * 112 * 64) / 4;
    $display("OP3ST: dir=%s rows=%0d", adir, rows);
    fh = $fopen({adir, "/op3_A.hex"}, "r");
    if (fh == 0) begin $display("OP3ST: FAIL cannot open op3_A.hex"); $fatal; end
    for (i = 0; i < n_a; i++) rc = $fscanf(fh, "%h", a_words[i]);
    $fclose(fh);
    fh = $fopen({adir, "/op3_W.hex"}, "r");
    for (i = 0; i < W_WORDS; i++) rc = $fscanf(fh, "%h", w_words[i]);
    $fclose(fh);
    fh = $fopen({adir, "/op3_Q.hex"}, "r");
    for (i = 0; i < Q_WORDS; i++) rc = $fscanf(fh, "%h", q_words[i]);
    $fclose(fh);
    fh = $fopen({adir, "/op3_golden.hex"}, "r");
    for (i = 0; i < n_g; i++) rc = $fscanf(fh, "%h", g_words[i]);
    $fclose(fh);
    $display("OP3ST: loaded A=%0d W=%0d Q=%0d G=%0d words", n_a, W_WORDS, Q_WORDS, n_g);

    rst = 1'b1;
    for (i = 0; i < 8; i++) @(negedge clk);
    rst = 1'b0;
    for (i = 0; i < 4; i++) @(negedge clk);

    desc = '0;
    desc.op     = 2'd0;
    desc.flags  = 8'h00;
    desc.ks     = 4'd1;
    desc.stride = 2'd1;
    desc.pad    = 3'd0;
    desc.ih     = rows[15:0];
    desc.iw     = 16'd112;
    desc.ic     = 16'd64;
    desc.oc     = 16'd16;
    desc.src    = 32'(A_OFF);
    desc.dst    = 32'(B_OFF);
    desc.woff   = 32'd0;
    desc.qoff   = 32'd0;

    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    guard = 0;
    while ((done !== 1'b1) && (guard < 4000000)) begin
      @(negedge clk);
      guard = guard + 1;
    end
    $display("OP3ST: done=%0d guard=%0d cycles=%0d err=%02x", done, guard, cycles, err_code);

    mis = 0;
    for (i = 0; i < n_g; i++) begin : cmp
      got = b_mem[i >> 2][(i % 4) * 32 +: 32];
      gw  = g_words[i];
      if (got !== gw) begin
        if (mis < 8) $display("OP3ST:   MISMATCH word@%0d got=%08x exp=%08x", i, got, gw);
        mis = mis + 1;
      end
    end
    if ((mis == 0) && (done === 1'b1) && (err_code == 8'h00))
      $display("OP3ST: PASS rows=%0d cycles=%0d words=%0d err=00", rows, cycles, n_g);
    else
      $display("OP3ST: FAIL rows=%0d mis=%0d/%0d done=%0d err=%02x", rows, mis, n_g, done, err_code);
    $finish;
  end

endmodule
