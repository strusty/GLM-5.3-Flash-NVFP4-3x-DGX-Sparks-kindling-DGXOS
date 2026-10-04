"""GSM8K + HumanEval against the server, thinking off, greedy, 8 at a time; every output saved to records-LABEL.json.
HumanEval code runs in a locked-down container (no network, read-only, non-root, 512 MB, 15 s), on this machine's
docker, or over ssh on SANDBOX_HOST. Usage:
  python3 fetch_data.py; URL=http://HEAD:8888 MODEL=GLM-5.3-Flash GSM_FILE=gsm8k-1319.jsonl python3 run_evals.py LABEL
  python3 misses.py LABEL -v"""
import json, re, sys, subprocess, tempfile, os, concurrent.futures as cf, urllib.request, time
URL = os.environ.get("URL", "http://127.0.0.1:8888") + "/v1/chat/completions"; MODEL = os.environ.get("MODEL", "GLM-5.3-Flash"); L = sys.argv[1]; D = os.path.dirname(os.path.abspath(__file__))
def chat(content, max_tokens):
    b = {"model": MODEL, "temperature": 0, "max_tokens": max_tokens,
         "chat_template_kwargs": {"enable_thinking": False}, "messages": [{"role": "user", "content": content}]}
    for a in range(3):
        try:
            r = json.load(urllib.request.urlopen(urllib.request.Request(URL, json.dumps(b).encode(), {"Content-Type": "application/json"}), timeout=900))
            ch = r["choices"][0]
            return (ch["message"].get("content") or ""), ch.get("finish_reason"), (r.get("usage") or {}).get("completion_tokens"), (ch["message"].get("reasoning_content") or ch["message"].get("reasoning") or "")
        except Exception as e:
            time.sleep(5); err = e
    return f"<error {err}>", "error", 0, ""
def num(s):
    s = s.replace(",", ""); m = re.findall(r"-?\d+(?:\.\d+)?", s)
    return m[-1] if m else None
def gsm(row):
    q = row["question"]; gold = row["answer"].split("####")[-1].strip().replace(",", "")
    out, fr, nt, rs = chat(q + "\n\nSolve step by step, then finish with a line 'The answer is N.' where N is a number.", 1024)
    m = re.search(r"answer is\s*\$?\s*(-?[\d,]+(?:\.\d+)?)", out, re.I)
    pred = (m.group(1).replace(",", "") if m else num(out))
    ok = pred is not None and abs(float(pred) - float(gold)) < 1e-6
    REC.append({"set": "gsm8k", "q": q, "gold": gold, "pred": pred, "ok": ok, "finish": fr, "tokens": nt, "out": out, "reasoning": rs})
    return ok
def run_code(prog):
    # no network, read-only, non-root, 512 MB, 15 s; local docker, or ssh SANDBOX_HOST
    cmd = "docker run --rm -i --network none --read-only --tmpfs /tmp -m 512m --pids-limit 128 --user 65534:65534 python:3.12-slim timeout 15 python3 -"
    host = os.environ.get("SANDBOX_HOST")
    try:
        r = subprocess.run((["ssh", "-o", "BatchMode=yes", host, cmd] if host else ["sh", "-c", cmd]), 
                           input=prog.encode(), capture_output=True, timeout=90)
        return r.returncode == 0, r.stderr.decode(errors="replace")[-600:]
    except subprocess.TimeoutExpired:
        return False, "harness timeout"
def he(row):
    out, fr, nt, rs = chat("Complete the following Python function. Reply with the complete function (including its signature and any imports) "
               "in one ```python code block, nothing else.\n\n```python\n" + row["prompt"] + "\n```", 1536)
    m = re.findall(r"```(?:python)?\n(.*?)```", out, re.S); code = m[0] if m else out
    # the prompt first (its imports and helper functions), then the model's code, then the tests
    prog = row["prompt"] + "\n" + code + "\n\n" + row["test"] + f"\n\ncheck({row['entry_point']})\n"
    ok, err = run_code(prog)
    REC.append({"set": "humaneval", "task": row["task_id"], "ok": ok, "finish": fr, "tokens": nt, "out": out, "err": err})
    return ok
REC = []
GSM = os.environ.get('GSM_FILE', 'gsm8k-250.jsonl')
res = {}
for name, fn, path in (("GSM8K", gsm, GSM), ("HumanEval", he, "humaneval-164.jsonl")):
    rows = [json.loads(l) for l in open(os.path.join(D, path))]; t = time.time()
    with cf.ThreadPoolExecutor(8) as ex: oks = list(ex.map(fn, rows))
    res[name] = (sum(oks), len(oks)); print(f"{L} {name}: {sum(oks)}/{len(oks)} = {100*sum(oks)/len(oks):.1f}%  ({time.time()-t:.0f} s)", flush=True)
json.dump(res, open(os.path.join(D, f"evals-{L}.json"), "w")); json.dump(REC, open(os.path.join(D, f"records-{L}.json"), "w"))
