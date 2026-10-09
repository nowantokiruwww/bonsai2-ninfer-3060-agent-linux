#!/usr/bin/env python3
"""scripts/91-repeat-lock-probe.py — Phase 9.1：复读锁死（repeat-lock）回归门禁。

背景：见 PORTING-LEDGER L26。2026-10-07 的实战事故里，模型在上下文积累若干条
**完全相同的「工具调用 → 失败回执」配对**之后进入吸引子：逐字节重复同一条工具调用，
无视工具回执、无视 harness 的重复告警，永不自愈（现场连续 43 次）。
本探针用**小上下文**（1–3 K token）复现该吸引子，不依赖长上下文、不依赖真实 agent。

用法：
    python3 scripts/91-repeat-lock-probe.py                     # 默认扫 K=3..20
    python3 scripts/91-repeat-lock-probe.py --base http://127.0.0.1:8098
    python3 scripts/91-repeat-lock-probe.py --ks 3,4,6,10 --rounds 3

判定：
    对每个 K，先塞 K 条"完全相同的 edit 调用 + 完全相同的失败回执"，再让模型走
    --rounds 轮。任何一轮逐字节重现那条被反复失败的调用 ⇒ 该 K **LOCKED**。
    只要有一个 K 出现 LOCKED，整体 **FAIL**。

    期望（修好后）：K=3..20 全部 NOT locked，模型改换策略（read / bash / 别的 edit）。
    未修的现场（--no-thinking 且 --greedy）：K>=4 起全部 LOCKED。

退出码：0 = PASS，1 = FAIL，2 = 用法/连接错误。
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

SYS = ("You are a coding agent. Read a file before editing it. "
       "Use the edit tool for targeted changes. Check the tool result before continuing.")
TASK = '把 /tmp/a.html 里第 10 行的 x2=-8 改成 x2="-8"（加双引号）'
FP = "/tmp/a.html"

# 那条"被反复失败的调用"：old_string 缺引号、new_string 带引号，正是它本该成功的形态。
CALL = {
    "file_path": FP,
    "old_string": '    <line x1="5" y1="-40" x2=-8 y2="-40"/>',
    "new_string": '    <line x1="5" y1="-40" x2="-8" y2="-40"/>',
}
CALLS = json.dumps(CALL, ensure_ascii=False, separators=(",", ":"))
ERR = f'Error: old_string was not found in "{FP}"'
# 另一种失败回执：old==new，工具直接拒绝。
ERR_SAME = "Error: old_string and new_string must differ"

TOOLS = [
    {"type": "function", "function": {
        "name": "edit", "description": "Replace literal text in a file.",
        "parameters": {"type": "object", "properties": {
            "file_path": {"type": "string"}, "old_string": {"type": "string"},
            "new_string": {"type": "string"}},
            "required": ["file_path", "old_string", "new_string"]}}},
    {"type": "function", "function": {
        "name": "read", "description": "Read a file.",
        "parameters": {"type": "object", "properties": {
            "file_path": {"type": "string"}, "offset": {"type": "integer"},
            "limit": {"type": "integer"}}, "required": ["file_path"]}}},
    {"type": "function", "function": {
        "name": "bash", "description": "Run a shell command.",
        "parameters": {"type": "object", "properties": {
            "command": {"type": "string"}}, "required": ["command"]}}},
]


def history(k: int, err: str) -> list[dict]:
    h = [{"role": "system", "content": SYS}, {"role": "user", "content": TASK}]
    for i in range(k):
        h.append({"role": "assistant", "content": None, "tool_calls": [
            {"id": f"c{i}", "type": "function",
             "function": {"name": "edit", "arguments": CALLS}}]})
        h.append({"role": "tool", "tool_call_id": f"c{i}", "content": err})
    return h


def post(base: str, body: dict, timeout: float) -> tuple[dict, float]:
    req = urllib.request.Request(f"{base}/v1/chat/completions",
                                data=json.dumps(body).encode(),
                                headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.load(resp)
    return data, time.time() - t0


def classify(msg: dict) -> tuple[str, bool, str]:
    """-> (label, locked, raw_snippet)"""
    calls = msg.get("tool_calls") or []
    if not calls:
        return "TEXT-ONLY", False, (msg.get("content") or "")[:80]
    fn = calls[0].get("function") or {}
    name, raw = fn.get("name") or "<none>", fn.get("arguments") or ""
    if name == "edit":
        try:
            a = json.loads(raw)
        except Exception:
            return "EDIT-UNPARSEABLE", False, raw[:80]
        if a.get("old_string") == a.get("new_string"):
            return "EDIT-SAME(old==new)", False, raw[:80]
        if a == CALL:
            return "LOCKED(byte-identical repeat)", True, raw[:80]
        return "EDIT-OTHER", False, raw[:80]
    return f"OK({name})", False, raw[:80]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8098")
    ap.add_argument("--model", default="bonsai2-27b")
    ap.add_argument("--ks", default="3,4,5,6,8,12,16,20",
                    help="要扫的 K 列表（逗号分隔）")
    ap.add_argument("--rounds", type=int, default=3, help="每个 K 连续走几轮")
    ap.add_argument("--max-tokens", type=int, default=900)
    ap.add_argument("--timeout", type=float, default=600.0)
    ap.add_argument("--err", choices=("notfound", "same"), default="notfound",
                    help="反复出现的失败回执形态")
    args = ap.parse_args()

    err = ERR if args.err == "notfound" else ERR_SAME
    ks = [int(x) for x in args.ks.split(",") if x.strip()]

    print(f"# 复读锁死探针 base={args.base} model={args.model} "
          f"rounds={args.rounds} err={args.err}")
    print(f"{'K':>3} {'prompt':>7} {'out':>5} {'sec':>6}  rounds")

    failures: list[int] = []
    for k in ks:
        h = history(k, err)
        labels, last, dt = [], 0, 0.0
        for _ in range(args.rounds):
            try:
                data, dt = post(args.base, {
                    "model": args.model, "messages": h,
                    "max_tokens": args.max_tokens, "tools": TOOLS}, args.timeout)
            except (urllib.error.URLError, OSError) as exc:
                print(f"[fail] 连不上 {args.base}: {exc}", file=sys.stderr)
                return 2
            msg = data["choices"][0]["message"]
            last = data["usage"]["completion_tokens"]
            label, locked, raw = classify(msg)
            labels.append(label)
            if locked:
                failures.append(k)
            # 把这一轮的结果回灌，模拟真实 agent 回路
            h.append({"role": "assistant", "content": msg.get("content"),
                      "tool_calls": msg.get("tool_calls")})
            if msg.get("tool_calls"):
                h.append({"role": "tool",
                          "tool_call_id": msg["tool_calls"][0].get("id"),
                          "content": err})
        mark = "  <== LOCKED" if any(l.startswith("LOCKED") for l in labels) else ""
        print(f"{k:>3} {data['usage']['prompt_tokens']:>7} {last:>5} {dt:>6.1f}  "
              f"{labels}{mark}")

    if failures:
        print(f"\n[FAIL] K={failures} 进入复读锁死吸引子。"
              f"检查服务配置：--greedy 必须不在，采样（--temperature/--top-p/--top-k）应生效；"
              f"`--default-thinking-budget` 是收口机制而非质量帽，必须与 max_tokens 配对"
              f"（预算 + 工具调用载荷 ≤ max_tokens，见 L27）。")
        return 1
    print("\n[PASS] 所有 K 均未锁死，模型会改换策略。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
