    // ==========================================================================
    // task-20: op3 ISO 仲裁实验（默认不跑；+op3iso +op3dir=<dir> 才跑）
    //   动机: stock nn_mem 的 A 窗口以 B_OFF(0x78000) 为硬边界 => A 容量固定 96KB
    //   （nn_mem.sv:508），op3 的 A=802,816 B 装不下；因此用 **13 行 band** 验证
    //   引擎 dense 路径本身（ic=64 多 ic-block / k=1 / pad=0）：
    //     A band = 13*112*64 = 93,184 B <= 96KB; 输出 band = 13*112*16 = 23,296 B <= 32KB
    //   输入用复现包的 op3_A.hex 前 13 行，期望用 op3_golden.hex 前 13 行。
    // ==========================================================================
    if ($test$plusargs("op3iso")) begin : op3_iso_blk
      string       odir;
      integer      fh, fh2, rc, i, mis, ncyc, dummy;
      integer      ROWS, AW, GW;
      logic [31:0] v, gv;
      logic [7:0]  ecode;
      logic        ok, pass;
      ROWS = 13;
      AW   = ROWS*112*64/4;    // 23,296 个 u32
      GW   = ROWS*112*16/4;    // 5,824 个 u32
      dummy = $value$plusargs("op3dir=%s", odir);
      $display("OP3ISO: start dir=%s rows=%0d AW=%0d GW=%0d", odir, ROWS, AW, GW);

      // 1) W: 1024 B = 256 x u32 -> dbg space 0
      fh = $fopen({odir, "/op3_W.hex"}, "r");
      if (fh == 0) begin $display("OP3ISO: FAIL cannot open op3_W.hex"); end
      else begin
        for (i = 0; i < 256; i++) begin
          rc = $fscanf(fh, "%h", v);
          dbg_wr(1'b0, 17'(i), v);
        end
        $fclose(fh);
      end
      // 2) Q: 112 B = 28 x u32 -> dbg space 1
      fh = $fopen({odir, "/op3_Q.hex"}, "r");
      if (fh == 0) begin $display("OP3ISO: FAIL cannot open op3_Q.hex"); end
      else begin
        for (i = 0; i < 28; i++) begin
          rc = $fscanf(fh, "%h", v);
          dbg_wr(1'b1, 17'(i), v);
        end
        $fclose(fh);
      end
      // 3) A band: 前 13 行 (23,296 u32) -> CPU 窗口 NN_A_OFF
      fh = $fopen({odir, "/op3_A.hex"}, "r");
      if (fh == 0) begin $display("OP3ISO: FAIL cannot open op3_A.hex"); end
      else begin
        for (i = 0; i < AW; i++) begin
          rc = $fscanf(fh, "%h", v);
          cpu_wr32(NN_A_OFF + 32'(4*i), v);
        end
        $fclose(fh);
      end
      cpu_idle();
      @(negedge clk);

      // 4) 描述符: conv 1x1 s1 p0, 13x112, ic=64 oc=16, WQ 偏移 0
      desc = '0;
      desc.op     = 2'd0;
      desc.flags  = 8'h00;
      desc.ks     = 4'd1;
      desc.stride = 2'd1;
      desc.pad    = 3'd0;
      desc.ih     = 16'd13;
      desc.iw     = 16'd112;
      desc.ic     = 16'd64;
      desc.oc     = 16'd16;
      desc.src    = NN_A_OFF;
      desc.dst    = NN_B_OFF;
      desc.woff   = 32'd0;
      desc.qoff   = 32'd0;
      run_op(ncyc, ecode, ok);

      // 5) 读回 B 窗口前 GW 个 u32 与 golden 比
      mis = 0;
      fh2 = $fopen({odir, "/op3_golden.hex"}, "r");
      if (fh2 == 0) begin
        $display("OP3ISO: FAIL cannot open op3_golden.hex");
        mis = 999999;
      end else begin
        for (i = 0; i < GW; i++) begin
          rc = $fscanf(fh2, "%h", gv);
          cpu_rd32(NN_B_OFF + 32'(4*i), v);
          if (v !== gv) begin
            if (mis < 6)
              $display("OP3ISO:   MISMATCH word@%0d got=%08x exp=%08x", i, v, gv);
            mis = mis + 1;
          end
        end
        $fclose(fh2);
      end
      pass = ok && (mis == 0);
      if (pass) $display("OP3ISO: PASS rows=%0d cyc=%0d err=%02x mis=0", ROWS, ncyc, ecode);
      else      $display("OP3ISO: FAIL rows=%0d cyc=%0d err=%02x mis=%0d ok=%0d",
                         ROWS, ncyc, ecode, mis, ok);
    end

