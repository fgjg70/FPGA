`timescale 1ns/1ps

// ============================================================================
// nn_tilecache.sv -- activation band tile cache for the NPU engine (M4/task-9)
// ----------------------------------------------------------------------------
// Owner : rtl-stream.  Interface contract published in
//         results/bottlecap/reports/M4-TILECACHE.md.
//
// Problem
//   The bottle-cap model has activations up to 1,204,224 B per tensor, while
//   the chip-side A/B buffers are 96KB/32KB.  Execution therefore runs one
//   *output row band* at a time: fill the band's input rows from DDR3 into an
//   input buffer (IBUF), run the engine on that band, flush the band's output
//   rows from the output buffer (OBUF) back to DDR3.
//
// Design (P3-DDR3-TILECACHE.md section 4.5 "option A": independent module,
// nn_mem untouched, engine port semantics unchanged)
//   . IBUF: 2 banks x IB_BYTES (16 KiB) = 32 KiB.  The bank of the current band
//     is read by the engine through the nn_mem-compatible a_* port; the other
//     bank is the ADD destination band (a_sel=1) so an ADD op can read BOTH the
//     src and dst bands without a 2R1W BRAM (P3 section 4.5).
//   . OBUF: 2 banks x OB_BYTES (12 KiB) = 24 KiB.  The engine writes the
//     current band through the b_* port; the flush DMA reads it back to DDR3.
//     Bank parity toggles per band so consecutive bands never alias.
//   . a_*/b_* addresses are TILE-RELATIVE 16B-aligned byte offsets
//     (a_addr[13:4], b_addr[13:4] = 128-bit word index inside the bank).
//     For a band-sized engine run the sequencer programs the engine descriptor
//     with ih = band rows, iw = tensor width, src = 0, dst = 0 -- the engine's
//     existing address generator already substitutes zp_in for out-of-bounds
//     reads (nn_conv_engine.sv:339-340, 1079-1080), so it produces exactly
//     tile-relative addresses.
//   . Vertical padding: the band descriptor carries in_pad_top / in_rd_rows;
//     the fill DMA materializes pad rows as d_zp_in bytes (horizontal padding
//     stays inside the engine's x-bounds logic).
//   . Band handshake (sequential in v1, no cross-band overlap):
//       band_start (accepted when busy=0) -> fill src (+aux if add_mode)
//       -> band_ready -> [engine runs and writes OBUF] -> engine_done
//       -> flush all output rows -> band_done -> IDLE
//     nn_seq drives one band_start per band and one engine start per band
//     (see M4-TILECACHE.md section 8: "who drives the band loop").
//
// BRAM budget
//   IBUF 32 KiB + OBUF 24 KiB = 56 KiB = 14 tiles at the byte-addressed
//   4 KiB/BRAM convention used by nn_mem (or 12.4 tiles at the 36Kb/4.5 KiB
//   convention used by P3).  In bottle-cap mode the legacy A/B arrays (32
//   tiles) are freed, so 14 tiles fit (bottle-cap total: W 80 + Q 4 + tile 14
//   + core 12 = 110 / 135).
//
// Limitations of this first version (documented in M4-TILECACHE.md section 9)
//   . one band at a time (fill -> engine -> flush); cross-band fill overlap is
//     left to M5 (needs a second descriptor slot / start port).
//   . row_bytes and row strides must be multiples of 16 (16B = 1 DMA beat).
//   . the OBUF write port supports per-byte strobes (engine copy/half writes).
//   . PACKED3 conv0 streaming is out of scope for v1.
// ============================================================================

module nn_tilecache #(
  parameter int unsigned IB_BYTES = 16*1024,   // per IBUF bank
  parameter int unsigned OB_BYTES = 12*1024    // per OBUF bank
)(
  input  logic         clk,
  input  logic         rst,
  // ---- band descriptor (latched on band_start, clk domain) ----------------
  input  logic [31:0]  d_in_base,        // DDR byte addr of the first read row (16B aligned)
  input  logic [15:0]  d_in_rows,        // total rows materialized in IBUF (incl. pad rows)
  input  logic [15:0]  d_in_row_bytes,   // bytes per row in IBUF (multiple of 16)
  input  logic [15:0]  d_in_stride,      // DDR byte stride between rows (multiple of 16)
  input  logic [15:0]  d_in_pad_top,     // rows at the band start filled with d_zp_in
  input  logic [15:0]  d_in_rd_rows,     // rows read from DDR (after pad_top)
  input  logic [7:0]   d_zp_in,          // input zero point for pad rows
  input  logic         d_add_mode,       // 1 = also fill the aux (dst) band
  input  logic [31:0]  d_aux_base,       // DDR byte addr of aux band first read row
  input  logic [15:0]  d_aux_stride,
  input  logic [15:0]  d_aux_pad_top,
  input  logic [15:0]  d_aux_rd_rows,
  input  logic [31:0]  d_out_base,       // DDR byte addr of the first output row
  input  logic [15:0]  d_out_rows,       // output band rows
  input  logic [15:0]  d_out_row_bytes,  // bytes per output row (multiple of 16)
  input  logic [15:0]  d_out_stride,     // DDR byte stride between output rows
  // engine-side address bases (M6b): the real engine emits NN-window absolute
  // addresses; these are subtracted to get tile-relative offsets.
  // a_sel[0]=0 -> a_src_base, a_sel[0]=1 -> a_aux_base, b_* -> b_base
  input  logic [23:0]  d_a_src_base,
  input  logic [23:0]  d_a_aux_base,
  input  logic [23:0]  d_b_base,
  // optional 128b-word offsets applied when writing/reading the buffers.
  // Stock-address mode (M6b control experiment): set these to
  // A_OFF>>4 / B_OFF>>4 and the engine bases to the real A/B window offsets,
  // so the tilecache address mapping becomes identical to stock nn_mem.
  input  logic [16:0]  d_in_word_off,
  input  logic [16:0]  d_out_word_off,
  // ---- band handshake -----------------------------------------------------
  input  logic         band_start,       // 1-cycle pulse, accepted when busy=0
  output logic         band_ready,       // fill done: engine may run this band
  input  logic         engine_done,      // 1-cycle pulse: engine finished writing OBUF
  output logic         band_done,        // 1-cycle pulse: flush finished (or descriptor error)
  output logic         busy,
  output logic [7:0]   err_code,         // descriptor error bits (0 = ok)
  // ---- status / debug -----------------------------------------------------
  output logic [1:0]   cur_bank,         // {out_bank, in_bank}
  output logic [31:0]  fill_beats,       // DMA fill beats accepted (per band)
  output logic [31:0]  flush_beats,      // DMA flush beats issued (per band)
  // ---- DDR read channel (fill) : direct connect to beh_ddr3 / MIG --------
  output logic         dd_rd_re,
  output logic [31:0]  dd_rd_addr,
  output logic [15:0]  dd_rd_len,
  input  logic         dd_rd_ready,
  input  logic [127:0] dd_rd_data,
  input  logic         dd_rd_valid,
  input  logic         dd_rd_last,
  output logic         dd_rd_rready,
  // ---- DDR write channel (flush) : direct connect to beh_ddr3 / MIG ------
  output logic         dd_wr_re,
  output logic [31:0]  dd_wr_addr,
  output logic [15:0]  dd_wr_len,
  input  logic         dd_wr_ready,
  output logic [127:0] dd_wr_data,
  output logic         dd_wr_valid,
  input  logic         dd_wr_rready,   // model ready for a data beat (producer must respect)
  input  logic         dd_wr_done,
  // ---- engine activation read port (nn_mem a_* semantics, tile-relative) --
  input  logic [1:0]   a_sel,
  input  logic         a_re,
  input  logic [23:0]  a_addr,
  output logic [127:0] a_rdata,
  // ---- engine activation write port (nn_mem b_* semantics, tile-relative) -
  input  logic [1:0]   b_sel,
  input  logic         b_we,
  input  logic [23:0]  b_addr,
  input  logic [127:0] b_wdata,
  input  logic [15:0]  b_wstrb
);

  localparam int unsigned IB_WORDS = IB_BYTES / 16;   // 128-bit words per bank
  localparam int unsigned OB_WORDS = OB_BYTES / 16;
  localparam int unsigned IB_AW    = $clog2(IB_WORDS);  // word index width (M4: 10)
  localparam int unsigned OB_AW    = $clog2(OB_WORDS);  // word index width (M4: 10)

  // ==========================================================================
  // storage
  // ==========================================================================
  logic [127:0] ibuf [0:1][0:IB_WORDS-1];
  logic [127:0] obuf [0:1][0:OB_WORDS-1];

  logic         band_parity;      // toggles once per accepted band_start
  logic         in_bank, aux_bank, out_bank;

  assign in_bank  = band_parity;
  assign aux_bank = ~band_parity;
  assign out_bank = band_parity;
  assign cur_bank = {out_bank, in_bank};

  // engine address bases (M6b): subtract to get tile-relative offsets
  logic [23:0] a_src_base, a_aux_base, b_base;

  // ---- engine read port: nn_mem semantics = address at cycle N, data at N+1 -
  logic         a_re_q;
  logic [1:0]   a_sel_q;
  logic [23:0]  a_addr_q;
  logic [127:0] a_rdata_q;

  // nn_mem A/B-read semantics (verified against ddr3-feas stock trace):
  //   16B window, LATENCY 1 (address in cycle N -> a_rdata valid in N+1),
  //   and the low 4 address bits are IGNORED (window is 16B aligned).
  //   Only the W read port has 8B granularity -- A/B reads never rotate.
  logic [IB_AW-1:0] ib_words;   // words materialised in in_bank
  logic [IB_AW-1:0] aux_words;  // words materialised in aux_bank
  logic [23:0] a_local;      // combinational from the current a_addr
  logic [23:0] a_local_q;    // registered copy (debug: pairs with a_rdata_q)
  logic [IB_AW-1:0] a_word;

  assign a_local = a_addr - (a_sel[0] ? a_aux_base : a_src_base);
  assign a_word  = a_local[IB_AW+3:4];
  wire  a_in_band = a_sel[0] ? (a_word < aux_words) : (a_word < ib_words);

  always @(posedge clk) begin
    if (rst) begin
      a_re_q   <= 1'b0;
      a_sel_q  <= 2'd0;
      a_addr_q <= 24'd0;
      a_local_q<= 24'd0;
      a_rdata_q<= 128'd0;
    end else begin
      a_re_q    <= a_re;
      a_sel_q   <= a_sel;
      a_addr_q  <= a_addr;
      a_local_q <= a_local;
      if (!a_re || !a_in_band)
        a_rdata_q <= 128'd0;
      else
        a_rdata_q <= ibuf[a_sel[0] ? aux_bank : in_bank][a_word];
    end
  end
  assign a_rdata = a_rdata_q;

  // ---- engine write port -> OBUF with per-byte strobe (16 byte lanes) ------
  logic [23:0] b_local;
  assign b_local = b_addr - b_base;

  always @(posedge clk) begin
    if (b_we && (b_local[23:4] < 24'(OB_WORDS))) begin
      for (int bi = 0; bi < 16; bi++) begin
        if (b_wstrb[bi])
          obuf[out_bank][b_local[OB_AW+3:4]][bi*8 +: 8] <= b_wdata[bi*8 +: 8];
      end
    end
  end

  // ==========================================================================
  // descriptor latches (taken at band_start)
  // ==========================================================================
  logic [31:0] in_base, aux_base, out_base;
  logic [15:0] in_rows, in_row_bytes, in_stride, in_pad_top, in_rd_rows;
  logic [15:0] out_rows, out_row_bytes, out_stride;
  logic [15:0] aux_stride, aux_pad_top, aux_rd_rows;
  logic [15:0] in_beats_row, out_beats_row, aux_beats_row;
  logic [7:0]  zp_in;
  logic        add_mode;
  logic [7:0]  err_q;

  // current fill segment
  logic [1:0]  seg;             // 0 = src band, 1 = aux (ADD dst) band
  logic [15:0] row;
  logic [15:0] beat;
  logic [15:0] rows_this, pad_top_this, rd_rows_this, beats_row_this;
  logic [31:0] base_this;
  logic [15:0] stride_this;
  logic [IB_AW-1:0] ib_widx;    // 128b word index inside the IBUF bank
  logic [16:0]      in_word_off, out_word_off;

  // ==========================================================================
  // FSM
  // ==========================================================================
  typedef enum logic [3:0] {
    T_IDLE, T_ROW, T_FILL_REQ, T_FILL_RD, T_FILL_PAD,
    T_READY, T_FLUSH_REQ, T_FLUSH_WR, T_FIN
  } tstate_e;
  tstate_e state;

  // DDR read command (fill): combinational request only in T_FILL_REQ
  assign dd_rd_re      = (state == T_FILL_REQ);
  assign dd_rd_addr    = base_this + (32'(row) - 32'(pad_top_this)) * 32'(stride_this);
  assign dd_rd_len     = beats_row_this;
  assign dd_rd_rready  = (state == T_FILL_RD);

  // DDR write command (flush)
  assign dd_wr_re      = (state == T_FLUSH_REQ);
  assign dd_wr_addr    = out_base + 32'(row) * 32'(out_stride);
  assign dd_wr_len     = out_beats_row;
  assign dd_wr_data    = obuf[out_bank]
        [OB_AW'(32'(out_word_off) + 32'(row) * 32'(out_beats_row) + 32'(beat))];
  assign dd_wr_valid   = (state == T_FLUSH_WR);

  assign busy = (state != T_IDLE);

  always @(posedge clk) begin
    if (rst) begin
      state        <= T_IDLE;
      band_ready   <= 1'b0;
      band_done    <= 1'b0;
      err_q        <= 8'h00;
      band_parity  <= 1'b0;
      seg          <= 2'd0;
      row          <= 16'd0;
      beat         <= 16'd0;
      rows_this    <= 16'd0;
      pad_top_this <= 16'd0;
      rd_rows_this <= 16'd0;
      beats_row_this <= 16'd0;
      base_this    <= 32'd0;
      stride_this  <= 16'd0;
      ib_widx      <= '0;
      in_base      <= 32'd0;
      aux_base     <= 32'd0;
      out_base     <= 32'd0;
      in_rows      <= 16'd0;
      in_row_bytes <= 16'd0;
      in_stride    <= 16'd0;
      in_pad_top   <= 16'd0;
      in_rd_rows   <= 16'd0;
      out_rows     <= 16'd0;
      out_row_bytes<= 16'd0;
      out_stride   <= 16'd0;
      aux_stride   <= 16'd0;
      aux_pad_top  <= 16'd0;
      aux_rd_rows  <= 16'd0;
      in_beats_row <= 16'd0;
      out_beats_row<= 16'd0;
      aux_beats_row<= 16'd0;
      zp_in        <= 8'h00;
      add_mode     <= 1'b0;
      a_src_base   <= 24'd0;
      a_aux_base   <= 24'd0;
      b_base       <= 24'd0;
      in_word_off  <= 17'd0;
      out_word_off <= 17'd0;
      ib_words     <= '0;
      aux_words    <= '0;
      fill_beats   <= 32'd0;
      flush_beats  <= 32'd0;
    end else begin
      band_done <= 1'b0;

      unique case (state)
        // ------------------------------------------------------------------
        T_IDLE: begin
          band_ready <= 1'b0;
          if (band_start) begin
            err_q <= 8'h00;
            if ((d_in_row_bytes[3:0] != 4'h0) ||
                (d_in_stride[3:0]     != 4'h0) ||
                (d_out_row_bytes[3:0] != 4'h0) ||
                (d_out_stride[3:0]    != 4'h0)) begin
              err_q <= 8'hE0;             // 16B alignment violation
              state <= T_FIN;
            end else if ((32'(d_in_rows) * 32'(d_in_row_bytes) > 32'(IB_BYTES)) ||
                         (32'(d_out_rows) * 32'(d_out_row_bytes) > 32'(OB_BYTES))) begin
              err_q <= 8'hE1;             // band exceeds buffer capacity
              state <= T_FIN;
            end else if ((32'(d_in_pad_top) + 32'(d_in_rd_rows) > 32'(d_in_rows)) ||
                         (d_add_mode &&
                          (32'(d_aux_pad_top) + 32'(d_aux_rd_rows) > 32'(d_in_rows)))) begin
              err_q <= 8'hE2;             // pad_top + rd_rows > rows
              state <= T_FIN;
            end else begin
              in_base       <= d_in_base;
              in_rows       <= d_in_rows;
              in_row_bytes  <= d_in_row_bytes;
              in_stride     <= d_in_stride;
              in_pad_top    <= d_in_pad_top;
              in_rd_rows    <= d_in_rd_rows;
              out_base      <= d_out_base;
              out_rows      <= d_out_rows;
              out_row_bytes <= d_out_row_bytes;
              out_stride    <= d_out_stride;
              zp_in         <= d_zp_in;
              add_mode      <= d_add_mode;
              aux_base      <= d_aux_base;
              aux_stride    <= d_aux_stride;
              aux_pad_top   <= d_aux_pad_top;
              aux_rd_rows   <= d_aux_rd_rows;
              a_src_base    <= d_a_src_base;
              a_aux_base    <= d_a_aux_base;
              b_base        <= d_b_base;
              in_word_off   <= d_in_word_off;
              out_word_off  <= d_out_word_off;
              in_beats_row  <= d_in_row_bytes >> 4;
              out_beats_row <= d_out_row_bytes >> 4;
              aux_beats_row <= d_aux_stride >> 4;
              ib_words  <= IB_AW'(32'(d_in_rows) *
                                  (32'(d_in_row_bytes) >> 4));
              aux_words <= IB_AW'((32'(d_aux_pad_top) + 32'(d_aux_rd_rows)) *
                                   (32'(d_aux_stride) >> 4));
              band_parity   <= ~band_parity;
              fill_beats    <= 32'd0;
              flush_beats   <= 32'd0;
              seg           <= 2'd0;
              row           <= 16'd0;
              beat          <= 16'd0;
              rows_this     <= d_in_rows;
              pad_top_this  <= d_in_pad_top;
              rd_rows_this  <= d_in_rd_rows;
              base_this     <= d_in_base;
              stride_this   <= d_in_stride;
              beats_row_this<= d_in_row_bytes >> 4;
              ib_widx       <= '0;
              state         <= T_ROW;
            end
          end
        end

        // ------------------------------------------------------------------
        // decide pad row vs DDR-read row for the current row
        T_ROW: begin
          if ((row < pad_top_this) ||
              (row >= (pad_top_this + rd_rows_this))) begin
            beat  <= 16'd0;
            state <= T_FILL_PAD;
          end else begin
            beat  <= 16'd0;
            state <= T_FILL_REQ;
          end
        end

        // one DDR read burst per row
        T_FILL_REQ: begin
          if (dd_rd_ready) state <= T_FILL_RD;
        end
        T_FILL_RD: begin
          if (dd_rd_valid && dd_rd_rready) begin
            ibuf[(seg == 2'd1) ? aux_bank : in_bank]
              [IB_AW'(ib_widx + in_word_off[IB_AW-1:0])] <= dd_rd_data;
            ib_widx      <= ib_widx + 1'b1;
            fill_beats   <= fill_beats + 32'd1;
            if (beat == (beats_row_this - 16'd1)) begin
              beat <= 16'd0;
              row  <= row + 16'd1;
              if (row == (rows_this - 16'd1)) begin
                if (add_mode && (seg == 2'd0)) begin
                  seg           <= 2'd1;
                  row           <= 16'd0;
                  pad_top_this  <= aux_pad_top;
                  rd_rows_this  <= aux_rd_rows;
                  base_this     <= aux_base;
                  stride_this   <= aux_stride;
                  beats_row_this<= aux_beats_row;
                  ib_widx       <= '0;   // aux bank starts at word 0
                  state         <= T_ROW;
                end else begin
                  band_ready <= 1'b1;
                  state      <= T_READY;
                end
              end else begin
                state <= T_ROW;
              end
            end else begin
              beat <= beat + 16'd1;
            end
          end
        end
        // pad row: write d_zp_in replicated 16x, one 128b beat per cycle
        T_FILL_PAD: begin
          ibuf[(seg == 2'd1) ? aux_bank : in_bank]
            [IB_AW'(ib_widx + in_word_off[IB_AW-1:0])] <= {16{zp_in}};
          ib_widx    <= ib_widx + 1'b1;
          fill_beats <= fill_beats + 32'd1;
          if (beat == (beats_row_this - 16'd1)) begin
            beat <= 16'd0;
            row  <= row + 16'd1;
            if (row == (rows_this - 16'd1)) begin
              if (add_mode && (seg == 2'd0)) begin
                seg           <= 2'd1;
                row           <= 16'd0;
                pad_top_this  <= aux_pad_top;
                rd_rows_this  <= aux_rd_rows;
                base_this     <= aux_base;
                stride_this   <= aux_stride;
                beats_row_this<= aux_beats_row;
                ib_widx       <= '0;   // aux bank starts at word 0
                state         <= T_ROW;
              end else begin
                band_ready <= 1'b1;
                state      <= T_READY;
              end
            end else begin
              state <= T_ROW;
            end
          end else begin
            beat <= beat + 16'd1;
          end
        end

        // ------------------------------------------------------------------
        T_READY: begin
          if (engine_done) begin
            band_ready <= 1'b0;
            row        <= 16'd0;
            beat       <= 16'd0;
            state      <= T_FLUSH_REQ;
          end
        end

        // one DDR write burst per output row
        T_FLUSH_REQ: begin
          if (dd_wr_ready) state <= T_FLUSH_WR;
        end
        T_FLUSH_WR: begin
          if (dd_wr_valid && dd_wr_rready) begin
            flush_beats <= flush_beats + 32'd1;
            if (beat == (out_beats_row - 16'd1)) begin
              beat <= 16'd0;
              row  <= row + 16'd1;
              if (row == (out_rows - 16'd1)) state <= T_FIN;
              else                          state <= T_FLUSH_REQ;
            end else begin
              beat <= beat + 16'd1;
            end
          end
        end
        T_FIN: begin
          band_done <= 1'b1;
          state     <= T_IDLE;
        end
        default: state <= T_IDLE;
      endcase
    end
  end

  assign err_code = err_q;

`ifndef SYNTHESIS
  initial begin
    $display("[nn_tilecache] CONFIG IB=%0d B/bank x2, OB=%0d B/bank x2, total=%0d B",
             IB_BYTES, OB_BYTES, 2*IB_BYTES + 2*OB_BYTES);
  end
  always @(posedge clk) begin
    if (b_we && (b_local[23:4] >= 24'(OB_WORDS)) && !rst)
      $display("[nn_tilecache] ERROR @%0t: OBUF write addr 0x%06x out of range",
               $time, b_addr);
  end
`endif

endmodule
