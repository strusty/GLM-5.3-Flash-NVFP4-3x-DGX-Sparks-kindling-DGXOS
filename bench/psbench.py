#!/usr/bin/env python3
# Runs a sparkDash (github.com/MiaAI-Lab/sparkDash) bench job: SPARK_ID=<your head spark id in sparkDash> SPARKDASH_URL=http://host:5570 python3 psbench.py bench|prefill-bench JSON
# psbench.py KIND BODYJSON — run a sparkDash bench job against your head and print results.
import json, sys, time, urllib.request
kind, body = sys.argv[1], json.loads(sys.argv[2])
import os
base = os.environ.get("SPARKDASH_URL", "http://127.0.0.1:5570") + "/api/sparks/" + os.environ["SPARK_ID"] + "/llm/" + kind
req = urllib.request.Request(base, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
try: r = json.load(urllib.request.urlopen(req, timeout=30))
except urllib.error.HTTPError as e: print("HTTP", e.code, e.read().decode()[:300]); sys.exit(1)
bid = r.get("benchId") or r.get("id"); print("started", bid, flush=True)
for _ in range(240):
    time.sleep(5)
    j = json.load(urllib.request.urlopen(f"{base}/{bid}", timeout=30))
    if j.get("status") in ("completed", "failed", "cancelled", "error"): break
print("status", j.get("status"), j.get("error") or "")
json.dump(j, open(f"psbench-{kind}-{int(time.time())}.json", "w"), indent=1)
for x in j.get("results", []):
    print(json.dumps({k: x[k] for k in x if not isinstance(x[k], (list, dict))}))
