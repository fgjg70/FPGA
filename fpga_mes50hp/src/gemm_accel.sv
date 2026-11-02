`timescale 1ns/1ps

module gemm_accel
  import rv32_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        sel,
  input  logic        we,
  input  logic        re,
  input  logic [31:0] addr,
  input  logic [3:0]  wstrb,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,
  output logic        busy,
  output logic        irq
);
  typedef enum logic [1:0] { IDLE, FETCH, MAC, STORE } state_e;
  state_e state;
  logic [31:0] dimension_m, dimension_k, dimension_n;
  logic done_r, error_r, irq_enable;
  logic [31:0] cycles_r;
  logic [8:0] row_index, column_index, inner_index;
  logic [7:0] a_index, b_index, row_base, output_index;
  logic [7:0] result_index;
  logic signed [31:0] accumulator;
  logic [31:0] a_words [0:63];
  logic [31:0] b_words [0:63];
  logic [31:0] c_words [0:255];
  logic [31:0] a_read, b_read, c_read;
  logic signed [7:0] a_value, b_value;
  logic signed [15:0] product;
  logic [31:0] arena_offset;
  logic arena_a, arena_b;
  logic dimensions_valid;
  logic [17:0] a_size, b_size, c_size;

  assign busy = state != IDLE;
  assign irq = done_r && irq_enable;
  assign arena_offset = addr - MMIO_GEMM_ARENA;
  assign arena_a = addr >= MMIO_GEMM_ARENA && addr < MMIO_GEMM_ARENA + 32'h100;
  assign arena_b = addr >= MMIO_GEMM_ARENA + 32'h100 && addr < MMIO_GEMM_ARENA + 32'h200;
  assign a_size = dimension_m[8:0] * dimension_k[8:0];
  assign b_size = dimension_k[8:0] * dimension_n[8:0];
  assign c_size = dimension_m[8:0] * dimension_n[8:0];
  assign dimensions_valid = dimension_m != 0 && dimension_m <= 256 &&
                            dimension_k != 0 && dimension_k <= 256 &&
                            dimension_n != 0 && dimension_n <= 256 &&
                            a_size <= 256 && b_size <= 256 && c_size <= 256;

  always_ff @(posedge clk) begin
    a_read <= a_words[a_index[7:2]];
    b_read <= b_words[b_index[7:2]];
    c_read <= c_words[result_index];
    if (!rst && sel && we && !busy && arena_a) begin
      if (wstrb[0]) a_words[arena_offset[7:2]][7:0] <= wdata[7:0];
      if (wstrb[1]) a_words[arena_offset[7:2]][15:8] <= wdata[15:8];
      if (wstrb[2]) a_words[arena_offset[7:2]][23:16] <= wdata[23:16];
      if (wstrb[3]) a_words[arena_offset[7:2]][31:24] <= wdata[31:24];
    end
    if (!rst && sel && we && !busy && arena_b) begin
      if (wstrb[0]) b_words[arena_offset[7:2]][7:0] <= wdata[7:0];
      if (wstrb[1]) b_words[arena_offset[7:2]][15:8] <= wdata[15:8];
      if (wstrb[2]) b_words[arena_offset[7:2]][23:16] <= wdata[23:16];
      if (wstrb[3]) b_words[arena_offset[7:2]][31:24] <= wdata[31:24];
    end
    if (!rst && state == STORE) c_words[output_index] <= accumulator;
  end

  always_comb begin
    case (a_index[1:0])
      0: a_value = a_read[7:0];
      1: a_value = a_read[15:8];
      2: a_value = a_read[23:16];
      default: a_value = a_read[31:24];
    endcase
    case (b_index[1:0])
      0: b_value = b_read[7:0];
      1: b_value = b_read[15:8];
      2: b_value = b_read[23:16];
      default: b_value = b_read[31:24];
    endcase
    product = a_value * b_value;
    rdata = 0;
    if (sel && re) begin
      case (addr)
        MMIO_GEMM_STATUS: rdata = {29'd0, error_r, done_r, busy};
        MMIO_GEMM_M: rdata = dimension_m;
        MMIO_GEMM_K: rdata = dimension_k;
        MMIO_GEMM_N: rdata = dimension_n;
        MMIO_GEMM_CYCLES: rdata = cycles_r;
        MMIO_GEMM_C_INDEX: rdata = {24'd0, result_index};
        MMIO_GEMM_C_DATA: rdata = c_read;
        MMIO_GEMM_ID: rdata = 32'h474D_0101;
        default: rdata = 0;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      dimension_m <= 0;
      dimension_k <= 0;
      dimension_n <= 0;
      done_r <= 0;
      error_r <= 0;
      irq_enable <= 0;
      cycles_r <= 0;
      row_index <= 0;
      column_index <= 0;
      inner_index <= 0;
      a_index <= 0;
      b_index <= 0;
      row_base <= 0;
      output_index <= 0;
      result_index <= 0;
      accumulator <= 0;
    end else begin
      if (busy) cycles_r <= cycles_r + 1;
      if (sel && we && wstrb == 4'hf) begin
        if (addr == MMIO_GEMM_C_INDEX) result_index <= wdata[7:0];
        if (!busy) begin
          case (addr)
            MMIO_GEMM_M: dimension_m <= wdata;
            MMIO_GEMM_K: dimension_k <= wdata;
            MMIO_GEMM_N: dimension_n <= wdata;
            MMIO_GEMM_CTRL: begin
              irq_enable <= wdata[1];
              if (wdata[0]) begin
                done_r <= 0;
                error_r <= !dimensions_valid;
                if (dimensions_valid) begin
                  state <= FETCH;
                  row_index <= 0;
                  column_index <= 0;
                  inner_index <= 0;
                  a_index <= 0;
                  b_index <= 0;
                  row_base <= 0;
                  output_index <= 0;
                  accumulator <= 0;
                  cycles_r <= 0;
                end
              end
            end
            default: begin end
          endcase
        end
      end
      case (state)
        FETCH: state <= MAC;
        MAC: begin
          accumulator <= accumulator + {{16{product[15]}}, product};
          if (inner_index + 1 < dimension_k) begin
            inner_index <= inner_index + 1;
            a_index <= a_index + 1;
            b_index <= b_index + dimension_n[7:0];
            state <= FETCH;
          end else state <= STORE;
        end
        STORE: begin
          accumulator <= 0;
          inner_index <= 0;
          output_index <= output_index + 1;
          if (column_index + 1 < dimension_n) begin
            column_index <= column_index + 1;
            a_index <= row_base;
            b_index <= column_index[7:0] + 1;
            state <= FETCH;
          end else if (row_index + 1 < dimension_m) begin
            row_index <= row_index + 1;
            column_index <= 0;
            row_base <= row_base + dimension_k[7:0];
            a_index <= row_base + dimension_k[7:0];
            b_index <= 0;
            state <= FETCH;
          end else begin
            state <= IDLE;
            done_r <= 1;
          end
        end
        default: begin end
      endcase
      if (sel && we && wstrb == 4'hf && addr == MMIO_GEMM_CTRL && wdata[2]) begin
        state <= IDLE;
        done_r <= 0;
        error_r <= 0;
        cycles_r <= 0;
      end
    end
  end
endmodule
