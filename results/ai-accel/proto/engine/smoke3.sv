`timescale 1ns/1ps
module smoke3;
  integer fd, rc, n;
  logic [31:0] a, b;
  initial begin
    fd = $fopen("D:/USER/Desktop/FPGA/FPGA/results/ai-accel/proto/engine/probe_fmt.txt", "r");
    if (fd == 0) begin $display("SMOKE3: FAIL open"); $finish; end
    for (n = 0; n < 3; n++) begin
      rc = $fscanf(fd, "%h %h", a, b);
      $display("SMOKE3: rc=%0d a=%h b=%h", rc, a, b);
    end
    rc = $fscanf(fd, "%h %h", a, b);
    $display("SMOKE3: eof rc=%0d", rc);
    $finish;
  end
endmodule
