`timescale 1ns/1ps

module top_mes50hp (
  input  wire       sys_clk,
  input  wire       sys_rst_n,
`ifdef DIGIT_APP
  input  wire       video_clk,
  input  wire [6:0] keys_n,
  output wire [7:0] led,
  inout wire eeprom_scl,
  inout wire eeprom_sda,
  inout wire hdmi_scl,
  inout wire hdmi_sda,
  output wire hdmi_reset_n,
  output wire hdmi_pclk,
  output wire hdmi_hsync,
  output wire hdmi_vsync,
  output wire hdmi_de,
  output wire [23:0] hdmi_data,
`else
  output wire [3:0] led,
`endif
  output wire       uart_txd,
  input  wire       uart_rxd
);
  top_pgl22g u_soc (
    .sys_clk   (sys_clk),
    .sys_rst_n (sys_rst_n),
`ifdef DIGIT_APP
    .video_clk(video_clk), .keys_n(keys_n),
    .eeprom_scl(eeprom_scl), .eeprom_sda(eeprom_sda),
    .hdmi_scl(hdmi_scl), .hdmi_sda(hdmi_sda),
    .hdmi_reset_n(hdmi_reset_n), .hdmi_pclk(hdmi_pclk),
    .hdmi_hsync(hdmi_hsync), .hdmi_vsync(hdmi_vsync), .hdmi_de(hdmi_de), .hdmi_data(hdmi_data),
`endif
    .led       (led),
    .uart_txd  (uart_txd),
    .uart_rxd  (uart_rxd)
  );

endmodule
