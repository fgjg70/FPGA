import importlib.util
spec = importlib.util.spec_from_file_location("gv", "gen_vectors.py")
gv = importlib.util.module_from_spec(spec); spec.loader.exec_module(gv)
v = gv.make_conv("dw3x3_c8", 9, 10, 8, 8, 3, 1, 1, True, 21, dw=True)
ic8=8; oc8=8; C8=8
inp = gv.unpack_nhwc8(bytes(v.a[v.src-gv.NN_A_OFF: v.src-gv.NN_A_OFF+9*10*C8]), 9, 10, C8)
wbytes = v.wq[v.woff: v.woff+9*oc8]
w = [[0]*9 for _ in range(oc8)]
for tap in range(9):
    for oc in range(oc8):
        b = wbytes[tap*oc8+oc]; w[oc][tap] = b-256 if b>=128 else b
qb = v.wq[v.qoff-gv.NN_Q_OFF: v.qoff-gv.NN_Q_OFF+6*oc8+16]
bias = [int.from_bytes(qb[i*4:(i+1)*4],"little",signed=True) for i in range(oc8)]
mpos = [int.from_bytes(qb[4*oc8+i*2:4*oc8+(i+1)*2],"little",signed=True) for i in range(oc8)]
zp_out = qb[6*oc8]; zp_out = zp_out-256 if zp_out>=128 else zp_out
zp_in = qb[6*oc8+1]; zp_in = zp_in-256 if zp_in>=128 else zp_in
leaky = qb[6*oc8+2]; shift = qb[6*oc8+3]
k,st,pad = 3,1,1; ih,iw,ic = 9,10,8
# golden-style per-oc
accg=[]
for ocn in range(oc8):
    acc = bias[ocn]
    for ky in range(k):
        for kx in range(k):
            iy = 0*st + ky - pad; ix = 0*st + kx - pad
            for icn in range(ic):
                av = inp[iy][ix][icn] if (0<=iy<ih and 0<=ix<iw) else zp_in
                acc += av * w[ocn][ky*k+kx]
    accg.append(acc)
# manual transpose
accm=[bias[c] for c in range(oc8)]
for ky in range(k):
    iy = 0*st+ky-pad
    for kx in range(k):
        ix = 0*st+kx-pad
        for c in range(ic8):
            av = inp[iy][ix][c] if (0<=iy<ih and 0<=ix<iw) else zp_in
            accm[c] += av*w[c][ky*k+kx]
print("acc golden-style:", accg)
print("acc transposed  :", accm)
