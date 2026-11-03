import importlib.util
spec = importlib.util.spec_from_file_location("gv", "gen_vectors.py")
gv = importlib.util.module_from_spec(spec); spec.loader.exec_module(gv)
v = gv.make_conv("dw3x3_c8", 9, 10, 8, 8, 3, 1, 1, True, 21, dw=True)
ic8 = gv.pad8(8); oc8 = gv.pad8(8)
# decode inputs from v.a (src in A at v.src)
C8 = ic8
inp = gv.unpack_nhwc8(bytes(v.a[v.src-gv.NN_A_OFF: v.src-gv.NN_A_OFF+9*10*C8]), 9, 10, C8)
# weights: layout [tap][oc8]
wbytes = v.wq[v.woff: v.woff+9*oc8]
w = [[0]*9 for _ in range(oc8)]
for tap in range(9):
    for oc in range(oc8):
        b = wbytes[tap*oc8+oc]
        w[oc][tap] = b-256 if b>=128 else b
# q params
qb = v.wq[v.qoff-gv.NN_Q_OFF: v.qoff-gv.NN_Q_OFF+6*oc8+16]
bias = [int.from_bytes(qb[i*4:(i+1)*4],"little",signed=True) for i in range(oc8)]
mpos = [int.from_bytes(qb[4*oc8+i*2:4*oc8+(i+1)*2],"little",signed=True) for i in range(oc8)]
zp_out = qb[6*oc8]; zp_out = zp_out-256 if zp_out>=128 else zp_out
zp_in = qb[6*oc8+1]; zp_in = zp_in-256 if zp_in>=128 else zp_in
leaky = qb[6*oc8+2]; shift = qb[6*oc8+3]
print("woff=%x qoff=%x src=%x dst=%x bias=%s" % (v.woff, v.qoff, v.src, v.dst, bias))
print("mpos=", mpos, "zp_out", zp_out, "zp_in", zp_in, "shift", shift)
mneg = [((m*3277+16384)>>15) if leaky else m for m in mpos]
# acc for pixel (0,0)
k, st, pad = 3,1,1
acc = [bias[oc] for oc in range(oc8)]
for ky in range(k):
    iy = 0*st + ky - pad
    for kx in range(k):
        ix = 0*st + kx - pad
        for c in range(ic8):
            av = inp[iy][ix][c] if (0<=iy<9 and 0<=ix<10) else zp_in
            acc[c] += av * w[c][ky*k+kx]
print("acc px0 =", acc)
out=[]
for c in range(oc8):
    m = mpos[c] if acc[c] >= 0 else mneg[c]
    y = (acc[c]*m)>>shift
    out.append(gv.clamp8(y+zp_out))
print("out px0 =", [x & 0xFF for x in out])
# also dump first 3 input pixels & expected output words
print("exp b word8..9:", v.bexp[(v.dst-gv.NN_B_OFF):(v.dst-gv.NN_B_OFF)+16].hex())
