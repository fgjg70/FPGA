import sys
sys.path.insert(0, ".")
import importlib.util
spec = importlib.util.spec_from_file_location("gv", "gen_vectors.py")
gv = importlib.util.module_from_spec(spec); spec.loader.exec_module(gv)
# reconstruct the conv1x1_s1 case exactly: make_conv(...) random.Random(seed=1)
cases = []
cases.append(gv.make_conv("conv1x1_s1", 8, 10, 8, 8, 1, 1, 0, True, 1))
v = cases[0]
# read Q block from v.wq
oc8 = gv.pad8(8)
qb = v.wq[v.qoff-gv.NN_Q_OFF: v.qoff-gv.NN_Q_OFF+6*oc8+16]
bias = [int.from_bytes(qb[i*4:(i+1)*4],"little",signed=True) for i in range(oc8)]
mpos = [int.from_bytes(qb[4*oc8+i*2:4*oc8+(i+1)*2],"little",signed=True) for i in range(oc8)]
tail = qb[6*oc8:6*oc8+4]
zp_out = tail[0]-256 if tail[0]>=128 else tail[0]
leaky = tail[2]; shift = tail[3]
print("bias", bias)
print("mpos", mpos, "zp_out", zp_out, "leaky", leaky, "shift", shift)
def clamp8(x): return -128 if x<-128 else (127 if x>127 else x)
mneg = [((m*3277+16384)>>15) if leaky else m for m in mpos]
out = []
for oc in range(oc8):
    acc = bias[oc]
    m = mpos[oc] if acc>=0 else mneg[oc]
    y = (acc*m)>>shift
    out.append(clamp8(y+zp_out))
print("bias-only out bytes:", [x & 0xFF for x in out])
