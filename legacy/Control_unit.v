module control_unit#(
    parameter WIDTH = 32
)(
    input [WIDTH-1:0] instr,

    output reg reg_write,
    output reg mem_read,
    output reg mem_write,
    output reg mem_to_reg,
    output reg alu_src,
    output reg alu_src_pc,
    output reg branch,
    output reg jump,
    output reg jalr,
    output reg [2:0] imm_fmt,
    output reg [3:0] alu_op,
    output reg [2:0] branch_type,
    output reg [1:0] mem_size,
    output reg mem_unsigned,
    output reg [1:0] wb_src

);

wire [6:0] opcode = instr[6:0];
wire [2:0] funct3 = instr[14:12];
wire [6:0] funct7 = instr[31:25];

//opcode编码
localparam R_TYPE = 7'b0110011;
localparam I_TYPE = 7'b0010011;
localparam LOAD = 7'b0000011;
localparam STORE = 7'b0100011;
localparam BRANCH = 7'b1100011;
localparam LUI = 7'b0110111;
localparam AUIPC = 7'b0010111;
localparam JAL = 7'b1101111;
localparam JALR = 7'b1100111;

//立即数编码
localparam IMM_I = 3'b000;
localparam IMM_S = 3'b001;
localparam IMM_B = 3'b010;
localparam IMM_U = 3'b011;
localparam IMM_J = 3'b100;

//ALU操作编码
localparam ALU_ADD = 4'b0000;
localparam ALU_SUB = 4'b0001;
localparam ALU_AND = 4'b0010;
localparam ALU_OR = 4'b0011;
localparam ALU_XOR = 4'b0100;
localparam ALU_SLL = 4'b0101;
localparam ALU_SRL = 4'b0110;
localparam ALU_SRA = 4'b0111;
localparam ALU_SLT = 4'b1000;
localparam ALU_SLTU = 4'b1001;

//分支类型编码
localparam BEQ = 3'b000;
localparam BNE = 3'b001;
localparam BLT = 3'b100;
localparam BGE = 3'b101;
localparam BLTU = 3'b110;
localparam BGEU = 3'b111;

//内存访问大小编码
localparam MEM_BYTE = 2'b00;
localparam MEM_HALF = 2'b01;
localparam MEM_WORD = 2'b10;

always @(*) begin
    //默认值
    reg_write = 0;
    mem_read = 0;
    mem_write = 0;
    mem_to_reg = 0;
    alu_src = 0;
    alu_src_pc = 0;
    branch = 0;
    jump = 0;
    jalr = 0;
    imm_fmt = IMM_I; //默认立即数格式为I型
    alu_op = ALU_ADD; //默认ALU操作为加法
    mem_size = MEM_BYTE; //默认内存访问大小为字节
    branch_type = BEQ; //默认分支类型为BEQ

    case (opcode)
        R_TYPE: begin
            reg_write = 1;
            alu_src = 0; //寄存器操作数
            wb_src = 2'b00; //写回数据来自ALU
            case (funct3)
                3'b000: alu_op = (funct7 == 7'b0100000) ? ALU_SUB : ALU_ADD; //ADD/SUB
                3'b111: alu_op = ALU_AND; //AND
                3'b110: alu_op = ALU_OR; //OR
                3'b100: alu_op = ALU_XOR; //XOR
                3'b001: alu_op = ALU_SLL; //SLL
                3'b101: alu_op = (funct7 == 7'b0100000) ? ALU_SRA : ALU_SRL; //SRL/SRA
                3'b010: alu_op = ALU_SLT; //SLT
                3'b011: alu_op = ALU_SLTU; //SLTU
            endcase
        end
        I_TYPE: begin
            reg_write = 1;
            alu_src = 1; //立即数操作数
            wb_src = 2'b00; //写回数据来自ALU
            imm_fmt = IMM_I; //立即数格式为I型
            case (funct3)
                3'b000: alu_op = ALU_ADD; //ADDI
                3'b111: alu_op = ALU_AND; //ANDI
                3'b110: alu_op = ALU_OR; //ORI
                3'b100: alu_op = ALU_XOR; //XORI
                3'b001: alu_op = ALU_SLL; //SLLI
                3'b101: alu_op = (funct7 == 7'b0100000) ? ALU_SRA : ALU_SRL; //SRLI/SRAI
                3'b010: alu_op = ALU_SLT; //SLTI
                3'b011: alu_op = ALU_SLTU; //SLTIU
            endcase
        end
        LOAD: begin
            reg_write = 1;
            mem_read = 1;
            mem_to_reg = 1;
            alu_src = 1; //立即数操作数
            imm_fmt = IMM_L; //立即数格式为L型
            wb_src = 2'b01; //写回数据来自ALU
            case (funct3)
                3'b000: begin
                    mem_size = MEM_BYTE; //LB
                    mem_unsigned = 0;
                end
                3'b001: begin
                    mem_size = MEM_HALF; //LH
                    mem_unsigned = 0;
                end
                3'b010: begin
                    mem_size = MEM_WORD; //LW
                    mem_unsigned = 0;
                end
                3'b100: begin
                    mem_size = MEM_BYTE; //LBU
                    mem_unsigned = 1;
                end
                3'b101: begin
                    mem_size = MEM_HALF; //LHU
                    mem_unsigned = 1;
                end
                default: begin
                    mem_size = MEM_BYTE; //默认字节访问
                    mem_unsigned = 0;
                end
            endcase
        end
        STORE: begin
            mem_write = 1;
            alu_src = 1; //立即数操作数
            imm_fmt = IMM_S; //立即数格式为S型
            case (funct3)
                3'b000: mem_size = MEM_BYTE; //SB
                3'b001: mem_size = MEM_HALF; //SH
                3'b010: mem_size = MEM_WORD; //SW
                default: mem_size = MEM_BYTE; //默认字节访问
            endcase
        end
        BRANCH: begin
            branch = 1;
            alu_src = 0; //寄存器操作数
            imm_fmt = IMM_B; //立即数格式为B型
            case (funct3)
                3'b000: branch_type = BEQ; //BEQ
                3'b001: branch_type = BNE; //BNE
                3'b100: branch_type = BLT; //BLT
                3'b101: branch_type = BGE; //BGE
                3'b110: branch_type = BLTU; //BLTU
                3'b111: branch_type = BGEU; //BGEU
                default: branch_type = BEQ; //默认BEQ
            endcase
        end
        LUI: begin
            reg_write = 1;
            alu_src = 1; //立即数操作数
            imm_fmt = IMM_U; //立即数格式为U型
            alu_op = ALU_ADD; //LUI使用加法操作
        end
        AUIPC: begin
            reg_write = 1;
            alu_src = 1; //立即数操作数
            imm_fmt = IMM_U; //立即数格式为U型
            alu_op = ALU_ADD; //AUIPC使用加法操作
        end
        JAL: begin
            reg_write = 1;
            jump = 1;
            jalr = 1;
            imm_fmt = IMM_J; //立即数格式为J型
            wb_src = 2'b10; //写回数据来自PC+4
        end
        JALR: begin
            reg_write = 1;
            jump = 1;
            jalr = 1;
            alu_src = 1; //立即数操作数
            imm_fmt = IMM_I; //立即数格式为I型
            alu_op = ALU_ADD; //JALR使用加法操作
        end
        default: begin
            //保持默认值
        end
    endcase
end

endmodule