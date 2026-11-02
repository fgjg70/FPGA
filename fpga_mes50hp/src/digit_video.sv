`timescale 1ns/1ps

module digit_video (
  input wire pixel_clk,
  input wire reset,
  input wire frame_valid,
  input wire [31:0] state,
  input wire [23:0] software_bcd,
  input wire [23:0] hardware_bcd,
  input wire [7:0] image_value,
  output wire frame_start,
  output wire [7:0] image_address,
  output reg hsync,
  output reg vsync,
  output reg data_enable,
  output reg [23:0] rgb
);
  reg [9:0] horizontal, vertical;
  wire visible = horizontal >= 132 && horizontal < 852 && vertical >= 44 && vertical < 620;
  wire [9:0] position_x = horizontal - 132;
  wire [9:0] position_y = vertical - 44;
  wire [9:0] image_column = (position_x - 10'd32) / 10'd12;
  wire [9:0] image_row = (position_y - 10'd96) / 10'd12;
  reg [9:0] delayed_x, delayed_y;
  reg delayed_visible, delayed_hsync, delayed_vsync;
  wire tile = delayed_x >= 32 && delayed_x < 224 && delayed_y >= 96 && delayed_y < 288;
  wire [5:0] text_column = delayed_x[9:4];
  wire [5:0] text_row = delayed_y[9:4];
  reg [7:0] character;
  reg [4:0] glyph;
  reg [23:0] text_color;
  reg [23:0] time_digits;
  integer text_offset;

  assign frame_start = horizontal == 0 && vertical == 0;
  assign image_address = {image_row[3:0], image_column[3:0]};

  function automatic [7:0] text_char(input [255:0] text, input integer length, input integer column);
    if (column >= 0 && column < length) text_char = text >> ((length - 1 - column) * 8);
    else text_char = 8'd32;
  endfunction

  function automatic [4:0] font_row(input [7:0] letter, input [2:0] row_index);
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
        "-": bitmap = {5'd0,5'd0,5'd0,5'b11111,5'd0,5'd0,5'd0};
        ".": bitmap = {5'd0,5'd0,5'd0,5'd0,5'd0,5'b00110,5'b00110};
        "*": bitmap = {5'd0,5'b10101,5'b01110,5'b11111,5'b01110,5'b10101,5'd0};
        "_": bitmap = {5'd0,5'd0,5'd0,5'd0,5'd0,5'd0,5'b11111};
        default: bitmap = 0;
      endcase
      font_row = row_index < 7 ? bitmap >> ((6 - row_index) * 5) : 5'd0;
    end
  endfunction

  always @* begin
    character = 32;
    text_color = 24'he2e8f0;
    text_offset = {26'd0, text_column} - 16;
    time_digits = text_row == 14 ? software_bcd : hardware_bcd;
    case (text_row)
      1: begin
        character = text_char("RISC-V DIGIT TERMINAL", 21, text_column - 2);
        text_color = 24'h38bdf8;
      end
      4: character = text_char("INPUT 16X16", 11, text_column - 2);
      6: begin
        character = text_char("RESULT", 6, text_offset);
        if (text_column == 23) character = state[11:8] < 10 && state[15] ? 48 + {4'd0, state[11:8]} : 45;
        if (state[5] && text_column >= 26) character = text_char("CONFIRM", 7, text_column - 26);
      end
      8: begin
        character = text_char("DOOR", 4, text_offset);
        if (text_column >= 21)
          character = state[0] ? text_char("UNLOCKED", 8, text_column - 21) :
                      state[1] ? text_char("ALARM", 5, text_column - 21) : text_char("LOCKED", 6, text_column - 21);
        text_color = state[0] ? 24'h4ade80 : state[1] ? 24'hfb7185 : 24'hfbbf24;
      end
      10: begin
        character = text_char("PIN", 3, text_offset);
        if (text_column >= 21 && text_column < 25) character = text_column - 21 < state[4:2] ? 42 : 95;
      end
      12: begin
        character = text_char("MODE", 4, text_offset);
        if (text_column >= 21)
          character = state[13:12] == 0 ? text_char("HARDWARE", 8, text_column - 21) :
                      state[13:12] == 1 ? text_char("SOFTWARE", 8, text_column - 21) : text_char("COMPARE", 7, text_column - 21);
      end
      14, 16: begin
        if (text_offset == 0) character = text_row == 14 ? "S" : "H";
        if (text_offset == 1) character = "W";
        if (text_offset >= 3 && text_offset <= 5) character = 48 + ((time_digits >> ((8 - text_offset) * 4)) & 15);
        if (text_offset == 6) character = ".";
        if (text_offset >= 7 && text_offset <= 9) character = 48 + ((time_digits >> ((9 - text_offset) * 4)) & 15);
        if (text_offset == 11) character = "M";
        if (text_offset == 12) character = "S";
      end
      18: character = state[18] ? text_char("EEPROM ERROR", 12, text_offset) :
                      state[20] ? text_char("EEPROM SAVING", 13, text_offset) :
                      state[16] ? text_char("EEPROM SAVED", 12, text_offset) : text_char("EEPROM DEFAULT", 14, text_offset);
      21: character = text_char("VIDEO 720X576P50 27MHZ", 22, text_column - 2);
      23: character = state[14] ? text_char("PROCESSING", 10, text_column - 2) : text_char("RECOGNIZE THEN CONFIRM", 22, text_column - 2);
      25: character = text_char("K2 LOCK K3 UNDO K4 CONFIRM", 26, text_column - 2);
      27: character = text_char("K5 MODE K6 RECOGNIZE K7 CLEAR", 29, text_column - 2);
      29: character = text_char("K8 HOLD 2S RESTORE DEFAULTS", 27, text_column - 2);
      default: begin end
    endcase
    glyph = font_row(character, delayed_y[3:1]);
  end

  always @(posedge pixel_clk) begin
    if (reset) begin
      horizontal <= 0;
      vertical <= 0;
      delayed_x <= 0;
      delayed_y <= 0;
      delayed_visible <= 0;
      delayed_hsync <= 1;
      delayed_vsync <= 1;
      hsync <= 1;
      vsync <= 1;
      data_enable <= 0;
      rgb <= 0;
    end else begin
      if (horizontal == 863) begin
        horizontal <= 0;
        if (vertical == 624) vertical <= 0;
        else vertical <= vertical + 1;
      end else horizontal <= horizontal + 1;
      delayed_x <= position_x;
      delayed_y <= position_y;
      delayed_visible <= visible;
      delayed_hsync <= horizontal >= 64;
      delayed_vsync <= vertical >= 5;
      hsync <= delayed_hsync;
      vsync <= delayed_vsync;
      data_enable <= delayed_visible;
      rgb <= 0;
      if (delayed_visible) begin
        rgb <= 24'h0f172a;
        if (tile && frame_valid && state[15]) rgb <= {{image_value[6:0],1'b0},{image_value[6:0],1'b0},{image_value[6:0],1'b0}};
        else if (delayed_x[3:1] >= 1 && delayed_x[3:1] <= 5 && glyph[5 - delayed_x[3:1]]) rgb <= text_color;
      end
    end
  end
endmodule
