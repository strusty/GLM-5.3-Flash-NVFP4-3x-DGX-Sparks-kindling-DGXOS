"""glm47_repair: kindling's glm47_failclosed, plus recovery of tool calls the model nested or
abandoned, and keep-alives while a buffered call is being written. Registered as `glm47_repair`.

## What it adds to glm47_failclosed

Observed on real agent traffic (5 of 5,094 tool calls over two days):

A. A call opened inside the think block. The model writes `<tool_call>NAME<arg_key>...` while it is
   still reasoning (the engine's (REASONING, TOOL_START) transition silently ends reasoning there),
   keeps reasoning, then writes the real call after `</think>`. The engine takes the first
   `<tool_call>`, so the argument swallows the reasoning, the `</think>` and the whole real call.
   Upstream executes it with reasoning text as its argument.
B. An abandoned call. `<tool_call>terminal<arg_key>command</arg_key><arg_value># comment\nweb_search
   <arg_key>limit</arg_key>...`: the model switched tools without closing the first, and the engine
   merged both into one call. Upstream ran the merge in bash.

At TOOL_CALL_END (fail-closed already buffers arguments) this parser looks for the call the model
meant: the text after `</think><tool_call>` (A), or an offered tool name directly followed by
`<arg_key>` inside an argument value (B). When it finds one that passes the fail-closed checks on its
own (offered name, JSON object, schema keys), the outer call is REFUSED with a retryable reason that
spells out the recovered call, so the model re-issues it in one step.

It never executes text recovered from inside another call's arguments: that text could be a file's
content (an agent writing parser tests writes exactly these strings), and turning content into an
action is worse than a refusal. The reason also tells the model how to write such markup literally.

## Keep-alive

Arguments are buffered until the call ends, so a long call (a big write_file) sends nothing while it
is written. Agent clients typically drop a stream after a few minutes without a chunk. While a call is buffered, an empty
argument delta goes out every GLM47_KEEPALIVE_S seconds (default 5; 0 turns it off). Clients append
"" to the arguments; vLLM sends a chunk for any delta a parser returns.

GLM47_REPAIR=0 leaves recovery off (plain fail-closed with keep-alives).
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import time

from vllm.entrypoints.generate.base.protocol import DeltaFunctionCall, DeltaToolCall
from vllm.logger import init_logger
from vllm.parser.engine.adapters import make_adapters
from vllm.tool_parsers.abstract_tool_parser import ToolParserManager

logger = init_logger(__name__)

_FC_PATH = os.environ.get("GLM47_FAILCLOSED_PATH", "/usr/local/share/glm47_failclosed.py")
_spec = importlib.util.spec_from_file_location("glm47_failclosed_base", _FC_PATH)
_fc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fc)  # also registers glm47_failclosed, which is harmless

REPAIR = os.environ.get("GLM47_REPAIR", "1") not in ("0", "false", "False")
KEEPALIVE_S = float(os.environ.get("GLM47_KEEPALIVE_S", "5"))

ARG_KEY = "<arg_key>"
NAME_CHAR = re.compile(r"[A-Za-z0-9_.-]")
# Case A's signature: the reasoning close, then a new call to a name, then its first key.
NESTED_RE = re.compile(r"</think>\s*<tool_call>\s*([A-Za-z_][A-Za-z0-9_.-]{0,63})\s*<arg_key>")


class Glm47RepairParser(_fc.Glm47FailClosedParser):
    def __init__(self, tokenizer, tools=None, **kwargs) -> None:
        super().__init__(tokenizer, tools, **kwargs)
        self._last_emit: dict[int, float] = {}

    def _reset(self, *args, **kwargs) -> None:
        super()._reset(*args, **kwargs)
        self._last_emit = {}

    # ── keep-alive while a buffered call is written ────────────────────

    def _handle_arg_chunk(self, event, deltas) -> None:
        super()._handle_arg_chunk(event, deltas)
        if KEEPALIVE_S <= 0 or self._stream_arg_deltas:
            return
        idx = event.tool_index
        if not (0 <= idx < len(self._tool_slots)) or not self._tool_slots[idx].name_sent:
            return
        now = time.monotonic()
        last = self._last_emit.get(idx)
        if last is None or any(d.index == idx for d in deltas):
            self._last_emit[idx] = now  # the name (or another delta) just went out
            return
        if now - last >= KEEPALIVE_S:
            self._last_emit[idx] = now
            deltas.append(DeltaToolCall(index=idx, function=DeltaFunctionCall(arguments="")))

    # ── recovery ──────────────────────────────────────────────────────

    def _json_for(self, name: str, raw: str) -> str | None:
        converter = self._arg_converter
        if converter is None:
            return None
        try:
            text = converter(raw, False)
        except (json.JSONDecodeError, ValueError, TypeError):
            return None
        return self._fix_arg_types(text, name) if text else text

    def _recover(self, idx: int) -> tuple[str, str, str] | None:
        """(kind, name, arguments JSON) of the call the model meant, or None."""
        raw = self._tool_slots[idx].args or ""
        found: tuple[str, str, str] | None = None  # kind, name, raw args after the name
        m = None
        for m in NESTED_RE.finditer(raw):
            pass  # the last nested call is the one the model finished
        if m is not None:
            found = ("nested", m.group(1), raw[m.end() - len(ARG_KEY):])
        else:
            best = None
            for name in self._offered_names():
                start = 0
                while (j := raw.find(name + ARG_KEY, start)) != -1:
                    start = j + 1
                    if j == 0 or NAME_CHAR.match(raw[j - 1]):
                        continue  # the call's own first key, or the tail of a longer name
                    if raw.rfind("<arg_value>", 0, j) <= raw.rfind("</arg_value>", 0, j):
                        continue  # not inside an argument value
                    if best is None or j < best[0]:
                        best = (j, name)
                    break
            if best is not None:
                found = ("abandoned", best[1], raw[best[0] + len(best[1]):])
        if found is None:
            return None
        kind, name, args_raw = found
        if args_raw.endswith("</tool_call>"):
            args_raw = args_raw[: -len("</tool_call>")]
        args_json = self._json_for(name, args_raw)
        if args_json is None or self._reject_reason(name, args_json) is not None:
            return None  # what we found is not a valid call either; plain fail-closed decides
        return kind, name, args_json

    def _refuse(self, idx: int, deltas, reason: str) -> None:
        """Re-offer the call under its own name with the sentinel, as fail-closed does."""
        slot = self._tool_slots[idx]
        self._flush_arg_converter(idx)
        emitted = (slot.name or self._try_extract_name(idx) or "").strip()
        name = self._resolve_name(emitted) or (emitted if _fc.NAME_RE.match(emitted) else "unknown_tool")
        slot.name = name
        slot.name_sent = True
        self._ensure_tool_id(slot, name)
        arguments = json.dumps({_fc.SENTINEL_KEY: reason}, ensure_ascii=False)
        slot.streamed_json = arguments
        self._refused[slot.id] = arguments
        deltas.append(DeltaToolCall(index=idx, id=slot.id, type="function",
                                    function=DeltaFunctionCall(name=name, arguments=arguments)))

    def _handle_tool_end(self, event, deltas) -> None:
        idx = event.tool_index
        was_sent = 0 <= idx < len(self._tool_slots) and self._tool_slots[idx].name_sent
        start = len(deltas)
        try:
            self._tool_end(event, deltas)
        finally:
            # OpenAI streaming sends a call's name (and id) once; fail-closed's refusal re-sends
            # them, and clients that concatenate strings (the openai SDK's stream helper) would
            # read "terminalterminal". Later deltas for a sent call carry arguments only.
            if was_sent:
                for d in deltas[start:]:
                    if d.index == idx and d.function is not None:
                        d.function.name = None
                        d.id = None
                        d.type = None

    def _tool_end(self, event, deltas) -> None:
        idx = event.tool_index
        if REPAIR and _fc.ENABLED and 0 <= idx < len(self._tool_slots):
            found = self._recover(idx)
            if found is not None:
                kind, name, args_json = found
                outer = (self._tool_slots[idx].name or "").strip() or "this call"
                how = ("was opened inside your reasoning, so its arguments swallowed the rest of the "
                       "reasoning and the call you wrote after it" if kind == "nested" else
                       "was left unfinished when you started another call inside its arguments")
                reason = (f"Refused, nothing was run: this {outer} call {how}. The call you meant "
                          f"appears to be {name} with arguments {args_json}. Issue that call on its own. "
                          f"(To write tool-call markup literally inside an argument, split the tags, "
                          f"e.g. '</th' + 'ink>'.)")
                logger.warning("glm47 repair: %s %s call holds a %s call; refused with recovery hint",
                               kind, outer, name)
                self._refuse(idx, deltas, reason)
                return
        super()._handle_tool_end(event, deltas)


_REASONING_ADAPTER, _TOOL_ADAPTER = make_adapters(Glm47RepairParser)


@ToolParserManager.register_module("glm47_repair")
class Glm47RepairToolParser(_TOOL_ADAPTER):  # type: ignore[valid-type, misc]
    supports_required_and_named = False
    structural_tag_model = "glm_4_7"
