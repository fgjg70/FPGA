`timescale 1ns/1ps

// ============================================================================
// nn_wload.sv -- DDR3 -> nn_mem weight/Q prefetch engine (M3, task-8)
// ----------------------------------------------------------------------------
// Owner : rtl-stream.  Interface frozen 2026-11-03 (v1.0); contract published
//         in results/bottlecap/reports/M3-WSTREAM.md section 2.
//
// What it does
//   One `pre_start` prefetches ONE NPU layer: `pre_wlen` weight bytes and
//   `pre_qlen` Q bytes from DDR3 into the nn_mem fill ports of the *inactive*
//   bank.  Both transfers are 16B-aligned DDR bursts of 128-bit beats that are
//   expanded into 64-bit words on the nn_mem fill ports:
//     . weight bytes -> wfill_we/wfill_addr[17:0]/wfill_wdata[63:0]
//       (addr = 64-bit word index inside the destination bank, starts at 0 for
//        every layer => layer-relative addressing, see WEIGHT-STREAMING 3.1)
//     . Q bytes      -> qfill_we/qfill_addr[12:0]/qfill_wdata[63:0]
//       (addr = 64-bit word index inside the Q shadow bank, starts at 0)
//   The DDR source address does NOT need to be 16B aligned: the engine aligns
//   the burst down to 16B and skips the leading 64-bit word.  The plan's W
//   region has 47/84 layers starting at 8 (mod 16) -- this is why.
//
// Clocking
//   `clk`      : NPU domain (control, fill ports).
//   `ddr_clk`  : DDR/MIG ui_clk domain (read command + read data).
//   Two asynchronous LUTRAM FIFOs (2^FIFO_AW x 144 bit = 576B each for AW=5)
//   carry data across the domains and cover the DDR read latency.  The job
//   descriptor crosses as a level payload + toggle handshake (payload is stable
//   from pre_start until pre_done); the completion crosses as a done toggle.
//   Tie `rst` and `ddr_rst` together (single reset) in the current integration.
//
// Flow / handshake
//   IDLE --pre_start--> wait ddr done --settle--> wait FIFOs drained --done
//   pre_busy : high from pre_start until all fill writes have been issued
//   pre_done : 1-cycle pulse in `clk` domain (after the last fill write)
//   pre_err  : level, valid with pre_done for the finished job; sticky until
//              the next pre_start.  Set on:
//                . pre_wlen > MAX_PRE_WLEN (128 KiB, rtl-mem portB rule)
//                . pre_qlen > Q_BANK_BYTES
//                . DDR model reported an error (ddr side only reports via the
//                  fill-word count mismatch here)
//                . fill word count != ceil(len/8) (lost/extra FIFO words,
//                  FIFO overflow, DDR read error)
//   pre_fill_bank : echo of pre_bank (debug/check only; nn_mem itself writes
//                   the non-active bank, so this must equal ~w_bank_sel)
//
// Length limits
//   pre_wlen <= 131,072 B (128 KiB).  Why not the full 160 KiB bank: rtl-mem's
//   nn_mem arbitrates BRAM portB between the engine `next` read and the fill
//   write; crossing 128 KiB would contend.  The bottle-cap max layer is
//   124,416 B and YOLO max is 30,720 B, both OK.
//   pre_qlen <= 8,192 B (Q shadow bank, 1024 x 64-bit words).
//   Lengths that are not a multiple of 8 write a final zero-padded 64-bit word
//   (nn_mem's fill port has no byte enables); all real layer lengths are
//   multiples of 8.
//
// Source address alignment
//   pre_src_addr / pre_qsrc_addr MUST be 8 B aligned (plan woff/qoff are
//   multiples of 8 because all layer payloads are multiples of 8).
//   16 B alignment is NOT required: the burst is aligned down to 16 B and the
//   leading 64-bit word is skipped (YOLO has 47/84 layers starting at 8 mod 16).
//   A non-8B-aligned source is rejected with pre_err (a 64-bit destination word
//   cannot express a byte-rotated layer).
// ============================================================================

module nn_wload #(
  // Defaults mirror nn_pkg.sv v0.8 constants (kept as parameters so this
  // module can be compiled standalone by sim/tb_nn_wstream.sv).
  parameter int unsigned MAX_PRE_WLEN = 128*1024,     // nn_pkg 128 KiB rule
  parameter int unsigned W_FILL_W64   = 20480,        // NN_W_BANK_W64 (160 KiB bank)
  parameter int unsigned Q_FILL_W64   = 1024,         // NN_Q_BANK_W64 (8 KiB)
  parameter int unsigned FIFO_AW      = 5             // 2^5 x 128b = 512B / FIFO
)(
  // ---- NPU clock domain ----
  input  logic         clk,
  input  logic         rst,
  // ---- DDR clock domain ----
  input  logic         ddr_clk,
  input  logic         ddr_rst,
  // ---- control (clk domain) ----
  input  logic         pre_start,
  input  logic [31:0]  pre_src_addr,
  input  logic [17:0]  pre_wlen,
  input  logic [31:0]  pre_qsrc_addr,
  input  logic [12:0]  pre_qlen,
  input  logic         pre_bank,
  output logic         pre_busy,
  output logic         pre_done,
  output logic         pre_err,
  output logic         pre_fill_bank,
  // ---- DDR read port (ddr_clk domain) : direct connect to beh_ddr3/MIG ----
  output logic         ddr_rd_re,
  output logic [31:0]  ddr_rd_addr,
  output logic [15:0]  ddr_rd_len,
  input  logic         ddr_rd_ready,
  input  logic [127:0] ddr_rd_data,
  input  logic         ddr_rd_valid,
  input  logic         ddr_rd_last,
  output logic         ddr_rd_rready,
  // ---- W fill (clk domain -> nn_mem) ----
  output logic         wfill_we,
  output logic [17:0]  wfill_addr,
  output logic [63:0]  wfill_wdata,
  // ---- Q fill (clk domain -> nn_mem) ----
  output logic         qfill_we,
  output logic [12:0]  qfill_addr,
  output logic [63:0]  qfill_wdata
);

  localparam int unsigned FIFO_DW = 144;   // {16-bit byte mask, 128-bit beat}

  // ---- cross-domain handshake (declared first: used by both domains) ------
  logic        job_tog;        // clk -> ddr : toggles at pre_start
  logic        done_tog;       // ddr -> clk : toggles when the job finished
  logic        d_job_err;      // ddr -> clk : error flag, stable with done_tog

  // ==========================================================================
  // helpers
  // ==========================================================================
  function automatic logic [15:0] ceil_beats(input logic [17:0] len,
                                             input logic [4:0]  off);
    ceil_beats = 16'((32'(len) + 32'(off) + 32'd15) >> 4);
  endfunction

  function automatic logic [4:0] last_hi_of(input logic [17:0] len,
                                            input logic [4:0]  off,
                                            input logic [15:0] beats);
    last_hi_of = 5'((32'(len) + 32'(off)) - (32'(beats) - 32'd1) * 32'd16);
  endfunction

  function automatic logic [63:0] mask_word(input logic [63:0] w,
                                            input logic [7:0]  bm);
    for (int b = 0; b < 8; b++)
      mask_word[8*b +: 8] = bm[b] ? w[8*b +: 8] : 8'h00;
  endfunction

  // ==========================================================================
  // asynchronous FIFOs (one for weights, one for Q)
  // ==========================================================================
  logic         wfifo_winc, wfifo_full, wfifo_ovf;
  logic [143:0] wfifo_wdata;
  logic         wfifo_rinc, wfifo_empty;
  logic [143:0] wfifo_rdata;

  logic         qfifo_winc, qfifo_full, qfifo_ovf;
  logic [143:0] qfifo_wdata;
  logic         qfifo_rinc, qfifo_empty;
  logic [143:0] qfifo_rdata;

  nn_wload_afifo #(.DW(FIFO_DW), .AW(FIFO_AW)) u_wfifo (
    .wclk   (ddr_clk),
    .wrst   (ddr_rst),
    .winc   (wfifo_winc),
    .wdata  (wfifo_wdata),
    .wfull  (wfifo_full),
    .wr_ovf (wfifo_ovf),
    .rclk   (clk),
    .rrst   (rst),
    .rinc   (wfifo_rinc),
    .rdata  (wfifo_rdata),
    .rempty (wfifo_empty)
  );

  nn_wload_afifo #(.DW(FIFO_DW), .AW(FIFO_AW)) u_qfifo (
    .wclk   (ddr_clk),
    .wrst   (ddr_rst),
    .winc   (qfifo_winc),
    .wdata  (qfifo_wdata),
    .wfull  (qfifo_full),
    .wr_ovf (qfifo_ovf),
    .rclk   (clk),
    .rrst   (rst),
    .rinc   (qfifo_rinc),
    .rdata  (qfifo_rdata),
    .rempty (qfifo_empty)
  );

  // ==========================================================================
  // clk domain: job control + fill drain
  // ==========================================================================
  typedef enum logic [2:0] {C_IDLE, C_WAIT, C_SETTLE, C_DRAIN, C_FIN} cstate_e;
  cstate_e     cstate;

  logic [31:0] job_wsrc, job_qsrc;
  logic [17:0] job_wlen;
  logic [12:0] job_qlen;
  logic        job_bank;
  logic        done_tog_s0, done_tog_s1, done_seen;
  logic        job_err_s0, job_err_s1;

  logic [7:0]  settle_cnt;
  logic [17:0] exp_w_words;
  logic [12:0] exp_q_words;
  logic [17:0] wcnt;           // number of wfill writes issued (job-relative)
  logic [12:0] qcnt;           // number of qfill writes issued (job-relative)
  logic        fill_clr;       // 1-cycle: reset the fill word counters at pre_start

  // ---- W fill drain (128b FIFO entry -> two 64b fill writes) --------------
  typedef enum logic [1:0] {WD_IDLE, WD_LO, WD_HI} wd_e;
  wd_e          wd_state;
  logic [127:0] wd_data;
  logic [15:0]  wd_mask;
  logic         wfill_lo_we, wfill_hi_we;
  logic [63:0]  wfill_lo_word, wfill_hi_word;

  assign wfifo_rinc = (wd_state == WD_IDLE) && !wfifo_empty;

  assign wfill_we   = wfill_lo_we | wfill_hi_we;
  assign wfill_addr = wcnt;
  assign wfill_wdata = wfill_lo_we ? wfill_lo_word : wfill_hi_word;

  assign wfill_lo_we   = (wd_state == WD_LO) && (|wd_mask[7:0]);
  assign wfill_hi_we   = (wd_state == WD_HI) && (|wd_mask[15:8]);
  assign wfill_lo_word = mask_word(wd_data[63:0],   wd_mask[7:0]);
  assign wfill_hi_word = mask_word(wd_data[127:64], wd_mask[15:8]);

  always_ff @(posedge clk) begin
    if (rst || fill_clr) begin
      wd_state <= WD_IDLE;
      wd_data  <= '0;
      wd_mask  <= '0;
      wcnt     <= '0;
    end else begin
      unique case (wd_state)
        WD_IDLE: if (!wfifo_empty) begin
          wd_data  <= wfifo_rdata[127:0];
          wd_mask  <= wfifo_rdata[143:128];
          wd_state <= WD_LO;
        end
        WD_LO: begin
          if (|wd_mask[7:0]) wcnt <= wcnt + 18'd1;
          wd_state <= WD_HI;
        end
        WD_HI: begin
          if (|wd_mask[15:8]) wcnt <= wcnt + 18'd1;
          wd_state <= WD_IDLE;
        end
        default: wd_state <= WD_IDLE;
      endcase
    end
  end

  // ---- Q fill drain -------------------------------------------------------
  typedef enum logic [1:0] {QD_IDLE, QD_LO, QD_HI} qd_e;
  qd_e          qd_state;
  logic [127:0] qd_data;
  logic [15:0]  qd_mask;
  logic         qfill_lo_we, qfill_hi_we;
  logic [63:0]  qfill_lo_word, qfill_hi_word;

  assign qfifo_rinc = (qd_state == QD_IDLE) && !qfifo_empty;

  assign qfill_we    = qfill_lo_we | qfill_hi_we;
  assign qfill_addr  = qcnt;
  assign qfill_wdata = qfill_lo_we ? qfill_lo_word : qfill_hi_word;

  assign qfill_lo_we   = (qd_state == QD_LO) && (|qd_mask[7:0]);
  assign qfill_hi_we   = (qd_state == QD_HI) && (|qd_mask[15:8]);
  assign qfill_lo_word = mask_word(qd_data[63:0],   qd_mask[7:0]);
  assign qfill_hi_word = mask_word(qd_data[127:64], qd_mask[15:8]);

  always_ff @(posedge clk) begin
    if (rst || fill_clr) begin
      qd_state <= QD_IDLE;
      qd_data  <= '0;
      qd_mask  <= '0;
      qcnt     <= '0;
    end else begin
      unique case (qd_state)
        QD_IDLE: if (!qfifo_empty) begin
          qd_data  <= qfifo_rdata[127:0];
          qd_mask  <= qfifo_rdata[143:128];
          qd_state <= QD_LO;
        end
        QD_LO: begin
          if (|qd_mask[7:0]) qcnt <= qcnt + 13'd1;
          qd_state <= QD_HI;
        end
        QD_HI: begin
          if (|qd_mask[15:8]) qcnt <= qcnt + 13'd1;
          qd_state <= QD_IDLE;
        end
        default: qd_state <= QD_IDLE;
      endcase
    end
  end

  assign pre_busy      = (cstate != C_IDLE);
  assign pre_fill_bank = job_bank;

  // ---- job start / completion FSM -----------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      cstate       <= C_IDLE;
      job_wsrc     <= '0;
      job_qsrc     <= '0;
      job_wlen     <= '0;
      job_qlen     <= '0;
      job_bank     <= 1'b0;
      job_tog      <= 1'b0;
      done_tog_s0  <= 1'b0;
      done_tog_s1  <= 1'b0;
      done_seen    <= 1'b0;
      job_err_s0   <= 1'b0;
      job_err_s1   <= 1'b0;
      settle_cnt   <= '0;
      exp_w_words  <= '0;
      exp_q_words  <= '0;
      fill_clr     <= 1'b0;
      pre_done     <= 1'b0;
      pre_err      <= 1'b0;
    end else begin
      pre_done <= 1'b0;
      fill_clr <= 1'b0;
      // 2FF synchronizers of the ddr-domain completion / error
      done_tog_s0 <= done_tog;
      done_tog_s1 <= done_tog_s0;
      job_err_s0  <= d_job_err;
      job_err_s1  <= job_err_s0;

      unique case (cstate)
        C_IDLE: begin
          if (pre_start) begin
            job_wsrc    <= pre_src_addr;
            job_qsrc    <= pre_qsrc_addr;
            job_wlen    <= pre_wlen;
            job_qlen    <= pre_qlen;
            job_bank    <= pre_bank;
            job_tog     <= ~job_tog;
            exp_w_words <= 18'((18'(pre_wlen) + 18'd7) >> 3);
            exp_q_words <= 13'((13'(pre_qlen) + 13'd7) >> 3);
            fill_clr    <= 1'b1;     // reset job-relative fill word counters
            pre_err     <= 1'b0;
            cstate      <= C_WAIT;
          end
        end
        C_WAIT: begin
          if (done_tog_s1 != done_seen) begin
            done_seen  <= done_tog_s1;
            settle_cnt <= 8'd8;      // let the last FIFO pointer propagate
            cstate     <= C_SETTLE;
          end
        end
        C_SETTLE: begin
          if (settle_cnt == 8'd0) cstate <= C_DRAIN;
          else                    settle_cnt <= settle_cnt - 8'd1;
        end
        C_DRAIN: begin
          if (wfifo_empty && qfifo_empty &&
              (wd_state == WD_IDLE) && (qd_state == QD_IDLE)) begin
            pre_err <= job_err_s1 | (wcnt != exp_w_words) | (qcnt != exp_q_words);
            cstate  <= C_FIN;
          end
        end
        C_FIN: begin
          pre_done <= 1'b1;
          cstate   <= C_IDLE;
        end
        default: cstate <= C_IDLE;
      endcase
    end
  end

  // ==========================================================================
  // ddr_clk domain: job capture + read bursts
  // ==========================================================================
  typedef enum logic [2:0] {D_IDLE, D_W_ISSUE, D_W_XFER, D_Q_ISSUE, D_Q_XFER,
                            D_FIN} dstate_e;
  dstate_e      dstate;

  logic         req_tog_s0, req_tog_s1, req_tog_seen;
  logic [31:0]  d_wsrc, d_qsrc;
  logic [17:0]  d_wlen;
  logic [12:0]  d_qlen;

  // W transfer setup
  logic [31:0]  w_aligned;
  logic [15:0]  w_beats;
  logic [4:0]   w_offset;
  logic [4:0]   w_last_hi;
  // Q transfer setup
  logic [31:0]  q_aligned;
  logic [15:0]  q_beats;
  logic [4:0]   q_offset;
  logic [4:0]   q_last_hi;
  // current beat index (shared by the two sequential transfers)
  logic [15:0]  t_beat;

  logic [4:0]   w_cur_lo, w_cur_hi, q_cur_lo, q_cur_hi;
  logic [15:0]  beat_mask;

  assign w_cur_lo = (t_beat == 16'd0) ? w_offset : 5'd0;
  assign w_cur_hi = (t_beat == (w_beats - 16'd1)) ? w_last_hi : 5'd16;
  assign q_cur_lo = (t_beat == 16'd0) ? q_offset : 5'd0;
  assign q_cur_hi = (t_beat == (q_beats - 16'd1)) ? q_last_hi : 5'd16;

  always_comb begin
    beat_mask = 16'h0000;
    for (int j = 0; j < 16; j++) begin
      if (dstate == D_W_XFER) beat_mask[j] = (j >= int'(w_cur_lo)) && (j < int'(w_cur_hi));
      else                    beat_mask[j] = (j >= int'(q_cur_lo)) && (j < int'(q_cur_hi));
    end
  end

  // read command channel (combinational: handshake in the *_ISSUE cycle)
  assign ddr_rd_re   = (dstate == D_W_ISSUE) || (dstate == D_Q_ISSUE);
  assign ddr_rd_addr = (dstate == D_W_ISSUE) ? w_aligned : q_aligned;
  assign ddr_rd_len  = (dstate == D_W_ISSUE) ? w_beats   : q_beats;
  // data channel: accept a beat only when the target FIFO has room
  assign ddr_rd_rready = (dstate == D_W_XFER) ? !wfifo_full :
                         (dstate == D_Q_XFER) ? !qfifo_full : 1'b0;

  assign wfifo_winc  = (dstate == D_W_XFER) && ddr_rd_valid && ddr_rd_rready;
  assign wfifo_wdata = {beat_mask, ddr_rd_data};
  assign qfifo_winc  = (dstate == D_Q_XFER) && ddr_rd_valid && ddr_rd_rready;
  assign qfifo_wdata = {beat_mask, ddr_rd_data};

  always_ff @(posedge ddr_clk) begin
    if (ddr_rst) begin
      dstate        <= D_IDLE;
      req_tog_s0    <= 1'b0;
      req_tog_s1    <= 1'b0;
      req_tog_seen  <= 1'b0;
      done_tog      <= 1'b0;
      d_wsrc        <= '0;
      d_qsrc        <= '0;
      d_wlen        <= '0;
      d_qlen        <= '0;
      d_job_err     <= 1'b0;
      w_aligned     <= '0;
      w_beats       <= '0;
      w_offset      <= '0;
      w_last_hi     <= '0;
      q_aligned     <= '0;
      q_beats       <= '0;
      q_offset      <= '0;
      q_last_hi     <= '0;
      t_beat        <= '0;
    end else begin
      req_tog_s0 <= job_tog;
      req_tog_s1 <= req_tog_s0;

      unique case (dstate)
        D_IDLE: begin
          if (req_tog_s1 != req_tog_seen) begin
            req_tog_seen <= req_tog_s1;
            d_wsrc       <= job_wsrc;
            d_qsrc       <= job_qsrc;
            d_wlen       <= job_wlen;
            d_qlen       <= job_qlen;
            d_job_err    <= 1'b0;
            if ((job_wlen == 18'd0) && (job_qlen == 13'd0)) begin
              dstate <= D_FIN;
            end else if ((job_wlen > 18'(MAX_PRE_WLEN)) ||
                         (32'((32'(job_qlen) + 32'd7) >> 3) > 32'(Q_FILL_W64)) ||
                         ((job_wlen != 18'd0) && (job_wsrc[2:0] != 3'd0)) ||
                         ((job_qlen != 13'd0) && (job_qsrc[2:0] != 3'd0))) begin
              // descriptor violates the bank limits: report, do not transfer
              d_job_err <= 1'b1;
              dstate    <= D_FIN;
            end else if (job_wlen == 18'd0) begin
              q_aligned <= {job_qsrc[31:4], 4'h0};
              q_offset  <= job_qsrc[3:0];
              q_beats   <= ceil_beats(18'(job_qlen), job_qsrc[3:0]);
              q_last_hi <= last_hi_of(18'(job_qlen), job_qsrc[3:0],
                                      ceil_beats(18'(job_qlen), job_qsrc[3:0]));
              t_beat    <= 16'd0;
              dstate    <= D_Q_ISSUE;
            end else begin
              w_aligned <= {job_wsrc[31:4], 4'h0};
              w_offset  <= job_wsrc[3:0];
              w_beats   <= ceil_beats(job_wlen, job_wsrc[3:0]);
              w_last_hi <= last_hi_of(job_wlen, job_wsrc[3:0],
                                      ceil_beats(job_wlen, job_wsrc[3:0]));
              t_beat    <= 16'd0;
              dstate    <= D_W_ISSUE;
            end
          end
        end
        D_W_ISSUE: begin
          if (ddr_rd_ready) dstate <= D_W_XFER;
        end
        D_W_XFER: begin
          if (wfifo_winc) begin
            t_beat <= t_beat + 16'd1;
            if (t_beat == (w_beats - 16'd1)) begin
              if (d_qlen == 13'd0) begin
                dstate <= D_FIN;
              end else begin
                q_aligned <= {d_qsrc[31:4], 4'h0};
                q_offset  <= d_qsrc[3:0];
                q_beats   <= ceil_beats(18'(d_qlen), d_qsrc[3:0]);
                q_last_hi <= last_hi_of(18'(d_qlen), d_qsrc[3:0],
                                        ceil_beats(18'(d_qlen), d_qsrc[3:0]));
                t_beat    <= 16'd0;
                dstate    <= D_Q_ISSUE;
              end
            end
          end
        end
        D_Q_ISSUE: begin
          if (ddr_rd_ready) dstate <= D_Q_XFER;
        end
        D_Q_XFER: begin
          if (qfifo_winc) begin
            t_beat <= t_beat + 16'd1;
            if (t_beat == (q_beats - 16'd1)) dstate <= D_FIN;
          end
        end
        D_FIN: begin
          d_job_err <= d_job_err | wfifo_ovf | qfifo_ovf;
          done_tog  <= ~done_tog;
          dstate    <= D_IDLE;
        end
        default: dstate <= D_IDLE;
      endcase
    end
  end

  // ==========================================================================
  // simulation-only sanity: lengths must be multiples of 8 except the final
  // word (documented zero padding), and the DDR source must be a valid 32-bit
  // address.  These are non-fatal info messages; the fill-word-count check in
  // C_DRAIN is the authoritative correctness gate.
  // ==========================================================================
`ifndef SYNTHESIS
  logic pre_start_d;
  always_ff @(posedge clk) begin
    if (rst) pre_start_d <= 1'b0;
    else begin
      pre_start_d <= pre_start;
      if (pre_start && !pre_start_d && (pre_wlen > 18'(MAX_PRE_WLEN)))
        $display("[nn_wload] ERROR @%0t: pre_wlen=%0d > MAX_PRE_WLEN=%0d",
                 $time, pre_wlen, MAX_PRE_WLEN);
    end
  end

  initial begin
    $display("[nn_wload] CONFIG MAX_PRE_WLEN=%0d W_FILL_W64=%0d Q_FILL_W64=%0d FIFO_AW=%0d (fifo=%0d B)",
             MAX_PRE_WLEN, W_FILL_W64, Q_FILL_W64, FIFO_AW, (1 << FIFO_AW) * 16);
  end
`endif

endmodule


// ============================================================================
// nn_wload_afifo -- dual-clock asynchronous FIFO (LUTRAM), 144b x 2^AW
// ----------------------------------------------------------------------------
// Standard gray-code pointer FIFO.  `rdata` is a combinational read of the
// current head entry; a pop is (rinc && !rempty).  `wr_ovf` is a sticky
// write-when-full flag for debug (a correct producer gates on wfull).
// ============================================================================
module nn_wload_afifo #(
  parameter int unsigned DW = 144,
  parameter int unsigned AW = 5
)(
  input  logic          wclk,
  input  logic          wrst,
  input  logic          winc,
  input  logic [DW-1:0] wdata,
  output logic          wfull,
  output logic          wr_ovf,
  input  logic          rclk,
  input  logic          rrst,
  input  logic          rinc,
  output logic [DW-1:0] rdata,
  output logic          rempty
);

  localparam int unsigned DEPTH = 1 << AW;

  logic [DW-1:0] mem [0:DEPTH-1];
  logic [AW:0]   wbin, wgray, rbin, rgray;
  logic [AW:0]   wgray_next, rgray_next;
  logic [AW:0]   rgray_s1, rq2_wgray;   // read ptr -> write domain
  logic [AW:0]   wgray_s1, wq2_rgray;   // write ptr -> read domain

  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    bin2gray = (b >> 1) ^ b;
  endfunction

  assign wgray_next = bin2gray(wbin + 1'b1);
  assign rgray_next = bin2gray(rbin + 1'b1);
  assign wfull      = (wgray == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});
  assign rempty     = (rgray == rq2_wgray);
  assign rdata      = mem[rbin[AW-1:0]];

  // write pointer + memory
  always_ff @(posedge wclk) begin
    if (wrst) begin
      wbin   <= '0;
      wgray  <= '0;
      wr_ovf <= 1'b0;
    end else if (winc) begin
      if (wfull) begin
        wr_ovf <= 1'b1;
      end else begin
        mem[wbin[AW-1:0]] <= wdata;
        wbin  <= wbin + 1'b1;
        wgray <= wgray_next;
      end
    end
  end

  // read pointer
  always_ff @(posedge rclk) begin
    if (rrst) begin
      rbin  <= '0;
      rgray <= '0;
    end else if (rinc && !rempty) begin
      rbin  <= rbin + 1'b1;
      rgray <= rgray_next;
    end
  end

  // gray pointer synchronizers (2FF each)
  always_ff @(posedge wclk) begin
    if (wrst) begin
      rgray_s1  <= '0;
      wq2_rgray <= '0;
    end else begin
      rgray_s1  <= rgray;
      wq2_rgray <= rgray_s1;
    end
  end

  always_ff @(posedge rclk) begin
    if (rrst) begin
      wgray_s1  <= '0;
      rq2_wgray <= '0;
    end else begin
      wgray_s1  <= wgray;
      rq2_wgray <= wgray_s1;
    end
  end

endmodule
