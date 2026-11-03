module PC#
(
    parameter WIDTH = 32
    parameter RESET_VALUE = 32'h0000_0000
)(
    input	clk,
    input	rst,
    
    input   stall,

    input   pc_src,                 //0:pc+4, 1:pc_target
    input	[WIDTH-1:0]	pc_target,
    
    output reg	[WIDTH-1:0]	pc,
    output reg	[WIDTH-1:0]	pc_plus4
);

assign pc_plus4 = pc + {{(WIDTH-3){1'b0}}, 3'd4};

wire [WIDTH-1:0] next_pc = pc_src ? pc_target : pc_plus4;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pc <= RESET_VALUE;
    end 
    else if (!stall) begin
        pc <= next_pc;
    end
end