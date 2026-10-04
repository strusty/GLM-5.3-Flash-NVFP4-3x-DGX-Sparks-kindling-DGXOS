"""Classify eval misses from records-LABEL.json: harness/format problems vs genuinely wrong answers."""
import json, re, sys, collections
L = sys.argv[1]; R = json.load(open(f"records-{L}.json"))
def nums(s): return [x.replace(",", "") for x in re.findall(r"-?\d[\d,]*(?:\.\d+)?", s)]
g = [r for r in R if r["set"] == "gsm8k"]; gm = [r for r in g if not r["ok"]]
cat = collections.Counter(); ex = collections.defaultdict(list)
for r in gm:
    tail = r["out"][-300:]
    if r["finish"] == "length" or r["pred"] is None: c = "cut off / no final answer"
    elif any(abs(float(x) - float(r["gold"])) < 1e-6 for x in nums(tail) if re.fullmatch(r"-?\d+(\.\d+)?", x)): c = "gold number in final lines (parse/format?)"
    else: c = "wrong answer"
    cat[c] += 1; ex[c].append(r)
print(f"GSM8K {sum(r['ok'] for r in g)}/{len(g)} = {100*sum(r['ok'] for r in g)/len(g):.1f}%  misses {len(gm)}:", dict(cat))
print(f"   reply tokens: median {sorted(r['tokens'] or 0 for r in g)[len(g)//2]}, max {max(r['tokens'] or 0 for r in g)}; finish=length: {sum(r['finish']=='length' for r in g)}")
h = [r for r in R if r["set"] == "humaneval"]; hm = [r for r in h if not r["ok"]]
hc = collections.Counter(); hex_ = collections.defaultdict(list)
for r in hm:
    e = r.get("err") or ""
    if r["finish"] == "length": c = "cut off"
    elif "SyntaxError" in e or "IndentationError" in e: c = "syntax/indent"
    elif "NameError" in e or "ModuleNotFoundError" in e or "ImportError" in e: c = "missing name/import"
    elif "AssertionError" in e: c = "wrong logic (assert)"
    elif "timeout" in e.lower() or e.strip() == "": c = "timeout / no output"
    else: c = "other: " + (e.strip().splitlines()[-1][:60] if e.strip() else "?")
    hc[c] += 1; hex_[c].append(r)
print(f"HumanEval {sum(r['ok'] for r in h)}/{len(h)} = {100*sum(r['ok'] for r in h)/len(h):.1f}%  failures {len(hm)}:", dict(hc))
print("   failed tasks:", " ".join(sorted(r["task"].split("/")[-1] for r in hm)))
if "-v" in sys.argv:
    for c, rs in ex.items():
        print(f"\n=== GSM8K [{c}] ({len(rs)})")
        for r in rs[:40]: print(f"  gold {r['gold']:>8} pred {str(r['pred']):>10} tok {r['tokens']}: …{r['out'][-160:].strip()!r}")
    for c, rs in hex_.items():
        print(f"\n=== HumanEval [{c}] ({len(rs)})")
        for r in rs: print(f"  {r['task']}: {(r.get('err') or '').strip().splitlines()[-1][:110] if (r.get('err') or '').strip() else ''}")
