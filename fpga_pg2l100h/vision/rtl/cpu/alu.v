`timescale 1ns/1ps

module alu (
	a,
	b,
	op,
	out
);
	reg _sv2v_0;
	parameter [31:0] XLEN = 32;
	input wire [XLEN - 1:0] a;
	input wire [XLEN - 1:0] b;
	input wire [4:0] op;
	output reg [XLEN - 1:0] out;
	localparam [31:0] SHAMT_W = $clog2(XLEN);
	wire [XLEN - 1:0] sum;
	wire [XLEN - 1:0] diff;
	wire [XLEN - 1:0] and_out;
	wire [XLEN - 1:0] or_out;
	wire [XLEN - 1:0] xor_out;
	wire [XLEN - 1:0] sll_out;
	wire [XLEN - 1:0] srl_out;
	wire [XLEN - 1:0] sra_out;
	wire slt;
	wire sltu;
	assign sum = a + b;
	assign diff = a - b;
	assign and_out = a & b;
	assign or_out = a | b;
	assign xor_out = a ^ b;
	assign sll_out = a << b[SHAMT_W - 1:0];
	assign srl_out = a >> b[SHAMT_W - 1:0];
	assign sra_out = $signed(a) >>> b[SHAMT_W - 1:0];
	assign slt = $signed(a) < $signed(b);
	assign sltu = a < b;
	wire [XLEN - 1:0] amo_swap;
	wire [XLEN - 1:0] amo_add;
	wire [XLEN - 1:0] amo_xor;
	wire [XLEN - 1:0] amo_and;
	wire [XLEN - 1:0] amo_or;
	wire [XLEN - 1:0] amo_min;
	wire [XLEN - 1:0] amo_max;
	wire [XLEN - 1:0] amo_minu;
	wire [XLEN - 1:0] amo_maxu;
	assign amo_swap = b;
	assign amo_add = a + b;
	assign amo_xor = a ^ b;
	assign amo_and = a & b;
	assign amo_or = a | b;
	assign amo_min = (slt ? a : b);
	assign amo_max = (slt ? b : a);
	assign amo_minu = (sltu ? a : b);
	assign amo_maxu = (sltu ? b : a);
	always @(*) begin
		if (_sv2v_0)
			;
		case (op)
			5'd0: out = sum;
			5'd1: out = diff;
			5'd2: out = and_out;
			5'd3: out = or_out;
			5'd4: out = xor_out;
			5'd5: out = sll_out;
			5'd6: out = srl_out;
			5'd7: out = sra_out;
			5'd8: out = {{XLEN - 1 {1'b0}}, slt};
			5'd9: out = {{XLEN - 1 {1'b0}}, sltu};
			5'd10, 5'd11, 5'd12, 5'd13, 5'd14, 5'd15, 5'd16, 5'd17: out = 1'sb0;
			5'd18: out = amo_swap;
			5'd19: out = amo_add;
			5'd20: out = amo_xor;
			5'd21: out = amo_and;
			5'd22: out = amo_or;
			5'd23: out = amo_min;
			5'd24: out = amo_max;
			5'd25: out = amo_minu;
			5'd26: out = amo_maxu;
			default: out = 1'sbx;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule
