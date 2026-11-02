`timescale 1ns/1ps

module tb_lcd;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1;
    reg configured = 1;
    reg failed = 0;
    reg frame_valid = 1;
    wire [14:0] image_address;
    wire frame_tick;
    wire dclk;
    wire hsync;
    wire vsync;
    wire de;
    wire [4:0] red;
    wire [5:0] green;
    wire [4:0] blue;
    integer pixel_x;
    integer pixel_y;
    integer active_count = 0;
    integer red_count = 0;
    integer white_count = 0;
    integer output_file;
    reg [2047:0] output_path;
    reg [7:0] sampled_character;
    vision_lcd dut (.clk(clk), .reset(reset), .show_bars(1'b0), .frame_valid(frame_valid), .configured(configured), .failed(failed),
        .overlay_valid(1'b1), .box_left(10'd112), .box_top(9'd50), .box_right(10'd240), .box_bottom(9'd140), .label(6'd19),
        .panel_status(32'h00643732), .pass_count(32'd12), .reject_count(32'd3),
        .camera_diagnostics({16'h1234, 16'h0056, 16'h0007, 8'h76, 8'h73, 8'h31, 8'h31, 16'h0012, 16'h0003, 16'h0004}),
        .image_pixel(16'h07e0), .image_address(image_address), .frame_tick(frame_tick), .dclk(dclk),
        .hsync(hsync), .vsync(vsync), .de(de), .red(red), .green(green), .blue(blue));
    initial begin
        if (!$value$plusargs("image=%s", output_path)) $fatal(1, "Missing output image path");
        output_file = $fopen(output_path, "w");
        $fwrite(output_file, "P3\n480 272\n255\n");
        configured = 0;
        #1;
        if (dut.state_text !== "CAM WAIT" || dut.state_color !== 16'hffe0) $fatal(1, "Missing camera initialization state");
        if (dut.footer_text[319:280] !== "DVP18") $fatal(1, "Missing DVP18 hardware-profile banner");
        failed = 1;
        #1;
        if (dut.state_text !== "CAM ERR " || dut.state_color !== 16'hf800) $fatal(1, "Camera failure hidden as initialization");
        configured = 1;
        failed = 0;
        frame_valid = 0;
        #1;
        if (dut.state_text !== "NO FRAME") $fatal(1, "Missing frame acquisition state");
        frame_valid = 1;
        repeat (4) @(negedge clk);
        reset = 0;
    end
    always @(posedge clk) begin
        if (!reset && dut.pixel_enable) begin
            pixel_x = dut.pixel_x;
            pixel_y = dut.pixel_y;
            sampled_character = dut.character;
            #1;
            if (de) begin
                active_count = active_count + 1;
                $fwrite(output_file, "%0d %0d %0d\n", {red, red[4:2]}, {green, green[5:4]}, {blue, blue[4:2]});
                if ({red, green, blue} == 16'hf800) red_count = red_count + 1;
                if ({red, green, blue} == 16'hffff) white_count = white_count + 1;
                if (pixel_x == 112 && pixel_y == 50 && {red, green, blue} !== 16'hf800) $fatal(1, "Missing red box edge");
                if (pixel_x == 180 && pixel_y == 100 && {red, green, blue} !== 16'h07e0) $fatal(1, "Box overwrote image interior");
                if (pixel_x == 360 && pixel_y == 256 && {red, green, blue} !== 16'hffff) $fatal(1, "Missing label glyph");
                if (pixel_x == 36 && pixel_y == 64 && sampled_character !== "7") $fatal(1, "Wrong camera PID text");
                if (pixel_x == 48 && pixel_y == 80 && sampled_character !== "3") $fatal(1, "Wrong camera version text");
                if (pixel_x == 48 && pixel_y == 96 && sampled_character !== "1") $fatal(1, "Wrong camera step text");
                if (pixel_x == 60 && pixel_y == 128 && sampled_character !== "2") $fatal(1, "Wrong camera VSYNC count text");
                if (pixel_x == 60 && pixel_y == 144 && sampled_character !== "4") $fatal(1, "Wrong camera frame count text");
                if (pixel_x == 60 && pixel_y == 160 && sampled_character !== "3") $fatal(1, "Wrong camera timeout text");
                if (pixel_x == 60 && pixel_y == 192 && sampled_character !== "4") $fatal(1, "Wrong camera PCLK count text");
                if (pixel_x == 60 && pixel_y == 208 && sampled_character !== "6") $fatal(1, "Wrong camera HREF count text");
                if (pixel_x == 60 && pixel_y == 224 && sampled_character !== "7") $fatal(1, "Wrong camera bad-frame count text");
                if (pixel_x == 479 && pixel_y == 271) begin
                    $fclose(output_file);
                    if (active_count != 130560 || red_count != 864 || white_count < 300)
                        $fatal(1, "LCD geometry mismatch active=%0d red=%0d white=%0d", active_count, red_count, white_count);
                    $display("PASS lcd 480x272 red_edges=%0d label_pixels=%0d", red_count, white_count);
                    $finish;
                end
            end
        end
    end
    initial begin #6000000; $fatal(1, "LCD test timeout"); end
endmodule
