`timescale 1ns/1ps

// ============================================================================
// tb_nn_tilecache.sv -- M4 unit testbench: activation band tile cache
// ----------------------------------------------------------------------------
// Owner : rtl-stream (task-9 / M4).  Pass marker: "TILECACHE_TB: PASS".
//
// DUT: nn_tilecache (+ beh_ddr3 used as the DDR3 user-port model).  The TB plays
// both roles that will exist in the SoC:
//   . "nn_seq"      : per band, programs the band descriptor, pulses band_start,
//                     waits band_ready, runs the engine, pulses engine_done,
//                     waits band_done.
//   . "fake engine" : reads the input band through the nn_mem-compatible a_*
//                     port, computes the op, writes the output band through the
//                     b_* port.  Its addressing/padding semantics follow
//                     nn_conv_engine.sv: tile-relative addresses, y/x in-bounds
//                     tracking with zp_in substitution for padding.
//
// Cases
//   case_a : 96x96x8 tensor, 3x3/s1/pad1 conv, whole-tensor golden vs 6 bands
//            (16 output rows each; 18 input rows incl. 2 halo rows) -- the
//            banded result must equal the whole-tensor golden byte for byte.
//   case_b : 3x3/s2/pad1 conv (96x96x8 -> 48x48x8), 6 bands of 8 rows: stride-2
//            halo parity (input band origin is odd: 2*out_row0 - 1).
//   case_c : 8x8x8 3x3/s1/pad1 conv, 1 band: top/bottom/left/right padding must
//            read zp_in (vertical pad rows are materialized by the fill DMA,
//            horizontal pad is handled by the engine x-bounds logic).
//   case_e : ADD op: dst band is filled into the second IBUF bank (a_sel=1) while
//            src is in bank 0 -- solves the 2R1W problem of P3 section 4.5.
//   case_d : slow fill (BEAT_GAP=16 instance): 8x8x8 conv band must fill, run and
//            flush without deadlock; watchdog is on every wait.
//   case_f : band_rows = 1 (B=1) numeric check: 8x8x8 conv3x3/s1/pad1 run as 8
//            single-row bands; every flushed row must equal the whole-tensor
//            golden.  This is the B=1 path the bottlecap big layers use.
//   case_g : bottlecap buffer config (IBUF 2x32KiB on the second instance):
//            112x112x96 dwconv-shaped B=1 band (in_rows=3, in_row_bytes=10,752 =>
//            32,256 B <= 32,768 B) must fill + flush with the right beat counts;
//            proves the 32KiB IBUF removes the 17-layer overflow without
//            IC-block tiling (M4-TILECACHE.md appendix).
//
// The fake engine's "conv" arithmetic is deliberately simple (weighted 3x3
// window sum, >>5 requant, int8 clamp) but deterministic and *identical* for
// the golden and banded paths, so byte equality proves the tiling/descriptor
// logic; it does not try to model the real engine's exact numerics.
// ============================================================================

module tb_nn_tilecache;

  localparam int BUF_BYTES = 131072;   // 128 KiB TB tensor scratch

  // ==========================================================================
  // clock / reset
  // ==========================================================================
  logic clk;
  logic rst;

  initial begin : clkgen
    clk = 1'b0;
    forever #5 clk = ~clk;             // 100 MHz
  end

  initial begin : rstgen
    rst = 1'b1;
    repeat (32) @(posedge clk);
    rst = 1'b0;
    $display("[TILECACHE] reset released @%0t", $time);
  end

  // ==========================================================================
  // main instance : nn_tilecache + beh_ddr3 (READ_LAT=40, BEAT_GAP=4)
  // ==========================================================================
  logic [31:0] d_in_base;
  logic [15:0] d_in_rows, d_in_row_bytes, d_in_stride, d_in_pad_top, d_in_rd_rows;
  logic [7:0]  d_zp_in;
  logic        d_add_mode;
  logic [31:0] d_aux_base;
  logic [15:0] d_aux_stride, d_aux_pad_top, d_aux_rd_rows;
  logic [31:0] d_out_base;
  logic [15:0] d_out_rows, d_out_row_bytes, d_out_stride;

  logic        band_start, band_ready, engine_done, band_done, busy;
  logic [7:0]  err_code;
  logic [1:0]  cur_bank;
  logic [31:0] fill_beats, flush_beats;

  logic        dd_rd_re;
  logic [31:0] dd_rd_addr;
  logic [15:0] dd_rd_len;
  logic        dd_rd_ready;
  logic [127:0] dd_rd_data;
  logic        dd_rd_valid, dd_rd_last, dd_rd_rready;

  logic        dd_wr_re;
  logic [31:0] dd_wr_addr;
  logic [15:0] dd_wr_len;
  logic        dd_wr_ready;
  logic [127:0] dd_wr_data;
  logic        dd_wr_valid, dd_wr_rready, dd_wr_done;

  logic [1:0]  a_sel;
  logic        a_re;
  logic [23:0] a_addr;
  logic [127:0] a_rdata;
  logic [1:0]  b_sel;
  logic        b_we;
  logic [23:0] b_addr;
  logic [127:0] b_wdata;
  logic [15:0] b_wstrb;

  nn_tilecache #(.IB_BYTES(16*1024), .OB_BYTES(12*1024)) u_tc (
    .clk             (clk),
    .rst             (rst),
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
    .d_a_src_base    (24'd0),
    .d_a_aux_base    (24'd0),
    .d_b_base        (24'd0),
    .d_in_word_off   (17'd0),
    .d_out_word_off  (17'd0),
    .band_start      (band_start),
    .band_ready      (band_ready),
    .engine_done     (engine_done),
    .band_done       (band_done),
    .busy            (busy),
    .err_code        (err_code),
    .cur_bank        (cur_bank),
    .fill_beats      (fill_beats),
    .flush_beats     (flush_beats),
    .dd_rd_re        (dd_rd_re),
    .dd_rd_addr      (dd_rd_addr),
    .dd_rd_len       (dd_rd_len),
    .dd_rd_ready     (dd_rd_ready),
    .dd_rd_data      (dd_rd_data),
    .dd_rd_valid     (dd_rd_valid),
    .dd_rd_last      (dd_rd_last),
    .dd_rd_rready    (dd_rd_rready),
    .dd_wr_re        (dd_wr_re),
    .dd_wr_addr      (dd_wr_addr),
    .dd_wr_len       (dd_wr_len),
    .dd_wr_ready     (dd_wr_ready),
    .dd_wr_data      (dd_wr_data),
    .dd_wr_valid     (dd_wr_valid),
    .dd_wr_rready    (dd_wr_rready),
    .dd_wr_done      (dd_wr_done),
    .a_sel           (a_sel),
    .a_re            (a_re),
    .a_addr          (a_addr),
    .a_rdata         (a_rdata),
    .b_sel           (b_sel),
    .b_we            (b_we),
    .b_addr          (b_addr),
    .b_wdata         (b_wdata),
    .b_wstrb         (b_wstrb)
  );

  beh_ddr3 #(
    .MEM_BYTES (2*1024*1024),
    .READ_LAT  (40),
    .BEAT_GAP  (4)
  ) u_ddr (
    .clk          (clk),
    .rst          (rst),
    .ddr_rd_re    (dd_rd_re),
    .ddr_rd_addr  (dd_rd_addr),
    .ddr_rd_len   (dd_rd_len),
    .ddr_rd_ready (dd_rd_ready),
    .ddr_rd_data  (dd_rd_data),
    .ddr_rd_valid (dd_rd_valid),
    .ddr_rd_last  (dd_rd_last),
    .ddr_rd_rready(dd_rd_rready),
    .ddr_wr_re    (dd_wr_re),
    .ddr_wr_addr  (dd_wr_addr),
    .ddr_wr_len   (dd_wr_len),
    .ddr_wr_ready (dd_wr_ready),
    .ddr_wr_data  (dd_wr_data),
    .ddr_wr_valid (dd_wr_valid),
    .ddr_wr_rready(dd_wr_rready),
    .ddr_wr_done  (dd_wr_done),
    .ddr_busy     (),
    .ddr_err      ()
  );

  // ==========================================================================
  // slow instance : case_d (BEAT_GAP=16 -> 64 B per 16 cycles)
  // ==========================================================================
  logic [31:0] s_in_base;
  logic [15:0] s_in_rows, s_in_row_bytes, s_in_stride, s_in_pad_top, s_in_rd_rows;
  logic [7:0]  s_zp_in;
  logic        s_add_mode;
  logic [31:0] s_aux_base;
  logic [15:0] s_aux_stride, s_aux_pad_top, s_aux_rd_rows;
  logic [31:0] s_out_base;
  logic [15:0] s_out_rows, s_out_row_bytes, s_out_stride;
  logic        s_band_start, s_band_ready, s_engine_done, s_band_done, s_busy;
  logic [7:0]  s_err_code;
  logic [31:0] s_fill_beats, s_flush_beats;
  logic        s_dd_rd_re;
  logic [31:0] s_dd_rd_addr;
  logic [15:0] s_dd_rd_len;
  logic        s_dd_rd_ready;
  logic [127:0] s_dd_rd_data;
  logic        s_dd_rd_valid, s_dd_rd_last, s_dd_rd_rready;
  logic        s_dd_wr_re;
  logic [31:0] s_dd_wr_addr;
  logic [15:0] s_dd_wr_len;
  logic        s_dd_wr_ready;
  logic [127:0] s_dd_wr_data;
  logic        s_dd_wr_valid, s_dd_wr_rready, s_dd_wr_done;

  // bottlecap config per Lead 2026-11-04: IBUF 2x40KiB, OBUF 2x12KiB.
  // 112x112x96 dwconv B=1 band needs 32,832 B > 32KiB, hence 40KiB.
  nn_tilecache #(.IB_BYTES(40*1024), .OB_BYTES(12*1024)) u_tc_s (
    .clk             (clk),
    .rst             (rst),
    .d_in_base       (s_in_base),
    .d_in_rows       (s_in_rows),
    .d_in_row_bytes  (s_in_row_bytes),
    .d_in_stride     (s_in_stride),
    .d_in_pad_top    (s_in_pad_top),
    .d_in_rd_rows    (s_in_rd_rows),
    .d_zp_in         (s_zp_in),
    .d_add_mode      (s_add_mode),
    .d_aux_base      (s_aux_base),
    .d_aux_stride    (s_aux_stride),
    .d_aux_pad_top   (s_aux_pad_top),
    .d_aux_rd_rows   (s_aux_rd_rows),
    .d_out_base      (s_out_base),
    .d_out_rows      (s_out_rows),
    .d_out_row_bytes (s_out_row_bytes),
    .d_out_stride    (s_out_stride),
    .d_a_src_base    (24'd0),
    .d_a_aux_base    (24'd0),
    .d_b_base        (24'd0),
    .d_in_word_off   (17'd0),
    .d_out_word_off  (17'd0),
    .band_start      (s_band_start),
    .band_ready      (s_band_ready),
    .engine_done     (s_engine_done),
    .band_done       (s_band_done),
    .busy            (s_busy),
    .err_code        (s_err_code),
    .cur_bank        (),
    .fill_beats      (s_fill_beats),
    .flush_beats     (s_flush_beats),
    .dd_rd_re        (s_dd_rd_re),
    .dd_rd_addr      (s_dd_rd_addr),
    .dd_rd_len       (s_dd_rd_len),
    .dd_rd_ready     (s_dd_rd_ready),
    .dd_rd_data      (s_dd_rd_data),
    .dd_rd_valid     (s_dd_rd_valid),
    .dd_rd_last      (s_dd_rd_last),
    .dd_rd_rready    (s_dd_rd_rready),
    .dd_wr_re        (s_dd_wr_re),
    .dd_wr_addr      (s_dd_wr_addr),
    .dd_wr_len       (s_dd_wr_len),
    .dd_wr_ready     (s_dd_wr_ready),
    .dd_wr_data      (s_dd_wr_data),
    .dd_wr_valid     (s_dd_wr_valid),
    .dd_wr_rready    (s_dd_wr_rready),
    .dd_wr_done      (s_dd_wr_done),
    .a_sel           (2'd0),
    .a_re            (1'b0),
    .a_addr          (24'd0),
    .a_rdata         (),
    .b_sel           (2'd0),
    .b_we            (1'b0),
    .b_addr          (24'd0),
    .b_wdata         (128'd0),
    .b_wstrb         (16'd0)
  );

  beh_ddr3 #(
    .MEM_BYTES (2*1024*1024),
    .READ_LAT  (40),
    .BEAT_GAP  (16)
  ) u_ddr_s (
    .clk          (clk),
    .rst          (rst),
    .ddr_rd_re    (s_dd_rd_re),
    .ddr_rd_addr  (s_dd_rd_addr),
    .ddr_rd_len   (s_dd_rd_len),
    .ddr_rd_ready (s_dd_rd_ready),
    .ddr_rd_data  (s_dd_rd_data),
    .ddr_rd_valid (s_dd_rd_valid),
    .ddr_rd_last  (s_dd_rd_last),
    .ddr_rd_rready(s_dd_rd_rready),
    .ddr_wr_re    (s_dd_wr_re),
    .ddr_wr_addr  (s_dd_wr_addr),
    .ddr_wr_len   (s_dd_wr_len),
    .ddr_wr_ready (s_dd_wr_ready),
    .ddr_wr_data  (s_dd_wr_data),
    .ddr_wr_valid (s_dd_wr_valid),
    .ddr_wr_rready(s_dd_wr_rready),
    .ddr_wr_done  (s_dd_wr_done),
    .ddr_busy     (),
    .ddr_err      ()
  );

  // ==========================================================================
  // TB state
  // ==========================================================================
  logic [7:0]  img    [0:BUF_BYTES-1];   // input tensor(s), row-major NHWC
  logic [7:0]  gold   [0:BUF_BYTES-1];   // whole-tensor golden output
  logic [7:0]  dstb   [0:BUF_BYTES-1];   // ADD dst tensor
  logic [7:0]  rb     [0:2][0:1023];     // fake-engine row buffers (K rows)
  logic        rb_valid [0:2];

  int          G_IH, G_IW, G_IC, G_OC, G_K, G_ST, G_PAD, G_OH, G_OW;
  int          G_row_bytes, G_out_row_bytes;
  int unsigned G_in_base, G_out_base;
  int          G_zp;

  int          errors;
  int          err_shown;
  int          cases_run;
  int          cases_pass;

  // --------------------------------------------------------------------------
  // check helpers
  // --------------------------------------------------------------------------
  task automatic fail(input string ctx);
    errors = errors + 1;
    if (err_shown < 30) begin
      err_shown = err_shown + 1;
      $display("[TILECACHE][FAIL] %s", ctx);
    end
  endtask

  task automatic chk(input logic cond, input string ctx);
    if (!cond) fail(ctx);
  endtask

  task automatic chk_byte(input logic [7:0] got, input logic [7:0] exp,
                          input string ctx, input int unsigned idx);
    if (got !== exp) begin
      errors = errors + 1;
      if (err_shown < 30) begin
        err_shown = err_shown + 1;
        $display("[TILECACHE][FAIL] %s[%0d] got=%02x exp=%02x", ctx, idx, got, exp);
      end
    end
  endtask

  // --------------------------------------------------------------------------
  // backdoor helpers (DDR model memory access, no port traffic)
  // --------------------------------------------------------------------------
  task automatic poke_ddr(input int unsigned byte_addr, input int unsigned nbytes,
                          input int unsigned src_base);
    logic [63:0] wd;
    for (int w = 0; w < (nbytes + 7) / 8; w++) begin
      wd = 64'd0;
      for (int bi = 0; bi < 8; bi++)
        if ((w*8 + bi) < nbytes) wd[bi*8 +: 8] = img[src_base + w*8 + bi];
      u_ddr.poke_word((byte_addr >> 3) + w, wd);
    end
  endtask

  task automatic poke_ddr_s(input int unsigned byte_addr, input int unsigned nbytes,
                            input int unsigned src_base);
    logic [63:0] wd;
    for (int w = 0; w < (nbytes + 7) / 8; w++) begin
      wd = 64'd0;
      for (int bi = 0; bi < 8; bi++)
        if ((w*8 + bi) < nbytes) wd[bi*8 +: 8] = img[src_base + w*8 + bi];
      u_ddr_s.poke_word((byte_addr >> 3) + w, wd);
    end
  endtask

  // compare a flushed DDR region against the golden array
  task automatic cmp_ddr_gold(input int unsigned ddr_addr,
                              input int unsigned gold_idx,
                              input int unsigned nbytes,
                              input string ctx);
    logic [63:0] wd;
    for (int w = 0; w < nbytes / 8; w++) begin
      wd = u_ddr.peek_word((ddr_addr >> 3) + w);
      for (int bi = 0; bi < 8; bi++)
        chk_byte(wd[bi*8 +: 8], gold[gold_idx + w*8 + bi], ctx,
                 gold_idx + w*8 + bi);
    end
  endtask

  // --------------------------------------------------------------------------
  // fake-engine port drivers (nn_mem a_*/b_* semantics)
  // --------------------------------------------------------------------------
  initial begin
    a_sel = 2'd0; a_re = 1'b0; a_addr = 24'd0;
    b_sel = 2'd0; b_we = 1'b0; b_addr = 24'd0; b_wdata = 128'd0; b_wstrb = 16'd0;
    band_start = 1'b0; engine_done = 1'b0;
    s_band_start = 1'b0; s_engine_done = 1'b0;
    d_add_mode = 1'b0; s_add_mode = 1'b0;
    d_zp_in = 8'h00; s_zp_in = 8'h00;
  end

  // nn_mem a_* timing: address at cycle N -> a_rdata at N+1
  task automatic rd_beat(input logic sel, input logic [23:0] addr,
                         output logic [127:0] data);
    @(negedge clk);
    a_sel = {1'b0, sel};
    a_addr = addr;
    a_re   = 1'b1;
    @(posedge clk);
    @(posedge clk);
    @(negedge clk);
    data = a_rdata;
    a_re = 1'b0;
  endtask

  task automatic wr_beat(input logic [23:0] addr, input logic [127:0] data,
                         input logic [15:0] strb);
    @(negedge clk);
    b_sel  = 2'd0;
    b_addr = addr;
    b_wdata = data;
    b_wstrb = strb;
    b_we    = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b_we = 1'b0;
  endtask

  // --------------------------------------------------------------------------
  // fake engine: 3x3 conv over one band (tile-relative addressing)
  //   band-local input row iy = oy*ST - PAD + ky ; OOB -> zp_in
  //   horizontal: ix = ox*ST - PAD + kx ; OOB -> zp_in
  //   arithmetic: weighted sum (w = ky*K+kx+1), >>5, int8 clamp
  // --------------------------------------------------------------------------
  task automatic fake_conv_band(input int out_row0, input int nrows,
                                input int band_in_row0, input int band_in_rows);
    for (int oy = 0; oy < nrows; oy++) begin
      // read the K input rows needed by this output row
      for (int ky = 0; ky < G_K; ky++) begin
        int iy_abs, iy;
        iy_abs = (out_row0 + oy)*G_ST - G_PAD + ky;   // absolute input row
        iy     = iy_abs - band_in_row0;               // buffer row index
        rb_valid[ky] = (iy_abs >= 0) && (iy_abs < G_IH) &&
                       (iy >= 0) && (iy < band_in_rows);
        if (rb_valid[ky]) begin
          for (int b = 0; b < G_row_bytes/16; b++) begin
            logic [127:0] wd;
            rd_beat(1'b0, 24'((iy*G_row_bytes) + b*16), wd);
            for (int bi = 0; bi < 16; bi++) rb[ky][b*16 + bi] = wd[bi*8 +: 8];
          end
        end
      end
      // compute + write the output row (out_row_bytes/16 beats)
      for (int b = 0; b < G_out_row_bytes/16; b++) begin
        logic [127:0] pack;
        pack = 128'd0;
        for (int bi = 0; bi < 16; bi++) begin
          int pix;
          int chn;
          pix = (b*16 + bi) / G_OC;
          chn = (b*16 + bi) % G_OC;
          pack[bi*8 +: 8] = conv_px(oy, pix, chn);
        end
        wr_beat(24'((oy*G_out_row_bytes) + b*16), pack, 16'hFFFF);
      end
    end
  endtask

  // conv value for one output pixel/channel from the fake-engine row buffers
  function automatic logic [7:0] conv_px(input int oy, input int ox, input int chn);
    longint acc;
    acc = 0;
    for (int ky = 0; ky < G_K; ky++) begin
      for (int kx = 0; kx < G_K; kx++) begin
        int ix, val;
        ix = ox*G_ST - G_PAD + kx;
        if (!rb_valid[ky] || (ix < 0) || (ix >= G_IW)) val = G_zp;
        else val = int'($signed(rb[ky][ix*G_IC + chn]));
        acc = acc + val * (ky*G_K + kx + 1);
      end
    end
    acc = acc >> 5;
    if (acc > 127) acc = 127;
    if (acc < -128) acc = -128;
    conv_px = acc[7:0];
  endfunction

  // whole-tensor golden for the same convolution
  function automatic logic [7:0] conv_gold_px(input int y, input int x, input int chn);
    longint acc;
    int iy, ix, val;
    acc = 0;
    for (int ky = 0; ky < G_K; ky++) begin
      for (int kx = 0; kx < G_K; kx++) begin
        iy = y*G_ST - G_PAD + ky;
        ix = x*G_ST - G_PAD + kx;
        if ((iy < 0) || (iy >= G_IH) || (ix < 0) || (ix >= G_IW)) val = G_zp;
        else val = int'($signed(img[iy*G_IW*G_IC + ix*G_IC + chn]));
        acc = acc + val * (ky*G_K + kx + 1);
      end
    end
    acc = acc >> 5;
    if (acc > 127) acc = 127;
    if (acc < -128) acc = -128;
    conv_gold_px = acc[7:0];
  endfunction

  task automatic golden_conv_all();
    for (int y = 0; y < G_OH; y++)
      for (int x = 0; x < G_OW; x++)
        for (int c = 0; c < G_OC; c++)
          gold[(y*G_OW + x)*G_OC + c] = conv_gold_px(y, x, c);
  endtask

  task automatic golden_add_all();
    longint acc;
    for (int i = 0; i < G_IH*G_IW*G_IC; i++) begin
      acc = int'($signed(img[i])) + int'($signed(dstb[i]));
      if (acc > 127) acc = 127;
      if (acc < -128) acc = -128;
      gold[i] = acc[7:0];
    end
  endtask

  // --------------------------------------------------------------------------
  // band orchestration (main instance)
  // --------------------------------------------------------------------------
  task automatic set_band_conv(input int out_row0, input int nrows,
                               output int in_rows, output int band_in_row0);
    int abs_start, abs_end, rd_start, rd_stop, rd_rows, pad_top;
    band_in_row0 = out_row0*G_ST - G_PAD;   // absolute input row of buffer row 0
    in_rows      = (nrows - 1)*G_ST + G_K;
    abs_start    = band_in_row0;
    abs_end      = band_in_row0 + in_rows;
    rd_start     = (abs_start < 0) ? 0 : abs_start;
    rd_stop      = (abs_end > G_IH) ? G_IH : abs_end;
    rd_rows      = rd_stop - rd_start;
    pad_top      = rd_start - abs_start;
    d_in_base      = G_in_base + rd_start*G_row_bytes;
    d_in_rows      = in_rows[15:0];
    d_in_row_bytes = G_row_bytes[15:0];
    d_in_stride    = G_row_bytes[15:0];
    d_in_pad_top   = pad_top[15:0];
    d_in_rd_rows   = rd_rows[15:0];
    d_zp_in        = G_zp[7:0];
    d_add_mode     = 1'b0;
    d_aux_base     = 32'd0;
    d_aux_stride   = G_row_bytes[15:0];
    d_aux_pad_top  = 16'd0;
    d_aux_rd_rows  = 16'd0;
    d_out_base     = G_out_base + out_row0*G_out_row_bytes;
    d_out_rows     = nrows[15:0];
    d_out_row_bytes= G_out_row_bytes[15:0];
    d_out_stride   = G_out_row_bytes[15:0];
  endtask

  task automatic band_start_wait(output logic ok);
    int n;
    @(negedge clk);
    band_start = 1'b1;
    @(posedge clk);
    @(negedge clk);
    band_start = 1'b0;
    n = 0;
    while (!band_ready && (n < 500000)) begin
      @(posedge clk);
      n = n + 1;
    end
    ok = band_ready;
    if (!ok) fail("band_ready timeout (fill deadlock?)");
  endtask

  task automatic engine_done_wait(output logic ok);
    int n;
    @(negedge clk);
    engine_done = 1'b1;
    @(posedge clk);
    @(negedge clk);
    engine_done = 1'b0;
    n = 0;
    while (!band_done && (n < 500000)) begin
      @(posedge clk);
      n = n + 1;
    end
    ok = band_done;
    if (!ok) fail("band_done timeout (flush deadlock?)");
    @(posedge clk);
  endtask

  task automatic run_band_conv(input int out_row0, input int nrows);
    int in_rows, band_in_row0;
    logic ok1, ok2;
    set_band_conv(out_row0, nrows, in_rows, band_in_row0);
    band_start_wait(ok1);
    chk(ok1, "run_band_conv fill");
    chk(err_code == 8'h00, "run_band_conv err_code");
    fake_conv_band(out_row0, nrows, band_in_row0, in_rows);
    engine_done_wait(ok2);
    chk(ok2, "run_band_conv flush");
    chk(err_code == 8'h00, "run_band_conv err_code after flush");
    cmp_ddr_gold(d_out_base, out_row0*G_out_row_bytes,
                 nrows*G_out_row_bytes, "case_band_out");
  endtask

  // --------------------------------------------------------------------------
  // ADD band: fill src (bank0) + dst (bank1), fake engine reads both
  // --------------------------------------------------------------------------
  task automatic run_band_add(input int out_row0, input int nrows);
    logic ok1, ok2;
    int n;
    // src descriptor
    d_in_base      = G_in_base + out_row0*G_row_bytes;
    d_in_rows      = nrows[15:0];
    d_in_row_bytes = G_row_bytes[15:0];
    d_in_stride    = G_row_bytes[15:0];
    d_in_pad_top   = 16'd0;
    d_in_rd_rows   = nrows[15:0];
    d_zp_in        = G_zp[7:0];
    d_add_mode     = 1'b1;
    d_aux_base     = 32'h0006_0000 + out_row0*G_row_bytes;   // dst tensor DDR base
    d_aux_stride   = G_row_bytes[15:0];
    d_aux_pad_top  = 16'd0;
    d_aux_rd_rows  = nrows[15:0];
    d_out_base     = G_out_base + out_row0*G_out_row_bytes;
    d_out_rows     = nrows[15:0];
    d_out_row_bytes= G_out_row_bytes[15:0];
    d_out_stride   = G_out_row_bytes[15:0];
    band_start_wait(ok1);
    chk(ok1, "run_band_add fill");
    chk(err_code == 8'h00, "run_band_add err_code");
    // fake ADD engine: read src from bank0 and dst from bank1, clamp-add
    for (int oy = 0; oy < nrows; oy++) begin
      for (int b = 0; b < G_row_bytes/16; b++) begin
        logic [127:0] sdata, ddata, pack;
        rd_beat(1'b0, 24'((oy*G_row_bytes) + b*16), sdata);
        rd_beat(1'b1, 24'((oy*G_row_bytes) + b*16), ddata);
        pack = 128'd0;
        for (int bi = 0; bi < 16; bi++) begin
          longint acc;
          acc = int'($signed(sdata[bi*8 +: 8])) + int'($signed(ddata[bi*8 +: 8]));
          if (acc > 127) acc = 127;
          if (acc < -128) acc = -128;
          pack[bi*8 +: 8] = acc[7:0];
        end
        wr_beat(24'((oy*G_out_row_bytes) + b*16), pack, 16'hFFFF);
      end
    end
    engine_done_wait(ok2);
    chk(ok2, "run_band_add flush");
    chk(err_code == 8'h00, "run_band_add err_code after flush");
    cmp_ddr_gold(d_out_base, out_row0*G_out_row_bytes,
                 nrows*G_out_row_bytes, "case_add_out");
  endtask

  // --------------------------------------------------------------------------
  // random tensor generator (deterministic LCG)
  // --------------------------------------------------------------------------
  task automatic gen_img(input int unsigned n, input int unsigned seed0);
    int unsigned s;
    s = seed0;
    for (int i = 0; i < n; i++) begin
      s = s * 32'd1664525 + 32'd1013904223;
      img[i] = s[7:0];
    end
  endtask

  task automatic gen_dst(input int unsigned n, input int unsigned seed0);
    int unsigned s;
    s = seed0;
    for (int i = 0; i < n; i++) begin
      s = s * 32'd1664525 + 32'd1013904223;
      dstb[i] = s[7:0];
    end
  endtask

  // ==========================================================================
  // case_a : 96x96x8 3x3/s1/pad1 conv, 6 bands of 16 output rows
  // ==========================================================================
  task automatic case_a();
    int err0;
    int unsigned cyc0;
    err0 = errors;
    cyc0 = 0;
    $display("\n[TILECACHE] ---- case_a: 96x96x8 conv3x3/s1/pad1, 6 bands ----");
    G_IH = 96; G_IW = 96; G_IC = 8; G_OC = 8;
    G_K = 3; G_ST = 1; G_PAD = 1;
    G_OH = 96; G_OW = 96;
    G_row_bytes = G_IW*G_IC; G_out_row_bytes = G_OW*G_OC;
    G_in_base = 32'h0000_0000; G_out_base = 32'h0002_0000;   // DDR arena offsets
    G_zp = -7;
    gen_img( G_IH*G_IW*G_IC, 32'hA5A5_0001);
    poke_ddr(G_in_base, G_IH*G_IW*G_IC, 0);
    golden_conv_all();
    for (int b = 0; b < 6; b++) run_band_conv(b*16, 16);
    if (errors == err0) $display("[TILECACHE] case_a: PASS");
    else                $display("[TILECACHE] case_a: FAIL (%0d new errs)", errors - err0);
    cases_run = cases_run + 1;
    if (errors == err0) cases_pass = cases_pass + 1;
  endtask

  // ==========================================================================
  // case_b : 3x3/s2/pad1 (96x96x8 -> 48x48x8), 6 bands of 8 rows (halo parity)
  // ==========================================================================
  task automatic case_b();
    int err0;
    err0 = errors;
    $display("\n[TILECACHE] ---- case_b: 96x96x8 conv3x3/s2/pad1 -> 48x48, 6 bands ----");
    G_IH = 96; G_IW = 96; G_IC = 8; G_OC = 8;
    G_K = 3; G_ST = 2; G_PAD = 1;
    G_OH = 48; G_OW = 48;
    G_row_bytes = G_IW*G_IC; G_out_row_bytes = G_OW*G_OC;   // 768 / 384
    G_in_base = 32'h0004_0000; G_out_base = 32'h0006_0000;
    G_zp = 5;
    gen_img( G_IH*G_IW*G_IC, 32'hB0B0_0002);
    poke_ddr(G_in_base, G_IH*G_IW*G_IC, 0);
    golden_conv_all();
    for (int b = 0; b < 6; b++) run_band_conv(b*8, 8);
    if (errors == err0) $display("[TILECACHE] case_b: PASS");
    else                $display("[TILECACHE] case_b: FAIL (%0d new errs)", errors - err0);
    cases_run = cases_run + 1;
    if (errors == err0) cases_pass = cases_pass + 1;
  endtask

  // ==========================================================================
  // case_c : 8x8x8 conv3x3/s1/pad1, single band -> all four pad edges
  // ==========================================================================
  task automatic case_c();
    int err0;
    err0 = errors;
    $display("\n[TILECACHE] ---- case_c: 8x8x8 conv3x3/s1/pad1, 1 band, pad edges ----");
    G_IH = 8; G_IW = 8; G_IC = 8; G_OC = 8;
    G_K = 3; G_ST = 1; G_PAD = 1;
    G_OH = 8; G_OW = 8;
    G_row_bytes = G_IW*G_IC;    // 64
    G_out_row_bytes = G_OW*G_OC; // 64
    G_in_base = 32'h0008_0000; G_out_base = 32'h0008_4000;
    G_zp = -128;   // extreme zero point: every compared byte must use it
    gen_img( G_IH*G_IW*G_IC, 32'hC0C0_0003);
    poke_ddr(G_in_base, G_IH*G_IW*G_IC, 0);
    golden_conv_all();
    run_band_conv(0, 8);
    if (errors == err0) $display("[TILECACHE] case_c: PASS");
    else                $display("[TILECACHE] case_c: FAIL (%0d new errs)", errors - err0);
    cases_run = cases_run + 1;
    if (errors == err0) cases_pass = cases_pass + 1;
  endtask

  // ==========================================================================
  // case_e : ADD op, src band in IBUF bank0 + dst band in bank1 (2R1W fix)
  // ==========================================================================
  task automatic case_e();
    int err0;
    err0 = errors;
    $display("\n[TILECACHE] ---- case_e: ADD src+dst bands (a_sel=0/1), 16x16x8 ----");
    G_IH = 16; G_IW = 16; G_IC = 8; G_OC = 8;
    G_K = 1; G_ST = 1; G_PAD = 0;
    G_OH = 16; G_OW = 16;
    G_row_bytes = G_IW*G_IC;     // 128
    G_out_row_bytes = G_OW*G_OC; // 128
    G_in_base = 32'h000A_0000; G_out_base = 32'h000C_0000;
    G_zp = 0;
    gen_img( G_IH*G_IW*G_IC, 32'hE0E0_0004);
    gen_dst( G_IH*G_IW*G_IC, 32'hE0E0_0005);
    poke_ddr(G_in_base, G_IH*G_IW*G_IC, 0);
    // dst tensor is written at a separate DDR base (0x60000) from src
    for (int w = 0; w < (G_IH*G_IW*G_IC + 7) / 8; w++) begin
      logic [63:0] wd;
      wd = 64'd0;
      for (int bi = 0; bi < 8; bi++)
        if ((w*8 + bi) < G_IH*G_IW*G_IC) wd[bi*8 +: 8] = dstb[w*8 + bi];
      u_ddr.poke_word((32'h0006_0000 >> 3) + w, wd);
    end
    golden_add_all();
    for (int b = 0; b < 2; b++) run_band_add(b*8, 8);
    if (errors == err0) $display("[TILECACHE] case_e: PASS");
    else                $display("[TILECACHE] case_e: FAIL (%0d new errs)", errors - err0);
    cases_run = cases_run + 1;
    if (errors == err0) cases_pass = cases_pass + 1;
  endtask

  // ==========================================================================
  // case_d : slow fill/flush (BEAT_GAP=16) -- no deadlock, counters correct
  // ==========================================================================
  task automatic case_d();
    int err0, n, cycles;
    logic ok;
    err0 = errors;
    $display("\n[TILECACHE] ---- case_d: slow DDR (BEAT_GAP=16), 8x8x8 conv band ----");
    G_IH = 8; G_IW = 8; G_IC = 8; G_OC = 8;
    G_K = 3; G_ST = 1; G_PAD = 1;
    G_OH = 8; G_OW = 8;
    G_row_bytes = G_IW*G_IC;
    G_out_row_bytes = G_OW*G_OC;
    G_zp = -3;
    gen_img( G_IH*G_IW*G_IC, 32'hD0D0_0006);
    poke_ddr_s(32'h0000_0000, G_IH*G_IW*G_IC, 0);
    // 1 band: in_rows = 10, out_rows = 8
    s_in_base      = 32'h0000_0000 + 0;         // read rows start at DDR row 0
    s_in_rows      = 16'd10;
    s_in_row_bytes = 16'(G_row_bytes);
    s_in_stride    = 16'(G_row_bytes);
    s_in_pad_top   = 16'd1;
    s_in_rd_rows   = 16'd8;
    s_zp_in        = G_zp[7:0];
    s_add_mode     = 1'b0;
    s_aux_base     = 32'd0;
    s_aux_stride   = 16'(G_row_bytes);
    s_aux_pad_top  = 16'd0;
    s_aux_rd_rows  = 16'd0;
    s_out_base     = 32'h0001_0000;
    s_out_rows     = 16'd8;
    s_out_row_bytes= 16'(G_out_row_bytes);
    s_out_stride   = 16'(G_out_row_bytes);
    @(negedge clk);
    s_band_start = 1'b1;
    @(posedge clk);
    @(negedge clk);
    s_band_start = 1'b0;
    n = 0;
    while (!s_band_ready && (n < 500000)) begin
      @(posedge clk);
      n = n + 1;
    end
    chk(s_band_ready, "case_d slow fill band_ready timeout");
    cycles = n;
    $display("[TILECACHE] case_d: slow fill took %0d cycles (BEAT_GAP=16)", cycles);
    chk(s_err_code == 8'h00, "case_d slow err_code after fill");
    chk(s_fill_beats == 32'd40, "case_d slow fill beats (10 rows x 4)");
    // finish: no engine data needed, just complete the handshake
    @(negedge clk);
    s_engine_done = 1'b1;
    @(posedge clk);
    @(negedge clk);
    s_engine_done = 1'b0;
    n = 0;
    while (!s_band_done && (n < 500000)) begin
      @(posedge clk);
      n = n + 1;
    end
    chk(s_band_done, "case_d slow flush band_done timeout");
    $display("[TILECACHE] case_d: slow flush took %0d cycles (BEAT_GAP=16)", n);
    chk(s_err_code == 8'h00, "case_d slow err_code after flush");
    chk(s_flush_beats == 32'd32, "case_d slow flush beats (8 rows x 4)");
    chk(!s_busy, "case_d slow busy deasserted");
    if (errors == err0) $display("[TILECACHE] case_d: PASS");
    else                $display("[TILECACHE] case_d: FAIL (%0d new errs)", errors - err0);
    cases_run = cases_run + 1;
    if (errors == err0) cases_pass = cases_pass + 1;
  endtask

  // ==========================================================================
  // case_f : B=1 bands (single output row per band) on the 16KiB instance
  // ==========================================================================
  task automatic case_f();
    int err0;
    err0 = errors;
    $display("\n[TILECACHE] ---- case_f: B=1 bands (8x8x8 conv3x3/s1/pad1) ----");
    G_IH = 8; G_IW = 8; G_IC = 8; G_OC = 8;
    G_K = 3; G_ST = 1; G_PAD = 1;
    G_OH = 8; G_OW = 8;
    G_row_bytes = G_IW*G_IC;      // 64
    G_out_row_bytes = G_OW*G_OC;  // 64
    G_in_base = 32'h000D_0000; G_out_base = 32'h000D_4000;
    G_zp = -5;
    gen_img(G_IH*G_IW*G_IC, 32'hF0F0_0007);
    poke_ddr(G_in_base, G_IH*G_IW*G_IC, 0);
    golden_conv_all();
    for (int b = 0; b < 8; b++) run_band_conv(b, 1);
    if (errors == err0) $display("[TILECACHE] case_f: PASS");
    else                $display("[TILECACHE] case_f: FAIL (%0d new errs)", errors - err0);
    cases_run = cases_run + 1;
    if (errors == err0) cases_pass = cases_pass + 1;
  endtask

  // ==========================================================================
  // case_g : 32KiB IBUF config, bottlecap big-channel dwconv B=1 band capacity
  //   geometry 112x112x96, k=3,s=1,pad=1: in_row_bytes=10,752; B=1 -> in_rows=3
  //   -> 32,256 B (fits 32 KiB IBUF, exceeds the 16 KiB one).
  // ==========================================================================
  task automatic case_g();
    int err0, n;
    int in_row_bytes, out_row_bytes;
    logic ok;
    err0 = errors;
    $display("\n[TILECACHE] ---- case_g: 32KiB IBUF config, 112x112x96 B=1 band ----");
    in_row_bytes  = 112*96;      // 10,752
    out_row_bytes = 112*96;      // 10,752
    // input data for the 3 band rows (absolute rows 54..56) placed at DDR 0
    gen_img(3*in_row_bytes, 32'hA1B2_0008);
    poke_ddr_s(32'h0000_0000, 3*in_row_bytes, 0);
    s_in_base      = 32'h0000_0000;               // row 54 of the tensor -> DDR 0
    s_in_rows      = 16'd3;
    s_in_row_bytes = 16'(in_row_bytes);
    s_in_stride    = 16'(in_row_bytes);
    s_in_pad_top   = 16'd0;
    s_in_rd_rows   = 16'd3;
    s_zp_in        = 8'h00;
    s_add_mode     = 1'b0;
    s_aux_base     = 32'd0;
    s_aux_stride   = 16'(in_row_bytes);
    s_aux_pad_top  = 16'd0;
    s_aux_rd_rows  = 16'd0;
    s_out_base     = 32'h000E_0000;
    s_out_rows     = 16'd1;
    s_out_row_bytes= 16'(out_row_bytes);
    s_out_stride   = 16'(out_row_bytes);
    @(negedge clk);
    s_band_start = 1'b1;
    @(posedge clk);
    @(negedge clk);
    s_band_start = 1'b0;
    n = 0;
    while (!s_band_ready && n < 2_000_000) begin
      @(posedge clk);
      n = n + 1;
    end
    chk(s_band_ready, "case_g 32KiB fill timeout");
    chk(s_err_code == 8'h00, "case_g 32KiB err_code after fill");
    chk(s_fill_beats == 32'd2016, "case_g 32KiB fill beats (3 rows x 672)");
    @(negedge clk);
    s_engine_done = 1'b1;
    @(posedge clk);
    @(negedge clk);
    s_engine_done = 1'b0;
    n = 0;
    while (!s_band_done && n < 2_000_000) begin
      @(posedge clk);
      n = n + 1;
    end
    chk(s_band_done, "case_g 32KiB flush timeout");
    chk(s_flush_beats == 32'd672, "case_g 32KiB flush beats (1 row x 672)");
    chk(!s_busy, "case_g 32KiB busy deasserted");
    if (errors == err0) $display("[TILECACHE] case_g: PASS");
    else                $display("[TILECACHE] case_g: FAIL (%0d new errs)", errors - err0);
    cases_run = cases_run + 1;
    if (errors == err0) cases_pass = cases_pass + 1;
  endtask

  // ==========================================================================
  // main
  // ==========================================================================
  initial begin : main
    wait (!rst);
    repeat (10) @(posedge clk);
    errors = 0;
    err_shown = 0;
    cases_run = 0;
    cases_pass = 0;
    $display("================================================================");
    $display("[TILECACHE] tb_nn_tilecache start (clk=100MHz)");
    $display("================================================================");
    case_a();
    case_b();
    case_c();
    case_e();
    case_d();
    case_f();
    case_g();
    $display("\n================================================================");
    $display("[TILECACHE] SUMMARY: %0d/%0d cases pass, errors=%0d",
             cases_pass, cases_run, errors);
    $display("================================================================");
    if (errors == 0) $display("TILECACHE_TB: PASS");
    else             $display("TILECACHE_TB: FAIL (%0d errors)", errors);
    $finish;
  end

endmodule
