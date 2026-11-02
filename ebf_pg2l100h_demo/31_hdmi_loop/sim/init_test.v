`timescale 1ns/1ps
// Mock successful chip readback and frequency detection; use the real I2C driver.
module init_test;
 reg clk=0,rst=0;always #50 clk=~clk;
 wire done,scl;tri1 sda;
 ms72xx_shared dut(clk,rst,done,scl,sda);
 integer rx_requests=0,tx_requests=0;
 always @(posedge clk)if(dut.start)begin
  if(dut.owner)begin
   if(!dut.rx_done)$fatal(1,"TX started before RX init");
   tx_requests=tx_requests+1;
  end else rx_requests=rx_requests+1;
 end
 initial begin
  force dut.read_data=8'h5a;
  force dut.rx.freq_ensure=1'b1;
  force dut.tx.delay_cnt=22'h30D399;
  #200;rst=1;
  wait(done);
  if(rx_requests<300 || tx_requests<49)$fatal(1,"Incomplete initialization");
  $display("PASS mocked chip initialization RX=%0d TX=%0d",rx_requests,tx_requests);
  $finish;
 end
 initial begin #100000000;$fatal(1,"initialization timeout");end
endmodule
