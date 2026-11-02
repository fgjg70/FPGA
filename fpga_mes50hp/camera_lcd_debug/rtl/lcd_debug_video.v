`timescale 1ns/1ps

module lcd_debug_video (
    input wire clk,
    input wire reset,
    input wire camera_mode,
    input wire frame_valid,
    input wire configured,
    input wire failed,
    input wire frozen,
    input wire pen_down,
    input wire [15:0] image_pixel,
    output wire [14:0] image_address,
    output wire frame_tick,
    output wire dclk,
    output reg hsync,
    output reg vsync,
    output reg de,
    output reg [4:0] red,
    output reg [5:0] green,
    output reg [4:0] blue
);
    reg [1:0] phase;
    reg clock_pos;
    reg clock_neg;
    reg [9:0] horizontal;
    reg [8:0] vertical;
    wire pixel_enable = phase == 1;
    wire active = horizontal >= 43 && horizontal < 523 && vertical >= 12 && vertical < 284;
    wire [9:0] pixel_x = horizontal - 10'd43;
    wire [8:0] pixel_y = vertical - 9'd12;
    wire image_area = active && pixel_x >= 80 && pixel_x < 400 && pixel_y >= 16 && pixel_y < 256;
    wire [7:0] image_x = (pixel_x - 10'd80) >> 1;
    wire [6:0] image_y = (pixel_y - 9'd16) >> 1;
    assign image_address = image_area ? image_y * 15'd160 + image_x : 15'd0;
    assign frame_tick = pixel_enable && horizontal == 0 && vertical == 0;
    assign dclk = clock_pos | clock_neg;
    reg [15:0] selected_color;

    always @* begin
        case (pixel_x / 60)
            0: selected_color = 16'hffff;
            1: selected_color = 16'hffe0;
            2: selected_color = 16'h07ff;
            3: selected_color = 16'h07e0;
            4: selected_color = 16'hf81f;
            5: selected_color = 16'hf800;
            6: selected_color = 16'h001f;
            default: selected_color = 16'h0000;
        endcase
        if (camera_mode) begin
            selected_color = 16'h18e3;
            if (image_area) selected_color = frame_valid ? image_pixel : 16'h0000;
            if (pixel_y < 8) begin
                if (failed) selected_color = 16'hf800;
                else if (!configured) selected_color = 16'hffe0;
                else if (!frame_valid) selected_color = 16'h001f;
                else selected_color = 16'h07e0;
            end
            if (pixel_y >= 264) selected_color = frozen ? 16'hffe0 : 16'h001f;
        end
        if (pen_down && pixel_x < 12 && pixel_y < 12) selected_color = 16'hffff;
        if (!active) selected_color = 0;
    end

    always @(negedge clk) begin
        if (reset) clock_neg <= 0;
        else clock_neg <= clock_pos;
    end

    always @(posedge clk) begin
        if (reset) begin
            phase <= 0;
            clock_pos <= 0;
            horizontal <= 0;
            vertical <= 0;
            hsync <= 1;
            vsync <= 1;
            de <= 0;
            red <= 0;
            green <= 0;
            blue <= 0;
        end else begin
            if (phase == 2) begin phase <= 0; clock_pos <= 1; end
            else begin phase <= phase + 1'b1; clock_pos <= 0; end
            if (pixel_enable) begin
                hsync <= horizontal >= 41;
                vsync <= vertical >= 10;
                de <= active;
                red <= selected_color[15:11];
                green <= selected_color[10:5];
                blue <= selected_color[4:0];
                if (horizontal == 524) begin
                    horizontal <= 0;
                    if (vertical == 285) vertical <= 0;
                    else vertical <= vertical + 1'b1;
                end else horizontal <= horizontal + 1'b1;
            end
        end
    end
endmodule
