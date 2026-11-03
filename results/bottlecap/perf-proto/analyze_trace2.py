import io
import re

PAT = re.compile(
    r'# TRC (\d+) a_re=(\d+) a_sel=(\d+) a_addr=([0-9a-f]+) a_rdata=([0-9a-f]+) '
    r'w_re=(\d+) w_addr=([0-9a-f]+) w_rdata=([0-9a-f]+) '
    r'q_re=(\d+) q_addr=([0-9a-f]+) q_rdata=([0-9a-f]+) '
    r'b_we=(\d+) b_addr=([0-9a-f]+) b_wdata=([0-9a-f]+) b_wstrb=([0-9a-f]+)')

SIG = ('# TRC %d a_re=%d a_sel=%d a_addr=%06x a_rdata=%s w_re=%d w_addr=%06x w_rdata=%s '
       'q_re=%d q_addr=%05x q_rdata=%s b_we=%d b_addr=%06x b_wdata=%s b_wstrb=%s')

trace = []
for line in io.open('results/bottlecap/perf-proto/op3work/trace_run.log', encoding='utf-8', errors='ignore'):
    m = PAT.search(line)
    if not m:
        continue
    trace.append(dict(
        cyc=int(m.group(1)),
        a_re=int(m.group(2)), a_sel=int(m.group(3)), a_addr=int(m.group(4), 16), a_rdata=m.group(5),
        w_re=int(m.group(6)), w_addr=int(m.group(7), 16), w_rdata=m.group(8),
        q_re=int(m.group(9)), q_addr=int(m.group(10), 16), q_rdata=m.group(11),
        b_we=int(m.group(12)), b_addr=int(m.group(13), 16), b_wdata=m.group(14), b_wstrb=m.group(15)))
print('parsed', len(trace), 'trace lines')

io.open('results/bottlecap/perf-proto/op3_stock_trace.log', 'w', encoding='utf-8', newline='\n').write(
    '\n'.join(SIG % (t['cyc'], t['a_re'], t['a_sel'], t['a_addr'], t['a_rdata'],
                     t['w_re'], t['w_addr'], t['w_rdata'], t['q_re'], t['q_addr'], t['q_rdata'],
                     t['b_we'], t['b_addr'], t['b_wdata'], t['b_wstrb']) for t in trace) + '\n')


def load_hex_words(path):
    out = []
    for line in io.open(path, encoding='utf-8', errors='ignore'):
        line = line.strip()
        if line:
            out.append(int(line, 16))
    return out


adir = 'results/bottlecap/proto/m6b_data/op3_iso'
a_words = load_hex_words(adir + '/op3_A.hex')
w_words = load_hex_words(adir + '/op3_W.hex')
q_words = load_hex_words(adir + '/op3_Q.hex')
A_OFF = 0x60000


def a_win(off):
    base = (off >> 4) * 4
    vals = [a_words[base + i] if (base + i) < len(a_words) else 0 for i in range(4)]
    return ''.join('%08x' % v for v in reversed(vals))


def w_win(off):
    base = off >> 2
    vals = [w_words[base + i] if (base + i) < len(w_words) else 0 for i in range(4)]
    return ''.join('%08x' % v for v in reversed(vals))


def q_w64(idx):
    lo = q_words[2 * idx] if 2 * idx < len(q_words) else 0
    hi = q_words[2 * idx + 1] if 2 * idx + 1 < len(q_words) else 0
    return '%08x%08x' % (hi, lo)


by = {t['cyc']: t for t in trace}


def lat_hist(sel, exp_fn, field, deltas=(1, 2, 3)):
    hist, checked, ok = {}, 0, 0
    for t in trace:
        if t[sel] != 1:
            continue
        exp = exp_fn(t)
        checked += 1
        for d in deltas:
            nxt = by.get(t['cyc'] + d)
            if nxt is not None and nxt[field].lower() == exp.lower():
                hist[d] = hist.get(d, 0) + 1
                ok += 1
                break
        else:
            hist[-1] = hist.get(-1, 0) + 1
    return checked, ok, hist, [t['cyc'] for t in trace if t[sel] == 1][:6]


chk, ok, hist, first = lat_hist('a_re', lambda t: a_win(t['a_addr'] - A_OFF), 'a_rdata')
print('a: beats=%d matched=%d hist=%s first_cyc=%s' % (chk, ok, hist, first))
chk, ok, hist, first = lat_hist('w_re', lambda t: w_win(t['w_addr']), 'w_rdata')
print('w: beats=%d matched=%d hist=%s first_cyc=%s' % (chk, ok, hist, first))
chk, ok, hist, first = lat_hist('q_re', lambda t: q_w64(t['q_addr']), 'q_rdata')
print('q: beats=%d matched=%d hist=%s first_cyc=%s' % (chk, ok, hist, first))

print('a_sel values seen:', sorted({t['a_sel'] for t in trace}))
a_cyc = [t['cyc'] for t in trace if t['a_re'] == 1]
print('a_re cyc:', a_cyc[:10], '...', a_cyc[-3:])
w_cyc = [t['cyc'] for t in trace if t['w_re'] == 1]
print('w_re cyc:', w_cyc[:8], '...', w_cyc[-3:])
print('q_re cyc:', [t['cyc'] for t in trace if t['q_re'] == 1])
b_cyc = [t['cyc'] for t in trace if t['b_we'] == 1]
print('b_we beats:', len(b_cyc), 'first:', b_cyc[:4])
