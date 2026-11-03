module ALU #(parameter W = 32)(
	input	[W-1:0]	a,
	input	[W-1:0]	b,
	input	[3:0]		op,
	
	output	wire		zero,
	output 	reg	[W-1:0]	out,
);

localparam	ALU_ADD = 4'd0;
localparam	ALU_SUB = 4'd1;
localparam	ALU_AND = 4'd2;
localparam	ALU_OR = 4'd3;
localparam	ALU_XOR = 4'd4;
localparam	ALU_SLL = 4'd5;		//逻辑左移
localparam	ALU_SRL = 4'd6;		//逻辑右移
localparam	ALU_SRA = 4'd7;		//算术右移
localparam	ALU_SLT = 4'd8;		//小于
localparam	ALU_SLTU = 4'd9;	//无符号小于

wire [W-1:0] sum = a + b;
wire [W-1:0] diff = a - b;
wire [W-1:0] and_out = a & b;
wire [W-1:0] or_out = a | b;
wire [W-1:0] xor_out = a ^ b;
wire [W-1:0] sll_out = a << b[4:0];
wire [W-1:0] srl_out = a >> b[4:0];
wire [W-1:0] sra_out = $signed(a) >>> b[4:0];
wire	slt_out = ($signed(a) < $signed(b)) ? 1'd1 : 1'd0;
wire	sltu_out = (a < b) ? 1'd1 : 1'd0;

always @(*) begin
	case (op)
		ALU_ADD:	out = sum;
		ALU_SUB:	out = diff;
		ALU_AND:	out = and_out;
		ALU_OR:		out = or_out;
		ALU_XOR:	out = xor_out;
		ALU_SLL:	out = sll_out;
		ALU_SRL:	out = srl_out;
		ALU_SRA:	out = sra_out;
		ALU_SLT:	out = slt_out;
		ALU_SLTU:	out = sltu_out;
		default:	out = '0;
	endcase
end

assign zero = (out == '0) ? 1'b1 : 1'b0;

endmodule