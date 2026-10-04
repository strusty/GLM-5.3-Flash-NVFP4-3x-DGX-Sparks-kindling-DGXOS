"""Fetch GSM8K (test, 1,319) and HumanEval (164) as JSONL via the Hugging Face datasets API (no extra packages)."""
import json, urllib.request, time
def rows(ds, cfg, n):
    out = []
    for off in range(0, n, 100):
        u = f"https://datasets-server.huggingface.co/rows?dataset={ds}&config={cfg}&split=test&offset={off}&length={min(100, n - off)}"
        for _ in range(5):
            try: d = json.load(urllib.request.urlopen(u, timeout=60)); break
            except Exception: time.sleep(3)
        out += [r["row"] for r in d["rows"]]
    return out
g = rows("openai/gsm8k", "main", 1319); h = rows("openai/openai_humaneval", "openai_humaneval", 164)
open("gsm8k-1319.jsonl", "w").write("".join(json.dumps(r) + "\n" for r in g)); open("gsm8k-250.jsonl", "w").write("".join(json.dumps(r) + "\n" for r in g[:250]))
open("humaneval-164.jsonl", "w").write("".join(json.dumps(r) + "\n" for r in h)); print("gsm8k", len(g), "humaneval", len(h))
