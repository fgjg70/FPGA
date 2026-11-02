`timescale 1ns/1ps

module uart_rx_fifo #(
  parameter integer CLK_HZ = 50_000_000,
  parameter integer BAUD_HZ = 115_200,
  parameter integer ADDRESS_BITS = 9
) (
  input wire clk,
  input wire rst,
  input wire serial_in,
  input wire pop,
  input wire flush,
  input wire clear_errors,
  input wire clear_counts,
  output wire [7:0] data,
  output wire ready,
  output wire [ADDRESS_BITS:0] count,
  output reg overrun,
  output reg framing_error,
  output reg [31:0] overrun_count,
  output reg [31:0] framing_count,
  output reg [31:0] received_count
);
  localparam integer DIVISOR = CLK_HZ / BAUD_HZ;
  localparam integer DEPTH = 1 << ADDRESS_BITS;
  localparam [2:0] IDLE = 0, START = 1, BITS = 2, STOP = 3, RECOVER = 4;
  (* ASYNC_REG = "TRUE" *) reg [2:0] synchronizer;
  reg [2:0] state;
  reg [15:0] divider;
  reg [2:0] bit_index;
  reg [7:0] shift;
  reg [7:0] memory [0:DEPTH-1];
  reg [ADDRESS_BITS-1:0] read_pointer, write_pointer;
  reg [ADDRESS_BITS:0] occupancy;
  wire receive_finished = state == STOP && divider == DIVISOR - 1;
  wire valid_byte = receive_finished && synchronizer[2];
  wire invalid_frame = receive_finished && !synchronizer[2];
  wire take = pop && ready;
  wire insert_byte = valid_byte && (occupancy != DEPTH || take);

  assign data = ready ? memory[read_pointer] : 8'd0;
  assign ready = occupancy != 0;
  assign count = occupancy;

  always @(posedge clk) begin
    if (rst) begin
      synchronizer <= 3'b111;
      state <= IDLE;
      divider <= 0;
      bit_index <= 0;
      shift <= 0;
    end else begin
      synchronizer <= {synchronizer[1:0], serial_in};
      case (state)
        IDLE: if (synchronizer[2:1] == 2'b10) begin
          state <= START;
          divider <= 0;
        end
        START: if (divider == DIVISOR / 2) begin
          divider <= 0;
          bit_index <= 0;
          state <= synchronizer[2] ? IDLE : BITS;
        end else divider <= divider + 1;
        BITS: if (divider == DIVISOR - 1) begin
          divider <= 0;
          shift <= {synchronizer[2], shift[7:1]};
          if (bit_index == 7) state <= STOP;
          else bit_index <= bit_index + 1;
        end else divider <= divider + 1;
        STOP: if (receive_finished) begin
          divider <= 0;
          state <= synchronizer[2] ? IDLE : RECOVER;
        end else divider <= divider + 1;
        RECOVER: if (synchronizer[2]) state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      read_pointer <= 0;
      write_pointer <= 0;
      occupancy <= 0;
      overrun <= 0;
      framing_error <= 0;
      overrun_count <= 0;
      framing_count <= 0;
      received_count <= 0;
    end else begin
      if (clear_errors) begin
        overrun <= 0;
        framing_error <= 0;
      end
      if (clear_counts) begin
        overrun_count <= 0;
        framing_count <= 0;
      end
      if (invalid_frame) begin
        framing_error <= 1;
        framing_count <= clear_counts ? 1 : framing_count + 1;
      end
      if (valid_byte) received_count <= received_count + 1;
      if (valid_byte && !insert_byte) begin
        overrun <= 1;
        overrun_count <= clear_counts ? 1 : overrun_count + 1;
      end
      if (flush) begin
        read_pointer <= 0;
        write_pointer <= 0;
        occupancy <= 0;
      end else begin
        if (insert_byte) begin
          memory[write_pointer] <= shift;
          write_pointer <= write_pointer + 1;
        end
        if (take) read_pointer <= read_pointer + 1;
        case ({insert_byte, take})
          2'b10: occupancy <= occupancy + 1;
          2'b01: occupancy <= occupancy - 1;
          default: begin end
        endcase
      end
    end
  end
endmodule
