`timescale 1ns/1ps

// ============================================================================
// tb_nn_engine.sv — nn_conv_engine 自校验 TB (阶段 A: 独立 Python 参考向量)
// ----------------------------------------------------------------------------
// 判据 (机器可判定):
//   · 每个 case: 通过 CPU 窗口装载 W/Q + A/B 区域 → 跑 1 个 op → 逐字读回
//     A/B 区域, 与 gen_vectors.py 生成的期望**逐位**比较 (`!==`, X 也算错)
//   · 每个 op 汇总 mismatch 计数; 全部 case PASS 才打印 `ENGINE_TB: PASS`
//
// 向量目录 (由 +vec=<dir> 指定, 默认 results/ai-accel/proto/engine/vec):
//   manifest.txt       每行: name op flags ks st pad ih iw ic oc src dst woff qoff
//   <name>.wq.wr       每行: <窗口字节偏移 hex> <32 位字 hex>
//   <name>.a.wr        A 缓冲初始装载: <64 位字索引 hex> <hi32> <lo32>
//   <name>.b.wr        B 缓冲初始装载: 同上
//   <name>.aexp.wr     A 缓冲期望终值: 同上
//   <name>.bexp.wr     B 缓冲期望终值: 同上
//
// 依赖: nn_pkg.sv, nn_mem.sv (T-mem 的真实实现; 接口同 CONTRACT §9.1 v0.3),
//       nn_conv_engine.sv。nn_mem 上电全 0, 区域外内容不参与比较。
//
// 【v0.8 / M1 扩展 (2026-11-03)】旧 47 个 manifest case **原样保留** (向量/期望全
//   部来自 proto/engine/vec, 与 v0.7 同一份文件), 另加 9 个现场生成的自检 case
//   覆盖新增能力: ReLU(requant M_neg=0)/RELU 优先 LEAKY/ADD 后置 ReLU(含全负)/
//   ADD_R+RELU/IC=864 的 dense-dw-add-copy (icb_n 6→8 bit)。新 case 的向量与
//   expected 由本 TB 内的整数金标生成 (种子固定), 见文件后半 "M1 新增能力自检"。
// ============================================================================

module tb_nn_engine #(
  // [rtl-mem 2026-11-04, M6b op3 仲裁实验] A/B 容量参数化:
  //   默认值与 stock nn_mem 契约一致 (A=96KB / B=32KB) -> 现有 47+9+SA case 逐位不变。
  //   大张量实验用顶层参数覆盖 (ModelSim 在 vsim 命令行覆盖顶层 Verilog 参数):
  //     vsim -gA_BYTES=802816 -gB_BYTES=262144 work.tb_nn_engine +op3iso +op3rows=112 ...
  //   注意 1: nn_mem 内部 B 窗口起点 B_OFF = NN_A_OFF + A_BYTES; 放大 A 后会从 0x78000
  //           推到 NN_A_OFF+A_BYTES。引擎的 a_sel/b_sel 阈值仍是 nn_pkg::NN_B_OFF(0x78000),
  //           所以 B 侧基准地址必须用本 TB 的 AB_BOFF (默认时 AB_BOFF == 0x78000 ==
  //           NN_B_OFF, 默认行为不变; op3iso case 已按 AB_BOFF 取 B 基址)。
  //   注意 2: 放大 A 时 stock manifest/M1/SA case 里把 B 放在 NN_B_OFF 的 case 会因 B 区
  //           起点后移而失配 —— 那是参数覆盖的预期副作用, 此时只看 "OP3ISO: ..." 判据。
  parameter int A_BYTES = 96*1024,
  parameter int B_BYTES = 32*1024
);
  import nn_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  // ---- CPU 数据窗口 (装载/读回) ----
  logic        cpu_re, cpu_we;
  logic [31:0] cpu_addr, cpu_wdata;
  logic [3:0]  cpu_wstrb;
  logic [31:0] cpu_rdata;

  // ---- 引擎 ----
  nn_desc_t    desc;
  logic        start, busy, done;
  logic [31:0] cycles;
  logic [7:0]  err_code;
  logic        w_re;
  logic [23:0] w_addr;
  logic [127:0] w_rdata;
  logic        q_re;
  logic [12:0] q_addr;
  logic [63:0] q_rdata;
  logic [1:0]  a_sel;
  logic        a_re;
  logic [23:0] a_addr;
  logic [127:0] a_rdata;
  logic [1:0]  b_sel;
  logic        b_we;
  logic [23:0] b_addr;
  logic [127:0] b_wdata;
  logic [15:0] b_wstrb;
  logic        dbg_we;
  logic        dbg_space;
  logic [16:0] dbg_addr;
  logic [31:0] dbg_wdata;

  nn_mem #(.A_BYTES(A_BYTES), .B_BYTES(B_BYTES)) u_mem (
    .clk(clk), .rst(rst),
    .cpu_re(cpu_re), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_rdata(cpu_rdata),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .q_re(q_re), .q_addr(q_addr), .q_rdata(q_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata),
    .b_wstrb(b_wstrb),
    .dbg_we(dbg_we), .dbg_space(dbg_space), .dbg_addr(dbg_addr), .dbg_wdata(dbg_wdata),
    // [M2] nn_mem 新增流式口: 本 TB 只测 v0.7 ROM 路径 => 全部 tie 到默认(0), 与 v0.7 完全等价
    .w_mode(1'b0), .w_bank_sel(1'b0),
    .wfill_we(1'b0), .wfill_addr(18'd0), .wfill_wdata(64'd0),
    .q_bank_sel(1'b0), .qfill_we(1'b0), .qfill_addr(13'd0), .qfill_wdata(64'd0)
  );

  nn_conv_engine #(.OC_LANES(16), .PX_LANES(8), .W_RD_LAT(2)) u_eng (
    .clk(clk), .rst(rst), .desc(desc), .start(start),
    .busy(busy), .done(done), .cycles(cycles), .err_code(err_code),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .q_re(q_re), .q_addr(q_addr), .q_rdata(q_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr),
    .b_wdata_128(b_wdata), .b_wstrb(b_wstrb)
  );

  string vecdir;

  // [rtl-mem 2026-11-04] A/B 窗口起点推导 + 参数生效自证:
  //   启动打印一行, 便于在 `-gA_BYTES/-gB_BYTES` 覆盖时核对是否真的生效。
  localparam int AB_AOFF = int'(NN_A_OFF);            // A 窗口起始 0x0006_0000
  localparam int AB_BOFF = int'(NN_A_OFF) + A_BYTES;  // B 窗口起始 (默认 0x0007_8000)
  initial $display("TB_CFG A_BYTES=%0d B_BYTES=%0d A_BASE=0x%08x B_BASE=0x%08x (NN_B_OFF=0x%08x)",
                   A_BYTES, B_BYTES, AB_AOFF, AB_BOFF, int'(NN_B_OFF));

  // ---- 统计 ----
  integer ncase = 0;
  integer npass = 0;
  integer op_cases [0:3];
  integer op_fail  [0:3];
  integer op_mis   [0:3];
  integer op_maxcyc[0:3];
  integer g_mis_a, g_mis_b;
  integer errcases_fail = 0;
  integer nmis_max = 6;      // +misall 时打印全部 mismatch (调试用)

  // ==========================================================================
  // CPU 窗口任务
  // ==========================================================================
  task automatic cpu_wr32(input logic [31:0] addr, input logic [31:0] data);
    begin
      @(negedge clk);
      cpu_we    = 1'b1;
      cpu_re    = 1'b0;
      cpu_addr  = addr;
      cpu_wdata = data;
      cpu_wstrb = 4'hF;
    end
  endtask

  task automatic cpu_rd32(input logic [31:0] addr, output logic [31:0] data);
    begin
      // nn_mem 的 CPU 读口是 1 拍寄存读 (地址 N 拍, 数据 N+1 拍), 与 dmem 同口径
      @(negedge clk);
      cpu_we   = 1'b0;
      cpu_re   = 1'b1;
      cpu_addr = addr;
      @(negedge clk);
      data = cpu_rdata;
    end
  endtask

  task automatic cpu_idle;
    begin
      @(negedge clk);
      cpu_we = 1'b0;
      cpu_re = 1'b0;
      cpu_wstrb = 4'h0;
    end
  endtask

  // ==========================================================================
  // 装载 / 比较任务
  // ==========================================================================
  // v0.7: W/Q 走 mem 的 debug 预装口 (CPU 不可访问); 向量偏移约定:
  //   off <  NN_Q_OFF -> W 区 32-bit 字索引 = off>>2
  //   off >= NN_Q_OFF -> Q 区 32-bit 字索引 = (off-NN_Q_OFF)>>2
  task automatic dbg_wr(input logic sp, input logic [16:0] widx, input logic [31:0] wd);
    begin
      @(negedge clk);
      dbg_we    = 1'b1;
      dbg_space = sp;
      dbg_addr  = widx;
      dbg_wdata = wd;
      @(negedge clk);
      dbg_we    = 1'b0;
    end
  endtask

  task automatic load_wq(input string nm, output integer nw);
    integer fh, rc;
    logic [31:0] off, wd;
    begin
      nw = 0;
      fh = $fopen({vecdir, "/", nm, ".wq.wr"}, "r");
      if (fh == 0) begin
        $display("TB: [FAIL] cannot open %s.wq.wr", nm);
        $fatal;
      end
      rc = $fscanf(fh, "%h %h", off, wd);
      while (rc == 2) begin
        if (off >= NN_Q_OFF)
          dbg_wr(1'b1, 17'((off - NN_Q_OFF) >> 2), wd);
        else
          dbg_wr(1'b0, 17'(off >> 2), wd);
        nw = nw + 1;
        rc = $fscanf(fh, "%h %h", off, wd);
      end
      $fclose(fh);
    end
  endtask

  // 64 位字: 两次 32 位 CPU 写
  task automatic load_buf(input string nm, input string tag,
                          input logic [31:0] base, output integer nw);
    integer fh, rc;
    logic [31:0] idx, hi, lo;
    begin
      nw = 0;
      fh = $fopen({vecdir, "/", nm, ".", tag, ".wr"}, "r");
      if (fh == 0) begin
        $display("TB: [FAIL] cannot open %s.%s.wr", nm, tag);
        $fatal;
      end
      rc = $fscanf(fh, "%h %h %h", idx, hi, lo);
      while (rc == 3) begin
        cpu_wr32(base + (idx << 3), lo);
        cpu_wr32(base + (idx << 3) + 32'd4, hi);
        nw = nw + 2;
        rc = $fscanf(fh, "%h %h %h", idx, hi, lo);
      end
      $fclose(fh);
    end
  endtask

  task automatic check_buf(input string nm, input string tag,
                           input logic [31:0] base, output integer nmis);
    integer fh, rc;
    logic [31:0] idx, ehi, elo, glo, ghi;
    begin
      nmis = 0;
      fh = $fopen({vecdir, "/", nm, ".", tag, "exp.wr"}, "r");
      if (fh == 0) begin
        $display("TB: [FAIL] cannot open %s.%sexp.wr", nm, tag);
        $fatal;
      end
      rc = $fscanf(fh, "%h %h %h", idx, ehi, elo);
      while (rc == 3) begin
        cpu_rd32(base + (idx << 3), glo);
        cpu_rd32(base + (idx << 3) + 32'd4, ghi);
        if (({ghi, glo} !== {ehi, elo})) begin
          if (nmis < nmis_max)
            $display("TB:   MISMATCH %s word@%0d got=%08x_%08x exp=%08x_%08x",
                     tag, idx, ghi, glo, ehi, elo);
          nmis = nmis + 1;
        end
        rc = $fscanf(fh, "%h %h %h", idx, ehi, elo);
      end
      $fclose(fh);
    end
  endtask

  // ==========================================================================
  // 跑一个 op
  // ==========================================================================
  task automatic run_op(output integer ncyc, output logic [7:0] ecode,
                        output logic ok);
    integer guard;
    begin
      guard = 0;
      @(negedge clk);
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      while ((done !== 1'b1) && (guard < 1000000)) begin
        @(negedge clk);
        guard = guard + 1;
      end
      ncyc  = int'(cycles);
      ecode = err_code;
      ok    = (done === 1'b1) && (guard < 1000000) && (ecode == 8'h00);
      @(negedge clk);
      if (busy !== 1'b0) ok = 1'b0;
      @(negedge clk);
    end
  endtask

  // ==========================================================================
  // case 执行
  // ==========================================================================
  task automatic run_case(input string nm, input int op, input int flags,
                          input int ks, input int st, input int pad,
                          input int ih, input int iw, input int ic, input int oc,
                          input int src, input int dst, input int woff, input int qoff,
                          output logic pass, output integer cyc);
    integer mis_a, mis_b, nw;
    integer dummy;
    logic [7:0] ecode;
    logic       ok;
    begin
      // 1) 装载 WQ + A/B
      load_wq(nm, nw);
      load_buf(nm, "a", NN_A_OFF, dummy);
      load_buf(nm, "b", NN_B_OFF, dummy);
      cpu_idle();
      @(negedge clk);
      // 2) 组装描述符并启动
      desc = '0;
      desc.op     = op[1:0];
      desc.flags  = flags[7:0];
      desc.ks     = ks[3:0];
      desc.stride = st[1:0];
      desc.pad    = pad[2:0];
      desc.ih     = ih[15:0];
      desc.iw     = iw[15:0];
      desc.ic     = ic[15:0];
      desc.oc     = oc[15:0];
      desc.src    = src[31:0];
      desc.dst    = dst[31:0];
      desc.woff   = woff[31:0];
      desc.qoff   = (qoff[31:0] >= NN_Q_OFF) ? (qoff[31:0] - NN_Q_OFF) : qoff[31:0];
      run_op(cyc, ecode, ok);
      // 3) 读回比较
      check_buf(nm, "a", NN_A_OFF, mis_a);
      check_buf(nm, "b", NN_B_OFF, mis_b);
      g_mis_a = g_mis_a + mis_a;
      g_mis_b = g_mis_b + mis_b;
      pass = ok && (mis_a == 0) && (mis_b == 0);
      op_cases[op] = op_cases[op] + 1;
      if (!pass) op_fail[op] = op_fail[op] + 1;
      op_mis[op] = op_mis[op] + mis_a + mis_b;
      if (cyc > op_maxcyc[op]) op_maxcyc[op] = cyc;
      $display("CASE %-16s op=%0d k=%0d st=%0d pad=%0d ih=%0d iw=%0d ic=%0d oc=%0d : cyc=%0d misA=%0d misB=%0d err=%02x %s",
               nm, op, ks, st, pad, ih, iw, ic, oc, cyc, mis_a, mis_b, ecode,
               pass ? "PASS" : "FAIL");
    end
  endtask

  // ==========================================================================
  // v0.8 / M1 新增能力自检 (ReLU / ADD 后置 ReLU / IC>512 大通道)
  // --------------------------------------------------------------------------
  // 设计取舍: M1 的写作用域只有本 TB, 所以新 case 的**向量与 expected 全部在本
  //   TB 内**用固定种子的整数金标现场生成 (不落文件、不依赖 proto/engine/vec),
  //   旧 47 个 manifest case 仍逐字节走原路径 —— 两条路径互不影响, 因此
  //   "旧 case 逐位 逐周期不变" 可以机器核对 (见报告 §4 的日志 diff)。
  // 金标语义: CONTRACT §5/§6/§8/§12.3, 与 proto/engine/gen_vectors.py 同口径:
  //   acc   = bias_adj + Σ a_q*w_q                         (int32, 不截断)
  //   M_neg = (M_pos*3277+16384)>>15 (leaky) / M_pos (linear) / 0 (RELU)
  //   y     = (acc >= 0 ? acc*M_pos : acc*M_neg) >> SHIFT   (int64, floor)
  //   q     = clamp(y + zp_out, -128, 127)
  //   ADD   = clamp(q_d + Δ); Δ = q_s (plain) 或 ((q_s-zp_s)*R)>>KADD (ADD_R)
  //   ADD+RELU 再取 max(q, zp_d)   [zp_d = ADD Q 块 byte[1]]
  // ==========================================================================
  localparam int M1_TMAX = 96*1024;     // 单张量字节上限 (= A 区容量)
  localparam int M1_WMAX = 128*1024;    // 单 case 权重上限 (IC=864/OC=144 1x1 = 124,416B)

  logic [7:0] m1_wb [0:M1_WMAX-1];      // 本 case 权重镜像 (dense [tap][ic8][oc8] / dw [tap][oc8])
  logic [7:0] m1_ab [0:M1_TMAX-1];      // A 侧源张量字节
  logic [7:0] m1_db [0:M1_TMAX-1];      // dst 初值 (ADD) / poison (其余)
  logic [7:0] m1_eb [0:M1_TMAX-1];      // 期望输出字节
  int         m1_bias [0:1023];
  int         m1_mpos [0:1023];
  integer     m1_ncase = 0;
  integer     m1_npass = 0;
  integer     m1_nmis  = 0;
  // v0.9 [task-14 Step A] conv add-mode 自检计数
  integer     sa_ncase = 0;
  integer     sa_npass = 0;
  integer     sa_nmis  = 0;

  function automatic int m1_pad8(input int c);
    m1_pad8 = ((c + 7) / 8) * 8;
  endfunction

  // 固定公式的 int8 伪随机 (不用 $random: 可复现、无全局状态)
  function automatic logic signed [7:0] m1_h8(input int a, input int b, input int c);
    int x;
    begin
      x = (a * 32'sd73856093) ^ (b * 32'sd19349663) ^ (c * 32'sd83492791);
      x = x ^ (x >>> 13);
      x = x * 32'sd1274126177;
      x = x ^ (x >>> 16);
      m1_h8 = x[7:0];
    end
  endfunction

  function automatic logic [7:0] m1_get8(input int which, input int off);
    case (which)
      0:       m1_get8 = m1_ab[off];
      1:       m1_get8 = m1_db[off];
      default: m1_get8 = m1_eb[off];
    endcase
  endfunction

  // ---- 写 A/B 张量 (which: 0=ab 1=db; boff = 缓冲内相对偏移) ----
  task automatic m1_wr_words(input logic [31:0] base_abs, input int boff,
                             input int nbytes, input int which);
    logic [31:0] lo32, hi32;
    begin
      for (int k = 0; k < nbytes/8; k++) begin
        lo32 = {m1_get8(which,boff+k*8+3), m1_get8(which,boff+k*8+2),
                m1_get8(which,boff+k*8+1), m1_get8(which,boff+k*8)};
        hi32 = {m1_get8(which,boff+k*8+7), m1_get8(which,boff+k*8+6),
                m1_get8(which,boff+k*8+5), m1_get8(which,boff+k*8+4)};
        cpu_wr32(base_abs + 32'(boff) + 32'(k*8), lo32);
        cpu_wr32(base_abs + 32'(boff) + 32'(k*8) + 32'd4, hi32);
      end
    end
  endtask

  // ---- 读回 A/B 与 m1_eb 逐字节比较; use_lim 时同时统计 <lim 的字节数 ----
  task automatic m1_cmp_words(input string tag, input logic [31:0] base_abs, input int boff,
                              input int nbytes, input int use_lim, input int lim,
                              output int nmis, output int nbelow);
    logic [31:0] glo, ghi;
    logic [7:0]  b;
    begin
      nmis = 0; nbelow = 0;
      for (int k = 0; k < nbytes/8; k++) begin
        cpu_rd32(base_abs + 32'(boff) + 32'(k*8), glo);
        cpu_rd32(base_abs + 32'(boff) + 32'(k*8) + 32'd4, ghi);
        for (int j = 0; j < 8; j++) begin
          b = 8'((j < 4) ? (glo >> (j*8)) : (ghi >> ((j-4)*8)));
          if (b !== m1_get8(2, boff + k*8 + j)) begin
            if (nmis < nmis_max)
              $display("TB:   M1 MISMATCH %s byte@%0d got=%02x exp=%02x",
                       tag, boff + k*8 + j, b, m1_get8(2, boff + k*8 + j));
            nmis = nmis + 1;
          end
          if (use_lim && (int'($signed(b)) < lim)) nbelow = nbelow + 1;
        end
      end
    end
  endtask

  // ---- W 区装载 (dbg 口, 32-bit 字; woff_rel 相对 W 基址) ----
  task automatic m1_load_w(input int nbytes, input int woff_rel);
    begin
      for (int k = 0; k < nbytes/4; k++)
        dbg_wr(1'b0, 17'((woff_rel + k*4) >> 2),
               32'({m1_wb[k*4+3], m1_wb[k*4+2], m1_wb[k*4+1], m1_wb[k*4]}));
    end
  endtask

  // ---- Q 块装载: conv/dwconv (bias int32 + M_pos int16 + 16B tail, CONTRACT §7) ----
  task automatic m1_load_q_conv(input int qoff_rel, input int oc8,
                                input int zp_o, input int zp_i,
                                input int shift, input int leaky);
    int base, lo, hi;
    begin
      base = qoff_rel >> 3;                       // 64b 字索引
      for (int w = 0; w < oc8/2; w++) begin
        dbg_wr(1'b1, 17'(base*2 + w*2),     32'(m1_bias[2*w]));
        dbg_wr(1'b1, 17'(base*2 + w*2 + 1), 32'(m1_bias[2*w+1]));
      end
      for (int w = 0; w < oc8/4; w++) begin
        lo = (m1_mpos[4*w]   & 16'hFFFF) | ((m1_mpos[4*w+1] & 16'hFFFF) << 16);
        hi = (m1_mpos[4*w+2] & 16'hFFFF) | ((m1_mpos[4*w+3] & 16'hFFFF) << 16);
        dbg_wr(1'b1, 17'((base + oc8/2 + w)*2),     32'(lo));
        dbg_wr(1'b1, 17'((base + oc8/2 + w)*2 + 1), 32'(hi));
      end
      lo = (zp_o & 8'hFF) | ((zp_i & 8'hFF) << 8) | ((leaky & 1) << 16) |
           ((shift & 8'hFF) << 24);
      dbg_wr(1'b1, 17'((base + (6*oc8)/8)*2),     32'(lo));
      dbg_wr(1'b1, 17'((base + (6*oc8)/8)*2 + 1), 32'd0);
    end
  endtask

  // ---- Q 块装载: ADD (16B: [0]=zp_s [1]=zp_d [2:3]=R(u16 LE) [4]=KADD) ----
  task automatic m1_load_q_add(input int qoff_rel, input int zp_s, input int zp_d,
                               input int R, input int KADD);
    int w32;
    begin
      w32 = qoff_rel >> 2;
      dbg_wr(1'b1, 17'(w32), 32'((zp_s & 8'hFF) | ((zp_d & 8'hFF) << 8) |
                                 ((R & 16'hFFFF) << 16)));
      dbg_wr(1'b1, 17'(w32 + 1), 32'(KADD & 8'hFF));
    end
  endtask

  // ---- 整数金标: conv / dwconv (含 RELU 负支 M_neg=0) ----
  task automatic m1_golden_conv(input int ks, input int st, input int pad,
                                input int ih, input int iw, input int ic, input int oc,
                                input int flags, input int shift,
                                input int zp_i, input int zp_o,
                                input int srel, input int drel, output int nrelu);
    int ic8, oc8, oh, ow, dw, relu, leaky;
    int oy, ox, ocn, tap, ky, kx, iy, ix, icn, acc, y, v, eidx;
    longint p;
    logic signed [15:0] mn;
    logic signed [7:0]  av, wv;
    begin
      ic8 = m1_pad8(ic);
      oc8 = m1_pad8(oc);
      oh  = (ih + 2*pad - ks)/st + 1;
      ow  = (iw + 2*pad - ks)/st + 1;
      dw    = (flags >> NN_F_DEPTHWISE) & 1;
      relu  = (flags >> NN_F_RELU) & 1;
      leaky = (flags >> NN_F_LEAKY) & 1;
      nrelu = 0;
      for (oy = 0; oy < oh; oy++)
        for (ox = 0; ox < ow; ox++)
          for (ocn = 0; ocn < oc8; ocn++) begin
            eidx = drel + (oy*ow + ox)*oc8 + ocn;
            if (ocn >= oc) begin
              m1_eb[eidx] = 8'(zp_o);              // padding lane: 引擎写 zp_out
            end
            else begin
              acc = m1_bias[ocn];
              for (tap = 0; tap < ks*ks; tap++) begin
                ky = tap / ks;
                kx = tap % ks;
                iy = oy*st + ky - pad;
                ix = ox*st + kx - pad;
                if (dw) begin
                  wv = $signed(m1_wb[tap*oc8 + ocn]);
                  if ((iy >= 0) && (iy < ih) && (ix >= 0) && (ix < iw))
                    av = $signed(m1_ab[(iy*iw + ix)*ic8 + ocn]);
                  else
                    av = 8'(zp_i);
                  acc = acc + int'(av) * int'(wv);
                end
                else begin
                  for (icn = 0; icn < ic; icn++) begin
                    wv = $signed(m1_wb[(tap*ic8 + icn)*oc8 + ocn]);
                    if ((iy >= 0) && (iy < ih) && (ix >= 0) && (ix < iw))
                      av = $signed(m1_ab[(iy*iw + ix)*ic8 + icn]);
                    else
                      av = 8'(zp_i);
                    acc = acc + int'(av) * int'(wv);
                  end
                end
              end
              if (relu && (acc < 0)) begin
                y = 0;                                // M_neg = 0 => y = 0 => q = zp_out
                nrelu = nrelu + 1;
              end
              else begin
                if (acc < 0)
                  mn = leaky ? 16'((m1_mpos[ocn]*3277 + 16384) >>> 15)
                             : 16'(m1_mpos[ocn]);
                else
                  mn = 16'(m1_mpos[ocn]);
                p = longint'(acc) * longint'(mn);
                y = int'(p >>> shift);
              end
              v = y + zp_o;
              if (v > 127) v = 127;
              else if (v < -128) v = -128;
              m1_eb[eidx] = 8'(v);
            end
          end
    end
  endtask

  // ---- 一个 conv/dwconv case: 造向量 -> 装载 -> 跑 -> 金标 -> 逐字节比较 ----
  task automatic m1_run_conv(input string nm,
                             input int ks, input int st, input int pad,
                             input int ih, input int iw, input int ic, input int oc,
                             input int flags, input int seed,
                             input int zp_i, input int zp_o, input int shift,
                             input int src_abs, input int dst_abs, input int woff_rel);
    int ic8, oc8, oh, ow, dw, nw, tap, icn, ocn, pix, c, idx;
    int srel, drel, sbase, dbase, mis, nbelow, nrelu, cyc;
    logic [7:0] ecode;
    logic ok, pass;
    begin
      ic8 = m1_pad8(ic);
      oc8 = m1_pad8(oc);
      oh  = (ih + 2*pad - ks)/st + 1;
      ow  = (iw + 2*pad - ks)/st + 1;
      dw  = (flags >> NN_F_DEPTHWISE) & 1;
      sbase = (src_abs >= int'(NN_B_OFF)) ? int'(NN_B_OFF) : int'(NN_A_OFF);
      dbase = (dst_abs >= int'(NN_B_OFF)) ? int'(NN_B_OFF) : int'(NN_A_OFF);
      srel  = src_abs - sbase;
      drel  = dst_abs - dbase;

      // 1) 权重镜像 (dense [tap][ic8][oc8] / depthwise [tap][oc8]; padding 写 0)
      if (dw) begin
        nw = ks*ks*oc8;
        for (tap = 0; tap < ks*ks; tap++)
          for (ocn = 0; ocn < oc8; ocn++)
            m1_wb[tap*oc8 + ocn] = (ocn < oc) ? m1_h8(tap*512, ocn, seed*7 + 1) : 8'd0;
      end else begin
        nw = ks*ks*ic8*oc8;
        for (tap = 0; tap < ks*ks; tap++)
          for (icn = 0; icn < ic8; icn++)
            for (ocn = 0; ocn < oc8; ocn++)
              m1_wb[(tap*ic8 + icn)*oc8 + ocn] =
                ((icn < ic) && (ocn < oc)) ? m1_h8(tap*512 + icn, ocn, seed*7 + 1) : 8'd0;
      end

      // 2) Q 参数 (padding lane 的 bias/M_pos 写 0)
      for (ocn = 0; ocn < oc8; ocn++) begin
        if (ocn < oc) begin
          m1_bias[ocn] = int'(m1_h8(ocn, 17, seed*7 + 2)) * 128 + 5;
          m1_mpos[ocn] = 64 + (int'(m1_h8(ocn, 19, seed*7 + 3)) + 128) * 128;
        end
        else begin
          m1_bias[ocn] = 0;
          m1_mpos[ocn] = 0;
        end
      end
      m1_load_q_conv(32'h2000, oc8, zp_o, zp_i, shift, (flags >> NN_F_LEAKY) & 1);

      // 3) 输入张量 (NHWC8; 未用通道填 zp_in) + dst poison (抓"该写没写"的字节)
      for (pix = 0; pix < ih*iw; pix++)
        for (c = 0; c < ic8; c++)
          m1_ab[srel + pix*ic8 + c] = (c < ic) ? m1_h8(pix, c, seed*7 + 4) : 8'(zp_i);
      for (idx = 0; idx < oh*ow*oc8; idx++) m1_db[drel + idx] = 8'hA5;

      // 4) 装载 (W: dbg 口; A/B: CPU 窗口)
      m1_load_w(nw, woff_rel);
      m1_wr_words(32'(sbase), srel, ih*iw*ic8, 0);
      m1_wr_words(32'(dbase), drel, oh*ow*oc8, 1);
      cpu_idle();
      @(negedge clk);

      // 5) 描述符 + 运行
      desc = '0;
      desc.op     = NN_OP_CONV;
      desc.flags  = flags[7:0];
      desc.ks     = 4'(ks); desc.stride = 2'(st); desc.pad = 3'(pad);
      desc.ih = 16'(ih); desc.iw = 16'(iw); desc.ic = 16'(ic); desc.oc = 16'(oc);
      desc.src = 32'(src_abs); desc.dst = 32'(dst_abs);
      desc.woff = 32'(woff_rel); desc.qoff = 32'h2000;
      run_op(cyc, ecode, ok);

      // 6) 金标 + 回读比较
      m1_golden_conv(ks, st, pad, ih, iw, ic, oc, flags, shift, zp_i, zp_o,
                     srel, drel, nrelu);
      m1_cmp_words(nm, 32'(dbase), drel, oh*ow*oc8,
                   (flags >> NN_F_RELU) & 1, zp_o, mis, nbelow);
      pass = ok && (mis == 0);
      if (((flags >> NN_F_RELU) & 1) != 0)
        pass = pass && (nbelow == 0) && (nrelu > 0);   // 下界=zp_out 且确有负 acc 被截
      m1_ncase = m1_ncase + 1;
      if (pass) m1_npass = m1_npass + 1;
      m1_nmis = m1_nmis + mis;
      $display("M1CASE %-18s flags=%02x k=%0d st=%0d pad=%0d ih=%0d iw=%0d ic=%0d oc=%0d : cyc=%0d mis=%0d below=%0d relu_hits=%0d err=%02x %s",
               nm, flags, ks, st, pad, ih, iw, ic, oc, cyc, mis, nbelow, nrelu, ecode,
               pass ? "PASS" : "FAIL");
    end
  endtask

  // ---- v0.9 [task-14 Step A] Q 块装载: conv + ADD_R 融合（tail 扩展 byte4=zp_d, byte5=KADD, byte6..7=R）
  task automatic m1_load_q_conv_fad(input int qoff_rel, input int oc8,
                                    input int zp_o, input int zp_i,
                                    input int shift, input int leaky,
                                    input int zp_d, input int R, input int KADD);
    int base, lo, hi;
    begin
      m1_load_q_conv(qoff_rel, oc8, zp_o, zp_i, shift, leaky);
      base = qoff_rel >> 3;
      lo = (zp_o & 8'hFF) | ((zp_i & 8'hFF) << 8) | ((leaky & 1) << 16) |
           ((shift & 8'hFF) << 24);
      hi = (zp_d & 8'hFF) | ((KADD & 8'hFF) << 8) | ((R & 16'hFFFF) << 16);
      dbg_wr(1'b1, 17'((base + (6*oc8)/8)*2),     32'(lo));
      dbg_wr(1'b1, 17'((base + (6*oc8)/8)*2 + 1), 32'(hi));
    end
  endtask

  // ---- 一个 ADD / ADD_R (+可选后置 ReLU) case ----
  task automatic m1_run_add(input string nm, input int ih, input int iw, input int ic,
                            input int flags, input int seed,
                            input int zp_s, input int zp_d, input int R, input int KADD,
                            input int src_abs, input int dst_abs, input int force_neg);
    int ic8, srel, drel, sbase, dbase, pix, c, idx, nbytes, mis, nbelow, cyc, nrelu;
    int add_r, relu, qs, qd;
    longint p, s;
    logic [7:0] ecode;
    logic ok, pass;
    begin
      ic8 = m1_pad8(ic);
      nbytes = ih*iw*ic8;
      sbase = (src_abs >= int'(NN_B_OFF)) ? int'(NN_B_OFF) : int'(NN_A_OFF);
      dbase = (dst_abs >= int'(NN_B_OFF)) ? int'(NN_B_OFF) : int'(NN_A_OFF);
      srel  = src_abs - sbase;
      drel  = dst_abs - dbase;
      add_r = (flags >> NN_F_ADD_R) & 1;
      relu  = (flags >> NN_F_RELU) & 1;

      // 源/目标张量 (force_neg: 全负 => RELU 后应全部等于 zp_d, 用来钉死"全负"判据)
      for (pix = 0; pix < ih*iw; pix++)
        for (c = 0; c < ic8; c++)
          if (force_neg) begin
            m1_ab[srel + pix*ic8 + c] = 8'h80 | (8'(m1_h8(pix, c, seed*7 + 5)) & 8'h7F);
            m1_db[drel + pix*ic8 + c] = 8'h80 | (8'(m1_h8(pix, c, seed*7 + 6)) & 8'h7F);
          end
          else begin
            m1_ab[srel + pix*ic8 + c] = m1_h8(pix, c, seed*7 + 5);
            m1_db[drel + pix*ic8 + c] = m1_h8(pix, c, seed*7 + 6);
          end

      if (add_r || relu)
        m1_load_q_add(32'h2000, add_r ? zp_s : 0, zp_d,
                      add_r ? R : 0, add_r ? KADD : 0);
      m1_wr_words(32'(sbase), srel, nbytes, 0);
      m1_wr_words(32'(dbase), drel, nbytes, 1);
      cpu_idle();
      @(negedge clk);

      desc = '0;
      desc.op = NN_OP_ADD;
      desc.flags = flags[7:0];
      desc.ks = 4'd1; desc.stride = 2'd1; desc.pad = 3'd0;
      desc.ih = 16'(ih); desc.iw = 16'(iw); desc.ic = 16'(ic); desc.oc = 16'(ic);
      desc.src = 32'(src_abs); desc.dst = 32'(dst_abs);
      desc.woff = 32'd0; desc.qoff = 32'h2000;
      run_op(cyc, ecode, ok);

      // 金标: plain add 的 Δ = q_s (引擎里 zp_s 不加载保持 0); ADD_R 用整数公式
      nrelu = 0;
      for (idx = 0; idx < nbytes; idx++) begin
        qs = int'($signed(m1_get8(0, srel + idx)));
        qd = int'($signed(m1_get8(1, drel + idx)));
        if (add_r) begin
          p = (longint'(qs) - longint'(zp_s)) * longint'(R);
          p = p >>> KADD;
        end
        else p = longint'(qs);
        s = longint'(qd) + p;
        if (s > 127) s = 127;
        else if (s < -128) s = -128;
        if (relu && (s < longint'(zp_d))) begin
          s = longint'(zp_d);
          nrelu = nrelu + 1;
        end
        m1_eb[drel + idx] = 8'(s);
      end
      m1_cmp_words(nm, 32'(dbase), drel, nbytes, 0, 0, mis, nbelow);
      pass = ok && (mis == 0);
      if (relu) pass = pass && (nrelu > 0);
      if (force_neg) begin
        // 全负: 全部输出必须 == zp_d (显式数一遍, 防止"金标与断言同错")
        if (nrelu != nbytes) begin
          $display("TB:   M1 FAIL %s 全负 case 只有 %0d/%0d 个输出被 RELU 截到 zp_d",
                   nm, nrelu, nbytes);
          pass = 1'b0;
        end
      end
      m1_ncase = m1_ncase + 1;
      if (pass) m1_npass = m1_npass + 1;
      m1_nmis = m1_nmis + mis;
      $display("M1CASE %-18s flags=%02x ih=%0d iw=%0d ic=%0d : cyc=%0d mis=%0d relu_hits=%0d err=%02x %s",
               nm, flags, ih, iw, ic, cyc, mis, nrelu, ecode, pass ? "PASS" : "FAIL");
    end
  endtask

  // ---- 一个 COPY case (验证 icb_n 加宽在 copy 通道循环里同样生效) ----
  // ==========================================================================
  // v0.9 [task-14 Step A] conv add-mode（残差融进 conv）自检
  //   金标 = 先算 conv 的 q_s（复用 m1_golden_conv），再按引擎同式做 ADD_R：
  //     out = clamp(q_d + ((q_s - zp_o) * R) >> KADD)，f_relu 时再夹下界 zp_d
  // ==========================================================================
  task automatic m1_run_conv_add(input string nm,
                                 input int ks, input int st, input int pad,
                                 input int ih, input int iw, input int ic, input int oc,
                                 input int flags, input int seed,
                                 input int zp_i, input int zp_o, input int shift,
                                 input int zp_d, input int R, input int KADD,
                                 input int src_abs, input int dst_abs, input int woff_rel);
    int ic8, oc8, oh, ow, dw, nw, tap, icn, ocn, pix, c, idx;
    int srel, drel, sbase, dbase, mis, nbelow, nrelu, cyc, add_r, relu;
    int qs, qd;
    longint p, s;
    logic [7:0] ecode;
    logic ok, pass;
    begin
      ic8 = m1_pad8(ic);
      oc8 = m1_pad8(oc);
      oh  = (ih + 2*pad - ks)/st + 1;
      ow  = (iw + 2*pad - ks)/st + 1;
      dw  = (flags >> NN_F_DEPTHWISE) & 1;
      add_r = (flags >> NN_F_ADD_R) & 1;
      relu  = (flags >> NN_F_RELU) & 1;
      sbase = (src_abs >= int'(NN_B_OFF)) ? int'(NN_B_OFF) : int'(NN_A_OFF);
      dbase = (dst_abs >= int'(NN_B_OFF)) ? int'(NN_B_OFF) : int'(NN_A_OFF);
      srel  = src_abs - sbase;
      drel  = dst_abs - dbase;

      // 1) 权重镜像（dense）
      nw = ks*ks*ic8*oc8;
      for (tap = 0; tap < ks*ks; tap++)
        for (icn = 0; icn < ic8; icn++)
          for (ocn = 0; ocn < oc8; ocn++)
            m1_wb[(tap*ic8 + icn)*oc8 + ocn] =
              ((icn < ic) && (ocn < oc)) ? m1_h8(tap*512 + icn, ocn, seed*7 + 1) : 8'd0;

      // 2) Q 参数（conv 常规 + 融合 tail 扩展）
      for (ocn = 0; ocn < oc8; ocn++) begin
        if (ocn < oc) begin
          m1_bias[ocn] = int'(m1_h8(ocn, 17, seed*7 + 2)) * 128 + 5;
          m1_mpos[ocn] = 64 + (int'(m1_h8(ocn, 19, seed*7 + 3)) + 128) * 128;
        end
        else begin
          m1_bias[ocn] = 0;
          m1_mpos[ocn] = 0;
        end
      end
      m1_load_q_conv_fad(32'h2000, oc8, zp_o, zp_i, shift,
                         (flags >> NN_F_LEAKY) & 1, zp_d, R, KADD);

      // 3) 源张量 + dst 残差初值
      for (pix = 0; pix < ih*iw; pix++)
        for (c = 0; c < ic8; c++)
          m1_ab[srel + pix*ic8 + c] = (c < ic) ? m1_h8(pix, c, seed*7 + 4) : 8'(zp_i);
      for (pix = 0; pix < oh*ow; pix++)
        for (c = 0; c < oc8; c++)
          m1_db[drel + pix*oc8 + c] = m1_h8(pix, c, seed*7 + 6);

      // 4) 装载
      m1_load_w(nw, woff_rel);
      m1_wr_words(32'(sbase), srel, ih*iw*ic8, 0);
      m1_wr_words(32'(dbase), drel, oh*ow*oc8, 1);
      cpu_idle();
      @(negedge clk);

      // 5) 描述符 + 运行（conv op + ADD_R(融合)）
      desc = '0;
      desc.op     = NN_OP_CONV;
      desc.flags  = flags[7:0];
      desc.ks     = 4'(ks); desc.stride = 2'(st); desc.pad = 3'(pad);
      desc.ih = 16'(ih); desc.iw = 16'(iw); desc.ic = 16'(ic); desc.oc = 16'(oc);
      desc.src = 32'(src_abs); desc.dst = 32'(dst_abs);
      desc.woff = 32'(woff_rel); desc.qoff = 32'h2000;
      run_op(cyc, ecode, ok);

      // 6) 金标: conv q_s -> ADD_R(+relu) 累加进 dst
      m1_golden_conv(ks, st, pad, ih, iw, ic, oc, flags & ~(1 << NN_F_ADD_R), shift,
                     zp_i, zp_o, srel, drel, nrelu);
      nrelu = 0;
      for (idx = 0; idx < oh*ow*oc8; idx++) begin
        qs = int'($signed(m1_eb[drel + idx]));
        qd = int'($signed(m1_db[drel + idx]));
        if (add_r) begin
          p = (longint'(qs) - longint'(zp_o)) * longint'(R);
          p = p >>> KADD;
        end
        else p = longint'(qs);
        s = longint'(qd) + p;
        if (s > 127) s = 127;
        else if (s < -128) s = -128;
        if (relu && (s < longint'(zp_d))) begin
          s = longint'(zp_d);
          nrelu = nrelu + 1;
        end
        m1_eb[drel + idx] = 8'(s);
      end
      m1_cmp_words(nm, 32'(dbase), drel, oh*ow*oc8, 0, 0, mis, nbelow);
      pass = ok && (mis == 0);
      if (relu) pass = pass && (nrelu > 0);
      sa_ncase = sa_ncase + 1;
      if (pass) sa_npass = sa_npass + 1;
      sa_nmis = sa_nmis + mis;
      $display("SACASE %-18s flags=%02x k=%0d st=%0d pad=%0d ih=%0d iw=%0d ic=%0d oc=%0d : cyc=%0d mis=%0d relu_hits=%0d err=%02x %s",
               nm, flags, ks, st, pad, ih, iw, ic, oc, cyc, mis, nrelu, ecode,
               pass ? "PASS" : "FAIL");
    end
  endtask

  task automatic m1_run_copy(input string nm, input int ih, input int iw,
                             input int ic, input int oc,
                             input int src_abs, input int dst_abs, input int seed);
    int ic8, oc8, srel, drel, sbase, dbase, pix, cb, c, idx, nb_src, nb_dst;
    int mis, nbelow, cyc;
    logic [7:0] ecode;
    logic ok, pass;
    begin
      ic8 = m1_pad8(ic);
      oc8 = m1_pad8(oc);
      sbase = (src_abs >= int'(NN_B_OFF)) ? int'(NN_B_OFF) : int'(NN_A_OFF);
      dbase = (dst_abs >= int'(NN_B_OFF)) ? int'(NN_B_OFF) : int'(NN_A_OFF);
      srel  = src_abs - sbase;
      drel  = dst_abs - dbase;
      nb_src = ih*iw*ic8;
      nb_dst = ih*iw*oc8;
      for (pix = 0; pix < ih*iw; pix++)
        for (c = 0; c < ic8; c++)
          m1_ab[srel + pix*ic8 + c] = m1_h8(pix, c, seed*7 + 7);
      for (idx = 0; idx < nb_dst; idx++) m1_db[drel + idx] = 8'h5A;
      m1_wr_words(32'(sbase), srel, nb_src, 0);
      m1_wr_words(32'(dbase), drel, nb_dst, 1);
      cpu_idle();
      @(negedge clk);

      desc = '0;
      desc.op = NN_OP_COPY;
      desc.flags = 8'd0;
      desc.ks = 4'd1; desc.stride = 2'd1; desc.pad = 3'd0;
      desc.ih = 16'(ih); desc.iw = 16'(iw); desc.ic = 16'(ic); desc.oc = 16'(oc);
      desc.src = 32'(src_abs); desc.dst = 32'(dst_abs);
      desc.woff = 32'd0; desc.qoff = 32'h2000;
      run_op(cyc, ecode, ok);

      // 金标: 每像素 ic8 字节原样拷贝到 dst 的 oc8 步长布局 (8 通道一块)
      for (pix = 0; pix < ih*iw; pix++)
        for (cb = 0; cb < ic8/8; cb++)
          for (c = 0; c < 8; c++)
            m1_eb[drel + pix*oc8 + cb*8 + c] = m1_ab[srel + pix*ic8 + cb*8 + c];
      m1_cmp_words(nm, 32'(dbase), drel, nb_dst, 0, 0, mis, nbelow);
      pass = ok && (mis == 0);
      m1_ncase = m1_ncase + 1;
      if (pass) m1_npass = m1_npass + 1;
      m1_nmis = m1_nmis + mis;
      $display("M1CASE %-18s flags=00 ih=%0d iw=%0d ic=%0d oc=%0d : cyc=%0d mis=%0d err=%02x %s",
               nm, ih, iw, ic, oc, cyc, mis, ecode, pass ? "PASS" : "FAIL");
    end
  endtask

  // ==========================================================================
  // 主流程
  // ==========================================================================
  integer fd, rc, i, opi;
  integer m_op, m_flags, m_ks, m_st, m_pad, m_ih, m_iw, m_ic, m_oc;
  integer m_src, m_dst, m_woff, m_qoff;
  string  m_name;
  logic   cpass;
  integer ccyc;

  initial begin
    dbg_we = 1'b0; dbg_space = 1'b0; dbg_addr = 17'd0; dbg_wdata = 32'd0;
    // 输出表格初始化
    for (i = 0; i < 4; i++) begin
      op_cases[i] = 0; op_fail[i] = 0; op_mis[i] = 0; op_maxcyc[i] = 0;
    end
    g_mis_a = 0; g_mis_b = 0;
    if ($test$plusargs("misall")) nmis_max = 400;

    // 向量目录: +vec=<dir> 优先; 否则按候选相对路径找 manifest.txt
    // (vsim 的 cwd 由你决定, 所以这里做几层兜底, 找不到才 FAIL)
    if (!$value$plusargs("vec=%s", vecdir)) vecdir = "";
    if (vecdir == "") begin
      fd = 0;
      for (i = 0; (i < 3) && (fd == 0); i++) begin
        case (i)
          0: vecdir = "results/ai-accel/proto/engine/vec";
          1: vecdir = "vec";
          default: vecdir = "../results/ai-accel/proto/engine/vec";
        endcase
        fd = $fopen({vecdir, "/manifest.txt"}, "r");
      end
      if (fd != 0) begin $fclose(fd); fd = 0; end
    end
    else
      fd = $fopen({vecdir, "/manifest.txt"}, "r");

    // 复位
    rst = 1'b1;
    start = 1'b0;
    desc = '0;
    cpu_we = 1'b0; cpu_re = 1'b0; cpu_addr = 32'd0;
    cpu_wdata = 32'd0; cpu_wstrb = 4'h0;
    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    $display("TB: nn_conv_engine self-check; vectors = %s", vecdir);
    if (fd == 0) fd = $fopen({vecdir, "/manifest.txt"}, "r");
    if (fd == 0) begin
      $display("ENGINE_TB: FAIL (cannot open manifest.txt; pass +vec=<dir>)");
      $finish;
    end
    rc = $fscanf(fd, "%s %d %d %d %d %d %d %d %d %d %d %d %d %d",
                 m_name, m_op, m_flags, m_ks, m_st, m_pad, m_ih, m_iw,
                 m_ic, m_oc, m_src, m_dst, m_woff, m_qoff);
    while (rc == 14) begin
      run_case(m_name, m_op, m_flags, m_ks, m_st, m_pad, m_ih, m_iw, m_ic, m_oc,
               m_src, m_dst, m_woff, m_qoff, cpass, ccyc);
      ncase = ncase + 1;
      if (cpass) npass = npass + 1;
      rc = $fscanf(fd, "%s %d %d %d %d %d %d %d %d %d %d %d %d %d",
                   m_name, m_op, m_flags, m_ks, m_st, m_pad, m_ih, m_iw,
                   m_ic, m_oc, m_src, m_dst, m_woff, m_qoff);
    end
    $fclose(fd);

    // ---- 非法描述符: 必须报 err 且不写内存 ----
    begin : err_case
      logic [7:0] ecode;
      logic       ok;
      integer     cyc2;
      desc = '0;
      desc.op = NN_OP_CONV; desc.flags = 5'd0; desc.ks = 4'd2;
      desc.stride = 2'd1; desc.pad = 2'd0;
      desc.ih = 16'd8; desc.iw = 16'd8; desc.ic = 16'd8; desc.oc = 16'd8;
      desc.src = NN_A_OFF; desc.dst = NN_B_OFF;
      desc.woff = 32'd0; desc.qoff = NN_Q_OFF;
      run_op(cyc2, ecode, ok);
      if ((ecode != 8'h00) && (ok == 1'b0) && (cyc2 > 0))
        $display("ERRCASE invalid-desc : PASS (err=%02x, cyc=%0d)", ecode, cyc2);
      else begin
        $display("ERRCASE invalid-desc : FAIL (err=%02x)", ecode);
        errcases_fail = 1;
      end
    end

    // ======================================================================
    // v0.8 / M1 新增能力 case (旧 47 个 manifest case 已在前; 两段互不依赖)
    // ======================================================================
    // (a) ReLU conv: 3x3/s1/p1, 输入含负值; 判据 = 整数金标 + 全部输出 >= zp_out
    m1_run_conv("m1_relu_conv", 3, 1, 1, 9, 10, 8, 8,
                (1 << NN_F_RELU), 601, -13, 7, 24,
                int'(NN_A_OFF), int'(NN_B_OFF), 0);
    // (a2) RELU 与 LEAKY 同时置位 => RELU 优先 (M_neg=0); 1x1 小 case
    m1_run_conv("m1_relu_prio", 1, 1, 0, 5, 5, 8, 8,
                (1 << NN_F_RELU) | (1 << NN_F_LEAKY), 602, -13, 7, 24,
                int'(NN_A_OFF), int'(NN_B_OFF), 0);
    // (c1) 大通道 dense: IC=864 / OC=144 1x1 (原 icb_n 只有 6 bit, 该 shape 必错)
    m1_run_conv("m1_ic864_conv1x1", 1, 1, 0, 8, 8, 864, 144,
                0, 603, -13, 7, 26,
                int'(NN_A_OFF), int'(NN_B_OFF), 0);
    // (c2) 大通道 depthwise: IC=OC=864 3x3 (icb_n = 108 > 63)
    m1_run_conv("m1_ic864_dw3x3", 3, 1, 1, 6, 6, 864, 864,
                (1 << NN_F_DEPTHWISE), 604, -13, 7, 24,
                int'(NN_A_OFF), int'(NN_A_OFF) + 32'h8000, 0);
    // (b) ADD + 后置 ReLU (mixed: 部分和被截到 zp_d)
    m1_run_add("m1_add_relu_mix", 6, 7, 8, (1 << NN_F_RELU), 605, 0, 7, 0, 0,
               int'(NN_A_OFF), int'(NN_A_OFF) + 32'h2000, 0);
    // (b2) ADD + 后置 ReLU 全负输入: 判据 = 100% 输出 == zp_d
    m1_run_add("m1_add_relu_allneg", 4, 4, 8, (1 << NN_F_RELU), 606, 0, 7, 0, 0,
               int'(NN_A_OFF), int'(NN_A_OFF) + 32'h2000, 1);
    // (b3) ADD_R + 后置 ReLU (残差块实际形态: out = relu(x + conv2); R/KADD 生效)
    m1_run_add("m1_addr_relu", 6, 6, 8, (1 << NN_F_ADD_R) | (1 << NN_F_RELU), 607,
               -10, 5, 32768, 15,
               int'(NN_A_OFF), int'(NN_A_OFF) + 32'h2000, 0);
    // (c3) 大通道 ADD: IC=864 (icb_n 加宽同时覆盖 add 的通道循环)
    m1_run_add("m1_add_ic864", 2, 2, 864, 0, 608, 0, 0, 0, 0,
               int'(NN_A_OFF), int'(NN_A_OFF) + 32'h2000, 0);
    // (c4) 大通道 COPY: IC=864 (icb_n 加宽同时覆盖 copy 的通道循环)
    m1_run_copy("m1_copy_ic864", 1, 1, 864, 864,
                int'(NN_A_OFF), int'(NN_B_OFF), 609);

    // ---- v0.9 [task-14 Step A] conv add-mode（残差融进 conv）2 个 case ----
    // (sa1) 1x1 conv + ADD_R（无 ReLU）：4x4x8 -> 4x4x16，dst 残差参与累加
    m1_run_conv_add("sa_cvadd_nr", 1, 1, 0, 4, 4, 8, 16,
                    (1 << NN_F_ADD_R), 801,
                    2, -5, 10, 7, 20000, 14,
                    int'(NN_A_OFF), int'(NN_A_OFF) + 32'h2000, 0);
    // (sa2) 3x3 conv + ADD_R + 后置 ReLU：4x4x8 -> 4x4x16，含负输出被夹到 zp_d
    m1_run_conv_add("sa_cvadd_rl", 3, 1, 1, 4, 4, 8, 16,
                    (1 << NN_F_ADD_R) | (1 << NN_F_RELU), 802,
                    0, -10, 12, -3, 30000, 15,
                    int'(NN_A_OFF), int'(NN_A_OFF) + 32'h3000, 0);

    // ---- 汇总 ----
    // ==========================================================================
    // task-20: op3 ISO 仲裁实验（默认不跑；+op3iso +op3dir=<dir> 才跑）
    //   动机: stock nn_mem 的 A 窗口以 B_OFF(0x78000) 为硬边界 => A 容量固定 96KB
    //   （nn_mem.sv:508），op3 的 A=802,816 B 装不下；因此默认用 **13 行 band** 验证
    //   引擎 dense 路径本身（ic=64 多 ic-block / k=1 / pad=0）：
    //     A band = 13*112*64 = 93,184 B <= 96KB; 输出 band = 13*112*16 = 23,296 B <= 32KB
    //   输入用复现包的 op3_A.hex 前 13 行，期望用 op3_golden.hex 前 13 行。
    //   [rtl-mem 2026-11-04] 全张量模式 (112 行, A=802,816 B) 需要放大 nn_mem 的 A/B:
    //     vsim -gA_BYTES=802816 -gB_BYTES=262144 work.tb_nn_engine \
    //          +op3iso +op3rows=112 +op3dir=results/bottlecap/proto/m6b_data/op3_iso ...
    //   B 侧基址用本 TB 的 AB_BOFF (= NN_A_OFF+A_BYTES; 默认 0x78000 == NN_B_OFF)，
    //   保证放大 A 后 nn_mem 的 b_in_b 解码与引擎的 b_sel 阈值同时成立。
    // ==========================================================================
    if ($test$plusargs("op3iso")) begin : op3_iso_blk
      string       odir;
      integer      fh, fh2, rc, i, mis, ncyc, dummy;
      integer      ROWS, AW, GW;
      // [rtl-mem 2026-11-04] 给默认值再读 plusarg: 原写法在"不传 +op3rows/+op3src"时
      // 4 态变量保持 X (X<=0 为假、X==0 为假), 会导致 AW/GW/src=X 的假失败。
      logic [31:0] srch = 32'h0006_0000;
      logic [31:0] v, gv;
      logic [7:0]  ecode;
      logic        ok, pass;
      ROWS = 13;
      dummy = $value$plusargs("op3rows=%d", ROWS);
      if (ROWS <= 0) ROWS = 13;
      dummy = $value$plusargs("op3src=%h", srch);
      if (srch == 0) srch = 32'h0006_0000;
      AW   = ROWS*112*64/4;
      GW   = ROWS*112*16/4;
      dummy = $value$plusargs("op3dir=%s", odir);
      $display("OP3ISO: start dir=%s rows=%0d src=%08x AW=%0d GW=%0d", odir, ROWS, srch, AW, GW);

      // 1) W: 1024 B = 256 x u32 -> dbg space 0
      fh = $fopen({odir, "/op3_W.hex"}, "r");
      if (fh == 0) begin $display("OP3ISO: FAIL cannot open op3_W.hex"); end
      else begin
        for (i = 0; i < 256; i++) begin
          rc = $fscanf(fh, "%h", v);
          dbg_wr(1'b0, 17'(i), v);
        end
        $fclose(fh);
      end
      // 2) Q: 112 B = 28 x u32 -> dbg space 1
      fh = $fopen({odir, "/op3_Q.hex"}, "r");
      if (fh == 0) begin $display("OP3ISO: FAIL cannot open op3_Q.hex"); end
      else begin
        for (i = 0; i < 28; i++) begin
          rc = $fscanf(fh, "%h", v);
          dbg_wr(1'b1, 17'(i), v);
        end
        $fclose(fh);
      end
      // 3) A band: 前 13 行 (23,296 u32) -> CPU 窗口 NN_A_OFF
      fh = $fopen({odir, "/op3_A.hex"}, "r");
      if (fh == 0) begin $display("OP3ISO: FAIL cannot open op3_A.hex"); end
      else begin
        for (i = 0; i < AW; i++) begin
          rc = $fscanf(fh, "%h", v);
          cpu_wr32(srch + 32'(4*i), v);
        end
        $fclose(fh);
      end
      cpu_idle();
      @(negedge clk);

      // 4) 描述符: conv 1x1 s1 p0, 13x112, ic=64 oc=16, WQ 偏移 0
      desc = '0;
      desc.op     = 2'd0;
      desc.flags  = 8'h00;
      desc.ks     = 4'd1;
      desc.stride = 2'd1;
      desc.pad    = 3'd0;
      desc.ih     = 16'(ROWS);   // [rtl-mem] band 行数 (默认 13, 全张量用 +op3rows=112)
      desc.iw     = 16'd112;
      desc.ic     = 16'd64;
      desc.oc     = 16'd16;
      desc.src    = srch;
      desc.dst    = AB_BOFF;    // [rtl-mem] 放大 A 时随 B 窗口起点移动; 默认 == NN_B_OFF
      desc.woff   = 32'd0;
      desc.qoff   = 32'd0;
      if ($test$plusargs("op3trace")) begin : op3_tr
        integer trc;
        logic tr_on;
        tr_on = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        trc = 0;
        while ((done !== 1'b1) && (trc < 1000000)) begin
          if (tr_on) begin
            $display("TRC %0d a_re=%b a_sel=%b a_addr=%06x a_rdata=%032x w_re=%b w_addr=%06x w_rdata=%032x q_re=%b q_addr=%05x q_rdata=%016x b_we=%b b_addr=%06x b_wdata=%032x b_wstrb=%04x",
                     trc, a_re, a_sel, a_addr, a_rdata, w_re, w_addr, w_rdata,
                     q_re, q_addr, q_rdata, b_we, b_addr, b_wdata, b_wstrb);
            if (trc >= 140) tr_on = 1'b0;
          end
          @(negedge clk);
          trc = trc + 1;
        end
        ncyc  = int'(cycles);
        ecode = err_code;
        ok    = (done === 1'b1) && (trc < 1000000) && (ecode == 8'h00);
        @(negedge clk);
      end else begin
        run_op(ncyc, ecode, ok);
      end

      // 5) 读回 B 窗口前 GW 个 u32 与 golden 比
      mis = 0;
      fh2 = $fopen({odir, "/op3_golden.hex"}, "r");
      if (fh2 == 0) begin
        $display("OP3ISO: FAIL cannot open op3_golden.hex");
        mis = 999999;
      end else begin
        for (i = 0; i < GW; i++) begin
          rc = $fscanf(fh2, "%h", gv);
          cpu_rd32(AB_BOFF + 32'(4*i), v);
          if (v !== gv) begin
            if (mis < 6)
              $display("OP3ISO:   MISMATCH word@%0d got=%08x exp=%08x", i, v, gv);
            mis = mis + 1;
          end
        end
        $fclose(fh2);
      end
      pass = ok && (mis == 0);
      if (pass) $display("OP3ISO: PASS rows=%0d src=%08x cyc=%0d err=%02x mis=0", ROWS, srch, ncyc, ecode);
      else      $display("OP3ISO: FAIL rows=%0d src=%08x cyc=%0d err=%02x mis=%0d ok=%0d",
                         ROWS, srch, ncyc, ecode, mis, ok);
    end

    $display("SUMMARY cases=%0d pass=%0d fail=%0d total_mismatch=%0d",
             ncase, npass, ncase - npass, g_mis_a + g_mis_b);
    for (opi = 0; opi < 4; opi++) begin
      if (op_cases[opi] != 0)
        $display("  op=%0d (%s) cases=%0d fail=%0d mismatch=%0d max_cycles=%0d",
                 opi, (opi == 0) ? "conv/dw" : (opi == 1) ? "pool" : (opi == 2) ? "copy/ups" : "add",
                 op_cases[opi], op_fail[opi], op_mis[opi], op_maxcyc[opi]);
    end
    $display("M1SUMMARY cases=%0d pass=%0d fail=%0d mismatch=%0d",
             m1_ncase, m1_npass, m1_ncase - m1_npass, m1_nmis);
    $display("SASUMMARY cases=%0d pass=%0d fail=%0d mismatch=%0d",
             sa_ncase, sa_npass, sa_ncase - sa_npass, sa_nmis);
    if ((ncase > 0) && (npass == ncase) && (errcases_fail == 0) &&
        (m1_ncase > 0) && (m1_npass == m1_ncase) &&
        (sa_ncase > 0) && (sa_npass == sa_ncase))
      $display("ENGINE_TB: PASS (%0d cases, mismatch=0)", ncase + m1_ncase + sa_ncase);
    else
      $display("ENGINE_TB: FAIL (%0d/%0d manifest, %0d/%0d M1, %0d/%0d SA, errcases_fail=%0d)",
               npass, ncase, m1_npass, m1_ncase, sa_npass, sa_ncase, errcases_fail);
    $finish;
  end

  // 看门狗
  initial begin
    #200000000;   // 200 ms 仿真时间
    $display("ENGINE_TB: FAIL (watchdog timeout)");
    $finish;
  end

endmodule
