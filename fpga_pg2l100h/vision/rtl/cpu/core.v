`timescale 1ns/1ps

module core #(
	parameter EXTERNAL_WAIT = 0
) (
	clk,
	rst,
	dbg_pc,
	dbg_id_pc,
	dbg_instr,
	dbg_illegal,
	dbg_raddr,
	dbg_rdata,
	dbg_mem_we,
	dbg_mem_addr,
	dbg_mem_wdata,
	dbg_stall,
	dbg_redirect,
	ext_we,
	ext_re,
	ext_addr,
	ext_wdata,
	ext_wstrb,
	ext_rdata,
	ext_ready,
	irq_timer
);
	reg _sv2v_0;
	input wire clk;
	input wire rst;
	output wire [31:0] dbg_pc;
	output wire [31:0] dbg_id_pc;
	output wire [31:0] dbg_instr;
	output reg dbg_illegal;
	input wire [4:0] dbg_raddr;
	output wire [31:0] dbg_rdata;
	output wire dbg_mem_we;
	output wire [31:0] dbg_mem_addr;
	output wire [31:0] dbg_mem_wdata;
	output wire dbg_stall;
	output wire dbg_redirect;
	output wire ext_we;
	output wire ext_re;
	output wire [31:0] ext_addr;
	output wire [31:0] ext_wdata;
	output wire [3:0] ext_wstrb;
	input wire [31:0] ext_rdata;
	input wire ext_ready;
	input wire irq_timer;
	wire [31:0] pc;
	wire [31:0] pc_plus4;
	wire [31:0] pc_target;
	wire [31:0] imem_rdata;
	(* max_fanout = 16 *) wire pc_src;
	(* max_fanout = 16 *) wire redirect;
	(* max_fanout = 16 *) wire redirect_raw;
	wire lsu_stall;
	wire amo_write_phase;
	wire [31:0] amo_old;
	wire amo_is_lr;
	wire amo_is_sc;
	wire id_ex_bubble;
	wire pred_hit;
	wire pred_taken;
	wire btb_upd_en;
	wire is_ctrl_flow;
	wire [31:0] pred_target;
	wire [31:0] actual_target;
	wire pred_is_ret;
	wire ex_is_call;
	wire ex_is_ret;
	wire ex_is_cond;
	(* max_fanout = 16 *) wire actual_taken;
	(* max_fanout = 16 *) wire pred_ok;
	wire [31:0] btb_pred_target;
	wire [15:0] btb_align_err;
	wire [31:0] if_pc;
	wire [31:0] if_pc_plus4;
	wire [31:0] if_instr;
	wire if_pred_taken;
	wire [31:0] if_pred_target;
	reg [55:0] id_ctrl;
	wire [55:0] id_ctrl_raw;
	wire id_en;
	wire [31:0] id_imm;
	wire [31:0] id_rs1_data;
	wire [31:0] id_rs2_data;
	wire [4:0] id_rs1;
	wire [4:0] id_rs2;
	wire [4:0] id_rd;
	wire [55:0] id_ex_ctrl;
	wire id_ex_valid;
	wire [31:0] id_ex_instr;
	wire [31:0] id_ex_pc;
	wire [31:0] id_ex_pc_plus4;
	wire [31:0] id_ex_rs1_data;
	wire [31:0] id_ex_rs2_data;
	wire [31:0] id_ex_imm;
	wire [4:0] id_ex_rs1;
	wire [4:0] id_ex_rs2;
	wire [4:0] id_ex_rd;
	wire id_ex_pred_taken;
	wire [31:0] id_ex_pred_target;
	reg [31:0] id_ex_jr_p;
	wire [1:0] fwd_a_pre;
	wire [1:0] fwd_b_pre;
	(* max_fanout = 16 *) reg [1:0] id_ex_fwd_a;
	(* max_fanout = 16 *) reg [1:0] id_ex_fwd_b;
	reg [31:0] ex_rs1;
	reg [31:0] ex_rs2;
	reg [31:0] ex_a;
	reg [31:0] ex_b;
	wire [31:0] ex_alu_out;
	wire [31:0] ex_pc_target;
	reg [31:0] ex_amo_addr;
	wire [31:0] ex_result;
	wire [31:0] md_result;
	wire md_busy;
	reg is_muldiv;
	reg [31:0] md_a_r;
	reg [31:0] md_b_r;
	reg [4:0] md_op_r;
	reg md_served;
	wire md_busy_raw;
	wire ex_taken;
	wire [31:0] csr_rdata;
	wire [31:0] csr_wdata;
	wire [31:0] csr_src;
	wire csr_we;
	wire is_csr;
	wire exc_req;
	wire irq_take;
	wire trap_req;
	wire trap_enter;
	wire trap_redir;
	wire mret_req_int;
	(* max_fanout = 16 *) wire any_redir;
	wire [4:0] trap_cause;
	wire [4:0] irq_cause;
	wire [3:0] exc_cause;
	wire [31:0] trap_vector;
	wire [31:0] mret_pc;
	wire [31:0] trap_tval;
	wire irq_pending;
	wire mret_taken;
	wire is_mret;
	wire [55:0] ex_mem_ctrl;
	wire [31:0] ex_mem_alu_out;
	wire [31:0] ex_mem_store_data;
	wire [31:0] ex_mem_pc_plus4;
	wire [4:0] ex_mem_rd;
	wire [31:0] dmem_addr;
	wire [31:0] dmem_wdata;
	wire [31:0] dmem_rdata;
	wire [31:0] mem_load_data;
	wire [3:0] dmem_wstrb;
	wire dmem_we;
	wire sel_dmem;
	wire dmem_we_g;
	wire [31:0] dmem_rdata_g;
	reg sel_dmem_r;
	reg [31:0] ext_rdata_r;
	wire [55:0] mem_wb_ctrl;
	wire [31:0] mem_wb_alu_out;
	wire [31:0] mem_wb_load_data;
	wire [31:0] mem_wb_pc_plus4;
	wire [4:0] mem_wb_rd;
	(* max_fanout = 16 *) wire [1:0] mem_wb_wb_src;
	assign mem_wb_wb_src = mem_wb_ctrl[36-:2];
	reg [31:0] wb_data;
	reg [31:0] wait_wb_data;
	reg external_wait_active;
	wire external_wait = EXTERNAL_WAIT && (ext_we || ext_re) && !ext_ready;
	wire [4:0] wb_rd;
	wire wb_reg_write;
	wire pipe_stall;
	wire if_id_flush;
	wire hold_mem;
	wire br_redir;
	wire br_redir_eff;
	reg br_redir_r;
	wire redir_flush;
	wire pc_flush;
	wire redir_kill;
	wire id_ex_flush;
	reg [31:0] br_tgt_r;
	wire [31:0] pc_flush_pc;
	wire fetch_hold;
	reg boot_done;
	always @(posedge clk or posedge rst)
		if (rst)
			boot_done <= 1'b0;
		else
			boot_done <= 1'b1;
	assign fetch_hold = pipe_stall || !boot_done;
	localparam [31:0] rv32_pkg_PC_RESET = 32'h80000000;
	localparam [31:0] rv32_pkg_XLEN = 32;
	pc #(
		.XLEN(rv32_pkg_XLEN),
		.RESET_PC(rv32_pkg_PC_RESET)
	) u_pc(
		.clk(clk),
		.rst(rst),
		.stall(fetch_hold),
		.flush(pc_flush),
		.flush_pc(pc_flush_pc),
		.pc_src(pc_src),
		.pc_target(pc_target),
		.pc(pc),
		.pc_plus4(pc_plus4)
	);
	wire [31:0] imem_addr;
	wire [31:0] pc_next = (pc_flush ? pc_flush_pc : (fetch_hold ? pc : (pc_src ? pc_target : pc_plus4)));
	assign imem_addr = pc_next;
	wire [31:0] p2_pc_ns = (pc_flush ? pc_flush_pc : (pc_src ? pc_target : pc_plus4));
	wire p2_hold = fetch_hold && !pc_flush;
	localparam [31:0] rv32_pkg_IMEM_BASE = 32'h80000000;
	localparam [31:0] rv32_pkg_IMEM_BYTES = 16384;
	imem #(
		.BASE(rv32_pkg_IMEM_BASE),
		.BYTES(rv32_pkg_IMEM_BYTES)
	) u_imem(
		.clk(clk),
		.addr(imem_addr),
		.rdata(imem_rdata)
	);
	assign if_id_flush = any_redir;
	btb #(
		.IDX_BITS(9),
		.PC_TOP(14),
		.PC_BASE(rv32_pkg_IMEM_BASE)
	) u_btb(
		.clk(clk),
		.rst(rst),
		.pred_pc(32'd0),
		.pred_hit(),
		.pred_taken(),
		.pred_target(),
		.pred_is_ret(),
		.p2_pc(p2_pc_ns),
		.p2_hold(p2_hold),
		.p2_pc_pht(pc_next),
		.q_hit(pred_hit),
		.q_taken(pred_taken),
		.q_target(btb_pred_target),
		.q_is_ret(pred_is_ret),
		.upd_en(btb_upd_en),
		.upd_pc(id_ex_pc),
		.upd_taken(actual_taken),
		.upd_target(ex_pc_target),
		.upd_is_ret(ex_is_ret),
		.upd_is_cond(ex_is_cond),
		.align_err_cnt(btb_align_err)
	);
	assign ex_is_cond = id_ex_ctrl[44-:2] == 2'd1;
	assign ex_is_call = 1'b0;
	assign ex_is_ret = 1'b0;
	assign pred_target = btb_pred_target;
	assign is_ctrl_flow = id_ex_ctrl[44-:2] != 2'd0;
	assign btb_upd_en = ((is_ctrl_flow && !hold_mem) && !rst) && !redir_kill;
	assign if_pc = pc;
	assign if_pc_plus4 = pc_plus4;
	assign if_instr = imem_rdata;
	assign if_pred_taken = pred_taken;
	assign if_pred_target = pred_target;
	assign id_en = boot_done;
	assign id_rs1 = if_instr[19:15];
	assign id_rs2 = if_instr[24:20];
	assign id_rd = if_instr[11:7];
	control_unit u_ctrl(
		.instr(if_instr),
		.ctrl(id_ctrl_raw)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		id_ctrl = (id_en ? id_ctrl_raw : 56'd0);
	end
	imm_gen u_imm(
		.instr(if_instr),
		.fmt(id_ctrl[34-:3]),
		.imm_out(id_imm)
	);
	regfile #(
		.XLEN(rv32_pkg_XLEN),
		.NUM_REGS(32)
	) u_regfile(
		.clk(clk),
		.we(wb_reg_write),
		.waddr(wb_rd),
		.wdata(wb_data),
		.raddr1(id_rs1),
		.raddr2(id_rs2),
		.rdata1(id_rs1_data),
		.rdata2(id_rs2_data),
		.dbg_raddr(dbg_raddr),
		.dbg_rdata(dbg_rdata)
	);
	id_ex_reg u_id_ex(
		.clk(clk),
		.rst(rst),
		.flush(id_ex_flush),
		.stall(pipe_stall),
		.bubble(id_ex_bubble),
		.valid_in(id_en),
		.instr_in(if_instr),
		.ctrl_in(id_ctrl),
		.pc_in(if_pc),
		.pc_plus4_in(if_pc_plus4),
		.rs1_data_in(id_rs1_data),
		.rs2_data_in(id_rs2_data),
		.imm_in(id_imm),
		.rs1_addr_in(id_rs1),
		.rs2_addr_in(id_rs2),
		.rd_addr_in(id_rd),
		.pred_taken_in(if_pred_taken),
		.pred_target_in(if_pred_target),
		.ctrl(id_ex_ctrl),
		.valid(id_ex_valid),
		.instr(id_ex_instr),
		.pc(id_ex_pc),
		.pc_plus4(id_ex_pc_plus4),
		.rs1_data(id_ex_rs1_data),
		.rs2_data(id_ex_rs2_data),
		.imm(id_ex_imm),
		.rs1_addr(id_ex_rs1),
		.rs2_addr(id_ex_rs2),
		.rd_addr(id_ex_rd),
		.pred_taken(id_ex_pred_taken),
		.pred_target(id_ex_pred_target)
	);
	wire [31:0] ex_mem_fwd_data = (ex_mem_ctrl[36-:2] == 2'd2 ? ex_mem_pc_plus4 : ex_mem_alu_out);
	wire [31:0] amo_wb_value = 32'd0;
	wire [31:0] fwd_wb_data = (mem_wb_wb_src != 2'd1 ? (mem_wb_wb_src == 2'd2 ? mem_wb_pc_plus4 : mem_wb_alu_out) : (mem_wb_ctrl[42] ? mem_wb_load_data : amo_wb_value));
	always @(*) begin
		if (_sv2v_0)
			;
		ex_rs1 = (id_ex_fwd_a == 2'd1 ? ex_mem_fwd_data : (id_ex_fwd_a == 2'd2 ? fwd_wb_data : id_ex_rs1_data));
		ex_rs2 = (id_ex_fwd_b == 2'd1 ? ex_mem_fwd_data : (id_ex_fwd_b == 2'd2 ? fwd_wb_data : id_ex_rs2_data));
		ex_a = (id_ex_ctrl[50-:2] == 2'd1 ? id_ex_pc : (id_ex_ctrl[50-:2] == 2'd2 ? 32'd0 : ex_rs1));
		ex_b = (id_ex_ctrl[48] == 1'b1 ? id_ex_imm : ex_rs2);
		ex_amo_addr = ex_rs1;
	end
	alu #(.XLEN(rv32_pkg_XLEN)) u_alu(
		.a(ex_a),
		.b(ex_b),
		.op(id_ex_ctrl[55-:5]),
		.out(ex_alu_out)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		case (id_ex_ctrl[55-:5])
			5'd10, 5'd11, 5'd12, 5'd13, 5'd14, 5'd15, 5'd16, 5'd17: is_muldiv = 1'b1;
			default: is_muldiv = 1'b0;
		endcase
	end
	wire is_muldiv_eff = is_muldiv && !redir_kill;
	wire md_start = is_muldiv_eff && !md_served;
	wire md_done = md_served && !md_busy_raw;
	wire [4:0] md_op_eff = (md_served ? md_op_r : 5'd0);
	assign md_busy = md_start || (md_served && !md_done);
	always @(posedge clk or posedge rst)
		if (rst) begin
			md_a_r <= 32'd0;
			md_b_r <= 32'd0;
			md_op_r <= 5'd0;
			md_served <= 1'b0;
		end
		else begin
			if (md_start) begin
				md_a_r <= ex_rs1;
				md_b_r <= ex_rs2;
				md_op_r <= id_ex_ctrl[55-:5];
			end
			md_served <= md_start | (md_served & ~md_done);
		end
	muldiv #(.XLEN(rv32_pkg_XLEN)) u_muldiv(
		.clk(clk),
		.rst(rst),
		.op(md_op_eff),
		.a(md_a_r),
		.b(md_b_r),
		.result(md_result),
		.busy(md_busy_raw)
	);
	assign ex_result = (is_muldiv ? md_result : (is_csr ? csr_rdata : (id_ex_ctrl[7] ? ex_amo_addr : ex_alu_out)));
	branch_unit #(.XLEN(rv32_pkg_XLEN)) u_branch(
		.rs1(ex_rs1),
		.rs2(ex_rs2),
		.branch_type(id_ex_ctrl[47-:3]),
		.taken(ex_taken)
	);
	wire [31:0] ex_ctrl_operand_a = (id_ex_ctrl[44-:2] == 2'd3 ? ex_rs1 : id_ex_pc);
	wire [31:0] ex_ctrl_sum = ex_ctrl_operand_a + id_ex_imm;
	wire [31:0] ex_jr_diff = ex_rs1 - id_ex_jr_p;
	wire ex_jr_match = ex_jr_diff[31:1] == 31'd0;
	assign ex_pc_target = (id_ex_ctrl[44-:2] == 2'd3 ? {ex_ctrl_sum[31:1], 1'b0} : ex_ctrl_sum);
	assign actual_taken = (((id_ex_ctrl[44-:2] == 2'd1) && ex_taken) || (id_ex_ctrl[44-:2] == 2'd2)) || (id_ex_ctrl[44-:2] == 2'd3);
	assign actual_target = (actual_taken ? ex_pc_target : id_ex_pc_plus4);
	wire ex_tgt_match = (id_ex_ctrl[44-:2] == 2'd3 ? ex_jr_match : ex_pc_target == id_ex_pred_target);
	assign pred_ok = (actual_taken == id_ex_pred_taken) && (!actual_taken || ex_tgt_match);
	assign redirect_raw = !pred_ok && !redir_kill;
	csr_file u_csr(
		.clk(clk),
		.rst(rst),
		.raddr(id_ex_ctrl[27-:12]),
		.rdata(csr_rdata),
		.we(csr_we),
		.waddr(id_ex_ctrl[27-:12]),
		.wdata(csr_wdata),
		.trap_req(trap_req),
		.trap_cause(trap_cause),
		.trap_pc(id_ex_pc),
		.trap_tval(trap_tval),
		.trap_enter(trap_enter),
		.trap_vector(trap_vector),
		.mret_req(mret_req_int),
		.mret_taken(mret_taken),
		.mret_pc(mret_pc),
		.irq_timer(irq_timer),
		.irq_ext(1'b0),
		.irq_pending(irq_pending),
		.irq_cause(irq_cause)
	);
	assign is_csr = id_ex_ctrl[30-:3] == 3'd1;
	assign csr_src = (id_ex_ctrl[13] ? {27'b000000000000000000000000000, id_ex_ctrl[12-:5]} : ex_rs1);
	assign csr_wdata = (id_ex_ctrl[15-:2] == 2'b01 ? csr_src : (id_ex_ctrl[15-:2] == 2'b10 ? csr_rdata | csr_src : csr_rdata & ~csr_src));
	assign csr_we = (((is_csr && !hold_mem) && !exc_req) && !redir_kill) && ((id_ex_ctrl[15-:2] == 2'b01) || (csr_src != 32'd0));
	assign is_mret = id_ex_ctrl[30-:3] == 3'd4;
	assign mret_req_int = (is_mret && !hold_mem) && !redir_kill;
	assign exc_req = (!hold_mem && !redir_kill) && ((id_ex_ctrl[31] || (id_ex_ctrl[30-:3] == 3'd2)) || (id_ex_ctrl[30-:3] == 3'd3));
	localparam [3:0] rv32_pkg_CAUSE_BREAKPOINT = 4'd3;
	localparam [3:0] rv32_pkg_CAUSE_ECALL_M = 4'd11;
	localparam [3:0] rv32_pkg_CAUSE_ILLEGAL = 4'd2;
	assign exc_cause = (id_ex_ctrl[31] ? rv32_pkg_CAUSE_ILLEGAL : (id_ex_ctrl[30-:3] == 3'd2 ? rv32_pkg_CAUSE_ECALL_M : rv32_pkg_CAUSE_BREAKPOINT));
	assign irq_take = ((((irq_pending && !hold_mem) && !exc_req) && !is_mret) && id_ex_valid) && !redir_kill;
	assign trap_req = exc_req || irq_take;
	assign trap_cause = (exc_req ? {1'b0, exc_cause} : irq_cause);
	assign trap_tval = (id_ex_ctrl[31] ? id_ex_instr : 32'd0);
	assign br_redir = redirect;
	assign br_redir_eff = (br_redir && !trap_redir) && !redir_kill;
	always @(posedge clk or posedge rst)
		if (rst) begin
			br_redir_r <= 1'b0;
			br_tgt_r <= 32'd0;
		end
		else begin
			br_redir_r <= br_redir_eff;
			br_tgt_r <= actual_target;
		end
	assign redir_kill = br_redir_r;
	assign redir_flush = br_redir_eff || br_redir_r;
	assign trap_redir = trap_enter || mret_taken;
	assign any_redir = redir_flush || trap_redir;
	assign id_ex_flush = trap_redir || br_redir_r;
	assign pc_flush = trap_redir || br_redir_r;
	assign pc_flush_pc = (trap_enter ? trap_vector : (mret_taken ? mret_pc : br_tgt_r));
	assign pc_src = pred_taken;
	assign pc_target = pred_target;
	hazard_unit u_hazard(
		.id_ex_mem_read(id_ex_ctrl[42] && !redir_kill),
		.id_ex_reg_write(id_ex_ctrl[37] && !redir_kill),
		.id_ex_rd((redir_kill ? 5'd0 : id_ex_rd)),
		.ex_mem_reg_write(ex_mem_ctrl[37]),
		.ex_mem_mem_read(ex_mem_ctrl[42]),
		.ex_mem_rd(ex_mem_rd),
		.if_id_rs1(id_rs1),
		.if_id_rs2(id_rs2),
		.lsu_stall(lsu_stall || external_wait),
		.ex_busy(md_busy),
		.redirect_raw(redirect_raw),
		.fwd_a_pre(fwd_a_pre),
		.fwd_b_pre(fwd_b_pre),
		.pipe_stall(pipe_stall),
		.id_ex_bubble(id_ex_bubble),
		.hold_mem(hold_mem),
		.redirect(redirect)
	);
	wire [31:0] id_jr_p = if_pred_target - id_imm;
	always @(posedge clk or posedge rst)
		if (rst) begin
			id_ex_fwd_a <= 2'd0;
			id_ex_fwd_b <= 2'd0;
			id_ex_jr_p <= 32'd0;
		end
		else if (!pipe_stall) begin
			id_ex_fwd_a <= fwd_a_pre;
			id_ex_fwd_b <= fwd_b_pre;
			id_ex_jr_p <= id_jr_p;
		end
	ex_mem_reg u_ex_mem(
		.clk(clk),
		.rst(rst),
		.stall(hold_mem),
		.flush(trap_enter || br_redir_r),
		.ctrl_in(id_ex_ctrl),
		.alu_out_in(ex_result),
		.store_data_in(ex_rs2),
		.pc_plus4_in(id_ex_pc_plus4),
		.rd_addr_in(id_ex_rd),
		.ctrl(ex_mem_ctrl),
		.alu_out(ex_mem_alu_out),
		.store_data(ex_mem_store_data),
		.pc_plus4(ex_mem_pc_plus4),
		.rd_addr(ex_mem_rd)
	);
	wire [31:0] amo_newdata;
	load_store_unit u_lsu(
		.clk(clk),
		.rst(rst),
		.stall_external(external_wait),
		.req_read(ex_mem_ctrl[42]),
		.req_write(ex_mem_ctrl[41]),
		.req_size(ex_mem_ctrl[40-:2]),
		.req_unsigned(ex_mem_ctrl[38]),
		.req_addr(ex_mem_alu_out),
		.req_wdata(ex_mem_store_data),
		.dmem_addr(dmem_addr),
		.dmem_wdata(dmem_wdata),
		.dmem_wstrb(dmem_wstrb),
		.dmem_we(dmem_we),
		.dmem_rdata(dmem_rdata_g),
		.load_data(mem_load_data),
		.lsu_stall(lsu_stall),
		.amo_en(ex_mem_ctrl[7]),
		.amo_newdata(amo_newdata),
		.amo_lr(amo_is_lr),
		.amo_sc(amo_is_sc),
		.amo_write_phase(amo_write_phase),
		.amo_old_out(amo_old)
	);
	assign amo_newdata = 32'd0;
	assign amo_is_lr = 1'b0;
	assign amo_is_sc = 1'b0;
	localparam [31:0] rv32_pkg_DMEM_BASE = 32'h90000000;
	localparam [31:0] rv32_pkg_DMEM_BYTES = 16384;
	assign sel_dmem = (dmem_addr >= rv32_pkg_DMEM_BASE) && (dmem_addr < (rv32_pkg_DMEM_BASE + rv32_pkg_DMEM_BYTES));
	assign dmem_we_g = dmem_we && sel_dmem;
	always @(posedge clk) begin
		if (!external_wait) begin
			ext_rdata_r <= ext_rdata;
			sel_dmem_r <= sel_dmem;
		end
	end
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			external_wait_active <= 0;
			wait_wb_data <= 0;
		end else begin
			external_wait_active <= external_wait;
			if (external_wait && !external_wait_active) wait_wb_data <= wb_data;
		end
	end
	assign dmem_rdata_g = (sel_dmem_r ? dmem_rdata : ext_rdata_r);
	assign ext_we = (dmem_we && !sel_dmem) && (dmem_wstrb != 4'b0000);
	assign ext_re = ex_mem_ctrl[42] && !sel_dmem;
	assign ext_addr = dmem_addr;
	assign ext_wdata = dmem_wdata;
	assign ext_wstrb = dmem_wstrb;
	dmem #(
		.BASE(rv32_pkg_DMEM_BASE),
		.BYTES(rv32_pkg_DMEM_BYTES)
	) u_dmem(
		.clk(clk),
		.addr(dmem_addr),
		.wdata(dmem_wdata),
		.wstrb(dmem_wstrb),
		.we(dmem_we_g),
		.rdata(dmem_rdata)
	);
	mem_wb_reg u_mem_wb(
		.clk(clk),
		.rst(rst),
		.stall(hold_mem),
		.ctrl_in(ex_mem_ctrl),
		.alu_out_in(ex_mem_alu_out),
		.load_data_in(32'h00000000),
		.pc_plus4_in(ex_mem_pc_plus4),
		.rd_addr_in(ex_mem_rd),
		.ctrl(mem_wb_ctrl),
		.alu_out(mem_wb_alu_out),
		.load_data(mem_wb_load_data),
		.pc_plus4(mem_wb_pc_plus4),
		.rd_addr(mem_wb_rd)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		case (mem_wb_wb_src)
			2'd1: wb_data = mem_load_data;
			2'd2: wb_data = mem_wb_pc_plus4;
			default: wb_data = mem_wb_alu_out;
		endcase
		if (external_wait_active) wb_data = wait_wb_data;
	end
	assign wb_reg_write = mem_wb_ctrl[37] && (mem_wb_rd != 5'd0);
	assign wb_rd = mem_wb_rd;
	assign dbg_pc = pc;
	assign dbg_id_pc = if_pc;
	assign dbg_instr = if_instr;
	assign dbg_mem_we = dmem_we && (dmem_wstrb != 4'b0000);
	assign dbg_mem_addr = dmem_addr;
	assign dbg_mem_wdata = dmem_wdata;
	always @(posedge clk or posedge rst)
		if (rst)
			dbg_illegal <= 1'b0;
		else if (((id_ex_ctrl[31] && !pipe_stall) && !redir_flush) && !trap_enter)
			dbg_illegal <= 1'b1;
	assign dbg_stall = pipe_stall;
	assign dbg_redirect = redirect;
	initial _sv2v_0 = 0;
endmodule
