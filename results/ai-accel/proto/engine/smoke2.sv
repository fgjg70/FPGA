`timescale 1ns/1ps
// probe ModelSim support: hierarchical $readmemh with @addr, $fscanf mixed format
module smoke2;
  logic [31:0] wq [0:7];
  logic [63:0] amem [0:3];
  string name;
  int a, b, c;
  integer fd, rc;
  initial begin
    for (int i = 0; i < 8; i++) wq[i] = 32'hDEAD_BEEF;
    for (int i = 0; i < 4; i++) amem[i] = 64'hDEAD_BEEF_DEAD_BEEF;
    $readmemh("D:/USER/Desktop/FPGA/FPGA/results/ai-accel/proto/engine/probe_wq.hex", wq);
    $readmemh("D:/USER/Desktop/FPGA/FPGA/results/ai-accel/proto/engine/probe_a.hex", amem);
    $display("SMOKE2: wq0=%h wq1=%h wq3=%h wq7=%h", wq[0], wq[1], wq[3], wq[7]);
    $display("SMOKE2: a0=%h a1=%h a2=%h a3=%h", amem[0], amem[1], amem[2], amem[3]);
    fd = $fopen("D:/USER/Desktop/FPGA/FPGA/results/ai-accel/proto/engine/probe_manifest.txt", "r");
    if (fd == 0) begin $display("SMOKE2: FAIL open"); $finish; end
    rc = $fscanf(fd, "%s %d %d %d", name, a, b, c);
    $display("SMOKE2: rc=%0d name=%s a=%0d b=%0d c=%0d", rc, name, a, b, c);
    rc = $fscanf(fd, "%s %d %d %d", name, a, b, c);
    $display("SMOKE2: rc=%0d name=%s a=%0d b=%0d c=%0d", rc, name, a, b, c);
    $finish;
  end
endmodule
