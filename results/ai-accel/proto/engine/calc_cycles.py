import re
raw = open("tb_run10.log", "rb").read()
for enc in ("utf-16", "utf-8", "latin-1"):
    try:
        txt = raw.decode(enc)
        if "CASE conv1x1_s1" in txt: break
    except Exception:
        pass
rows = []
for line in open("vec/manifest.txt", encoding="utf-8"):
    p = line.split()
    if len(p) != 14: continue
    name = p[0]; op,fl,ks,st,pad,ih,iw,ic,oc,src,dst,woff,qoff = map(int,p[1:])
    rows.append(dict(name=name,op=op,flags=fl,ks=ks,st=st,pad=pad,ih=ih,iw=iw,ic=ic,oc=oc,
                     src=src,dst=dst))
meas = {}
for m in re.finditer(r"CASE (\S+)\s+op=(\d+).*?cyc=(\d+)\s+misA=(\d+)\s+misB=(\d+)", txt):
    meas[m.group(1)] = (int(m.group(3)), int(m.group(4)), int(m.group(5)))
def ceil8(x): return ((x+7)//8)*8
def theory(c):
    ic8 = ceil8(c['ic']); oc8 = ceil8(c['oc']); ICB = ic8//8; OCB = oc8//8
    k, st = c['ks'], c['st']
    pad = c['pad']
    if c['op'] == 1 and pad == 0: pad = (k-1)//2
    oh = (c['ih'] + 2*pad - k)//st + 1; ow = (c['iw'] + 2*pad - k)//st + 1
    if c['op'] == 0:
        if c['flags'] & 1:
            count = 7*st + k
            per = (count+1) + 1 + k
            nb = oh*((ow+7)//8)
            return 1 + OCB*9 + OCB*nb*(1 + k*per + 2 + 9 + 1)
        else:
            count = 8 if k == 1 else 7*st + k
            wi = 0 if k == 1 else 1
            sub = (1 if k == 1 else k) * ICB
            per = (count+1) + wi + 8*k
            nb = oh*((ow+7)//8)
            return 1 + OCB*9 + OCB*nb*(1 + sub*per + 2 + 9 + 1)
    elif c['op'] == 1:
        count = 7*st + k
        per = (count+1) + 1 + k
        nb = ICB * oh * ((ow+7)//8)
        return 1 + nb*(1 + k*per + 8 + 1)
    elif c['op'] == 2:
        return 1 + c['ih']*c['iw']*ICB*(5 if (c['flags'] & 8) else 2)
    else:
        return 1 + c['ih']*c['iw']*ICB*3
tot_mis = 0
bad = 0
lines = []
for c in rows:
    th = theory(c)
    me, ma, mb = meas.get(c['name'], (-1,0,0))
    tot_mis += ma + mb
    ok = (th == me) and (ma == 0) and (mb == 0)
    bad += 0 if ok else 1
    lines.append("| %-17s | %d/%d/%d | %d | %d,%d | %d | %s |" % (
        c['name'], c['ks'], c['st'], c['pad'], me, ma, mb, th, "OK" if ok else "FAIL"))
print("\n".join(lines))
print("TOTAL cases=%d fail=%d tot_mismatch=%d" % (len(rows), bad, tot_mis))
open("cycle_table.md","w",encoding="utf-8").write("\n".join(lines)+"\n")
