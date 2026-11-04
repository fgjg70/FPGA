`timescale 1ns/1ps

module vision_yolo_rom #(
    parameter integer WORDS = 1
) (
    input wire clk,
    input wire [31:0] address,
    output reg [31:0] data
);
    reg [31:0] contents [0:WORDS-1];
    initial $readmemh("model/yolo.hex", contents);
    always @(posedge clk) data <= address < WORDS ? contents[address] : 32'd0;
endmodule
