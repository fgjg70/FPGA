`timescale 1ns/1ps

module vision_snapshot (
    input wire clk,
    input wire reset,
    input wire model_select,
    input wire enabled,
    input wire busy,
    input wire done,
    input wire pixel_write,
    input wire [14:0] pixel_address,
    input wire [15:0] pixel_data,
    input wire frame_done,
    output reg input_write,
    output reg [11:0] input_address,
    output reg [7:0] input_data,
    output reg start
);
    localparam PAD=0, WAIT_FRAME=1, CAPTURE=2, WAIT_NPU=3;
    reg [1:0] state;
    reg [7:0] pad_index;
    reg [7:0] column;
    reg [6:0] row;
    wire [7:0] red = {pixel_data[15:11], pixel_data[15:13]};
    wire [7:0] green = {pixel_data[10:5], pixel_data[10:9]};
    wire [7:0] blue = {pixel_data[4:0], pixel_data[4:2]};
    wire [9:0] luminance_sum = {2'b0, red} + {1'b0, green, 1'b0} + {2'b0, blue};
    wire [7:0] gray = luminance_sum[9:2];
    wire skin = red > 50 && green > 25 && blue > 10 &&
                {1'b0, red} > {1'b0, green} + 9'd5 && {1'b0, red} > {1'b0, blue} + 9'd15;

    always @(posedge clk) begin
        if (reset) begin
            state <= PAD;
            pad_index <= 0;
            row <= 0;
            column <= 0;
            input_write <= 0;
            input_address <= 0;
            input_data <= 0;
            start <= 0;
        end else begin
            input_write <= 0;
            start <= 0;
            if (pixel_write) begin
                if (pixel_address == 0) begin column <= 1; row <= 0; end
                else if (column == 159) begin column <= 0; row <= row + 1'b1; end
                else column <= column + 1'b1;
            end
            case (state)
                PAD: if (!busy && !done) begin
                    input_write <= 1;
                    input_data <= 0;
                    input_address <= pad_index < 128 ? {4'b0, pad_index} : 12'd3968 + (pad_index - 8'd128);
                    if (pad_index == 255) begin state <= WAIT_FRAME; pad_index <= 0; end
                    else pad_index <= pad_index + 1'b1;
                end
                WAIT_FRAME: if (enabled && !busy && !done && pixel_write && pixel_address == 0) state <= CAPTURE;
                CAPTURE: begin
                    if (!enabled) state <= PAD;
                    else if (frame_done) begin start <= 1; state <= WAIT_NPU; end
                    else if (pixel_write && !column[0] && !row[0] && column >= 16 && column < 144) begin
                        input_write <= 1;
                        input_address <= ((row >> 1) + 12'd2) * 12'd64 + ((column - 8'd16) >> 1);
                        input_data <= model_select ? (skin ? 8'd127 : 8'd0) : {1'b0, ~gray[7:1]};
                    end
                end
                WAIT_NPU: if (!busy && !done && !start) state <= PAD;
                default: state <= PAD;
            endcase
        end
    end
endmodule
