`timescale 1ns/1ps

module debug_console (
    input wire clk,
    input wire reset,
    input wire clear_errors,
    input wire report_event,
    input wire [5:0] keys,
    input wire [31:0] press_count,
    input wire [31:0] rx_count,
    input wire [7:0] last_rx,
    input wire [2:0] pattern,
    input wire hdmi_ok,
    input wire hdmi_failed,
    input wire [7:0] hdmi_step,
    input wire video_alive,
    input wire [7:0] rx_data,
    input wire rx_valid,
    input wire rx_frame_error,
    input wire tx_busy,
    output reg [7:0] tx_data,
    output reg tx_start,
    output reg fifo_overflow,
    output reg frame_error
);
    localparam integer MESSAGE_BYTES = 104;
    reg [7:0] fifo [0:1023];
    reg [10:0] write_pointer;
    reg [10:0] read_pointer;
    reg [MESSAGE_BYTES*8-1:0] message;
    reg [6:0] message_left;
    reg report_pending;
    wire fifo_empty = write_pointer == read_pointer;
    wire fifo_full = write_pointer[9:0] == read_pointer[9:0] &&
        write_pointer[10] != read_pointer[10];
    wire can_transmit = !tx_busy && !tx_start;
    wire pop_echo = can_transmit && message_left == 0 && !fifo_empty;
    wire new_report = report_event || (rx_valid && rx_data == 8'h3f) ||
        rx_frame_error || (rx_valid && fifo_full && !pop_echo);

    function [7:0] hex_digit;
        input [3:0] value;
        begin
            if (value < 10) hex_digit = 8'd48 + {4'd0, value};
            else hex_digit = 8'd55 + {4'd0, value};
        end
    endfunction

    function [63:0] hex_word;
        input [31:0] value;
        begin
            hex_word = {hex_digit(value[31:28]), hex_digit(value[27:24]),
                hex_digit(value[23:20]), hex_digit(value[19:16]),
                hex_digit(value[15:12]), hex_digit(value[11:8]),
                hex_digit(value[7:4]), hex_digit(value[3:0])};
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            write_pointer <= 0;
            read_pointer <= 0;
            message <= 0;
            message_left <= 0;
            report_pending <= 1;
            tx_data <= 0;
            tx_start <= 0;
            fifo_overflow <= 0;
            frame_error <= 0;
        end else begin
            tx_start <= 0;
            report_pending <= report_pending || new_report;
            if (clear_errors) begin
                fifo_overflow <= 0;
                frame_error <= 0;
            end
            if (rx_frame_error) frame_error <= 1;
            if (rx_valid) begin
                if (!fifo_full || pop_echo) begin
                    fifo[write_pointer[9:0]] <= rx_data;
                    write_pointer <= write_pointer + 1'b1;
                end else fifo_overflow <= 1;
            end
            if (can_transmit) begin
                if (message_left != 0) begin
                    tx_data <= message[MESSAGE_BYTES*8-1 -: 8];
                    message <= message << 8;
                    message_left <= message_left - 1'b1;
                    tx_start <= 1;
                end else if (!fifo_empty) begin
                    tx_data <= fifo[read_pointer[9:0]];
                    read_pointer <= read_pointer + 1'b1;
                    tx_start <= 1;
                end else if (report_pending) begin
                    message <= {"[MES50HP] KEY=", hex_digit({2'b00, keys[5:4]}), hex_digit(keys[3:0]),
                        " COUNT=", hex_word(press_count), " RX=", hex_word(rx_count),
                        " LAST=", hex_digit(last_rx[7:4]), hex_digit(last_rx[3:0]),
                        " HDMI=", (hdmi_ok ? "OK  " : (hdmi_failed ? "NACK" : "INIT")),
                        " STEP=", hex_digit(hdmi_step[7:4]), hex_digit(hdmi_step[3:0]),
                        " VIDEO=", (video_alive ? "OK  " : "STOP"),
                        " FIFO=", hex_digit({3'b000, fifo_overflow}),
                        " FRAME=", hex_digit({3'b000, frame_error}),
                        " MODE=", hex_digit({1'b0, pattern}), 8'h0d, 8'h0a};
                    message_left <= MESSAGE_BYTES;
                    report_pending <= new_report;
                end
            end
        end
    end
endmodule
