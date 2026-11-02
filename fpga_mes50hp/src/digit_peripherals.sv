`timescale 1ns/1ps

module digit_peripherals #(
  parameter integer DEBOUNCE_CYCLES = 250_000
) (
  input wire clk,
  input wire rst,
  input wire pixel_clk,
  input wire [6:0] keys_n,
  input wire we,
  input wire re,
  input wire [31:0] addr,
  input wire [31:0] wdata,
  input wire [3:0] wstrb,
  output reg [31:0] rdata,
  output wire selected,
  output wire [6:0] key_levels,
  inout wire eeprom_scl,
  inout wire eeprom_sda,
  inout wire hdmi_scl,
  inout wire hdmi_sda,
  output wire hdmi_reset_n,
  output wire hdmi_pclk,
  output wire hdmi_hsync,
  output wire hdmi_vsync,
  output wire hdmi_de,
  output wire [23:0] hdmi_data
);
  (* ASYNC_REG = "TRUE" *) reg [6:0] key_sync_first, key_sync_second;
  reg [6:0] key_stable, key_pulse, key_events;
  reg [17:0] debounce_count [0:6];
  reg [4:0] io_control;
  (* ASYNC_REG = "TRUE" *) reg [3:0] io_sync_first, io_sync_second;
  reg [31:0] staging_state;
  reg [23:0] staging_software, staging_hardware;
  reg request_toggle;
  (* ASYNC_REG = "TRUE" *) reg [1:0] acknowledge_sync;
  (* ASYNC_REG = "TRUE" *) reg [1:0] request_sync;
  (* ASYNC_REG = "TRUE" *) reg [2:0] video_reset_sync;
  reg front_buffer, frame_valid;
  reg [31:0] video_state;
  reg [23:0] video_software, video_hardware;
  reg [31:0] image_memory [0:127];
  reg [31:0] image_word;
  reg [1:0] image_lane;
  wire [7:0] image_address;
  wire [8:0] read_address = {front_buffer, image_address};
  wire [6:0] write_address = {~acknowledge_sync[1], addr[7:2]};
  wire [7:0] image_value = image_word >> (image_lane * 8);
  wire commit_pending = request_toggle != acknowledge_sync[1];
  wire frame_start;
  wire video_reset = !video_reset_sync[2];
  wire register_selected = addr >= 32'hA0000080 && addr <= 32'hA00000A8;
  wire image_selected = addr >= 32'hA0000800 && addr < 32'hA0000900;
  integer key_index;

  assign selected = register_selected || image_selected;
  assign key_levels = key_stable;
  assign eeprom_scl = io_control[0] ? 1'bz : 1'b0;
  assign eeprom_sda = io_control[1] ? 1'bz : 1'b0;
  assign hdmi_scl = io_control[2] ? 1'bz : 1'b0;
  assign hdmi_sda = io_control[3] ? 1'bz : 1'b0;
  assign hdmi_reset_n = io_control[4];
  assign hdmi_pclk = ~pixel_clk;

  always @(posedge clk) begin
    if (rst) begin
      key_sync_first <= 7'h7f;
      key_sync_second <= 7'h7f;
      key_stable <= 0;
      key_pulse <= 0;
      key_events <= 0;
      for (key_index = 0; key_index < 7; key_index = key_index + 1) debounce_count[key_index] <= 0;
    end else begin
      key_sync_first <= keys_n;
      key_sync_second <= key_sync_first;
      key_pulse <= 0;
      key_events <= (key_events & ~(we && addr == 32'hA0000080 ? wdata[6:0] : 7'd0)) | key_pulse;
      for (key_index = 0; key_index < 7; key_index = key_index + 1) begin
        if (!key_sync_second[key_index] == key_stable[key_index]) debounce_count[key_index] <= 0;
        else if (debounce_count[key_index] == DEBOUNCE_CYCLES - 1) begin
          key_stable[key_index] <= !key_sync_second[key_index];
          key_pulse[key_index] <= !key_sync_second[key_index];
          debounce_count[key_index] <= 0;
        end else debounce_count[key_index] <= debounce_count[key_index] + 1;
      end
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      io_control <= 5'h0f;
      io_sync_first <= 4'hf;
      io_sync_second <= 4'hf;
      staging_state <= 0;
      staging_software <= 0;
      staging_hardware <= 0;
      request_toggle <= 0;
      acknowledge_sync <= 0;
    end else begin
      io_sync_first <= {hdmi_sda, hdmi_scl, eeprom_sda, eeprom_scl};
      io_sync_second <= io_sync_first;
      acknowledge_sync <= {acknowledge_sync[0], front_buffer};
      if (we && wstrb == 4'hf) begin
        if (addr == 32'hA0000088) io_control <= wdata[4:0];
        if (!commit_pending) begin
          if (addr == 32'hA0000090) staging_state <= wdata;
          if (addr == 32'hA0000094) staging_software <= wdata[23:0];
          if (addr == 32'hA0000098) staging_hardware <= wdata[23:0];
          if (addr == 32'hA00000A0 && wdata[0]) request_toggle <= ~request_toggle;
        end
      end
    end
    if (!rst && we && image_selected && !commit_pending) begin
      if (wstrb[0]) image_memory[write_address][7:0] <= wdata[7:0];
      if (wstrb[1]) image_memory[write_address][15:8] <= wdata[15:8];
      if (wstrb[2]) image_memory[write_address][23:16] <= wdata[23:16];
      if (wstrb[3]) image_memory[write_address][31:24] <= wdata[31:24];
    end
  end

  always @(posedge pixel_clk or posedge rst) begin
    if (rst) video_reset_sync <= 0;
    else video_reset_sync <= {video_reset_sync[1:0], 1'b1};
  end

  always @(posedge pixel_clk) begin
    image_word <= image_memory[read_address[8:2]];
    image_lane <= read_address[1:0];
    if (video_reset) begin
      request_sync <= 0;
      front_buffer <= 0;
      frame_valid <= 0;
      video_state <= 0;
      video_software <= 0;
      video_hardware <= 0;
    end else begin
      request_sync <= {request_sync[0], request_toggle};
      if (frame_start && request_sync[1] != front_buffer) begin
        front_buffer <= request_sync[1];
        frame_valid <= 1;
        video_state <= staging_state;
        video_software <= staging_software;
        video_hardware <= staging_hardware;
      end
    end
  end

  always @* begin
    rdata = 0;
    if (re) begin
      case (addr)
        32'hA0000080: rdata = {25'd0, key_events};
        32'hA0000084: rdata = {25'd0, key_stable};
        32'hA0000088: rdata = {27'd0, io_control};
        32'hA000008C: rdata = {28'd0, io_sync_second};
        32'hA0000090: rdata = staging_state;
        32'hA0000094: rdata = {8'd0, staging_software};
        32'hA0000098: rdata = {8'd0, staging_hardware};
        32'hA00000A0: rdata = {30'd0, acknowledge_sync[1], commit_pending};
        32'hA00000A8: rdata = 32'h44500201;
        default: begin end
      endcase
    end
  end

  digit_video u_video (
    .pixel_clk(pixel_clk), .reset(video_reset), .frame_valid(frame_valid),
    .state(video_state), .software_bcd(video_software), .hardware_bcd(video_hardware),
    .image_value(image_value), .frame_start(frame_start), .image_address(image_address),
    .hsync(hdmi_hsync), .vsync(hdmi_vsync), .data_enable(hdmi_de), .rgb(hdmi_data)
  );
endmodule
