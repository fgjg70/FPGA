`timescale 1ns/1ps
module clk_gen(input clkin1,input rst,output clkout0,output lock);
 assign clkout0=clkin1;assign lock=!rst;
endmodule
module test;
 reg clk=0,rst=0,pclk=0;always #50 clk=~clk;always #3.367 pclk=~pclk;
 reg [23:0] rgb=0;reg hs=0,vs=0,de=0;
 wire [23:0] out;wire oh,ov,od,oc,ir,tr,scl;tri1 sda;
 hdmi_loop dut(clk,rst,scl,sda,pclk,ir,hs,vs,rgb,de,oc,tr,oh,ov,out,od);
 integer n;
 initial begin
  force dut.hdmi_config.rx_trigger=0;force dut.hdmi_config.tx_trigger=0;
  #200;rst=1;
  wait(ir);if(!tr)$fatal(1,"resets differ");
  repeat(4)@(negedge pclk);
  if(out!==0 || od!==0)$fatal(1,"video enabled before init");
  force dut.init_over=1;
  repeat(4)@(negedge pclk);
  for(n=0;n<100;n=n+1)begin
   rgb=$random;hs=$random;vs=$random;de=$random;
   @(posedge pclk);#1;
   if({out,oh,ov,od}!=={rgb,hs,vs,de})$fatal(1,"video mismatch");
   if(oc!==pclk)$fatal(1,"clock mismatch");
   @(negedge pclk);
  end
  rst=0;#1;if(out!==0 || ir!==0 || tr!==0)$fatal(1,"reset failed");
  $display("PASS reset, initialization gating and 100 video samples");$finish;
 end
 initial begin #2000000;$fatal(1,"timeout");end
endmodule
