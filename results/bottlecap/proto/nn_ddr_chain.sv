`timescale 1ns/1ps

// ============================================================================
// nn_ddr_chain.sv -- M6b wiring wrapper: DDR3 -> weight prefetch + activation
//                    tile cache -> REAL nn_mem + REAL nn_conv_engine
// ----------------------------------------------------------------------------
// Owner: rtl-stream (task-15 / M6b).  Test-only wrapper (lives under
// results/bottlecap/proto/, not part of the synthesizable SoC hierarchy).
//
// Data flow
//   beh_ddr3 (weight/Q stream image + activation arena)
//     |-- read channel, owner-muxed between:
//     |     . nn_wload  : whole-layer W/Q prefetch -> nn_mem wfill/qfill
//     |     . nn_tilecache : activation band fill -> IBUF
//     '-- write channel: nn_tilecache band flush (OBUF -> DDR3)
//   nn_conv_engine:
//     w_re/w_addr/w_rdata, q_re/q_addr/q_rdata  <-> nn_mem (w_mode=1)
//     a_sel/a_re/a_addr/a_rdata                 <-> nn_tilecache (IBUF banks)
//     b_sel/b_we/b_addr/b_wdata/b_wstrb         <-> nn_tilecache (OBUF bank)
//   nn_mem: W dual bank (layer-relative, bank 0/1 selected by w_bank_sel),
//           Q shadow bank (q_bank_sel); fill ports come from nn_wload.
//
// The TB plays nn_seq: it drives pre_* (weight prefetch), the band descriptor
// (d_*), band_start, and the engine descriptor/start; it waits on pre_done,
// band_ready/band_done and eng_done.  ddr_rd_owner must be 0 while nn_wload is
// active and 1 while nn_tilecache is active (they never overlap in this TB).
//
// M6b v1 scope: one band = one whole activation tensor (loose TB buffers
// IB/OB = 2 MiB), so the engine descriptor is the plan op descriptor with
// src=dst=0, woff=qoff=0 (tile-relative).  Banded 56 KiB runs are the next step
// (M6B-DDR-CHAIN.md section on band sizing).
// ============================================================================

module nn_ddr_chain #(
  parameter int unsigned MEM_BYTES = 8*1024*1024,
  parameter int unsigned READ_LAT  = 40,
  parameter int unsigned BEAT_GAP  = 1,           // 1 = full-rate (no starvation)
  parameter int unsigned IB_BYTES  = 2*1024*1024, // loose TB config
  parameter int unsigned OB_BYTES  = 2*1024*1024
)(
  input  logic clk,
  input  logic rst,
  // ---- weight/Q prefetch control (nn_seq -> nn_wload) ---------------------
  input  logic         pre_start,
  input  logic [31:0]  pre_src_addr,
  input  logic [17:0]  pre_wlen,
  input  logic [31:0]  pre_qsrc_addr,
  input  logic [12:0]  pre_qlen,
  input  logic         pre_bank,
  output logic         pre_busy,
  output logic         pre_done,
  output logic         pre_err,
  // ---- nn_mem stream mode / active banks (nn_seq) -------------------------
  input  logic         w_bank_sel,
  input  logic         q_bank_sel,
  // ---- activation band descriptor (nn_seq -> nn_tilecache) ----------------
  input  logic [31:0]  d_in_base,
  input  logic [15:0]  d_in_rows,
  input  logic [15:0]  d_in_row_bytes,
  input  logic [15:0]  d_in_stride,
  input  logic [15:0]  d_in_pad_top,
  input  logic [15:0]  d_in_rd_rows,
  input  logic [7:0]   d_zp_in,
  input  logic         d_add_mode,
  input  logic [31:0]  d_aux_base,
  input  logic [15:0]  d_aux_stride,
  input  logic [15:0]  d_aux_pad_top,
  input  logic [15:0]  d_aux_rd_rows,
  input  logic [31:0]  d_out_base,
  input  logic [15:0]  d_out_rows,
  input  logic [15:0]  d_out_row_bytes,
  input  logic [15:0]  d_out_stride,
  input  logic [23:0]  d_a_src_base,
  input  logic [23:0]  d_a_aux_base,
  input  logic [23:0]  d_b_base,
  input  logic [16:0]  d_in_word_off,
  input  logic [16:0]  d_out_word_off,
  // ---- band handshake -----------------------------------------------------
  input  logic         band_start,
  output logic         band_ready,
  output logic         band_done,
  output logic         tc_busy,
  output logic [7:0]   tc_err,
  output logic [31:0]  tc_fill_beats,
  output logic [31:0]  tc_flush_beats,
  // ---- engine (nn_seq -> nn_conv_engine) ----------------------------------
  input  nn_pkg::nn_desc_t eng_desc,
  input  logic         eng_start,
  output logic         eng_busy,
  output logic         eng_done,
  output logic [31:0]  eng_cycles,
  output logic [7:0]   eng_err,
  // ---- DDR read channel owner: 0 = nn_wload, 1 = nn_tilecache -------------
  input  logic         ddr_rd_owner,
  // ---- nn_mem mode select + ROM debug load port (M6b ROM control test) ----
  input  logic         w_mode_sel,     // 1 = streaming (default), 0 = ROM
  input  logic         dbg_we,
  input  logic         dbg_space,      // 0 = W ROM, 1 = Q ROM
  input  logic [16:0]  dbg_addr,       // 32-bit word index inside W/Q region
  input  logic [31:0]  dbg_wdata
);
  import nn_pkg::*;

  // ==========================================================================
  // DDR3 model
  // ==========================================================================
  logic         ddr_rd_re;
  logic [31:0]  ddr_rd_addr;
  logic [15:0]  ddr_rd_len;
  logic         ddr_rd_ready;
  logic [127:0] ddr_rd_data;
  logic         ddr_rd_valid;
  logic         ddr_rd_last;
  logic         ddr_rd_rready;

  logic         tc_rd_re;
  logic [31:0]  tc_rd_addr;
  logic [15:0]  tc_rd_len;
  logic         tc_rd_ready;
  logic [127:0] tc_rd_data;
  logic         tc_rd_valid;
  logic         tc_rd_last;
  logic         tc_rd_rready;
  logic         tc_wr_re;
  logic [31:0]  tc_wr_addr;
  logic [15:0]  tc_wr_len;
  logic         tc_wr_ready;
  logic [127:0] tc_wr_data;
  logic         tc_wr_valid;
  logic         tc_wr_rready;
  logic         tc_wr_done;

  logic         wl_rd_re;
  logic [31:0]  wl_rd_addr;
  logic [15:0]  wl_rd_len;
  logic         wl_rd_ready;
  logic [127:0] wl_rd_data;
  logic         wl_rd_valid;
  logic         wl_rd_last;
  logic         wl_rd_rready;

  beh_ddr3 #(
    .MEM_BYTES (MEM_BYTES),
    .READ_LAT  (READ_LAT),
    .BEAT_GAP  (BEAT_GAP)
  ) u_ddr (
    .clk          (clk),
    .rst          (rst),
    .ddr_rd_re    (ddr_rd_re),
    .ddr_rd_addr  (ddr_rd_addr),
    .ddr_rd_len   (ddr_rd_len),
    .ddr_rd_ready (ddr_rd_ready),
    .ddr_rd_data  (ddr_rd_data),
    .ddr_rd_valid (ddr_rd_valid),
    .ddr_rd_last  (ddr_rd_last),
    .ddr_rd_rready(ddr_rd_rready),
    .ddr_wr_re    (tc_wr_re),
    .ddr_wr_addr  (tc_wr_addr),
    .ddr_wr_len   (tc_wr_len),
    .ddr_wr_ready (tc_wr_ready),
    .ddr_wr_data  (tc_wr_data),
    .ddr_wr_valid (tc_wr_valid),
    .ddr_wr_rready(tc_wr_rready),
    .ddr_wr_done  (tc_wr_done),
    .ddr_busy     (),
    .ddr_err      ()
  );

  // read-channel owner mux (TB guarantees no overlap)
  assign ddr_rd_re    = ddr_rd_owner ? tc_rd_re   : wl_rd_re;
  assign ddr_rd_addr  = ddr_rd_owner ? tc_rd_addr : wl_rd_addr;
  assign ddr_rd_len   = ddr_rd_owner ? tc_rd_len  : wl_rd_len;
  assign ddr_rd_rready= ddr_rd_owner ? tc_rd_rready : wl_rd_rready;
  assign wl_rd_ready  = ddr_rd_owner ? 1'b0       : ddr_rd_ready;
  assign tc_rd_ready  = ddr_rd_owner ? ddr_rd_ready : 1'b0;
  assign wl_rd_data   = ddr_rd_data;
  assign wl_rd_valid  = ddr_rd_valid;
  assign wl_rd_last   = ddr_rd_last;
  assign tc_rd_data   = ddr_rd_data;
  assign tc_rd_valid  = ddr_rd_valid;
  assign tc_rd_last   = ddr_rd_last;

  // ==========================================================================
  // weight/Q prefetch engine -> nn_mem fill ports
  // ==========================================================================
  logic         wfill_we;
  logic [17:0]  wfill_addr;
  logic [63:0]  wfill_wdata;
  logic         qfill_we;
  logic [12:0]  qfill_addr;
  logic [63:0]  qfill_wdata;

  nn_wload #(
    .MAX_PRE_WLEN (128*1024),
    .FIFO_AW      (5)
  ) u_wload (
    .clk           (clk),
    .rst           (rst),
    .ddr_clk       (clk),
    .ddr_rst       (rst),
    .pre_start     (pre_start),
    .pre_src_addr  (pre_src_addr),
    .pre_wlen      (pre_wlen),
    .pre_qsrc_addr (pre_qsrc_addr),
    .pre_qlen      (pre_qlen),
    .pre_bank      (pre_bank),
    .pre_busy      (pre_busy),
    .pre_done      (pre_done),
    .pre_err       (pre_err),
    .pre_fill_bank (),
    .ddr_rd_re     (wl_rd_re),
    .ddr_rd_addr   (wl_rd_addr),
    .ddr_rd_len    (wl_rd_len),
    .ddr_rd_ready  (wl_rd_ready),
    .ddr_rd_data   (wl_rd_data),
    .ddr_rd_valid  (wl_rd_valid),
    .ddr_rd_last   (wl_rd_last),
    .ddr_rd_rready (wl_rd_rready),
    .wfill_we      (wfill_we),
    .wfill_addr    (wfill_addr),
    .wfill_wdata   (wfill_wdata),
    .qfill_we      (qfill_we),
    .qfill_addr    (qfill_addr),
    .qfill_wdata   (qfill_wdata)
  );

  // ==========================================================================
  // nn_mem (W dual bank / Q shadow bank, w_mode=1) + engine read ports
  // ==========================================================================
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

  nn_mem u_nn_mem (
    .clk         (clk),
    .rst         (rst),
    .cpu_re      (1'b0),
    .cpu_we      (1'b0),
    .cpu_addr    (32'd0),
    .cpu_wdata   (32'd0),
    .cpu_wstrb   (4'd0),
    .cpu_rdata   (),
    .w_re        (w_re),
    .w_addr      (w_addr),
    .w_rdata     (w_rdata),
    .q_re        (q_re),
    .q_addr      (q_addr),
    .q_rdata     (q_rdata),
    .a_sel       (a_sel),
    .a_re        (a_re),
    .a_addr      (a_addr),
    .a_rdata     (a_rdata),
    .b_sel       (b_sel),
    .b_we        (b_we),
    .b_addr      (b_addr),
    .b_wdata     (b_wdata),
    .b_wstrb     (b_wstrb),
    .dbg_we      (dbg_we),
    .dbg_space   (dbg_space),
    .dbg_addr    (dbg_addr),
    .dbg_wdata   (dbg_wdata),
    .w_mode      (w_mode_sel),
    .w_bank_sel  (w_bank_sel),
    .wfill_we    (wfill_we),
    .wfill_addr  (wfill_addr),
    .wfill_wdata (wfill_wdata),
    .q_bank_sel  (q_bank_sel),
    .qfill_we    (qfill_we),
    .qfill_addr  (qfill_addr),
    .qfill_wdata (qfill_wdata)
  );

  // ==========================================================================
  // activation tile cache (band fill / engine / flush)
  // ==========================================================================
  logic [127:0] tc_a_rdata;

  nn_tilecache #(
    .IB_BYTES (IB_BYTES),
    .OB_BYTES (OB_BYTES)
  ) u_tilecache (
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
    .d_a_src_base    (d_a_src_base),
    .d_a_aux_base    (d_a_aux_base),
    .d_b_base        (d_b_base),
    .d_in_word_off   (d_in_word_off),
    .d_out_word_off  (d_out_word_off),
    .band_start      (band_start),
    .band_ready      (band_ready),
    .engine_done     (eng_done),
    .band_done       (band_done),
    .busy            (tc_busy),
    .err_code        (tc_err),
    .cur_bank        (),
    .fill_beats      (tc_fill_beats),
    .flush_beats     (tc_flush_beats),
    .dd_rd_re        (tc_rd_re),
    .dd_rd_addr      (tc_rd_addr),
    .dd_rd_len       (tc_rd_len),
    .dd_rd_ready     (tc_rd_ready),
    .dd_rd_data      (tc_rd_data),
    .dd_rd_valid     (tc_rd_valid),
    .dd_rd_last      (tc_rd_last),
    .dd_rd_rready    (tc_rd_rready),
    .dd_wr_re        (tc_wr_re),
    .dd_wr_addr      (tc_wr_addr),
    .dd_wr_len       (tc_wr_len),
    .dd_wr_ready     (tc_wr_ready),
    .dd_wr_data      (tc_wr_data),
    .dd_wr_valid     (tc_wr_valid),
    .dd_wr_rready    (tc_wr_rready),
    .dd_wr_done      (tc_wr_done),
    .a_sel           (a_sel),
    .a_re            (a_re),
    .a_addr          (a_addr),
    .a_rdata         (tc_a_rdata),
    .b_sel           (b_sel),
    .b_we            (b_we),
    .b_addr          (b_addr),
    .b_wdata         (b_wdata),
    .b_wstrb         (b_wstrb)
  );

  // ==========================================================================
  // real conv engine
  // ==========================================================================
  logic [31:0] eng_cycles_i;

  nn_conv_engine #(
    .OC_LANES (16),
    .PX_LANES (8),
    .W_RD_LAT (2)
  ) u_engine (
    .clk         (clk),
    .rst         (rst),
    .desc        (eng_desc),
    .start       (eng_start),
    .busy        (eng_busy),
    .done        (eng_done),
    .cycles      (eng_cycles_i),
    .err_code    (eng_err),
    .w_re        (w_re),
    .w_addr      (w_addr),
    .w_rdata     (w_rdata),
    .q_re        (q_re),
    .q_addr      (q_addr),
    .q_rdata     (q_rdata),
    .a_sel       (a_sel),
    .a_re        (a_re),
    .a_addr      (a_addr),
    .a_rdata     (tc_a_rdata),
    .b_sel       (b_sel),
    .b_we        (b_we),
    .b_addr      (b_addr),
    .b_wdata_128 (b_wdata),
    .b_wstrb     (b_wstrb)
  );

  assign eng_cycles = eng_cycles_i;

  // ==========================================================================
  // TB backdoor helpers (hierarchical calls from the TB)
  // ==========================================================================
  task automatic load_hex(input string path, input int unsigned word_off = 0);
    u_ddr.load_hex(path, word_off);
  endtask

  function automatic logic [63:0] peek_word(input int unsigned word_idx);
    peek_word = u_ddr.peek_word(word_idx);
  endfunction

`ifndef SYNTHESIS
  initial begin
    $display("[nn_ddr_chain] CONFIG MEM=%0dMB READ_LAT=%0d BEAT_GAP=%0d IB=%0dKBx2 OB=%0dKBx2",
             MEM_BYTES/1024/1024, READ_LAT, BEAT_GAP, IB_BYTES/1024, OB_BYTES/1024);
  end
`endif

endmodule
