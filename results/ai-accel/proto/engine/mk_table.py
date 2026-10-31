import re
raw = open("tb_run10.log", "rb").read()
for enc in ("utf-16", "utf-8", "latin-1"):
    try:
        txt = raw.decode(enc)
        if "CASE conv1x1_s1" in txt: break
    except Exception: pass
rows = []
for line in open("vec/manifest.txt", encoding="utf-8"):
    p = line.split()
    if len(p) != 14: continue
    name = p[0]; op,fl,ks,st,pad,ih,iw,ic,oc,src,dst,woff,qoff = map(int,p[1:])
    rows.append(dict(name=name,op=op,flags=fl,ks=ks,st=st,pad=pad,ih=ih,iw=iw,ic=ic,oc=oc))
meas = {}
for m in re.finditer(r"CASE (\S+)\s+op=(\d+).*?cyc=(\d+)\s+misA=(\d+)\s+misB=(\d+)", txt):
    meas[m.group(1)] = (int(m.group(3)), int(m.group(4)), int(m.group(5)))
def ceil8(x): return ((x+7)//8)*8
def dims(c):
    k, st, pad = c['ks'], c['st'], c['pad']
    if c['op'] == 1 and pad == 0: pad = (k-1)//2
    return (c['ih']+2*pad-k)//st+1, (c['iw']+2*pad-k)//st+1
def theory(c):
    ic8 = ceil8(c['ic']); oc8 = ceil8(c['oc']); ICB = ic8//8; OCB = oc8//8
    k, st = c['ks'], c['st']
    oh, ow = dims(c)
    if c['op'] == 0:
        if c['flags'] & 1:
            return 1 + OCB*9 + OCB*(oh*((ow+7)//8))*(1 + k*((7*st+k+1)+1+k) + 2 + 9 + 1)
        count = 8 if k == 1 else 7*st+k
        wi = 0 if k == 1 else 1
        sub = (1 if k == 1 else k) * ICB
        return 1 + OCB*9 + OCB*(oh*((ow+7)//8))*(1 + sub*((count+1)+wi+8*k) + 2 + 9 + 1)
    elif c['op'] == 1:
        nb = ICB*oh*((ow+7)//8)
        return 1 + nb*(1 + k*((7*st+k+1)+1+k) + 8 + 1)
    elif c['op'] == 2:
        return 1 + c['ih']*c['iw']*ICB*(5 if (c['flags'] & 8) else 2)
    else:
        return 1 + c['ih']*c['iw']*ICB*3
NAMES = {0:'conv/dw',1:'pool',2:'copy/up',3:'add'}
out = []
for c in rows:
    oh, ow = dims(c)
    me, ma, mb = meas[c['name']]
    th = theory(c)
    out.append("| %s | %s | %d/%d/%d | %dx%d | %dx%dx%d->%d | %d | %d | %d,%d |" % (
        c['name'], NAMES[c['op']], c['ks'], c['st'], c['pad'], c['ih'], c['iw'],
        oh, ow, c['ic'], c['oc'], me, th, ma, mb))
open("case_table.md","w",encoding="utf-8").write("\n".join(out)+"\n")
print("\n".join(out[:4])); print("... %d rows" % len(out))
