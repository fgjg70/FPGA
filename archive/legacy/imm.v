module imm #(
    parameter WIDTH = 32
)(
    input [WIDTH-1:0]	instr,
    input [2:0]   fmt,

    output reg	[WIDTH-1:0]	imm_out
);
    
localparam FMT_I = 3'b000;
localparam FMT_S = 3'b001;
localparam FMT_B = 3'b010;
localparam FMT_U = 3'b011;
localparam FMT_J = 3'b100;

always @(*) begin
    case (fmt)
        FMT_I:  imm_out = {{20{instr[31]}}, instr[31:20]};
        FMT_S:  imm_out = {{20{instr[31]}}, instr[31:25], instr[11:7]};
        FMT_B:  imm_out = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
        FMT_U:  imm_out = {instr[31:12], {12{1'b0}}};
        FMT_J:  imm_out = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
        default:imm_out = '0;
    endcase
end

endmodule