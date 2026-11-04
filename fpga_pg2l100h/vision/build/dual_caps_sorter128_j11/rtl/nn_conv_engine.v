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
	b_wstrb,
	raw_valid,
	raw_x,
	raw_y,
	raw_channel,
	raw_data
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
	output wire raw_valid;
	output wire [15:0] raw_x;
	output wire [15:0] raw_y;
	output wire [15:0] raw_channel;
	output wire [OC_LANES * 32 - 1:0] raw_data;
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
	assign raw_valid = is_conv && state == 5'd13 && c_p >= 16'd5 && c_p <= 16'd12;
	assign raw_x = (c_oxg << 3) + c_p - 16'd5;
	assign raw_y = c_oy;
	assign raw_channel = oc_base_w;
	genvar raw_lane;
	generate for (raw_lane = 0; raw_lane < OC_LANES; raw_lane = raw_lane + 1) begin: raw_lanes
		assign raw_data[raw_lane * 32 +: 32] = y2_q[raw_lane][31:0];
	end endgenerate
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
