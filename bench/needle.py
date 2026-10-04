"""Needle retrieval at long context: three random codes at 10/50/90% depth; greedy, thinking off.
Usage: URL=http://127.0.0.1:8888 MODEL=GLM-5.3-Flash python3 needle.py 300000   (~0.83 x N tokens)."""
import json, random, sys, time, urllib.request
import os
URL = os.environ.get("URL", "http://127.0.0.1:8888") + "/v1/chat/completions"; MODEL = os.environ.get("MODEL", "GLM-5.3-Flash")
W = ("river stone lantern copper meadow harbor quiet signal amber orchard canyon velvet thunder ember "
     "willow granite compass echo silver prairie beacon marble cedar falcon tide glacier saffron ivory").split()
def filler(rng, ntok):
    out, n = [], 0
    while n < ntok * 0.62:
        k = rng.randint(6, 14); n += k
        out.append(" ".join(rng.choice(W) for _ in range(k)).capitalize() + ".")
    return " ".join(out)
def run(ntok, seed):
    rng = random.Random(seed); codes = [f"{rng.randint(100000, 999999)}" for _ in range(3)]
    parts = [filler(rng, ntok // 4) for _ in range(4)]
    text = (parts[0][: len(parts[0]) * 2 // 5] + f" The first secret code is {codes[0]}. " + parts[0][len(parts[0]) * 2 // 5:] + " "
            + parts[1] + f" The second secret code is {codes[1]}. " + parts[2] + " "
            + parts[3][: len(parts[3]) * 3 // 5] + f" The third secret code is {codes[2]}. " + parts[3][len(parts[3]) * 3 // 5:])
    body = {"model": MODEL, "temperature": 0, "max_tokens": 64, "chat_template_kwargs": {"enable_thinking": False},
            "messages": [{"role": "user", "content": text + "\n\nWhat are the first, second and third secret codes? Answer with the three numbers only, in order."}]}
    t = time.time()
    r = json.load(urllib.request.urlopen(urllib.request.Request(URL, json.dumps(body).encode(), {"Content-Type": "application/json"}), timeout=2400))
    ans = (r["choices"][0]["message"].get("content") or "").strip(); pt = r["usage"]["prompt_tokens"]
    ok = all(c in ans for c in codes)
    print(f"{'PASS' if ok else 'FAIL'}  {pt:>7,} prompt tokens  {time.time() - t:6.1f} s  want {' '.join(codes)}  got {ans[:60]!r}", flush=True)
    return ok
res = [run(int(sys.argv[1]) if len(sys.argv) > 1 else 300000, 9)]
print("RESULT", "PASS" if all(res) else "FAIL", f"{sum(res)}/{len(res)}")
