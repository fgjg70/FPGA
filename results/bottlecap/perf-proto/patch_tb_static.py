import io

p = 'results/bottlecap/perf-proto/tb_op3_static.sv'
s = io.open(p, encoding='utf-8').read()

s = s.replace('''    dummy = $value$plusargs("adir=%s", adir);
    $display("OP3ST: dir=%s", adir);''',
'''    dummy = $value$plusargs("adir=%s", adir);
    dummy = $value$plusargs("rows=%d", rows);
    if (rows <= 0) rows = 112;
    n_g = (rows * 112 * 16) / 4;
    n_a = (rows * 112 * 64) / 4;
    $display("OP3ST: dir=%s rows=%0d", adir, rows);''')

s = s.replace('    for (i = 0; i < A_WORDS; i++) rc = $fscanf(fh, "%h", a_words[i]);',
              '    for (i = 0; i < n_a; i++) rc = $fscanf(fh, "%h", a_words[i]);')
s = s.replace('    for (i = 0; i < G_WORDS; i++) rc = $fscanf(fh, "%h", g_words[i]);',
              '    for (i = 0; i < n_g; i++) rc = $fscanf(fh, "%h", g_words[i]);')
s = s.replace('    $display("OP3ST: loaded A=%0d W=%0d Q=%0d G=%0d words", A_WORDS, W_WORDS, Q_WORDS, G_WORDS);',
              '    $display("OP3ST: loaded A=%0d W=%0d Q=%0d G=%0d words", n_a, W_WORDS, Q_WORDS, n_g);')
s = s.replace("    desc.ih     = 16'd112;", "    desc.ih     = rows[15:0];")
s = s.replace('''    mis = 0;
    for (i = 0; i < G_WORDS; i++) begin : cmp''',
'''    mis = 0;
    for (i = 0; i < n_g; i++) begin : cmp''')
s = s.replace('      $display("OP3ST: PASS cycles=%0d words=%0d err=00", cycles, G_WORDS);',
              '      $display("OP3ST: PASS rows=%0d cycles=%0d words=%0d err=00", rows, cycles, n_g);')
s = s.replace('      $display("OP3ST: FAIL mis=%0d/%0d done=%0d err=%02x", mis, G_WORDS, done, err_code);',
              '      $display("OP3ST: FAIL rows=%0d mis=%0d/%0d done=%0d err=%02x", rows, mis, n_g, done, err_code);')
s = s.replace('  integer fh, rc, i, mis, guard, dummy;',
              '  integer fh, rc, i, mis, guard, dummy, rows, n_g, n_a;')

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched rows support:', 'rows=%d' in s)
