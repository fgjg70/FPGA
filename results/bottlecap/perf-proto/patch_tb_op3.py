import io

p = 'sim/tb_nn_engine.sv'
ins = io.open('results/bottlecap/perf-proto/_tb_op3iso_insert.sv', encoding='utf-8').read()
s = io.open(p, encoding='utf-8').read()
anchor = '    $display("SUMMARY cases=%0d pass=%0d fail=%0d total_mismatch=%0d",'
assert s.count(anchor) == 1, s.count(anchor)
s = s.replace(anchor, ins + anchor)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('tb_nn_engine: op3iso gated case inserted, size', len(s))
