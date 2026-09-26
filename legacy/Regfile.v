module Regfile #(
    parameter WIDTH = 32,
    parameter DEPTH = 32
)(
    input	clk,

    input	we,
    input	[$clog2(DEPTH)-1:0]	waddr,
    input	[WIDTH-1:0]	wdata,

    input	[$clog2(DEPTH)-1:0]	raddr1,
    input	[$clog2(DEPTH)-1:0]	raddr2,
    output reg	[WIDTH-1:0]	rdata1,
    output reg	[WIDTH-1:0]	rdata2
);

reg	[WIDTH-1:0]	mem [0:DEPTH-1];

always @(posedge clk) begin
	if (we&&(waddr != '0)) begin
		mem[waddr] <= wdata;
	end
end

always @(*) begin
	rdata1 = raddr1 == '0 ? '0: mem[raddr1];
	rdata2 = raddr2 == '0 ? '0: mem[raddr2];
end

endmodule