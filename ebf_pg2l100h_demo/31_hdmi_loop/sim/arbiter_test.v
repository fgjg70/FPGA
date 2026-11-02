`timescale 1ns/1ps
module arbiter_test;
 reg clk=0,rst=0,rq=0,tq=0;always #50 clk=~clk;
 wire done,scl;tri1 sda;
 ms72xx_shared dut(clk,rst,done,scl,sda);
 integer count=0;
 always @(posedge clk)if(dut.start)begin
  count=count+1;
  if(count==1 && dut.owner!==0)$fatal(1,"RX first");
  if(count==2 && dut.owner!==1)$fatal(1,"TX request lost");
  if(count==3 && dut.owner!==0)$fatal(1,"RX polling lost");
 end
 initial begin
  force dut.rx_trigger=rq;force dut.tx_trigger=tq;
  force dut.rx_done=1;
  #200;rst=1;repeat(5)@(negedge clk);
  rq=1;tq=1;@(negedge clk);rq=0;tq=0;
  wait(count==2);wait(!dut.inflight);repeat(5)@(negedge clk);
  rq=1;@(negedge clk);rq=0;
  wait(count==3);wait(!dut.inflight);
  $display("PASS simultaneous requests and subsequent RX polling");$finish;
 end
 initial begin #2000000;$fatal(1,"arbiter timeout");end
endmodule
