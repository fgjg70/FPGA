import io

p = 'sim/tb_nn_engine.sv'
s = io.open(p, encoding='utf-8').read()

# 在 op3iso 块里：把手动 run 换成"带逐拍监视"的 run（+op3trace 开关）
old = '''      run_op(ncyc, ecode, ok);'''
new = '''      if ($test$plusargs("op3trace")) begin : op3_tr
        integer trc;
        logic tr_on;
        tr_on = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        trc = 0;
        while ((done !== 1'b1) && (trc < 1000000)) begin
          if (tr_on) begin
            $display("TRC %0d a_re=%b a_sel=%b a_addr=%06x a_rdata=%032x w_re=%b w_addr=%06x w_rdata=%032x q_re=%b q_addr=%05x q_rdata=%016x b_we=%b b_addr=%06x b_wdata=%032x b_wstrb=%04x",
                     trc, a_re, a_sel, a_addr, a_rdata, w_re, w_addr, w_rdata,
                     q_re, q_addr, q_rdata, b_we, b_addr, b_wdata, b_wstrb);
            if (trc >= 140) tr_on = 1'b0;
          end
          @(negedge clk);
          trc = trc + 1;
        end
        ncyc  = int'(cycles);
        ecode = err_code;
        ok    = (done === 1'b1) && (trc < 1000000) && (ecode == 8'h00);
        @(negedge clk);
      end else begin
        run_op(ncyc, ecode, ok);
      end'''
assert s.count(old) == 1, s.count(old)
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('op3trace monitor added')
