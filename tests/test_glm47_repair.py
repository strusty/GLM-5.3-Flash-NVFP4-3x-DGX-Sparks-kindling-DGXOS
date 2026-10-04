"""Checks for glm47_repair on real GLM tool-call text, fed whole and token by token.
Run inside the serving image (CPU only): python3 test_glm47_repair.py /tmp/glm47_repair.py
"""
import json
import sys
import time

from transformers import AutoTokenizer
from vllm.entrypoints.openai.chat_completion.protocol import ChatCompletionRequest
from vllm.tool_parsers.abstract_tool_parser import ToolParserManager as M

M.import_tool_parser(sys.argv[1] if len(sys.argv) > 1 else "/tmp/glm47_repair.py")
Parser = M.get_tool_parser("glm47_repair")
tok = AutoTokenizer.from_pretrained("/models/glm-5.3-flash-nvfp4", trust_remote_code=True)
fn = lambda name, props, req=(): {"type": "function", "function": {"name": name, "parameters": {
    "type": "object", "properties": props, "required": list(req)}}}
tools = [
    fn("terminal", {"command": {"type": "string"}, "timeout": {"type": "integer"}}, ["command"]),
    fn("execute_code", {"code": {"type": "string"}}, ["code"]),
    fn("write_file", {"path": {"type": "string"}, "content": {"type": "string"}}, ["path", "content"]),
    fn("web_search", {"query": {"type": "string"}, "limit": {"type": "integer"}}, ["query"]),
]
req = ChatCompletionRequest(model="glm53", messages=[{"role": "user", "content": "x"}], tools=tools)
R = "_rejected_by_server"
TC = lambda name, **kv: "<tool_call>" + name + "".join(
    f"<arg_key>{k}</arg_key><arg_value>{v}</arg_value>" for k, v in kv.items()) + "</tool_call>"

CASES = [  # label, model output, expected [(name, keys | R, substring the refusal must contain)]
    ("good", "</think>Listing." + TC("terminal", command="ls /tmp"), [("terminal", ["command"], None)]),
    ("two good", "</think>" + TC("terminal", command="pwd") + TC("web_search", query="x", limit="3"),
     [("terminal", ["command"], None), ("web_search", ["query", "limit"], None)]),
    ("key not in schema (fail-closed)", "</think>" + TC("terminal", cmd="ls"), [("terminal", R, "not in the schema")]),
    ("A: nested, same tool",
     "Let me look at the timeline.<tool_call>execute_code<arg_key>code</arg_key><arg_value>import os\n"
     "hmm, first check when he last fired.</think><tool_call>execute_code<arg_key>code</arg_key>"
     "<arg_value>print(2)</arg_value></tool_call>",
     [("execute_code", R, '"code": "print(2)"')]),
    ("A: nested, other tool",
     "Defer the upload.<tool_call>execute_code<arg_key>code</arg_key><arg_value>x\nDo that quickly."
     "</think><tool_call>write_file<arg_key>path</arg_key><arg_value>/tmp/p.py</arg_value>"
     "<arg_key>content</arg_key><arg_value>print(3)</arg_value></tool_call>",
     [("execute_code", R, "appears to be write_file")]),
    ("B: abandoned terminal -> web_search",
     "</think><tool_call>terminal<arg_key>command</arg_key><arg_value># Not in the library.\n"
     "web_search<arg_key>limit</arg_key><arg_value>5</arg_value><arg_key>query</arg_key>"
     "<arg_value>Barsane Wali Radhe mp3</arg_value></tool_call>",
     [("terminal", R, 'appears to be web_search with arguments {"limit": 5, "query": "Barsane Wali Radhe mp3"}')]),
    ("prefix name is not a hit", "</think>" + TC("terminal", command="echo my_web_search<x>"),
     [("terminal", ["command"], None)]),
    ("content then call", "</think>I'll check.\n" + TC("execute_code", code="print('hi')"), [("execute_code", ["code"], None)]),
]


def whole(text):
    info = Parser(tok, req.tools).extract_tool_calls(text, req)
    return [(c.function.name, c.function.arguments) for c in info.tool_calls]


def streamed(text, clock=None):
    p = Parser(tok, req.tools)
    ids = tok.encode(text, add_special_tokens=False)
    names, args, prev, empties = {}, {}, "", 0
    for i in range(len(ids)):
        if clock: clock[0] += 1.0
        cur = tok.decode(ids[: i + 1])
        d = p.extract_tool_calls_streaming(prev, cur, cur[len(prev):], ids[:i], ids[: i + 1], [ids[i]], req)
        for tc in (d.tool_calls or []) if d else []:
            if tc.function and tc.function.name:
                names[tc.index] = names.get(tc.index, "") + tc.function.name  # clients append names too
            if tc.function and tc.function.arguments is not None:
                if tc.function.arguments == "": empties += 1
                args[tc.index] = args.get(tc.index, "") + tc.function.arguments
        prev = cur
    return [(names.get(k), args.get(k, "")) for k in sorted(set(names) | set(args))], empties


def check(label, got, want):
    ok = len(got) == len(want)
    for (gn, ga), (wn, wk, sub) in zip(got, want):
        try: a = json.loads(ga) if ga else {}
        except json.JSONDecodeError: a = {"<not json>": ga}
        if gn != wn: ok = False
        elif wk == R: ok = ok and R in a and (sub is None or sub in a[R])
        else: ok = ok and sorted(a) == sorted(wk)
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else f"\n     got {got}"))
    return ok


fails = 0
for label, text, want in CASES:
    fails += not check(f"whole    | {label}", whole(text), want)
    got, _ = streamed(text)
    fails += not check(f"streamed | {label}", got, want)

# keep-alive: a long buffered argument with a fake clock advancing 1 s per token
import importlib
mod = sys.modules[[k for k in sys.modules if k.endswith("glm47_repair") or "glm47_repair" in k][0]]
clock = [0.0]
real = mod.time.monotonic
mod.time.monotonic = lambda: clock[0]
long_text = "</think>" + TC("write_file", path="/tmp/big.txt", content="word " * 400)
got, empties = streamed(long_text, clock)
mod.time.monotonic = real
ka_ok = check("streamed | long call keeps alive", got, [("write_file", ["path", "content"], None)]) and empties >= 20
print(("PASS " if ka_ok else "FAIL ") + f"keep-alive deltas: {empties} (expect >= 20 over ~400 s)")
fails += not ka_ok
print("RESULT:", "PASS" if not fails else f"FAIL ({fails})")
sys.exit(1 if fails else 0)
