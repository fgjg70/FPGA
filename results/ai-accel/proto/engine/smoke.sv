`timescale 1ns/1ps
module smoke;
  logic [7:0] a = 8'd3, b = 8'd5;
  logic [15:0] c;
  assign c = a * b;
  initial begin
    #1;
    $display("SMOKE: c=%0d", c);
    if (c == 16'd15) $display("SMOKE: PASS");
    else $display("SMOKE: FAIL");
    $finish;
  end
endmodule
