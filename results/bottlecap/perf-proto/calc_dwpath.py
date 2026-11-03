import io
import json
import importlib.util

spec = importlib.util.spec_from_file_location('cm', 'tools/bottlecap/cycle_model.py')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)

out = {}
for nm, p in (('bottlecap', 'results/bottlecap/plan/plan.json'),
              ('yolo', 'sim/prog/yolo/plan.json')):
    ops = json.load(io.open(p, encoding='utf-8'))['ops']
    rows, macs = cm.decompose(ops)
    dw = [r for r in rows if r['detail'].get('cat') == 'dw']
    elig = [r for r in dw if r['ic'] == r['oc'] and r['oc'] % 16 == 0]
    tot = sum(r['cycles'] for r in dw)
    et = sum(r['cycles'] for r in elig)
    out[nm] = dict(dw=tot, eligible=et, frac=et / tot, half=et / 2.0)
    print('%s: dw=%.0f eligible=%.0f (%.0f%%) halve-saving=%.0f'
          % (nm, tot, et, 100 * et / tot, et / 2.0))
io.open('results/bottlecap/reports/dwpath_a7a_eligible.json', 'w', encoding='utf-8').write(
    json.dumps(out, ensure_ascii=False, indent=1))
