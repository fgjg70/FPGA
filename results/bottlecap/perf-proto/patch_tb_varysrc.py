import io

p = 'sim/tb_nn_engine.sv'
s = io.open(p, encoding='utf-8').read()

# 1) rows/src 参数化
s = s.replace('''      ROWS = 13;
      AW   = ROWS*112*64/4;    // 23,296 个 u32
      GW   = ROWS*112*16/4;    // 5,824 个 u32
      dummy = $value$plusargs("op3dir=%s", odir);''',
'''      dummy = $value$plusargs("op3rows=%d", ROWS);
      if (ROWS <= 0) ROWS = 13;
      dummy = $value$plusargs("op3src=%h", srch);
      if (srch == 0) srch = 32'h0006_0000;
      AW   = ROWS*112*64/4;
      GW   = ROWS*112*16/4;
      dummy = $value$plusargs("op3dir=%s", odir);''')
s = s.replace('      integer      ROWS, AW, GW;',
              '      integer      ROWS, AW, GW;\n      logic [31:0] srch;')
# 2) A 装载基址改为 srch
s = s.replace('          cpu_wr32(NN_A_OFF + 32\'(4*i), v);',
              '          cpu_wr32(srch + 32\'(4*i), v);')
# 3) 描述符 src 用 srch
s = s.replace("      desc.src    = NN_A_OFF;", "      desc.src    = srch;")
# 4) 打印 src
s = s.replace('$display("OP3ISO: start dir=%s rows=%0d AW=%0d GW=%0d", odir, ROWS, AW, GW);',
              '$display("OP3ISO: start dir=%s rows=%0d src=%08x AW=%0d GW=%0d", odir, ROWS, srch, AW, GW);')
# 5) PASS/FAIL 打印带 src
s = s.replace('$display("OP3ISO: PASS rows=%0d cyc=%0d err=%02x mis=0", ROWS, ncyc, ecode);',
              '$display("OP3ISO: PASS rows=%0d src=%08x cyc=%0d err=%02x mis=0", ROWS, srch, ncyc, ecode);')
s = s.replace('$display("OP3ISO: FAIL rows=%0d cyc=%0d err=%02x mis=%0d ok=%0d",\n                         ROWS, ncyc, ecode, mis, ok);',
              '$display("OP3ISO: FAIL rows=%0d src=%08x cyc=%0d err=%02x mis=%0d ok=%0d",\n                         ROWS, srch, ncyc, ecode, mis, ok);')

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched vary-src support:', 'op3src' in s)
