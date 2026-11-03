`timescale 1ns/1ps

// ============================================================================
// tb_bottlecap_ddr_banded.sv -- M6b v2: bottlecap DDR3 chain, BANDED execution
// ----------------------------------------------------------------------------
// Owner: rtl-stream (task-15 / M6b).  Pass marker:
//   "BOTTLECAP_DDR_BANDED_TB: PASS"
//
// Why v2: v1 (tb_bottlecap_ddr_chain) ran ONE band = whole tensor and fed the
// real engine desc.ih = full image height.  Cross-team debugging (M6b report
// app. G/H/I) established that the real engine's DENSE path is only validated
// in banded form (desc.ih = band input rows), matching ddr3-feas task-20:
//   OP3ISO: PASS rows=13 cyc=28963 mis=0   (stock nn_mem, band of 13 rows)
// v1 PACKED3 (op0) happened to pass in whole-tensor mode; dense ops did not.
//
// v2 scope (this TB): banded chain for k=1/stride=1/pad=0 ops (no horizontal
// pad materialisation needed) -- op1/op3/op4 of bottlecap.  pad>0 ops need the
// M4 "Path A" horizontal pad materialisation in nn_tilecache (next step).
//
// Chain: beh_ddr3 -> nn_wload (W/Q per layer) -> nn_mem(stream) -> nn_tilecache
//        (per-band fill) -> REAL nn_conv_engine (desc.ih = band in_rows) ->
//        band flush -> DDR arena.  A/B provider is the tilecache (2 MB banks),
//        addresses passed as NN-window absolute + per-side base subtraction.
//
// Judging per op (after all bands): FNV-1a over compact NHWC real channels vs
// plan csum, plus optional tensor golden compare (arena layout incl pad).
//
// Plusargs
//   +ops=<ops.txt> +bands=<bands.txt> +whex= +qhex= +inhex= +golden_dir=
//   +nops=<n>  +dbg
// ============================================================================

module tb_bottlecap_ddr_banded;

  localparam logic [31:0] W_BASE     = 32'h0000_0000;
  localparam logic [31:0] Q_BASE     = 32'h0020_0000;
  localparam logic [31:0] ARENA_BASE = 32'h0040_0000;
  localparam logic [31:0] GOLD_BASE  = 32'h0070_0000;
  localparam int MAX_OPS   = 128;
  localparam int MAX_BANDS = 4096;
  localparam int WD        = 40_000_000;

  logic clk, rst;
  initial begin clk = 1'b0; forever #5 clk = ~clk; end
  initial begin
    rst = 1'b1;
    repeat (32) @(posedge clk);
    rst = 1'b0;
  end

  // ---- DUT wrapper ports ----
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
  logic         band_start, band_ready, band_done, tc_busy;
  logic [7:0]   tc_err;
  logic [31:0]  tc_fill_beats, tc_flush_beats;
  nn_pkg::nn_desc_t eng_desc;
  logic         eng_start, eng_busy, eng_done;
  logic [31:0]  eng_cycles;
  logic [7:0]   eng_err;
  logic         ddr_rd_owner;

  nn_ddr_chain #(
    .MEM_BYTES (8*1024*1024),
    .READ_LAT  (40),
    .BEAT_GAP  (4),
    .IB_BYTES  (2*1024*1024),
    .OB_BYTES  (2*1024*1024)
  ) dut (
    .clk (clk), .rst (rst),
    .pre_start (pre_start), .pre_src_addr (pre_src_addr), .pre_wlen (pre_wlen),
    .pre_qsrc_addr (pre_qsrc_addr), .pre_qlen (pre_qlen), .pre_bank (pre_bank),
    .pre_busy (pre_busy), .pre_done (pre_done), .pre_err (pre_err),
    .w_bank_sel (w_bank_sel), .q_bank_sel (q_bank_sel),
    .d_in_base (d_in_base), .d_in_rows (d_in_rows),
    .d_in_row_bytes (d_in_row_bytes), .d_in_stride (d_in_stride),
    .d_in_pad_top (d_in_pad_top), .d_in_rd_rows (d_in_rd_rows),
    .d_zp_in (d_zp_in), .d_add_mode (d_add_mode),
    .d_aux_base (d_aux_base), .d_aux_stride (d_aux_stride),
    .d_aux_pad_top (d_aux_pad_top), .d_aux_rd_rows (d_aux_rd_rows),
    .d_out_base (d_out_base), .d_out_rows (d_out_rows),
    .d_out_row_bytes (d_out_row_bytes), .d_out_stride (d_out_stride),
    .d_a_src_base (d_a_src_base), .d_a_aux_base (d_a_aux_base),
    .d_b_base (d_b_base),
    .d_in_word_off (d_in_word_off), .d_out_word_off (d_out_word_off),
    .band_start (band_start), .band_ready (band_ready), .band_done (band_done),
    .tc_busy (tc_busy), .tc_err (tc_err),
    .tc_fill_beats (tc_fill_beats), .tc_flush_beats (tc_flush_beats),
    .eng_desc (eng_desc), .eng_start (eng_start), .eng_busy (eng_busy),
    .eng_done (eng_done), .eng_cycles (eng_cycles), .eng_err (eng_err),
    .ddr_rd_owner (ddr_rd_owner),
    .w_mode_sel (1'b1), .dbg_we (1'b0), .dbg_space (1'b0),
    .dbg_addr (17'd0), .dbg_wdata (32'd0)
  );

  // ---- op table ----
  int op_id  [0:MAX_OPS-1];
  int op_kind[0:MAX_OPS-1];
  int op_k   [0:MAX_OPS-1];
  int op_st  [0:MAX_OPS-1];
  int op_pad [0:MAX_OPS-1];
  int op_ih  [0:MAX_OPS-1];
  int op_iw  [0:MAX_OPS-1];
  int op_ic  [0:MAX_OPS-1];
  int op_oc  [0:MAX_OPS-1];
  int op_icp [0:MAX_OPS-1];
  int op_ocp [0:MAX_OPS-1];
  int op_oh  [0:MAX_OPS-1];
  int op_ow  [0:MAX_OPS-1];
  int op_src [0:MAX_OPS-1];
  int op_dst [0:MAX_OPS-1];
  int op_woff[0:MAX_OPS-1];
  int op_wlen[0:MAX_OPS-1];
  int op_qoff[0:MAX_OPS-1];
  int op_qlen[0:MAX_OPS-1];
  int op_nnop[0:MAX_OPS-1];
  int op_nnfl[0:MAX_OPS-1];
  int op_csum[0:MAX_OPS-1];
  int n_ops;

  // ---- band table ----
  int  b_op [0:MAX_BANDS-1];
  int  b_in_off[0:MAX_BANDS-1];
  int  b_in_rows[0:MAX_BANDS-1];
  int  b_pad_top[0:MAX_BANDS-1];
  int  b_rd_rows[0:MAX_BANDS-1];
  int  b_out_off[0:MAX_BANDS-1];
  int  b_out_rows[0:MAX_BANDS-1];
  int  b_in_rb [0:MAX_BANDS-1];
  int  b_out_rb[0:MAX_BANDS-1];
  int  b_add   [0:MAX_BANDS-1];
  int  n_bands_tab;

  // ---- engines bases for this env (tilecache subtracts) ----
  localparam logic [23:0] ENG_SRC_BASE = 24'h06_0000;
  localparam logic [23:0] ENG_DST_BASE = 24'h07_8000;

  int errors, err_shown;
  logic trace_done;
  task automatic fail(input string ctx);
    errors = errors + 1;
    if (err_shown < 30) begin
      err_shown = err_shown + 1;
      $display("[BANDED][FAIL] %s", ctx);
    end
  endtask
  task automatic chk(input logic c, input string ctx);
    if (!c) fail(ctx);
  endtask

  function automatic logic [63:0] get_word(input int unsigned wi);
    get_word = dut.peek_word(wi);
  endfunction

  task automatic fnv_compact(input int unsigned base, input int h, input int w,
                             input int real_c, input int c8, output logic [31:0] hout);
    int unsigned hh; int cw, tail, b; logic [63:0] wd;
    hh = 32'd2166136261; cw = real_c / 8; tail = real_c % 8;
    for (int y = 0; y < h; y++)
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
    hout = hh;
  endtask

  task automatic cmp_region(input int unsigned a, input int unsigned bb,
                            input int unsigned nbytes, output int nbad);
    logic [63:0] wa, wb;
    nbad = 0;
    for (int w = 0; w < nbytes/8; w++) begin
      wa = get_word((a >> 3) + w);
      wb = get_word((bb >> 3) + w);
      if (wa !== wb) begin
        nbad = nbad + 1;
        if (nbad <= 3) $display("[BANDED]   bad word %0d got %016x exp %016x", w, wa, wb);
      end
    end
  endtask

  task automatic load_ops(input string path);
    integer fd, r, v [0:22];
    reg [8*200-1:0] line;
    fd = $fopen(path, "r");
    if (fd == 0) begin fail("open ops"); return; end
    n_ops = 0;
    while (!$feof(fd) && n_ops < MAX_OPS) begin
      r = $fgets(line, fd);
      if (r == 0) break;
      r = $sscanf(line,
        "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
        v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10],
        v[11], v[12], v[13], v[14], v[15], v[16], v[17], v[18], v[19],
        v[20], v[21], v[22]);
      if (r == 23) begin
        op_id[n_ops]=v[0]; op_kind[n_ops]=v[1]; op_k[n_ops]=v[2];
        op_st[n_ops]=v[3]; op_pad[n_ops]=v[4]; op_ih[n_ops]=v[5];
        op_iw[n_ops]=v[6]; op_ic[n_ops]=v[7]; op_oc[n_ops]=v[8];
        op_icp[n_ops]=v[9]; op_ocp[n_ops]=v[10]; op_oh[n_ops]=v[11];
        op_ow[n_ops]=v[12]; op_src[n_ops]=v[13]; op_dst[n_ops]=v[14];
        op_woff[n_ops]=v[15]; op_wlen[n_ops]=v[16]; op_qoff[n_ops]=v[17];
        op_qlen[n_ops]=v[18]; op_nnop[n_ops]=v[19]; op_nnfl[n_ops]=v[20];
        op_csum[n_ops]=(v[21] << 16) | (v[22] & 16'hFFFF);
        n_ops = n_ops + 1;
      end
    end
    $fclose(fd);
    $display("[BANDED] ops parsed: %0d", n_ops);
  endtask

  task automatic load_bands(input string path);
    integer fd, r, v [0:10];
    reg [8*200-1:0] line;
    fd = $fopen(path, "r");
    if (fd == 0) begin fail("open bands"); return; end
    n_bands_tab = 0;
    while (!$feof(fd) && n_bands_tab < MAX_BANDS) begin
      r = $fgets(line, fd);
      if (r == 0) break;
      r = $sscanf(line, "%d %d %d %d %d %d %d %d %d %d %d",
        v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10]);
      if (r == 11) begin
        b_op[n_bands_tab]=v[0]; b_in_off[n_bands_tab]=v[2];
        b_in_rows[n_bands_tab]=v[3]; b_pad_top[n_bands_tab]=v[4];
        b_rd_rows[n_bands_tab]=v[5]; b_out_off[n_bands_tab]=v[6];
        b_out_rows[n_bands_tab]=v[7]; b_in_rb[n_bands_tab]=v[8];
        b_out_rb[n_bands_tab]=v[9]; b_add[n_bands_tab]=v[10];
        n_bands_tab = n_bands_tab + 1;
      end
    end
    $fclose(fd);
    $display("[BANDED] bands parsed: %0d", n_bands_tab);
  endtask

  // ---- main ----
  initial begin : main
    string ops_path, bands_path, w_path, q_path, in_path, gold_dir;
    int nops;
    int n_ok, n_tensor_ok, n_tensor_bad;
    int unsigned tot_fill, tot_eng, tot_flush, tot_exp;
    int bfirst, bcount, bi;
    string preload_path, trace_path, golden_file, preload2_path;
    int preload_off, judge_rows, start_op, preload2_off;

    wait (!rst);
    repeat (10) @(posedge clk);
    errors = 0; err_shown = 0;
    n_ops = 0; n_bands_tab = 0; nops = 4; trace_done = 0;
    pre_start = 0; eng_start = 0; band_start = 0; ddr_rd_owner = 0;
    w_bank_sel = 0; q_bank_sel = 0;
    d_a_src_base = 24'd0; d_a_aux_base = 24'd0; d_b_base = 24'd0;
    d_in_word_off = 17'd0; d_out_word_off = 17'd0;
    d_zp_in = 8'd0;
    $display("================================================================");
    $display("[BANDED] tb_bottlecap_ddr_banded start (banded chain, 100MHz)");
    $display("================================================================");

    if (!$value$plusargs("ops=%s", ops_path))     fail("missing +ops");
    if (!$value$plusargs("bands=%s", bands_path)) fail("missing +bands");
    if (!$value$plusargs("whex=%s", w_path))      fail("missing +whex");
    if (!$value$plusargs("qhex=%s", q_path))      fail("missing +qhex");
    if (!$value$plusargs("inhex=%s", in_path))    fail("missing +inhex");
    if (!$value$plusargs("nops=%d", nops))        nops = 4;
    if (!$value$plusargs("golden_dir=%s", gold_dir)) gold_dir = "";
    preload_path = ""; preload_off = 0; trace_path = "";
    if (!$value$plusargs("preload=%s", preload_path)) preload_path = "";
    if (!$value$plusargs("preload_off=%d", preload_off)) preload_off = 0;
    if (!$value$plusargs("trace=%s", trace_path)) trace_path = "";
    judge_rows = 0; golden_file = "";
    start_op = 0;
    if (!$value$plusargs("start_op=%d", start_op)) start_op = 0;
    preload2_path = ""; preload2_off = 0;
    if (!$value$plusargs("preload2=%s", preload2_path)) preload2_path = "";
    if (!$value$plusargs("preload2_off=%d", preload2_off)) preload2_off = 0;
    if (!$value$plusargs("judge_rows=%d", judge_rows)) judge_rows = 0;
    if (!$value$plusargs("golden_file=%s", golden_file)) golden_file = "";

    load_ops(ops_path);
    load_bands(bands_path);
    if (nops > n_ops) nops = n_ops;
    dut.load_hex(w_path, W_BASE >> 3);
    dut.load_hex(q_path, Q_BASE >> 3);
    dut.load_hex(in_path, ARENA_BASE >> 3);
    if (preload_path != "") begin
      dut.load_hex(preload_path, (ARENA_BASE + preload_off) >> 3);
      $display("[BANDED] preloaded %s at arena 0x%08x", preload_path,
               ARENA_BASE + preload_off);
    end
    if (preload2_path != "") begin
      dut.load_hex(preload2_path, (ARENA_BASE + preload2_off) >> 3);
      $display("[BANDED] preloaded2 %s at arena 0x%08x", preload2_path,
               ARENA_BASE + preload2_off);
    end
    $display("[BANDED] images loaded");

    n_ok = 0; n_tensor_ok = 0; n_tensor_bad = 0;
    tot_fill = 0; tot_eng = 0; tot_flush = 0; tot_exp = 0;

    for (int i = start_op; i < nops; i++) begin
      int unsigned n;
      logic [31:0] hfnv;
      int nbad, jrows;
      logic op_ok, ok_fill, ok_eng, ok_flush, ok_pre;
      int in_row_bytes, out_row_bytes;

      // band range for this op
      bfirst = -1; bcount = 0;
      for (int t = 0; t < n_bands_tab; t++)
        if (b_op[t] == i) begin
          if (bfirst < 0) bfirst = t;
          bcount = bcount + 1;
        end
      if (bfirst < 0) begin
        $display("[BANDED] op %0d has no band entries -> skip", i);
        continue;
      end

      // ---- W/Q prefetch once per op, then flip bank ----
      @(negedge clk);
      pre_start = 1'b1;
      pre_src_addr = W_BASE + op_woff[i];
      pre_wlen = 18'(op_wlen[i]);
      pre_qsrc_addr = Q_BASE + op_qoff[i];
      pre_qlen = 13'(op_qlen[i]);
      pre_bank = ~w_bank_sel;
      @(posedge clk);
      @(negedge clk);
      pre_start = 1'b0;
      n = 0;
      while (!pre_done && n < WD) begin @(posedge clk); n = n + 1; end
      ok_pre = pre_done && !pre_err;
      chk(ok_pre, "prefetch");
      w_bank_sel = ~w_bank_sel;
      q_bank_sel = w_bank_sel;
      @(posedge clk);

      // ---- per-band fill -> engine -> flush ----
      for (int k = 0; k < bcount; k++) begin
        bi = bfirst + k;
        in_row_bytes  = b_in_rb[bi];
        out_row_bytes = b_out_rb[bi];

        d_in_base       = ARENA_BASE + b_in_off[bi];
        d_in_rows       = 16'(b_in_rows[bi]);
        d_in_row_bytes  = 16'(in_row_bytes);
        d_in_stride     = 16'(in_row_bytes);
        d_in_pad_top    = 16'(b_pad_top[bi]);
        d_in_rd_rows    = 16'(b_rd_rows[bi]);
        d_zp_in         = 8'd0;
        d_add_mode      = (b_add[bi] != 0);
        d_aux_base      = ARENA_BASE + b_out_off[bi];
        d_aux_stride    = 16'(out_row_bytes);
        d_aux_pad_top   = 16'd0;
        d_aux_rd_rows   = 16'(b_in_rows[bi]);
        d_out_base      = ARENA_BASE + b_out_off[bi];
        d_out_rows      = 16'(b_out_rows[bi]);
        d_out_row_bytes = 16'(out_row_bytes);
        d_out_stride    = 16'(out_row_bytes);
        d_a_src_base    = ENG_SRC_BASE;
        d_a_aux_base    = ENG_DST_BASE;
        d_b_base        = ENG_DST_BASE;

        ddr_rd_owner = 1'b1;
        @(negedge clk);
        band_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        band_start = 1'b0;
        n = 0;
        while (!band_ready && n < WD) begin @(posedge clk); n = n + 1; end
        tot_fill = tot_fill + n;
        ok_fill = band_ready;
        chk(ok_fill, "band_ready");
        chk(tc_err == 8'h00, "tilecache err after fill");

        // engine desc: banded form -> ih = band input rows, pad = 0 (k1/s1/p0)
        eng_desc.op     = 2'(op_nnop[i]);
        eng_desc.flags  = 8'(op_nnfl[i]);
        eng_desc.ks     = 4'((op_k[i] == 0) ? 1 : op_k[i]);
        eng_desc.stride = 2'((op_st[i] == 0) ? 1 : op_st[i]);
        eng_desc.pad    = 3'd0;                       // banded: no engine pad
        eng_desc.ih     = 16'(b_in_rows[bi]);         // band rows!
        eng_desc.iw     = 16'(op_iw[i]);
        eng_desc.ic     = 16'(op_ic[i]);
        eng_desc.oc     = 16'(op_oc[i]);
        eng_desc.src    = {8'd0, ENG_SRC_BASE};
        eng_desc.dst    = {8'd0, ENG_DST_BASE};
        eng_desc.woff   = 32'd0;
        eng_desc.qoff   = 32'd0;
        @(negedge clk);
        eng_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        eng_start = 1'b0;
        if (trace_path != "" && !trace_done) begin : trace_blk
          integer fd;
          logic [31:0] cyc;
          fd = $fopen(trace_path, "w");
          trace_done = 1;
          if (fd != 0) begin
            for (cyc = 0; cyc < 300; cyc = cyc + 1) begin
              @(posedge clk);
              $fwrite(fd, "# TRC %0d a_re=%0d a_sel=%0d a_addr=%06x a_rdata=%032x w_re=%0d w_addr=%06x w_rdata=%032x q_re=%0d q_addr=%05x q_rdata=%016x b_we=%0d b_addr=%06x b_wdata=%032x b_wstrb=%04x\n", cyc, dut.u_engine.a_re, dut.u_engine.a_sel, dut.u_engine.a_addr, dut.u_engine.a_rdata, dut.u_engine.w_re, dut.u_engine.w_addr, dut.u_engine.w_rdata, dut.u_engine.q_re, dut.u_engine.q_addr, dut.u_engine.q_rdata, dut.u_engine.b_we, dut.u_engine.b_addr, dut.u_engine.b_wdata_128, dut.u_engine.b_wstrb);
            end
            $fclose(fd);
            $display("[BANDED] trace written -> %s", trace_path);
          end
        end
        n = 0;
        while (!eng_done && n < WD) begin @(posedge clk); n = n + 1; end
        tot_eng = tot_eng + n;
        ok_eng = eng_done && (eng_err == 8'h00);
        chk(ok_eng, "engine");

        n = 0;
        while (!band_done && n < WD) begin @(posedge clk); n = n + 1; end
        tot_flush = tot_flush + n;
        ok_flush = band_done;
        chk(ok_flush, "band_done");
        chk(tc_err == 8'h00, "tilecache err after flush");
        ddr_rd_owner = 1'b0;
        @(posedge clk);
      end

      // ---- judge this op: FNV + tensor golden ----
      jrows = (judge_rows > 0) ? judge_rows : op_oh[i];
      fnv_compact(ARENA_BASE + op_dst[i], jrows, op_ow[i],
                  op_oc[i], op_ocp[i], hfnv);
      chk(hfnv == 32'(op_csum[i]), "op FNV != plan csum");
      op_ok = (hfnv == 32'(op_csum[i]));

      if (golden_file != "" || gold_dir != "") begin
        string gpath;
        integer fd;
        if (golden_file != "") gpath = golden_file;
        else if (op_id[i] < 10) gpath = $sformatf("%s/golden_op00%0d.hex", gold_dir, op_id[i]);
        else if (op_id[i] < 100) gpath = $sformatf("%s/golden_op0%0d.hex", gold_dir, op_id[i]);
        else gpath = $sformatf("%s/golden_op%0d.hex", gold_dir, op_id[i]);
        fd = $fopen(gpath, "r");
        if (fd != 0) begin
          $fclose(fd);
          dut.load_hex(gpath, GOLD_BASE >> 3);
          cmp_region(ARENA_BASE + op_dst[i], GOLD_BASE,
                     jrows*op_ow[i]*op_ocp[i], nbad);
          if (nbad == 0) n_tensor_ok = n_tensor_ok + 1;
          else begin
            n_tensor_bad = n_tensor_bad + 1;
            fail("tensor golden mismatch");
          end
        end
      end

      if (op_ok) n_ok = n_ok + 1;
      $display("[BANDED] op %0d kind=%0d bands=%0d FNV=%08x exp=%08x %s",
               op_id[i], op_kind[i], bcount, hfnv, op_csum[i],
               op_ok ? "FNV_OK" : "FNV_FAIL");
    end

    $display("\n[BANDED] cycles: fill=%0d eng=%0d flush=%0d", tot_fill, tot_eng, tot_flush);
    $display("================================================================");
    $display("[BANDED] SUMMARY: %0d/%0d ops FNV pass, %0d tensor goldens OK (%0d bad), errors=%0d",
             n_ok, nops, n_tensor_ok, n_tensor_bad, errors);
    $display("================================================================");
    if (errors == 0) $display("BOTTLECAP_DDR_BANDED_TB: PASS");
    else             $display("BOTTLECAP_DDR_BANDED_TB: FAIL (%0d errors)", errors);
    $finish;
  end

endmodule
