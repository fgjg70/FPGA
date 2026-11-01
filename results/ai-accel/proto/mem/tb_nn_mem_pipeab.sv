`timescale 1ns/1ps

// ============================================================================
// tb_nn_mem_pipeab — nn_mem_pipeab 自检 TB (A=1 B=1) (Q LUTRAM / W 128b / A,B 128b+strobe) 自检 TB
// ----------------------------------------------------------------------------
// 判据: MEM_TB: PASS/FAIL + mismatch/xerr 计数; 所有比较用 !== (X 必报)。
//
// 覆盖:
//   ① W 128b 读: 2 × 20,480 次全量扫描 —— 16B 对齐 + **8B 对齐窗口 (跨 128b 字边界)**,
//      与打包前 32-bit 字序列比对 + FNV (需 +nnw= 或 +nnwq= 镜像)
//   ② Q 64b 读: 全量 6,144 次扫描 (需 +nnq= 或 +nnwq=), 逐字比对 + FNV
//   ③ dbg 装载口: 写 W(128b 字内 lane)/Q(64b 字内半字) 后经 NPU 口回读
//   ④ A/B: 128b 写 + b_wstrb 字节使能 (含半字写不做 RMW)、128b 读、两区不串扰、
//      A/B 边界地址、非法 sel/越界 -> 0
//   ⑤ CPU 窗口: 只 A/B 命中 (1 拍寄存读); W/Q/空洞/越界 读 0; 写忽略 (内容不变)
//   ⑥ 复位: 输出无 X; 复位不清存储内容; 看门狗超时打 FAIL
//
// 运行 (ModelSim):
//   vlib work
//   vlog -sv rv32_pkg.sv nn_pkg.sv nn_mem.sv sim/tb_nn_mem.sv
//   vsim -c -do "run -all; quit -f" work.tb_nn_mem_pipeab +nnwq=<yolo_wq.hex>   (旧口径)
//   或  vsim ... +nnw=<yolo_w.hex> +nnq=<yolo_q.hex>
//   无镜像也能跑: 打印 SKIP, 其余检查照测 (集成 verify 默认不传镜像)。
// ============================================================================

module tb_nn_mem_pipeab #(
  parameter int W_BYTES = 320*1024,
  parameter int Q_BYTES = 48*1024,
  parameter int A_BYTES = 96*1024,
  parameter int B_BYTES = 32*1024,
  parameter int CPU_AW  = 19
);

  localparam int W_WORDS = W_BYTES / 4;
  localparam int W128    = W_BYTES / 16;
  localparam int Q_WORDS = Q_BYTES / 4;
  localparam int Q64     = Q_WORDS / 2;

  localparam logic [31:0] A_OFF  = 32'h0006_0000;
  localparam logic [31:0] B_OFF  = A_OFF + A_BYTES;
  localparam logic [31:0] B_END  = B_OFF + B_BYTES;
  localparam logic [31:0] WIN    = 32'h1 << CPU_AW;

  localparam logic [23:0] A_ADDR = A_OFF[23:0];
  localparam logic [23:0] B_ADDR = B_OFF[23:0];

  // ---- DUT 端口 ----
  logic         clk, rst;
  logic         cpu_re, cpu_we;
  logic [31:0]  cpu_addr, cpu_wdata;
  logic [3:0]   cpu_wstrb;
  logic [31:0]  cpu_rdata;
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
  logic         dbg_we;
  logic         dbg_space;
  logic [16:0]  dbg_addr;
  logic [31:0]  dbg_wdata;

  // ---- 计分板 ----
  int n_checks, n_mismatch, n_xerr, n_w_sweep, n_q_sweep, n_act, n_cpu;

  // ---- 期望值模式 (必须与 proto/mem/gen_wq_image.py 一致) ----
  function automatic logic [31:0] wpat32(input logic [31:0] i);
    wpat32 = (i * 32'h9E37_79B9) ^ 32'hC0DE_0000;
  endfunction
  function automatic logic [31:0] qpat32(input logic [31:0] i);
    qpat32 = (i * 32'h85EB_CA6B) ^ 32'h5A5A_1234;
  endfunction
  // A/B 测试样图
  function automatic logic [31:0] p32(input logic [31:0] j);
    p32 = (j * 32'hA5A5_5A5A) ^ 32'h1234_5678;
  endfunction
  function automatic logic [127:0] p128(input logic [31:0] j);
    p128 = {p32(4*j+3), p32(4*j+2), p32(4*j+1), p32(4*j)};
  endfunction
  function automatic logic [31:0] fnv1a_byte(input logic [31:0] h, input logic [7:0] b);
    fnv1a_byte = (h ^ 32'(b)) * 32'd16777619;
  endfunction

  // ---- 时钟 ----
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---- 检查任务 ----
  task automatic chk32(input logic [31:0] a, input logic [31:0] e, input string m);
    n_checks++;
    if (^a === 1'bx) begin n_xerr++; if (n_xerr <= 10) $display("[MEM_TB] X-ERR  %s : %b", m, a); end
    else if (a !== e) begin n_mismatch++; if (n_mismatch <= 20)
      $display("[MEM_TB] MISMATCH %s : act=0x%08x exp=0x%08x", m, a, e); end
  endtask
  task automatic chk64(input logic [63:0] a, input logic [63:0] e, input string m);
    n_checks++;
    if ((^a) === 1'bx) begin n_xerr++; if (n_xerr <= 10) $display("[MEM_TB] X-ERR  %s : %b", m, a); end
    else if (a !== e) begin n_mismatch++; if (n_mismatch <= 20)
      $display("[MEM_TB] MISMATCH %s : act=0x%016x exp=0x%016x", m, a, e); end
  endtask
  task automatic chk128(input logic [127:0] a, input logic [127:0] e, input string m);
    n_checks++;
    if ((^a) === 1'bx) begin n_xerr++; if (n_xerr <= 10) $display("[MEM_TB] X-ERR  %s : %b", m, a); end
    else if (a !== e) begin n_mismatch++; if (n_mismatch <= 20)
      $display("[MEM_TB] MISMATCH %s : act=0x%032x exp=0x%032x", m, a, e); end
  endtask

  // ---- 总线驱动任务 (negedge 驱动, 下一 negedge 采样 = 1 拍口径) ----
  task automatic idle_all;
    cpu_re = 0; cpu_we = 0; cpu_addr = 0; cpu_wdata = 0; cpu_wstrb = 0;
    w_re = 0; w_addr = 0;
    q_re = 0; q_addr = 0;
    a_re = 0; a_sel = 0; a_addr = 0;
    b_we = 0; b_sel = 0; b_addr = 0; b_wdata = 0; b_wstrb = 0;
    dbg_we = 0; dbg_space = 0; dbg_addr = 0; dbg_wdata = 0;
  endtask

  task automatic cpu_write(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb);
    @(negedge clk);
    cpu_we = 1; cpu_re = 0; cpu_addr = addr; cpu_wdata = data; cpu_wstrb = strb;
    @(negedge clk);
    cpu_we = 0; cpu_wstrb = 0;
  endtask

  // 方案 B: CPU 窗口读共用读口 -> 读延迟 1->2 拍
  task automatic cpu_read(input logic [31:0] addr, output logic [31:0] data);
    @(negedge clk);
    cpu_re = 1; cpu_we = 0; cpu_addr = addr; cpu_wstrb = 0;
    @(negedge clk);
    @(negedge clk);
    data = cpu_rdata;
    cpu_re = 0;
  endtask

  task automatic w_read(input logic [23:0] addr, output logic [127:0] data);
    @(negedge clk);
    w_re = 1; w_addr = addr;
    @(negedge clk);
    data = w_rdata;
    w_re = 0;
  endtask

  task automatic q_read(input logic [12:0] idx, output logic [63:0] data);
    @(negedge clk);
    q_re = 1; q_addr = idx;
    @(negedge clk);
    data = q_rdata;
    q_re = 0;
  endtask

  // 方案 B: a 读延迟 1->2 拍, 多等 1 拍再采样
  task automatic a_read(input logic [23:0] addr, input logic [1:0] sel, output logic [127:0] data);
    @(negedge clk);
    a_re = 1; a_sel = sel; a_addr = addr;
    @(negedge clk);
    @(negedge clk);
    data = a_rdata;
    a_re = 0;
  endtask

  // 方案 A: NPU b 写延迟 1->2 拍, deassert 后再等 1 拍再返回
  task automatic b_write(input logic [23:0] addr, input logic [1:0] sel,
                         input logic [127:0] data, input logic [15:0] strb);
    @(negedge clk);
    b_we = 1; b_sel = sel; b_addr = addr; b_wdata = data; b_wstrb = strb;
    @(negedge clk);
    b_we = 0; b_wstrb = 0;
    @(negedge clk);
  endtask

  task automatic dbg_write(input logic space, input logic [16:0] addr, input logic [31:0] data);
    @(negedge clk);
    dbg_we = 1; dbg_space = space; dbg_addr = addr; dbg_wdata = data;
    @(negedge clk);
    dbg_we = 0;
  endtask

  // 期望值 (无镜像时全 0)
  function automatic logic [127:0] w_exp(input bit has_img, input logic [31:0] k128);
    if (has_img) w_exp = {wpat32(4*k128+3), wpat32(4*k128+2), wpat32(4*k128+1), wpat32(4*k128)};
    else         w_exp = 128'b0;
  endfunction
  // 8B 对齐的 16B 窗口 (w_addr = 16k+8): 32-bit 字序列 [4k+2 .. 4k+5],
  // 末字 k=20479 时高 8B 越出 W 区 -> 0。
  function automatic logic [127:0] w_exp_odd(input bit has_img, input logic [31:0] k128);
    logic [31:0] w0, w1, w2, w3;
    if (!has_img) begin
      w0 = 32'h0; w1 = 32'h0; w2 = 32'h0; w3 = 32'h0;
    end else begin
      w0 = (4*k128+2 < 32'(W_WORDS)) ? wpat32(4*k128+2) : 32'h0;
      w1 = (4*k128+3 < 32'(W_WORDS)) ? wpat32(4*k128+3) : 32'h0;
      w2 = (4*k128+4 < 32'(W_WORDS)) ? wpat32(4*k128+4) : 32'h0;
      w3 = (4*k128+5 < 32'(W_WORDS)) ? wpat32(4*k128+5) : 32'h0;
    end
    w_exp_odd = {w3, w2, w1, w0};
  endfunction
  function automatic logic [63:0] q_exp(input bit has_img, input logic [31:0] k64);
    if (has_img) q_exp = {qpat32(2*k64+1), qpat32(2*k64)};
    else         q_exp = 64'b0;
  endfunction

  // ==========================================================================
  // 主序列
  // ==========================================================================
  logic [31:0]  rd32;
  logic [63:0]  rd64, exp64;
  logic [127:0] rd128, exp128;
  logic [31:0]  fnv_wr, fnv_we, fnv_qr, fnv_qe;
  logic         has_wq, has_w, has_q, has_wimg, has_qimg;

  initial begin : main
    n_checks = 0; n_mismatch = 0; n_xerr = 0;
    n_w_sweep = 0; n_q_sweep = 0; n_act = 0; n_cpu = 0;
    fnv_wr = 32'h811c_9dc5; fnv_we = 32'h811c_9dc5;
    fnv_qr = 32'h811c_9dc5; fnv_qe = 32'h811c_9dc5;

    has_wq   = $test$plusargs("nnwq");
    has_w    = $test$plusargs("nnw");
    has_q    = $test$plusargs("nnq");
    has_wimg = has_wq || has_w;
    has_qimg = has_wq || has_q;

    idle_all();
    rst = 1;

    // ---------- ⑥ 复位: 输出无 X, 全 0 ----------
    repeat (3) @(negedge clk);
    chk32(cpu_rdata, 32'h0, "reset: cpu_rdata");
    chk64(q_rdata, 64'h0, "reset: q_rdata");
    chk128(a_rdata, 128'h0, "reset: a_rdata");
    chk128(w_rdata, 128'h0, "reset: w_rdata");
    @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);
    chk128(w_rdata, 128'h0, "post-reset: w_rdata");
    chk64(q_rdata, 64'h0, "post-reset: q_rdata");

    // ---------- ① W 128b 全量扫描 (2 × 20,480 次: 16B 对齐 + 8B 对齐跨字) ----------
    if (has_wimg) begin : w_sweep
      $display("[MEM_TB] W sweep start: %0d x 128b aligned + %0d x 128b 8B-window (%0d x 32b words)",
               W128, W128, W_WORDS);
      for (int k = 0; k < W128; k++) begin
        w_read(24'(k * 16), rd128);
        exp128 = w_exp(1'b1, k);
        n_w_sweep++;
        n_checks++;
        if ((^rd128) === 1'bx) begin
          n_xerr++; if (n_xerr <= 10) $display("[MEM_TB] X-ERR W[%0d]", k);
        end else if (rd128 !== exp128) begin
          n_mismatch++; if (n_mismatch <= 20)
            $display("[MEM_TB] MISMATCH W[%0d] act=0x%032x exp=0x%032x", k, rd128, exp128);
        end
        for (int bi = 0; bi < 16; bi++) begin
          fnv_wr = fnv1a_byte(fnv_wr, rd128[8*bi +: 8]);
          fnv_we = fnv1a_byte(fnv_we, exp128[8*bi +: 8]);
        end
      end
      // 8B 对齐窗口 (w_addr[3]=1, 跨 128b 字边界; 引擎 v3 的 8-lane tile 会发这种地址)
      for (int k = 0; k < W128; k++) begin
        w_read(24'(k * 16 + 8), rd128);
        exp128 = w_exp_odd(1'b1, k);
        n_w_sweep++;
        n_checks++;
        if ((^rd128) === 1'bx) begin
          n_xerr++; if (n_xerr <= 10) $display("[MEM_TB] X-ERR Wodd[%0d]", k);
        end else if (rd128 !== exp128) begin
          n_mismatch++; if (n_mismatch <= 20)
            $display("[MEM_TB] MISMATCH Wodd[%0d] act=0x%032x exp=0x%032x", k, rd128, exp128);
        end
        for (int bi = 0; bi < 16; bi++) begin
          fnv_wr = fnv1a_byte(fnv_wr, rd128[8*bi +: 8]);
          fnv_we = fnv1a_byte(fnv_we, exp128[8*bi +: 8]);
        end
      end
      $display("[MEM_TB] W sweep done: %0d reads, fnv=0x%08x/0x%08x",
               n_w_sweep, fnv_wr, fnv_we);
      chk32(fnv_wr, fnv_we, "W full-sweep (aligned+odd) FNV");
    end else begin
      $display("[MEM_TB] SKIP W sweep (no +nnw/+nnwq image)");
    end

    // ---------- ② Q 64b 全量扫描 (6,144 次) ----------
    if (has_qimg) begin : q_sweep
      $display("[MEM_TB] Q sweep start: %0d x 64b", Q64);
      for (int k = 0; k < Q64; k++) begin
        q_read(13'(k), rd64);
        exp64 = q_exp(1'b1, k);
        n_q_sweep++;
        n_checks++;
        if ((^rd64) === 1'bx) begin
          n_xerr++; if (n_xerr <= 10) $display("[MEM_TB] X-ERR Q[%0d]", k);
        end else if (rd64 !== exp64) begin
          n_mismatch++; if (n_mismatch <= 20)
            $display("[MEM_TB] MISMATCH Q[%0d] act=0x%016x exp=0x%016x", k, rd64, exp64);
        end
        for (int bi = 0; bi < 8; bi++) begin
          fnv_qr = fnv1a_byte(fnv_qr, rd64[8*bi +: 8]);
          fnv_qe = fnv1a_byte(fnv_qe, exp64[8*bi +: 8]);
        end
      end
      $display("[MEM_TB] Q sweep done: %0d reads, fnv=0x%08x/0x%08x",
               n_q_sweep, fnv_qr, fnv_qe);
      chk32(fnv_qr, fnv_qe, "Q full-sweep FNV");
    end else begin
      $display("[MEM_TB] SKIP Q sweep (no +nnq/+nnwq image)");
    end

    // ---------- ③ dbg 装载口 (W lane / Q half) ----------
    dbg_write(1'b0, 17'd100, 32'hDEAD_BEEF);
    w_read(24'(400), rd128);
    exp128 = w_exp(has_wimg, 32'd25);
    exp128[31:0] = 32'hDEAD_BEEF;
    chk128(rd128, exp128, "dbg W write word100 lane0");
    dbg_write(1'b0, 17'd32768, 32'h1122_3344);
    w_read(24'(32768*4), rd128);
    exp128 = w_exp(has_wimg, 32'd8192);
    exp128[31:0] = 32'h1122_3344;
    chk128(rd128, exp128, "dbg W write segB first word");
    dbg_write(1'b0, 17'd81919, 32'hC0FF_EE00);
    w_read(24'(81919*4 - 12), rd128);
    exp128 = w_exp(has_wimg, 32'd20479);
    exp128[127:96] = 32'hC0FF_EE00;
    chk128(rd128, exp128, "dbg W write last word lane3");
    dbg_write(1'b1, 17'd1, 32'hCAFE_BABE);
    q_read(13'd0, rd64);
    exp64 = q_exp(has_qimg, 32'd0);
    exp64[63:32] = 32'hCAFE_BABE;
    chk64(rd64, exp64, "dbg Q write word1 (half1)");
    dbg_write(1'b1, 17'd12287, 32'h0BAD_F00D);
    q_read(13'd6143, rd64);
    exp64 = q_exp(has_qimg, 32'd6143);
    exp64[63:32] = 32'h0BAD_F00D;
    chk64(rd64, exp64, "dbg Q write last word (half1)");


    // ---------- ③b 方案A+B 契约: b 写延迟 2 拍 (commit 前读旧值, commit 后读新值) ----------
    b_write(A_ADDR + 24'h1F0, 2'd0, 128'h0, 16'hFFFF);
    @(negedge clk);
    b_we = 1; b_sel = 2'd0; b_addr = A_ADDR + 24'h1F0;
    b_wdata = {4{32'hC0DE_1234}}; b_wstrb = 16'hFFFF;
    a_re = 1; a_sel = 2'd0; a_addr = A_ADDR + 24'h1F0;
    @(negedge clk);
    b_we = 0; b_wstrb = 0;
    @(negedge clk);
    chk128(a_rdata, 128'h0, "AB contract: b-write not visible before commit");
    a_re = 1; a_sel = 2'd0; a_addr = A_ADDR + 24'h1F0;
    @(negedge clk);
    chk128(a_rdata, {4{32'hC0DE_1234}}, "AB contract: b-write visible after commit");
    a_re = 0;

    // ---------- ④ A/B: 128b 写 + strobe + 128b 读 ----------
    b_write(A_ADDR + 24'h0, 2'd0, p128(32'd1), 16'hFFFF);
    a_read(A_ADDR + 24'h0, 2'd0, rd128);
    chk128(rd128, p128(32'd1), "A 128b write/read @0");
    n_act++;
    b_write(A_ADDR + 24'h10, 2'd0, p128(32'd2), 16'h00FF);
    a_read(A_ADDR + 24'h10, 2'd0, rd128);
    exp128 = {64'h0, p128(32'd2)[63:0]};
    chk128(rd128, exp128, "A half-word write low64 only (no RMW)");
    b_write(A_ADDR + 24'h10, 2'd0, p128(32'd3), 16'hFF00);
    a_read(A_ADDR + 24'h10, 2'd0, rd128);
    exp128 = {p128(32'd3)[127:64], p128(32'd2)[63:0]};
    chk128(rd128, exp128, "A half-word write high64 only");
    n_act++;
    b_write(A_ADDR + 24'h20, 2'd0, {120'h0, 32'hA1B2C3D4}, 16'h0001);
    a_read(A_ADDR + 24'h20, 2'd0, rd128);
    chk128(rd128, {120'h0, 8'hD4}, "A single-byte write (strobes)");
    n_act++;
    b_write(A_ADDR + 24'(A_BYTES - 16), 2'd0, p128(32'd4), 16'hFFFF);
    a_read(A_ADDR + 24'(A_BYTES - 16), 2'd0, rd128);
    chk128(rd128, p128(32'd4), "A last 16B group");
    n_act++;
    b_write(B_ADDR + 24'(B_BYTES - 16), 2'd1, p128(32'd5), 16'hFFFF);
    a_read(B_ADDR + 24'(B_BYTES - 16), 2'd1, rd128);
    chk128(rd128, p128(32'd5), "B last 16B group");
    n_act++;
    b_write(A_ADDR + 24'h80, 2'd0, p128(32'd6), 16'hFFFF);
    b_write(B_ADDR + 24'h80, 2'd1, p128(32'd7), 16'hFFFF);
    a_read(A_ADDR + 24'h80, 2'd0, rd128);
    chk128(rd128, p128(32'd6), "A/B crosstalk: A @0x80");
    a_read(B_ADDR + 24'h80, 2'd1, rd128);
    chk128(rd128, p128(32'd7), "A/B crosstalk: B @0x80");
    n_act += 2;
    a_read(A_ADDR + 24'h0, 2'd1, rd128);
    chk128(rd128, 128'h0, "a sel=1 with A addr -> 0");
    a_read(B_ADDR + 24'h0, 2'd0, rd128);
    chk128(rd128, 128'h0, "a sel=0 with B addr -> 0");
    a_read(24'h000000, 2'd0, rd128);
    chk128(rd128, 128'h0, "a W area addr -> 0");
    a_read(24'h0005_C000, 2'd0, rd128);
    chk128(rd128, 128'h0, "a hole addr -> 0");
    b_write(B_ADDR + 24'h0, 2'd0, p128(32'd8), 16'hFFFF);   // sel 与地址不符 -> 忽略
    a_read(B_ADDR + 24'h0, 2'd1, rd128);
    chk128(rd128, 128'h0, "b sel mismatch write ignored");
    n_act++;

    // ---------- ⑤ CPU 窗口: A/B only ----------
    cpu_write(A_ADDR + 32'h40, 32'h1234_5678, 4'hF);
    cpu_read (A_ADDR + 32'h40, rd32);
    chk32(rd32, 32'h1234_5678, "CPU A word write/read");
    n_cpu++;
    cpu_write(A_ADDR + 32'h44, 32'h0, 4'hF);
    cpu_write(A_ADDR + 32'h44, 32'hAABB_CCDD, 4'b0101);
    cpu_read (A_ADDR + 32'h44, rd32);
    chk32(rd32, 32'h00BB_00DD, "CPU A byte write strb=0101");
    n_cpu++;
    cpu_write(B_ADDR + 32'h40, 32'h0BAD_CAFE, 4'hF);
    cpu_read (B_ADDR + 32'h40, rd32);
    chk32(rd32, 32'h0BAD_CAFE, "CPU B word write/read");
    n_cpu++;
    cpu_read(32'h0000_1000, rd32);
    chk32(rd32, 32'h0, "CPU read W area -> 0");
    n_cpu++;
    cpu_read(32'h0005_0000, rd32);
    chk32(rd32, 32'h0, "CPU read Q area -> 0");
    n_cpu++;
    cpu_read(32'h0005_C000, rd32);
    chk32(rd32, 32'h0, "CPU read hole 0x5C000 -> 0");
    n_cpu++;
    cpu_read(WIN, rd32);
    chk32(rd32, 32'h0, "CPU read addr==512KB -> 0");
    n_cpu++;
    dbg_write(1'b0, 17'd1024, 32'h5A5A_5A5A);
    cpu_write(32'h0000_1000, 32'hFFFF_FFFF, 4'hF);
    w_read(24'h0000_1000, rd128);
    exp128 = w_exp(has_wimg, 32'd256);
    exp128[31:0] = 32'h5A5A_5A5A;
    chk128(rd128, exp128, "CPU write W ignored (dbg value kept)");
    n_cpu++;
    cpu_write(32'h0005_0050, 32'hFFFF_FFFF, 4'hF);
    q_read(13'd10, rd64);
    chk64(rd64, q_exp(has_qimg, 32'd10), "CPU write Q ignored");
    n_cpu++;

    // ---------- ⑥ 中途复位: 输出归 0, 存储不清 ----------
    @(negedge clk);
    rst = 1;
    repeat (2) @(negedge clk);
    chk32(cpu_rdata, 32'h0, "mid-reset: cpu_rdata=0");
    chk64(q_rdata, 64'h0, "mid-reset: q_rdata=0");
    chk128(a_rdata, 128'h0, "mid-reset: a_rdata=0");
    chk128(w_rdata, 128'h0, "mid-reset: w_rdata=0");
    @(negedge clk);
    rst = 0;
    a_read(A_ADDR + 24'h0, 2'd0, rd128);
    chk128(rd128, p128(32'd1), "after reset: A content retained");
    w_read(24'(400), rd128);
    exp128 = w_exp(has_wimg, 32'd25);
    exp128[31:0] = 32'hDEAD_BEEF;
    chk128(rd128, exp128, "after reset: dbg W content retained");
    cpu_read(A_ADDR + 32'h40, rd32);
    chk32(rd32, 32'h1234_5678, "after reset: CPU-visible A content retained");
    n_cpu++;

    // ---------- 收尾 ----------
    $display("[MEM_TB] SUMMARY checks=%0d w_sweep=%0d q_sweep=%0d act=%0d cpu=%0d",
             n_checks, n_w_sweep, n_q_sweep, n_act, n_cpu);
    if (n_mismatch == 0 && n_xerr == 0)
      $display("MEM_TB: PASS (checks=%0d, mismatch=0, xerr=0)", n_checks);
    else
      $display("MEM_TB: FAIL (checks=%0d, mismatch=%0d, xerr=%0d)",
               n_checks, n_mismatch, n_xerr);
    $finish;
  end

  // ---- 看门狗 ----
  initial begin : watchdog
    repeat (200000) @(posedge clk);
    $display("MEM_TB: FAIL (watchdog timeout)");
    $fatal(1);
  end

  // ==========================================================================
  // DUT
  // ==========================================================================
  nn_mem_pipeab #(
    .W_BYTES (W_BYTES),
    .Q_BYTES (Q_BYTES),
    .A_BYTES (A_BYTES),
    .B_BYTES (B_BYTES),
    .CPU_AW  (CPU_AW)
  ) u_dut (
    .clk       (clk),
    .rst       (rst),
    .cpu_re    (cpu_re),
    .cpu_we    (cpu_we),
    .cpu_addr  (cpu_addr),
    .cpu_wdata (cpu_wdata),
    .cpu_wstrb (cpu_wstrb),
    .cpu_rdata (cpu_rdata),
    .w_re      (w_re),
    .w_addr    (w_addr),
    .w_rdata   (w_rdata),
    .q_re      (q_re),
    .q_addr    (q_addr),
    .q_rdata   (q_rdata),
    .a_sel     (a_sel),
    .a_re      (a_re),
    .a_addr    (a_addr),
    .a_rdata   (a_rdata),
    .b_sel     (b_sel),
    .b_we      (b_we),
    .b_addr    (b_addr),
    .b_wdata   (b_wdata),
    .b_wstrb   (b_wstrb),
    .dbg_we    (dbg_we),
    .dbg_space (dbg_space),
    .dbg_addr  (dbg_addr),
    .dbg_wdata (dbg_wdata)
  );

endmodule
