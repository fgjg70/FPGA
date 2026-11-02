`timescale 1ns/1ps
module hdmi_loop(
    input wire sys_clk, input wire sys_rst_n,
    output wire ddc_scl, inout wire ddc_sda,
    input wire hdmi_in_clk, output wire hdmi_in_rst_n,
    input wire hdmi_in_hsync, input wire hdmi_in_vsync,
    input wire [23:0] hdmi_in_rgb, input wire hdmi_in_de,
    output wire hdmi_out_clk, output wire hdmi_out_rst_n,
    output reg hdmi_out_hsync, output reg hdmi_out_vsync,
    output reg [23:0] hdmi_out_rgb, output reg hdmi_out_de
);
    wire cfg_clk,locked,init_over;
    reg [15:0] reset_count;
    clk_gen cfg_pll(.clkin1(sys_clk),.rst(~sys_rst_n),.clkout0(cfg_clk),.lock(locked));
    always @(posedge cfg_clk or negedge sys_rst_n)
        if (!sys_rst_n) reset_count<=0;
        else if (!locked) reset_count<=0;
        else if (reset_count<16'd10000) reset_count<=reset_count+1'b1;
    wire chip_reset_n=sys_rst_n && locked && (reset_count==16'd10000);
    assign hdmi_in_rst_n=chip_reset_n;
    assign hdmi_out_rst_n=chip_reset_n;
    ms72xx_shared hdmi_config(.clk(cfg_clk),.rst_n(chip_reset_n),
        .init_over(init_over),.scl(ddc_scl),.sda(ddc_sda));
    // Async assertion, synchronous release in the recovered pixel domain.
    reg [1:0] ready_sync;
    always @(posedge hdmi_in_clk or negedge chip_reset_n)
        if (!chip_reset_n) ready_sync<=0;
        else ready_sync<={ready_sync[0],init_over};
    assign hdmi_out_clk=hdmi_in_clk;
    always @(posedge hdmi_in_clk or negedge chip_reset_n)
        if (!chip_reset_n) begin
            hdmi_out_hsync<=0; hdmi_out_vsync<=0; hdmi_out_de<=0; hdmi_out_rgb<=0;
        end else if (!ready_sync[1]) begin
            hdmi_out_hsync<=0; hdmi_out_vsync<=0; hdmi_out_de<=0; hdmi_out_rgb<=0;
        end else begin
            hdmi_out_hsync<=hdmi_in_hsync; hdmi_out_vsync<=hdmi_in_vsync;
            hdmi_out_de<=hdmi_in_de; hdmi_out_rgb<=hdmi_in_rgb;
        end
endmodule
