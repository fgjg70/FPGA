module branch_unit#(
    parameter WIDTH = 32
)(
    input [WIDTH-1:0] rs1,
    input [WIDTH-1:0] rs2,
    input [2:0] branch_type,

    output reg branch_taken
);

wire eq = (rs1 == rs2);
wire lt_s = ($signed(rs1) < $signed(rs2));
wire lt_u = (rs1 < rs2);

always @(*) begin
    case (branch_type)
        3'b000: branch_taken = eq; // BEQ
        3'b001: branch_taken = ~eq; // BNE
        3'b100: branch_taken = lt_s; // BLT
        3'b101: branch_taken = ~lt_s; // BGE
        3'b110: branch_taken = lt_u; // BLTU
        3'b111: branch_taken = ~lt_u; // BGEU
        default: branch_taken = 1'b0;
    endcase
end

endmodule