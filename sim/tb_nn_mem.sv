`timescale 1ns/1ps

// ============================================================================
// tb_nn_mem.sv — nn_mem v0.7 (Q LUTRAM / W 128b / A,B 128b+strobe) 自检 TB
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
//   vsim -c -do "run -all; quit -f" work.tb_nn_mem +nnwq=<yolo_wq.hex>   (旧口径)
//   或  vsim ... +nnw=<yolo_w.hex> +nnq=<yolo_q.hex>
//   无镜像也能跑: 打印 SKIP, 其余检查照测 (集成 verify 默认不传镜像)。
// ============================================================================

module tb_nn_mem #(
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
  // ---- [M2] 流式 W/Q 端口 ----
  logic         w_mode, w_bank_sel, wfill_we;
  logic [17:0]  wfill_addr;
  logic [63:0]  wfill_wdata;
  logic         q_bank_sel, qfill_we;
  logic [12:0]  qfill_addr;
  logic [63:0]  qfill_wdata;

  // ---- 计分板 ----
  int n_checks, n_mismatch, n_xerr, n_w_sweep, n_q_sweep, n_act, n_cpu;
  int n_legacy, n_stream;      // [M2] legacy(ROM 路径) / stream(w_mode=1) 检查点计数
  localparam int WBANK64 = 20480;   // 单银行 64-bit 字数 (160KiB, 与 nn_pkg::NN_W_BANK_W64 一致)
  localparam int QBANK64 = 1024;    // Q 影子银行 64-bit 字数 (8KiB)

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
    // [M2] 默认 = ROM 兼容路径: w_mode=0, 银行 0, 填充关闭
    w_mode = 0; w_bank_sel = 0; wfill_we = 0; wfill_addr = 0; wfill_wdata = 0;
    q_bank_sel = 0; qfill_we = 0; qfill_addr = 0; qfill_wdata = 0;
  endtask

  task automatic cpu_write(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb);
    @(negedge clk);
    cpu_we = 1; cpu_re = 0; cpu_addr = addr; cpu_wdata = data; cpu_wstrb = strb;
    @(negedge clk);
    cpu_we = 0; cpu_wstrb = 0;
  endtask

  task automatic cpu_read(input logic [31:0] addr, output logic [31:0] data);
    @(negedge clk);
    cpu_re = 1; cpu_we = 0; cpu_addr = addr; cpu_wstrb = 0;
    @(negedge clk);
    data = cpu_rdata;
    cpu_re = 0;
  endtask

  // [wpipe] W 读时延 1->2 拍: 多等 1 拍再采样
  task automatic w_read(input logic [23:0] addr, output logic [127:0] data);
    @(negedge clk);
    w_re = 1; w_addr = addr;
    @(negedge clk);
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

  task automatic a_read(input logic [23:0] addr, input logic [1:0] sel, output logic [127:0] data);
    @(negedge clk);
    a_re = 1; a_sel = sel; a_addr = addr;
    @(negedge clk);
    data = a_rdata;
    a_re = 0;
  endtask

  task automatic b_write(input logic [23:0] addr, input logic [1:0] sel,
                         input logic [127:0] data, input logic [15:0] strb);
    @(negedge clk);
    b_we = 1; b_sel = sel; b_addr = addr; b_wdata = data; b_wstrb = strb;
    @(negedge clk);
    b_we = 0; b_wstrb = 0;
  endtask

  task automatic dbg_write(input logic space, input logic [16:0] addr, input logic [31:0] data);
    @(negedge clk);
    dbg_we = 1; dbg_space = space; dbg_addr = addr; dbg_wdata = data;
    @(negedge clk);
    dbg_we = 0;
  endtask

  // ---- [M2] 流式填充任务: wfill 写非活动银行 (~w_bank_sel), qfill 写 ~q_bank_sel ----
  task automatic wfill_word(input logic [17:0] a, input logic [63:0] d);
    @(negedge clk);
    wfill_we = 1; wfill_addr = a; wfill_wdata = d;
    @(negedge clk);
    wfill_we = 0;
  endtask

  task automatic qfill_word(input logic [12:0] a, input logic [63:0] d);
    @(negedge clk);
    qfill_we = 1; qfill_addr = a; qfill_wdata = d;
    @(negedge clk);
    qfill_we = 0;
  endtask

  // 流式读 + 比对 (w_addr = wi*8, 自动按当前 w_bank_sel 选银行)
  task automatic chk_w_stream(input int bank, input int wi, input string m);
    logic [127:0] rdx;
    w_read(24'(wi*8), rdx);
    chk128(rdx, w_exp_stream(bank, wi), m);
    n_stream++;
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

  // ---- [M2] 流式模式测试样图: 由 (bank, 银行内 64b 字序号) 唯一确定 ----
  function automatic logic [63:0] wbank64(input int bank, input int wi);
    wbank64 = {p32(32'(wi*2 + bank*100003 + 7)), p32(32'(wi*2 + bank*100003))};
  endfunction
  function automatic logic [63:0] qbank64(input int bank, input int qi);
    qbank64 = {qpat32(32'(qi*2 + bank*7777 + 1)), qpat32(32'(qi*2 + bank*7777))};
  endfunction
  // 流式模式 16B 窗口期望: {下一个 64b 字, 当前 64b 字}; 银行末字 next -> 0
  function automatic logic [127:0] w_exp_stream(input int bank, input int wi);
    logic [63:0] nxt;
    if (wi >= WBANK64 - 1) nxt = 64'b0;
    else                   nxt = wbank64(bank, wi + 1);
    w_exp_stream = {nxt, wbank64(bank, wi)};
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
    n_legacy = 0; n_stream = 0;
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


    // ---------- ③c [wpipe] W 读时延契约: 地址拍 +1 拍仍无效, +2 拍才有效 ----------
    dbg_write(1'b0, 17'd0, 32'hDEAD_BEEF);      // W word0 low
    dbg_write(1'b0, 17'd1, 32'h1234_5678);      // W word0 high
    dbg_write(1'b0, 17'd2, 32'h0);              // W word1 = next64 清零 (镜像里非 0)
    dbg_write(1'b0, 17'd3, 32'h0);
    @(negedge clk);
    w_re = 1; w_addr = 24'h0;
    @(negedge clk);                              // +1 拍: 无前次有效读 -> w_rdata 必须为 0
    chk128(w_rdata, 128'h0, "wpipe contract: W data NOT valid at +1 cycle");
    @(negedge clk);                              // +2 拍: 数据有效
    chk128(w_rdata, {64'h0, 64'h1234_5678_DEAD_BEEF},
           "wpipe contract: W data valid at +2 cycle");
    w_re = 0;

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

    // ==========================================================================
    // [M2] 流式模式 (w_mode=1) 用例:
    //   S1 填 bank0 -> 翻转读 bank0; S2 填 bank1 -> 读 bank1 (含跨段/末字);
    //   S3 银行翻转/内容保持; S4 Q 影子银行 (2x8KiB) 填充/读回/翻转/越界;
    //   S5 并发: 引擎连续读活动银行 + 填充写非活动银行; S6 模式回到 ROM 路径自洽。
    //   全部 pattern 由 TB 自己写入 (不依赖 +nnwq 镜像), 因此有/无镜像两种口径都可跑。
    // ==========================================================================
    n_legacy = n_checks;
    $display("[MEM_TB] SUMMARY_LEGACY(ROM 路径) checks=%0d w_sweep=%0d q_sweep=%0d act=%0d cpu=%0d",
             n_legacy, n_w_sweep, n_q_sweep, n_act, n_cpu);

    n_stream = 0;
    w_mode   = 1'b1;
    w_bank_sel = 1'b1;

    // ---------- S1: 填 bank0 (活动=bank1 => 填非活动银行), 翻转后读 bank0 ----------
    //   bank0 的可填充区 = wi < 16384 (128KiB): 共享 b 段的上 32KiB 在活动 bank=1 时
    //   port B 必须留给引擎 next 读, 填充写被丢弃 -> 单层 wlen <= 128KiB 约束 (见 S1b)。
    for (int i = 0; i < 16; i++)        wfill_word(18'(i),     wbank64(0, i));
    for (int i = 16368; i < 16384; i++) wfill_word(18'(i),     wbank64(0, i));
    w_bank_sel = 1'b0;
    for (int i = 0; i < 15; i++)        chk_w_stream(0, i,     "S1 bank0 read a 区");
    for (int i = 16368; i < 16383; i++) chk_w_stream(0, i,     "S1 bank0 read a 区高段");
    chk_w_stream(0, 16382, "S1 bank0 read 118KiB 附近 (16B 窗口跨字)");

    // ---------- S1b: 文档化约束实测: bank0 高 32KiB (wi>=16384, 共享 b 段) 的填充被丢弃 ----------
    w_bank_sel = 1'b0;
    w_read(24'(16384*8), rd128);          // 先读 b[0..1] 的当前值
    exp128 = rd128;
    w_bank_sel = 1'b1;                    // 活动 bank1 => 试图填 bank0 的高 32KiB
    wfill_word(18'(16384), 64'hDEAD_BEEF_DEAD_BEEF);
    wfill_word(18'(16385), 64'hDEAD_BEEF_DEAD_BEEF);
    w_bank_sel = 1'b0;
    w_read(24'(16384*8), rd128);
    chk128(rd128, exp128, "S1b bank0 高 32KiB 填充被丢弃 (共享 b 段 portB 约束)");
    n_stream++;

    // ---------- S2: 填 bank1 (活动=bank0), 翻转后读 bank1 (b->c / c->d 跨段) ----------
    w_bank_sel = 1'b0;
    for (int i = 0; i < 16; i++)        wfill_word(18'(i),     wbank64(1, i));
    for (int i = 4088; i < 4104; i++)   wfill_word(18'(i),     wbank64(1, i));
    for (int i = 12280; i < 12296; i++) wfill_word(18'(i),     wbank64(1, i));
    for (int i = 20464; i < 20480; i++) wfill_word(18'(i),     wbank64(1, i));
    w_bank_sel = 1'b1;
    for (int i = 0; i < 15; i++)        chk_w_stream(1, i,     "S2 bank1 read b 低区");
    for (int i = 4088; i < 4103; i++)   chk_w_stream(1, i,     "S2 bank1 read b->c 跨段");
    for (int i = 12280; i < 12295; i++) chk_w_stream(1, i,     "S2 bank1 read c->d 跨段");
    for (int i = 20464; i < 20479; i++) chk_w_stream(1, i,     "S2 bank1 read d 高区");
    chk_w_stream(1, 20479, "S2 bank1 末字 next=0");

    // ---------- S3: 银行翻转: 同一银行内地址, w_bank_sel 不同 => 不同银行数据 ----------
    for (int i = 0; i < 3; i++) begin
      w_bank_sel = 1'b0; chk_w_stream(0, i, "S3 翻转读 bank0");
      w_bank_sel = 1'b1; chk_w_stream(1, i, "S3 翻转读 bank1");
    end
    w_bank_sel = 1'b0; chk_w_stream(0, 0, "S3 翻回 bank0 内容保持");
    w_bank_sel = 1'b1; chk_w_stream(1, 0, "S3 翻回 bank1 内容保持");

    // ---------- S4: Q 影子银行 (2 x 8KiB) 填充/读回/翻转/越界 ----------
    q_bank_sel = 1'b1;    // 填 Q bank0
    for (int i = 0; i < 16; i++)        qfill_word(13'(i), qbank64(0, i));
    for (int i = 1010; i < 1024; i++)   qfill_word(13'(i), qbank64(0, i));
    q_bank_sel = 1'b0;
    for (int i = 0; i < 16; i++) begin
      q_read(13'(i), rd64); chk64(rd64, qbank64(0, i), "S4 Q bank0 read"); n_stream++;
    end
    for (int i = 1010; i < 1024; i++) begin
      q_read(13'(i), rd64); chk64(rd64, qbank64(0, i), "S4 Q bank0 tail read"); n_stream++;
    end
    // 填 Q bank1 (活动=bank0), 翻转后读 bank1
    for (int i = 0; i < 16; i++)        qfill_word(13'(i), qbank64(1, i));
    for (int i = 1010; i < 1024; i++)   qfill_word(13'(i), qbank64(1, i));
    q_bank_sel = 1'b1;
    for (int i = 0; i < 16; i++) begin
      q_read(13'(i), rd64); chk64(rd64, qbank64(1, i), "S4 Q bank1 read"); n_stream++;
    end
    for (int i = 1010; i < 1024; i++) begin
      q_read(13'(i), rd64); chk64(rd64, qbank64(1, i), "S4 Q bank1 tail read"); n_stream++;
    end
    q_bank_sel = 1'b0;    // bank0 内容仍在
    for (int i = 0; i < 3; i++) begin
      q_read(13'(i), rd64); chk64(rd64, qbank64(0, i), "S4 Q bank0 retained"); n_stream++;
    end
    q_read(13'd1024, rd64); chk64(rd64, 64'b0, "S4 Q addr=1024 -> 0 (影子银行外)"); n_stream++;
    q_read(13'd6143, rd64); chk64(rd64, 64'b0, "S4 Q addr=6143 -> 0 (影子银行外)"); n_stream++;

    // ---------- S5: 并发: 引擎连续读活动银行(bank1) + 填充写非活动银行(bank0) ----------
    w_bank_sel = 1'b1;
    @(negedge clk);
    for (int t = 0; t < 600; t++) begin
      w_re        = 1'b1;
      w_addr      = 24'((t % 15) * 8);          // bank1 已填 0..15, 窗口(pi,pi+1)都确定
      wfill_we    = 1'b1;
      wfill_addr  = 18'(t);                     // 填 bank0 (=~活动银行)
      wfill_wdata = wbank64(0, t);
      @(negedge clk);
      if (t >= 1) begin                        // 读时延 2 拍: 本拍读到 t-1 发的地址
        chk128(w_rdata, w_exp_stream(1, (t - 1) % 15),
               "S5 并发: 活动银行读不受填充影响");
        n_stream++;
      end
    end
    w_re = 1'b0; wfill_we = 1'b0; wfill_addr = 18'd0; wfill_wdata = 64'd0;
    w_bank_sel = 1'b0;
    for (int i = 0; i < 4; i++) chk_w_stream(0, i, "S5 填充的 bank0 数据正确");

    // ---------- S6: 模式回到 ROM 路径 (dbg 预置字经原 ROM 读口读回) + 流式越界 ----------
    w_mode = 1'b0; w_bank_sel = 1'b0; q_bank_sel = 1'b0;
    dbg_write(1'b0, 17'd512, 32'h5A5A_0000);   // 全局 64b 字 256 低半
    dbg_write(1'b0, 17'd513, 32'hA5A5_0001);   // 字 256 高半
    dbg_write(1'b0, 17'd514, 32'h1234_0002);   // 字 257 低半
    dbg_write(1'b0, 17'd515, 32'h5678_0003);   // 字 257 高半
    dbg_write(1'b0, 17'd516, 32'h9ABC_0004);   // 字 258 低半
    dbg_write(1'b0, 17'd517, 32'hDEF0_0005);   // 字 258 高半
    w_read(24'(256*8), rd128);
    chk128(rd128, {64'h5678_0003_1234_0002, 64'hA5A5_0001_5A5A_0000},
           "S6 ROM 模式读回 (全局字 256/257)");
    n_stream++;
    w_read(24'(257*8), rd128);
    chk128(rd128, {64'hDEF0_0005_9ABC_0004, 64'h5678_0003_1234_0002},
           "S6 ROM 模式读回 (全局字 257/258)");
    n_stream++;
    w_mode = 1'b1; w_bank_sel = 1'b1;
    w_read(24'h028000, rd128);                       // 163,840 = 银行容量 -> 越界
    chk128(rd128, 128'h0, "S6 流式越界 w_addr=0x28000 -> 0"); n_stream++;
    w_read(24'h07FFFF, rd128);
    chk128(rd128, 128'h0, "S6 流式越界 w_addr=0x7FFFF -> 0"); n_stream++;
    w_mode = 1'b0; w_bank_sel = 1'b0;                // 回到默认 ROM 模式

    // ---------- 收尾 ----------
    $display("[MEM_TB] SUMMARY checks=%0d w_sweep=%0d q_sweep=%0d act=%0d cpu=%0d",
             n_checks, n_w_sweep, n_q_sweep, n_act, n_cpu);
    $display("[MEM_TB] SUMMARY_LEGACY(ROM)=%0d + STREAM(w_mode=1)=%0d",
             n_legacy, n_stream);
    if (n_mismatch == 0 && n_xerr == 0)
      $display("MEM_TB: PASS (checks=%0d, mismatch=0, xerr=0)", n_checks);
    else
      $display("MEM_TB: FAIL (checks=%0d, mismatch=%0d, xerr=%0d)",
               n_checks, n_mismatch, n_xerr);
    $finish;
  end

  // ---- 看门狗 ----
  // [M2] 200,000 -> 400,000: 增加 w_mode=1 的流式用例 (填充/并发)。带镜像的
  // legacy 全量扫描约 13.6 万拍, 流式用例约 0.4 万拍, 400k 仍有 ~2.4x 余量。
  initial begin : watchdog
    repeat (400000) @(posedge clk);
    $display("MEM_TB: FAIL (watchdog timeout)");
    $fatal(1);
  end

  // ==========================================================================
  // DUT
  // ==========================================================================
  nn_mem #(
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
    .dbg_wdata (dbg_wdata),
    // [M2] 流式 W/Q 端口
    .w_mode      (w_mode),
    .w_bank_sel  (w_bank_sel),
    .wfill_we    (wfill_we),
    .wfill_addr  (wfill_addr),
    .wfill_wdata (wfill_wdata),
    .q_bank_sel  (q_bank_sel),
    .qfill_we    (qfill_we),
    .qfill_addr  (qfill_addr),
    .qfill_wdata (qfill_wdata)
  );

endmodule
