`timescale 1ns/1ps

module camera_framebuffer #(
    parameter integer PIXELS = 19200
) (
    input wire clk,
    input wire reset,
    input wire pixel_write,
    input wire [14:0] write_address,
    input wire [15:0] write_data,
    input wire frame_done,
    input wire frame_tick,
    input wire [14:0] read_address,
    output reg [15:0] read_data,
    output reg frame_valid,
    output reg frame_ack
);
    reg [15:0] memory [0:2*PIXELS-1];
    reg front_bank;
    reg back_bank;
    reg pending;
    wire [15:0] write_index = back_bank ? write_address + PIXELS : write_address;
    wire [15:0] read_index = front_bank ? read_address + PIXELS : read_address;

    always @(posedge clk) begin
        if (pixel_write && !reset) memory[write_index] <= write_data;
        read_data <= memory[read_index];
        if (reset) begin
            front_bank <= 0;
            back_bank <= 1;
            pending <= 0;
            frame_valid <= 0;
            frame_ack <= 0;
        end else begin
            frame_ack <= 0;
            if (frame_done) pending <= 1;
            if (pending && frame_tick) begin
                front_bank <= back_bank;
                back_bank <= front_bank;
                pending <= 0;
                frame_valid <= 1;
                frame_ack <= 1;
            end
        end
    end
endmodule
