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
// ============================================================================

module tb_nn_engine;
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
  logic [63:0] w_rdata;
  logic [1:0]  a_sel;
  logic        a_re;
  logic [23:0] a_addr;
  logic [127:0] a_rdata;
  logic [1:0]  b_sel;
  logic        b_we;
  logic [23:0] b_addr;
  logic [63:0] b_wdata;

  nn_mem u_mem (
    .clk(clk), .rst(rst),
    .cpu_re(cpu_re), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_rdata(cpu_rdata),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata)
  );

  nn_conv_engine u_eng (
    .clk(clk), .rst(rst), .desc(desc), .start(start),
    .busy(busy), .done(done), .cycles(cycles), .err_code(err_code),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata)
  );

  string vecdir;

  // ---- 统计 ----
  integer ncase = 0;
  integer npass = 0;
  integer op_cases [0:3];
  integer op_fail  [0:3];
  integer op_mis   [0:3];
  integer op_maxcyc[0:3];
  integer g_mis_a, g_mis_b;
  integer errcases_fail = 0;

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
        cpu_wr32(off, wd);
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
          if (nmis < 6)
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
      desc.flags  = flags[4:0];
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
      desc.qoff   = qoff[31:0];
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
  // 主流程
  // ==========================================================================
  integer fd, rc, i, opi;
  integer m_op, m_flags, m_ks, m_st, m_pad, m_ih, m_iw, m_ic, m_oc;
  integer m_src, m_dst, m_woff, m_qoff;
  string  m_name;
  logic   cpass;
  integer ccyc;

  initial begin
    // 输出表格初始化
    for (i = 0; i < 4; i++) begin
      op_cases[i] = 0; op_fail[i] = 0; op_mis[i] = 0; op_maxcyc[i] = 0;
    end
    g_mis_a = 0; g_mis_b = 0;

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

    // ---- 汇总 ----
    $display("SUMMARY cases=%0d pass=%0d fail=%0d total_mismatch=%0d",
             ncase, npass, ncase - npass, g_mis_a + g_mis_b);
    for (opi = 0; opi < 4; opi++) begin
      if (op_cases[opi] != 0)
        $display("  op=%0d (%s) cases=%0d fail=%0d mismatch=%0d max_cycles=%0d",
                 opi, (opi == 0) ? "conv/dw" : (opi == 1) ? "pool" : (opi == 2) ? "copy/ups" : "add",
                 op_cases[opi], op_fail[opi], op_mis[opi], op_maxcyc[opi]);
    end
    if ((ncase > 0) && (npass == ncase) && (errcases_fail == 0))
      $display("ENGINE_TB: PASS (%0d cases, mismatch=0)", ncase);
    else
      $display("ENGINE_TB: FAIL (%0d/%0d cases, errcases_fail=%0d)",
               npass, ncase, errcases_fail);
    $finish;
  end

  // 看门狗
  initial begin
    #200000000;   // 200 ms 仿真时间
    $display("ENGINE_TB: FAIL (watchdog timeout)");
    $finish;
  end

endmodule
