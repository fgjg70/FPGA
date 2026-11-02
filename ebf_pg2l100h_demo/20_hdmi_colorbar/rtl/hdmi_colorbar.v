`timescale  1ns/1ns
////////////////////////////////////////////////////////////////////////
// Author        : EmbedFire
// 实验平台: 野火FPGA系列开发板
// 公司    : http://www.embedfire.com
// 论坛    : http://www.firebbs.cn
// 淘宝    : https://fire-stm32.taobao.com
////////////////////////////////////////////////////////////////////////

module  hdmi_colorbar
(
    input   wire            sys_clk     ,   //输入工作时钟,频率50MHz
    input   wire            sys_rst_n   ,   //输入复位信号,低电平有效

    output  wire            ddc_scl         ,
    inout   wire            ddc_sda         ,
    output  wire            hdmi_out_clk    ,
    output  wire            hdmi_out_rst_n  ,
    output  wire            hdmi_out_hsync  ,   //输出行同步信号
    output  wire            hdmi_out_vsync  ,   //输出场同步信号
    output  wire    [23:0]  hdmi_out_rgb    ,   //输出像素信息
    output  wire            hdmi_out_de     
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire define
wire            locked  ;   //PLL locked信号
wire            rst_n   ;   //VGA模块复位信号
wire    [11:0]  pix_x   ;   //VGA有效显示区域X轴坐标
wire    [11:0]  pix_y   ;   //VGA有效显示区域Y轴坐标
wire    [15:0]  pix_data;   //VGA像素点色彩信息
wire    [15:0]  rgb     ;   //输出像素信息

//rst_n:VGA模块复位信号
assign  rst_n   = (sys_rst_n & locked);
// Hold MS7210 in reset for 1 ms after PLL lock (50 MHz system clock).
reg [15:0] reset_count;
reg [1:0] lock_sync;
always @(posedge sys_clk or negedge sys_rst_n)
    if (!sys_rst_n) begin
        lock_sync <= 2'b00;
        reset_count <= 16'd0;
    end else begin
        lock_sync <= {lock_sync[0], locked};
        if (!lock_sync[1]) reset_count <= 16'd0;
        else if (reset_count < 16'd50000)
            reset_count <= reset_count + 1'b1;
    end
assign hdmi_out_rst_n = sys_rst_n && lock_sync[1] && (reset_count == 16'd50000);
// Register data and all three qualifiers together. Forward the complementary
// PLL clock so the MS7210 rising edge falls between pixel launch edges.
wire pixel_clk, raw_hsync, raw_vsync, raw_de;
wire cfg_done;
reg [26:0] video_out;
always @(posedge pixel_clk or negedge rst_n)
    if (!rst_n) video_out <= {1'b0, 1'b1, 1'b0, 24'd0};
    else video_out <= {raw_hsync, raw_vsync, raw_de,
        rgb[15:11], 3'b0, rgb[10:5], 2'b0, rgb[4:0], 3'b0};
assign {hdmi_out_hsync, hdmi_out_vsync, hdmi_out_de, hdmi_out_rgb} = video_out;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//

//------------- clk_gen_inst -------------
clk_gen clk_gen_inst(
    .clkin1  (sys_clk       ),//输入50MHz晶振时钟,1bit
    .rst     (~sys_rst_n    ),//复位信号,高电平有效
    .clkout0 (pixel_clk     ),
    .clkout0_n(hdmi_out_clk),//输出VGA工作时钟,频率148.5MHz,1bit

    .lock    (locked        )//输出pll locked信号,1bit
    );

hdmi_i2c hdmi_i2c_inst
(
    .sys_clk   (sys_clk        ),   //系统时钟
    .sys_rst_n (hdmi_out_rst_n ),   //复位信号
    .cfg_done  (cfg_done       ),   //寄存器配置完成
    .sccb_scl  (ddc_scl        ),   //SCL
    .sccb_sda  (ddc_sda        )    //SDA
);

//------------- vga_ctrl_inst -------------
vga_ctrl  vga_ctrl_inst
(
    .vga_clk     (pixel_clk     ),  //输入工作时钟,频率148.5MHz,1bit
    .sys_rst_n   (rst_n         ),  //输入复位信号,低电平有效,1bit
    .pix_data    (pix_data      ),  //输入像素点色彩信息,16bit

    .pix_x       (pix_x         ),  //输出VGA有效显示区域像素点X轴坐标,10bit
    .pix_y       (pix_y         ),  //输出VGA有效显示区域像素点Y轴坐标,10bit
    .hsync       (raw_hsync     ),  //输出行同步信号,1bit
    .vsync       (raw_vsync     ),  //输出场同步信号,1bit
    .rgb_valid   (raw_de        ),
    .rgb         (rgb           )   //输出像素点色彩信息,16bit
);

//------------- vga_pic_inst -------------
vga_pic vga_pic_inst
(
    .vga_clk    (pixel_clk      ),  //输入工作时钟,频率148.5MHz,1bit
    .sys_rst_n  (rst_n          ),  //输入复位信号,低电平有效,1bit
    .pix_x      (pix_x          ),  //输入VGA有效显示区域像素点X轴坐标,10bit
    .pix_y      (pix_y          ),  //输入VGA有效显示区域像素点Y轴坐标,10bit

    .pix_data   (pix_data       )   //输出像素点色彩信息,16bit

);

endmodule
