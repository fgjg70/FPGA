`timescale 1ns/1ps
// Temporary debug TB (not a deliverable). ASCII only.
// Usage: vsim ... work.debug_tb +case=<name>
module debug_tb;
  import nn_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic cpu_re, cpu_we;
  logic [31:0] cpu_addr, cpu_wdata;
  logic [3:0] cpu_wstrb;
  logic [31:0] cpu_rdata;
  nn_desc_t desc;
  logic start, busy, done;
  logic [31:0] cycles;
  logic [7:0] err_code;
  logic w_re; logic [23:0] w_addr; logic [63:0] w_rdata;
  logic [1:0] a_sel; logic a_re; logic [23:0] a_addr; logic [127:0] a_rdata;
  logic [1:0] b_sel; logic b_we; logic [23:0] b_addr; logic [63:0] b_wdata;

  nn_mem u_mem (.clk(clk), .rst(rst), .cpu_re(cpu_re), .cpu_we(cpu_we),
    .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb),
    .cpu_rdata(cpu_rdata), .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata));
  nn_conv_engine u_eng (.clk(clk), .rst(rst), .desc(desc), .start(start),
    .busy(busy), .done(done), .cycles(cycles), .err_code(err_code),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata));

  string vecdir = "D:/USER/Desktop/FPGA/FPGA/results/ai-accel/proto/engine/vec";
  string cname;
  integer fd, rc, i, nw;
  logic [31:0] off, wd, idx, hi, lo;
  integer m_op, m_flags, m_ks, m_st, m_pad, m_ih, m_iw, m_ic, m_oc;
  integer m_src, m_dst, m_woff, m_qoff;
  string m_name;

  task automatic cw(input logic [31:0] a, input logic [31:0] d);
    begin
      @(negedge clk); cpu_we = 1; cpu_re = 0; cpu_addr = a; cpu_wdata = d; cpu_wstrb = 4'hF;
    end
  endtask
  task automatic cr(input logic [31:0] a, output logic [31:0] d);
    begin
      @(negedge clk); cpu_we = 0; cpu_re = 1; cpu_addr = a;
      @(negedge clk); d = cpu_rdata;
    end
  endtask

  always @(negedge clk) begin
    if (u_eng.state == u_eng.S_LD)
      $display("DBG LD t=%0t c_ld=%0d y=%0d x=%0d inb=%b a_addr=%h a_rdata=%h retv=%b fill=%b",
        $time, u_eng.c_ld, u_eng.ld_y, u_eng.ld_x, u_eng.ld_inb, a_addr, a_rdata,
        u_eng.ld_ret_v, u_eng.ld_fill_d);
    if (u_eng.state == u_eng.S_LDCAP)
      $display("DBG LDCAP t=%0t abuf0=%h abuf1=%h abuf2=%h abuf3=%h", $time,
        u_eng.abuf[0], u_eng.abuf[1], u_eng.abuf[2], u_eng.abuf[3]);
    if (u_eng.state == u_eng.S_PMAX)
      $display("DBG PMAX t=%0t c_m=%0d win0=%h mx0=%h mx1=%h win_adv=%b", $time,
        u_eng.c_m, u_eng.win_sel[0], u_eng.mx[0][0], u_eng.mx[0][1], u_eng.win_adv);
    if (u_eng.state == u_eng.S_PPACK)
      $display("DBG PPACK t=%0t c_p=%0d b_we=%b b_addr=%h b_wdata=%h mxrow0=%h mxrow1=%h", $time,
        u_eng.c_p, b_we, b_addr, b_wdata, u_eng.mx[0][0], u_eng.mx[1][0]);
    if (u_eng.state == u_eng.S_CP_RD)
      $display("DBG CPRD t=%0t iy=%0d ix=%0d cb=%0d a_addr=%h", $time,
        u_eng.c_iy, u_eng.c_ix, u_eng.c_cb, a_addr);
    if (u_eng.state == u_eng.S_CP_WR)
      $display("DBG CPWR t=%0t iy=%0d ix=%0d cb=%0d c_wr=%0d b_we=%b b_addr=%h b_wdata=%h half=%b", $time,
        u_eng.c_iy, u_eng.c_ix, u_eng.c_cb, u_eng.c_wr, b_we, b_addr, b_wdata, u_eng.rd_half_s);
  end

  logic [31:0] rdv;
  initial begin
    rst = 1; start = 0; desc = '0; cpu_we = 0; cpu_re = 0; cpu_addr = 0; cpu_wdata = 0; cpu_wstrb = 0;
    if (!$value$plusargs("case=%s", cname)) cname = "pool3_s1p1";
    repeat (4) @(negedge clk);
    rst = 0;
    // find case in manifest
    fd = $fopen({vecdir, "/manifest.txt"}, "r");
    rc = $fscanf(fd, "%s %d %d %d %d %d %d %d %d %d %d %d %d %d",
                 m_name, m_op, m_flags, m_ks, m_st, m_pad, m_ih, m_iw,
                 m_ic, m_oc, m_src, m_dst, m_woff, m_qoff);
    while (rc == 14) begin
      if (m_name == cname) rc = -2;
      else rc = $fscanf(fd, "%s %d %d %d %d %d %d %d %d %d %d %d %d %d",
                 m_name, m_op, m_flags, m_ks, m_st, m_pad, m_ih, m_iw,
                 m_ic, m_oc, m_src, m_dst, m_woff, m_qoff);
    end
    $fclose(fd);
    $display("DBG case=%s op=%0d flags=%0d ks=%0d st=%0d pad=%0d ih=%0d iw=%0d ic=%0d oc=%0d src=%h dst=%h woff=%h qoff=%h",
             cname, m_op, m_flags, m_ks, m_st, m_pad, m_ih, m_iw, m_ic, m_oc,
             m_src, m_dst, m_woff, m_qoff);
    // load wq
    fd = $fopen({vecdir, "/", cname, ".wq.wr"}, "r");
    rc = $fscanf(fd, "%h %h", off, wd);
    while (rc == 2) begin
      cw(off, wd);
      rc = $fscanf(fd, "%h %h", off, wd);
    end
    $fclose(fd);
    // load A and B init images
    fd = $fopen({vecdir, "/", cname, ".a.wr"}, "r");
    rc = $fscanf(fd, "%h %h %h", idx, hi, lo);
    while (rc == 3) begin
      cw(NN_A_OFF + (idx<<3), lo);
      cw(NN_A_OFF + (idx<<3) + 32'd4, hi);
      rc = $fscanf(fd, "%h %h %h", idx, hi, lo);
    end
    $fclose(fd);
    fd = $fopen({vecdir, "/", cname, ".b.wr"}, "r");
    rc = $fscanf(fd, "%h %h %h", idx, hi, lo);
    while (rc == 3) begin
      cw(NN_B_OFF + (idx<<3), lo);
      cw(NN_B_OFF + (idx<<3) + 32'd4, hi);
      rc = $fscanf(fd, "%h %h %h", idx, hi, lo);
    end
    $fclose(fd);
    @(negedge clk); cpu_we = 0; cpu_re = 0; cpu_wstrb = 0;
    @(negedge clk);
    desc = '0;
    desc.op = m_op[1:0]; desc.flags = m_flags[4:0]; desc.ks = m_ks[3:0];
    desc.stride = m_st[1:0]; desc.pad = m_pad[1:0];
    desc.ih = m_ih[15:0]; desc.iw = m_iw[15:0]; desc.ic = m_ic[15:0]; desc.oc = m_oc[15:0];
    desc.src = m_src[31:0]; desc.dst = m_dst[31:0];
    desc.woff = m_woff[31:0]; desc.qoff = m_qoff[31:0];
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    wait (done === 1'b1);
    $display("DBG: done cyc=%0d err=%02x", cycles, err_code);
    // dump first 8 words of dst region (64-bit each, high then low reads)
    for (i = 0; i < 8; i++) begin
      cr(m_dst + i*8, rdv); lo = rdv;
      cr(m_dst + i*8 + 4, rdv); hi = rdv;
      $display("DBG DST[%0d] = %08x_%08x", i, hi, lo);
    end
    $finish;
  end
endmodule
