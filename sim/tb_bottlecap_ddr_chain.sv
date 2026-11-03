`timescale 1ns/1ps

// ============================================================================
// tb_bottlecap_ddr_chain.sv -- M6b: bottlecap DDR3 full chain integration
// ----------------------------------------------------------------------------
// Owner: rtl-stream (task-15 / M6b).  Pass marker: "BOTTLECAP_DDR_CHAIN_TB: PASS".
//
// Chain under test (all real modules, no fakes):
//   beh_ddr3 (weight/Q stream image + activation arena)
//     -> nn_wload (whole-layer W/Q prefetch into nn_mem W/Q banks)
//     -> nn_tilecache (activation band fill -> IBUF, band flush -> DDR3)
//     -> nn_conv_engine (real engine, W/Q from nn_mem, activations from tilecache)
//
// M6b v1 configuration: "loose buffers" (IBUF/OBUF 2 MiB per bank), so one band
// = one whole activation tensor: fill the op's input tensor, run the real
// engine with the plan descriptor (src=dst=0, woff=qoff=0 -> tile-relative),
// flush the output tensor.  This validates the DDR3 data path end to end and
// the real-engine numerics per op against converter golden.
//
// Per-op judging (both criteria):
//   1. FNV-1a 32 over real channels in NHWC (y,x,c) order == plan.json op csum
//      (same convention as checksums.txt and converter opvec)
//   2. if a tensor golden exists (results/bottlecap/proto/m6b_data/golden_opNNN.hex,
//      exported by converter from opvec), the full arena-layout byte block
//      (including channel pad bytes = zp_out) must match word for word.
//
// Plusargs
//   +ops=<ops.txt>       m6b_data/ops.txt
//   +whex=<w stream>     results/bottlecap/stream/bottlecap/bottlecap_ddr_stream_w.hex
//   +qhex=<q stream>     results/bottlecap/stream/bottlecap/bottlecap_ddr_stream_q.hex
//   +inhex=<input hex>   m6b_data/arena_input.hex (op0 input, PACKED3 arena layout)
//   +golden_dir=<dir>    directory with golden_opNNN.hex (optional)
//   +nops=<n>            number of leading ops to run (default 8)
// ============================================================================

module tb_bottlecap_ddr_chain;

  localparam logic [31:0] W_BASE     = 32'h0000_0000;   // stream W image (2,020,960 B)
  localparam logic [31:0] Q_BASE     = 32'h0020_0000;   // stream Q image (90,368 B)
  localparam logic [31:0] ARENA_BASE = 32'h0040_0000;   // activation arena window
  localparam logic [31:0] GOLD_BASE  = 32'h0070_0000;   // golden tensor scratch
  localparam logic [23:0] ENG_SRC_BASE = 24'h06_0000;  // < NN_B_OFF -> a_sel=0
  localparam logic [23:0] ENG_DST_BASE = 24'h07_8000;  // >= NN_B_OFF -> a_sel=1
  localparam int MAX_OPS = 128;
  localparam int WD = 40_000_000;                       // watchdog cycles

  logic clk;
  logic rst;

  initial begin : clkgen
    clk = 1'b0;
    forever #5 clk = ~clk;                              // 100 MHz
  end

  initial begin : rstgen
    rst = 1'b1;
    repeat (32) @(posedge clk);
    rst = 1'b0;
    $display("[CHAIN] reset released @%0t", $time);
  end

  // ==========================================================================
  // DUT wrapper
  // ==========================================================================
  logic         pre_start;
  logic [31:0]  pre_src_addr;
  logic [17:0]  pre_wlen;
  logic [31:0]  pre_qsrc_addr;
  logic [12:0]  pre_qlen;
  logic         pre_bank;
  logic         pre_busy, pre_done, pre_err;
  logic         w_bank_sel, q_bank_sel;

  logic [31:0]  d_in_base;
  logic [15:0]  d_in_rows, d_in_row_bytes, d_in_stride, d_in_pad_top, d_in_rd_rows;
  logic [7:0]   d_zp_in;
  logic         d_add_mode;
  logic [31:0]  d_aux_base;
  logic [15:0]  d_aux_stride, d_aux_pad_top, d_aux_rd_rows;
  logic [31:0]  d_out_base;
  logic [15:0]  d_out_rows, d_out_row_bytes, d_out_stride;
  logic [23:0]  d_a_src_base, d_a_aux_base, d_b_base;
  logic [16:0]  d_in_word_off, d_out_word_off;
  int           stock_addr;
  logic         band_start, band_ready, band_done, tc_busy;
  logic [7:0]   tc_err;
  logic [31:0]  tc_fill_beats, tc_flush_beats;

  nn_pkg::nn_desc_t eng_desc;
  logic         eng_start, eng_busy, eng_done;
  logic [31:0]  eng_cycles;
  logic [7:0]   eng_err;
  logic         ddr_rd_owner;
  string        vcd_path;
  logic         vcd_on;
  logic         vcd_dumped;
  logic         w_mode_sel;
  logic         dbg_we, dbg_space;
  logic [16:0]  dbg_addr;
  logic [31:0]  dbg_wdata;
  int           rom_mode;      // +rom_mode: run the op through nn_mem ROM path

  nn_ddr_chain #(
    .MEM_BYTES (8*1024*1024),
    .READ_LAT  (40),
    .BEAT_GAP  (4),
    .IB_BYTES  (2*1024*1024),
    .OB_BYTES  (2*1024*1024)
  ) dut (
    .clk             (clk),
    .rst             (rst),
    .pre_start       (pre_start),
    .pre_src_addr    (pre_src_addr),
    .pre_wlen        (pre_wlen),
    .pre_qsrc_addr   (pre_qsrc_addr),
    .pre_qlen        (pre_qlen),
    .pre_bank        (pre_bank),
    .pre_busy        (pre_busy),
    .pre_done        (pre_done),
    .pre_err         (pre_err),
    .w_bank_sel      (w_bank_sel),
    .q_bank_sel      (q_bank_sel),
    .d_in_base       (d_in_base),
    .d_in_rows       (d_in_rows),
    .d_in_row_bytes  (d_in_row_bytes),
    .d_in_stride     (d_in_stride),
    .d_in_pad_top    (d_in_pad_top),
    .d_in_rd_rows    (d_in_rd_rows),
    .d_zp_in         (d_zp_in),
    .d_add_mode      (d_add_mode),
    .d_aux_base      (d_aux_base),
    .d_aux_stride    (d_aux_stride),
    .d_aux_pad_top   (d_aux_pad_top),
    .d_aux_rd_rows   (d_aux_rd_rows),
    .d_out_base      (d_out_base),
    .d_out_rows      (d_out_rows),
    .d_out_row_bytes (d_out_row_bytes),
    .d_out_stride    (d_out_stride),
    .d_a_src_base    (d_a_src_base),
    .d_a_aux_base    (d_a_aux_base),
    .d_b_base        (d_b_base),
    .d_in_word_off   (d_in_word_off),
    .d_out_word_off  (d_out_word_off),
    .band_start      (band_start),
    .band_ready      (band_ready),
    .band_done       (band_done),
    .tc_busy         (tc_busy),
    .tc_err          (tc_err),
    .tc_fill_beats   (tc_fill_beats),
    .tc_flush_beats  (tc_flush_beats),
    .eng_desc        (eng_desc),
    .eng_start       (eng_start),
    .eng_busy        (eng_busy),
    .eng_done        (eng_done),
    .eng_cycles      (eng_cycles),
    .eng_err         (eng_err),
    .ddr_rd_owner    (ddr_rd_owner),
    .w_mode_sel      (w_mode_sel),
    .dbg_we          (dbg_we),
    .dbg_space       (dbg_space),
    .dbg_addr        (dbg_addr),
    .dbg_wdata       (dbg_wdata)
  );

  // ==========================================================================
  // op table (ops.txt)
  // ==========================================================================
  int op_id   [0:MAX_OPS-1];
  int op_kind [0:MAX_OPS-1];
  int op_k    [0:MAX_OPS-1];
  int op_st   [0:MAX_OPS-1];
  int op_pad  [0:MAX_OPS-1];
  int op_ih   [0:MAX_OPS-1];
  int op_iw   [0:MAX_OPS-1];
  int op_ic   [0:MAX_OPS-1];
  int op_oc   [0:MAX_OPS-1];
  int op_icp  [0:MAX_OPS-1];
  int op_ocp  [0:MAX_OPS-1];
  int op_oh   [0:MAX_OPS-1];
  int op_ow   [0:MAX_OPS-1];
  int op_src  [0:MAX_OPS-1];
  int op_dst  [0:MAX_OPS-1];
  int op_woff [0:MAX_OPS-1];
  int op_wlen [0:MAX_OPS-1];
  int op_qoff [0:MAX_OPS-1];
  int op_qlen [0:MAX_OPS-1];
  int op_nnop [0:MAX_OPS-1];
  int op_nnfl [0:MAX_OPS-1];
  int op_csum [0:MAX_OPS-1];
  int op_expc [0:MAX_OPS-1];
  int n_ops;

  // ---- debug (plusarg +dbg): engine b-write stream + OBUF coverage bitmap ----
  logic         dbg_en;
  logic [63:0]  wimg [0:262143];   // W stream image (252,620 x64b words)
  logic [63:0]  qimg [0:16383];    // Q stream image (11,296 x64b words)
  logic [63:0]  iimg [0:32767];    // arena input tensor, 64b words (op0 = 18,816)
  logic [23:0]  cur_b_base;      // OBUF base subtracted by the tilecache
  logic [31:0]  cur_in_base;     // DDR byte addr of the op input tensor (a-debug)
  int           b_beats;
  int           b_lin;           // expected linear OBUF offset for next beat
  int           b_ooo;           // out-of-order b writes (OC-plane-major check)
  int           cur_op;          // op index being executed (debug)
  int           b_print_n;       // per-op b-write print budget
  logic [131071:0] b_written;    // 1 = OBUF 128b word written by the engine
  // a-side check: engine a_addr -> tilecache a_rdata valid 1 cycle later.
  // Every read is compared against the op input tensor in the DDR arena.
  int          a_cap_n;    // total a reads
  int          a_bad_n;    // mismatching a reads
  always @(posedge clk) begin
    if (dbg_en && !rst && dut.u_tilecache.a_re_q) begin
      int unsigned loc;
      logic [127:0] gd, ed;
      a_cap_n = a_cap_n + 1;
      loc = 32'(dut.u_tilecache.a_local_q);
      gd  = dut.tc_a_rdata;
      ed  = {get_word(((cur_in_base + loc) >> 3) + 1),
             get_word((cur_in_base + loc) >> 3)};
      if (gd !== ed) begin
        a_bad_n = a_bad_n + 1;
        if (a_bad_n <= 8)
          $display("[ADBG] bad a-read #%0d sel=%0d loc=%06x tile=%032x exp=%032x",
                   a_cap_n, dut.u_tilecache.a_sel_q, loc, gd, ed);
      end
    end
  end

  initial a_cap_n = 0;

  // ---- engine load-coordinate capture (only op1, first 20 loads) ----------
  int la_cap_n;
  // ---- w-read capture (engine emits w_addr, nn_mem returns after W_RD_LAT) --
  logic        w_re_d1, w_re_d2;
  logic [23:0] w_addr_d1, w_addr_d2;
  int          w_cap_n;
  always @(posedge clk) begin
    w_re_d1   <= dut.u_engine.w_re;
    w_addr_d1 <= dut.u_engine.w_addr;
    w_re_d2   <= w_re_d1;
    w_addr_d2 <= w_addr_d1;
    if (dbg_en && !rst && (cur_op == 1) && w_re_d2 && (w_cap_n < 24)) begin
      logic [127:0] wexp;
      w_cap_n = w_cap_n + 1;
      // expected 16B at byte offset w_addr_d2 inside the layer W image
      wexp = {wimg[((op_woff[cur_op] + int'(w_addr_d2)) >> 3) + 1],
              wimg[((op_woff[cur_op] + int'(w_addr_d2)) >> 3)]};
      $display("[WDBG] #%0d w_addr=%06x data=%032x exp=%032x %s",
               w_cap_n, w_addr_d2, dut.u_engine.w_rdata, wexp,
               (dut.u_engine.w_rdata === wexp) ? "OK" : "MISMATCH");
    end
  end
  always @(posedge clk) begin
    if (dbg_en && !rst && (cur_op == 1) && dut.u_engine.a_re && (la_cap_n < 20)) begin
      la_cap_n = la_cap_n + 1;
      $display("[LADBG] #%0d la=%06x local=%06x y_ld=%0d x_ld=%0d c_ld=%0d f_p3=%0b",
               la_cap_n, dut.u_engine.la,
               24'(dut.u_engine.la - d_a_src_base),
               $signed(dut.u_engine.y_ld), $signed(dut.u_engine.x_ld),
               dut.u_engine.c_ld, dut.u_engine.f_p3);
    end
  end

  // ---- q-read capture: per-OC-tile Q segment check (Lead hint #1/#2) -------
  logic        q_re_d1;
  logic [12:0] q_addr_d1;
  int          q_print_n;
  always @(posedge clk) begin
    q_re_d1   <= dut.u_engine.q_re;
    q_addr_d1 <= dut.u_engine.q_addr;
    if (dbg_en && !rst && q_re_d1 && (q_print_n < 48)) begin
      logic [63:0] qexp;
      q_print_n = q_print_n + 1;
      qexp = qimg[(op_qoff[cur_op] / 8) + int'(q_addr_d1)];
      $display("[QDBG] op%0d q_addr=%0d(0x%0x) data=%016x exp=%016x %s",
               cur_op, q_addr_d1, q_addr_d1, dut.u_engine.q_rdata, qexp,
               (dut.u_engine.q_rdata === qexp) ? "OK" : "MISMATCH");
    end
  end

  initial q_print_n = 0;

  // ---- op3 W address sequence during MAC (expected: 0,16,32,... for k1) ----
  int wa_cap_n;
  always @(posedge clk) begin
    if (dbg_en && !rst && (cur_op == 3) && dut.u_engine.w_re && (wa_cap_n < 20)) begin
      wa_cap_n = wa_cap_n + 1;
      $display("[WADBG] #%0d w_addr=%06x w_rdata=%032x",
               wa_cap_n, dut.u_engine.w_addr, dut.u_engine.w_rdata);
    end
  end
  initial wa_cap_n = 0;

  always @(posedge clk) begin
    if (rst) begin
      b_beats <= 0;
      b_written <= '0;
    end else if (dut.u_engine.b_we) begin
      b_beats <= b_beats + 1;
      if (24'(dut.u_engine.b_addr - cur_b_base) != 24'(b_lin)) b_ooo = b_ooo + 1;
      b_lin = b_lin + 16;
      if (dbg_en && b_print_n < 20) begin
        b_print_n = b_print_n + 1;
        $display("[DBG] op%0d b_we #%0d addr=%06x local=%06x strb=%04x data=%032x",
                 cur_op, b_print_n, dut.u_engine.b_addr,
                 24'(dut.u_engine.b_addr - cur_b_base),
                 dut.u_engine.b_wstrb, dut.u_engine.b_wdata_128);
      end
      if (24'(dut.u_engine.b_addr - cur_b_base) < 24'(131072))
        b_written[24'(dut.u_engine.b_addr - cur_b_base)>>4] <= 1;
    end
  end

  // ==========================================================================
  // checks
  // ==========================================================================
  int errors;
  int err_shown;

  task automatic fail(input string ctx);
    errors = errors + 1;
    if (err_shown < 40) begin
      err_shown = err_shown + 1;
      $display("[CHAIN][FAIL] %s", ctx);
    end
  endtask

  task automatic chk(input logic cond, input string ctx);
    if (!cond) fail(ctx);
  endtask

  // ==========================================================================
  // DDR backdoor helpers
  // ==========================================================================
  function automatic logic [63:0] get_word(input int unsigned word_idx);
    get_word = dut.peek_word(word_idx);
  endfunction

  task automatic fnv_compact(input int unsigned base,
                             input int h, input int w, input int real_c,
                             input int c8, output logic [31:0] hout);
    int unsigned hh;
    int cw, tail, b;
    logic [63:0] wd;
    hh = 32'd2166136261;
    cw = real_c / 8;
    tail = real_c % 8;
    for (int y = 0; y < h; y++) begin
      for (int x = 0; x < w; x++) begin
        int unsigned pixbase;
        pixbase = base + (y*w + x)*c8;
        for (int k = 0; k < cw; k++) begin
          wd = get_word((pixbase + k*8) >> 3);
          for (b = 0; b < 8; b++) begin
            hh = hh ^ int'(wd[b*8 +: 8]);
            hh = hh * 32'd16777619;
          end
        end
        if (tail != 0) begin
          wd = get_word((pixbase + cw*8) >> 3);
          for (b = 0; b < tail; b++) begin
            hh = hh ^ int'(wd[b*8 +: 8]);
            hh = hh * 32'd16777619;
          end
        end
      end
    end
    hout = hh;
  endtask

  task automatic cmp_region(input int unsigned a_addr, input int unsigned b_addr,
                            input int unsigned nbytes, input string ctx,
                            output int nbad);
    logic [63:0] wa, wb;
    nbad = 0;
    for (int w = 0; w < nbytes/8; w++) begin
      wa = get_word((a_addr >> 3) + w);
      wb = get_word((b_addr >> 3) + w);
      if (wa !== wb) begin
        nbad = nbad + 1;
        if (nbad <= 3)
          $display("[CHAIN]   %s bad word %0d: got %016x exp %016x",
                   ctx, w, wa, wb);
      end
    end
  endtask

  // read one 64-bit word of an nn_mem W bank (M2 layout):
  //   bank0 = global 0..20479 = a[0..16383] + b[0..4095]
  //   bank1 = global 20480..40959 = b[4096..8191] + c[0..8191] + d[0..8191]
  function automatic logic [63:0] wbank_word(input int bank, input int wi);
    if (bank == 0) begin
      if (wi < 16384) wbank_word = dut.u_nn_mem.w_mem_a[wi];
      else            wbank_word = dut.u_nn_mem.w_mem_b[wi - 16384];
    end else begin
      if (wi < 4096)       wbank_word = dut.u_nn_mem.w_mem_b[4096 + wi];
      else if (wi < 12288) wbank_word = dut.u_nn_mem.w_mem_c[wi - 4096];
      else                 wbank_word = dut.u_nn_mem.w_mem_d[wi - 12288];
    end
  endfunction

  // read one 64-bit word of the active Q shadow bank (w_mode=1 mapping)
  //   q_lo index = {1'b0, bank, q_addr[9:0]}
  function automatic logic [63:0] qbank_word(input int bank, input int wi);
    qbank_word = dut.u_nn_mem.q_mem_lo[1024*bank + wi];
  endfunction

  // golden file name: golden_opNNN.hex (3-digit decimal)
  function automatic string golden_path(input string dir, input int opid);
    if (opid < 10)
      golden_path = $sformatf("%s/golden_op00%0d.hex", dir, opid);
    else if (opid < 100)
      golden_path = $sformatf("%s/golden_op0%0d.hex", dir, opid);
    else
      golden_path = $sformatf("%s/golden_op%0d.hex", dir, opid);
  endfunction

  // one nn_mem dbg write (32-bit) into W (space=0) or Q (space=1) region
  task automatic dbg_wr(input int space, input int widx, input logic [31:0] data);
    @(negedge clk);
    dbg_we    = 1'b1;
    dbg_space = 1'(space);
    dbg_addr  = 17'(widx);
    dbg_wdata = data;
    @(posedge clk);
    @(negedge clk);
    dbg_we = 1'b0;
  endtask

  // load the op's W layer (wimg at op_woff) into W ROM starting at 32-bit word 0
  task automatic rom_load_w(input int opi);
    logic [63:0] wd;
    for (int k = 0; k < (op_wlen[opi] + 3) / 4; k++) begin
      wd = wimg[(op_woff[opi] / 8) + (k / 2)];
      dbg_wr(0, k, k[0] ? wd[63:32] : wd[31:0]);
    end
  endtask

  // load the op's Q layer (qimg at op_qoff) into Q ROM starting at 32-bit word 0
  task automatic rom_load_q(input int opi);
    logic [63:0] qd;
    for (int k = 0; k < (op_qlen[opi] + 3) / 4; k++) begin
      qd = qimg[(op_qoff[opi] / 8) + (k / 2)];
      dbg_wr(1, k, k[0] ? qd[63:32] : qd[31:0]);
    end
  endtask

  // ==========================================================================
  // load ops.txt
  // ==========================================================================
  task automatic load_ops(input string path);
    integer fd, r;
    integer v [0:23];
    reg [8*200-1:0] line;
    fd = $fopen(path, "r");
    if (fd == 0) begin
      fail("cannot open ops file");
      return;
    end
    n_ops = 0;
    while (!$feof(fd) && n_ops < MAX_OPS) begin
      r = $fgets(line, fd);
      if (r == 0) break;
      r = $sscanf(line,
        "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
        v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10],
        v[11], v[12], v[13], v[14], v[15], v[16], v[17], v[18], v[19],
        v[20], v[21], v[22], v[23]);
      if (r == 24) begin
        op_id[n_ops]   = v[0];  op_kind[n_ops] = v[1];  op_k[n_ops]    = v[2];
        op_st[n_ops]   = v[3];  op_pad[n_ops]  = v[4];  op_ih[n_ops]   = v[5];
        op_iw[n_ops]   = v[6];  op_ic[n_ops]   = v[7];  op_oc[n_ops]   = v[8];
        op_icp[n_ops]  = v[9];  op_ocp[n_ops]  = v[10]; op_oh[n_ops]   = v[11];
        op_ow[n_ops]   = v[12]; op_src[n_ops]  = v[13]; op_dst[n_ops]  = v[14];
        op_woff[n_ops] = v[15]; op_wlen[n_ops] = v[16]; op_qoff[n_ops] = v[17];
        op_qlen[n_ops] = v[18]; op_nnop[n_ops] = v[19]; op_nnfl[n_ops] = v[20];
        op_csum[n_ops] = (v[21] << 16) | (v[22] & 16'hFFFF);
        op_expc[n_ops] = v[23];
        n_ops = n_ops + 1;
      end
    end
    $fclose(fd);
    $display("[CHAIN] ops parsed: %0d", n_ops);
  endtask

  // ==========================================================================
  // main
  // ==========================================================================
  initial begin : main
    string ops_path, w_path, q_path, in_path, gold_dir;
    string iso_src;
    int iso_op, iso_off;
    int first_op, last_op;
    int syn_h, syn_w;
    string golden_file;
    int nops, n_ok, n_tensor_ok, n_tensor_bad;
    int unsigned pre_cyc, fill_cyc, eng_cyc_m, flush_cyc;
    int unsigned tot_pre, tot_fill, tot_eng, tot_flush, tot_expc;
    logic op_ok;
    logic [31:0] hfnv;
    int nbad;
    logic okf;

    ops_path = ""; w_path = ""; q_path = ""; in_path = ""; gold_dir = "";
    nops = 8;
    wait (!rst);
    repeat (10) @(posedge clk);
    errors = 0; err_shown = 0;
    n_ops = 0;
    pre_start = 1'b0; eng_start = 1'b0; band_start = 1'b0; ddr_rd_owner = 1'b0;
    w_bank_sel = 1'b0; q_bank_sel = 1'b0;
    d_a_src_base = 24'd0; d_a_aux_base = 24'd0; d_b_base = 24'd0;
    stock_addr = 0;
    if ($test$plusargs("stock_addr")) stock_addr = 1;
    d_in_word_off = 17'd0; d_out_word_off = 17'd0;
    dbg_en = 1'b0; cur_b_base = 24'd0; vcd_dumped = 1'b0;
    if ($test$plusargs("dbg")) dbg_en = 1'b1;
    vcd_on = 1'b0; vcd_path = "";
    if ($value$plusargs("vcd=%s", vcd_path)) vcd_on = 1'b1;
    rom_mode = 0;
    if ($test$plusargs("rom_mode")) rom_mode = 1;
    w_mode_sel = rom_mode ? 1'b0 : 1'b1;
    dbg_we = 1'b0; dbg_space = 1'b0; dbg_addr = 17'd0; dbg_wdata = 32'd0;
    $display("================================================================");
    $display("[CHAIN] tb_bottlecap_ddr_chain start (clk=100MHz)");
    $display("================================================================");

    // optional isolation: run exactly one op with its input tensor preloaded
    //   +iso_op=<n> +iso_src=<64b hex file>   (file = that op's input tensor)
    if (!$value$plusargs("ops=%s", ops_path))       fail("missing +ops");
    if (!$value$plusargs("whex=%s", w_path))        fail("missing +whex");
    if (!$value$plusargs("qhex=%s", q_path))        fail("missing +qhex");
    if (!$value$plusargs("inhex=%s", in_path))      fail("missing +inhex");
    if (!$value$plusargs("nops=%d", nops))          nops = 8;
    syn_h = 0; syn_w = 0; golden_file = "";
    if (!$value$plusargs("syn_ih=%d", syn_h)) syn_h = 0;
    if (!$value$plusargs("syn_iw=%d", syn_w)) syn_w = 0;
    void'($value$plusargs("golden_file=%s", golden_file));
    iso_op = -1; iso_src = "";
    if ($value$plusargs("iso_op=%d", iso_op) &&
        $value$plusargs("iso_src=%s", iso_src)) begin
      $display("[CHAIN] ISO mode: only op %0d, input preloaded from %s", iso_op, iso_src);
    end else begin
      iso_op = -1;
    end
    if (!$value$plusargs("golden_dir=%s", gold_dir)) gold_dir = "";

    if (errors == 0) begin
      load_ops(ops_path);
      if (n_ops == 0) fail("no ops parsed");
      if (nops > n_ops) nops = n_ops;
      if (syn_h > 0 && syn_w > 0) begin
        for (int i = 0; i < n_ops; i++) begin
          if (op_k[i] <= 1 && op_pad[i] == 0) begin
            op_ih[i] = syn_h; op_iw[i] = syn_w;
            op_oh[i] = syn_h; op_ow[i] = syn_w;
          end
        end
        $display("[CHAIN] SYNTHETIC geometry: ih=iw=%0d (oh=ow=%0d) for k1/p0 ops",
                 syn_h, syn_w);
      end
      $display("[CHAIN] run ops: %0d (of %0d parsed)", nops, n_ops);
      dut.load_hex(w_path, W_BASE >> 3);
      dut.load_hex(q_path, Q_BASE >> 3);
      dut.load_hex(in_path, ARENA_BASE >> 3);
      $readmemh(w_path, wimg);
      $readmemh(q_path, qimg);
      $readmemh(in_path, iimg);
      $display("[CHAIN] images loaded: W=0x%08x Q=0x%08x arena=0x%08x",
               W_BASE, Q_BASE, ARENA_BASE);
    end

    first_op = 0;
    last_op  = nops - 1;
    if (iso_op >= 0) begin
      first_op = iso_op;
      last_op  = iso_op;
      if (errors == 0) begin
        iso_off = op_src[iso_op];
        dut.load_hex(iso_src, (ARENA_BASE + iso_off) >> 3);
        $display("[CHAIN] ISO: preloaded input tensor at arena 0x%08x", ARENA_BASE + iso_off);
      end
    end
    n_ok = 0; n_tensor_ok = 0; n_tensor_bad = 0;
    tot_pre = 0; tot_fill = 0; tot_eng = 0; tot_flush = 0; tot_expc = 0;

    if (errors == 0) begin
      for (int i = first_op; i <= last_op; i++) begin
        int in_row_bytes, out_row_bytes;
        int unsigned n;

        // ---- activation descriptor: one band = whole tensor ----------------
        if (op_nnfl[i] & 32)                          // PACKED3: 3B/pixel
          in_row_bytes = op_iw[i] * 3;
        else
          in_row_bytes = op_iw[i] * op_icp[i];
        out_row_bytes = op_ow[i] * op_ocp[i];
        d_in_base      = ARENA_BASE + op_src[i];
        cur_in_base    = ARENA_BASE + op_src[i];
        d_in_rows      = 16'(op_ih[i]);
        d_in_row_bytes = 16'(in_row_bytes);
        d_in_stride    = 16'(in_row_bytes);
        d_in_pad_top   = 16'd0;
        d_in_rd_rows   = 16'(op_ih[i]);
        d_zp_in        = 8'd0;
        d_add_mode     = (op_nnop[i] == 3);
        d_aux_base     = ARENA_BASE + op_dst[i];
        d_aux_stride   = 16'(in_row_bytes);
        d_aux_pad_top  = 16'd0;
        d_aux_rd_rows  = 16'(op_ih[i]);
        d_out_base     = ARENA_BASE + op_dst[i];
        d_out_rows     = 16'(op_oh[i]);
        d_out_row_bytes= 16'(out_row_bytes);
        d_out_stride   = 16'(out_row_bytes);

        a_cap_n = 0; a_bad_n = 0;
        b_lin = 0; b_ooo = 0; b_print_n = 0; q_print_n = 0;
        la_cap_n = 0; w_cap_n = 0; wa_cap_n = 0; cur_op = i;

        // ---- stock-address control mode (M6b debug) -----------------------
        // data is placed at the same buffer word offsets as nn_mem's real A/B
        // windows; engine desc uses the real window offsets and bases are 0.
        if (stock_addr) begin
          d_a_src_base  = 24'd0;
          d_a_aux_base  = 24'd0;
          d_b_base      = 24'd0;
          d_in_word_off = 17'(24'h06_0000 >> 4);
          d_out_word_off= 17'(24'h07_8000 >> 4);
        end else begin
          d_in_word_off = 17'd0;
          d_out_word_off= 17'd0;
        end

        // ---- engine-side address bases (latched by band_start!) -----------
        // The real engine emits NN-window ABSOLUTE addresses; the tilecache
        // subtracts these bases.  They MUST be stable before band_start.
        // In stock-address mode the bases are 0 (buffer offsets = absolute
        // window offsets), so skip the override below.
        if (!stock_addr) begin
          d_a_src_base = ENG_SRC_BASE;
          d_a_aux_base = ENG_DST_BASE;
          d_b_base     = ENG_DST_BASE;
        end

        // ---- weight/Q prefetch into the inactive bank ----------------------
        @(negedge clk);
        pre_start     = 1'b1;
        pre_src_addr  = W_BASE + op_woff[i];
        pre_wlen      = 18'(op_wlen[i]);
        pre_qsrc_addr = Q_BASE + op_qoff[i];
        pre_qlen      = 13'(op_qlen[i]);
        pre_bank      = ~w_bank_sel;
        @(posedge clk);
        @(negedge clk);
        pre_start = 1'b0;
        n = 0;
        while (!pre_done && n < WD) begin @(posedge clk); n = n + 1; end
        pre_cyc = n;
        chk(pre_done && !pre_err, "prefetch pre_done/pre_err");
        // switch the active bank to the one just filled
        w_bank_sel = ~w_bank_sel;
        q_bank_sel = w_bank_sel;
        @(posedge clk);

        // ---- debug: W/Q bank content vs stream image (Lead checklist #4) ----
        if (dbg_en) begin
          int nbad_w, nbad_q, wk, qk;
          logic [63:0] expw, gotw;
          nbad_w = 0;
          nbad_q = 0;
          for (wk = 0; wk < (op_wlen[i] + 7) / 8; wk++) begin
            expw = wimg[(op_woff[i] / 8) + wk];
            gotw = wbank_word(w_bank_sel, wk);
            if (gotw !== expw) begin
              nbad_w = nbad_w + 1;
              if (nbad_w <= 3)
                $display("[DBG] op %0d W word %0d: got %016x exp %016x (bank %0d)",
                         op_id[i], wk, gotw, expw, w_bank_sel);
            end
          end
          for (qk = 0; qk < (op_qlen[i] + 7) / 8; qk++) begin
            expw = qimg[(op_qoff[i] / 8) + qk];
            gotw = qbank_word(q_bank_sel, qk);
            if (gotw !== expw) begin
              nbad_q = nbad_q + 1;
              if (nbad_q <= 3)
                $display("[DBG] op %0d Q word %0d: got %016x exp %016x (bank %0d)",
                         op_id[i], qk, gotw, expw, q_bank_sel);
            end
          end
          $display("[DBG] op %0d bank=%0d: W words=%0d bad=%0d, Q words=%0d bad=%0d",
                   op_id[i], w_bank_sel, (op_wlen[i] + 7) / 8, nbad_w,
                   (op_qlen[i] + 7) / 8, nbad_q);
        end

        // ---- band fill -----------------------------------------------------
        ddr_rd_owner = 1'b1;
        @(negedge clk);
        band_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        band_start = 1'b0;
        n = 0;
        while (!band_ready && n < WD) begin @(posedge clk); n = n + 1; end
        fill_cyc = n;
        chk(band_ready, "band_ready timeout");
        chk(tc_err == 8'h00, "tilecache err after fill");

        // ---- ROM control test: load this layer into nn_mem ROM (w_mode=0) --
        if (rom_mode) begin
          rom_load_w(i);
          rom_load_q(i);
          $display("[CHAIN] ROM mode: op %0d layer loaded (W %0d B, Q %0d B) at ROM byte 0",
                   op_id[i], op_wlen[i], op_qlen[i]);
        end

        // ---- real engine ---------------------------------------------------
        // The real engine uses NN-window ABSOLUTE addressing: base0_a is
        // derived from desc.src (minus pad steps), and a_sel/b_sel are chosen
        // by (addr >= NN_B_OFF).  Use a non-zero src base (must stay above the
        // pad-derived negative terms) and, for ADD, a dst base >= NN_B_OFF so
        // the engine reads the dst operand through a_sel=1 (aux IBUF bank).
        // src in A window (< NN_B_OFF -> a_sel=0), dst in B window
        // (>= NN_B_OFF -> a_sel=1 for ADD operand / b_sel=1 for writes)
        if (stock_addr) begin
          eng_desc.src = 32'h0006_0000;
          eng_desc.dst = 32'h0007_8000;
        end else begin
          eng_desc.src = {8'd0, ENG_SRC_BASE};
          eng_desc.dst = {8'd0, ENG_DST_BASE};
        end
        cur_b_base = d_b_base;   // for the debug monitor
        eng_desc.op     = 2'(op_nnop[i]);
        eng_desc.flags  = 8'(op_nnfl[i]);
        eng_desc.ks     = 4'((op_k[i] == 0) ? 1 : op_k[i]);
        eng_desc.stride = 2'((op_st[i] == 0) ? 1 : op_st[i]);
        eng_desc.pad    = 3'(op_pad[i]);
        eng_desc.ih     = 16'(op_ih[i]);
        eng_desc.iw     = 16'(op_iw[i]);
        eng_desc.ic     = 16'(op_ic[i]);
        eng_desc.oc     = 16'(op_oc[i]);
        eng_desc.woff   = 32'd0;
        eng_desc.qoff   = 32'd0;
        @(negedge clk);
        eng_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        eng_start = 1'b0;
        // optional short VCD window for the engine owner (first 2000 cycles
        // after eng_start; engine + mem + wload + tilecache internals)
        if (vcd_on && !vcd_dumped) begin
          vcd_dumped = 1'b1;
          $dumpfile(vcd_path);
          $dumpvars(0, dut.u_engine);
          $dumpvars(0, dut.u_nn_mem);
          $dumpvars(0, dut.u_wload);
          repeat (2000) @(posedge clk);
          $dumpoff;
          $display("[CHAIN] VCD window dumped (2000 cycles) -> %s", vcd_path);
        end
        if (dbg_en && (cur_op == 3)) begin
          repeat (6) @(posedge clk);
          $display("[EDBG] desc: op=%0d flags=%02x ks=%0d pad=%0d ih=%0d iw=%0d ic=%0d oc=%0d",
                   dut.u_engine.d_op, dut.u_engine.d_flags, dut.u_engine.d_ks,
                   dut.u_engine.d_pad, dut.u_engine.d_ih,
                   dut.u_engine.d_iw, dut.u_engine.d_ic, dut.u_engine.d_oc);
          $display("[EDBG] derived: pad_eff=%0d dense=%0b f_dw=%0b f_p3=%0b ic8_r=%0d oc8_r=%0d row_step_a=%0d band_step_a=%0d d_woff=%06x d_qoff=%06x",
                   dut.u_engine.pad_eff, dut.u_engine.dense, dut.u_engine.f_dw,
                   dut.u_engine.f_p3, dut.u_engine.ic8_r, dut.u_engine.oc8_r,
                   dut.u_engine.row_step_a, dut.u_engine.band_step_a,
                   dut.u_engine.d_woff, dut.u_engine.d_qoff);
        end
        n = 0;
        while (!eng_done && n < WD) begin @(posedge clk); n = n + 1; end
        eng_cyc_m = n;
        chk(eng_done, "engine timeout");
        chk(eng_err == 8'h00, "engine err_code");

        // ---- flush ---------------------------------------------------------
        n = 0;
        while (!band_done && n < WD) begin @(posedge clk); n = n + 1; end
        flush_cyc = n;
        chk(band_done, "band_done timeout");
        chk(tc_err == 8'h00, "tilecache err after flush");
        ddr_rd_owner = 1'b0;
        @(posedge clk);

        // ---- debug: OBUF coverage + engine b-beat count -------------------
        if (dbg_en) begin
          int exp_words, nw, first_uw;
          exp_words = (op_oh[i]*out_row_bytes) / 16;
          nw = 0;
          first_uw = -1;
          for (int w = 0; w < exp_words; w++) begin
            if (!b_written[w]) begin
              nw = nw + 1;
              if (first_uw < 0) first_uw = w;
            end
          end
          $display("[DBG] op %0d: b_we beats=%0d, expected 128b words=%0d, unwritten=%0d first=%0d",
                   op_id[i], b_beats, exp_words, nw, first_uw);
          $display("[DBG] op %0d: a-reads=%0d bad=%0d, b out-of-order=%0d (linear)",
                   op_id[i], a_cap_n, a_bad_n, b_ooo);
        end

        // ---- judge 1: FNV over compact real channels -----------------------
        fnv_compact(ARENA_BASE + op_dst[i], op_oh[i], op_ow[i],
                    op_oc[i], op_ocp[i], hfnv);
        chk(hfnv == 32'(op_csum[i]), "op FNV != plan csum");

        // ---- judge 2: tensor golden (arena layout, incl. pad bytes) --------
        if (gold_dir != "") begin
          string gpath;
          integer fd, j;
          gpath = (golden_file != "") ? golden_file : golden_path(gold_dir, op_id[i]);
          fd = $fopen(gpath, "r");
          if (fd != 0) begin
            $fclose(fd);
            dut.load_hex(gpath, GOLD_BASE >> 3);
            $display("[CHAIN] golden %s: arena w0=%016x gold w0=%016x nbytes=%0d",
                     gpath, get_word((ARENA_BASE + op_dst[i]) >> 3),
                     get_word(GOLD_BASE >> 3), op_oh[i]*out_row_bytes);
            cmp_region(ARENA_BASE + op_dst[i], GOLD_BASE,
                       op_oh[i]*out_row_bytes, "tensor_golden", nbad);
            if (dbg_en) begin
              int oct_per_pix, nov, nbad_oct;
              oct_per_pix = (op_ocp[i] + 15) / 16;
              begin : dump_out
            string dpath;
            int fd;
            logic [63:0] dw;
            if ($value$plusargs("dump_out=%s", dpath)) begin
              fd = $fopen(dpath, "w");
              if (fd != 0) begin
                for (int w = 0; w < op_oh[i]*out_row_bytes/8; w++) begin
                  dw = get_word(((ARENA_BASE + op_dst[i]) >> 3) + w);
                  $fwrite(fd, "%016x\n", dw);
                end
                $fclose(fd);
                $display("[CHAIN] dumped op %0d output (%0d B) to %s",
                         op_id[i], op_oh[i]*out_row_bytes, dpath);
              end
            end
          end
          $display("[DBG] op %0d golden mismatch by OC tile (of %0d):",
                       op_id[i], oct_per_pix);
              for (int oct = 0; oct < oct_per_pix; oct++) begin
                nbad_oct = 0;
                for (int w = 0; w < op_oh[i]*out_row_bytes/8; w++) begin
                  if ((w % oct_per_pix) == oct &&
                      get_word((ARENA_BASE + op_dst[i])/8 + w) !==
                      get_word((GOLD_BASE)/8 + w))
                    nbad_oct = nbad_oct + 1;
                end
                $display("[DBG]   op %0d tile%0d: bad words=%0d", op_id[i], oct, nbad_oct);
              end
            end
            if (nbad == 0) n_tensor_ok = n_tensor_ok + 1;
            else begin
              n_tensor_bad = n_tensor_bad + 1;
              fail("tensor golden mismatch");
            end
          end
        end

        op_ok = (hfnv == 32'(op_csum[i]));
        if (op_ok) n_ok = n_ok + 1;
        tot_pre = tot_pre + pre_cyc;
        tot_fill = tot_fill + fill_cyc;
        tot_eng = tot_eng + eng_cyc_m;
        tot_flush = tot_flush + flush_cyc;
        tot_expc = tot_expc + op_expc[i];
        $display("[CHAIN] op %0d kind=%0d FNV=%08x exp=%08x fill=%0d eng=%0d (model %0d) flush=%0d %s",
                 op_id[i], op_kind[i], hfnv, op_csum[i],
                 fill_cyc, eng_cyc_m, op_expc[i], flush_cyc,
                 (op_ok ? "FNV_OK" : "FNV_FAIL"));
      end
    end

    $display("\n[CHAIN] ---- cycle accounting (v1 loose buffers, 1 band/op) ----");
    $display("[CHAIN] prefetch cycles : %0d", tot_pre);
    $display("[CHAIN] fill cycles     : %0d", tot_fill);
    $display("[CHAIN] engine cycles   : %0d (cycle_model p0: %0d)",
             tot_eng, tot_expc);
    $display("[CHAIN] flush cycles    : %0d", tot_flush);
    $display("[CHAIN] total band cycles: %0d", tot_fill + tot_eng + tot_flush);
    if (tot_expc > 0)
      $display("[CHAIN] engine/model delta: %0.2f%%",
               (int'(tot_eng) - int'(tot_expc)) * 100.0 / tot_expc);

    $display("\n================================================================");
    $display("[CHAIN] SUMMARY: %0d/%0d ops FNV pass, %0d tensor goldens OK (%0d bad), errors=%0d",
             n_ok, nops, n_tensor_ok, n_tensor_bad, errors);
    $display("================================================================");
    if (errors == 0) $display("BOTTLECAP_DDR_CHAIN_TB: PASS");
    else             $display("BOTTLECAP_DDR_CHAIN_TB: FAIL (%0d errors)", errors);
    $finish;
  end

endmodule
