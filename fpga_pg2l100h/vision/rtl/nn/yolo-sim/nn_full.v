`timescale 1ns/1ps
module nn_conv_engine (
	clk,
	rst,
	desc,
	start,
	busy,
	done,
	cycles,
	err_code,
	w_re,
	w_addr,
	w_rdata,
	q_re,
	q_addr,
	q_rdata,
	a_sel,
	a_re,
	a_addr,
	a_rdata,
	b_sel,
	b_we,
	b_addr,
	b_wdata_128,
	b_wstrb
);
	reg _sv2v_0;
	parameter signed [31:0] OC_LANES = 16;
	parameter signed [31:0] PX_LANES = 8;
	parameter signed [31:0] W_RD_LAT = 2;
	input wire clk;
	input wire rst;
	input wire [210:0] desc;
	input wire start;
	output wire busy;
	output wire done;
	output wire [31:0] cycles;
	output wire [7:0] err_code;
	output reg w_re;
	output wire [23:0] w_addr;
	input wire [127:0] w_rdata;
	output wire q_re;
	output wire [12:0] q_addr;
	input wire [63:0] q_rdata;
	output reg [1:0] a_sel;
	output reg a_re;
	output wire [23:0] a_addr;
	input wire [127:0] a_rdata;
	output wire [1:0] b_sel;
	output wire b_we;
	output wire [23:0] b_addr;
	output wire [127:0] b_wdata_128;
	output wire [15:0] b_wstrb;
	localparam signed [31:0] PX = PX_LANES;
	localparam signed [31:0] OCL = OC_LANES;
	localparam signed [31:0] BANDW = 24;
	localparam signed [31:0] WINW = 15;
	localparam [0:0] LAT2 = W_RD_LAT >= 2;
	localparam signed [31:0] DRNN = (LAT2 ? 4 : 3);
	reg [4:0] state;
	reg [1:0] d_op;
	reg [7:0] d_flags;
	reg [3:0] d_ks;
	reg [1:0] d_st;
	reg [2:0] d_pad;
	reg [15:0] d_ih;
	reg [15:0] d_iw;
	reg [15:0] d_ic;
	reg [15:0] d_oc;
	reg [31:0] d_src;
	reg [31:0] d_dst;
	reg [31:0] d_woff;
	reg [31:0] d_qoff;
	reg is_conv;
	reg is_pool;
	reg is_copy;
	reg is_add;
	reg f_dw;
	reg f_leaky;
	reg f_up2x;
	reg f_p3;
	reg f_add_r;
	reg f_relu;
	wire dense = is_conv && !f_dw;
	wire f_dw16 = f_dw && (((d_oc[3:0] == 4'd0) && (d_ic[3:0] == 4'd0)) && (d_oc == d_ic));
	wire [2:0] pad_eff = (is_pool && (d_pad == 3'd0) ? ({1'b0, d_ks} - 4'd1) >> 1 : d_pad);
	wire [15:0] ks16 = {12'd0, d_ks};
	wire [15:0] st16 = {14'd0, d_st};
	reg [15:0] oh_w;
	reg [15:0] ow_w;
	reg [2:0] pad_r;
	reg st2_r;
	wire [15:0] ic8 = (d_ic + 16'd7) & 16'hfff8;
	wire [15:0] oc8 = (d_oc + 16'd7) & 16'hfff8;
	wire [15:0] icb_n = {8'd0, ic8[10:3]};
	wire [15:0] ld_count = (dense && (d_ks == 4'd1) ? 16'd8 : (7 * st16) + ks16);
	reg cr_ks_bad;
	reg cr_st_bad;
	reg cr_pad_bad;
	reg cr_ic_bad;
	reg cr_ih_bad;
	reg cr_dw_bad;
	reg cr_p3_bad;
	reg pl_ks_bad;
	reg pl_st_bad;
	reg pl_pad_bad;
	reg pl_ic_bad;
	reg cp_ic_bad;
	reg cp_hw_bad;
	reg cp_cn_bad;
	reg ad_ic_bad;
	reg ad_hw_bad;
	reg ad_oc_bad;
	reg ad_r_bad;
	reg d_oh_bad;
	always @(*) begin
		if (_sv2v_0)
			;
		cr_ks_bad = !(((d_ks == 4'd1) || (d_ks == 4'd3)) || (d_ks == 4'd5));
		cr_st_bad = !((d_st == 2'd1) || (d_st == 2'd2));
		cr_pad_bad = d_pad > (ks16 >> 1);
		cr_ic_bad = (d_ic == 16'd0) || (d_oc == 16'd0);
		cr_ih_bad = (d_ih == 16'd0) || (d_iw == 16'd0);
		cr_dw_bad = f_dw && (d_oc != d_ic);
		cr_p3_bad = f_p3 && ((((!is_conv || f_dw) || f_add_r) || (d_ic > 16'd8)) || (d_ks != 4'd3));
		pl_ks_bad = !((((d_ks == 4'd2) || (d_ks == 4'd3)) || (d_ks == 4'd5)) || (d_ks == 4'd9));
		pl_st_bad = !((d_st == 2'd1) || (d_st == 2'd2));
		pl_pad_bad = d_pad > (ks16 >> 1);
		pl_ic_bad = ((d_ic == 16'd0) || (d_ih == 16'd0)) || (d_iw == 16'd0);
		cp_ic_bad = (d_ic == 16'd0) || (d_oc == 16'd0);
		cp_hw_bad = (d_ih == 16'd0) || (d_iw == 16'd0);
		cp_cn_bad = ic8 > oc8;
		ad_ic_bad = d_ic == 16'd0;
		ad_hw_bad = (d_ih == 16'd0) || (d_iw == 16'd0);
		ad_oc_bad = d_oc != d_ic;
		ad_r_bad = f_add_r && !(is_add || is_conv);
		d_oh_bad = (({1'b0, d_ih} + (pad_eff << 1)) < {13'd0, d_ks}) || (({1'b0, d_iw} + (pad_eff << 1)) < {13'd0, d_ks});
	end
	reg cr_ks_f;
	reg cr_st_f;
	reg cr_pad_f;
	reg cr_ic_f;
	reg cr_ih_f;
	reg cr_dw_f;
	reg cr_p3_f;
	reg pl_ks_f;
	reg pl_st_f;
	reg pl_pad_f;
	reg pl_ic_f;
	reg cp_ic_f;
	reg cp_hw_f;
	reg cp_cn_f;
	reg ad_ic_f;
	reg ad_hw_f;
	reg ad_oc_f;
	reg ad_r_f;
	reg d_oh_f;
	reg [7:0] init_err;
	always @(*) begin
		if (_sv2v_0)
			;
		init_err = 8'h00;
		if (is_conv) begin
			if (cr_ks_f)
				init_err = 8'h11;
			else if (cr_st_f)
				init_err = 8'h12;
			else if (cr_pad_f)
				init_err = 8'h13;
			else if (cr_ic_f)
				init_err = 8'h14;
			else if (cr_ih_f)
				init_err = 8'h15;
			else if (cr_dw_f)
				init_err = 8'h16;
			else if (cr_p3_f)
				init_err = 8'h17;
			else if (d_oh_f)
				init_err = 8'h18;
		end
		else if (is_pool) begin
			if (pl_ks_f)
				init_err = 8'h21;
			else if (pl_st_f)
				init_err = 8'h22;
			else if (pl_pad_f)
				init_err = 8'h23;
			else if (pl_ic_f)
				init_err = 8'h24;
			else if (d_oh_f)
				init_err = 8'h25;
		end
		else if (is_copy) begin
			if (cp_ic_f)
				init_err = 8'h31;
			else if (cp_hw_f)
				init_err = 8'h32;
			else if (cp_cn_f)
				init_err = 8'h33;
		end
		else if (ad_ic_f)
			init_err = 8'h41;
		else if (ad_hw_f)
			init_err = 8'h42;
		else if (ad_oc_f)
			init_err = 8'h43;
		else if (ad_r_f)
			init_err = 8'h44;
	end
	reg [31:0] cycles_r;
	reg [7:0] err_r;
	reg done_r;
	reg [15:0] c_ocb;
	reg [15:0] c_oy;
	reg [15:0] c_oxg;
	reg [15:0] c_ky;
	reg [15:0] c_icb;
	reg [15:0] c_m;
	reg [15:0] c_ld;
	reg [15:0] c_p;
	reg [15:0] c_iy;
	reg [15:0] c_ix;
	reg [15:0] c_cb;
	reg [2:0] c_drn;
	reg [4:0] q_iss;
	reg [1:0] c_wr;
	reg c_ql;
	reg [1:0] p3_ph;
	reg ld_ret_v;
	reg ld_fill_d;
	reg ld_half_d;
	reg [4:0] ld_j_d;
	reg [7:0] ld_fillbyte_d;
	reg mac_v1;
	reg mac_v2;
	reg mac_v3;
	reg mac_v4;
	reg signed [15:0] wby_r [0:OCL - 1];
	reg rd_half_s;
	reg rd_half_d;
	reg [63:0] src_word_q;
	reg [63:0] cp_word_q;
	reg [63:0] abuf [0:23];
	reg [63:0] bshift [0:14];
	reg [127:0] dwbuf [0:23];
	reg [127:0] dwbsh [0:14];
	reg signed [31:0] acc [0:PX - 1][0:OCL - 1];
	reg signed [7:0] a_pipe [0:PX - 1][0:OCL - 1];
	reg signed [7:0] a_pipe1 [0:PX - 1][0:OCL - 1];
	reg signed [7:0] a_pipe2 [0:PX - 1][0:OCL - 1];
	reg signed [15:0] prod [0:PX - 1][0:OCL - 1];
	reg signed [31:0] bias_q [0:OCL - 1];
	reg signed [15:0] mpos_q [0:OCL - 1];
	reg signed [15:0] mneg_q [0:OCL - 1];
	reg signed [31:0] mpos32 [0:OCL - 1];
	(* use_dsp = "no" *) reg signed [31:0] mtmp [0:OCL - 1];
	reg signed [7:0] zp_out;
	reg signed [7:0] zp_in;
	reg [7:0] shift_q;
	reg leaky_q;
	reg signed [7:0] zp_s_r;
	reg signed [7:0] zp_d_r;
	reg [15:0] add_r_r;
	reg [7:0] kadd_r;
	reg signed [7:0] mx [0:PX - 1][0:OCL - 1];
	reg signed [31:0] acc_sel [0:OCL - 1];
	reg signed [15:0] m_sel [0:OCL - 1];
	reg signed [16:0] acc_hi [0:OCL - 1];
	reg signed [16:0] acc_lo [0:OCL - 1];
	(* use_dsp = "yes" *) reg signed [31:0] prod_hi [0:OCL - 1];
	(* use_dsp = "yes" *) reg signed [31:0] prod_lo [0:OCL - 1];
	reg signed [47:0] prod64 [0:OCL - 1];
	reg signed [47:0] y64_q [0:OCL - 1];
	reg signed [47:0] y2_q [0:OCL - 1];
	reg [63:0] out_lo [0:PX - 1];
	reg [63:0] out_hi [0:PX - 1];
	reg [127:0] p3w0;
	reg [127:0] p3w1;
	reg [15:0] ic8_r;
	reg [15:0] oc8_r;
	reg [15:0] ocw_r;
	reg [15:0] oc_limit_r;
	reg [15:0] icb_n_r;
	reg [4:0] q_tot_r;
	reg [4:0] qb_w_r;
	reg [4:0] qm_w_r;
	reg icb_more_r;
	reg [15:0] rem_ch;
	reg [12:0] q_bias_w;
	reg [12:0] q_mpos_w;
	reg [12:0] q_tail_w;
	reg [23:0] row_step_a;
	reg [23:0] oy_step_a;
	reg [23:0] ox_step_a;
	reg [23:0] band_step_a;
	reg [23:0] band_ky_step;
	reg [23:0] base0_a;
	reg [23:0] row_step_w;
	reg [23:0] ox_step_w;
	reg [23:0] px_bytes;
	reg [23:0] w_p2;
	reg [23:0] w_dgrp;
	reg [23:0] w_sub;
	reg [23:0] p1;
	reg [23:0] p1_2;
	reg [23:0] p1_3;
	reg [23:0] p1_4;
	reg [23:0] base0_t;
	reg [23:0] base0_t2;
	reg [23:0] d_row_step;
	reg [23:0] d_row_step2;
	reg [23:0] d_x_step;
	reg [23:0] up_px_row;
	reg [23:0] ups_dx;
	reg [23:0] cp_dst_pix;
	reg [15:0] dx_r;
	reg [15:0] ld_count_r;
	reg [15:0] ld_m1_r;
	reg [23:0] p3_row;
	reg [23:0] p3_oy;
	reg [23:0] p3_ox;
	reg [23:0] wa_r;
	reg [23:0] qa_r;
	reg [23:0] row_base_a;
	reg [23:0] blk_base;
	reg [23:0] band_base;
	reg [23:0] la;
	reg [23:0] row_base_w;
	reg [23:0] wr_base;
	reg [23:0] wpx;
	reg [23:0] src_la;
	reg [23:0] dst_la;
	reg [23:0] row_base_a_n;
	reg [23:0] row_base_w_n;
	reg [1:0] nxt_sel;
	reg sel_a_src;
	reg sel_b_dst;
	reg signed [15:0] x_ld;
	reg signed [15:0] x0_ld;
	reg signed [15:0] y_ld;
	reg y_ok_r;
	wire w_re_c;
	reg q_re_c;
	wire a_re_c;
	reg b_we_c;
	reg q_re_q;
	reg [12:0] q_addr_q;
	reg [23:0] w_addr_c;
	reg [23:0] a_addr_c;
	reg [23:0] b_addr_c;
	reg [12:0] q_addr_c;
	reg [127:0] b_wdata_c;
	reg [15:0] b_wstrb_c;
	reg b_we_q;
	reg [23:0] b_addr_q;
	reg [127:0] b_wdata_q;
	reg [15:0] b_wstrb_q;
	wire [15:0] ox0 = c_oxg << 3;
	wire signed [15:0] x0_c = ($signed(ox0) * (st2_r ? 16'sd2 : 16'sd1)) - $signed({13'd0, pad_r});
	wire signed [15:0] y_ky0 = ($signed(c_oy) * (st2_r ? 16'sd2 : 16'sd1)) - $signed({13'd0, pad_r});
	wire [15:0] act_l = {{10 {1'b0}}, qb_w_r, 1'b0};
	wire [15:0] oc_base_w = (oc8_r - act_l) - rem_ch;
	wire [15:0] qb_w = {11'd0, qb_w_r};
	wire [15:0] qm_w = {11'd0, qm_w_r};
	wire [15:0] q_tot = {11'd0, q_tot_r};
	wire single16 = (((dense || f_dw16) && (act_l == 16'd16)) && (oc8_r[3:0] == 4'd0)) && (d_dst[3:0] == 4'd0);
	wire wr_dense16 = (dense || f_dw16) && (act_l == 16'd16);
	wire [15:0] req_beats = (wr_dense16 ? (single16 ? 16'd8 : 16'd16) : 16'd8);
	reg wr16_r;
	reg wrs16_r;
	reg [15:0] wrbeats_r;
	reg fad_active;
	reg signed [7:0] fad_zp_d;
	reg [7:0] fad_kadd;
	reg [15:0] fad_r;
	reg [127:0] ad_cap [0:PX - 1];
	reg signed [24:0] fad_dlo [0:7];
	reg signed [24:0] fad_dhi [0:7];
	reg [63:0] fad_plo [0:7];
	reg [63:0] fad_phi [0:7];
	reg signed [8:0] fad_dv_lo [0:7];
	reg signed [8:0] fad_dv_hi [0:7];
	wire [15:0] fad_off_w = (fad_active ? 16'd3 : 16'd0);
	wire [15:0] reqn_w = ((16'd6 + wrbeats_r) + 16'd2) + fad_off_w;
	function automatic [63:0] fad_add;
		input reg [199:0] dlt;
		input reg [63:0] qd_w;
		reg signed [24:0] dv;
		reg signed [26:0] sv;
		reg signed [7:0] bb;
		begin
			fad_add = 64'd0;
			begin : sv2v_autoblock_1
				reg signed [31:0] l;
				for (l = 0; l < 8; l = l + 1)
					if (l < OCL) begin
						dv = $signed(dlt[l * 25+:25]);
						sv = $signed(qd_w[l * 8+:8]) + dv;
						if (sv > 27'sd127)
							bb = 8'sd127;
						else if (sv < -27'sd128)
							bb = -8'sd128;
						else
							bb = sv[7:0];
						if (f_relu && (bb < fad_zp_d))
							bb = fad_zp_d;
						fad_add[l * 8+:8] = bb;
					end
			end
		end
	endfunction
	wire [12:0] q_bias_base = q_bias_w;
	wire [12:0] q_mpos_base = q_mpos_w;
	wire [12:0] q_tail_base = q_tail_w;
	wire ld_inb = (y_ok_r && (x_ld >= 0)) && (x_ld < $signed(d_iw));
	wire [7:0] ld_fill = (is_pool ? 8'h80 : zp_in);
	wire [23:0] w_delta = (c_m == ((ks16 << 3) - 16'd1) ? ((c_icb + 16'd1) < icb_n_r ? w_sub : w_p2) : ((c_m[2:0] == 3'd7) && ((c_m[7:3] + 16'd1) < ks16) ? w_dgrp : w_p2));
	reg [127:0] rq_pack;
	function automatic signed [15:0] sv2v_cast_16_signed;
		input reg signed [15:0] inp;
		sv2v_cast_16_signed = inp;
	endfunction
	always @(*) begin : sv2v_autoblock_2
		reg signed [47:0] y2;
		reg [7:0] bb;
		reg fits;
		if (_sv2v_0)
			;
		rq_pack = 128'd0;
		begin : sv2v_autoblock_3
			reg signed [31:0] l;
			for (l = 0; l < OCL; l = l + 1)
				begin
					y2 = y2_q[l];
					fits = &y2[47:7] || ~|y2[47:7];
					if (fits)
						bb = y2[7:0];
					else
						bb = (y2[47] ? 8'h80 : 8'h7f);
					if ((oc_base_w + sv2v_cast_16_signed(l)) >= d_oc)
						bb = zp_out;
					rq_pack[l * 8+:8] = bb;
				end
		end
	end
	reg [127:0] pool_pack;
	always @(*) begin : sv2v_autoblock_4
		reg [7:0] bb;
		if (_sv2v_0)
			;
		pool_pack = 128'd0;
		begin : sv2v_autoblock_5
			reg signed [31:0] l;
			for (l = 0; l < OCL; l = l + 1)
				if (l < 8) begin
					bb = mx[c_p[2:0]][l];
					if (((c_ocb * 16'd8) + l) >= d_ic)
						bb = 8'h00;
					pool_pack[l * 8+:8] = bb;
				end
		end
	end
	wire [63:0] ad_dst_word = (rd_half_d ? a_rdata[127:64] : a_rdata[63:0]);
	reg [63:0] ad_pack;
	reg [63:0] ad_pack_q;
	reg signed [8:0] ad_delta [0:7];
	reg signed [8:0] ad_qq [0:7];
	reg signed [7:0] ad_qs [0:7];
	(* use_dsp = "no" *) reg signed [31:0] ad_mul [0:7];
	reg [63:0] ad_dst_q;
	always @(*) begin : sv2v_autoblock_6
		reg signed [8:0] s;
		reg signed [31:0] p;
		reg signed [7:0] qs;
		reg signed [7:0] qd;
		if (_sv2v_0)
			;
		ad_pack = 64'd0;
		begin : sv2v_autoblock_7
			reg signed [31:0] l;
			for (l = 0; l < OCL; l = l + 1)
				if (l < 8) begin
					if (f_add_r) begin
						qs = $signed(src_word_q[l * 8+:8]);
						qd = $signed(ad_dst_word[l * 8+:8]);
						p = ($signed(qs) - $signed(zp_s_r)) * $signed({1'b0, add_r_r});
						p = p >>> kadd_r;
						p = p + {{24 {qd[7]}}, qd};
						if (p > 32'sd127)
							ad_pack[l * 8+:8] = 8'h7f;
						else if (p < -32'sd128)
							ad_pack[l * 8+:8] = 8'h80;
						else
							ad_pack[l * 8+:8] = p[7:0];
					end
					else begin
						s = $signed({src_word_q[(l * 8) + 7], src_word_q[l * 8+:8]}) + $signed({ad_dst_word[(l * 8) + 7], ad_dst_word[l * 8+:8]});
						if (s > 9'sd127)
							ad_pack[l * 8+:8] = 8'h7f;
						else if (s < -9'sd128)
							ad_pack[l * 8+:8] = 8'h80;
						else
							ad_pack[l * 8+:8] = s[7:0];
					end
				end
		end
	end
	reg [63:0] win_sel [0:PX - 1];
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_8
			reg signed [31:0] px;
			for (px = 0; px < PX; px = px + 1)
				if (dense && (d_ks == 4'd1))
					win_sel[px] = abuf[px];
				else
					win_sel[px] = (st2_r ? bshift[2 * px] : bshift[px]);
		end
	end
	reg [127:0] dw_win [0:PX - 1];
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_9
			reg signed [31:0] px;
			for (px = 0; px < PX; px = px + 1)
				dw_win[px] = (st2_r ? dwbsh[2 * px] : dwbsh[px]);
		end
	end
	reg [63:0] ad_pack2;
	always @(*) begin : sv2v_autoblock_10
		reg signed [9:0] s2;
		reg signed [7:0] qd2;
		reg [7:0] bb;
		if (_sv2v_0)
			;
		ad_pack2 = 64'd0;
		begin : sv2v_autoblock_11
			reg signed [31:0] l;
			for (l = 0; l < 8; l = l + 1)
				begin
					qd2 = $signed(ad_dst_q[l * 8+:8]);
					s2 = $signed({qd2[7], qd2}) + $signed(ad_delta[l]);
					if (s2 > 10'sd127)
						bb = 8'h7f;
					else if (s2 < -10'sd128)
						bb = 8'h80;
					else
						bb = s2[7:0];
					if (f_relu && ($signed(bb) < zp_d_r))
						bb = zp_d_r;
					ad_pack2[l * 8+:8] = bb;
				end
		end
	end
	wire [63:0] ad_src_word = (rd_half_s ? a_rdata[127:64] : a_rdata[63:0]);
	wire [5:0] sel_byte_base = {c_m[2:0], 3'b000};
	wire [3:0] cur_kx = (dense ? c_m[7:3] : c_m[3:0]);
	wire win_adv = (state == 5'd10 ? (dense ? (c_m[2:0] == 3'd7) && ((c_m[7:3] + 16'd1) < ks16) : (c_m + 16'd1) < ks16) : (state == 5'd17 ? (c_m + 16'd1) < ks16 : 1'b0));
	wire mac_issue = state == 5'd10;
	function automatic [15:0] sv2v_cast_16;
		input reg [15:0] inp;
		sv2v_cast_16 = inp;
	endfunction
	function automatic [12:0] sv2v_cast_13;
		input reg [12:0] inp;
		sv2v_cast_13 = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		w_re = 1'b0;
		w_addr_c = wa_r;
		q_re_c = 1'b0;
		q_addr_c = 13'd0;
		a_re = 1'b0;
		a_addr_c = la;
		a_sel = (sel_a_src ? 2'd1 : 2'd0);
		b_we_c = 1'b0;
		b_addr_c = {wpx[23:4], 4'h0};
		b_wdata_c = 128'd0;
		b_wstrb_c = 16'h0000;
		if (state == 5'd4) begin
			q_re_c = sv2v_cast_16(q_iss) < q_tot;
			q_addr_c = (q_iss < qb_w ? q_bias_base + sv2v_cast_13(q_iss) : (sv2v_cast_16(q_iss) < (qb_w + qm_w) ? q_mpos_base + sv2v_cast_13(q_iss - qb_w) : q_tail_base + sv2v_cast_13((q_iss - qb_w) - qm_w)));
		end
		else if (state == 5'd10) begin
			w_re = 1'b1;
			w_addr_c = wa_r;
		end
		case (state)
			5'd7:
				if (f_p3) begin
					a_re = ld_inb && (p3_ph != 2'd2);
					a_addr_c = (p3_ph == 2'd0 ? la & ~24'd15 : (la & ~24'd15) + 24'd16);
				end
				else begin
					a_re = ld_inb;
					a_addr_c = la;
				end
			5'd19: begin
				a_re = 1'b1;
				a_addr_c = src_la;
			end
			5'd22: begin
				a_re = 1'b1;
				a_addr_c = src_la;
			end
			5'd23: begin
				a_re = 1'b1;
				a_addr_c = dst_la;
				a_sel = (sel_b_dst ? 2'd1 : 2'd0);
			end
			5'd21: begin
				q_re_c = 1'b1;
				q_addr_c = sv2v_cast_13(d_qoff >> 3);
			end
			5'd12: begin
				a_re = c_p < wrbeats_r;
				a_addr_c = wr_base + {18'd0, (wr16_r && !wrs16_r ? {c_p[3:1], 4'h0} : {c_p[3:0], 4'h0})};
				a_sel = (sel_b_dst ? 2'd1 : 2'd0);
			end
			5'd13: begin : req_wr
				reg [15:0] beat;
				reg [15:0] px;
				reg half;
				reg [63:0] pay;
				reg [63:0] pay_lo;
				reg [63:0] pay_hi;
				reg [3:0] sh;
				beat = (c_p - 16'd6) - fad_off_w;
				if (wr16_r && !wrs16_r) begin
					px = beat >> 1;
					half = beat[0];
				end
				else begin
					px = beat;
					half = 1'b0;
				end
				if (((c_p >= (16'd6 + fad_off_w)) && (c_p <= ((16'd5 + wrbeats_r) + fad_off_w))) && ((ox0 + px) < ow_w)) begin
					pay = (half ? out_hi[px[2:0]] : out_lo[px[2:0]]);
					pay_lo = out_lo[px[2:0]];
					pay_hi = out_hi[px[2:0]];
					if (fad_active) begin
						pay_lo = fad_plo[px[2:0]];
						pay_hi = fad_phi[px[2:0]];
					end
					sh = wpx[3:0];
					b_we_c = 1'b1;
					b_addr_c = {wpx[23:4], 4'h0};
					if (wrs16_r) begin
						b_wdata_c = {pay_hi, pay_lo};
						b_wstrb_c = 16'hffff;
					end
					else begin
						pay = (half ? pay_hi : pay_lo);
						b_wdata_c = (sh == 4'd8 ? {pay, 64'd0} : {64'd0, pay});
						b_wstrb_c = (sh == 4'd8 ? 16'hff00 : 16'h00ff);
					end
				end
			end
			5'd18: begin : pp_wr
				reg [63:0] pay;
				reg [15:0] stb;
				reg [3:0] sh;
				pay = pool_pack[63:0];
				stb = 16'h0000;
				begin : sv2v_autoblock_12
					reg signed [31:0] i;
					for (i = 0; i < 8; i = i + 1)
						stb[i] = ((c_ocb * 16'd8) + sv2v_cast_16_signed(i)) < ic8_r;
				end
				sh = wpx[3:0];
				if ((ox0 + c_p) < ow_w) begin
					b_we_c = 1'b1;
					b_addr_c = {wpx[23:4], 4'h0};
					b_wdata_c = (sh == 4'd8 ? {pay, 64'd0} : {64'd0, pay});
					b_wstrb_c = (sh == 4'd8 ? stb << 8 : stb);
				end
			end
			5'd20: begin : cp_wr
				reg [63:0] pay;
				reg [23:0] adr;
				reg [3:0] sh;
				pay = (c_wr == 2'd0 ? (rd_half_s ? a_rdata[127:64] : a_rdata[63:0]) : cp_word_q);
				adr = dst_la;
				if (f_up2x)
					adr = (dst_la + (c_wr[1] ? up_px_row : 24'd0)) + (c_wr[0] ? ups_dx : 24'd0);
				sh = adr[3:0];
				b_we_c = 1'b1;
				b_addr_c = {adr[23:4], 4'h0};
				b_wdata_c = (sh == 4'd8 ? {pay, 64'd0} : {64'd0, pay});
				b_wstrb_c = (sh == 4'd8 ? 16'hff00 : 16'h00ff);
			end
			5'd26: begin : ad_wr
				reg [3:0] sh;
				sh = dst_la[3:0];
				b_we_c = 1'b1;
				b_addr_c = {dst_la[23:4], 4'h0};
				b_wdata_c = (sh == 4'd8 ? {ad_pack2, 64'd0} : {64'd0, ad_pack2});
				b_wstrb_c = (sh == 4'd8 ? 16'hff00 : 16'h00ff);
			end
			default:
				;
		endcase
	end
	assign a_addr = a_addr_c;
	assign w_addr = w_addr_c;
	assign q_addr = q_addr_q;
	assign q_re = q_re_q;
	assign b_we = b_we_q;
	assign b_addr = b_addr_q;
	assign b_sel = (sel_b_dst ? 2'd1 : 2'd0);
	assign b_wdata_128 = b_wdata_q;
	assign b_wstrb = b_wstrb_q;
	localparam [31:0] nn_pkg_NN_B_OFF = 32'h00078000;
	localparam [31:0] nn_pkg_NN_F_ADD_R = 6;
	localparam [31:0] nn_pkg_NN_F_DEPTHWISE = 0;
	localparam [31:0] nn_pkg_NN_F_LEAKY = 1;
	localparam [31:0] nn_pkg_NN_F_PACKED3 = 5;
	localparam [31:0] nn_pkg_NN_F_RELU = 7;
	localparam [31:0] nn_pkg_NN_F_UP2X = 3;
	localparam [1:0] nn_pkg_NN_OP_ADD = 2'd3;
	localparam [1:0] nn_pkg_NN_OP_CONV = 2'd0;
	localparam [1:0] nn_pkg_NN_OP_COPY = 2'd2;
	localparam [1:0] nn_pkg_NN_OP_POOL = 2'd1;
	function automatic [4:0] sv2v_cast_5;
		input reg [4:0] inp;
		sv2v_cast_5 = inp;
	endfunction
	always @(posedge clk)
		if (rst) begin
			state <= 5'd0;
			cycles_r <= 32'd0;
			err_r <= 8'h00;
			done_r <= 1'b0;
			ld_ret_v <= 1'b0;
			b_we_q <= 1'b0;
			b_addr_q <= 24'd0;
			b_wdata_q <= 128'd0;
			b_wstrb_q <= 16'd0;
			q_re_q <= 1'b0;
			q_addr_q <= 13'd0;
			x_ld <= 16'sd0;
			x0_ld <= 16'sd0;
			dx_r <= 16'd1;
			y_ok_r <= 1'b0;
			y_ld <= 16'sd0;
			p3_ph <= 2'd0;
			p3w0 <= 128'd0;
			p3w1 <= 128'd0;
			mac_v1 <= 1'b0;
			mac_v2 <= 1'b0;
			mac_v3 <= 1'b0;
			mac_v4 <= 1'b0;
			q_iss <= 5'd0;
			is_conv <= 1'b0;
			is_pool <= 1'b0;
			is_copy <= 1'b0;
			is_add <= 1'b0;
			f_dw <= 1'b0;
			f_leaky <= 1'b0;
			f_up2x <= 1'b0;
			f_p3 <= 1'b0;
			f_add_r <= 1'b0;
			f_relu <= 1'b0;
			c_ocb <= 16'd0;
			c_oy <= 16'd0;
			c_oxg <= 16'd0;
			c_ky <= 16'd0;
			c_icb <= 16'd0;
			c_m <= 16'd0;
			c_ld <= 16'd0;
			c_p <= 16'd0;
			c_iy <= 16'd0;
			c_ix <= 16'd0;
			c_cb <= 16'd0;
			c_drn <= 3'd0;
			c_wr <= 2'd0;
			c_ql <= 1'b0;
			rd_half_s <= 1'b0;
			rd_half_d <= 1'b0;
			src_word_q <= 64'd0;
			cp_word_q <= 64'd0;
			wa_r <= 24'd0;
			qa_r <= 24'd0;
			row_base_a <= 24'd0;
			blk_base <= 24'd0;
			band_base <= 24'd0;
			la <= 24'd0;
			row_base_w <= 24'd0;
			wr_base <= 24'd0;
			wpx <= 24'd0;
			src_la <= 24'd0;
			dst_la <= 24'd0;
			row_base_a_n <= 24'd0;
			row_base_w_n <= 24'd0;
			nxt_sel <= 2'd0;
			sel_a_src <= 1'b0;
			sel_b_dst <= 1'b0;
			ic8_r <= 16'd0;
			oc8_r <= 16'd0;
			ocw_r <= 16'd8;
			oc_limit_r <= 16'd0;
			q_tot_r <= 5'd0;
			qb_w_r <= 5'd0;
			qm_w_r <= 5'd0;
			q_bias_w <= 13'd0;
			q_mpos_w <= 13'd0;
			q_tail_w <= 13'd0;
			rem_ch <= 16'd0;
			icb_n_r <= 16'd0;
			ld_count_r <= 16'd0;
			ld_m1_r <= 16'd0;
			row_step_a <= 24'd0;
			oy_step_a <= 24'd0;
			ox_step_a <= 24'd0;
			band_step_a <= 24'd0;
			band_ky_step <= 24'd0;
			base0_a <= 24'd0;
			row_step_w <= 24'd0;
			ox_step_w <= 24'd0;
			px_bytes <= 24'd0;
			w_p2 <= 24'd0;
			w_dgrp <= 24'd0;
			w_sub <= 24'd0;
			p1 <= 24'd0;
			p1_2 <= 24'd0;
			p1_3 <= 24'd0;
			p1_4 <= 24'd0;
			base0_t <= 24'd0;
			base0_t2 <= 24'd0;
			d_row_step <= 24'd0;
			d_row_step2 <= 24'd0;
			d_x_step <= 24'd0;
			up_px_row <= 24'd0;
			ups_dx <= 24'd0;
			cp_dst_pix <= 24'd0;
			p3_row <= 24'd0;
			p3_oy <= 24'd0;
			p3_ox <= 24'd0;
			pad_r <= 3'd0;
			oh_w <= 16'd0;
			ow_w <= 16'd0;
			st2_r <= 1'b0;
			zp_out <= 8'sd0;
			zp_in <= 8'sd0;
			shift_q <= 8'd0;
			leaky_q <= 1'b0;
			zp_s_r <= 8'sd0;
			zp_d_r <= 8'sd0;
			add_r_r <= 16'd0;
			kadd_r <= 8'd0;
			fad_active <= 1'b0;
			fad_zp_d <= 8'sd0;
			fad_kadd <= 8'd0;
			fad_r <= 16'd0;
			begin : sv2v_autoblock_13
				reg signed [31:0] l;
				for (l = 0; l < 8; l = l + 1)
					begin
						fad_dlo[l] <= 25'sd0;
						fad_dhi[l] <= 25'sd0;
					end
			end
			ad_pack_q <= 64'd0;
			ad_dst_q <= 64'd0;
			begin : sv2v_autoblock_14
				reg signed [31:0] l;
				for (l = 0; l < 8; l = l + 1)
					begin
						ad_delta[l] <= 9'sd0;
						ad_qq[l] <= 9'sd0;
						ad_mul[l] <= 32'sd0;
						ad_qs[l] <= 8'sd0;
					end
			end
			wr16_r <= 1'b0;
			wrs16_r <= 1'b0;
			wrbeats_r <= 16'd8;
			begin : sv2v_autoblock_15
				reg signed [31:0] px;
				for (px = 0; px < PX; px = px + 1)
					begin
						out_lo[px] <= 64'sd0;
						out_hi[px] <= 64'sd0;
					end
			end
			begin : sv2v_autoblock_16
				reg signed [31:0] l;
				for (l = 0; l < OCL; l = l + 1)
					begin
						y64_q[l] <= 48'sd0;
						y2_q[l] <= 48'sd0;
						bias_q[l] <= 32'sd0;
						mpos_q[l] <= 16'sd0;
						mneg_q[l] <= 16'sd0;
						mpos32[l] <= 32'sd0;
						mtmp[l] <= 32'sd0;
						acc_sel[l] <= 32'sd0;
						m_sel[l] <= 16'sd0;
						acc_hi[l] <= 17'sd0;
						acc_lo[l] <= 17'sd0;
						prod_hi[l] <= 32'sd0;
						prod_lo[l] <= 32'sd0;
						prod64[l] <= 48'sd0;
						wby_r[l] <= 16'sd0;
						begin : sv2v_autoblock_17
							reg signed [31:0] px;
							for (px = 0; px < PX; px = px + 1)
								begin
									acc[px][l] <= 32'sd0;
									a_pipe[px][l] <= 8'sd0;
									a_pipe1[px][l] <= 8'sd0;
									a_pipe2[px][l] <= 8'sd0;
									prod[px][l] <= 16'sd0;
									mx[px][l] <= -8'sd128;
								end
						end
					end
			end
			cr_ks_f <= 1'b0;
			cr_st_f <= 1'b0;
			cr_pad_f <= 1'b0;
			cr_ic_f <= 1'b0;
			cr_ih_f <= 1'b0;
			cr_dw_f <= 1'b0;
			cr_p3_f <= 1'b0;
			pl_ks_f <= 1'b0;
			pl_st_f <= 1'b0;
			pl_pad_f <= 1'b0;
			pl_ic_f <= 1'b0;
			cp_ic_f <= 1'b0;
			cp_hw_f <= 1'b0;
			cp_cn_f <= 1'b0;
			ad_ic_f <= 1'b0;
			ad_hw_f <= 1'b0;
			ad_oc_f <= 1'b0;
			ad_r_f <= 1'b0;
			d_oh_f <= 1'b0;
		end
		else begin
			done_r <= 1'b0;
			ld_ret_v <= 1'b0;
			if ((state != 5'd0) && (state != 5'd27))
				cycles_r <= cycles_r + 32'd1;
			b_we_q <= b_we_c;
			b_addr_q <= b_addr_c;
			b_wdata_q <= b_wdata_c;
			b_wstrb_q <= b_wstrb_c;
			q_re_q <= q_re_c;
			q_addr_q <= q_addr_c;
			if ((state == 5'd7) && !f_p3)
				la <= la + band_step_a;
			if (state == 5'd10)
				wa_r <= wa_r + w_delta;
			if (state == 5'd13) begin
				if (c_p == (16'd5 + fad_off_w))
					wpx <= wr_base;
				else if ((c_p >= (16'd6 + fad_off_w)) && (c_p < ((16'd6 + fad_off_w) + wrbeats_r))) begin
					if (wr16_r && !wrs16_r)
						wpx <= wpx + (c_p[0] ? px_bytes - 24'd8 : 24'd8);
					else
						wpx <= wpx + px_bytes;
				end
			end
			if ((state == 5'd17) && (c_m == (ks16 - 16'd1)))
				wpx <= wr_base;
			if (state == 5'd18)
				wpx <= wpx + px_bytes;
			if (ld_ret_v) begin
				if (ld_fill_d)
					abuf[ld_j_d] <= {8 {ld_fillbyte_d}};
				else
					abuf[ld_j_d] <= (ld_half_d ? a_rdata[127:64] : a_rdata[63:0]);
				dwbuf[ld_j_d] <= (ld_fill_d ? {16 {ld_fillbyte_d}} : a_rdata);
			end
			mac_v1 <= mac_issue;
			mac_v2 <= mac_v1;
			mac_v3 <= mac_v2;
			mac_v4 <= mac_v3;
			if (mac_issue) begin : sv2v_autoblock_18
				reg signed [31:0] px;
				for (px = 0; px < PX; px = px + 1)
					begin : sv2v_autoblock_19
						reg signed [31:0] oc;
						for (oc = 0; oc < OCL; oc = oc + 1)
							if (dense)
								a_pipe[px][oc] <= win_sel[px][sel_byte_base+:8];
							else if (f_dw16)
								a_pipe[px][oc] <= (sv2v_cast_16_signed(oc) < act_l ? dw_win[px][oc * 8+:8] : 8'sd0);
							else
								a_pipe[px][oc] <= (oc < 8 ? win_sel[px][oc * 8+:8] : 8'sd0);
					end
			end
			if (LAT2) begin : g_wlat2
				if (mac_v1) begin : sv2v_autoblock_20
					reg signed [31:0] px;
					for (px = 0; px < PX; px = px + 1)
						begin : sv2v_autoblock_21
							reg signed [31:0] oc;
							for (oc = 0; oc < OCL; oc = oc + 1)
								a_pipe1[px][oc] <= a_pipe[px][oc];
						end
				end
				if (mac_v2) begin
					begin : sv2v_autoblock_22
						reg signed [31:0] oc;
						for (oc = 0; oc < OCL; oc = oc + 1)
							wby_r[oc] <= (dense || (sv2v_cast_16_signed(oc) < act_l) ? $signed(w_rdata[oc * 8+:8]) : 16'sd0);
					end
					begin : sv2v_autoblock_23
						reg signed [31:0] px;
						for (px = 0; px < PX; px = px + 1)
							begin : sv2v_autoblock_24
								reg signed [31:0] oc;
								for (oc = 0; oc < OCL; oc = oc + 1)
									a_pipe2[px][oc] <= a_pipe1[px][oc];
							end
					end
				end
				if (mac_v3) begin : sv2v_autoblock_25
					reg signed [31:0] px;
					for (px = 0; px < PX; px = px + 1)
						begin : sv2v_autoblock_26
							reg signed [31:0] oc;
							for (oc = 0; oc < OCL; oc = oc + 1)
								prod[px][oc] <= $signed(a_pipe2[px][oc]) * wby_r[oc];
						end
				end
				if (mac_v4) begin : sv2v_autoblock_27
					reg signed [31:0] px;
					for (px = 0; px < PX; px = px + 1)
						begin : sv2v_autoblock_28
							reg signed [31:0] oc;
							for (oc = 0; oc < OCL; oc = oc + 1)
								acc[px][oc] <= acc[px][oc] + {{16 {prod[px][oc][15]}}, prod[px][oc]};
						end
				end
			end
			else begin : g_wlat1
				if (mac_v1) begin
					begin : sv2v_autoblock_29
						reg signed [31:0] oc;
						for (oc = 0; oc < OCL; oc = oc + 1)
							wby_r[oc] <= (dense || (sv2v_cast_16_signed(oc) < act_l) ? $signed(w_rdata[oc * 8+:8]) : 16'sd0);
					end
					begin : sv2v_autoblock_30
						reg signed [31:0] px;
						for (px = 0; px < PX; px = px + 1)
							begin : sv2v_autoblock_31
								reg signed [31:0] oc;
								for (oc = 0; oc < OCL; oc = oc + 1)
									a_pipe2[px][oc] <= a_pipe[px][oc];
							end
					end
				end
				if (mac_v2) begin : sv2v_autoblock_32
					reg signed [31:0] px;
					for (px = 0; px < PX; px = px + 1)
						begin : sv2v_autoblock_33
							reg signed [31:0] oc;
							for (oc = 0; oc < OCL; oc = oc + 1)
								prod[px][oc] <= $signed(a_pipe2[px][oc]) * wby_r[oc];
						end
				end
				if (mac_v3) begin : sv2v_autoblock_34
					reg signed [31:0] px;
					for (px = 0; px < PX; px = px + 1)
						begin : sv2v_autoblock_35
							reg signed [31:0] oc;
							for (oc = 0; oc < OCL; oc = oc + 1)
								acc[px][oc] <= acc[px][oc] + {{16 {prod[px][oc][15]}}, prod[px][oc]};
						end
				end
			end
			if (win_adv) begin
				begin : sv2v_autoblock_36
					reg signed [31:0] i;
					for (i = 0; i < 14; i = i + 1)
						bshift[i] <= bshift[i + 1];
				end
				bshift[14] <= abuf[15 + cur_kx[3:0]];
				begin : sv2v_autoblock_37
					reg signed [31:0] i;
					for (i = 0; i < 14; i = i + 1)
						dwbsh[i] <= dwbsh[i + 1];
				end
				dwbsh[14] <= dwbuf[15 + cur_kx[3:0]];
			end
			if (state == 5'd13) begin
				if (c_p <= 16'd7) begin : sv2v_autoblock_38
					reg signed [31:0] l;
					for (l = 0; l < OCL; l = l + 1)
						begin
							acc_sel[l] <= acc[c_p[2:0]][l];
							m_sel[l] <= (acc[c_p[2:0]][l] < 0 ? mneg_q[l] : mpos_q[l]);
						end
				end
				if ((c_p >= 16'd1) && (c_p <= 16'd8)) begin : sv2v_autoblock_39
					reg signed [31:0] l;
					for (l = 0; l < OCL; l = l + 1)
						begin
							acc_hi[l] <= $signed(acc_sel[l][31:16]);
							acc_lo[l] <= $signed({1'b0, acc_sel[l][15:0]});
							prod_hi[l] <= $signed(acc_sel[l][31:16]) * $signed(m_sel[l]);
							prod_lo[l] <= $signed({1'b0, acc_sel[l][15:0]}) * $signed(m_sel[l]);
						end
				end
				if ((c_p >= 16'd2) && (c_p <= 16'd9)) begin : sv2v_autoblock_40
					reg signed [47:0] ph;
					begin : sv2v_autoblock_41
						reg signed [31:0] l;
						for (l = 0; l < OCL; l = l + 1)
							begin
								ph = $signed({{16 {prod_hi[l][31]}}, prod_hi[l]}) <<< 16;
								prod64[l] <= ph + $signed({{16 {prod_lo[l][31]}}, prod_lo[l]});
							end
					end
				end
				if ((c_p >= 16'd3) && (c_p <= 16'd10)) begin : sv2v_autoblock_42
					reg signed [31:0] l;
					for (l = 0; l < OCL; l = l + 1)
						if (shift_q >= 8'd16)
							y64_q[l] <= (prod64[l] >>> 16) >>> shift_q[3:0];
						else
							y64_q[l] <= prod64[l] >>> shift_q[3:0];
				end
				if ((c_p >= 16'd4) && (c_p <= 16'd11)) begin : sv2v_autoblock_43
					reg signed [31:0] l;
					for (l = 0; l < OCL; l = l + 1)
						y2_q[l] <= y64_q[l] + {{40 {zp_out[7]}}, zp_out};
				end
				if ((c_p >= 16'd5) && (c_p <= 16'd12)) begin
					out_lo[c_p[2:0] - 3'd5] <= rq_pack[63:0];
					out_hi[c_p[2:0] - 3'd5] <= rq_pack[127:64];
				end
				if ((fad_active && (c_p >= 16'd6)) && (c_p <= 16'd13)) begin : fad_l1a
					begin : sv2v_autoblock_44
						reg signed [31:0] l;
						for (l = 0; l < 8; l = l + 1)
							begin
								fad_dv_lo[l] <= $signed(out_lo[c_p[3:0] - 4'd6][l * 8+:8]) - $signed(zp_out);
								fad_dv_hi[l] <= $signed(out_hi[c_p[3:0] - 4'd6][l * 8+:8]) - $signed(zp_out);
							end
					end
				end
				if ((fad_active && (c_p >= 16'd7)) && (c_p <= 16'd14)) begin : fad_l1b
					begin : sv2v_autoblock_45
						reg signed [31:0] l;
						for (l = 0; l < 8; l = l + 1)
							begin
								fad_dlo[l] <= (fad_dv_lo[l] * $signed({1'b0, fad_r})) >>> fad_kadd[3:0];
								fad_dhi[l] <= (fad_dv_hi[l] * $signed({1'b0, fad_r})) >>> fad_kadd[3:0];
							end
					end
				end
				if ((fad_active && (c_p >= 16'd8)) && (c_p <= 16'd15)) begin : fad_l2
					fad_plo[c_p[3:0] - 4'd8] <= fad_add({fad_dlo[7], fad_dlo[6], fad_dlo[5], fad_dlo[4], fad_dlo[3], fad_dlo[2], fad_dlo[1], fad_dlo[0]}, ad_cap[c_p[3:0] - 4'd8][63:0]);
					fad_phi[c_p[3:0] - 4'd8] <= fad_add({fad_dhi[7], fad_dhi[6], fad_dhi[5], fad_dhi[4], fad_dhi[3], fad_dhi[2], fad_dhi[1], fad_dhi[0]}, ad_cap[c_p[3:0] - 4'd8][127:64]);
				end
			end
			case (state)
				5'd0:
					if (start) begin
						d_op <= desc[210-:2];
						d_flags <= desc[208-:8];
						d_ks <= desc[200-:4];
						d_st <= desc[196-:2];
						d_pad <= desc[194-:3];
						d_ih <= desc[191-:16];
						d_iw <= desc[175-:16];
						d_ic <= desc[159-:16];
						d_oc <= desc[143-:16];
						d_src <= desc[127-:32];
						d_dst <= desc[95-:32];
						d_woff <= desc[63-:32];
						d_qoff <= desc[31-:32];
						is_conv <= desc[210-:2] == nn_pkg_NN_OP_CONV;
						is_pool <= desc[210-:2] == nn_pkg_NN_OP_POOL;
						is_copy <= desc[210-:2] == nn_pkg_NN_OP_COPY;
						is_add <= desc[210-:2] == nn_pkg_NN_OP_ADD;
						f_dw <= desc[201];
						f_leaky <= desc[202];
						f_up2x <= desc[204];
						f_p3 <= desc[206];
						f_add_r <= desc[207];
						f_relu <= desc[208];
						fad_active <= desc[207] && (desc[210-:2] == nn_pkg_NN_OP_CONV);
						cycles_r <= 32'd0;
						err_r <= 8'h00;
						q_iss <= 5'd0;
						state <= 5'd1;
					end
				5'd1: begin
					cr_ks_f <= cr_ks_bad;
					cr_st_f <= cr_st_bad;
					cr_pad_f <= cr_pad_bad;
					cr_ic_f <= cr_ic_bad;
					cr_ih_f <= cr_ih_bad;
					cr_dw_f <= cr_dw_bad;
					cr_p3_f <= cr_p3_bad;
					pl_ks_f <= pl_ks_bad;
					pl_st_f <= pl_st_bad;
					pl_pad_f <= pl_pad_bad;
					pl_ic_f <= pl_ic_bad;
					cp_ic_f <= cp_ic_bad;
					cp_hw_f <= cp_hw_bad;
					cp_cn_f <= cp_cn_bad;
					ad_ic_f <= ad_ic_bad;
					ad_hw_f <= ad_hw_bad;
					ad_oc_f <= ad_oc_bad;
					ad_r_f <= ad_r_bad;
					d_oh_f <= d_oh_bad;
					state <= 5'd2;
				end
				5'd2:
					if (init_err != 8'h00) begin
						err_r <= init_err;
						state <= 5'd27;
					end
					else begin
						c_ocb <= 16'd0;
						c_oy <= 16'd0;
						c_oxg <= 16'd0;
						c_ky <= 16'd0;
						c_icb <= 16'd0;
						c_m <= 16'd0;
						c_ld <= 16'd0;
						c_p <= 16'd0;
						c_iy <= 16'd0;
						c_ix <= 16'd0;
						c_cb <= 16'd0;
						c_drn <= 3'd0;
						c_wr <= 2'd0;
						p3_ph <= 2'd0;
						state <= 5'd3;
					end
				5'd3: begin
					case (c_p)
						16'd0: begin
							pad_r <= pad_eff;
							ic8_r <= ic8;
							oc8_r <= oc8;
							st2_r <= d_st == 2'd2;
							ocw_r <= (is_pool ? 16'd8 : (f_dw && !f_dw16 ? 16'd8 : 16'd16));
						end
						16'd1: begin
							icb_n_r <= ic8_r >> 3;
							oc_limit_r <= (is_pool ? ic8_r >> 3 : (f_dw && !f_dw16 ? oc8_r >> 3 : (oc8_r + 16'd15) >> 4));
							if (is_copy) begin
								oh_w <= (f_up2x ? d_ih << 1 : d_ih);
								ow_w <= (f_up2x ? d_iw << 1 : d_iw);
							end
							else if (is_add) begin
								oh_w <= d_ih;
								ow_w <= d_iw;
							end
							else begin
								oh_w <= ((({1'b0, d_ih} + {13'd0, pad_r}) + {13'd0, pad_r}) >= {12'd0, d_ks} ? (((({1'b0, d_ih} + {13'd0, pad_r}) + {13'd0, pad_r}) - {12'd0, d_ks}) >> (st2_r ? 1 : 0)) + 16'd1 : 16'd1);
								ow_w <= ((({1'b0, d_iw} + {13'd0, pad_r}) + {13'd0, pad_r}) >= {12'd0, d_ks} ? (((({1'b0, d_iw} + {13'd0, pad_r}) + {13'd0, pad_r}) - {12'd0, d_ks}) >> (st2_r ? 1 : 0)) + 16'd1 : 16'd1);
							end
						end
						16'd2: begin
							row_step_a <= {8'd0, d_iw} * {8'd0, ic8_r};
							row_step_w <= ow_w * {8'd0, oc8_r};
							d_row_step <= {8'd0, d_iw} * {8'd0, oc8_r};
							px_bytes <= (is_pool ? {8'd0, ic8_r} : {8'd0, oc8_r});
						end
						16'd3: begin
							oy_step_a <= (st2_r ? row_step_a << 1 : row_step_a);
							ox_step_a <= (st2_r ? {8'd0, ic8_r} << 4 : {8'd0, ic8_r} << 3);
							band_step_a <= (dense && (d_ks == 4'd1) ? (st2_r ? {8'd0, ic8_r} << 1 : {8'd0, ic8_r}) : {8'd0, ic8_r});
							band_ky_step <= (dense && (d_ks != 4'd1) ? (row_step_a - {8'd0, ic8_r}) + 24'd8 : row_step_a);
							base0_t <= {21'd0, pad_r} * row_step_a;
							base0_t2 <= {21'd0, pad_r} * {8'd0, ic8_r};
							ox_step_w <= px_bytes << 3;
							up_px_row <= d_row_step << 1;
							ups_dx <= {8'd0, oc8_r};
							w_p2 <= {8'd0, oc8_r};
							p1 <= {8'd0, ic8_r} * {8'd0, oc8_r};
							dx_r <= (dense && (d_ks == 4'd1) ? (st2_r ? 16'd2 : 16'd1) : 16'd1);
							ld_count_r <= (dense && (d_ks == 4'd1) ? 16'd8 : (7 * st16) + ks16);
							ld_m1_r <= (dense && (d_ks == 4'd1) ? 16'd8 : (7 * st16) + ks16) - 16'd1;
							p3_row <= ({8'd0, d_iw} << 1) + {8'd0, d_iw};
						end
						16'd4: begin
							base0_a <= (d_src[23:0] - base0_t) - base0_t2;
							cp_dst_pix <= ({8'd0, oc8_r} - {8'd0, ic8_r}) + 24'd8;
							d_row_step2 <= ((d_row_step << 1) + {8'd0, oc8_r}) + 24'd8;
							d_x_step <= {8'd0, oc8_r} + 24'd8;
							p1_2 <= p1 << 1;
							p1_3 <= p1 + (p1 << 1);
							p1_4 <= p1 << 2;
							w_dgrp <= p1 - (({8'd0, oc8_r} << 3) - {8'd0, oc8_r});
							p3_oy <= (st2_r ? p3_row << 1 : p3_row);
							p3_ox <= (st2_r ? 24'd48 : 24'd24);
						end
						16'd5: begin
							begin : qc0
								reg [15:0] a0;
								a0 = (oc8_r >= ocw_r ? ocw_r : oc8_r);
								qb_w_r <= sv2v_cast_5(a0 >> 1);
								qm_w_r <= sv2v_cast_5(a0 >> 2);
								q_tot_r <= sv2v_cast_5(((a0 >> 1) + (a0 >> 2)) + 16'd1);
								q_bias_w <= sv2v_cast_13(d_qoff[15:0] >> 3);
								q_mpos_w <= sv2v_cast_13((d_qoff[15:0] + (oc8_r << 2)) >> 3);
								q_tail_w <= sv2v_cast_13(((d_qoff[15:0] + (oc8_r << 2)) + (oc8_r << 1)) >> 3);
								rem_ch <= (oc8_r > ocw_r ? oc8_r - ocw_r : 16'd0);
							end
							w_sub <= {8'd0, oc8_r} - (d_ks == 4'd1 ? 24'd0 : (d_ks == 4'd2 ? p1 : (d_ks == 4'd3 ? p1_2 : (d_ks == 4'd4 ? p1_3 : p1_4))));
							row_base_a <= (f_p3 ? d_src[23:0] - ({21'd0, pad_r} * (p3_row + 24'd3)) : base0_a);
							blk_base <= (f_p3 ? d_src[23:0] - ({21'd0, pad_r} * (p3_row + 24'd3)) : base0_a);
							row_base_w <= d_dst[23:0];
							wr_base <= d_dst[23:0];
							src_la <= d_src[23:0];
							dst_la <= d_dst[23:0];
							sel_a_src <= d_src >= nn_pkg_NN_B_OFF;
							sel_b_dst <= d_dst >= nn_pkg_NN_B_OFF;
							c_p <= 16'd0;
							if (is_conv) begin
								q_iss <= 5'd0;
								state <= 5'd4;
							end
							else if (is_pool)
								state <= 5'd16;
							else if (is_copy)
								state <= 5'd19;
							else
								state <= (f_add_r || f_relu ? 5'd21 : 5'd22);
						end
						default:
							;
					endcase
					if (c_p != 16'd5)
						c_p <= c_p + 16'd1;
				end
				5'd4: begin
					if (q_iss == 5'd0) begin : sv2v_autoblock_46
						reg signed [31:0] l;
						for (l = 0; l < OCL; l = l + 1)
							begin
								bias_q[l] <= 32'sd0;
								mpos_q[l] <= 16'sd0;
							end
					end
					if (sv2v_cast_16(q_iss) < (q_tot + 16'd2))
						q_iss <= q_iss + 5'd1;
					if ((q_iss >= 5'd2) && (q_iss <= (q_tot + 16'd1))) begin
						if ((q_iss - 5'd2) < qb_w) begin
							bias_q[2 * (q_iss - 5'd2)] <= $signed(q_rdata[31:0]);
							bias_q[(2 * (q_iss - 5'd2)) + 1] <= $signed(q_rdata[63:32]);
						end
						else if ((q_iss - 5'd2) < (qb_w + qm_w)) begin
							mpos_q[(4 * ((q_iss - 2) - qb_w)) + 0] <= $signed(q_rdata[15:0]);
							mpos_q[(4 * ((q_iss - 2) - qb_w)) + 1] <= $signed(q_rdata[31:16]);
							mpos_q[(4 * ((q_iss - 2) - qb_w)) + 2] <= $signed(q_rdata[47:32]);
							mpos_q[(4 * ((q_iss - 2) - qb_w)) + 3] <= $signed(q_rdata[63:48]);
						end
						else begin
							zp_out <= q_rdata[7:0];
							zp_in <= q_rdata[15:8];
							leaky_q <= q_rdata[16];
							shift_q <= q_rdata[31:24];
							fad_zp_d <= q_rdata[39:32];
							fad_kadd <= q_rdata[47:40];
							fad_r <= q_rdata[63:48];
						end
					end
					if (sv2v_cast_16(q_iss) == (q_tot + 16'd1))
						state <= 5'd5;
				end
				5'd5:
					if (!c_ql) begin
						begin : sv2v_autoblock_47
							reg signed [31:0] l;
							for (l = 0; l < OCL; l = l + 1)
								begin
									mpos32[l] <= {{16 {mpos_q[l][15]}}, mpos_q[l]};
									mtmp[l] <= {{16 {mpos_q[l][15]}}, mpos_q[l]} * 32'sd3277;
								end
						end
						c_ql <= 1'b1;
					end
					else begin
						begin : sv2v_autoblock_48
							reg signed [31:0] l;
							for (l = 0; l < OCL; l = l + 1)
								mneg_q[l] <= (f_relu ? 16'sd0 : (leaky_q ? sv2v_cast_16((mtmp[l] + 32'sd16384) >>> 15) : mpos_q[l]));
						end
						c_ql <= 1'b0;
						state <= 5'd6;
					end
				5'd6: begin
					begin : sv2v_autoblock_49
						reg signed [31:0] px;
						for (px = 0; px < PX; px = px + 1)
							begin : sv2v_autoblock_50
								reg signed [31:0] oc;
								for (oc = 0; oc < OCL; oc = oc + 1)
									acc[px][oc] <= bias_q[oc];
							end
					end
					c_ky <= 16'd0;
					c_icb <= 16'd0;
					c_m <= 16'd0;
					c_ld <= 16'd0;
					p3_ph <= 2'd0;
					icb_more_r <= 16'd1 < icb_n_r;
					wa_r <= d_woff[23:0] + {8'd0, oc_base_w};
					if (f_p3) begin
						band_base <= blk_base;
						la <= blk_base;
					end
					else begin
						band_base <= (f_dw ? blk_base + (f_dw16 ? c_ocb << 4 : c_ocb << 3) : blk_base);
						la <= (f_dw ? blk_base + (f_dw16 ? c_ocb << 4 : c_ocb << 3) : blk_base);
					end
					x_ld <= x0_c;
					x0_ld <= x0_c;
					y_ld <= y_ky0;
					y_ok_r <= (y_ky0 >= 0) && (y_ky0 < $signed(d_ih));
					state <= 5'd7;
				end
				5'd7:
					if (f_p3)
						case (p3_ph)
							2'd0: p3_ph <= 2'd1;
							2'd1: begin
								p3w0 <= a_rdata;
								p3_ph <= 2'd2;
							end
							default: begin
								p3w1 <= a_rdata;
								begin : p3_emit
									reg [7:0] b0;
									reg [7:0] b1;
									reg [7:0] b2;
									reg [4:0] o5;
									reg [7:0] w32 [0:31];
									begin : sv2v_autoblock_51
										reg signed [31:0] k;
										for (k = 0; k < 8; k = k + 1)
											begin
												w32[k] = p3w0[k * 8+:8];
												w32[k + 8] = p3w0[(k + 8) * 8+:8];
												w32[k + 16] = a_rdata[k * 8+:8];
												w32[k + 24] = a_rdata[(k + 8) * 8+:8];
											end
									end
									o5 = {1'b0, la[3:0]};
									b0 = w32[o5];
									b1 = w32[o5 + 5'd1];
									b2 = w32[o5 + 5'd2];
									if (!ld_inb)
										abuf[c_ld[4:0]] <= {5 {ld_fill}};
									else
										abuf[c_ld[4:0]] <= {zp_in, zp_in, zp_in, zp_in, zp_in, b2, b1, b0};
								end
								la <= la + 24'd3;
								x_ld <= x_ld + $signed({15'd0, dx_r});
								c_ld <= c_ld + 16'd1;
								p3_ph <= 2'd0;
								if (c_ld == ld_m1_r)
									state <= 5'd8;
							end
						endcase
					else begin
						ld_j_d <= c_ld[4:0];
						ld_fill_d <= ~ld_inb;
						ld_half_d <= la[3];
						ld_fillbyte_d <= ld_fill;
						ld_ret_v <= 1'b1;
						x_ld <= x_ld + $signed({15'd0, dx_r});
						if (c_ld == ld_m1_r) begin
							c_ld <= 16'd0;
							state <= 5'd8;
						end
						else
							c_ld <= c_ld + 16'd1;
					end
				5'd8: begin
					c_m <= 16'd0;
					c_ld <= 16'd0;
					p3_ph <= 2'd0;
					if (f_p3) begin
						if ((c_ky + 16'd1) < ks16) begin
							band_base <= band_base + p3_row;
							la <= band_base + p3_row;
						end
						else begin
							band_base <= band_base;
							la <= band_base;
						end
					end
					else if (dense && icb_more_r) begin
						band_base <= band_base + 24'd8;
						la <= band_base + 24'd8;
					end
					else begin
						band_base <= band_base + band_ky_step;
						la <= band_base + band_ky_step;
					end
					if (dense && (d_ks == 4'd1))
						state <= 5'd10;
					else
						state <= 5'd9;
				end
				5'd9: begin
					begin : sv2v_autoblock_52
						reg signed [31:0] i;
						for (i = 0; i < WINW; i = i + 1)
							bshift[i] <= abuf[i];
					end
					begin : sv2v_autoblock_53
						reg signed [31:0] i;
						for (i = 0; i < WINW; i = i + 1)
							dwbsh[i] <= dwbuf[i];
					end
					c_m <= 16'd0;
					state <= (is_pool ? 5'd17 : 5'd10);
				end
				5'd10:
					if (dense) begin
						c_m <= c_m + 16'd1;
						if (c_m == ((ks16 << 3) - 16'd1)) begin
							c_m <= 16'd0;
							if ((c_icb + 16'd1) < icb_n_r) begin
								c_icb <= c_icb + 16'd1;
								icb_more_r <= (c_icb + 16'd2) < icb_n_r;
								c_ld <= 16'd0;
								x_ld <= x0_ld;
								y_ok_r <= (y_ld >= 0) && (y_ld < $signed(d_ih));
								state <= 5'd7;
							end
							else if ((c_ky + 16'd1) < ks16) begin
								c_ky <= c_ky + 16'd1;
								c_icb <= 16'd0;
								icb_more_r <= 16'd1 < icb_n_r;
								c_ld <= 16'd0;
								x_ld <= x0_ld;
								y_ld <= y_ld + 16'sd1;
								y_ok_r <= ((y_ld + 16'sd1) >= 0) && ((y_ld + 16'sd1) < $signed(d_ih));
								state <= 5'd7;
							end
							else begin
								c_drn <= 3'd0;
								state <= 5'd11;
							end
						end
					end
					else begin
						c_m <= c_m + 16'd1;
						if (c_m == (ks16 - 16'd1)) begin
							c_m <= 16'd0;
							if ((c_ky + 16'd1) < ks16) begin
								c_ky <= c_ky + 16'd1;
								c_ld <= 16'd0;
								x_ld <= x0_ld;
								y_ld <= y_ld + 16'sd1;
								y_ok_r <= ((y_ld + 16'sd1) >= 0) && ((y_ld + 16'sd1) < $signed(d_ih));
								state <= 5'd7;
							end
							else begin
								c_drn <= 3'd0;
								state <= 5'd11;
							end
						end
					end
				5'd11: begin
					if (c_drn == 16'd0) begin
						wr16_r <= wr_dense16;
						wrs16_r <= single16;
						wrbeats_r <= req_beats;
					end
					if (c_drn == (DRNN - 1)) begin
						c_drn <= 3'd0;
						c_p <= 16'd0;
						state <= (fad_active ? 5'd12 : 5'd13);
					end
					else
						c_drn <= c_drn + 3'd1;
				end
				5'd12: begin
					if ((c_p >= 16'd1) && (c_p <= wrbeats_r)) begin
						if (wrs16_r)
							ad_cap[c_p[3:0] - 16'd1] <= a_rdata;
						else
							ad_cap[(c_p[3:0] - 16'd1) >> 1] <= a_rdata;
					end
					if (c_p == (wrbeats_r + 16'd1)) begin
						c_p <= 16'd0;
						state <= 5'd13;
					end
					else
						c_p <= c_p + 16'd1;
				end
				5'd13:
					if (c_p == (reqn_w - 16'd1)) begin
						c_p <= 16'd0;
						state <= 5'd14;
					end
					else
						c_p <= c_p + 16'd1;
				5'd14: begin
					row_base_a_n <= row_base_a + (f_p3 ? p3_oy : oy_step_a);
					row_base_w_n <= row_base_w + row_step_w;
					if ((ox0 + 16'd8) < ow_w)
						nxt_sel <= 2'd0;
					else if ((c_oy + 16'd1) < oh_w)
						nxt_sel <= 2'd1;
					else
						nxt_sel <= 2'd2;
					state <= 5'd15;
				end
				5'd15:
					case (nxt_sel)
						2'd0: begin
							c_oxg <= c_oxg + 16'd1;
							blk_base <= blk_base + (f_p3 ? p3_ox : ox_step_a);
							wr_base <= wr_base + ox_step_w;
							state <= (is_pool ? 5'd16 : 5'd6);
						end
						2'd1: begin
							c_oxg <= 16'd0;
							c_oy <= c_oy + 16'd1;
							row_base_a <= row_base_a_n;
							blk_base <= row_base_a_n;
							row_base_w <= row_base_w_n;
							wr_base <= row_base_w_n;
							state <= (is_pool ? 5'd16 : 5'd6);
						end
						default: begin
							c_oy <= 16'd0;
							c_oxg <= 16'd0;
							c_ocb <= c_ocb + 16'd1;
							if ((c_ocb + 16'd1) < oc_limit_r) begin
								row_base_a <= (f_p3 ? d_src[23:0] - ({21'd0, pad_r} * (p3_row + 24'd3)) : base0_a);
								blk_base <= (f_p3 ? d_src[23:0] - ({21'd0, pad_r} * (p3_row + 24'd3)) : base0_a);
								row_base_w <= d_dst[23:0] + ((c_ocb + 16'd1) * ocw_r);
								wr_base <= d_dst[23:0] + ((c_ocb + 16'd1) * ocw_r);
								begin : qc1
									reg [15:0] rem_n;
									reg [15:0] a_n;
									a_n = (rem_ch >= ocw_r ? ocw_r : rem_ch);
									rem_n = (rem_ch > a_n ? rem_ch - a_n : 16'd0);
									rem_ch <= rem_n;
									qb_w_r <= sv2v_cast_5(a_n >> 1);
									qm_w_r <= sv2v_cast_5(a_n >> 2);
									q_tot_r <= sv2v_cast_5(((a_n >> 1) + (a_n >> 2)) + 16'd1);
									q_bias_w <= q_bias_w + sv2v_cast_13(ocw_r >> 1);
									q_mpos_w <= q_mpos_w + sv2v_cast_13(ocw_r >> 2);
								end
								if (is_pool)
									state <= 5'd16;
								else begin
									q_iss <= 5'd0;
									state <= 5'd4;
								end
							end
							else
								state <= 5'd27;
						end
					endcase
				5'd16: begin
					begin : sv2v_autoblock_54
						reg signed [31:0] px;
						for (px = 0; px < PX; px = px + 1)
							begin : sv2v_autoblock_55
								reg signed [31:0] oc;
								for (oc = 0; oc < OCL; oc = oc + 1)
									mx[px][oc] <= -8'sd128;
							end
					end
					c_ky <= 16'd0;
					c_m <= 16'd0;
					c_ld <= 16'd0;
					c_p <= 16'd0;
					band_base <= blk_base + (c_ocb << 3);
					la <= blk_base + (c_ocb << 3);
					x_ld <= x0_c;
					x0_ld <= x0_c;
					y_ld <= y_ky0;
					y_ok_r <= (y_ky0 >= 0) && (y_ky0 < $signed(d_ih));
					state <= 5'd7;
				end
				5'd17: begin
					begin : sv2v_autoblock_56
						reg signed [31:0] px;
						for (px = 0; px < PX; px = px + 1)
							begin : sv2v_autoblock_57
								reg signed [31:0] oc;
								for (oc = 0; oc < OCL; oc = oc + 1)
									if (oc < 8) begin
										if ($signed(win_sel[px][oc * 8+:8]) > mx[px][oc])
											mx[px][oc] <= $signed(win_sel[px][oc * 8+:8]);
									end
							end
					end
					c_m <= c_m + 16'd1;
					if (c_m == (ks16 - 16'd1)) begin
						c_m <= 16'd0;
						if ((c_ky + 16'd1) < ks16) begin
							c_ky <= c_ky + 16'd1;
							c_ld <= 16'd0;
							x_ld <= x0_ld;
							y_ld <= y_ld + 16'sd1;
							y_ok_r <= ((y_ld + 16'sd1) >= 0) && ((y_ld + 16'sd1) < $signed(d_ih));
							state <= 5'd7;
						end
						else begin
							c_p <= 16'd0;
							state <= 5'd18;
						end
					end
				end
				5'd18:
					if (c_p == 16'd7) begin
						c_p <= 16'd0;
						state <= 5'd14;
					end
					else
						c_p <= c_p + 16'd1;
				5'd19: begin
					rd_half_s <= src_la[3];
					c_wr <= 2'd0;
					state <= 5'd20;
				end
				5'd20: begin
					if (c_wr == 2'd0)
						cp_word_q <= (rd_half_s ? a_rdata[127:64] : a_rdata[63:0]);
					if (f_up2x && (c_wr != 2'd3))
						c_wr <= c_wr + 2'd1;
					else begin
						c_wr <= 2'd0;
						if ((c_cb + 16'd1) < icb_n_r) begin
							c_cb <= c_cb + 16'd1;
							src_la <= src_la + 24'd8;
							dst_la <= dst_la + 24'd8;
							state <= 5'd19;
						end
						else if ((c_ix + 16'd1) < d_iw) begin
							c_cb <= 16'd0;
							c_ix <= c_ix + 16'd1;
							src_la <= src_la + 24'd8;
							dst_la <= dst_la + (f_up2x ? d_x_step : cp_dst_pix);
							state <= 5'd19;
						end
						else if ((c_iy + 16'd1) < d_ih) begin
							c_cb <= 16'd0;
							c_ix <= 16'd0;
							c_iy <= c_iy + 16'd1;
							src_la <= src_la + 24'd8;
							dst_la <= dst_la + (f_up2x ? d_row_step2 : cp_dst_pix);
							state <= 5'd19;
						end
						else
							state <= 5'd27;
					end
				end
				5'd21: state <= 5'd22;
				5'd22: begin
					rd_half_s <= src_la[3];
					state <= 5'd23;
				end
				5'd23: begin
					rd_half_d <= dst_la[3];
					src_word_q <= ad_src_word;
					begin : sv2v_autoblock_58
						reg signed [31:0] l;
						for (l = 0; l < 8; l = l + 1)
							ad_qs[l] <= $signed(ad_src_word[l * 8+:8]);
					end
					if ((((f_add_r || f_relu) && (c_iy == 16'd0)) && (c_ix == 16'd0)) && (c_cb == 16'd0)) begin
						if (f_add_r) begin
							zp_s_r <= q_rdata[7:0];
							zp_d_r <= q_rdata[15:8];
							add_r_r <= {q_rdata[31:24], q_rdata[23:16]};
							kadd_r <= q_rdata[39:32];
						end
						else
							zp_d_r <= q_rdata[15:8];
					end
					state <= 5'd24;
				end
				5'd24: begin
					begin : ad_qq_calc
						reg signed [7:0] qs;
						reg [63:0] dword;
						dword = (rd_half_d ? a_rdata[127:64] : a_rdata[63:0]);
						ad_dst_q <= dword;
						begin : sv2v_autoblock_59
							reg signed [31:0] l;
							for (l = 0; l < 8; l = l + 1)
								begin
									qs = ad_qs[l];
									ad_qq[l] <= {qs[7], qs};
									ad_mul[l] <= ($signed(qs) - $signed(zp_s_r)) * $signed({1'b0, add_r_r});
								end
						end
					end
					state <= 5'd25;
				end
				5'd25: begin
					begin : ad_delta_calc
						reg signed [31:0] p;
						begin : sv2v_autoblock_60
							reg signed [31:0] l;
							for (l = 0; l < 8; l = l + 1)
								if (f_add_r) begin
									p = ad_mul[l] >>> kadd_r;
									ad_delta[l] <= p[8:0];
								end
								else
									ad_delta[l] <= ad_qq[l];
						end
					end
					state <= 5'd26;
				end
				5'd26:
					if ((c_cb + 16'd1) < icb_n_r) begin
						c_cb <= c_cb + 16'd1;
						src_la <= src_la + 24'd8;
						dst_la <= dst_la + 24'd8;
						state <= 5'd22;
					end
					else if ((c_ix + 16'd1) < d_iw) begin
						c_cb <= 16'd0;
						c_ix <= c_ix + 16'd1;
						src_la <= src_la + 24'd8;
						dst_la <= dst_la + 24'd8;
						state <= 5'd22;
					end
					else if ((c_iy + 16'd1) < d_ih) begin
						c_cb <= 16'd0;
						c_ix <= 16'd0;
						c_iy <= c_iy + 16'd1;
						src_la <= src_la + 24'd8;
						dst_la <= dst_la + 24'd8;
						state <= 5'd22;
					end
					else
						state <= 5'd27;
				5'd27: begin
					done_r <= 1'b1;
					state <= 5'd0;
				end
				default: state <= 5'd0;
			endcase
		end
	assign busy = state != 5'd0;
	assign done = done_r;
	assign cycles = cycles_r;
	assign err_code = err_r;
	initial _sv2v_0 = 0;
endmodule
module nn_mem (
	clk,
	rst,
	cpu_re,
	cpu_we,
	cpu_addr,
	cpu_wdata,
	cpu_wstrb,
	cpu_rdata,
	w_re,
	w_addr,
	w_rdata,
	q_re,
	q_addr,
	q_rdata,
	a_sel,
	a_re,
	a_addr,
	a_rdata,
	b_sel,
	b_we,
	b_addr,
	b_wdata,
	b_wstrb,
	dbg_we,
	dbg_space,
	dbg_addr,
	dbg_wdata,
	w_mode,
	w_bank_sel,
	wfill_we,
	wfill_addr,
	wfill_wdata,
	q_bank_sel,
	qfill_we,
	qfill_addr,
	qfill_wdata
);
	reg _sv2v_0;
	parameter signed [31:0] W_BYTES = 327680;
	parameter signed [31:0] Q_BYTES = 49152;
	parameter signed [31:0] A_BYTES = 98304;
	parameter signed [31:0] B_BYTES = 32768;
	parameter signed [31:0] CPU_AW = 19;
	input wire clk;
	input wire rst;
	input wire cpu_re;
	input wire cpu_we;
	input wire [31:0] cpu_addr;
	input wire [31:0] cpu_wdata;
	input wire [3:0] cpu_wstrb;
	output wire [31:0] cpu_rdata;
	input wire w_re;
	input wire [23:0] w_addr;
	output wire [127:0] w_rdata;
	input wire q_re;
	input wire [12:0] q_addr;
	output wire [63:0] q_rdata;
	input wire [1:0] a_sel;
	input wire a_re;
	input wire [23:0] a_addr;
	output wire [127:0] a_rdata;
	input wire [1:0] b_sel;
	input wire b_we;
	input wire [23:0] b_addr;
	input wire [127:0] b_wdata;
	input wire [15:0] b_wstrb;
	input wire dbg_we;
	input wire dbg_space;
	input wire [16:0] dbg_addr;
	input wire [31:0] dbg_wdata;
	input wire w_mode;
	input wire w_bank_sel;
	input wire wfill_we;
	input wire [17:0] wfill_addr;
	input wire [63:0] wfill_wdata;
	input wire q_bank_sel;
	input wire qfill_we;
	input wire [12:0] qfill_addr;
	input wire [63:0] qfill_wdata;
	localparam signed [31:0] W_WORDS = W_BYTES / 4;
	localparam signed [31:0] W64 = W_BYTES / 8;
	localparam signed [31:0] Q_WORDS = Q_BYTES / 4;
	localparam signed [31:0] Q64 = Q_WORDS / 2;
	localparam signed [31:0] QLO = 4096;
	localparam signed [31:0] QHI = Q64 - QLO;
	localparam signed [31:0] WSEG_A = 16384;
	localparam signed [31:0] WSEG_B = 8192;
	localparam signed [31:0] WSEG_C = 8192;
	localparam signed [31:0] WSEG_D = ((W64 - WSEG_A) - WSEG_B) - WSEG_C;
	localparam signed [31:0] ACT_BYTES = A_BYTES + B_BYTES;
	localparam signed [31:0] ACT_WORDS = ACT_BYTES / 16;
	localparam signed [31:0] ACT_AW = $clog2(ACT_WORDS);
	localparam [31:0] nn_pkg_NN_A_OFF = 32'h00060000;
	localparam [31:0] A_OFF = nn_pkg_NN_A_OFF;
	localparam [31:0] B_OFF = nn_pkg_NN_A_OFF + A_BYTES;
	localparam [31:0] B_END = B_OFF + B_BYTES;
	localparam [31:0] Q_END = 32'h00050000 + Q_BYTES;
	localparam [31:0] WIN = 32'h00000001 << CPU_AW;
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	localparam [0:0] ACT_ABS_OK = ((sv2v_cast_32_signed(nn_pkg_NN_A_OFF) % ACT_BYTES) == 0) && ((ACT_WORDS & (ACT_WORDS - 1)) == 0);
	localparam [31:0] nn_pkg_NN_W_BANKS = 2;
	localparam signed [31:0] W_BANKS = sv2v_cast_32_signed(nn_pkg_NN_W_BANKS);
	localparam signed [31:0] W_BANK_BYTES = W_BYTES / W_BANKS;
	localparam signed [31:0] W_BANK_W64 = W_BANK_BYTES / 8;
	localparam signed [31:0] W_BANK_AW = $clog2(W_BANK_BYTES);
	localparam [31:0] nn_pkg_NN_Q_BANK_BYTES = 8192;
	localparam [31:0] nn_pkg_NN_Q_BANK_W64 = 1024;
	localparam signed [31:0] Q_BANK_W64 = sv2v_cast_32_signed(nn_pkg_NN_Q_BANK_W64);
	localparam signed [31:0] Q_BANK_BYTES = sv2v_cast_32_signed(nn_pkg_NN_Q_BANK_BYTES);
	localparam [31:0] nn_pkg_NN_Q_FILL_AW = 13;
	localparam signed [31:0] Q_BANK_AW = sv2v_cast_32_signed(nn_pkg_NN_Q_FILL_AW);
	reg w_mode_i;
	reg w_bank_sel_i;
	reg wfill_we_i;
	reg q_bank_sel_i;
	reg qfill_we_i;
	always @(*) begin
		if (_sv2v_0)
			;
		w_mode_i = 1'b0;
		if (w_mode)
			w_mode_i = 1'b1;
		w_bank_sel_i = 1'b0;
		if (w_bank_sel)
			w_bank_sel_i = 1'b1;
		wfill_we_i = 1'b0;
		if (wfill_we)
			wfill_we_i = 1'b1;
		q_bank_sel_i = 1'b0;
		if (q_bank_sel)
			q_bank_sel_i = 1'b1;
		qfill_we_i = 1'b0;
		if (qfill_we)
			qfill_we_i = 1'b1;
	end
	localparam [31:0] nn_pkg_NN_B_OFF = 32'h00078000;
	initial begin
		$display("[nn_mem] v0.7 CONFIG W=%0dKB(%0d words) Q=%0dKB(%0d x64b) A=%0dKB B=%0dKB", W_BYTES / 1024, W_WORDS, Q_BYTES / 1024, Q64, A_BYTES / 1024, B_BYTES / 1024);
		$display("[nn_mem] v0.7 A_OFF=0x%05x B_OFF=0x%05x B_END=0x%05x Q_END=0x%05x CPU_WIN=0x%05x", A_OFF, B_OFF, B_END, Q_END, WIN);
		if (B_END > WIN)
			$display("[nn_mem] WARN: B_END 0x%05x 超出 CPU 窗口", B_END);
		if (B_OFF != nn_pkg_NN_B_OFF)
			$display("[nn_mem] WARN: B_OFF=0x%05x != nn_pkg::NN_B_OFF=0x%05x", B_OFF, nn_pkg_NN_B_OFF);
		if (WSEG_D <= 0)
			$display("[nn_mem] WARN: W 4 段拆分不成立 (WSEG_D=%0d)", WSEG_D);
		$display("[nn_mem] M2 CONFIG W banks=%0d x %0dKB (%0d x64b words/bank) Q shadow=%0d x %0dKB, wlen<=128KiB", W_BANKS, W_BANK_BYTES / 1024, W_BANK_W64, 2, Q_BANK_BYTES / 1024);
		$display("[nn_mem] ACT CONFIG A=%0dKB B=%0dKB A_OFF=0x%05x B_OFF=0x%05x B_END=0x%05x words=%0d idx=%s", A_BYTES / 1024, B_BYTES / 1024, A_OFF, B_OFF, B_END, ACT_WORDS, (ACT_ABS_OK ? "ABS-SLICE(default)" : "REL-OFFSET(big-A TB mode)"));
		if (W_BANK_W64 != 20480)
			$display("[nn_mem] WARN: W_BANK_W64=%0d != 20480 (wfill_addr/双银行契约按 20480 定义)", W_BANK_W64);
		if (Q_BANK_W64 > 2048)
			$display("[nn_mem] WARN: Q_BANK_W64=%0d 超过 lo 阵列一半 (%0d)", Q_BANK_W64, 2048);
	end
	wire w_dbg_we;
	wire q_dbg_we;
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	assign w_dbg_we = (dbg_we && (dbg_space == 1'b0)) && (sv2v_cast_32(dbg_addr) < W_WORDS);
	assign q_dbg_we = (dbg_we && (dbg_space == 1'b1)) && (sv2v_cast_32(dbg_addr) < Q_WORDS);
	(* ram_style = "block" *) reg [63:0] w_mem_a [0:16383];
	(* ram_style = "block" *) reg [63:0] w_mem_b [0:8191];
	(* ram_style = "block" *) reg [63:0] w_mem_c [0:8191];
	(* ram_style = "block" *) reg [63:0] w_mem_d [0:WSEG_D - 1];
	reg w_re_q;
	reg [23:0] w_addr_q;
	always @(posedge clk)
		if (rst) begin
			w_re_q <= 1'b0;
			w_addr_q <= 24'd0;
		end
		else begin
			w_re_q <= w_re;
			w_addr_q <= w_addr;
		end
	wire [14:0] w_idx;
	wire w_odd;
	wire [15:0] w_base;
	wire [15:0] w_nbase;
	wire [14:0] w_wi;
	wire [14:0] w_nwi;
	reg [1:0] w_seg;
	assign w_idx = w_addr_q[18:4];
	assign w_odd = w_addr_q[3];
	assign w_base = {w_idx, w_odd};
	assign w_nbase = w_base + 16'd1;
	assign w_wi = {w_addr_q[17:4], w_odd};
	assign w_nwi = w_wi + 15'd1;
	always @(*) begin
		if (_sv2v_0)
			;
		w_seg = 2'd3;
		if (w_base < 16'd16384)
			w_seg = 2'd0;
		else if (w_base < 16'd24576)
			w_seg = 2'd1;
		else if (w_base < 16'd32768)
			w_seg = 2'd2;
	end
	wire [15:0] w_wr_idx;
	reg [1:0] w_wr_seg;
	wire w_wr_half;
	assign w_wr_idx = dbg_addr[16:1];
	assign w_wr_half = dbg_addr[0];
	always @(*) begin
		if (_sv2v_0)
			;
		w_wr_seg = 2'd3;
		if (w_wr_idx < 16'd16384)
			w_wr_seg = 2'd0;
		else if (w_wr_idx < 16'd24576)
			w_wr_seg = 2'd1;
		else if (w_wr_idx < 16'd32768)
			w_wr_seg = 2'd2;
	end
	wire [13:0] a_ca;
	wire [13:0] a_na;
	wire [12:0] b_ca;
	wire [12:0] b_na;
	wire [12:0] c_ca;
	wire [12:0] c_na;
	wire [12:0] d_ca;
	wire [12:0] d_na;
	assign a_ca = (w_mode_i ? w_wi[13:0] : w_base[13:0]);
	assign a_na = (w_mode_i ? w_nwi[13:0] : w_nbase[13:0]);
	assign b_ca = (w_mode_i ? (w_bank_sel_i ? {1'b1, w_wi[11:0]} : w_wi[11:0]) : w_base[12:0]);
	assign b_na = (w_mode_i ? (w_bank_sel_i ? {1'b1, w_nwi[11:0]} : w_nwi[11:0]) : w_nbase[12:0]);
	assign c_ca = (w_mode_i ? {w_wi[13], w_wi[11:0]} : w_base[12:0]);
	assign c_na = (w_mode_i ? {w_nwi[13], w_nwi[11:0]} : w_nbase[12:0]);
	assign d_ca = (w_mode_i ? {w_wi[14], w_wi[11:0]} : w_base[12:0]);
	assign d_na = (w_mode_i ? {w_nwi[14], w_nwi[11:0]} : w_nbase[12:0]);
	wire wfill_en;
	wire wfill_inr;
	wire [15:0] wfill_g;
	wire fa_we;
	wire fb_we;
	wire fc_we;
	wire fd_we;
	wire fb_bwe;
	wire [13:0] fa_wa;
	wire [12:0] fb_wa;
	wire [12:0] fc_wa;
	wire [12:0] fd_wa;
	localparam [0:0] nn_pkg_NN_W_MODE_STREAM = 1'b1;
	assign wfill_en = wfill_we_i && (w_mode_i == nn_pkg_NN_W_MODE_STREAM);
	assign wfill_inr = sv2v_cast_32(wfill_addr) < W_BANK_W64;
	function automatic [15:0] sv2v_cast_16;
		input reg [15:0] inp;
		sv2v_cast_16 = inp;
	endfunction
	function automatic signed [15:0] sv2v_cast_16_signed;
		input reg signed [15:0] inp;
		sv2v_cast_16_signed = inp;
	endfunction
	assign wfill_g = (w_bank_sel_i ? {1'b0, wfill_addr[14:0]} : sv2v_cast_16(wfill_addr[14:0]) + sv2v_cast_16_signed(W_BANK_W64));
	assign fa_we = (wfill_en && wfill_inr) && (wfill_g < sv2v_cast_16_signed(WSEG_A));
	assign fb_we = ((wfill_en && wfill_inr) && (wfill_g >= sv2v_cast_16_signed(WSEG_A))) && (wfill_g < sv2v_cast_16_signed(WSEG_A + WSEG_B));
	assign fc_we = ((wfill_en && wfill_inr) && (wfill_g >= sv2v_cast_16_signed(WSEG_A + WSEG_B))) && (wfill_g < sv2v_cast_16_signed((WSEG_A + WSEG_B) + WSEG_C));
	assign fd_we = (wfill_en && wfill_inr) && (wfill_g >= sv2v_cast_16_signed((WSEG_A + WSEG_B) + WSEG_C));
	assign fa_wa = wfill_g[13:0];
	assign fb_wa = wfill_g[12:0];
	assign fc_wa = wfill_g[12:0];
	assign fd_wa = wfill_g[12:0];
	assign fb_bwe = fb_we && ~w_bank_sel_i;
	reg [63:0] w_cur_a;
	reg [63:0] w_cur_b;
	reg [63:0] w_cur_c;
	reg [63:0] w_cur_d;
	reg [63:0] w_nxt_a;
	reg [63:0] w_nxt_b;
	reg [63:0] w_nxt_c;
	reg [63:0] w_nxt_d;
	reg [15:0] w_base_r;
	reg [14:0] w_wi_r;
	reg [1:0] w_seg_r;
	reg w_mode_r;
	reg w_bank_r;
	reg w_rd_valid_r;
	wire w_addr_ok;
	always @(posedge clk) w_cur_a <= w_mem_a[a_ca];
	always @(posedge clk) w_cur_b <= w_mem_b[b_ca];
	always @(posedge clk) w_cur_c <= w_mem_c[c_ca];
	always @(posedge clk) w_cur_d <= w_mem_d[d_ca];
	wire [13:0] a_pba;
	wire [12:0] b_pba;
	wire [12:0] c_pba;
	wire [12:0] d_pba;
	assign a_pba = (fa_we ? fa_wa : a_na);
	assign b_pba = (fb_bwe ? fb_wa : b_na);
	assign c_pba = (fc_we ? fc_wa : c_na);
	assign d_pba = (fd_we ? fd_wa : d_na);
	always @(posedge clk) begin
		w_nxt_a <= w_mem_a[a_pba];
		if (w_dbg_we && (w_wr_seg == 2'd0)) begin
			if (w_wr_half)
				w_mem_a[w_wr_idx[13:0]][63:32] <= dbg_wdata;
			else
				w_mem_a[w_wr_idx[13:0]][31:0] <= dbg_wdata;
		end
		if (fa_we)
			w_mem_a[a_pba] <= wfill_wdata;
	end
	always @(posedge clk) begin
		w_nxt_b <= w_mem_b[b_pba];
		if (w_dbg_we && (w_wr_seg == 2'd1)) begin
			if (w_wr_half)
				w_mem_b[w_wr_idx[12:0]][63:32] <= dbg_wdata;
			else
				w_mem_b[w_wr_idx[12:0]][31:0] <= dbg_wdata;
		end
		if (fb_bwe)
			w_mem_b[b_pba] <= wfill_wdata;
	end
	always @(posedge clk) begin
		w_nxt_c <= w_mem_c[c_pba];
		if (w_dbg_we && (w_wr_seg == 2'd2)) begin
			if (w_wr_half)
				w_mem_c[w_wr_idx[12:0]][63:32] <= dbg_wdata;
			else
				w_mem_c[w_wr_idx[12:0]][31:0] <= dbg_wdata;
		end
		if (fc_we)
			w_mem_c[c_pba] <= wfill_wdata;
	end
	always @(posedge clk) begin
		w_nxt_d <= w_mem_d[d_pba];
		if (w_dbg_we && (w_wr_seg == 2'd3)) begin
			if (w_wr_half)
				w_mem_d[w_wr_idx[12:0]][63:32] <= dbg_wdata;
			else
				w_mem_d[w_wr_idx[12:0]][31:0] <= dbg_wdata;
		end
		if (fd_we)
			w_mem_d[d_pba] <= wfill_wdata;
	end
	assign w_addr_ok = (w_mode_i ? sv2v_cast_32(w_addr_q) < W_BANK_BYTES : sv2v_cast_32(w_addr_q) < W_BYTES);
	always @(posedge clk)
		if (rst) begin
			w_base_r <= 16'd0;
			w_wi_r <= 15'd0;
			w_seg_r <= 2'd0;
			w_mode_r <= 1'b0;
			w_bank_r <= 1'b0;
			w_rd_valid_r <= 1'b0;
		end
		else begin
			w_base_r <= w_base;
			w_wi_r <= w_wi;
			w_seg_r <= w_seg;
			w_mode_r <= w_mode_i;
			w_bank_r <= w_bank_sel_i;
			w_rd_valid_r <= w_re_q && w_addr_ok;
		end
	reg [63:0] w_cur_rom;
	reg [63:0] w_nxt_rom;
	reg [63:0] w_cur_s;
	reg [63:0] w_nxt_s;
	wire [63:0] w_cur;
	wire [63:0] w_nxt;
	always @(*) begin
		if (_sv2v_0)
			;
		case (w_seg_r)
			2'd0: w_cur_rom = w_cur_a;
			2'd1: w_cur_rom = w_cur_b;
			2'd2: w_cur_rom = w_cur_c;
			default: w_cur_rom = w_cur_d;
		endcase
	end
	always @(*) begin
		if (_sv2v_0)
			;
		if (w_base_r == 16'd16383)
			w_nxt_rom = w_nxt_b;
		else if (w_base_r == 16'd24575)
			w_nxt_rom = w_nxt_c;
		else if (w_base_r == 16'd32767)
			w_nxt_rom = w_nxt_d;
		else if (w_base_r == 16'd40959)
			w_nxt_rom = 64'b0000000000000000000000000000000000000000000000000000000000000000;
		else
			case (w_seg_r)
				2'd0: w_nxt_rom = w_nxt_a;
				2'd1: w_nxt_rom = w_nxt_b;
				2'd2: w_nxt_rom = w_nxt_c;
				default: w_nxt_rom = w_nxt_d;
			endcase
	end
	always @(*) begin
		if (_sv2v_0)
			;
		if (!w_bank_r)
			w_cur_s = (w_wi_r < 15'd16384 ? w_cur_a : w_cur_b);
		else
			w_cur_s = (w_wi_r < 15'd4096 ? w_cur_b : (w_wi_r < 15'd12288 ? w_cur_c : w_cur_d));
		if (w_wi_r == 15'd20479)
			w_nxt_s = 64'b0000000000000000000000000000000000000000000000000000000000000000;
		else if (!w_bank_r)
			w_nxt_s = (w_wi_r < 15'd16383 ? w_nxt_a : w_nxt_b);
		else
			w_nxt_s = (w_wi_r < 15'd4095 ? w_nxt_b : (w_wi_r < 15'd12287 ? w_nxt_c : w_nxt_d));
	end
	assign w_cur = (w_mode_r ? w_cur_s : w_cur_rom);
	assign w_nxt = (w_mode_r ? w_nxt_s : w_nxt_rom);
	assign w_rdata = (w_rd_valid_r ? {w_nxt, w_cur} : 128'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000);
	(* ram_style = "block" *) reg [63:0] q_mem_lo [0:4095];
	(* rom_style = "distributed" *) reg [63:0] q_mem_hi [0:QHI - 1];
	reg [63:0] q_rd_lo;
	reg [63:0] q_rd_hi;
	wire [63:0] q_rd;
	reg q_hi_r;
	reg q_mode_r;
	reg q_rd_valid_r;
	wire [11:0] q_lo_ra;
	assign q_lo_ra = (w_mode_i ? {1'b0, q_bank_sel_i, q_addr[9:0]} : q_addr[11:0]);
	wire qfill_en;
	wire qfill_inr;
	wire [11:0] q_lo_wa;
	assign qfill_en = qfill_we_i && (w_mode_i == nn_pkg_NN_W_MODE_STREAM);
	assign qfill_inr = sv2v_cast_32(qfill_addr) < Q_BANK_W64;
	assign q_lo_wa = {1'b0, ~q_bank_sel_i, qfill_addr[9:0]};
	function automatic signed [12:0] sv2v_cast_13_signed;
		input reg signed [12:0] inp;
		sv2v_cast_13_signed = inp;
	endfunction
	always @(posedge clk)
		if (qfill_en && qfill_inr)
			q_mem_lo[q_lo_wa] <= qfill_wdata;
		else if (q_dbg_we) begin
			if (dbg_addr[13:1] < sv2v_cast_13_signed(QLO)) begin
				if (dbg_addr[0])
					q_mem_lo[dbg_addr[12:1]][63:32] <= dbg_wdata;
				else
					q_mem_lo[dbg_addr[12:1]][31:0] <= dbg_wdata;
			end
			else if (dbg_addr[0])
				q_mem_hi[dbg_addr[11:1]][63:32] <= dbg_wdata;
			else
				q_mem_hi[dbg_addr[11:1]][31:0] <= dbg_wdata;
		end
	always @(posedge clk) begin
		q_rd_lo <= q_mem_lo[q_lo_ra];
		q_rd_hi <= q_mem_hi[q_addr[10:0]];
		q_hi_r <= q_addr[12];
		q_mode_r <= w_mode_i;
	end
	wire q_addr_ok;
	assign q_addr_ok = (w_mode_i ? sv2v_cast_32(q_addr) < Q_BANK_W64 : sv2v_cast_32(q_addr) < Q64);
	always @(posedge clk)
		if (rst)
			q_rd_valid_r <= 1'b0;
		else
			q_rd_valid_r <= q_re && q_addr_ok;
	assign q_rd = (q_mode_r ? q_rd_lo : (q_hi_r ? q_rd_hi : q_rd_lo));
	assign q_rdata = (q_rd_valid_r ? q_rd : 64'b0000000000000000000000000000000000000000000000000000000000000000);
	reg [127:0] act_mem [0:ACT_WORDS - 1];
	wire [31:0] a_addr32;
	wire [31:0] b_addr32;
	wire [31:0] cpu_addr32;
	assign a_addr32 = {8'b00000000, a_addr};
	assign b_addr32 = {8'b00000000, b_addr};
	assign cpu_addr32 = cpu_addr;
	wire a_in_a;
	wire a_in_b;
	wire b_in_a;
	wire b_in_b;
	assign a_in_a = (a_addr32 >= A_OFF) && (a_addr32 < B_OFF);
	assign a_in_b = (a_addr32 >= B_OFF) && (a_addr32 < B_END);
	assign b_in_a = (b_addr32 >= A_OFF) && (b_addr32 < B_OFF);
	assign b_in_b = (b_addr32 >= B_OFF) && (b_addr32 < B_END);
	wire a_val_act;
	wire b_val_act;
	assign a_val_act = a_re && (((a_sel == 2'd0) && a_in_a) || ((a_sel == 2'd1) && a_in_b));
	assign b_val_act = b_we && (((b_sel == 2'd0) && b_in_a) || ((b_sel == 2'd1) && b_in_b));
	wire cpu_sel_act;
	assign cpu_sel_act = (cpu_addr32 >= A_OFF) && (cpu_addr32 < B_END);
	wire [ACT_AW - 1:0] a_idx;
	wire [ACT_AW - 1:0] b_idx;
	wire [ACT_AW - 1:0] cpu_idx;
	wire [ACT_AW - 1:0] act_rd_idx;
	function automatic [ACT_AW - 1:0] sv2v_cast_65FBC;
		input reg [ACT_AW - 1:0] inp;
		sv2v_cast_65FBC = inp;
	endfunction
	assign a_idx = (ACT_ABS_OK ? a_addr[ACT_AW + 3:4] : sv2v_cast_65FBC((a_addr32 - A_OFF) >> 4));
	assign b_idx = (ACT_ABS_OK ? b_addr[ACT_AW + 3:4] : sv2v_cast_65FBC((b_addr32 - A_OFF) >> 4));
	assign cpu_idx = (ACT_ABS_OK ? cpu_addr[ACT_AW + 3:4] : sv2v_cast_65FBC((cpu_addr32 - A_OFF) >> 4));
	assign act_rd_idx = (a_val_act ? a_idx : (cpu_sel_act ? cpu_idx : {ACT_AW {1'b0}}));
	reg [15:0] act_wr_en;
	reg [127:0] act_wr_data;
	reg [ACT_AW - 1:0] act_wr_idx;
	always @(*) begin
		if (_sv2v_0)
			;
		act_wr_en = 16'b0000000000000000;
		act_wr_data = 128'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
		act_wr_idx = {ACT_AW {1'b0}};
		if (b_val_act) begin
			act_wr_idx = b_idx;
			act_wr_en = b_wstrb;
			act_wr_data = b_wdata;
		end
		else if (cpu_we && cpu_sel_act) begin
			act_wr_idx = cpu_idx;
			case (cpu_addr[3:2])
				2'd0: begin
					act_wr_en[3:0] = cpu_wstrb;
					act_wr_data[31:0] = cpu_wdata;
				end
				2'd1: begin
					act_wr_en[7:4] = cpu_wstrb;
					act_wr_data[63:32] = cpu_wdata;
				end
				2'd2: begin
					act_wr_en[11:8] = cpu_wstrb;
					act_wr_data[95:64] = cpu_wdata;
				end
				default: begin
					act_wr_en[15:12] = cpu_wstrb;
					act_wr_data[127:96] = cpu_wdata;
				end
			endcase
		end
	end
	reg [127:0] act_rd;
	always @(posedge clk) begin
		if (act_wr_en[0])
			act_mem[act_wr_idx][7:0] <= act_wr_data[7:0];
		if (act_wr_en[1])
			act_mem[act_wr_idx][15:8] <= act_wr_data[15:8];
		if (act_wr_en[2])
			act_mem[act_wr_idx][23:16] <= act_wr_data[23:16];
		if (act_wr_en[3])
			act_mem[act_wr_idx][31:24] <= act_wr_data[31:24];
		if (act_wr_en[4])
			act_mem[act_wr_idx][39:32] <= act_wr_data[39:32];
		if (act_wr_en[5])
			act_mem[act_wr_idx][47:40] <= act_wr_data[47:40];
		if (act_wr_en[6])
			act_mem[act_wr_idx][55:48] <= act_wr_data[55:48];
		if (act_wr_en[7])
			act_mem[act_wr_idx][63:56] <= act_wr_data[63:56];
		if (act_wr_en[8])
			act_mem[act_wr_idx][71:64] <= act_wr_data[71:64];
		if (act_wr_en[9])
			act_mem[act_wr_idx][79:72] <= act_wr_data[79:72];
		if (act_wr_en[10])
			act_mem[act_wr_idx][87:80] <= act_wr_data[87:80];
		if (act_wr_en[11])
			act_mem[act_wr_idx][95:88] <= act_wr_data[95:88];
		if (act_wr_en[12])
			act_mem[act_wr_idx][103:96] <= act_wr_data[103:96];
		if (act_wr_en[13])
			act_mem[act_wr_idx][111:104] <= act_wr_data[111:104];
		if (act_wr_en[14])
			act_mem[act_wr_idx][119:112] <= act_wr_data[119:112];
		if (act_wr_en[15])
			act_mem[act_wr_idx][127:120] <= act_wr_data[127:120];
		act_rd <= act_mem[act_rd_idx];
	end
	reg a_valid_r;
	always @(posedge clk)
		if (rst)
			a_valid_r <= 1'b0;
		else
			a_valid_r <= a_val_act;
	assign a_rdata = (a_valid_r ? act_rd : 128'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000);
	reg cpu_sel_r;
	reg [1:0] cpu_lane_r;
	always @(posedge clk)
		if (rst) begin
			cpu_sel_r <= 1'b0;
			cpu_lane_r <= 2'd0;
		end
		else begin
			cpu_sel_r <= cpu_sel_act;
			cpu_lane_r <= cpu_addr[3:2];
		end
	reg [31:0] cpu_lane_data;
	always @(*) begin
		if (_sv2v_0)
			;
		case (cpu_lane_r)
			2'd0: cpu_lane_data = act_rd[31:0];
			2'd1: cpu_lane_data = act_rd[63:32];
			2'd2: cpu_lane_data = act_rd[95:64];
			default: cpu_lane_data = act_rd[127:96];
		endcase
	end
	assign cpu_rdata = (cpu_sel_r ? cpu_lane_data : 32'b00000000000000000000000000000000);
	initial begin : sim_init
		reg [8*512-1:0] fname;
		reg signed [31:0] fd;
		reg signed [31:0] code;
		reg signed [31:0] widx;
		reg signed [31:0] whalf;
		reg signed [31:0] qidx;
		reg signed [31:0] qword;
		reg [31:0] v32;
		reg [63:0] acc64;
		reg [8*4096-1:0] line;
		begin : sv2v_autoblock_1
			reg signed [31:0] i;
			for (i = 0; i < WSEG_A; i = i + 1)
				w_mem_a[i] = 64'b0000000000000000000000000000000000000000000000000000000000000000;
		end
		begin : sv2v_autoblock_2
			reg signed [31:0] i;
			for (i = 0; i < WSEG_B; i = i + 1)
				w_mem_b[i] = 64'b0000000000000000000000000000000000000000000000000000000000000000;
		end
		begin : sv2v_autoblock_3
			reg signed [31:0] i;
			for (i = 0; i < WSEG_C; i = i + 1)
				w_mem_c[i] = 64'b0000000000000000000000000000000000000000000000000000000000000000;
		end
		begin : sv2v_autoblock_4
			reg signed [31:0] i;
			for (i = 0; i < WSEG_D; i = i + 1)
				w_mem_d[i] = 64'b0000000000000000000000000000000000000000000000000000000000000000;
		end
		begin : sv2v_autoblock_5
			reg signed [31:0] i;
			for (i = 0; i < QLO; i = i + 1)
				q_mem_lo[i] = 64'b0000000000000000000000000000000000000000000000000000000000000000;
		end
		begin : sv2v_autoblock_6
			reg signed [31:0] i;
			for (i = 0; i < QHI; i = i + 1)
				q_mem_hi[i] = 64'b0000000000000000000000000000000000000000000000000000000000000000;
		end
		begin : sv2v_autoblock_7
			reg signed [31:0] i;
			for (i = 0; i < ACT_WORDS; i = i + 1)
				act_mem[i] = 128'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
		end
		if ($value$plusargs("nnwq=%s", fname)) begin
			fd = $fopen(fname, "r");
			if (fd == 0)
				$display("[nn_mem] WARN: cannot open +nnwq file: %s", fname);
			else begin
				widx = 0;
				whalf = 0;
				acc64 = 1'sb0;
				qidx = 0;
				qword = 0;
				code = $fgets(line, fd);
				while ((code != 0) && (widx < W64)) begin
					if ($sscanf(line, "%h", v32) == 1) begin
						if (whalf == 0) begin
							acc64[31:0] = v32;
							whalf = 1;
						end
						else begin
							acc64[63:32] = v32;
							if (widx < WSEG_A)
								w_mem_a[widx] = acc64;
							else if (widx < (WSEG_A + WSEG_B))
								w_mem_b[widx - WSEG_A] = acc64;
							else if (widx < ((WSEG_A + WSEG_B) + WSEG_C))
								w_mem_c[(widx - WSEG_A) - WSEG_B] = acc64;
							else
								w_mem_d[((widx - WSEG_A) - WSEG_B) - WSEG_C] = acc64;
							widx = widx + 1;
							whalf = 0;
							acc64 = 1'sb0;
						end
					end
					code = $fgets(line, fd);
				end
				while ((code != 0) && (qword < Q_WORDS)) begin
					if ($sscanf(line, "%h", v32) == 1) begin
						if ((qword % 2) == 0)
							acc64[31:0] = v32;
						else begin
							acc64[63:32] = v32;
							if (qidx < QLO)
								q_mem_lo[qidx] = acc64;
							else
								q_mem_hi[qidx - QLO] = acc64;
							qidx = qidx + 1;
							acc64 = 1'sb0;
						end
						qword = qword + 1;
					end
					code = $fgets(line, fd);
				end
				$fclose(fd);
				$display("[nn_mem] WQ image loaded: %s (W %0d x64b, Q %0d x64b)", fname, widx, qidx);
				if ((widx != W64) || (qword != Q_WORDS))
					$display("[nn_mem] WARN: +nnwq line count W=%0d/%0d Q=%0d/%0d", widx, W64, qword, Q_WORDS);
			end
		end
		else begin
			if ($value$plusargs("nnw=%s", fname)) begin
				fd = $fopen(fname, "r");
				if (fd == 0)
					$display("[nn_mem] WARN: cannot open +nnw file: %s", fname);
				else begin
					widx = 0;
					whalf = 0;
					acc64 = 1'sb0;
					code = $fgets(line, fd);
					while ((code != 0) && (widx < W64)) begin
						if ($sscanf(line, "%h", v32) == 1) begin
							if (whalf == 0) begin
								acc64[31:0] = v32;
								whalf = 1;
							end
							else begin
								acc64[63:32] = v32;
								if (widx < WSEG_A)
									w_mem_a[widx] = acc64;
								else if (widx < (WSEG_A + WSEG_B))
									w_mem_b[widx - WSEG_A] = acc64;
								else if (widx < ((WSEG_A + WSEG_B) + WSEG_C))
									w_mem_c[(widx - WSEG_A) - WSEG_B] = acc64;
								else
									w_mem_d[((widx - WSEG_A) - WSEG_B) - WSEG_C] = acc64;
								widx = widx + 1;
								whalf = 0;
								acc64 = 1'sb0;
							end
						end
						code = $fgets(line, fd);
					end
					$fclose(fd);
					$display("[nn_mem] W image loaded: %s (%0d / %0d x64b)", fname, widx, W64);
				end
			end
			else
				$display("[nn_mem] WARN: no +nnw / +nnwq; W arrays stay zero");
			if ($value$plusargs("nnq=%s", fname)) begin
				fd = $fopen(fname, "r");
				if (fd == 0)
					$display("[nn_mem] WARN: cannot open +nnq file: %s", fname);
				else begin
					qidx = 0;
					qword = 0;
					code = $fgets(line, fd);
					while ((code != 0) && (qword < Q_WORDS)) begin
						if ($sscanf(line, "%h", v32) == 1) begin
							if ((qword % 2) == 0)
								acc64[31:0] = v32;
							else begin
								acc64[63:32] = v32;
								if (qidx < QLO)
									q_mem_lo[qidx] = acc64;
								else
									q_mem_hi[qidx - QLO] = acc64;
								qidx = qidx + 1;
								acc64 = 1'sb0;
							end
							qword = qword + 1;
						end
						code = $fgets(line, fd);
					end
					$fclose(fd);
					$display("[nn_mem] Q image loaded: %s (%0d / %0d x64b)", fname, qidx, Q64);
				end
			end
			else
				$display("[nn_mem] WARN: no +nnq / +nnwq; Q stays zero");
		end
	end
	initial _sv2v_0 = 0;
endmodule
module nn_seq (
	clk,
	rst,
	start,
	busy,
	done,
	cycles,
	err,
	err_code,
	done_ops,
	job_timeout,
	eng_desc,
	eng_start,
	eng_busy,
	eng_done,
	eng_cycles,
	eng_err_code,
	pre_busy,
	pre_done,
	pre_err,
	band_ready,
	band_done,
	tile_err,
	w_ddr_base,
	q_ddr_base,
	arena_ddr_base,
	pre_start,
	pre_src_addr,
	pre_wlen,
	pre_qsrc_addr,
	pre_qlen,
	pre_bank,
	w_bank_sel,
	q_bank_sel,
	d_in_base,
	d_in_rows,
	d_in_row_bytes,
	d_in_stride,
	d_in_pad_top,
	d_in_rd_rows,
	d_zp_in,
	d_add_mode,
	d_aux_base,
	d_aux_stride,
	d_aux_pad_top,
	d_aux_rd_rows,
	d_out_base,
	d_out_rows,
	d_out_row_bytes,
	d_out_stride,
	band_start,
	band_idx,
	band_n,
	band_active
);
	reg _sv2v_0;
	input wire clk;
	input wire rst;
	input wire start;
	output wire busy;
	output wire done;
	output wire [31:0] cycles;
	output wire err;
	output wire [7:0] err_code;
	output wire [7:0] done_ops;
	output wire job_timeout;
	output wire [210:0] eng_desc;
	output wire eng_start;
	input wire eng_busy;
	input wire eng_done;
	input wire [31:0] eng_cycles;
	input wire [7:0] eng_err_code;
	input wire pre_busy;
	input wire pre_done;
	input wire pre_err;
	input wire band_ready;
	input wire band_done;
	input wire [7:0] tile_err;
	input wire [31:0] w_ddr_base;
	input wire [31:0] q_ddr_base;
	input wire [31:0] arena_ddr_base;
	output wire pre_start;
	output wire [31:0] pre_src_addr;
	output wire [17:0] pre_wlen;
	output wire [31:0] pre_qsrc_addr;
	output wire [12:0] pre_qlen;
	output wire pre_bank;
	output wire w_bank_sel;
	output wire q_bank_sel;
	output wire [31:0] d_in_base;
	output wire [15:0] d_in_rows;
	output wire [15:0] d_in_row_bytes;
	output wire [15:0] d_in_stride;
	output wire [15:0] d_in_pad_top;
	output wire [15:0] d_in_rd_rows;
	output wire [7:0] d_zp_in;
	output wire d_add_mode;
	output wire [31:0] d_aux_base;
	output wire [15:0] d_aux_stride;
	output wire [15:0] d_aux_pad_top;
	output wire [15:0] d_aux_rd_rows;
	output wire [31:0] d_out_base;
	output wire [15:0] d_out_rows;
	output wire [15:0] d_out_row_bytes;
	output wire [15:0] d_out_stride;
	output wire band_start;
	output wire [15:0] band_idx;
	output wire [15:0] band_n;
	output wire band_active;
	localparam [31:0] GUARD_MAX = 32'd4000000;
	localparam [31:0] JOB_GUARD_MAX = 32'd64000000;
	localparam [17:0] PRE_WLEN_MAX = 18'd131072;
	localparam [13:0] PRE_QLEN_MAX = 14'd8192;
	reg [4:0] st;
	reg [4:0] st_n;
	reg [7:0] idx;
	reg [31:0] acc_cycles;
	reg [31:0] guard;
	reg [7:0] err_code_r;
	reg done_r;
	reg busy_r;
	reg [31:0] job_guard;
	reg job_timeout_r;
	reg [7:0] done_ops_r;
	reg [255:0] rom;
	reg [255:0] rom_la;
	reg [210:0] desc_r;
	reg [6:0] band_b;
	reg [17:0] wlen_r;
	reg [17:0] wlen_next;
	reg [12:0] qlen_r;
	reg [12:0] qlen_next;
	reg [31:0] w_ptr;
	reg [31:0] q_ptr;
	reg cur_bank;
	reg pre_pending;
	reg cur_ready;
	reg pre_seen;
	reg pre_err_r;
	wire oband;
	localparam [31:0] nn_rom_pkg_NN_ROM_LEN = 112;
	function automatic [7:0] sv2v_cast_8;
		input reg [7:0] inp;
		sv2v_cast_8 = inp;
	endfunction
	wire last_entry = idx == sv2v_cast_8(111);
	wire has_next = idx != sv2v_cast_8(111);
	wire [7:0] idx_la = (has_next ? idx + 8'd1 : idx);
	localparam [31:0] nn_pkg_NN_ROM_DEPTH = 128;
	(* rom_style = "block" *) reg [255:0] rom_mem [0:127];
	localparam [32767:0] nn_rom_pkg_NN_ROM = 32768'h22330060420100300000d80000000000000240020000000000012a1d07b8000002108100410080360000c0000009000100004002000000000002727b43a0000103328100410080300000d000000a00020000480200000000000335aa6ac0000000108100210080340000f000000b20030000400200000000000154cb45300000021080804100803c0000c000000c200400004002000000000001d1b932b8000103328100410080300000d000000d20050000480200000000000327725090000000108100210080340000c000000e400600004002000000000005133fa6f8000440108080210080300000f000000002b38000000080039e98007ef70537e8000002108080c100803c0000c000000f40070000c005000000000006275de538000103330300c10080300000f000001240098000d8050000000000029669b7400000001083004080403c0000fc000015a00c0000c002000000000007344e18100000021081010080403f0000c0000018a00d00010006800000000004f947a880000103328401008040300000d000001ca0104001200680000000000578531b10000000108400408040340000c0000021201380010002000000000007e89b5e00000440108100408040300000fc00000002b3c0000000800130c000794ab6a9600000021081010080403f0000c0000025201480010006800000000007d09a4510000103328401008040300000d00000292017c0012006800000000005aedb7ac0000000108400408040340000c000002da01b00010002000000000000726f9970000440108100408040300000fc00000002b400000000800193d8007fa0bccc300000021081010080403f0000c0000031a01c000100068000000000077cb4eba0000103330401008040300000d0000035a01f40012006800000000004380c0cf8000000108400404020340000f000003a2022800100020000000000002193e3500000021081018040203c0000c000003e2023800180098000000000036c8be2b8000103328601804020300000c600004420284001b00980000000000355a44190000000108600404020318000c000004ae02d00018002000000000003729e9d30000440108100404020300000f000000002b44000000080007a20007eb37ca2d00000021081018040203c0000c0000050e02e000180098000000000036e187fd0000103328601804020300000c6000056e032c001b009800000000004477c3140000000108600404020318000c000005da03780018002000000000002f39ca3e8000440108100404020300000f000000002b48000000080007c18007c9e9031e00000021081018040203c0000c0000063a038800180098000000000040e3d0f38000103328601804020300000c6000069a03d4001b0098000000000056a598f38000000108600804020318000f00000706042000300038000000000074a1679200000021082030040203c0000c000007c6043c0060012800000000000710df258000103328c03004020300000cc000094604d000360128000000000015b014698000000108c00804020330000c00000a1e0564006000380000000000241f50a48000440108200804020300000f000000002b4c00000008000f2a8007bff5e1fe80000021082030040203c0000c00000b9e05800060012800000000000d9047340000103328c03004020300000cc0000d1e06140036012800000000000e448b458000000108c00804020330000c00000df606a8006000380000000000485a1df60000440108200804020300000f000000002b500000000800120d8007f4a6b9c700000021082030040203c0000c00000f7606c4006001280000000000710d3b3d0000103328c03004020300000cc00010f60758003601280000000000470edda70000000108c00804020330000c000011ce07ec00600038000000000077649d6f8000440108200804020300000f000000002b54000000080014728007f7c2bf5680000021082030040203c0000c0000134e0808006001280000000000313fcb118000103328c03004020300000cc00014ce089c0036012800000000006dbbf5ce8000000108c00804020330000c000015a609300060003800000000004db23d180000440108200804020300000f000000002b58000000080016e70007a2111ec400000021082030040203c0000c00001726094c00600128000000000028e6d15e0000103330c03004020300000cc00018a609e0003601280000000000383397220000000108c00c02010330000f0000197e0a740090005000000000007a16365780000021083044020103c0000c00001bbe0a9c00cc01a0000000000024bd05018000103329104402010300000c44001eee0b6c004c81a000000000006056dcdd0000000109100c02010311000c000020200c3c00cc005000000000000c8985cf8000440108300c02010300000f000000002b5c000000080010740007a8efa2b680000021083044020103c0000c000023500c6400cc01a000000000005e5c147a0000103329104402010300000c440026800d34004c81a00000000000735044238000000109100c02010311000c000027b20e0400cc00500000000000660421d08000440108300c02010300000f000000002b60000000080014128007e00a49e300000021083044020103c0000c00002ae20e2c00cc01a000000000004479f4550000103329104402010300000c44002e120efc004c81a000000000002ecb28930000000109100c02010311000c00002f440fcc00cc0050000000000031fb05ff0000440108300c02010300000f000000002b64000000080013918007cb2fef3480000021083044020103c0000c000032740ff400cc01a000000000005643d45a0000103329104402010300000c440035a410c4004c81a0000000000036a9eb578000000109100c02010311000c000036d6119400cc0050000000000017304bd80000440108300c02010300000f000000002b680000000800110b0007e698fb7200000021083044020103c0000c00003a0611bc00cc01a000000000007994b9488000103331104402010300000c44003d36128c004c81a000000000000812edc70000000109101801008311000f0c003e68135c01980098000000000079ab2a8c00000021086070010083c3000c000044c813a802a002a800000000005624c3648000103329c07001008300000c1c004f4814fc007e02a800000000005e5a8d4f8000000109c01801008307000c00005140165002a00098000000000058c482ee0000440108601801008300000f0c0000002b6c00000008000d880007a00aa92280000021086070010083c3000c00005bc0169c02a002a800000000003229595c8000103329c07001008300000c1c00664017f0007e02a800000000007c0203630000000109c01801008307000c00006838194402a0009800000000004222463c8000440108601801008300000f0c0000002b70000000080011788007e57d332800000021086070010083c3000c000072b8199002a002a800000000002786d35e8000103329c07001008300000c1c007d381ae4007e02a8000000000000ab09ea0000000109c01801008307000c00007f301c3802a000980000000000740e68548000440108601801008300000f0c0000002b74000000080011538007e087539300000021086070010083c3000c000089b01c8402a002a8000000000012f343e10000103329c07001008300000c1c0094301dd8007e02a800000000005f93fd6f0000000109c01801008307000c000096281f2c02a000980000000000105e5d810000440108601801008300000f0c0000002b78000000080013440007a751e94200000021086070010083c3000c0000a0a81f7802a002a8000000000038fcdd4a0000103329c07001008300000c1c00ab2820cc007e02a800000000003d6d9cbe0000000109c01801008307000c0000ad20222002a0009800000000000a17f2240000440108601801008300000f0c0000002b7c00000008002bbd00078f01b3d080002103286018010083c3000f1200000000000000000000000000001d89254380002105486018010083c3000f1800000000000000000000000000005dae3e6f80002109886018010083c3000c0000000000000000000000000000006de96bc28000500108606001008300000f1e00000000000000000000000000006de96bc280005001086060010083c6000f1e60000000000000000000000000005dae3e6f80005001086060010083c4800f1ec0000000000000000000000000001d89254380005001086060010083c3000f1f20000000000000000000000000000f01b3d080000021098030010083c7800f0c00b7a0226c04800128000000000035530fd08000103548c030010083c3000c0000c9a0230000960128000000000055486af60000000108c03001008300000c0c00cbf82394024001280000000000690553840000103548c03001008303000c0000d4f82428009601280000000000183c06960000000108c03001008300000c0c00d75024bc0240012800000000005b615a0f0000000108c07f81008303000c1800e05025500600030800000000001e5d354a8000308210c030010083c3000c38000000000000000000000000000064af69ce8000500108c03c0201030e000c68000000000000000000000000000064af69ce8000500108303c020103c0000c68c0000000000000000000000000006698fb720000103548f03c0201031a000ca400f85026d400bb817000000000006c4038958000000108f03c02010329000c3800fb3e278c0384017000000000003e0d52980000103548f03c0201030e000c7401094e284400bb8170000000000041b157840000000108f03c0201031d000c38010c3c28fc0384017000000000000e2124dd8000000108f07f8201030e000c74011a4c29b40780030800000000004f06006a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
	initial begin : sv2v_autoblock_1
		reg signed [31:0] i;
		for (i = 0; i < nn_pkg_NN_ROM_DEPTH; i = i + 1)
			rom_mem[i] = nn_rom_pkg_NN_ROM[(127 - i) * 256+:256];
	end
	always @(posedge clk)
		if (rst) begin
			rom <= 1'sb0;
			rom_la <= 1'sb0;
		end
		else begin
			rom <= rom_mem[idx];
			rom_la <= rom_mem[idx_la];
		end
	assign oband = rom[80];
	localparam [31:0] nn_pkg_NN_F_PACKED3 = 5;
	wire p3_stream = rom[81] || rom[249];
	localparam [31:0] nn_pkg_NN_ROM_KIND_ADD = 4;
	wire kind_add = rom[255-:4] == nn_pkg_NN_ROM_KIND_ADD;
	localparam [31:0] nn_pkg_NN_ROM_KIND_COPY = 5;
	wire kind_copy = rom[255-:4] == nn_pkg_NN_ROM_KIND_COPY;
	localparam [31:0] nn_pkg_NN_ROM_KIND_UP2X = 3;
	wire kind_up = rom[255-:4] == nn_pkg_NN_ROM_KIND_UP2X;
	localparam [31:0] nn_pkg_NN_ROM_KIND_POOL = 2;
	wire kind_pool = rom[255-:4] == nn_pkg_NN_ROM_KIND_POOL;
	wire [3:0] k_g = (kind_add || kind_copy ? 4'd1 : (rom[243-:4] == 4'd0 ? 4'd1 : rom[243-:4]));
	wire [1:0] st_g = ((kind_add || kind_copy) || (rom[236-:2] == 2'd0) ? 2'd1 : rom[236-:2]);
	wire [2:0] pad_g = (kind_add || kind_copy ? 3'd0 : (kind_pool && (rom[239-:3] == 3'd0) ? (k_g - 4'd1) >> 1 : rom[239-:3]));
	function automatic [15:0] sv2v_cast_16;
		input reg [15:0] inp;
		sv2v_cast_16 = inp;
	endfunction
	wire [15:0] ic8_g = sv2v_cast_16((rom[234-:10] + 16'd7) & 16'hfff8);
	wire [15:0] oc8_g = sv2v_cast_16((rom[224-:10] + 16'd7) & 16'hfff8);
	wire [15:0] ih_g = sv2v_cast_16(rom[214-:9]);
	wire [15:0] iw_g = sv2v_cast_16(rom[205-:9]);
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	wire [31:0] oh32 = (kind_up ? sv2v_cast_32(ih_g) * 2 : (((sv2v_cast_32(ih_g) + (sv2v_cast_32(pad_g) * 2)) - sv2v_cast_32(k_g)) / sv2v_cast_32(st_g)) + 32'd1);
	wire [31:0] ow32 = (kind_up ? sv2v_cast_32(iw_g) * 2 : (((sv2v_cast_32(iw_g) + (sv2v_cast_32(pad_g) * 2)) - sv2v_cast_32(k_g)) / sv2v_cast_32(st_g)) + 32'd1);
	function automatic [4:0] sv2v_cast_5;
		input reg [4:0] inp;
		sv2v_cast_5 = inp;
	endfunction
	wire [4:0] br_raw = sv2v_cast_5(rom[86:83]) + 5'd1;
	wire [4:0] br_eff = (kind_up && br_raw[0] ? br_raw - 5'd1 : br_raw);
	wire [4:0] br_use = (br_eff == 5'd0 ? 5'd2 : br_eff);
	wire [15:0] n_bands16 = sv2v_cast_16(((oh32 + sv2v_cast_32(br_use)) - 32'd1) / sv2v_cast_32(br_use));
	wire [15:0] out_r0 = sv2v_cast_16(sv2v_cast_32(band_b) * sv2v_cast_32(br_use));
	wire [15:0] br_cur = sv2v_cast_16((sv2v_cast_32(out_r0) >= oh32 ? 32'd0 : ((oh32 - sv2v_cast_32(out_r0)) > sv2v_cast_32(br_use) ? sv2v_cast_32(br_use) : oh32 - sv2v_cast_32(out_r0))));
	wire [15:0] in_row_bytes = (p3_stream ? iw_g * 16'd3 : (kind_up ? iw_g * ic8_g : sv2v_cast_16((iw_g + ({13'd0, pad_g} * 16'd2)) * ic8_g)));
	wire [15:0] in_stride = (p3_stream ? iw_g * 16'd3 : iw_g * ic8_g);
	wire [15:0] out_row_bytes = sv2v_cast_16(ow32) * oc8_g;
	wire [15:0] in_rows_up = (br_cur >> 32'sd1) + 16'd1;
	wire [15:0] in_rows_cv = sv2v_cast_16(((br_cur - 16'd1) * {14'd0, st_g}) + {12'd0, k_g});
	wire [15:0] in_rows = (kind_up ? in_rows_up : in_rows_cv);
	wire signed [17:0] band_row0_s = ($signed({2'b00, out_r0}) * $signed({16'd0, st_g})) - $signed({15'd0, pad_g});
	function automatic signed [15:0] sv2v_cast_16_signed;
		input reg signed [15:0] inp;
		sv2v_cast_16_signed = inp;
	endfunction
	wire [15:0] abs1 = sv2v_cast_16_signed(band_row0_s + $signed({2'b00, in_rows}));
	wire [15:0] rd0 = (kind_up ? out_r0 >> 32'sd1 : (band_row0_s < 18'sd0 ? 16'd0 : sv2v_cast_16_signed(band_row0_s)));
	wire [15:0] rd1 = (kind_up ? ((rd0 + in_rows) > ih_g ? ih_g : rd0 + in_rows) : (abs1 > ih_g ? ih_g : abs1));
	wire [15:0] in_pad_top = (kind_up ? 16'd0 : (band_row0_s < 18'sd0 ? sv2v_cast_16_signed(-band_row0_s) : 16'd0));
	wire [15:0] in_rd_rows = (rd1 > rd0 ? rd1 - rd0 : 16'd0);
	wire [31:0] in_base_c = (arena_ddr_base + sv2v_cast_32(rom[196-:22])) + (sv2v_cast_32(rd0) * sv2v_cast_32(in_stride));
	wire [31:0] out_base_c = (arena_ddr_base + sv2v_cast_32(rom[174-:22])) + (sv2v_cast_32(out_r0) * sv2v_cast_32(out_row_bytes));
	assign d_in_base = in_base_c;
	assign d_in_rows = in_rows;
	assign d_in_row_bytes = in_row_bytes;
	assign d_in_stride = in_stride;
	assign d_in_pad_top = in_pad_top;
	assign d_in_rd_rows = in_rd_rows;
	assign d_zp_in = ((p3_stream || kind_add) || kind_copy ? 8'd0 : rom[70:63]);
	assign d_add_mode = kind_add;
	assign d_aux_base = out_base_c;
	assign d_aux_stride = out_row_bytes;
	assign d_aux_pad_top = 16'd0;
	assign d_aux_rd_rows = (kind_add ? br_cur : 16'd0);
	assign d_out_base = out_base_c;
	assign d_out_rows = br_cur;
	assign d_out_row_bytes = out_row_bytes;
	assign d_out_stride = out_row_bytes;
	function automatic [13:0] sv2v_cast_14;
		input reg [13:0] inp;
		sv2v_cast_14 = inp;
	endfunction
	wire wlen_bad = (rom[117-:18] > PRE_WLEN_MAX) || (sv2v_cast_14(rom[99-:13]) > PRE_QLEN_MAX);
	wire wlen_la_ok = (rom_la[117-:18] <= PRE_WLEN_MAX) && (sv2v_cast_14(rom_la[99-:13]) <= PRE_QLEN_MAX);
	wire la_band = rom_la[80];
	localparam [31:0] nn_pkg_NN_F_DEPTHWISE = 0;
	localparam [31:0] nn_pkg_NN_F_POOLMAX = 4;
	localparam [31:0] nn_pkg_NN_F_UP2X = 3;
	localparam [1:0] nn_pkg_NN_OP_ADD = 2'd3;
	localparam [1:0] nn_pkg_NN_OP_CONV = 2'd0;
	localparam [1:0] nn_pkg_NN_OP_COPY = 2'd2;
	localparam [1:0] nn_pkg_NN_OP_POOL = 2'd1;
	localparam [31:0] nn_pkg_NN_ROM_KIND_CONV = 0;
	localparam [31:0] nn_pkg_NN_ROM_KIND_DW = 1;
	function automatic [210:0] nn_pkg_nn_rom_to_desc;
		input reg [255:0] r;
		reg [210:0] d;
		begin
			d[210-:2] = nn_pkg_NN_OP_CONV;
			d[208-:8] = r[251-:8];
			d[200-:4] = r[243-:4];
			d[196-:2] = (r[236-:2] == 2'd0 ? 2'd1 : r[236-:2]);
			d[194-:3] = r[239-:3];
			d[191-:16] = sv2v_cast_16(r[214-:9]);
			d[175-:16] = sv2v_cast_16(r[205-:9]);
			d[159-:16] = sv2v_cast_16(r[234-:10]);
			d[143-:16] = sv2v_cast_16(r[224-:10]);
			d[127-:32] = sv2v_cast_32(r[196-:22]);
			d[95-:32] = sv2v_cast_32(r[174-:22]);
			d[63-:32] = sv2v_cast_32(r[152-:19]);
			d[31-:32] = sv2v_cast_32(r[133-:16]);
			nn_pkg_nn_rom_to_desc = d;
		end
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		desc_r = nn_pkg_nn_rom_to_desc(rom);
		desc_r[210-:2] = nn_pkg_NN_OP_CONV;
		(* full_case, parallel_case *)
		case (rom[255-:4])
			nn_pkg_NN_ROM_KIND_CONV: desc_r[210-:2] = nn_pkg_NN_OP_CONV;
			nn_pkg_NN_ROM_KIND_DW: begin
				desc_r[210-:2] = nn_pkg_NN_OP_CONV;
				desc_r[201] = 1'b1;
			end
			nn_pkg_NN_ROM_KIND_POOL: begin
				desc_r[210-:2] = nn_pkg_NN_OP_POOL;
				desc_r[205] = 1'b1;
			end
			nn_pkg_NN_ROM_KIND_UP2X: begin
				desc_r[210-:2] = nn_pkg_NN_OP_COPY;
				desc_r[204] = 1'b1;
			end
			nn_pkg_NN_ROM_KIND_ADD: desc_r[210-:2] = nn_pkg_NN_OP_ADD;
			nn_pkg_NN_ROM_KIND_COPY: desc_r[210-:2] = nn_pkg_NN_OP_COPY;
			default: desc_r[210-:2] = nn_pkg_NN_OP_CONV;
		endcase
	end
	reg [210:0] band_desc;
	always @(*) begin
		if (_sv2v_0)
			;
		band_desc = desc_r;
		band_desc[191-:16] = in_rows;
		band_desc[175-:16] = (p3_stream ? iw_g : sv2v_cast_16(iw_g + ({13'd0, pad_g} * 16'd2)));
		band_desc[194-:3] = (p3_stream ? rom[239-:3] : 3'd0);
		band_desc[127-:32] = 32'd0;
		band_desc[95-:32] = 32'd0;
		band_desc[63-:32] = 32'd0;
		band_desc[31-:32] = 32'd0;
	end
	assign eng_desc = (oband ? band_desc : desc_r);
	assign eng_start = ((st == 5'd2) && !oband) || (st == 5'd12);
	assign busy = busy_r;
	assign done = done_r;
	assign cycles = acc_cycles;
	assign err = st == 5'd6;
	assign err_code = err_code_r;
	assign done_ops = done_ops_r;
	assign job_timeout = job_timeout_r;
	assign band_active = |{st == 5'd8, st == 5'd9, st == 5'd10, st == 5'd11, st == 5'd12, st == 5'd13, st == 5'd14, st == 5'd15, st == 5'd16};
	assign band_idx = {9'd0, band_b};
	assign band_n = (band_active ? n_bands16 : 16'd0);
	wire pre_issue = (st == 5'd8) || (((((st == 5'd10) && (band_b == 7'd0)) && has_next) && la_band) && !pre_pending);
	assign pre_start = pre_issue;
	assign pre_src_addr = (st == 5'd8 ? w_ddr_base + w_ptr : (w_ddr_base + w_ptr) + sv2v_cast_32(wlen_r));
	assign pre_qsrc_addr = (st == 5'd8 ? q_ddr_base + q_ptr : (q_ddr_base + q_ptr) + sv2v_cast_32(qlen_r));
	assign pre_wlen = (st == 5'd8 ? wlen_r : wlen_next);
	assign pre_qlen = (st == 5'd8 ? qlen_r : qlen_next);
	assign pre_bank = ~cur_bank;
	assign w_bank_sel = cur_bank;
	assign q_bank_sel = cur_bank;
	assign band_start = st == 5'd10;
	function automatic [6:0] sv2v_cast_7;
		input reg [6:0] inp;
		sv2v_cast_7 = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		st_n = st;
		(* full_case, parallel_case *)
		case (st)
			5'd0:
				if (start)
					st_n = 5'd1;
			5'd1: st_n = 5'd2;
			5'd2: st_n = (!oband ? 5'd3 : (cur_ready ? 5'd10 : 5'd8));
			5'd3:
				if (eng_err_code != 8'd0)
					st_n = 5'd6;
				else if (job_guard >= JOB_GUARD_MAX)
					st_n = (eng_busy ? 5'd7 : 5'd5);
				else if (guard >= GUARD_MAX)
					st_n = 5'd6;
				else if (eng_done)
					st_n = 5'd4;
			5'd4: st_n = (last_entry ? 5'd5 : 5'd1);
			5'd5: st_n = 5'd0;
			5'd6: st_n = 5'd0;
			5'd7: st_n = (eng_busy ? 5'd7 : 5'd5);
			5'd8: st_n = (wlen_bad || ((!wlen_la_ok && has_next) && la_band) ? 5'd6 : 5'd9);
			5'd9:
				if (job_guard >= JOB_GUARD_MAX)
					st_n = 5'd7;
				else if (guard >= GUARD_MAX)
					st_n = 5'd6;
				else if (pre_seen)
					st_n = (pre_err_r ? 5'd6 : 5'd10);
			5'd10: st_n = ((((band_b == 7'd0) && has_next) && la_band) && !wlen_la_ok ? 5'd6 : 5'd11);
			5'd11:
				if (tile_err != 8'd0)
					st_n = 5'd6;
				else if (job_guard >= JOB_GUARD_MAX)
					st_n = 5'd7;
				else if (guard >= GUARD_MAX)
					st_n = 5'd6;
				else if (band_ready)
					st_n = 5'd12;
			5'd12: st_n = 5'd13;
			5'd13:
				if (eng_err_code != 8'd0)
					st_n = 5'd6;
				else if (job_guard >= JOB_GUARD_MAX)
					st_n = (eng_busy ? 5'd7 : 5'd5);
				else if (guard >= GUARD_MAX)
					st_n = 5'd6;
				else if (eng_done)
					st_n = 5'd14;
			5'd14:
				if (tile_err != 8'd0)
					st_n = 5'd6;
				else if (job_guard >= JOB_GUARD_MAX)
					st_n = 5'd7;
				else if (guard >= GUARD_MAX)
					st_n = 5'd6;
				else if (band_done)
					st_n = ((band_b + 7'd1) >= sv2v_cast_7(n_bands16) ? 5'd15 : 5'd10);
			5'd15: st_n = (pre_pending ? 5'd16 : (last_entry ? 5'd5 : 5'd1));
			5'd16:
				if (job_guard >= JOB_GUARD_MAX)
					st_n = 5'd7;
				else if (guard >= GUARD_MAX)
					st_n = 5'd6;
				else if (pre_seen)
					st_n = (pre_err_r ? 5'd6 : (last_entry ? 5'd5 : 5'd1));
			default: st_n = 5'd0;
		endcase
	end
	wire wait_any = ((((st == 5'd9) || (st == 5'd11)) || (st == 5'd13)) || (st == 5'd14)) || (st == 5'd16);
	always @(posedge clk)
		if (rst) begin
			st <= 5'd0;
			idx <= 8'd0;
			acc_cycles <= 32'd0;
			guard <= 32'd0;
			err_code_r <= 8'd0;
			busy_r <= 1'b0;
			done_r <= 1'b0;
			job_guard <= 32'd0;
			job_timeout_r <= 1'b0;
			done_ops_r <= 8'd0;
			band_b <= 7'd0;
			wlen_r <= 18'd0;
			qlen_r <= 13'd0;
			wlen_next <= 18'd0;
			qlen_next <= 13'd0;
			w_ptr <= 32'd0;
			q_ptr <= 32'd0;
			cur_bank <= 1'b0;
			pre_pending <= 1'b0;
			cur_ready <= 1'b0;
			pre_seen <= 1'b0;
			pre_err_r <= 1'b0;
		end
		else begin
			st <= st_n;
			done_r <= 1'b0;
			if (pre_done) begin
				pre_seen <= 1'b1;
				pre_err_r <= pre_err;
			end
			if (pre_issue)
				pre_seen <= 1'b0;
			if ((st == 5'd3) || wait_any) begin
				guard <= guard + 32'd1;
				job_guard <= job_guard + 32'd1;
			end
			if (st == 5'd3) begin
				if (eng_err_code != 8'd0)
					err_code_r <= eng_err_code;
				else if (guard >= GUARD_MAX)
					err_code_r <= 8'he3;
			end
			if ((wait_any && (guard >= GUARD_MAX)) && (err_code_r == 8'd0))
				err_code_r <= ((((st == 5'd9) || (st == 5'd16)) || (st == 5'd11)) || (st == 5'd14) ? 8'he6 : 8'he3);
			if ((((st == 5'd9) || (st == 5'd16)) && pre_seen) && pre_err_r)
				err_code_r <= 8'he6;
			if (((st == 5'd11) || (st == 5'd14)) && (tile_err != 8'd0))
				err_code_r <= 8'he6;
			if ((st == 5'd8) && (wlen_bad || ((!wlen_la_ok && has_next) && la_band)))
				err_code_r <= 8'he6;
			if (((((st == 5'd10) && (band_b == 7'd0)) && has_next) && la_band) && !wlen_la_ok)
				err_code_r <= 8'he6;
			if (job_guard >= JOB_GUARD_MAX) begin
				job_timeout_r <= 1'b1;
				err_code_r <= 8'he4;
			end
			(* full_case, parallel_case *)
			case (st)
				5'd0: begin
					busy_r <= 1'b0;
					if (start) begin
						idx <= 8'd0;
						acc_cycles <= 32'd0;
						guard <= 32'd0;
						err_code_r <= 8'd0;
						busy_r <= 1'b1;
						job_guard <= 32'd0;
						job_timeout_r <= 1'b0;
						done_ops_r <= 8'd0;
						band_b <= 7'd0;
						w_ptr <= 32'd0;
						q_ptr <= 32'd0;
						cur_bank <= 1'b0;
						pre_pending <= 1'b0;
						cur_ready <= 1'b0;
						wlen_next <= 18'd0;
						qlen_next <= 13'd0;
					end
				end
				5'd2: begin
					band_b <= 7'd0;
					wlen_r <= rom[117-:18];
					qlen_r <= rom[99-:13];
					wlen_next <= rom_la[117-:18];
					qlen_next <= rom_la[99-:13];
					if (!oband) begin
						done_ops_r <= done_ops_r + 8'd1;
						cur_ready <= 1'b0;
					end
				end
				5'd3:
					if (eng_done)
						acc_cycles <= acc_cycles + eng_cycles;
				5'd4: begin
					idx <= idx + 8'd1;
					w_ptr <= w_ptr + sv2v_cast_32(wlen_r);
					q_ptr <= q_ptr + sv2v_cast_32(qlen_r);
				end
				5'd8:
					;
				5'd9:
					if (pre_seen && !pre_err_r) begin
						cur_bank <= ~cur_bank;
						cur_ready <= 1'b1;
						band_b <= 7'd0;
						pre_pending <= 1'b0;
						pre_seen <= 1'b0;
					end
				5'd10:
					if (((band_b == 7'd0) && has_next) && la_band)
						pre_pending <= 1'b1;
				5'd13:
					if (eng_done)
						acc_cycles <= acc_cycles + eng_cycles;
				5'd14:
					if (band_done) begin
						if ((band_b + 7'd1) >= sv2v_cast_7(n_bands16))
							done_ops_r <= done_ops_r + 8'd1;
						else
							band_b <= band_b + 7'd1;
					end
				5'd15: begin
					w_ptr <= w_ptr + sv2v_cast_32(wlen_r);
					q_ptr <= q_ptr + sv2v_cast_32(qlen_r);
					if (pre_pending)
						;
					else begin
						cur_ready <= 1'b0;
						if (!last_entry)
							idx <= idx + 8'd1;
					end
				end
				5'd16:
					if (pre_seen && !pre_err_r) begin
						cur_bank <= ~cur_bank;
						cur_ready <= 1'b1;
						pre_pending <= 1'b0;
						pre_seen <= 1'b0;
						if (!last_entry)
							idx <= idx + 8'd1;
					end
				5'd5: begin
					done_r <= 1'b1;
					busy_r <= 1'b0;
				end
				5'd6: busy_r <= 1'b0;
				default:
					;
			endcase
		end
	initial _sv2v_0 = 0;
endmodule
module nn_wload (
	clk,
	rst,
	ddr_clk,
	ddr_rst,
	pre_start,
	pre_src_addr,
	pre_wlen,
	pre_qsrc_addr,
	pre_qlen,
	pre_bank,
	pre_busy,
	pre_done,
	pre_err,
	pre_fill_bank,
	ddr_rd_re,
	ddr_rd_addr,
	ddr_rd_len,
	ddr_rd_ready,
	ddr_rd_data,
	ddr_rd_valid,
	ddr_rd_last,
	ddr_rd_rready,
	wfill_we,
	wfill_addr,
	wfill_wdata,
	qfill_we,
	qfill_addr,
	qfill_wdata
);
	reg _sv2v_0;
	parameter [31:0] MAX_PRE_WLEN = 131072;
	parameter [31:0] W_FILL_W64 = 20480;
	parameter [31:0] Q_FILL_W64 = 1024;
	parameter [31:0] FIFO_AW = 5;
	input wire clk;
	input wire rst;
	input wire ddr_clk;
	input wire ddr_rst;
	input wire pre_start;
	input wire [31:0] pre_src_addr;
	input wire [17:0] pre_wlen;
	input wire [31:0] pre_qsrc_addr;
	input wire [12:0] pre_qlen;
	input wire pre_bank;
	output wire pre_busy;
	output reg pre_done;
	output reg pre_err;
	output wire pre_fill_bank;
	output wire ddr_rd_re;
	output wire [31:0] ddr_rd_addr;
	output wire [15:0] ddr_rd_len;
	input wire ddr_rd_ready;
	input wire [127:0] ddr_rd_data;
	input wire ddr_rd_valid;
	input wire ddr_rd_last;
	output wire ddr_rd_rready;
	output wire wfill_we;
	output wire [17:0] wfill_addr;
	output wire [63:0] wfill_wdata;
	output wire qfill_we;
	output wire [12:0] qfill_addr;
	output wire [63:0] qfill_wdata;
	localparam [31:0] FIFO_DW = 144;
	reg job_tog;
	reg done_tog;
	reg d_job_err;
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	function automatic [15:0] sv2v_cast_16;
		input reg [15:0] inp;
		sv2v_cast_16 = inp;
	endfunction
	function automatic [15:0] ceil_beats;
		input reg [17:0] len;
		input reg [4:0] off;
		ceil_beats = sv2v_cast_16(((sv2v_cast_32(len) + sv2v_cast_32(off)) + 32'd15) >> 4);
	endfunction
	function automatic [4:0] sv2v_cast_5;
		input reg [4:0] inp;
		sv2v_cast_5 = inp;
	endfunction
	function automatic [4:0] last_hi_of;
		input reg [17:0] len;
		input reg [4:0] off;
		input reg [15:0] beats;
		last_hi_of = sv2v_cast_5((sv2v_cast_32(len) + sv2v_cast_32(off)) - ((sv2v_cast_32(beats) - 32'd1) * 32'd16));
	endfunction
	function automatic [63:0] mask_word;
		input reg [63:0] w;
		input reg [7:0] bm;
		reg signed [31:0] b;
		for (b = 0; b < 8; b = b + 1)
			mask_word[8 * b+:8] = (bm[b] ? w[8 * b+:8] : 8'h00);
	endfunction
	wire wfifo_winc;
	wire wfifo_full;
	wire wfifo_ovf;
	wire [143:0] wfifo_wdata;
	wire wfifo_rinc;
	wire wfifo_empty;
	wire [143:0] wfifo_rdata;
	wire qfifo_winc;
	wire qfifo_full;
	wire qfifo_ovf;
	wire [143:0] qfifo_wdata;
	wire qfifo_rinc;
	wire qfifo_empty;
	wire [143:0] qfifo_rdata;
	nn_wload_afifo #(
		.DW(FIFO_DW),
		.AW(FIFO_AW)
	) u_wfifo(
		.wclk(ddr_clk),
		.wrst(ddr_rst),
		.winc(wfifo_winc),
		.wdata(wfifo_wdata),
		.wfull(wfifo_full),
		.wr_ovf(wfifo_ovf),
		.rclk(clk),
		.rrst(rst),
		.rinc(wfifo_rinc),
		.rdata(wfifo_rdata),
		.rempty(wfifo_empty)
	);
	nn_wload_afifo #(
		.DW(FIFO_DW),
		.AW(FIFO_AW)
	) u_qfifo(
		.wclk(ddr_clk),
		.wrst(ddr_rst),
		.winc(qfifo_winc),
		.wdata(qfifo_wdata),
		.wfull(qfifo_full),
		.wr_ovf(qfifo_ovf),
		.rclk(clk),
		.rrst(rst),
		.rinc(qfifo_rinc),
		.rdata(qfifo_rdata),
		.rempty(qfifo_empty)
	);
	reg [2:0] cstate;
	reg [31:0] job_wsrc;
	reg [31:0] job_qsrc;
	reg [17:0] job_wlen;
	reg [12:0] job_qlen;
	reg job_bank;
	reg done_tog_s0;
	reg done_tog_s1;
	reg done_seen;
	reg job_err_s0;
	reg job_err_s1;
	reg [7:0] settle_cnt;
	reg [17:0] exp_w_words;
	reg [12:0] exp_q_words;
	reg [17:0] wcnt;
	reg [12:0] qcnt;
	reg fill_clr;
	reg [1:0] wd_state;
	reg [127:0] wd_data;
	reg [15:0] wd_mask;
	wire wfill_lo_we;
	wire wfill_hi_we;
	wire [63:0] wfill_lo_word;
	wire [63:0] wfill_hi_word;
	assign wfifo_rinc = (wd_state == 2'd0) && !wfifo_empty;
	assign wfill_we = wfill_lo_we | wfill_hi_we;
	assign wfill_addr = wcnt;
	assign wfill_wdata = (wfill_lo_we ? wfill_lo_word : wfill_hi_word);
	assign wfill_lo_we = (wd_state == 2'd1) && |wd_mask[7:0];
	assign wfill_hi_we = (wd_state == 2'd2) && |wd_mask[15:8];
	assign wfill_lo_word = mask_word(wd_data[63:0], wd_mask[7:0]);
	assign wfill_hi_word = mask_word(wd_data[127:64], wd_mask[15:8]);
	always @(posedge clk)
		if (rst || fill_clr) begin
			wd_state <= 2'd0;
			wd_data <= 1'sb0;
			wd_mask <= 1'sb0;
			wcnt <= 1'sb0;
		end
		else
			(* full_case, parallel_case *)
			case (wd_state)
				2'd0:
					if (!wfifo_empty) begin
						wd_data <= wfifo_rdata[127:0];
						wd_mask <= wfifo_rdata[143:128];
						wd_state <= 2'd1;
					end
				2'd1: begin
					if (|wd_mask[7:0])
						wcnt <= wcnt + 18'd1;
					wd_state <= 2'd2;
				end
				2'd2: begin
					if (|wd_mask[15:8])
						wcnt <= wcnt + 18'd1;
					wd_state <= 2'd0;
				end
				default: wd_state <= 2'd0;
			endcase
	reg [1:0] qd_state;
	reg [127:0] qd_data;
	reg [15:0] qd_mask;
	wire qfill_lo_we;
	wire qfill_hi_we;
	wire [63:0] qfill_lo_word;
	wire [63:0] qfill_hi_word;
	assign qfifo_rinc = (qd_state == 2'd0) && !qfifo_empty;
	assign qfill_we = qfill_lo_we | qfill_hi_we;
	assign qfill_addr = qcnt;
	assign qfill_wdata = (qfill_lo_we ? qfill_lo_word : qfill_hi_word);
	assign qfill_lo_we = (qd_state == 2'd1) && |qd_mask[7:0];
	assign qfill_hi_we = (qd_state == 2'd2) && |qd_mask[15:8];
	assign qfill_lo_word = mask_word(qd_data[63:0], qd_mask[7:0]);
	assign qfill_hi_word = mask_word(qd_data[127:64], qd_mask[15:8]);
	always @(posedge clk)
		if (rst || fill_clr) begin
			qd_state <= 2'd0;
			qd_data <= 1'sb0;
			qd_mask <= 1'sb0;
			qcnt <= 1'sb0;
		end
		else
			(* full_case, parallel_case *)
			case (qd_state)
				2'd0:
					if (!qfifo_empty) begin
						qd_data <= qfifo_rdata[127:0];
						qd_mask <= qfifo_rdata[143:128];
						qd_state <= 2'd1;
					end
				2'd1: begin
					if (|qd_mask[7:0])
						qcnt <= qcnt + 13'd1;
					qd_state <= 2'd2;
				end
				2'd2: begin
					if (|qd_mask[15:8])
						qcnt <= qcnt + 13'd1;
					qd_state <= 2'd0;
				end
				default: qd_state <= 2'd0;
			endcase
	assign pre_busy = cstate != 3'd0;
	assign pre_fill_bank = job_bank;
	always @(posedge clk)
		if (rst) begin
			cstate <= 3'd0;
			job_wsrc <= 1'sb0;
			job_qsrc <= 1'sb0;
			job_wlen <= 1'sb0;
			job_qlen <= 1'sb0;
			job_bank <= 1'b0;
			job_tog <= 1'b0;
			done_tog_s0 <= 1'b0;
			done_tog_s1 <= 1'b0;
			done_seen <= 1'b0;
			job_err_s0 <= 1'b0;
			job_err_s1 <= 1'b0;
			settle_cnt <= 1'sb0;
			exp_w_words <= 1'sb0;
			exp_q_words <= 1'sb0;
			fill_clr <= 1'b0;
			pre_done <= 1'b0;
			pre_err <= 1'b0;
		end
		else begin
			pre_done <= 1'b0;
			fill_clr <= 1'b0;
			done_tog_s0 <= done_tog;
			done_tog_s1 <= done_tog_s0;
			job_err_s0 <= d_job_err;
			job_err_s1 <= job_err_s0;
			(* full_case, parallel_case *)
			case (cstate)
				3'd0:
					if (pre_start) begin
						job_wsrc <= pre_src_addr;
						job_qsrc <= pre_qsrc_addr;
						job_wlen <= pre_wlen;
						job_qlen <= pre_qlen;
						job_bank <= pre_bank;
						job_tog <= ~job_tog;
						exp_w_words <= (pre_wlen + 18'd7) >> 32'sd3;
						exp_q_words <= (pre_qlen + 13'd7) >> 32'sd3;
						fill_clr <= 1'b1;
						pre_err <= 1'b0;
						cstate <= 3'd1;
					end
				3'd1:
					if (done_tog_s1 != done_seen) begin
						done_seen <= done_tog_s1;
						settle_cnt <= 8'd8;
						cstate <= 3'd2;
					end
				3'd2:
					if (settle_cnt == 8'd0)
						cstate <= 3'd3;
					else
						settle_cnt <= settle_cnt - 8'd1;
				3'd3:
					if (((wfifo_empty && qfifo_empty) && (wd_state == 2'd0)) && (qd_state == 2'd0)) begin
						pre_err <= (job_err_s1 | (wcnt != exp_w_words)) | (qcnt != exp_q_words);
						cstate <= 3'd4;
					end
				3'd4: begin
					pre_done <= 1'b1;
					cstate <= 3'd0;
				end
				default: cstate <= 3'd0;
			endcase
		end
	reg [2:0] dstate;
	reg req_tog_s0;
	reg req_tog_s1;
	reg req_tog_seen;
	reg [31:0] d_wsrc;
	reg [31:0] d_qsrc;
	reg [17:0] d_wlen;
	reg [12:0] d_qlen;
	reg [31:0] w_aligned;
	reg [15:0] w_beats;
	reg [4:0] w_offset;
	reg [4:0] w_last_hi;
	reg [31:0] q_aligned;
	reg [15:0] q_beats;
	reg [4:0] q_offset;
	reg [4:0] q_last_hi;
	reg [15:0] t_beat;
	wire [4:0] w_cur_lo;
	wire [4:0] w_cur_hi;
	wire [4:0] q_cur_lo;
	wire [4:0] q_cur_hi;
	reg [15:0] beat_mask;
	assign w_cur_lo = (t_beat == 16'd0 ? w_offset : 5'd0);
	assign w_cur_hi = (t_beat == (w_beats - 16'd1) ? w_last_hi : 5'd16);
	assign q_cur_lo = (t_beat == 16'd0 ? q_offset : 5'd0);
	assign q_cur_hi = (t_beat == (q_beats - 16'd1) ? q_last_hi : 5'd16);
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		beat_mask = 16'h0000;
		begin : sv2v_autoblock_1
			reg signed [31:0] j;
			for (j = 0; j < 16; j = j + 1)
				if (dstate == 3'd2)
					beat_mask[j] = (j >= sv2v_cast_32_signed(w_cur_lo)) && (j < sv2v_cast_32_signed(w_cur_hi));
				else
					beat_mask[j] = (j >= sv2v_cast_32_signed(q_cur_lo)) && (j < sv2v_cast_32_signed(q_cur_hi));
		end
	end
	assign ddr_rd_re = (dstate == 3'd1) || (dstate == 3'd3);
	assign ddr_rd_addr = (dstate == 3'd1 ? w_aligned : q_aligned);
	assign ddr_rd_len = (dstate == 3'd1 ? w_beats : q_beats);
	assign ddr_rd_rready = (dstate == 3'd2 ? !wfifo_full : (dstate == 3'd4 ? !qfifo_full : 1'b0));
	assign wfifo_winc = ((dstate == 3'd2) && ddr_rd_valid) && ddr_rd_rready;
	assign wfifo_wdata = {beat_mask, ddr_rd_data};
	assign qfifo_winc = ((dstate == 3'd4) && ddr_rd_valid) && ddr_rd_rready;
	assign qfifo_wdata = {beat_mask, ddr_rd_data};
	function automatic [17:0] sv2v_cast_18;
		input reg [17:0] inp;
		sv2v_cast_18 = inp;
	endfunction
	always @(posedge ddr_clk)
		if (ddr_rst) begin
			dstate <= 3'd0;
			req_tog_s0 <= 1'b0;
			req_tog_s1 <= 1'b0;
			req_tog_seen <= 1'b0;
			done_tog <= 1'b0;
			d_wsrc <= 1'sb0;
			d_qsrc <= 1'sb0;
			d_wlen <= 1'sb0;
			d_qlen <= 1'sb0;
			d_job_err <= 1'b0;
			w_aligned <= 1'sb0;
			w_beats <= 1'sb0;
			w_offset <= 1'sb0;
			w_last_hi <= 1'sb0;
			q_aligned <= 1'sb0;
			q_beats <= 1'sb0;
			q_offset <= 1'sb0;
			q_last_hi <= 1'sb0;
			t_beat <= 1'sb0;
		end
		else begin
			req_tog_s0 <= job_tog;
			req_tog_s1 <= req_tog_s0;
			(* full_case, parallel_case *)
			case (dstate)
				3'd0:
					if (req_tog_s1 != req_tog_seen) begin
						req_tog_seen <= req_tog_s1;
						d_wsrc <= job_wsrc;
						d_qsrc <= job_qsrc;
						d_wlen <= job_wlen;
						d_qlen <= job_qlen;
						d_job_err <= 1'b0;
						if ((job_wlen == 18'd0) && (job_qlen == 13'd0))
							dstate <= 3'd5;
						else if ((((job_wlen > sv2v_cast_18(MAX_PRE_WLEN)) || (sv2v_cast_32((sv2v_cast_32(job_qlen) + 32'd7) >> 3) > Q_FILL_W64)) || ((job_wlen != 18'd0) && (job_wsrc[2:0] != 3'd0))) || ((job_qlen != 13'd0) && (job_qsrc[2:0] != 3'd0))) begin
							d_job_err <= 1'b1;
							dstate <= 3'd5;
						end
						else if (job_wlen == 18'd0) begin
							q_aligned <= {job_qsrc[31:4], 4'h0};
							q_offset <= job_qsrc[3:0];
							q_beats <= ceil_beats(sv2v_cast_18(job_qlen), job_qsrc[3:0]);
							q_last_hi <= last_hi_of(sv2v_cast_18(job_qlen), job_qsrc[3:0], ceil_beats(sv2v_cast_18(job_qlen), job_qsrc[3:0]));
							t_beat <= 16'd0;
							dstate <= 3'd3;
						end
						else begin
							w_aligned <= {job_wsrc[31:4], 4'h0};
							w_offset <= job_wsrc[3:0];
							w_beats <= ceil_beats(job_wlen, job_wsrc[3:0]);
							w_last_hi <= last_hi_of(job_wlen, job_wsrc[3:0], ceil_beats(job_wlen, job_wsrc[3:0]));
							t_beat <= 16'd0;
							dstate <= 3'd1;
						end
					end
				3'd1:
					if (ddr_rd_ready)
						dstate <= 3'd2;
				3'd2:
					if (wfifo_winc) begin
						t_beat <= t_beat + 16'd1;
						if (t_beat == (w_beats - 16'd1)) begin
							if (d_qlen == 13'd0)
								dstate <= 3'd5;
							else begin
								q_aligned <= {d_qsrc[31:4], 4'h0};
								q_offset <= d_qsrc[3:0];
								q_beats <= ceil_beats(sv2v_cast_18(d_qlen), d_qsrc[3:0]);
								q_last_hi <= last_hi_of(sv2v_cast_18(d_qlen), d_qsrc[3:0], ceil_beats(sv2v_cast_18(d_qlen), d_qsrc[3:0]));
								t_beat <= 16'd0;
								dstate <= 3'd3;
							end
						end
					end
				3'd3:
					if (ddr_rd_ready)
						dstate <= 3'd4;
				3'd4:
					if (qfifo_winc) begin
						t_beat <= t_beat + 16'd1;
						if (t_beat == (q_beats - 16'd1))
							dstate <= 3'd5;
					end
				3'd5: begin
					d_job_err <= (d_job_err | wfifo_ovf) | qfifo_ovf;
					done_tog <= ~done_tog;
					dstate <= 3'd0;
				end
				default: dstate <= 3'd0;
			endcase
		end
	reg pre_start_d;
	always @(posedge clk)
		if (rst)
			pre_start_d <= 1'b0;
		else begin
			pre_start_d <= pre_start;
			if ((pre_start && !pre_start_d) && (pre_wlen > sv2v_cast_18(MAX_PRE_WLEN)))
				$display("[nn_wload] ERROR @%0t: pre_wlen=%0d > MAX_PRE_WLEN=%0d", $time, pre_wlen, MAX_PRE_WLEN);
		end
	initial $display("[nn_wload] CONFIG MAX_PRE_WLEN=%0d W_FILL_W64=%0d Q_FILL_W64=%0d FIFO_AW=%0d (fifo=%0d B)", MAX_PRE_WLEN, W_FILL_W64, Q_FILL_W64, FIFO_AW, (1 << FIFO_AW) * 16);
	initial _sv2v_0 = 0;
endmodule
module nn_wload_afifo (
	wclk,
	wrst,
	winc,
	wdata,
	wfull,
	wr_ovf,
	rclk,
	rrst,
	rinc,
	rdata,
	rempty
);
	parameter [31:0] DW = 144;
	parameter [31:0] AW = 5;
	input wire wclk;
	input wire wrst;
	input wire winc;
	input wire [DW - 1:0] wdata;
	output wire wfull;
	output reg wr_ovf;
	input wire rclk;
	input wire rrst;
	input wire rinc;
	output wire [DW - 1:0] rdata;
	output wire rempty;
	localparam [31:0] DEPTH = 1 << AW;
	reg [DW - 1:0] mem [0:DEPTH - 1];
	reg [AW:0] wbin;
	reg [AW:0] wgray;
	reg [AW:0] rbin;
	reg [AW:0] rgray;
	wire [AW:0] wgray_next;
	wire [AW:0] rgray_next;
	reg [AW:0] rgray_s1;
	reg [AW:0] rq2_wgray;
	reg [AW:0] wgray_s1;
	reg [AW:0] wq2_rgray;
	function automatic [AW:0] bin2gray;
		input reg [AW:0] b;
		bin2gray = (b >> 1) ^ b;
	endfunction
	assign wgray_next = bin2gray(wbin + 1'b1);
	assign rgray_next = bin2gray(rbin + 1'b1);
	assign wfull = wgray == {~wq2_rgray[AW:AW - 1], wq2_rgray[AW - 2:0]};
	assign rempty = rgray == rq2_wgray;
	assign rdata = mem[rbin[AW - 1:0]];
	always @(posedge wclk)
		if (wrst) begin
			wbin <= 1'sb0;
			wgray <= 1'sb0;
			wr_ovf <= 1'b0;
		end
		else if (winc) begin
			if (wfull)
				wr_ovf <= 1'b1;
			else begin
				mem[wbin[AW - 1:0]] <= wdata;
				wbin <= wbin + 1'b1;
				wgray <= wgray_next;
			end
		end
	always @(posedge rclk)
		if (rrst) begin
			rbin <= 1'sb0;
			rgray <= 1'sb0;
		end
		else if (rinc && !rempty) begin
			rbin <= rbin + 1'b1;
			rgray <= rgray_next;
		end
	always @(posedge wclk)
		if (wrst) begin
			rgray_s1 <= 1'sb0;
			wq2_rgray <= 1'sb0;
		end
		else begin
			rgray_s1 <= rgray;
			wq2_rgray <= rgray_s1;
		end
	always @(posedge rclk)
		if (rrst) begin
			wgray_s1 <= 1'sb0;
			rq2_wgray <= 1'sb0;
		end
		else begin
			wgray_s1 <= wgray;
			rq2_wgray <= wgray_s1;
		end
endmodule
module nn_tilecache (
	clk,
	rst,
	d_in_base,
	d_in_rows,
	d_in_row_bytes,
	d_in_stride,
	d_in_pad_top,
	d_in_rd_rows,
	d_zp_in,
	d_add_mode,
	d_aux_base,
	d_aux_stride,
	d_aux_pad_top,
	d_aux_rd_rows,
	d_out_base,
	d_out_rows,
	d_out_row_bytes,
	d_out_stride,
	d_a_src_base,
	d_a_aux_base,
	d_b_base,
	d_in_word_off,
	d_out_word_off,
	band_start,
	band_ready,
	engine_done,
	band_done,
	busy,
	err_code,
	cur_bank,
	fill_beats,
	flush_beats,
	dd_rd_re,
	dd_rd_addr,
	dd_rd_len,
	dd_rd_ready,
	dd_rd_data,
	dd_rd_valid,
	dd_rd_last,
	dd_rd_rready,
	dd_wr_re,
	dd_wr_addr,
	dd_wr_len,
	dd_wr_ready,
	dd_wr_data,
	dd_wr_valid,
	dd_wr_rready,
	dd_wr_done,
	a_sel,
	a_re,
	a_addr,
	a_rdata,
	b_sel,
	b_we,
	b_addr,
	b_wdata,
	b_wstrb
);
	parameter [31:0] IB_BYTES = 16384;
	parameter [31:0] OB_BYTES = 12288;
	input wire clk;
	input wire rst;
	input wire [31:0] d_in_base;
	input wire [15:0] d_in_rows;
	input wire [15:0] d_in_row_bytes;
	input wire [15:0] d_in_stride;
	input wire [15:0] d_in_pad_top;
	input wire [15:0] d_in_rd_rows;
	input wire [7:0] d_zp_in;
	input wire d_add_mode;
	input wire [31:0] d_aux_base;
	input wire [15:0] d_aux_stride;
	input wire [15:0] d_aux_pad_top;
	input wire [15:0] d_aux_rd_rows;
	input wire [31:0] d_out_base;
	input wire [15:0] d_out_rows;
	input wire [15:0] d_out_row_bytes;
	input wire [15:0] d_out_stride;
	input wire [23:0] d_a_src_base;
	input wire [23:0] d_a_aux_base;
	input wire [23:0] d_b_base;
	input wire [16:0] d_in_word_off;
	input wire [16:0] d_out_word_off;
	input wire band_start;
	output reg band_ready;
	input wire engine_done;
	output reg band_done;
	output wire busy;
	output wire [7:0] err_code;
	output wire [1:0] cur_bank;
	output reg [31:0] fill_beats;
	output reg [31:0] flush_beats;
	output wire dd_rd_re;
	output wire [31:0] dd_rd_addr;
	output wire [15:0] dd_rd_len;
	input wire dd_rd_ready;
	input wire [127:0] dd_rd_data;
	input wire dd_rd_valid;
	input wire dd_rd_last;
	output wire dd_rd_rready;
	output wire dd_wr_re;
	output wire [31:0] dd_wr_addr;
	output wire [15:0] dd_wr_len;
	input wire dd_wr_ready;
	output wire [127:0] dd_wr_data;
	output wire dd_wr_valid;
	input wire dd_wr_rready;
	input wire dd_wr_done;
	input wire [1:0] a_sel;
	input wire a_re;
	input wire [23:0] a_addr;
	output wire [127:0] a_rdata;
	input wire [1:0] b_sel;
	input wire b_we;
	input wire [23:0] b_addr;
	input wire [127:0] b_wdata;
	input wire [15:0] b_wstrb;
	localparam [31:0] IB_WORDS = IB_BYTES / 16;
	localparam [31:0] OB_WORDS = OB_BYTES / 16;
	localparam [31:0] IB_AW = $clog2(IB_WORDS);
	localparam [31:0] OB_AW = $clog2(OB_WORDS);
	reg [127:0] ibuf [0:1][0:IB_WORDS - 1];
	reg [127:0] obuf [0:1][0:OB_WORDS - 1];
	reg band_parity;
	wire in_bank;
	wire aux_bank;
	wire out_bank;
	assign in_bank = band_parity;
	assign aux_bank = ~band_parity;
	assign out_bank = band_parity;
	assign cur_bank = {out_bank, in_bank};
	reg [23:0] a_src_base;
	reg [23:0] a_aux_base;
	reg [23:0] b_base;
	reg a_re_q;
	reg [1:0] a_sel_q;
	reg [23:0] a_addr_q;
	reg [127:0] a_rdata_q;
	reg [IB_AW - 1:0] ib_words;
	reg [IB_AW - 1:0] aux_words;
	wire [23:0] a_local;
	reg [23:0] a_local_q;
	wire [IB_AW - 1:0] a_word;
	assign a_local = a_addr - (a_sel[0] ? a_aux_base : a_src_base);
	assign a_word = a_local[IB_AW + 3:4];
	wire a_in_band = (a_sel[0] ? a_word < aux_words : a_word < ib_words);
	always @(posedge clk)
		if (rst) begin
			a_re_q <= 1'b0;
			a_sel_q <= 2'd0;
			a_addr_q <= 24'd0;
			a_local_q <= 24'd0;
			a_rdata_q <= 128'd0;
		end
		else begin
			a_re_q <= a_re;
			a_sel_q <= a_sel;
			a_addr_q <= a_addr;
			a_local_q <= a_local;
			if (!a_re || !a_in_band)
				a_rdata_q <= 128'd0;
			else
				a_rdata_q <= ibuf[(a_sel[0] ? aux_bank : in_bank)][a_word];
		end
	assign a_rdata = a_rdata_q;
	wire [23:0] b_local;
	assign b_local = b_addr - b_base;
	function automatic [23:0] sv2v_cast_24;
		input reg [23:0] inp;
		sv2v_cast_24 = inp;
	endfunction
	always @(posedge clk)
		if (b_we && (b_local[23:4] < sv2v_cast_24(OB_WORDS))) begin : sv2v_autoblock_1
			reg signed [31:0] bi;
			for (bi = 0; bi < 16; bi = bi + 1)
				if (b_wstrb[bi])
					obuf[out_bank][b_local[OB_AW + 3:4]][bi * 8+:8] <= b_wdata[bi * 8+:8];
		end
	reg [31:0] in_base;
	reg [31:0] aux_base;
	reg [31:0] out_base;
	reg [15:0] in_rows;
	reg [15:0] in_row_bytes;
	reg [15:0] in_stride;
	reg [15:0] in_pad_top;
	reg [15:0] in_rd_rows;
	reg [15:0] out_rows;
	reg [15:0] out_row_bytes;
	reg [15:0] out_stride;
	reg [15:0] aux_stride;
	reg [15:0] aux_pad_top;
	reg [15:0] aux_rd_rows;
	reg [15:0] in_beats_row;
	reg [15:0] out_beats_row;
	reg [15:0] aux_beats_row;
	reg [7:0] zp_in;
	reg add_mode;
	reg [7:0] err_q;
	reg [1:0] seg;
	reg [15:0] row;
	reg [15:0] beat;
	reg [15:0] rows_this;
	reg [15:0] pad_top_this;
	reg [15:0] rd_rows_this;
	reg [15:0] beats_row_this;
	reg [31:0] base_this;
	reg [15:0] stride_this;
	reg [IB_AW - 1:0] ib_widx;
	reg [16:0] in_word_off;
	reg [16:0] out_word_off;
	reg [3:0] state;
	assign dd_rd_re = state == 4'd2;
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	assign dd_rd_addr = base_this + ((sv2v_cast_32(row) - sv2v_cast_32(pad_top_this)) * sv2v_cast_32(stride_this));
	assign dd_rd_len = beats_row_this;
	assign dd_rd_rready = state == 4'd3;
	assign dd_wr_re = state == 4'd6;
	assign dd_wr_addr = out_base + (sv2v_cast_32(row) * sv2v_cast_32(out_stride));
	assign dd_wr_len = out_beats_row;
	function automatic [OB_AW - 1:0] sv2v_cast_B1494;
		input reg [OB_AW - 1:0] inp;
		sv2v_cast_B1494 = inp;
	endfunction
	assign dd_wr_data = obuf[out_bank][sv2v_cast_B1494((sv2v_cast_32(out_word_off) + (sv2v_cast_32(row) * sv2v_cast_32(out_beats_row))) + sv2v_cast_32(beat))];
	assign dd_wr_valid = state == 4'd7;
	assign busy = state != 4'd0;
	function automatic [IB_AW - 1:0] sv2v_cast_1CDB2;
		input reg [IB_AW - 1:0] inp;
		sv2v_cast_1CDB2 = inp;
	endfunction
	always @(posedge clk)
		if (rst) begin
			state <= 4'd0;
			band_ready <= 1'b0;
			band_done <= 1'b0;
			err_q <= 8'h00;
			band_parity <= 1'b0;
			seg <= 2'd0;
			row <= 16'd0;
			beat <= 16'd0;
			rows_this <= 16'd0;
			pad_top_this <= 16'd0;
			rd_rows_this <= 16'd0;
			beats_row_this <= 16'd0;
			base_this <= 32'd0;
			stride_this <= 16'd0;
			ib_widx <= 1'sb0;
			in_base <= 32'd0;
			aux_base <= 32'd0;
			out_base <= 32'd0;
			in_rows <= 16'd0;
			in_row_bytes <= 16'd0;
			in_stride <= 16'd0;
			in_pad_top <= 16'd0;
			in_rd_rows <= 16'd0;
			out_rows <= 16'd0;
			out_row_bytes <= 16'd0;
			out_stride <= 16'd0;
			aux_stride <= 16'd0;
			aux_pad_top <= 16'd0;
			aux_rd_rows <= 16'd0;
			in_beats_row <= 16'd0;
			out_beats_row <= 16'd0;
			aux_beats_row <= 16'd0;
			zp_in <= 8'h00;
			add_mode <= 1'b0;
			a_src_base <= 24'd0;
			a_aux_base <= 24'd0;
			b_base <= 24'd0;
			in_word_off <= 17'd0;
			out_word_off <= 17'd0;
			ib_words <= 1'sb0;
			aux_words <= 1'sb0;
			fill_beats <= 32'd0;
			flush_beats <= 32'd0;
		end
		else begin
			band_done <= 1'b0;
			(* full_case, parallel_case *)
			case (state)
				4'd0: begin
					band_ready <= 1'b0;
					if (band_start) begin
						err_q <= 8'h00;
						if ((((d_in_row_bytes[3:0] != 4'h0) || (d_in_stride[3:0] != 4'h0)) || (d_out_row_bytes[3:0] != 4'h0)) || (d_out_stride[3:0] != 4'h0)) begin
							err_q <= 8'he0;
							state <= 4'd8;
						end
						else if (((sv2v_cast_32(d_in_rows) * sv2v_cast_32(d_in_row_bytes)) > IB_BYTES) || ((sv2v_cast_32(d_out_rows) * sv2v_cast_32(d_out_row_bytes)) > OB_BYTES)) begin
							err_q <= 8'he1;
							state <= 4'd8;
						end
						else if (((sv2v_cast_32(d_in_pad_top) + sv2v_cast_32(d_in_rd_rows)) > sv2v_cast_32(d_in_rows)) || (d_add_mode && ((sv2v_cast_32(d_aux_pad_top) + sv2v_cast_32(d_aux_rd_rows)) > sv2v_cast_32(d_in_rows)))) begin
							err_q <= 8'he2;
							state <= 4'd8;
						end
						else begin
							in_base <= d_in_base;
							in_rows <= d_in_rows;
							in_row_bytes <= d_in_row_bytes;
							in_stride <= d_in_stride;
							in_pad_top <= d_in_pad_top;
							in_rd_rows <= d_in_rd_rows;
							out_base <= d_out_base;
							out_rows <= d_out_rows;
							out_row_bytes <= d_out_row_bytes;
							out_stride <= d_out_stride;
							zp_in <= d_zp_in;
							add_mode <= d_add_mode;
							aux_base <= d_aux_base;
							aux_stride <= d_aux_stride;
							aux_pad_top <= d_aux_pad_top;
							aux_rd_rows <= d_aux_rd_rows;
							a_src_base <= d_a_src_base;
							a_aux_base <= d_a_aux_base;
							b_base <= d_b_base;
							in_word_off <= d_in_word_off;
							out_word_off <= d_out_word_off;
							in_beats_row <= d_in_row_bytes >> 4;
							out_beats_row <= d_out_row_bytes >> 4;
							aux_beats_row <= d_aux_stride >> 4;
							ib_words <= sv2v_cast_1CDB2(sv2v_cast_32(d_in_rows) * (sv2v_cast_32(d_in_row_bytes) >> 4));
							aux_words <= sv2v_cast_1CDB2((sv2v_cast_32(d_aux_pad_top) + sv2v_cast_32(d_aux_rd_rows)) * (sv2v_cast_32(d_aux_stride) >> 4));
							band_parity <= ~band_parity;
							fill_beats <= 32'd0;
							flush_beats <= 32'd0;
							seg <= 2'd0;
							row <= 16'd0;
							beat <= 16'd0;
							rows_this <= d_in_rows;
							pad_top_this <= d_in_pad_top;
							rd_rows_this <= d_in_rd_rows;
							base_this <= d_in_base;
							stride_this <= d_in_stride;
							beats_row_this <= d_in_row_bytes >> 4;
							ib_widx <= 1'sb0;
							state <= 4'd1;
						end
					end
				end
				4'd1:
					if ((row < pad_top_this) || (row >= (pad_top_this + rd_rows_this))) begin
						beat <= 16'd0;
						state <= 4'd4;
					end
					else begin
						beat <= 16'd0;
						state <= 4'd2;
					end
				4'd2:
					if (dd_rd_ready)
						state <= 4'd3;
				4'd3:
					if (dd_rd_valid && dd_rd_rready) begin
						ibuf[(seg == 2'd1 ? aux_bank : in_bank)][sv2v_cast_1CDB2(ib_widx + in_word_off[IB_AW - 1:0])] <= dd_rd_data;
						ib_widx <= ib_widx + 1'b1;
						fill_beats <= fill_beats + 32'd1;
						if (beat == (beats_row_this - 16'd1)) begin
							beat <= 16'd0;
							row <= row + 16'd1;
							if (row == (rows_this - 16'd1)) begin
								if (add_mode && (seg == 2'd0)) begin
									seg <= 2'd1;
									row <= 16'd0;
									pad_top_this <= aux_pad_top;
									rd_rows_this <= aux_rd_rows;
									base_this <= aux_base;
									stride_this <= aux_stride;
									beats_row_this <= aux_beats_row;
									ib_widx <= 1'sb0;
									state <= 4'd1;
								end
								else begin
									band_ready <= 1'b1;
									state <= 4'd5;
								end
							end
							else
								state <= 4'd1;
						end
						else
							beat <= beat + 16'd1;
					end
				4'd4: begin
					ibuf[(seg == 2'd1 ? aux_bank : in_bank)][sv2v_cast_1CDB2(ib_widx + in_word_off[IB_AW - 1:0])] <= {16 {zp_in}};
					ib_widx <= ib_widx + 1'b1;
					fill_beats <= fill_beats + 32'd1;
					if (beat == (beats_row_this - 16'd1)) begin
						beat <= 16'd0;
						row <= row + 16'd1;
						if (row == (rows_this - 16'd1)) begin
							if (add_mode && (seg == 2'd0)) begin
								seg <= 2'd1;
								row <= 16'd0;
								pad_top_this <= aux_pad_top;
								rd_rows_this <= aux_rd_rows;
								base_this <= aux_base;
								stride_this <= aux_stride;
								beats_row_this <= aux_beats_row;
								ib_widx <= 1'sb0;
								state <= 4'd1;
							end
							else begin
								band_ready <= 1'b1;
								state <= 4'd5;
							end
						end
						else
							state <= 4'd1;
					end
					else
						beat <= beat + 16'd1;
				end
				4'd5:
					if (engine_done) begin
						band_ready <= 1'b0;
						row <= 16'd0;
						beat <= 16'd0;
						state <= 4'd6;
					end
				4'd6:
					if (dd_wr_ready)
						state <= 4'd7;
				4'd7:
					if (dd_wr_valid && dd_wr_rready) begin
						flush_beats <= flush_beats + 32'd1;
						if (beat == (out_beats_row - 16'd1)) begin
							beat <= 16'd0;
							row <= row + 16'd1;
							if (row == (out_rows - 16'd1))
								state <= 4'd8;
							else
								state <= 4'd6;
						end
						else
							beat <= beat + 16'd1;
					end
				4'd8: begin
					band_done <= 1'b1;
					state <= 4'd0;
				end
				default: state <= 4'd0;
			endcase
		end
	assign err_code = err_q;
	initial $display("[nn_tilecache] CONFIG IB=%0d B/bank x2, OB=%0d B/bank x2, total=%0d B", IB_BYTES, OB_BYTES, (2 * IB_BYTES) + (2 * OB_BYTES));
	always @(posedge clk)
		if ((b_we && (b_local[23:4] >= sv2v_cast_24(OB_WORDS))) && !rst)
			$display("[nn_tilecache] ERROR @%0t: OBUF write addr 0x%06x out of range", $time, b_addr);
endmodule
module nn_subsys (
	clk,
	rst,
	ctl_we,
	ctl_re,
	ctl_addr,
	ctl_wdata,
	ctl_wstrb,
	ctl_rdata,
	cpu_re,
	cpu_we,
	cpu_addr,
	cpu_wdata,
	cpu_wstrb,
	cpu_rdata,
	busy_o,
	done_o,
	err_o,
	cycles_o,
	err_code_o
);
	reg _sv2v_0;
	localparam [31:0] nn_pkg_NN_W_BYTES = 327680;
	parameter [31:0] W_BYTES = nn_pkg_NN_W_BYTES;
	localparam [31:0] nn_pkg_NN_Q_BYTES = 49152;
	parameter [31:0] Q_BYTES = nn_pkg_NN_Q_BYTES;
	localparam [31:0] nn_pkg_NN_A_BYTES = 98304;
	parameter [31:0] A_BYTES = nn_pkg_NN_A_BYTES;
	localparam [31:0] nn_pkg_NN_B_BYTES = 32768;
	parameter [31:0] B_BYTES = nn_pkg_NN_B_BYTES;
	input wire clk;
	input wire rst;
	input wire ctl_we;
	input wire ctl_re;
	input wire [31:0] ctl_addr;
	input wire [31:0] ctl_wdata;
	input wire [3:0] ctl_wstrb;
	output reg [31:0] ctl_rdata;
	input wire cpu_re;
	input wire cpu_we;
	input wire [31:0] cpu_addr;
	input wire [31:0] cpu_wdata;
	input wire [3:0] cpu_wstrb;
	output wire [31:0] cpu_rdata;
	output wire busy_o;
	output wire done_o;
	output wire err_o;
	output wire [31:0] cycles_o;
	output wire [7:0] err_code_o;
	reg [31:0] r_op;
	reg [31:0] r_src;
	reg [31:0] r_dst;
	reg [31:0] r_woff;
	reg [31:0] r_qoff;
	reg [31:0] r_ih;
	reg [31:0] r_iw;
	reg [31:0] r_ic;
	reg [31:0] r_oc;
	reg [31:0] r_ks;
	reg [31:0] r_st;
	reg [31:0] r_pad;
	reg [31:0] r_flags;
	reg r_irq_en;
	reg auto_r;
	reg done_r;
	reg err_r;
	reg [7:0] err_code_r;
	reg [31:0] cycles_r;
	wire [210:0] desc_next;
	assign desc_next = {r_op[1:0], r_flags[7:0], r_ks[3:0], r_st[1:0], r_pad[2:0], r_ih[15:0], r_iw[15:0], r_ic[15:0], r_oc[15:0], r_src, r_dst, r_woff, r_qoff};
	reg [210:0] desc_r;
	reg eng_start_cpu;
	wire eng_start_seq;
	wire eng_start;
	wire [210:0] eng_desc;
	wire eng_busy;
	wire eng_done;
	wire [31:0] eng_cycles;
	wire [7:0] eng_err;
	wire eng_w_re;
	wire [23:0] eng_w_addr;
	wire [127:0] eng_w_rdata;
	wire eng_q_re;
	wire [12:0] eng_q_addr;
	wire [63:0] eng_q_rdata;
	wire [1:0] eng_a_sel;
	wire eng_a_re;
	wire [23:0] eng_a_addr;
	wire [127:0] eng_a_rdata;
	wire [1:0] eng_b_sel;
	wire eng_b_we;
	wire [23:0] eng_b_addr;
	wire [127:0] eng_b_wdata;
	wire [15:0] eng_b_wstrb;
	wire [210:0] desc_seq;
	reg seq_start;
	wire seq_busy;
	wire seq_done;
	wire [31:0] seq_cycles;
	wire seq_err;
	wire [7:0] seq_err_code;
	wire cpu_we_g;
	wire [31:0] mem_cpu_rdata;
	wire [31:0] cpu_off;
	assign done_o = done_r;
	assign err_o = err_r;
	localparam [31:0] NN_MB_WORDS = 512;
	localparam [31:0] NN_MB_PAY_WORD = 8;
	localparam [31:0] NN_MB_MAGIC_VAL = 32'h4e505552;
	reg [31:0] j_in_r;
	reg [31:0] j_out_r;
	reg [31:0] j_model_r;
	reg [31:0] j_frame_r;
	reg [31:0] j_len_r;
	reg j_pending;
	reg j_copy;
	reg j_ever;
	reg j_done;
	reg j_err;
	reg j_timeout;
	reg [7:0] j_err_code;
	reg [31:0] j_cycles;
	reg [31:0] j_frame_no;
	reg [31:0] j_jobs_done;
	reg [31:0] j_drop_cnt;
	wire j_mb_sel;
	reg [31:0] j_mb_rdata;
	(* ram_style = "distributed" *) reg [31:0] j_mb [0:511];
	reg [2:0] mc_st;
	reg [31:0] j_copy_addr;
	reg [10:0] j_copy_cnt;
	reg [10:0] j_len_words;
	reg [3:0] j_hdr_idx;
	reg job_start_pulse;
	wire seq_start_all = seq_start | job_start_pulse;
	wire mc_mem_active = (mc_st == 3'd1) || (mc_st == 3'd2);
	wire mem_cpu_re = (mc_mem_active ? 1'b1 : cpu_re);
	wire [31:0] mem_cpu_addr = (mc_mem_active ? j_copy_addr : cpu_off);
	wire [7:0] seq_done_ops;
	wire seq_job_timeout;
	reg [31:0] seq_cycles_lat;
	reg j_mb_sel_r;
	always @(posedge clk) begin
		j_mb_rdata <= j_mb[cpu_off[10:2]];
		j_mb_sel_r <= j_mb_sel;
	end
	initial begin : sv2v_autoblock_1
		reg signed [31:0] i;
		for (i = 0; i < NN_MB_WORDS; i = i + 1)
			j_mb[i] = 32'd0;
	end
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_ACK = 32'ha0000174;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_DOORBELL = 32'ha0000170;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_FRAME = 32'ha000016c;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_IN_ADDR = 32'ha0000160;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_LEN = 32'ha000017c;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_MODEL = 32'ha0000168;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_OUT_ADDR = 32'ha0000164;
	always @(posedge clk)
		if (rst) begin
			j_in_r <= 1'sb0;
			j_out_r <= 1'sb0;
			j_model_r <= 1'sb0;
			j_frame_r <= 1'sb0;
			j_len_r <= 1'sb0;
			j_pending <= 1'b0;
			j_copy <= 1'b0;
			j_ever <= 1'b0;
			j_done <= 1'b0;
			j_err <= 1'b0;
			j_timeout <= 1'b0;
			j_err_code <= 8'h00;
			j_cycles <= 32'd0;
			j_frame_no <= 32'd0;
			j_jobs_done <= 32'd0;
			j_drop_cnt <= 32'd0;
			mc_st <= 3'd0;
			j_copy_addr <= 32'd0;
			j_copy_cnt <= 11'd0;
			j_len_words <= 11'd0;
			j_hdr_idx <= 4'd0;
			job_start_pulse <= 1'b0;
			seq_cycles_lat <= 32'd0;
		end
		else begin
			job_start_pulse <= 1'b0;
			if (ctl_we)
				(* full_case, parallel_case *)
				case (ctl_addr)
					rv32_pkg_MMIO_NN_JOB_IN_ADDR: j_in_r <= ctl_wdata;
					rv32_pkg_MMIO_NN_JOB_OUT_ADDR: j_out_r <= ctl_wdata;
					rv32_pkg_MMIO_NN_JOB_MODEL: j_model_r <= ctl_wdata;
					rv32_pkg_MMIO_NN_JOB_FRAME: j_frame_r <= ctl_wdata;
					rv32_pkg_MMIO_NN_JOB_LEN: j_len_r <= ctl_wdata;
					rv32_pkg_MMIO_NN_JOB_DOORBELL:
						if (ctl_wdata[0]) begin
							if (((busy_o || j_done) || j_pending) || j_copy)
								j_drop_cnt <= j_drop_cnt + 32'd1;
							else begin
								j_ever <= 1'b1;
								j_done <= 1'b0;
								j_err <= 1'b0;
								j_timeout <= 1'b0;
								j_err_code <= 8'h00;
								j_cycles <= 32'd0;
								j_frame_no <= j_frame_r;
								if (j_model_r[7:0] != 8'd0) begin
									j_err <= 1'b1;
									j_err_code <= 8'he7;
									j_done <= 1'b1;
								end
								else if ((j_len_r > 32'd2016) || (j_len_r[1:0] != 2'b00)) begin
									j_err <= 1'b1;
									j_err_code <= 8'he1;
									j_done <= 1'b1;
								end
								else begin
									j_pending <= 1'b1;
									j_len_words <= j_len_r[12:2];
									job_start_pulse <= 1'b1;
								end
							end
						end
					rv32_pkg_MMIO_NN_JOB_ACK:
						if (ctl_wdata[0]) begin
							j_done <= 1'b0;
							j_err <= 1'b0;
							j_timeout <= 1'b0;
							j_err_code <= 8'h00;
						end
					default:
						;
				endcase
			if (j_pending) begin
				if (seq_job_timeout || seq_err) begin
					j_pending <= 1'b0;
					j_err <= 1'b1;
					j_err_code <= (seq_job_timeout ? 8'he4 : seq_err_code);
					j_timeout <= seq_job_timeout;
					j_cycles <= seq_cycles;
					j_jobs_done <= j_jobs_done + 32'd1;
					j_done <= 1'b1;
				end
				else if (seq_done) begin
					j_pending <= 1'b0;
					j_copy <= 1'b1;
					j_cycles <= seq_cycles;
					seq_cycles_lat <= seq_cycles;
					j_frame_no <= j_frame_r;
					j_err <= 1'b0;
					j_err_code <= 8'h00;
					j_jobs_done <= j_jobs_done + 32'd1;
					j_copy_addr <= j_out_r;
					j_copy_cnt <= 11'd0;
					j_hdr_idx <= 4'd0;
					mc_st <= (j_len_words == 11'd0 ? 3'd3 : 3'd1);
				end
			end
			case (mc_st)
				3'd1: begin
					j_copy_addr <= j_copy_addr + 32'd4;
					j_copy_cnt <= 11'd0;
					mc_st <= 3'd2;
				end
				3'd2: begin
					j_mb[NN_MB_PAY_WORD + j_copy_cnt] <= mem_cpu_rdata;
					if ((j_copy_cnt + 11'd1) >= j_len_words)
						mc_st <= 3'd3;
					else begin
						j_copy_cnt <= j_copy_cnt + 11'd1;
						j_copy_addr <= j_copy_addr + 32'd4;
					end
				end
				3'd3: begin
					case (j_hdr_idx)
						4'd0: j_mb[0] <= NN_MB_MAGIC_VAL;
						4'd1: j_mb[1] <= j_frame_r;
						4'd2: j_mb[2] <= j_model_r;
						4'd3: j_mb[3] <= seq_cycles_lat;
						4'd4: j_mb[4] <= {24'd0, j_err_code};
						4'd5: j_mb[5] <= j_out_r;
						4'd6: j_mb[6] <= j_len_r;
						default: j_mb[7] <= 32'd0;
					endcase
					if (j_hdr_idx == 4'd7)
						mc_st <= 3'd4;
					else
						j_hdr_idx <= j_hdr_idx + 4'd1;
				end
				3'd4: begin
					j_copy <= 1'b0;
					j_done <= 1'b1;
					mc_st <= 3'd0;
				end
				default:
					;
			endcase
		end
	assign busy_o = ((auto_r ? seq_busy : eng_busy) | j_pending) | j_copy;
	assign cpu_we_g = cpu_we && !busy_o;
	localparam [31:0] rv32_pkg_NN_BASE = 32'h90040000;
	assign cpu_off = cpu_addr - rv32_pkg_NN_BASE;
	assign j_mb_sel = j_ever && (cpu_off < 32'h00000800);
	assign cpu_rdata = (busy_o ? 32'hdeadbeef : (j_mb_sel_r ? j_mb_rdata : mem_cpu_rdata));
	assign eng_desc = (auto_r || j_pending ? desc_seq : desc_r);
	assign eng_start = (auto_r || j_pending ? eng_start_seq : eng_start_cpu);
	assign cycles_o = (auto_r || j_pending ? seq_cycles : cycles_r);
	assign err_code_o = (auto_r || j_pending ? seq_err_code : err_code_r);
	nn_mem #(
		.W_BYTES(W_BYTES),
		.Q_BYTES(Q_BYTES),
		.A_BYTES(A_BYTES),
		.B_BYTES(B_BYTES)
	) u_mem(
		.clk(clk),
		.rst(rst),
		.cpu_re(mem_cpu_re),
		.cpu_we(cpu_we_g),
		.cpu_addr(mem_cpu_addr),
		.cpu_wdata(cpu_wdata),
		.cpu_wstrb(cpu_wstrb),
		.cpu_rdata(mem_cpu_rdata),
		.w_re(eng_w_re),
		.w_addr(eng_w_addr),
		.w_rdata(eng_w_rdata),
		.q_re(eng_q_re),
		.q_addr(eng_q_addr),
		.q_rdata(eng_q_rdata),
		.a_sel(eng_a_sel),
		.a_re(eng_a_re),
		.a_addr(eng_a_addr),
		.a_rdata(eng_a_rdata),
		.b_sel(eng_b_sel),
		.b_we(eng_b_we),
		.b_addr(eng_b_addr),
		.b_wdata(eng_b_wdata),
		.b_wstrb(eng_b_wstrb),
		.dbg_we(1'b0),
		.dbg_space(1'b0),
		.dbg_addr(17'd0),
		.dbg_wdata(32'd0),
		.w_mode(1'b0),
		.w_bank_sel(1'b0),
		.wfill_we(1'b0),
		.wfill_addr(18'd0),
		.wfill_wdata(64'd0),
		.q_bank_sel(1'b0),
		.qfill_we(1'b0),
		.qfill_addr(13'd0),
		.qfill_wdata(64'd0)
	);
	nn_conv_engine #(
		.OC_LANES(16),
		.PX_LANES(8)
	) u_eng(
		.clk(clk),
		.rst(rst),
		.desc(eng_desc),
		.start(eng_start),
		.busy(eng_busy),
		.done(eng_done),
		.cycles(eng_cycles),
		.err_code(eng_err),
		.w_re(eng_w_re),
		.w_addr(eng_w_addr),
		.w_rdata(eng_w_rdata),
		.q_re(eng_q_re),
		.q_addr(eng_q_addr),
		.q_rdata(eng_q_rdata),
		.a_sel(eng_a_sel),
		.a_re(eng_a_re),
		.a_addr(eng_a_addr),
		.a_rdata(eng_a_rdata),
		.b_sel(eng_b_sel),
		.b_we(eng_b_we),
		.b_addr(eng_b_addr),
		.b_wdata_128(eng_b_wdata),
		.b_wstrb(eng_b_wstrb)
	);
	nn_seq u_seq(
		.clk(clk),
		.rst(rst),
		.start(seq_start_all),
		.busy(seq_busy),
		.done(seq_done),
		.cycles(seq_cycles),
		.err(seq_err),
		.err_code(seq_err_code),
		.done_ops(seq_done_ops),
		.job_timeout(seq_job_timeout),
		.eng_desc(desc_seq),
		.eng_start(eng_start_seq),
		.eng_busy(eng_busy),
		.eng_done(eng_done),
		.eng_cycles(eng_cycles),
		.eng_err_code(eng_err),
		.pre_busy(1'b0),
		.pre_done(1'b1),
		.pre_err(1'b0),
		.band_ready(1'b1),
		.band_done(1'b1),
		.tile_err(8'd0),
		.w_ddr_base(32'd0),
		.q_ddr_base(32'd0),
		.arena_ddr_base(32'd0)
	);
	reg desc_ok;
	localparam [1:0] nn_pkg_NN_OP_CONV = 2'd0;
	localparam [1:0] nn_pkg_NN_OP_POOL = 2'd1;
	always @(*) begin
		if (_sv2v_0)
			;
		desc_ok = 1'b1;
		if ((desc_next[159-:16] == 0) || (desc_next[159-:16] > 1023))
			desc_ok = 1'b0;
		if ((desc_next[143-:16] == 0) || (desc_next[143-:16] > 1023))
			desc_ok = 1'b0;
		if ((desc_next[191-:16] == 0) || (desc_next[175-:16] == 0))
			desc_ok = 1'b0;
		case (desc_next[210-:2])
			nn_pkg_NN_OP_CONV: begin
				if (!(((desc_next[200-:4] == 4'd1) || (desc_next[200-:4] == 4'd3)) || (desc_next[200-:4] == 4'd5)))
					desc_ok = 1'b0;
				if (!((desc_next[196-:2] == 2'd1) || (desc_next[196-:2] == 2'd2)))
					desc_ok = 1'b0;
				if (desc_next[194-:3] > 3'd2)
					desc_ok = 1'b0;
			end
			nn_pkg_NN_OP_POOL: begin
				if (!((((desc_next[200-:4] == 4'd2) || (desc_next[200-:4] == 4'd3)) || (desc_next[200-:4] == 4'd5)) || (desc_next[200-:4] == 4'd9)))
					desc_ok = 1'b0;
				if (desc_next[194-:3] > 3'd4)
					desc_ok = 1'b0;
			end
			default:
				;
		endcase
		if (desc_next[95-:32] >= 32'd4194304)
			desc_ok = 1'b0;
	end
	localparam [31:0] rv32_pkg_MMIO_NN_CTRL = 32'ha0000100;
	localparam [31:0] rv32_pkg_MMIO_NN_DST = 32'ha0000114;
	localparam [31:0] rv32_pkg_MMIO_NN_FLAGS = 32'ha000013c;
	localparam [31:0] rv32_pkg_MMIO_NN_IC = 32'ha0000128;
	localparam [31:0] rv32_pkg_MMIO_NN_IH = 32'ha0000120;
	localparam [31:0] rv32_pkg_MMIO_NN_IW = 32'ha0000124;
	localparam [31:0] rv32_pkg_MMIO_NN_KS = 32'ha0000130;
	localparam [31:0] rv32_pkg_MMIO_NN_OC = 32'ha000012c;
	localparam [31:0] rv32_pkg_MMIO_NN_OP = 32'ha000010c;
	localparam [31:0] rv32_pkg_MMIO_NN_PAD = 32'ha0000138;
	localparam [31:0] rv32_pkg_MMIO_NN_QOFF = 32'ha000011c;
	localparam [31:0] rv32_pkg_MMIO_NN_SRC = 32'ha0000110;
	localparam [31:0] rv32_pkg_MMIO_NN_ST = 32'ha0000134;
	localparam [31:0] rv32_pkg_MMIO_NN_STATUS = 32'ha0000104;
	localparam [31:0] rv32_pkg_MMIO_NN_WOFF = 32'ha0000118;
	always @(posedge clk)
		if (rst) begin
			r_op <= 1'sb0;
			r_src <= 1'sb0;
			r_dst <= 1'sb0;
			r_woff <= 1'sb0;
			r_qoff <= 1'sb0;
			r_ih <= 1'sb0;
			r_iw <= 1'sb0;
			r_ic <= 1'sb0;
			r_oc <= 1'sb0;
			r_ks <= 1'sb0;
			r_st <= 1'sb0;
			r_pad <= 1'sb0;
			r_flags <= 1'sb0;
			r_irq_en <= 1'b0;
			auto_r <= 1'b0;
			desc_r <= 1'sb0;
			eng_start_cpu <= 1'b0;
			seq_start <= 1'b0;
			done_r <= 1'b0;
			err_r <= 1'b0;
			err_code_r <= 8'h00;
			cycles_r <= 32'd0;
		end
		else begin
			eng_start_cpu <= 1'b0;
			seq_start <= 1'b0;
			if (ctl_we)
				case (ctl_addr)
					rv32_pkg_MMIO_NN_CTRL: begin
						r_irq_en <= ctl_wdata[1];
						if (ctl_wdata[0]) begin
							if (!busy_o) begin
								auto_r <= ctl_wdata[1];
								if (ctl_wdata[1]) begin
									seq_start <= 1'b1;
									done_r <= 1'b0;
									err_r <= 1'b0;
								end
								else if (desc_ok) begin
									eng_start_cpu <= 1'b1;
									desc_r <= desc_next;
									done_r <= 1'b0;
									cycles_r <= 32'd0;
									err_r <= 1'b0;
									err_code_r <= 8'h00;
								end
								else begin
									err_r <= 1'b1;
									err_code_r <= 8'he1;
								end
							end
						end
					end
					rv32_pkg_MMIO_NN_OP: r_op <= ctl_wdata;
					rv32_pkg_MMIO_NN_SRC: r_src <= ctl_wdata;
					rv32_pkg_MMIO_NN_DST: r_dst <= ctl_wdata;
					rv32_pkg_MMIO_NN_WOFF: r_woff <= ctl_wdata;
					rv32_pkg_MMIO_NN_QOFF: r_qoff <= ctl_wdata;
					rv32_pkg_MMIO_NN_IH: r_ih <= ctl_wdata;
					rv32_pkg_MMIO_NN_IW: r_iw <= ctl_wdata;
					rv32_pkg_MMIO_NN_IC: r_ic <= ctl_wdata;
					rv32_pkg_MMIO_NN_OC: r_oc <= ctl_wdata;
					rv32_pkg_MMIO_NN_KS: r_ks <= ctl_wdata;
					rv32_pkg_MMIO_NN_ST: r_st <= ctl_wdata;
					rv32_pkg_MMIO_NN_PAD: r_pad <= ctl_wdata;
					rv32_pkg_MMIO_NN_FLAGS: r_flags <= ctl_wdata;
					default:
						;
				endcase
			if (ctl_re && (ctl_addr == rv32_pkg_MMIO_NN_STATUS)) begin
				done_r <= 1'b0;
				err_r <= 1'b0;
			end
			if (busy_o && cpu_we) begin
				err_r <= 1'b1;
				err_code_r <= 8'he2;
			end
			if (!auto_r && !j_pending) begin
				if (eng_done) begin
					done_r <= 1'b1;
					cycles_r <= eng_cycles;
				end
				if (eng_err != 8'h00) begin
					err_r <= 1'b1;
					err_code_r <= eng_err;
				end
			end
			else begin
				if (seq_done)
					done_r <= 1'b1;
				if (seq_err) begin
					err_r <= 1'b1;
					err_code_r <= seq_err_code;
				end
			end
		end
	localparam [31:0] rv32_pkg_MMIO_NN_CYCLES = 32'ha0000108;
	localparam [31:0] rv32_pkg_MMIO_NN_DBG0 = 32'ha0000140;
	localparam [31:0] rv32_pkg_MMIO_NN_DBG1 = 32'ha0000144;
	localparam [31:0] rv32_pkg_MMIO_NN_DBG2 = 32'ha0000148;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_CYCLES = 32'ha000015c;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_DONE_CNT = 32'ha0000180;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_DROP_CNT = 32'ha0000184;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_ERR_CODE = 32'ha0000178;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_FRAME_NO = 32'ha0000158;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_ID = 32'ha0000150;
	localparam [31:0] rv32_pkg_MMIO_NN_JOB_STATUS = 32'ha0000154;
	always @(*) begin
		if (_sv2v_0)
			;
		ctl_rdata = 32'h00000000;
		case (ctl_addr)
			rv32_pkg_MMIO_NN_CTRL: ctl_rdata = {29'h00000000, auto_r, r_irq_en, 1'b0};
			rv32_pkg_MMIO_NN_STATUS: ctl_rdata = {28'h0000000, r_irq_en & done_o, err_o, done_o, busy_o};
			rv32_pkg_MMIO_NN_CYCLES: ctl_rdata = cycles_o;
			rv32_pkg_MMIO_NN_OP: ctl_rdata = r_op;
			rv32_pkg_MMIO_NN_SRC: ctl_rdata = r_src;
			rv32_pkg_MMIO_NN_DST: ctl_rdata = r_dst;
			rv32_pkg_MMIO_NN_WOFF: ctl_rdata = r_woff;
			rv32_pkg_MMIO_NN_QOFF: ctl_rdata = r_qoff;
			rv32_pkg_MMIO_NN_IH: ctl_rdata = r_ih;
			rv32_pkg_MMIO_NN_IW: ctl_rdata = r_iw;
			rv32_pkg_MMIO_NN_IC: ctl_rdata = r_ic;
			rv32_pkg_MMIO_NN_OC: ctl_rdata = r_oc;
			rv32_pkg_MMIO_NN_KS: ctl_rdata = r_ks;
			rv32_pkg_MMIO_NN_ST: ctl_rdata = r_st;
			rv32_pkg_MMIO_NN_PAD: ctl_rdata = r_pad;
			rv32_pkg_MMIO_NN_FLAGS: ctl_rdata = r_flags;
			rv32_pkg_MMIO_NN_DBG0: ctl_rdata = {24'h000000, eng_err};
			rv32_pkg_MMIO_NN_DBG1: ctl_rdata = {16'h0000, desc_r[159-:16], desc_r[143-:16]};
			rv32_pkg_MMIO_NN_DBG2: ctl_rdata = {16'h0000, err_code_o};
			rv32_pkg_MMIO_NN_JOB_ID: ctl_rdata = 32'h4e503101;
			rv32_pkg_MMIO_NN_JOB_STATUS: ctl_rdata = {8'd0, seq_done_ops, (j_done | j_err ? j_err_code : 8'h00), j_done, j_timeout, 2'b01, j_pending, j_err, j_done, busy_o};
			rv32_pkg_MMIO_NN_JOB_FRAME_NO: ctl_rdata = j_frame_no;
			rv32_pkg_MMIO_NN_JOB_CYCLES: ctl_rdata = j_cycles;
			rv32_pkg_MMIO_NN_JOB_IN_ADDR: ctl_rdata = j_in_r;
			rv32_pkg_MMIO_NN_JOB_OUT_ADDR: ctl_rdata = j_out_r;
			rv32_pkg_MMIO_NN_JOB_MODEL: ctl_rdata = j_model_r;
			rv32_pkg_MMIO_NN_JOB_FRAME: ctl_rdata = j_frame_r;
			rv32_pkg_MMIO_NN_JOB_DOORBELL: ctl_rdata = {31'd0, j_pending};
			rv32_pkg_MMIO_NN_JOB_ERR_CODE: ctl_rdata = {24'd0, j_err_code};
			rv32_pkg_MMIO_NN_JOB_LEN: ctl_rdata = j_len_r;
			rv32_pkg_MMIO_NN_JOB_DONE_CNT: ctl_rdata = j_jobs_done;
			rv32_pkg_MMIO_NN_JOB_DROP_CNT: ctl_rdata = j_drop_cnt;
			default: ctl_rdata = 32'h00000000;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule