`timescale 1ns/1ps

module debug_video (
    input wire pixel_clk,
    input wire reset,
    input wire [133:0] status_bundle,
    input wire status_request,
    output reg status_ack,
    output reg frame_toggle,
    output reg hsync,
    output reg vsync,
    output reg data_enable,
    output reg [23:0] rgb
);
    reg [9:0] horizontal;
    reg [9:0] vertical;
    reg [1:0] request_sync;
    reg [133:0] frame_status;
    wire [5:0] keys;
    wire [47:0] key_counts;
    wire [31:0] press_count;
    wire [31:0] rx_count;
    wire [7:0] last_rx;
    wire [2:0] pattern;
    wire hdmi_ok, hdmi_failed, video_alive, fifo_overflow, frame_error;
    wire visible = horizontal >= 132 && horizontal < 852 && vertical >= 44 && vertical < 620;
    wire [9:0] position_x = horizontal - 10'd132;
    wire [9:0] position_y = vertical - 10'd44;
    wire [5:0] text_column = position_x[9:4];
    wire [5:0] text_row = position_y[9:4];
    reg [7:0] character;
    reg [4:0] glyph;
    reg [23:0] pixel_color;
    reg [23:0] text_color;
    reg [7:0] gray;
    integer box_index;
    integer digit_index;

    assign {keys, key_counts, press_count, rx_count, last_rx, pattern,
        hdmi_ok, hdmi_failed, video_alive, fifo_overflow, frame_error} = frame_status;

    function [7:0] text_char;
        input [359:0] text;
        input integer length;
        input integer column;
        begin
            if (column >= 0 && column < length) text_char = text >> ((length - 1 - column) * 8);
            else text_char = " ";
        end
    endfunction

    function [7:0] hex_digit;
        input [3:0] value;
        begin
            if (value < 10) hex_digit = 8'd48 + {4'd0, value};
            else hex_digit = 8'd55 + {4'd0, value};
        end
    endfunction

    function [4:0] font_row;
        input [7:0] letter;
        input [2:0] row_index;
        reg [34:0] bitmap;
        begin
            case (letter)
                "0": bitmap = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1": bitmap = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2": bitmap = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3": bitmap = {5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "4": bitmap = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                "5": bitmap = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                "6": bitmap = {5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                "7": bitmap = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                "8": bitmap = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                "9": bitmap = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                "A": bitmap = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "B": bitmap = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "C": bitmap = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "D": bitmap = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "E": bitmap = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "F": bitmap = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "G": bitmap = {5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111};
                "H": bitmap = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "I": bitmap = {5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "J": bitmap = {5'b00111,5'b00010,5'b00010,5'b00010,5'b10010,5'b10010,5'b01100};
                "K": bitmap = {5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                "L": bitmap = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "M": bitmap = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "N": bitmap = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
                "O": bitmap = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "P": bitmap = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "Q": bitmap = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101};
                "R": bitmap = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "S": bitmap = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "T": bitmap = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "U": bitmap = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "V": bitmap = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                "W": bitmap = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                "X": bitmap = {5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
                "Y": bitmap = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                "Z": bitmap = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111};
                ":": bitmap = {5'b00000,5'b00100,5'b00100,5'b00000,5'b00100,5'b00100,5'b00000};
                "?": bitmap = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b00000,5'b00100};
                "-": bitmap = {5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
                "c": bitmap = {5'b00000,5'b00000,5'b01111,5'b10000,5'b10000,5'b10000,5'b01111};
                "r": bitmap = {5'b00000,5'b00000,5'b10110,5'b11001,5'b10000,5'b10000,5'b10000};
                default: bitmap = 0;
            endcase
            if (row_index < 7) font_row = bitmap >> ((6 - row_index) * 5);
            else font_row = 0;
        end
    endfunction

    always @(posedge pixel_clk) begin
        if (reset) begin
            horizontal <= 0;
            vertical <= 0;
            request_sync <= 0;
            frame_status <= 0;
            status_ack <= 0;
            frame_toggle <= 0;
            hsync <= 1;
            vsync <= 1;
            data_enable <= 0;
            rgb <= 0;
        end else begin
            request_sync <= {request_sync[0], status_request};
            if (horizontal == 0 && vertical == 0) begin
                frame_toggle <= !frame_toggle;
                if (request_sync[1] != status_ack) begin
                    frame_status <= status_bundle;
                    status_ack <= request_sync[1];
                end
            end
            if (horizontal == 863) begin
                horizontal <= 0;
                if (vertical == 624) vertical <= 0;
                else vertical <= vertical + 1'b1;
            end else horizontal <= horizontal + 1'b1;
            hsync <= horizontal >= 64;
            vsync <= vertical >= 5;
            data_enable <= visible;
            rgb <= visible ? pixel_color : 24'd0;
        end
    end

    always @* begin
        pixel_color = 24'h101c30;
        text_color = 24'hf0f4ff;
        character = " ";
        digit_index = 0;
        gray = {position_x[9:3], 1'b0};
        if ((position_y >= 64 && position_y < 128) || (position_y >= 304 && position_y < 368)) begin
            case (pattern)
                0: begin
                    if (position_x < 90) pixel_color = 24'hffffff;
                    else if (position_x < 180) pixel_color = 24'hffff00;
                    else if (position_x < 270) pixel_color = 24'h00ffff;
                    else if (position_x < 360) pixel_color = 24'h00ff00;
                    else if (position_x < 450) pixel_color = 24'hff00ff;
                    else if (position_x < 540) pixel_color = 24'hff0000;
                    else if (position_x < 630) pixel_color = 24'h0000ff;
                    else pixel_color = 0;
                end
                1: pixel_color = (position_x[5] ^ position_y[5]) ? 24'hffffff : 24'h000000;
                2: pixel_color = 24'hff0000;
                3: pixel_color = 24'h00ff00;
                4: pixel_color = 24'h0000ff;
                5: begin gray = position_x < 512 ? position_x[8:1] : 8'hff; pixel_color = {gray, gray, gray}; end
                default: pixel_color = 0;
            endcase
        end
        for (box_index = 0; box_index < 6; box_index = box_index + 1) begin
            if (position_x >= 16 + box_index * 112 && position_x < 112 + box_index * 112 &&
                position_y >= 192 && position_y < 256)
                pixel_color = keys[box_index] ? 24'h168c5a : 24'h2c3e58;
        end
        case (text_row)
            1: begin character = text_char("MES50HP HDMI UART KEY TEST", 26, text_column - 2); text_color = 24'h50e0ff; end
            3: character = text_char("720X576P50   UART 115200 8N1", 28, text_column - 2);
            9: begin
                if (text_column >= 2 && text_column < 10) character = text_char("HDMI", 4, text_column - 2);
                if (text_column >= 7 && text_column < 11)
                    character = text_char(hdmi_ok ? "OK  " : (hdmi_failed ? "NACK" : "INIT"), 4, text_column - 7);
                if (text_column >= 14 && text_column < 26) character = text_char("RX", 2, text_column - 14);
                if (text_column >= 17 && text_column < 25) begin
                    digit_index = 24 - text_column;
                    character = hex_digit(rx_count >> (digit_index * 4));
                end
                if (text_column >= 28 && text_column < 33) character = text_char("LAST", 4, text_column - 28);
                if (text_column == 33) character = hex_digit(last_rx[7:4]);
                if (text_column == 34) character = hex_digit(last_rx[3:0]);
                if (text_column >= 37) character = text_char("MODE", 4, text_column - 37);
                if (text_column == 42) character = hex_digit({1'b0, pattern});
            end
            11, 13, 15, 17: begin
                for (box_index = 0; box_index < 6; box_index = box_index + 1) begin
                    if (text_row == 11 && text_column >= 2 + box_index * 7 && text_column < 6 + box_index * 7) begin
                        character = text_char("KEY", 3, text_column - 2 - box_index * 7);
                        if (text_column == 5 + box_index * 7) character = 8'd50 + box_index;
                    end
                    if (text_row == 13 && text_column >= 2 + box_index * 7 && text_column < 6 + box_index * 7)
                        character = text_char(keys[box_index] ? "DOWN" : "UP  ", 4, text_column - 2 - box_index * 7);
                    if (text_row == 15 && text_column >= 2 + box_index * 7 && text_column < 5 + box_index * 7)
                        character = text_char("CNT", 3, text_column - 2 - box_index * 7);
                    if (text_row == 17 && text_column == 3 + box_index * 7)
                        character = hex_digit(key_counts >> (box_index * 8 + 4));
                    if (text_row == 17 && text_column == 4 + box_index * 7)
                        character = hex_digit(key_counts >> (box_index * 8));
                end
            end
            24: character = text_char("KEY2 BARS   KEY3 CHECKER   KEY4 RED", 35, text_column - 2);
            26: character = text_char("KEY5 GREEN  KEY6 BLUE      KEY7 GRAY", 36, text_column - 2);
            28: character = text_char("UART ? STATUS   c CLEAR   r HDMI RETRY", 38, text_column - 2);
            30: begin
                character = text_char("TOTAL", 5, text_column - 2);
                if (text_column >= 8 && text_column < 16) character = hex_digit(press_count >> ((15 - text_column) * 4));
                if (text_column >= 19 && text_column < 23) character = text_char("FIFO", 4, text_column - 19);
                if (text_column == 24) character = hex_digit({3'b000, fifo_overflow});
                if (text_column >= 27 && text_column < 32) character = text_char("FRAME", 5, text_column - 27);
                if (text_column == 33) character = hex_digit({3'b000, frame_error});
            end
            33: begin character = text_char("KEY1 RESET   LED7 HEARTBEAT   LED8 HDMI", 39, text_column - 2); text_color = 24'h80a8c8; end
            default: begin end
        endcase
        glyph = font_row(character, position_y[3:1]);
        if (position_x[3:1] < 5 && glyph[4 - position_x[3:1]]) pixel_color = text_color;
        if (position_x < 3 || position_x >= 717 || position_y < 3 || position_y >= 573)
            pixel_color = 24'h50e0ff;
    end
endmodule
