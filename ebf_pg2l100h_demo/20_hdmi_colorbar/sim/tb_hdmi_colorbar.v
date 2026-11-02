`timescale  1ns/1ns
////////////////////////////////////////////////////////////////////////
// Author        : EmbedFire
// 实验平台: 野火FPGA系列开发板
// 公司    : http://www.embedfire.com
// 论坛    : http://www.firebbs.cn
// 淘宝    : https://fire-stm32.taobao.com
////////////////////////////////////////////////////////////////////////

module  tb_hdmi_colorbar();
//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define

wire            ddc_scl       ;
wire            ddc_sda       ;
wire            hdmi_out_clk  ;
wire            hdmi_out_rst_n;
wire            hdmi_out_hsync;
wire            hdmi_out_vsync;
wire    [23:0]  hdmi_out_rgb  ;
wire            hdmi_out_de   ;

//reg   define
reg             sys_clk     ;
reg             sys_rst_n   ;

//********************************************************************//
//**************************** Clk And Rst ***************************//
//********************************************************************//

//sys_clk,sys_rst_n初始赋值
initial
    begin
        sys_clk     =   1'b1;
        sys_rst_n   <=  1'b0;
        #200
        sys_rst_n   <=  1'b1;
    end

//sys_clk：产生时钟
always  #10 sys_clk = ~sys_clk  ;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//

//------------- vga_colorbar_inst -------------
hdmi_colorbar    hdmi_colorbar_inst
(
    .sys_clk       (sys_clk       ),  //输入晶振时钟,频率50MHz,1bit
    .sys_rst_n     (sys_rst_n     ),  //输入复位信号,低电平有效,1bit
    .ddc_scl       (ddc_scl       ),
    .ddc_sda       (ddc_sda       ),
    .hdmi_out_clk  (hdmi_out_clk  ),
    .hdmi_out_rst_n(hdmi_out_rst_n),
    .hdmi_out_hsync(hdmi_out_hsync),
    .hdmi_out_vsync(hdmi_out_vsync),
    .hdmi_out_rgb  (hdmi_out_rgb  ),
    .hdmi_out_de   (hdmi_out_de   )

);

GTP_GRS GRS_INST (

.GRS_N(1'b1)

);
endmodule

