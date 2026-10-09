#!/usr/bin/env python3
"""92-thinking-throughput.py —— 从 ninfer 的 request.jsonl 里量化
「思考预算 ↔ 投机接受率 ↔ decode 速度」这条前沿。

背景（PORTING-LEDGER L26/L27）：
  打开思考后，思考文本是高熵散文，dflash2 草稿模型预测不了，
  投机接受率从 95%+ 崩到 18-43%，decode 从 ~240 tok/s 掉到 ~50-90 tok/s。
  本脚本把这件事变成可复现的数字，用来比较不同的 --default-thinking-budget /
  --draft-tokens 组合，并在 Phase 2 的矩阵实测里给出判据。

只用标准库（本机 python3 无 pip / 无 venv）。

用法:
  python3 scripts/92-thinking-throughput.py [--jsonl PATH] [--since-unix-ms N]
                                            [--server-instance ID] [--csv OUT.csv]
                                            [--label TEXT]

判据口径:
  * decode tok/s = result.completion_tokens / timings_seconds.decode
  * 接受率       = speculative.accepted_tokens / speculative.drafted_tokens
  * 思考 token   = result.model_thinking_tokens
  * 只统计 timings_seconds.decode > 0 且 completion_tokens > 0 的样本
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import statistics
import sys

# 历史默认值是当时那台机器的部署根。现在 request.jsonl 落在仓库的 logs/，
# 所以默认改成仓库相对路径；指向别处用 --jsonl。
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_JSONL = os.path.join(REPO_ROOT, "logs", "request.jsonl")


def load(path):
    """按行读 jsonl，坏行跳过（记录条数）。"""
    rows, bad = [], 0
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                bad += 1
    return rows, bad


def pair_requests(rows, since_ms=None, instance=None):
    """把 request_start / request_done 配对。

    日志里没有显式 request id，但同一 server_instance_id 内
    start 与 done 严格交替（并发度为 1），因此按顺序配对可靠。
    """
    starts = collections.defaultdict(list)
    pairs = []
    for r in rows:
        ev = r.get("event")
        inst = r.get("server_instance_id")
        if instance and inst != instance:
            continue
        ts = r.get("timestamp_unix_ms") or 0
        if since_ms and ts and ts < since_ms:
            continue
        if ev == "request_start":
            starts[inst].append(r)
        elif ev == "request_done":
            queue = starts.get(inst) or []
            st = queue.pop(0) if queue else None
            pairs.append((st, r))
    return pairs


def thinking_of(start, done):
    """返回 (enable_thinking, budget) —— done 优先，缺失时回落 start。"""
    enable, budget = None, None
    for src in (start, done):
        if not src:
            continue
        req = src.get("request") or {}
        res = src.get("result") or {}
        if enable is None and "enable_thinking" in req:
            enable = req.get("enable_thinking")
        if budget is None:
            b = req.get("effective_thinking_budget")
            if b is None:
                b = res.get("effective_thinking_budget")
            if b is not None:
                budget = b
    return enable, budget


def sample_of(start, done):
    """抽出一条可比较的样本；不合格返回 None。"""
    res = done.get("result") or {}
    tim = done.get("timings_seconds") or {}
    spec = done.get("speculative") or {}

    completion = res.get("completion_tokens") or 0
    decode_s = tim.get("decode") or 0.0
    if completion <= 0 or decode_s <= 0:
        return None

    drafted = spec.get("drafted_tokens") or 0
    accepted = spec.get("accepted_tokens") or 0
    acceptance = (accepted / drafted) if drafted else None

    enable, budget = thinking_of(start, done)
    req = (start or done).get("request") or {}

    return {
        "ts_ms": done.get("timestamp_unix_ms") or 0,
        "decode_tok_s": completion / decode_s,
        "completion_tokens": completion,
        "thinking_tokens": res.get("model_thinking_tokens") or 0,
        "acceptance": acceptance,
        "drafted": drafted,
        "accepted": accepted,
        "draft_window": spec.get("draft_window") or 0,
        "backend": spec.get("backend") or "?",
        "finish_reason": res.get("finish_reason") or "?",
        "enable_thinking": enable,
        "budget": budget,
        "ttft_s": tim.get("ttft") or 0.0,
        "tool_count": req.get("tool_count") or 0,
        "message_count": req.get("message_count") or 0,
        "instance": done.get("server_instance_id"),
        # 有效产出速度：思考 token 是用户要等、但不产生有效载荷的部分
        "useful_tok_s": (
            completion / (tim.get("total") or decode_s)
            if completion else 0.0
        ),
    }


def bucket_key(s):
    """按「思考开关 / 预算 / 草稿窗口」分桶 —— 这正是要比较的三个维度。"""
    think = "thinking off" if s["enable_thinking"] is False else "thinking on"
    budget = s["budget"] if s["budget"] is not None else "no-cap"
    return (think, str(budget), f"K={s['draft_window']}", s["backend"])


def med(vals):
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


def fmt(v, nd=1, suffix=""):
    if v is None:
        return "  --  "
    return f"{v:,.{nd}f}{suffix}"


def report(samples, label="", csv_out=None):
    print(f"样本数: {len(samples)}  {label}")
    if not samples:
        return

    groups = collections.OrderedDict()
    for s in samples:
        groups.setdefault(bucket_key(s), []).append(s)

    hdr = (f"{'思考':<12} {'预算':>8} {'草稿':>5} {'n':>4} "
           f"{'decode中位':>11} {'接受率中位':>11} {'思考tok中位':>11} "
           f"{'输出tok中位':>11} {'TTFT中位':>9}")
    print()
    print(hdr)
    print("-" * len(hdr))
    rows = []
    for key, g in sorted(groups.items(), key=lambda kv: -med([x["decode_tok_s"] for x in kv[1]])):
        think, budget, draft, backend = key
        acc = med([x["acceptance"] * 100 for x in g])
        row = {
            "thinking": think,
            "budget": budget,
            "draft": draft,
            "backend": backend,
            "n": len(g),
            "decode_tok_s_median": med([x["decode_tok_s"] for x in g]),
            "acceptance_pct_median": acc,
            "thinking_tokens_median": med([x["thinking_tokens"] for x in g]),
            "completion_tokens_median": med([x["completion_tokens"] for x in g]),
            "ttft_s_median": med([x["ttft_s"] for x in g]),
        }
        rows.append(row)
        print(f"{think:<12} {budget:>8} {draft:>5} {len(g):>4} "
              f"{fmt(row['decode_tok_s_median'],1):>11} "
              f"{fmt(acc,1,'%'):>11} "
              f"{fmt(row['thinking_tokens_median'],0):>11} "
              f"{fmt(row['completion_tokens_median'],0):>11} "
              f"{fmt(row['ttft_s_median'],2,'s'):>9}")

    # 收口情况：思考开着时最怕 finish_reason=length（烧光不发工具调用）
    print()
    print("finish_reason 分布（按思考开关）:")
    for flag in (True, False):
        sub = [s for s in samples if s["enable_thinking"] is flag]
        if not sub:
            continue
        dist = collections.Counter(s["finish_reason"] for s in sub)
        name = "thinking on " if flag else "thinking off"
        total = len(sub)
        parts = ", ".join(f"{k} {v} ({v*100//total}%)"
                          for k, v in dist.most_common())
        print(f"  {name} n={total:<4} {parts}")

    if csv_out:
        with open(csv_out, "w") as fh:
            cols = list(rows[0].keys()) if rows else []
            fh.write(",".join(cols) + "\n")
            for r in rows:
                fh.write(",".join(
                    "" if r[c] is None else str(r[c]) for c in cols) + "\n")
        print(f"\n已写 CSV: {csv_out}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jsonl", default=DEFAULT_JSONL)
    ap.add_argument("--since-unix-ms", type=int, default=None,
                    help="只看这个时间戳之后的请求（用来隔离某次重启之后的样本）")
    ap.add_argument("--server-instance", default=None,
                    help="只统计某个 server_instance_id（隔离到单次启动）")
    ap.add_argument("--csv", default=None)
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    if not os.path.exists(args.jsonl):
        print(f"找不到 {args.jsonl}", file=sys.stderr)
        return 2

    rows, bad = load(args.jsonl)
    pairs = pair_requests(rows, args.since_unix_ms, args.server_instance)
    samples = [s for s in (sample_of(a, b) for a, b in pairs) if s]

    print(f"日志: {args.jsonl}")
    print(f"事件行: {len(rows)}（坏行 {bad}）  start/done 配对: {len(pairs)}  可用样本: {len(samples)}")
    if args.server_instance:
        print(f"限定 instance: {args.server_instance}")
    if args.since_unix_ms:
        print(f"限定起始时间戳: {args.since_unix_ms}")

    report(samples, args.label, args.csv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
