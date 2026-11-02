`timescale 1ns/1ps

module tb_snapshot #(
    parameter HAND_MODE = 0
);
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1;
    reg enabled = 1;
    reg busy = 0;
    reg done = 0;
    reg pixel_write = 0;
    reg [14:0] pixel_address = 0;
    reg [15:0] pixel_data = 0;
    reg frame_done = 0;
    wire input_write;
    wire [11:0] input_address;
    wire [7:0] input_data;
    wire start;
    reg [7:0] captured [0:4095];
    reg [7:0] expected;
    integer writes = 0;
    integer pixel_index;
    integer sample_row;
    integer sample_column;
    integer gray;
    integer channel_red;
    integer channel_green;
    integer channel_blue;
    vision_snapshot dut (.clk(clk), .reset(reset), .model_select(HAND_MODE != 0), .enabled(enabled), .busy(busy), .done(done),
        .pixel_write(pixel_write), .pixel_address(pixel_address), .pixel_data(pixel_data), .frame_done(frame_done),
        .input_write(input_write), .input_address(input_address), .input_data(input_data), .start(start));
    function [15:0] color;
        input integer column;
        input integer row;
        begin color = {column[4:0], row[5:0], 5'd17}; end
    endfunction
    always @(posedge clk) begin
        if (!reset && input_write) begin
            if (busy || done) $fatal(1, "Snapshot writes during inference/result hold");
            captured[input_address] = input_data;
            writes = writes + 1;
        end
    end
    initial begin
        repeat (3) @(negedge clk);
        reset = 0;
        repeat (260) @(negedge clk);
        for (pixel_index = 0; pixel_index < 19200; pixel_index = pixel_index + 1) begin
            pixel_write = 1;
            pixel_address = pixel_index;
            pixel_data = color(pixel_index % 160, pixel_index / 160);
            @(negedge clk);
            pixel_write = 0;
            @(negedge clk);
        end
        frame_done = 1;
        @(negedge clk);
        frame_done = 0;
        if (!start) $fatal(1, "No inference request after complete frame");
        busy = 1;
        if (writes != 4096) $fatal(1, "Expected all 4096 input pixels, got %0d", writes);
        for (pixel_index = 0; pixel_index < 4096; pixel_index = pixel_index + 1) begin
            sample_row = pixel_index / 64;
            sample_column = pixel_index % 64;
            if (sample_row < 2 || sample_row >= 62) expected = 0;
            else begin
                pixel_data = color(16 + sample_column * 2, (sample_row - 2) * 2);
                gray = ({pixel_data[15:11], pixel_data[15:13]} + 2 * {pixel_data[10:5], pixel_data[10:9]} + {pixel_data[4:0], pixel_data[4:2]}) / 4;
                expected = (255 - gray) / 2;
                if (HAND_MODE) begin
                    channel_red = {pixel_data[15:11], pixel_data[15:13]};
                    channel_green = {pixel_data[10:5], pixel_data[10:9]};
                    channel_blue = {pixel_data[4:0], pixel_data[4:2]};
                    expected = channel_red > 50 && channel_green > 25 && channel_blue > 10 &&
                               channel_red > channel_green + 5 && channel_red > channel_blue + 15 ? 127 : 0;
                end
            end
            if (captured[pixel_index] !== expected)
                $fatal(1, "Snapshot mismatch address=%0d actual=%0d expected=%0d", pixel_index, captured[pixel_index], expected);
        end
        repeat (20) @(negedge clk);
        if (writes != 4096 || start) $fatal(1, "Snapshot did not stop while NPU busy");
        if (HAND_MODE) $display("PASS snapshot_hand 4096 pixels, RGB565 skin silhouette, zero padding and busy guard");
        else $display("PASS snapshot 4096 pixels, crop/padding/RGB565/inversion/busy guard");
        $finish;
    end
    initial begin #1000000; $fatal(1, "Snapshot test timeout"); end
endmodule
