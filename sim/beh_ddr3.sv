`timescale 1ns/1ps

// ============================================================================
// beh_ddr3.sv -- behavioral DDR3 memory model (simulation only, NO MIG)
// ----------------------------------------------------------------------------
// Owner : rtl-stream (task-8 / M3).  Interface frozen 2026-11-03 (v1.0),
//         published in results/bottlecap/reports/M3-WSTREAM.md section 2.
// Purpose: stand-in for a DDR3 controller user port while no board/pins/MIG
//          exist.  It models the *user side* of a 128-bit DDR3 controller:
//            . 128-bit read  port: burst command + AXI-like data handshake
//            . 128-bit write port: burst command + data handshake
//            . configurable read latency / read data cadence
//            . $readmemh initialization (weight/Q images) at a word offset
//          It is generic on purpose: nn_wload (weight prefetch) and the future
//          nn_tilecache (activation fill/flush) both connect to it.
//
// Memory model
//   mem[] is a 64-bit word array (MEM_BYTES/8 words), little endian:
//     beat[63:0]   = mem[byte_addr/8]
//     beat[127:64] = mem[byte_addr/8 + 1]
//   Byte address must be 16B aligned for a burst (128-bit beats).  This makes
//   a 64-bit-per-line $readmemh file map to memory byte-for-byte with no
//   repacking (the project's existing yolo_w.hex / yolo_q.hex format).
//
// Read command/data channel (port names are the DDR-side contract shared with
// nn_wload; see M3-WSTREAM.md section 2):
//   ddr_rd_re / ddr_rd_addr[31:0] / ddr_rd_len[15:0] -> ddr_rd_ready
//   ddr_rd_data[127:0] / ddr_rd_valid / ddr_rd_last -> ddr_rd_rready
//   - ddr_rd_len = burst length in 128-bit beats (1..65535), 1 = 16B
//   - command accepted when (ddr_rd_re && ddr_rd_ready) in one cycle
//   - first ddr_rd_valid beat appears READ_LAT+1 cycles after the handshake
//   - beats are spaced BEAT_GAP cycles apart (BEAT_GAP=1 -> 1 beat/cycle,
//     BEAT_GAP=4 -> 16B per 4 cycles = 4 B/cycle ~= 400 MB/s @100MHz, i.e. a
//     pessimistic model of 32-bit DDR3-400 effective bandwidth)
//   - if ddr_rd_rready is low the current beat is held (AXI-like backpressure);
//     a real MIG R channel behaves the same way.  Tie rready=1 when unused.
//   - ddr_rd_last marks the final beat of the burst.
//
// Write command/data channel:
//   ddr_wr_re / ddr_wr_addr[31:0] / ddr_wr_len[15:0] -> ddr_wr_ready
//   ddr_wr_data[127:0] / ddr_wr_valid -> ddr_wr_rready
//   ddr_wr_done : 1-cycle pulse when the burst is written
//   - the data phase accepts exactly ddr_wr_len beats (model always ready,
//     ddr_wr_rready=1 while the burst data phase is active)
//
// Status:
//   ddr_busy : read or write burst in progress
//   ddr_err  : sticky error bit (misaligned address / zero length / OOB)
//
// Notes / limitations (M3-WSTREAM.md section 2.3):
//   . Writes are visible to reads one cycle after they are accepted.
//   . A read and a write to the same 16B beat in the same cycle are not
//     defined; back-to-back traffic is fine.
//   . This model is NOT a DDR3 protocol/timing model: no bank/row/refresh,
//     no DQS, no ECC.  It models user-visible bandwidth/latency only.
// ============================================================================

module beh_ddr3 #(
  parameter int unsigned MEM_BYTES     = 8*1024*1024,  // 8MB default
  parameter int unsigned READ_LAT      = 40,           // cmd -> first beat (cycles)
  parameter int unsigned BEAT_GAP      = 4,            // 1 data beat per BEAT_GAP cycles
  parameter bit          ZERO_INIT     = 1'b1,         // zero-fill before init
  parameter string       INIT_FILE     = "",           // $readmemh image (64b/line)
  parameter int unsigned INIT_WORD_OFF = 0             // image dest word index
)(
  input  logic         clk,
  input  logic         rst,
  // ---- read command ----
  input  logic         ddr_rd_re,
  input  logic [31:0]  ddr_rd_addr,
  input  logic [15:0]  ddr_rd_len,
  output logic         ddr_rd_ready,
  // ---- read data ----
  output logic [127:0] ddr_rd_data,
  output logic         ddr_rd_valid,
  output logic         ddr_rd_last,
  input  logic         ddr_rd_rready,
  // ---- write command ----
  input  logic         ddr_wr_re,
  input  logic [31:0]  ddr_wr_addr,
  input  logic [15:0]  ddr_wr_len,
  output logic         ddr_wr_ready,
  // ---- write data ----
  input  logic [127:0] ddr_wr_data,
  input  logic         ddr_wr_valid,
  output logic         ddr_wr_rready,
  output logic         ddr_wr_done,
  // ---- status ----
  output logic         ddr_busy,
  output logic         ddr_err
);

  localparam int unsigned WORDS = MEM_BYTES / 8;      // 64-bit words
  localparam int unsigned AW    = $clog2(WORDS);      // word index width

  logic [63:0] mem [0:WORDS-1];

  // --------------------------------------------------------------------------
  // status / error
  // --------------------------------------------------------------------------
  logic err_q;
  assign ddr_err = err_q;

  // --------------------------------------------------------------------------
  // read path
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {R_IDLE, R_LAT, R_DATA} rstate_e;
  rstate_e       rstate;
  logic [AW-1:0] r_widx;        // current beat base word index (even)
  logic [15:0]   r_left;        // beats left to issue
  logic [15:0]   r_lat;         // latency countdown
  logic [15:0]   r_gap;         // cadence countdown
  logic          rvalid_q;
  logic [127:0]  rdata_q;
  logic          rlast_q;

  wire [63:0] rd_end_b = {32'd0, ddr_rd_addr} + ({48'd0, ddr_rd_len} << 4);

  assign ddr_rd_ready  = (rstate == R_IDLE);
  assign ddr_rd_valid  = rvalid_q;
  assign ddr_rd_data   = rdata_q;
  assign ddr_rd_last   = rlast_q;

  // NOTE: plain always (not always_ff) is used throughout this model: mem[] is
  // also written by the initial zero-fill / load_hex() backdoor, and err_q is
  // shared by both the read and write paths.
  always @(posedge clk) begin
    if (rst) begin
      rstate   <= R_IDLE;
      r_widx   <= '0;
      r_left   <= '0;
      r_lat    <= '0;
      r_gap    <= '0;
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
      rlast_q  <= 1'b0;
    end else begin
      unique case (rstate)
        R_IDLE: begin
          if (ddr_rd_re) begin
            if (ddr_rd_addr[3:0] != 4'h0) begin
              $display("[beh_ddr3] ERROR @%0t: read addr 0x%08x is not 16B aligned",
                       $time, ddr_rd_addr);
              err_q <= 1'b1;
            end else if (ddr_rd_len == 16'd0) begin
              $display("[beh_ddr3] ERROR @%0t: zero-length read burst", $time);
              err_q <= 1'b1;
            end else if (rd_end_b > MEM_BYTES) begin
              $display("[beh_ddr3] ERROR @%0t: read burst OOB addr=0x%08x len=%0d (mem=%0d B)",
                       $time, ddr_rd_addr, ddr_rd_len, MEM_BYTES);
              err_q <= 1'b1;
            end else begin
              r_widx <= ddr_rd_addr[AW+2:3];
              r_left <= ddr_rd_len;
              r_lat  <= READ_LAT[15:0];
              r_gap  <= '0;
              rstate <= R_LAT;
            end
          end
        end
        R_LAT: begin
          if (r_lat == 16'd0) rstate <= R_DATA;
          else                r_lat  <= r_lat - 16'd1;
        end
        R_DATA: begin
          if (rvalid_q && ddr_rd_rready) rvalid_q <= 1'b0;
          if (r_gap != 16'd0)            r_gap    <= r_gap - 16'd1;
          if ((r_left != 16'd0) && !rvalid_q && (r_gap == 16'd0)) begin
            rvalid_q <= 1'b1;
            rdata_q  <= {mem[r_widx + 1'b1], mem[r_widx]};
            rlast_q  <= (r_left == 16'd1);
            r_widx   <= r_widx + 2;
            r_left   <= r_left - 16'd1;
            r_gap    <= (BEAT_GAP <= 1) ? 16'd0 : 16'(BEAT_GAP - 1);
          end
          if ((r_left == 16'd0) && !rvalid_q) rstate <= R_IDLE;
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  // --------------------------------------------------------------------------
  // write path
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_DONE} wstate_e;
  wstate_e       wstate;
  logic [AW-1:0] w_widx;
  logic [15:0]   w_left;
  logic          wdone_q;

  wire [63:0] wr_end_b = {32'd0, ddr_wr_addr} + ({48'd0, ddr_wr_len} << 4);

  assign ddr_wr_ready  = (wstate == W_IDLE);
  assign ddr_wr_rready = (wstate == W_DATA);
  assign ddr_wr_done   = wdone_q;

  // NOTE: plain always (not always_ff) because `mem` is also written by the
  // initial zero-fill and by the load_hex() backdoor task (simulation only).
  always @(posedge clk) begin
    if (rst) begin
      wstate  <= W_IDLE;
      w_widx  <= '0;
      w_left  <= '0;
      wdone_q <= 1'b0;
    end else begin
      wdone_q <= 1'b0;
      unique case (wstate)
        W_IDLE: begin
          if (ddr_wr_re) begin
            if (ddr_wr_addr[3:0] != 4'h0) begin
              $display("[beh_ddr3] ERROR @%0t: write addr 0x%08x is not 16B aligned",
                       $time, ddr_wr_addr);
              err_q <= 1'b1;
            end else if (ddr_wr_len == 16'd0) begin
              $display("[beh_ddr3] ERROR @%0t: zero-length write burst", $time);
              err_q <= 1'b1;
            end else if (wr_end_b > MEM_BYTES) begin
              $display("[beh_ddr3] ERROR @%0t: write burst OOB addr=0x%08x len=%0d",
                       $time, ddr_wr_addr, ddr_wr_len);
              err_q <= 1'b1;
            end else begin
              w_widx <= ddr_wr_addr[AW+2:3];
              w_left <= ddr_wr_len;
              wstate <= W_DATA;
            end
          end
        end
        W_DATA: begin
          if (ddr_wr_valid) begin
            mem[w_widx]     <= ddr_wr_data[63:0];
            mem[w_widx + 1] <= ddr_wr_data[127:64];
            w_widx <= w_widx + 2;
            w_left <= w_left - 16'd1;
            if (w_left == 16'd1) wstate <= W_DONE;
          end
        end
        W_DONE: begin
          wdone_q <= 1'b1;
          wstate  <= W_IDLE;
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

  // --------------------------------------------------------------------------
  // status
  // --------------------------------------------------------------------------
  assign ddr_busy = (rstate != R_IDLE) || (wstate != W_IDLE) || rvalid_q;

  // --------------------------------------------------------------------------
  // initialization / backdoor helpers
  // --------------------------------------------------------------------------
  initial begin
    if (ZERO_INIT) begin
      for (int unsigned i = 0; i < WORDS; i++) mem[i] = 64'h0;
    end
    if (INIT_FILE != "") begin
      $display("[beh_ddr3] INIT: $readmemh(\"%s\") at word_off=%0d", INIT_FILE, INIT_WORD_OFF);
      $readmemh(INIT_FILE, mem, INIT_WORD_OFF);
    end
    $display("[beh_ddr3] CONFIG MEM_BYTES=%0d (%0d x64b words) READ_LAT=%0d BEAT_GAP=%0d",
             MEM_BYTES, WORDS, READ_LAT, BEAT_GAP);
  end

  // TB backdoor: load a 64-bit-per-line hex image at a word offset.
  // ModelSim resolves the hierarchical call at time > 0 (after the initial
  // zero-fill above has run), so a TB setup task must call this at #1 or later.
  task automatic load_hex(input string path, input int unsigned word_off = 0);
    $display("[beh_ddr3] BACKDOOR load_hex(\"%s\") at word_off=%0d", path, word_off);
    $readmemh(path, mem, word_off);
  endtask

  // TB backdoor: read one 64-bit word (no timing checks).
  function automatic logic [63:0] peek_word(input int unsigned word_idx);
    peek_word = mem[word_idx];
  endfunction

  // TB backdoor: write one 64-bit word (call while the DDR model is idle).
  task automatic poke_word(input int unsigned word_idx, input logic [63:0] data);
    mem[word_idx] = data;
  endtask

endmodule
