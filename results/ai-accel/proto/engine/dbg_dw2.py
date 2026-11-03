import importlib.util
spec = importlib.util.spec_from_file_location("gv", "gen_vectors.py")
gv = importlib.util.module_from_spec(spec); spec.loader.exec_module(gv)
v = gv.make_conv("dw3x3_c8", 9, 10, 8, 8, 3, 1, 1, True, 21, dw=True)
ic8 = 8; oc8 = 8
C8 = ic8
inp = gv.unpack_nhwc8(bytes(v.a[v.src-gv.NN_A_OFF: v.src-gv.NN_A_OFF+9*10*C8]), 9, 10, C8)
wbytes = v.wq[v.woff: v.woff+9*oc8]
w = [[0]*9 for _ in range(oc8)]
for tap in range(9):
    for oc in range(oc8):
        b = wbytes[tap*oc8+oc]
        w[oc][tap] = b-256 if b>=128 else b
qb = v.wq[v.qoff-gv.NN_Q_OFF: v.qoff-gv.NN_Q_OFF+6*oc8+16]
bias = [int.from_bytes(qb[i*4:(i+1)*4],"little",signed=True) for i in range(oc8)]
mpos = [int.from_bytes(qb[4*oc8+i*2:4*oc8+(i+1)*2],"little",signed=True) for i in range(oc8)]
zp_out = qb[6*oc8]; zp_out = zp_out-256 if zp_out>=128 else zp_out
zp_in = qb[6*oc8+1]; zp_in = zp_in-256 if zp_in>=128 else zp_in
leaky = qb[6*oc8+2]; shift = qb[6*oc8+3]
out, oh, ow = gv.golden_conv(v, inp, w, bias, mpos, zp_in, zp_out, shift, leaky, dw=True)
print("golden_conv out px0:", [out[0][0][c] & 0xFF for c in range(oc8)])
print("file exp word8:", v.bexp[(v.dst-gv.NN_A_OFF+0x10000)-(v.dst-gv.NN_A_OFF) : ][:8].hex() if False else v.bexp[(v.dst-gv.NN_B_OFF):(v.dst-gv.NN_B_OFF)+8].hex())
# also, print raw input px0 and weights
print("inp px0:", [inp[0][0][c] for c in range(8)])
print("w[0]:", w[0], "w[1]:", w[1], "w[7]:", w[7])
print("bias0..7:", bias, "mpos:", mpos)
