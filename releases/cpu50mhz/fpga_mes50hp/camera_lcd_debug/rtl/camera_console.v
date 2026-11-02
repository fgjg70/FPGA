`timescale 1ns/1ps

module camera_console #(
    parameter integer CLOCK_HZ = 27000000
) (
    input wire clk,
    input wire reset,
    input wire report,
    input wire camera_mode,
    input wire configured,
    input wire failed,
    input wire [7:0] pid,
    input wire [7:0] version,
    input wire [7:0] step,
    input wire frozen,
    input wire [15:0] frames,
    input wire [15:0] vsyncs,
    input wire [15:0] timeouts,
    input wire [5:0] keys,
    input wire [2:0] touch,
    input wire [15:0] uart_errors,
    input wire tx_busy,
    output reg tx_start,
    output reg [7:0] tx_data
);
    localparam [8*74-1:0] TEMPLATE = {"CAMLCD M=0 C=0 E=0 ID=0000 S=00 F=0 N=0000 V=0000 T=0000 K=00 P=0 U=0000",8'h0d,8'h0a};
    reg [31:0] timer;
    reg pending;
    reg sending;
    reg [6:0] position;
    reg [8*74-1:0] message;
    reg [8*74-1:0] formatted;

    function [7:0] hex_digit;
        input [3:0] value;
        begin hex_digit = value < 10 ? 8'h30 + value : 8'h41 + value - 10; end
    endfunction

    always @* begin
        formatted = TEMPLATE;
        formatted[(74-1-9)*8 +: 8] = hex_digit({3'b0,camera_mode});
        formatted[(74-1-13)*8 +: 8] = hex_digit({3'b0,configured});
        formatted[(74-1-17)*8 +: 8] = hex_digit({3'b0,failed});
        formatted[(74-1-22)*8 +: 8] = hex_digit(pid[7:4]);
        formatted[(74-1-23)*8 +: 8] = hex_digit(pid[3:0]);
        formatted[(74-1-24)*8 +: 8] = hex_digit(version[7:4]);
        formatted[(74-1-25)*8 +: 8] = hex_digit(version[3:0]);
        formatted[(74-1-29)*8 +: 8] = hex_digit(step[7:4]);
        formatted[(74-1-30)*8 +: 8] = hex_digit(step[3:0]);
        formatted[(74-1-34)*8 +: 8] = hex_digit({3'b0,frozen});
        formatted[(74-1-38)*8 +: 8] = hex_digit(frames[15:12]);
        formatted[(74-1-39)*8 +: 8] = hex_digit(frames[11:8]);
        formatted[(74-1-40)*8 +: 8] = hex_digit(frames[7:4]);
        formatted[(74-1-41)*8 +: 8] = hex_digit(frames[3:0]);
        formatted[(74-1-45)*8 +: 8] = hex_digit(vsyncs[15:12]);
        formatted[(74-1-46)*8 +: 8] = hex_digit(vsyncs[11:8]);
        formatted[(74-1-47)*8 +: 8] = hex_digit(vsyncs[7:4]);
        formatted[(74-1-48)*8 +: 8] = hex_digit(vsyncs[3:0]);
        formatted[(74-1-52)*8 +: 8] = hex_digit(timeouts[15:12]);
        formatted[(74-1-53)*8 +: 8] = hex_digit(timeouts[11:8]);
        formatted[(74-1-54)*8 +: 8] = hex_digit(timeouts[7:4]);
        formatted[(74-1-55)*8 +: 8] = hex_digit(timeouts[3:0]);
        formatted[(74-1-59)*8 +: 8] = hex_digit({2'b0,keys[5:4]});
        formatted[(74-1-60)*8 +: 8] = hex_digit(keys[3:0]);
        formatted[(74-1-64)*8 +: 8] = hex_digit({1'b0,touch});
        formatted[(74-1-68)*8 +: 8] = hex_digit(uart_errors[15:12]);
        formatted[(74-1-69)*8 +: 8] = hex_digit(uart_errors[11:8]);
        formatted[(74-1-70)*8 +: 8] = hex_digit(uart_errors[7:4]);
        formatted[(74-1-71)*8 +: 8] = hex_digit(uart_errors[3:0]);
    end

    always @(posedge clk) begin
        if (reset) begin
            timer <= 0;
            pending <= 1;
            sending <= 0;
            position <= 0;
            message <= TEMPLATE;
            tx_start <= 0;
            tx_data <= 0;
        end else begin
            tx_start <= 0;
            if (timer == CLOCK_HZ - 1) begin timer <= 0; pending <= 1; end
            else timer <= timer + 1'b1;
            if (report) pending <= 1;
            if (!sending && pending) begin
                message <= formatted;
                pending <= 0;
                sending <= 1;
                position <= 0;
            end else if (sending && !tx_busy && !tx_start) begin
                tx_data <= message[(74-1-position)*8 +: 8];
                tx_start <= 1;
                if (position == 73) sending <= 0;
                else position <= position + 1'b1;
            end
        end
    end
endmodule
