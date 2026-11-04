`timescale 1ns/1ps

// ============================================================================
// tb_nn_seq.sv — nn_seq 单元测试（legacy + M6c band）
// ----------------------------------------------------------------------------
// DUT1 "dut"   : 真实 YOLO nn_rom_pkg::NN_ROM（tile=0）→ 旧行为逐位不变
// DUT2 "dut_b" : 合成 band ROM（reset 后由 TB 层级写 dut_b.rom_mem[i] 注入）→
//                M6c band 循环/预取控制单测（stub nn_wload/nn_tilecache/engine）
// 判据:
//   legacy: 恰好 NN_ROM_LEN 次 start; cycles==假引擎 cycles 之和; desc op 映射;
//           busy/done 语义; err 注入路径 —— 与旧 TB 完全一致（断言在 err 注入前）
//   band  : 每 op 的 n_bands 与 per-band in_rows/pad_top/rd_rows/in_base/out_base/
//           row_bytes/out_rows/zp_in/add_mode 与附录 A 公式逐 band 一致;
//           engine desc pad=0/iw=iw+2pad/ih=in_rows/src=dst=0; pre_start 次数/地址/
//           长度/bank 交替; Σn_bands 次引擎 start; 周期累加; done/done_ops;
//           wlen>128KiB -> err E6; pre_err -> err E6
// 运行: python tools/fpga_workflow.py verify --only tb_nn_seq --force
// 输出: "NN_SEQ_TB: PASS (legacy starts=... cycles=... | band ops=... bands=...)" / FAIL
// ============================================================================
module tb_nn_seq;

  import nn_pkg::*;
  import nn_rom_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;             // 10 ns period (timescale 1ns)

  int errors;

  // ==========================================================================
  // DUT1: legacy 路径（真实 YOLO ROM; band 输入 tie-off, 输出悬空）
  // ==========================================================================
  logic              start;
  logic              busy, done, err;
  logic [31:0]       cycles;
  logic [7:0]        err_code;
  logic [7:0]        e1_done_ops;
  logic              e1_job_timeout;
  nn_desc_t          eng_desc;
  logic              eng_start;
  logic              eng_busy, eng_done;
  logic [31:0]       eng_cycles;
  logic [7:0]        eng_err_code;

  nn_seq dut (
    .clk(clk), .rst(rst),
    .start(start), .busy(busy), .done(done), .cycles(cycles),
    .err(err), .err_code(err_code), .done_ops(e1_done_ops), .job_timeout(e1_job_timeout),
    .eng_desc(eng_desc), .eng_start(eng_start),
    .eng_busy(eng_busy), .eng_done(eng_done),
    .eng_cycles(eng_cycles), .eng_err_code(eng_err_code),
    // band 端口: 本 DUT 只跑 legacy（YOLO ROM tile=0）, 输入常量 tie-off
    .pre_busy(1'b0), .pre_done(1'b1), .pre_err(1'b0),
    .band_ready(1'b1), .band_done(1'b1), .tile_err(8'd0),
    .w_ddr_base(32'd0), .q_ddr_base(32'd0), .arena_ddr_base(32'd0),
    // 输出显式空连接（本 DUT 只跑 legacy, 消除 vopt-2718 警告）
    .pre_start(), .pre_src_addr(), .pre_wlen(), .pre_qsrc_addr(), .pre_qlen(),
    .pre_bank(), .w_bank_sel(), .q_bank_sel(),
    .d_in_base(), .d_in_rows(), .d_in_row_bytes(), .d_in_stride(),
    .d_in_pad_top(), .d_in_rd_rows(), .d_zp_in(), .d_add_mode(),
    .d_aux_base(), .d_aux_stride(), .d_aux_pad_top(), .d_aux_rd_rows(),
    .d_out_base(), .d_out_rows(), .d_out_row_bytes(), .d_out_stride(),
    .band_start(), .band_idx(), .band_n(), .band_active()
  );

  int          n_start;
  logic [31:0] sum_cycles;
  int          legacy_starts;
  logic [31:0] legacy_cycles;
  nn_desc_t    op_desc [0:255];

  // stub legacy engine
  logic [31:0] stub_cnt, stub_cycles;
  always @(posedge clk) begin
    if (rst) begin
      stub_cnt <= 32'd0; stub_cycles <= 32'd0;
      n_start <= 0; sum_cycles <= 32'd0;
      eng_busy <= 1'b0; eng_done <= 1'b0; eng_cycles <= 32'd0; eng_err_code <= 8'd0;
    end else begin
      eng_done <= 1'b0;
      if (eng_start) begin
        if (n_start < 256) op_desc[n_start] = eng_desc;
        n_start     <= n_start + 1;
        stub_cycles <= 32'd3 + {26'd0, (eng_desc.src[3:0] ^ eng_desc.dst[3:0])};
        stub_cnt    <= 32'd3 + {26'd0, (eng_desc.src[3:0] ^ eng_desc.dst[3:0])};
        eng_busy    <= 1'b1;
      end else if (eng_busy) begin
        if (stub_cnt > 32'd0) begin
          stub_cnt <= stub_cnt - 32'd1;
        end else begin
          eng_busy   <= 1'b0;
          eng_done   <= 1'b1;
          eng_cycles <= stub_cycles;
          sum_cycles <= sum_cycles + stub_cycles;
        end
      end
    end
  end

  task automatic run_once;
    begin
      @(negedge clk); start = 1'b1;
      @(negedge clk); start = 1'b0;
      begin : wait_done
        int guard;
        guard = 0;
        while (done !== 1'b1) begin
          @(posedge clk); #1;
          if (guard > 20000) begin
            $display("NN_SEQ_TB: FAIL legacy timeout waiting done (starts=%0d)", n_start);
            errors++;
            disable wait_done;
          end
          guard++;
        end
      end
    end
  endtask

  task automatic legacy_tests;
    begin
      run_once();
      // ---- 严格断言（在 err 注入之前）----
      if (done !== 1'b1) begin
        $display("NN_SEQ_TB: FAIL legacy done not high"); errors++;
      end
      if (n_start !== NN_ROM_LEN) begin
        $display("NN_SEQ_TB: FAIL legacy start count %0d != ROM_LEN %0d", n_start, NN_ROM_LEN);
        errors++;
      end
      if (cycles !== sum_cycles) begin
        $display("NN_SEQ_TB: FAIL legacy cycles %0d != sum %0d", cycles, sum_cycles); errors++;
      end
      if (err !== 1'b0) begin
        $display("NN_SEQ_TB: FAIL legacy unexpected err"); errors++;
      end
      if (e1_done_ops !== 8'(NN_ROM_LEN)) begin
        $display("NN_SEQ_TB: FAIL legacy done_ops %0d", e1_done_ops); errors++;
      end
      for (int i = 0; i < n_start && i < 256; i++) begin
        automatic nn_rom_t r = NN_ROM[i];
        automatic nn_desc_t d;
        d = op_desc[i];
        unique case (r.kind)
          NN_ROM_KIND_CONV: if (d.op != NN_OP_CONV) errors++;
          NN_ROM_KIND_DW:   if (d.op != NN_OP_CONV) errors++;
          NN_ROM_KIND_POOL: if (d.op != NN_OP_POOL) errors++;
          NN_ROM_KIND_UP2X: if (d.op != NN_OP_COPY) errors++;
          NN_ROM_KIND_ADD:  if (d.op != NN_OP_ADD)  errors++;
          NN_ROM_KIND_COPY: if (d.op != NN_OP_COPY) errors++;
          default: errors++;
        endcase
        if (d.src !== 32'(r.src) || d.dst !== 32'(r.dst)) errors++;
      end
      legacy_starts = n_start;
      legacy_cycles = cycles;
      $display("[legacy] PASS starts=%0d cycles=%0d done_ops=%0d rom_len=%0d",
               legacy_starts, legacy_cycles, e1_done_ops, NN_ROM_LEN);

      // ---- 第 2 轮: 引擎报错注入（不影响上面的结论; 打印不再使用这里的计数）----
      if (NN_ROM_LEN > 0) begin
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        wait (eng_busy === 1'b1);
        repeat (3) @(posedge clk);
        #1 eng_err_code = 8'h7A;
        begin : wait_err
          int g2;
          g2 = 0;
          while (dut.err !== 1'b1) begin
            @(posedge clk); #1;
            if (g2 > 20000) begin
              $display("NN_SEQ_TB: FAIL legacy err path not triggered"); errors++;
              disable wait_err;
            end
            g2++;
          end
        end
        #1 eng_err_code = 8'd0;
        repeat (5) @(posedge clk);
        $display("[legacy] err-inject PASS");
      end
    end
  endtask

  // ==========================================================================
  // DUT2: M6c band 路径
  // ==========================================================================
  logic              b_start, b_busy, b_done, b_err;
  logic [31:0]       b_cycles;
  logic [7:0]        b_err_code;
  logic [7:0]        b_done_ops;
  logic              b_job_timeout;
  nn_desc_t          b_eng_desc;
  logic              b_eng_start, b_eng_busy, b_eng_done;
  logic [31:0]       b_eng_cycles;
  logic              b_pre_busy, b_pre_done, b_pre_err;
  logic              b_band_ready, b_band_done;
  logic              b_pre_start;
  logic [31:0]       b_pre_src_addr, b_pre_qsrc_addr;
  logic [17:0]       b_pre_wlen;
  logic [12:0]       b_pre_qlen;
  logic              b_pre_bank;
  logic              b_w_bank_sel, b_q_bank_sel;
  logic [31:0]       b_d_in_base, b_d_aux_base, b_d_out_base;
  logic [15:0]       b_d_in_rows, b_d_in_row_bytes, b_d_in_stride;
  logic [15:0]       b_d_in_pad_top, b_d_in_rd_rows;
  logic [15:0]       b_d_aux_stride, b_d_aux_pad_top, b_d_aux_rd_rows;
  logic [15:0]       b_d_out_rows, b_d_out_row_bytes, b_d_out_stride;
  logic [7:0]        b_d_zp_in;
  logic              b_d_add_mode;
  logic              b_band_start;
  logic [15:0]       b_band_idx, b_band_n;
  logic              b_band_active;
  logic [31:0]       b_w_ddr_base, b_q_ddr_base, b_arena_base;

  logic [7:0]        b_eng_err_zero;
  assign b_eng_err_zero = 8'd0;

  nn_seq dut_b (
    .clk(clk), .rst(rst),
    .start(b_start), .busy(b_busy), .done(b_done), .cycles(b_cycles),
    .err(b_err), .err_code(b_err_code), .done_ops(b_done_ops), .job_timeout(b_job_timeout),
    .eng_desc(b_eng_desc), .eng_start(b_eng_start),
    .eng_busy(b_eng_busy), .eng_done(b_eng_done),
    .eng_cycles(b_eng_cycles), .eng_err_code(b_eng_err_zero),
    .pre_busy(b_pre_busy), .pre_done(b_pre_done), .pre_err(b_pre_err),
    .band_ready(b_band_ready), .band_done(b_band_done), .tile_err(8'd0),
    .w_ddr_base(b_w_ddr_base), .q_ddr_base(b_q_ddr_base), .arena_ddr_base(b_arena_base),
    .pre_start(b_pre_start), .pre_src_addr(b_pre_src_addr), .pre_wlen(b_pre_wlen),
    .pre_qsrc_addr(b_pre_qsrc_addr), .pre_qlen(b_pre_qlen), .pre_bank(b_pre_bank),
    .w_bank_sel(b_w_bank_sel), .q_bank_sel(b_q_bank_sel),
    .d_in_base(b_d_in_base), .d_in_rows(b_d_in_rows),
    .d_in_row_bytes(b_d_in_row_bytes), .d_in_stride(b_d_in_stride),
    .d_in_pad_top(b_d_in_pad_top), .d_in_rd_rows(b_d_in_rd_rows),
    .d_zp_in(b_d_zp_in), .d_add_mode(b_d_add_mode),
    .d_aux_base(b_d_aux_base), .d_aux_stride(b_d_aux_stride),
    .d_aux_pad_top(b_d_aux_pad_top), .d_aux_rd_rows(b_d_aux_rd_rows),
    .d_out_base(b_d_out_base), .d_out_rows(b_d_out_rows),
    .d_out_row_bytes(b_d_out_row_bytes), .d_out_stride(b_d_out_stride),
    .band_start(b_band_start), .band_idx(b_band_idx), .band_n(b_band_n),
    .band_active(b_band_active)
  );

  localparam int BAND_CASE_N = 8;
  localparam int PRE_LAT     = 5;
  localparam int FILL_LAT    = 3;
  localparam int ENG_LAT     = 4;
  localparam int FLUSH_LAT   = 3;
  localparam logic [31:0] W_BASE   = 32'h0140_0000;
  localparam logic [31:0] Q_BASE   = 32'h0140_0000 + 32'd2_020_960;
  localparam logic [31:0] ARENA    = 32'h0100_0000;
  localparam int MAX_BANDS = 8192;
  bit b_done_seen = 1'b0;
  always @(posedge clk) if (b_done) b_done_seen <= 1'b1;

  typedef struct packed {
    logic [3:0]  kind;
    logic [7:0]  flags;
    logic [3:0]  k;
    logic [2:0]  pad;
    logic [1:0]  stride;
    logic [9:0]  ic;
    logic [9:0]  oc;
    logic [8:0]  ih;
    logic [8:0]  iw;
    logic [21:0] src;
    logic [21:0] dst;
    logic [17:0] wlen;
    logic [12:0] qlen;
    logic [7:0]  tile;
    logic [15:0] aux0;
    logic [15:0] aux1;
    logic [31:0] csum;
  } syn_op_t;

  function automatic syn_op_t syn_op(input int cid);
    syn_op_t o;
    o = '0;
    o.wlen = 18'd512; o.qlen = 13'd400; o.aux0 = 16'hFF80;   // zp_in = -128
    case (cid)
      0: begin  // conv k3 s2 p1, B=6
        o.kind=NN_ROM_KIND_CONV; o.flags=8'hA0; o.k=4'd3; o.pad=3'd1; o.stride=2'd2;
        o.ic=10'd8; o.oc=10'd16; o.ih=9'd224; o.iw=9'd224;
        o.src=22'd0; o.dst=22'd150528; o.tile=8'h52; o.wlen=18'd1152; o.qlen=13'd112;
      end
      1: begin  // conv k1 s1 p0, B=2
        o.kind=NN_ROM_KIND_CONV; o.flags=8'h80; o.k=4'd1; o.pad=3'd0; o.stride=2'd1;
        o.ic=10'd16; o.oc=10'd64; o.ih=9'd112; o.iw=9'd112;
        o.src=22'd150528; o.dst=22'd351232; o.tile=8'h12; o.wlen=18'd1024; o.qlen=13'd400;
      end
      2: begin  // dwconv k3 s1 p1, B=1（tile[0]=tile_en）
        o.kind=NN_ROM_KIND_DW; o.flags=8'h80; o.k=4'd3; o.pad=3'd1; o.stride=2'd1;
        o.ic=10'd64; o.oc=10'd64; o.ih=9'd112; o.iw=9'd112;
        o.src=22'd351232; o.dst=22'd0; o.tile=8'h02; o.wlen=18'd576; o.qlen=13'd400;
      end
      3: begin  // ADD_R+RELU, B=4
        o.kind=NN_ROM_KIND_ADD; o.flags=8'hC0; o.k=4'd0; o.pad=3'd0; o.stride=2'd1;
        o.ic=10'd16; o.oc=10'd16; o.ih=9'd112; o.iw=9'd112;
        o.src=22'd150528; o.dst=22'd351232; o.tile=8'h3A; o.wlen=18'd0; o.qlen=13'd16;
        o.aux0=16'h0000; o.aux1=16'd15;
      end
      4: begin  // upsample 2x, tile B=3 -> RTL 强制 B=2
        o.kind=NN_ROM_KIND_UP2X; o.flags=8'h00; o.k=4'd2; o.pad=3'd0; o.stride=2'd2;
        o.ic=10'd72; o.oc=10'd72; o.ih=9'd14; o.iw=9'd14;
        o.src=22'd0; o.dst=22'd150528; o.tile=8'h22; o.wlen=18'd0; o.qlen=13'd0;
      end
      5: begin  // copy 通道偏移, B=1
        o.kind=NN_ROM_KIND_COPY; o.flags=8'h00; o.k=4'd0; o.pad=3'd0; o.stride=2'd1;
        o.ic=10'd72; o.oc=10'd216; o.ih=9'd56; o.iw=9'd56;
        o.src=22'd0; o.dst=22'd150528; o.tile=8'h02; o.wlen=18'd0; o.qlen=13'd0;
        o.aux0=16'd72; o.aux1=16'd144;
      end
      6: begin  // conv k3 s1 p1, B=4
        o.kind=NN_ROM_KIND_CONV; o.flags=8'h80; o.k=4'd3; o.pad=3'd1; o.stride=2'd1;
        o.ic=10'd8; o.oc=10'd8; o.ih=9'd56; o.iw=9'd56;
        o.src=22'd150528; o.dst=22'd0; o.tile=8'h32; o.wlen=18'd576; o.qlen=13'd64;
      end
      default: begin  // dwconv k3 s2 p1, B=8
        o.kind=NN_ROM_KIND_DW; o.flags=8'h80; o.k=4'd3; o.pad=3'd1; o.stride=2'd2;
        o.ic=10'd144; o.oc=10'd144; o.ih=9'd56; o.iw=9'd56;
        o.src=22'd351232; o.dst=22'd150528; o.tile=8'h72; o.wlen=18'd1296; o.qlen=13'd400;
      end
    endcase
    return o;
  endfunction

  function automatic nn_rom_t pack_rom(input syn_op_t s);
    nn_rom_t r;
    r = '0;
    r.kind   = s.kind;
    r.flags  = s.flags;
    r.ks     = s.k;
    r.pad    = s.pad;
    r.stride = s.stride;
    r.ic     = s.ic;
    r.oc     = s.oc;
    r.ih     = s.ih;
    r.iw     = s.iw;
    r.src    = s.src;
    r.dst    = s.dst;
    r.wlen   = s.wlen;
    r.qlen   = s.qlen;
    r.tile   = s.tile;
    r.aux0   = s.aux0;
    r.aux1   = s.aux1;
    r.csum   = s.csum;
    return r;
  endfunction

  // ---- stub nn_wload（pre_*）----
  logic        st_pre_busy, st_pre_done, st_pre_err;
  int          st_pre_cnt, n_pre;
  logic [31:0] pre_addr_cap  [0:255];
  logic [17:0] pre_wlen_cap  [0:255];
  logic [31:0] pre_qaddr_cap [0:255];
  logic [12:0] pre_qlen_cap  [0:255];
  logic        pre_bank_cap  [0:255];
  logic        inj_pre_err;

  always @(posedge clk) begin
    if (rst) begin
      st_pre_busy <= 1'b0; st_pre_done <= 1'b0; st_pre_err <= 1'b0;
      st_pre_cnt <= 0; n_pre <= 0;
    end else begin
      st_pre_done <= 1'b0;
      if (b_pre_start) begin
        if (n_pre < 256) begin
          pre_addr_cap[n_pre]  <= b_pre_src_addr;
          pre_wlen_cap[n_pre]  <= b_pre_wlen;
          pre_qaddr_cap[n_pre] <= b_pre_qsrc_addr;
          pre_qlen_cap[n_pre]  <= b_pre_qlen;
          pre_bank_cap[n_pre]  <= b_pre_bank;
        end
        n_pre       <= n_pre + 1;
        st_pre_busy <= 1'b1;
        st_pre_cnt  <= PRE_LAT;
        st_pre_err  <= 1'b0;
      end else if (st_pre_busy) begin
        if (st_pre_cnt > 0) begin
          st_pre_cnt <= st_pre_cnt - 1;
        end else begin
          st_pre_busy <= 1'b0;
          st_pre_done <= 1'b1;
          if (inj_pre_err) begin
            st_pre_err  <= 1'b1;
            inj_pre_err <= 1'b0;
          end
        end
      end
    end
  end
  assign b_pre_done = st_pre_done;
  assign b_pre_err  = st_pre_err;
  assign b_pre_busy = st_pre_busy;

  // ---- stub nn_tilecache（band_*）----
  logic        st_band_ready, st_band_done;
  int          st_fill_cnt, st_flush_cnt;
  logic        st_engine_seen;
  int          n_band;
  int          band_idx_cap  [0:MAX_BANDS-1];
  logic [31:0] cap_in_base   [0:MAX_BANDS-1];
  logic [15:0] cap_in_rows   [0:MAX_BANDS-1];
  logic [15:0] cap_in_rowb   [0:MAX_BANDS-1];
  logic [15:0] cap_in_stride [0:MAX_BANDS-1];
  logic [15:0] cap_in_padtop [0:MAX_BANDS-1];
  logic [15:0] cap_in_rdrows [0:MAX_BANDS-1];
  logic [7:0]  cap_zp_in     [0:MAX_BANDS-1];
  logic        cap_add_mode  [0:MAX_BANDS-1];
  logic [31:0] cap_aux_base  [0:MAX_BANDS-1];
  logic [15:0] cap_aux_rdrow [0:MAX_BANDS-1];
  logic [31:0] cap_out_base  [0:MAX_BANDS-1];
  logic [15:0] cap_out_rows  [0:MAX_BANDS-1];
  logic [15:0] cap_out_rowb  [0:MAX_BANDS-1];

  always @(posedge clk) begin
    if (rst) begin
      st_band_ready <= 1'b0; st_band_done <= 1'b0;
      st_fill_cnt <= 0; st_flush_cnt <= 0; st_engine_seen <= 1'b0; n_band <= 0;
    end else begin
      st_band_done <= 1'b0;
      if (b_band_start) begin
        if (n_band < MAX_BANDS) begin
          cap_in_base[n_band]   <= b_d_in_base;
          cap_in_rows[n_band]   <= b_d_in_rows;
          cap_in_rowb[n_band]   <= b_d_in_row_bytes;
          cap_in_stride[n_band] <= b_d_in_stride;
          cap_in_padtop[n_band] <= b_d_in_pad_top;
          cap_in_rdrows[n_band] <= b_d_in_rd_rows;
          cap_zp_in[n_band]     <= b_d_zp_in;
          cap_add_mode[n_band]  <= b_d_add_mode;
          cap_aux_base[n_band]  <= b_d_aux_base;
          cap_aux_rdrow[n_band] <= b_d_aux_rd_rows;
          cap_out_base[n_band]  <= b_d_out_base;
          cap_out_rows[n_band]  <= b_d_out_rows;
          cap_out_rowb[n_band]  <= b_d_out_row_bytes;
          band_idx_cap[n_band]  <= int'(b_band_idx);
        end
        n_band         <= n_band + 1;
        st_fill_cnt    <= FILL_LAT;
        st_band_ready  <= 1'b0;
        st_engine_seen <= 1'b0;
      end else if (st_fill_cnt > 0) begin
        st_fill_cnt <= st_fill_cnt - 1;
        if (st_fill_cnt == 1) st_band_ready <= 1'b1;
      end
      if (b_eng_done) st_engine_seen <= 1'b1;
      if (st_engine_seen && (st_flush_cnt == 0)) st_flush_cnt <= FLUSH_LAT;
      if (st_flush_cnt > 0) begin
        st_flush_cnt <= st_flush_cnt - 1;
        if (st_flush_cnt == 1) begin
          st_band_done   <= 1'b1;
          st_band_ready  <= 1'b0;
          st_engine_seen <= 1'b0;
        end
      end
    end
  end
  assign b_band_ready = st_band_ready;
  assign b_band_done  = st_band_done;

  // ---- stub engine（band）----
  int          b_n_eng, b_eng_cnt;
  logic [31:0] b_eng_sum;
  nn_desc_t    b_eng_cap [0:MAX_BANDS-1];

  always @(posedge clk) begin
    if (rst) begin
      b_eng_busy <= 1'b0; b_eng_done <= 1'b0; b_eng_cycles <= 32'd0;
      b_eng_cnt <= 0; b_n_eng <= 0; b_eng_sum <= 32'd0;
    end else begin
      b_eng_done <= 1'b0;
      if (b_eng_start) begin
        if (b_n_eng < MAX_BANDS) b_eng_cap[b_n_eng] = b_eng_desc;
        b_n_eng      <= b_n_eng + 1;
        b_eng_busy   <= 1'b1;
        b_eng_cnt    <= ENG_LAT;
        b_eng_cycles <= 32'd17;
        b_eng_sum    <= b_eng_sum + 32'd17;
      end else if (b_eng_busy) begin
        if (b_eng_cnt > 0) b_eng_cnt <= b_eng_cnt - 1;
        else begin
          b_eng_busy <= 1'b0;
          b_eng_done <= 1'b1;
        end
      end
    end
  end

  task automatic inject_band_rom;
    begin
      for (int i = 0; i < NN_ROM_LEN; i++)
        dut_b.rom_mem[i] = pack_rom(syn_op(i % BAND_CASE_N));
    end
  endtask

  task automatic inject_bad_wlen_rom;
    begin
      for (int i = 0; i < NN_ROM_LEN; i++)
        dut_b.rom_mem[i] = pack_rom(syn_op(i % BAND_CASE_N));
      dut_b.rom_mem[0] = pack_rom(syn_op(0));
      begin
        syn_op_t bad;
        nn_rom_t rb;
        bad = syn_op(0);
        bad.wlen = 18'd131_073;
        rb = pack_rom(bad);
        dut_b.rom_mem[0] = rb;
      end
    end
  endtask

  // 参考几何（独立实现, 与附录 A 公式逐项对照）
  task automatic ref_band_geom(input syn_op_t s, input int b,
                               output int n_bands, output int br_use,
                               output int in_rows, output int in_row_bytes,
                               output int in_stride, output int in_pad_top,
                               output int in_rd_rows, output logic [31:0] in_base,
                               output logic [31:0] out_base, output int out_rows,
                               output int out_row_bytes, output logic [7:0] zp_in,
                               output logic add_mode);
    int k, st, pad, ic8, oc8, ih, iw, oh, ow, br_cur, band_row0, abs0, abs1, rd1;
    ic8 = ((s.ic + 7) / 8) * 8;
    oc8 = ((s.oc + 7) / 8) * 8;
    ih  = int'(s.ih);
    iw  = int'(s.iw);
    if ((s.kind == NN_ROM_KIND_ADD) || (s.kind == NN_ROM_KIND_COPY)) begin
      k = 1; st = 1; pad = 0;
    end else if ((s.kind == NN_ROM_KIND_POOL) && (s.pad == 0)) begin
      k = int'(s.k); st = (s.stride == 0) ? 1 : int'(s.stride); pad = (k - 1) / 2;
    end else begin
      k = (s.k == 0) ? 1 : int'(s.k);
      st = (s.stride == 0) ? 1 : int'(s.stride);
      pad = int'(s.pad);
    end
    br_use = int'(s.tile[7:4]) + 1;
    if (s.kind == NN_ROM_KIND_UP2X) begin
      oh = ih * 2; ow = iw * 2;
      if ((br_use % 2) == 1) br_use = br_use - 1;
      if (br_use == 0) br_use = 2;
    end else begin
      oh = (ih + 2 * pad - k) / st + 1;
      ow = (iw + 2 * pad - k) / st + 1;
    end
    n_bands = (oh + br_use - 1) / br_use;
    out_rows = (oh - b * br_use > br_use) ? br_use : (oh - b * br_use);
    br_cur = out_rows;
    out_row_bytes = ow * oc8;
    out_base = ARENA + s.dst + b * br_use * out_row_bytes;
    if (s.kind == NN_ROM_KIND_UP2X) begin
      in_rows       = (br_cur / 2) + 1;
      in_row_bytes  = iw * ic8;
      in_stride     = iw * ic8;
      in_pad_top    = 0;
      in_rd_rows    = (b * br_use / 2 + in_rows > ih) ? (ih - b * br_use / 2) : in_rows;
      in_base       = ARENA + s.src + (b * br_use / 2) * in_stride;
    end else begin
      in_rows = (br_cur - 1) * st + k;
      if (s.tile[2] || s.flags[NN_F_PACKED3]) begin
        in_row_bytes = iw * 3;
        in_stride    = iw * 3;
      end else begin
        in_row_bytes = (iw + 2 * pad) * ic8;
        in_stride    = iw * ic8;
      end
      band_row0 = b * br_use * st - pad;
      abs0      = (band_row0 < 0) ? 0 : band_row0;
      abs1      = band_row0 + in_rows;
      rd1       = (abs1 > ih) ? ih : abs1;
      in_pad_top  = abs0 - band_row0;
      in_rd_rows  = rd1 - abs0;
      in_base     = ARENA + s.src + abs0 * in_stride;
    end
    if ((s.kind == NN_ROM_KIND_ADD) || (s.kind == NN_ROM_KIND_COPY) ||
        s.tile[2] || s.flags[NN_F_PACKED3])
      zp_in = 8'd0;
    else
      zp_in = s.aux0[7:0];
    add_mode = (s.kind == NN_ROM_KIND_ADD);
  endtask

  int band_ops_seen, band_bands_seen, band_pre_seen, band_eng_seen;
  int exp_ops;
  int exp_bands;
  int exp_pre;
  int exp_eng;
  int band_cursor;

  task automatic check_band_run;
    int n_bands, br_use, in_rows, in_row_bytes, in_stride, in_pad_top, in_rd_rows;
    int out_rows, out_row_bytes;
    logic [31:0] in_base, out_base;
    logic [7:0] zp_in;
    logic add_mode;
    logic [31:0] wptr_e, qptr_e;
    begin
      band_cursor = 0;
      exp_bands   = 0;
      wptr_e      = 32'd0;
      qptr_e      = 32'd0;
      for (int i = 0; i < NN_ROM_LEN; i++) begin
        automatic syn_op_t s = syn_op(i % BAND_CASE_N);
        ref_band_geom(s, 0, n_bands, br_use, in_rows, in_row_bytes, in_stride,
                      in_pad_top, in_rd_rows, in_base, out_base, out_rows,
                      out_row_bytes, zp_in, add_mode);
        exp_bands += n_bands;
        for (int bb = 0; bb < n_bands; bb++) begin
          ref_band_geom(s, bb, n_bands, br_use, in_rows, in_row_bytes, in_stride,
                        in_pad_top, in_rd_rows, in_base, out_base, out_rows,
                        out_row_bytes, zp_in, add_mode);
          if (band_cursor >= n_band) begin
            $display("NN_SEQ_TB: FAIL band count short (op %0d b %0d)", i, bb);
            errors++;
            break;
          end
          if (band_idx_cap[band_cursor] !== bb) begin
            $display("NN_SEQ_TB: FAIL op %0d b %0d idx %0d", i, bb, band_idx_cap[band_cursor]);
            errors++;
          end
          if (cap_in_rows[band_cursor]   !== 16'(in_rows))       begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d in_rows %0d != %0d", i, bb, cap_in_rows[band_cursor], in_rows); errors++;
          end
          if (cap_in_rowb[band_cursor]   !== 16'(in_row_bytes))  begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d rowb %0d != %0d", i, bb, cap_in_rowb[band_cursor], in_row_bytes); errors++;
          end
          if (cap_in_stride[band_cursor] !== 16'(in_stride))     begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d stride %0d != %0d", i, bb, cap_in_stride[band_cursor], in_stride); errors++;
          end
          if (cap_in_padtop[band_cursor] !== 16'(in_pad_top))    begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d pad_top %0d != %0d", i, bb, cap_in_padtop[band_cursor], in_pad_top); errors++;
          end
          if (cap_in_rdrows[band_cursor] !== 16'(in_rd_rows))    begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d rd_rows %0d != %0d", i, bb, cap_in_rdrows[band_cursor], in_rd_rows); errors++;
          end
          if (cap_in_base[band_cursor]   !== in_base)            begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d in_base %08x != %08x", i, bb, cap_in_base[band_cursor], in_base); errors++;
          end
          if (cap_out_base[band_cursor]  !== out_base)           begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d out_base %08x != %08x", i, bb, cap_out_base[band_cursor], out_base); errors++;
          end
          if (cap_out_rows[band_cursor]  !== 16'(out_rows))      begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d out_rows %0d != %0d", i, bb, cap_out_rows[band_cursor], out_rows); errors++;
          end
          if (cap_out_rowb[band_cursor]  !== 16'(out_row_bytes)) begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d out_rowb %0d != %0d", i, bb, cap_out_rowb[band_cursor], out_row_bytes); errors++;
          end
          if (cap_zp_in[band_cursor]     !== zp_in)              begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d zp %02x != %02x", i, bb, cap_zp_in[band_cursor], zp_in); errors++;
          end
          if (cap_add_mode[band_cursor]  !== add_mode)           begin
            $display("NN_SEQ_TB: FAIL op%0d b%0d add_mode", i, bb); errors++;
          end
          band_cursor++;
        end
      end
      if (band_cursor !== n_band) begin
        $display("NN_SEQ_TB: FAIL total bands %0d != expected %0d", n_band, exp_bands); errors++;
      end
      for (int k2 = 0; k2 < b_n_eng; k2++) begin
        if (b_eng_cap[k2].src !== 32'd0 || b_eng_cap[k2].dst !== 32'd0 ||
            b_eng_cap[k2].woff !== 32'd0 || b_eng_cap[k2].qoff !== 32'd0) begin
          $display("NN_SEQ_TB: FAIL eng desc src/dst/woff/qoff @%0d", k2); errors++;
        end
      end
      // ---- pre 序列: 112 次, 地址/长度/bank ----
      wptr_e = 32'd0; qptr_e = 32'd0;
      for (int i = 0; i < n_pre; i++) begin
        automatic syn_op_t s = syn_op(i % BAND_CASE_N);
        if (pre_addr_cap[i] !== W_BASE + wptr_e) begin
          $display("NN_SEQ_TB: FAIL pre[%0d] addr %08x != %08x", i, pre_addr_cap[i], W_BASE + wptr_e); errors++;
        end
        if (pre_qaddr_cap[i] !== Q_BASE + qptr_e) begin
          $display("NN_SEQ_TB: FAIL pre[%0d] qaddr %08x != %08x", i, pre_qaddr_cap[i], Q_BASE + qptr_e); errors++;
        end
        if (pre_wlen_cap[i] !== s.wlen || pre_qlen_cap[i] !== s.qlen) begin
          $display("NN_SEQ_TB: FAIL pre[%0d] len %0d/%0d != %0d/%0d", i,
                   pre_wlen_cap[i], pre_qlen_cap[i], s.wlen, s.qlen); errors++;
        end
        if (pre_bank_cap[i] !== (((i % 2) == 0) ? 1'b1 : 1'b0)) begin
          $display("NN_SEQ_TB: FAIL pre[%0d] bank %0b", i, pre_bank_cap[i]); errors++;
        end
        wptr_e += 32'(s.wlen);
        qptr_e += 32'(s.qlen);
      end
      if (n_pre !== NN_ROM_LEN) begin
        $display("NN_SEQ_TB: FAIL pre count %0d != %0d", n_pre, NN_ROM_LEN); errors++;
      end
      // 112 次翻转（偶数）-> 最终 bank=0
      if (b_w_bank_sel !== 1'b0) begin
        $display("NN_SEQ_TB: FAIL final w_bank_sel %0b", b_w_bank_sel); errors++;
      end
      if (b_n_eng !== n_band) begin
        $display("NN_SEQ_TB: FAIL eng starts %0d != bands %0d", b_n_eng, n_band); errors++;
      end
      if (b_cycles !== b_eng_sum) begin
        $display("NN_SEQ_TB: FAIL cycles %0d != eng sum %0d", b_cycles, b_eng_sum); errors++;
      end
      if (b_done_ops !== 8'(NN_ROM_LEN)) begin
        $display("NN_SEQ_TB: FAIL done_ops %0d != %0d", b_done_ops, NN_ROM_LEN); errors++;
      end
      if (!b_done_seen) begin
        $display("NN_SEQ_TB: FAIL band done not high"); errors++;
      end
      band_ops_seen   = NN_ROM_LEN;
      band_bands_seen = n_band;
      band_pre_seen   = n_pre;
      band_eng_seen   = b_n_eng;
      $display("[band] PASS ops=%0d bands=%0d pre=%0d eng=%0d cycles=%0d",
               band_ops_seen, band_bands_seen, band_pre_seen, band_eng_seen, b_cycles);
    end
  endtask


  task automatic band_run;
    begin
      @(negedge clk); b_start = 1'b1;
      @(negedge clk); b_start = 1'b0;
      begin : wait_bdone
        int guard;
        guard = 0;
        while ((b_done !== 1'b1) && (b_err !== 1'b1)) begin
          @(posedge clk); #1;
          if (guard > 4_000_000) begin
            $display("NN_SEQ_TB: FAIL band timeout (pre=%0d bands=%0d eng=%0d)",
                     n_pre, n_band, b_n_eng);
            errors++;
            disable wait_bdone;
          end
          guard++;
        end
      end
      repeat (3) @(posedge clk);
    end
  endtask

  // ==========================================================================
  // 主流程
  // ==========================================================================
  initial begin : main
    rst         = 1'b1;
    start       = 1'b0;
    b_start     = 1'b0;
    inj_pre_err = 1'b0;
    b_w_ddr_base   = W_BASE;
    b_q_ddr_base   = Q_BASE;
    b_arena_base   = ARENA;
    errors = 0;
    n_start = 0;
    n_pre = 0;
    n_band = 0;
    b_n_eng = 0;
    b_eng_sum = 32'd0;
    repeat (5) @(posedge clk);
    rst <= 1'b0;
    repeat (3) @(posedge clk);

    legacy_tests();

    // ---- M6c band: 合成 ROM 注入 + 全模型跑 ----
    inject_band_rom();
    repeat (2) @(posedge clk);
    band_run();
    if (b_err) begin
      $display("NN_SEQ_TB: FAIL band err=%0b code=%02x", b_err, b_err_code); errors++;
    end
    if (!b_done_seen) begin
      $display("NN_SEQ_TB: FAIL band no done"); errors++;
    end
    check_band_run();

    // ---- 错误注入 1: wlen > 128KiB -> E6 ----
    inject_bad_wlen_rom();
    repeat (2) @(posedge clk);
    while (st_pre_busy || st_band_ready) @(posedge clk);
    @(negedge clk); b_start = 1'b1;
    @(negedge clk); b_start = 1'b0;
    begin : wait_bad_len
      int g;
      g = 0;
      while ((b_err !== 1'b1) && (g < 20000)) begin @(posedge clk); #1; g++; end
      if (b_err !== 1'b1) begin
        $display("NN_SEQ_TB: FAIL wlen>128K no err"); errors++;
      end else if (b_err_code !== 8'hE6) begin
        $display("NN_SEQ_TB: FAIL wlen>128K err_code %02x != E6", b_err_code); errors++;
      end else begin
        $display("[band] err-inject wlen>128K -> E6 PASS");
      end
      repeat (5) @(posedge clk);
    end

    // ---- 错误注入 2: pre_err -> E6 ----
    inject_band_rom();
    repeat (2) @(posedge clk);
    while (st_pre_busy || st_band_ready) @(posedge clk);
    inj_pre_err = 1'b1;
    @(negedge clk); b_start = 1'b1;
    @(negedge clk); b_start = 1'b0;
    begin : wait_pre_err
      int g;
      g = 0;
      while ((b_err !== 1'b1) && (g < 20000)) begin @(posedge clk); #1; g++; end
      if (b_err !== 1'b1) begin
        $display("NN_SEQ_TB: FAIL pre_err no err"); errors++;
      end else if (b_err_code !== 8'hE6) begin
        $display("NN_SEQ_TB: FAIL pre_err err_code %02x != E6", b_err_code); errors++;
      end else begin
        $display("[band] err-inject pre_err -> E6 PASS");
      end
      repeat (5) @(posedge clk);
    end

    if (errors == 0)
      $display("NN_SEQ_TB: PASS (legacy starts=%0d cycles=%0d | band ops=%0d bands=%0d pre=%0d eng=%0d)",
               legacy_starts, legacy_cycles, band_ops_seen, band_bands_seen,
               band_pre_seen, band_eng_seen);
    else
      $display("NN_SEQ_TB: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin : global_timeout
    #5_000_000;
    $display("NN_SEQ_TB: FAIL global timeout");
    $finish;
  end

endmodule
