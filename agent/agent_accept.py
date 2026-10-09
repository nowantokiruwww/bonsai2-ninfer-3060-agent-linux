#!/usr/bin/env python3
# agent/agent_accept.py — agent 体验验收（纯标准库；本机无 pip / 无 venv）
#
# 为什么不用 bench 的跑分口径：旧移植的"隔断"在于——测试测 256 token 短问答，
# 真实负载却是 `19 messages / tools 63 / prompt 21,629 / cache 21,371 (98.8%)` 的
# 多轮工具调用 agent 回路。所以验收必须长成 agent 的形状。
#
# 模式：
#   loop        主验收：≥N 轮真实工具调用回路（工具 schema + 长 system prompt）
#   context     长上下文扫描：TTFT / decode 随上下文增长如何退化
#   stability   长时间稳定性：N 轮内 decode/TTFT 是否漂移、显存是否上涨
#   correctness 正确性：无投机 vs dflash2 投机，输出逐字节/MD5 一致（投机无损）
#   all         依次跑 loop + context + stability（correctness 需自己起两个服务，单独跑）
#
# 用法：python3 agent/agent_accept.py loop|context|stability|correctness|all

import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOST = os.environ.get("NINFER_HOST", "127.0.0.1")
PORT = int(os.environ.get("NINFER_PORT", "8098"))
BASE = f"http://{HOST}:{PORT}"
MODEL_ID = os.environ.get("NINFER_MODEL_ID", "bonsai2-27b")
OUTDIR = os.environ.get("ACCEPT_OUTDIR", "results")
LOGDIR = os.environ.get("ACCEPT_LOGDIR", "evidence/agent")
N_TOOLS = int(os.environ.get("ACCEPT_N_TOOLS", "63"))
TURNS = int(os.environ.get("ACCEPT_TURNS", "50"))
MAX_TOK = int(os.environ.get("ACCEPT_MAX_TOK", "120"))
CTX_LADDER = [int(x) for x in os.environ.get(
    "ACCEPT_CTX_LADDER", "8192 16384 24576 32768 49152").split()]

SERVE = os.environ.get("NINFER_SERVE", "")
MODEL = os.environ.get("NINFER_MODEL_PATH", "")
# correctness 模式自己起服务时必须带上这些，否则两臂不公平：
#   实测教训：第一次 correctness 跑出 lossless=False 且 P1_repeat 两臂输出都是空字符串，
#   根因是两臂都没加 --no-thinking/--greedy —— 思考模式开着时正文内容不在
#   choices[0].message.content 里（于是 MD5 变成空串的 d41d8cd98f00…），
#   而且采样未被强制成贪婪，两臂自然不同。**这是测试公平性问题，不是投机解码的问题。**
SERVE_EXTRA = os.environ.get(
    "ACCEPT_SERVE_EXTRA", "--max-concurrency 1 --no-thinking --greedy").split()

SENT = "The quick brown fox jumps over the lazy dog near the river bank at dawn. "


# --------------------------------------------------------------------------- HTTP
def post(payload, timeout=900, path="/v1/chat/completions"):
    req = urllib.request.Request(BASE + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def stream_ttft(payload, timeout=900):
    """流式测 TTFT 与 decode。返回 dict。"""
    body = dict(payload)
    body["stream"] = True
    body["stream_options"] = {"include_usage": True}
    req = urllib.request.Request(BASE + "/v1/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    ttft = None
    first_done = None
    text = []
    usage = {}
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                obj = json.loads(data)
            except Exception:
                continue
            if obj.get("usage"):
                usage = obj["usage"]
            ch = obj.get("choices") or []
            if not ch:
                continue
            delta = ch[0].get("delta") or {}
            piece = delta.get("content") or ""
            if piece:
                text.append(piece)
                if ttft is None:
                    ttft = time.time() - t0
                first_done = time.time() - t0
    total = time.time() - t0
    ct = usage.get("completion_tokens", 0)
    decode = (ct / (total - ttft)) if (ttft and total > ttft and ct) else None
    return {"ttft_sec": round(ttft, 3) if ttft else None,
            "total_sec": round(total, 3),
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": ct,
            "decode_tok_s": round(decode, 1) if decode else None,
            "text": "".join(text),
            "md5": hashlib.md5("".join(text).encode("utf-8")).hexdigest(),
            "cached_tokens": (usage.get("prompt_tokens_details") or {}).get("cached_tokens")}


def health():
    try:
        with urllib.request.urlopen(BASE + "/v1/models", timeout=5) as r:
            return r.status == 200
    except Exception:
        return False


# --------------------------------------------------------------------------- 造场景
def make_tools(n):
    """生成 n 个结构不同但都合法的工具 schema（贴近真实 agent 的工具面）。"""
    tools = []
    kinds = [
        ("read_file", {"path": {"type": "string"}, "offset": {"type": "integer"}}),
        ("write_file", {"path": {"type": "string"}, "content": {"type": "string"}}),
        ("search_web", {"query": {"type": "string"}, "limit": {"type": "integer"}}),
        ("run_shell", {"cmd": {"type": "string"}, "cwd": {"type": "string"}}),
        ("list_dir", {"path": {"type": "string"}, "recursive": {"type": "boolean"}}),
        ("git_diff", {"rev": {"type": "string"}, "stat_only": {"type": "boolean"}}),
        ("http_get", {"url": {"type": "string"}, "headers": {"type": "object"}}),
    ]
    for i in range(n):
        base, props = kinds[i % len(kinds)]
        name = f"{base}_{i}"
        tools.append({
            "type": "function",
            "function": {
                "name": name,
                "description": f"Tool #{i}: {base} helper for the agent loop.",
                "parameters": {"type": "object",
                               "properties": props,
                               "required": [k for k in props][:1],
                               "additionalProperties": False},
            },
        })
    return tools


def system_prompt(target_tokens):
    """把 system prompt 撑到约 target_tokens（约 4 字符/token）。"""
    head = ("You are a precise tool-using agent operating on a Linux workstation. "
            "Call exactly one tool per turn, then wait for the tool result. "
            "Never invent a tool name outside the provided schema.\n\n")
    filler = ("Operational policy: prefer the narrowest tool that answers the question; "
              "batch nothing; verify paths before writing; keep tool arguments minimal.\n")
    body = "".join(f"[rule {i}] {filler}" for i in range(max(1, target_tokens // 24)))
    return head + body


def long_user_prompt(target_tokens):
    # 英文约 4 字符/token；SENT 长 70 字符 → 约每 17.5 个字符 1 token
    return ("Below is a long reference text. Read it carefully.\n" +
            SENT * max(1, target_tokens // 17) +
            "\n\nAnswer with a single word: what animal?")


# --------------------------------------------------------------- 服务起停（correctness 用）
def start_server(flags, port, logpath):
    env = os.environ.copy()
    cmd = [SERVE, MODEL, "--host", "127.0.0.1", "--port", str(port),
           "--max-context", os.environ["KV_CAPACITY"], "--kv-capacity", os.environ["KV_CAPACITY"],
           "--kv-dtype", os.environ["KV_DTYPE"]] + SERVE_EXTRA + flags
    lf = open(logpath, "w", encoding="utf-8", errors="replace")
    lf.write("### " + " ".join(cmd) + "\n")
    lf.flush()
    proc = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, env=env)
    t0 = time.time()
    while time.time() - t0 < 600:
        if proc.poll() is not None:
            return None
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/models", timeout=3) as r:
                if r.status == 200:
                    return proc
        except Exception:
            time.sleep(2)
    proc.kill()
    return None


def stop_server(proc):
    if not proc:
        return
    proc.send_signal(subprocess.signal.SIGINT)
    try:
        proc.wait(timeout=90)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait(timeout=30)
    time.sleep(5)


# --------------------------------------------------------------------------- 模式
def mode_loop(save, turns=TURNS):
    tools = make_tools(N_TOOLS)
    sys_p = system_prompt(2000)
    messages = [{"role": "system", "content": sys_p},
                {"role": "user", "content":
                 "Task: inspect the workspace. Call one tool per turn until instructed to stop."}]
    known = {t["function"]["name"] for t in tools}
    rec = {"mode": "loop", "turns_requested": turns, "n_tools": len(tools),
           "system_prompt_chars": len(sys_p), "turns": [], "started_at": time.strftime("%FT%T%z")}
    vram0 = _vram()
    ok_turns = valid_calls = bad_calls = 0
    for i in range(turns):
        payload = {"model": MODEL_ID, "messages": messages, "tools": tools,
                   "tool_choice": "auto", "max_tokens": MAX_TOK, "temperature": 0}
        t0 = time.time()
        try:
            resp = post(payload)
        except Exception as e:
            rec["turns"].append({"turn": i, "error": f"{type(e).__name__}: {e}"})
            break
        dt = time.time() - t0
        usage = resp.get("usage") or {}
        msg = ((resp.get("choices") or [{}])[0].get("message") or {})
        calls = msg.get("tool_calls") or []
        this_valid = this_bad = 0
        if calls:
            messages.append(msg)
            for tc in calls:
                name = ((tc.get("function") or {}).get("name") or "")
                args_raw = ((tc.get("function") or {}).get("arguments") or "")
                good = name in known
                try:
                    json.loads(args_raw) if args_raw else None
                    good = good and True
                except Exception:
                    good = False
                if good:
                    this_valid += 1
                else:
                    this_bad += 1
                messages.append({"role": "tool", "tool_call_id": tc.get("id"),
                                 "content": json.dumps({"status": "ok", "stub": True})})
        else:
            # 模型停下了：记下内容，并推一把继续，以便把轮数跑满
            content = msg.get("content") or ""
            messages.append({"role": "assistant", "content": content})
            messages.append({"role": "user", "content":
                             "Continue. Call the next tool."})
        ct = usage.get("completion_tokens", 0)
        rec["turns"].append({
            "turn": i, "wall_sec": round(dt, 3),
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": ct,
            "cached_tokens": (usage.get("prompt_tokens_details") or {}).get("cached_tokens"),
            "tool_calls": len(calls), "valid": this_valid, "invalid": this_bad,
            "text_head": (msg.get("content") or "")[:80],
        })
        ok_turns += 1
        valid_calls += this_valid
        bad_calls += this_bad
        if i % 10 == 0:
            print(f"  turn {i}: tok={ct} prompt={usage.get('prompt_tokens')} "
                  f"calls={len(calls)} wall={dt:.2f}s", flush=True)
    vram1 = _vram()
    rec.update({"turns_completed": ok_turns, "valid_tool_calls": valid_calls,
                "invalid_tool_calls": bad_calls,
                "vram_before_mib": vram0, "vram_after_mib": vram1,
                "finished_at": time.strftime("%FT%T%z")})
    _finish(rec, save)
    return rec


def mode_context(save):
    rec = {"mode": "context", "ladder": CTX_LADDER, "points": []}
    for ctx in CTX_LADDER:
        p = long_user_prompt(ctx)
        payload = {"model": MODEL_ID,
                   "messages": [{"role": "user", "content": p}],
                   "max_tokens": 64, "temperature": 0}
        try:
            r = stream_ttft(payload)
        except Exception as e:
            r = {"error": f"{type(e).__name__}: {e}"}
        r["target_context"] = ctx
        r.pop("text", None)
        rec["points"].append(r)
        print(f"  ctx~{ctx}: prompt={r.get('prompt_tokens')} ttft={r.get('ttft_sec')}s "
              f"decode={r.get('decode_tok_s')} tok/s", flush=True)
    _finish(rec, save)
    return rec


def mode_stability(save):
    rec = mode_loop_quiet(turns=max(TURNS, 50))
    rec["mode"] = "stability"
    ts = [t for t in rec["turns"] if "wall_sec" in t]
    if len(ts) >= 10:
        first = ts[:5]; last = ts[-5:]
        rec["drift"] = {
            "first5_mean_wall": round(sum(t["wall_sec"] for t in first) / len(first), 3),
            "last5_mean_wall": round(sum(t["wall_sec"] for t in last) / len(last), 3),
            "first5_mean_prompt_tokens": round(sum((t["prompt_tokens"] or 0) for t in first) / len(first), 1),
            "last5_mean_prompt_tokens": round(sum((t["prompt_tokens"] or 0) for t in last) / len(last), 1),
        }
    _finish(rec, save)
    return rec


def mode_loop_quiet(turns):
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rec = mode_loop(lambda *a, **k: None, turns=turns)
    return rec


def mode_correctness(save):
    if not SERVE or not MODEL:
        return {"mode": "correctness", "error": "需要 NINFER_SERVE / NINFER_MODEL_PATH"}
    if not os.environ.get("KV_CAPACITY") or not os.environ.get("KV_DTYPE"):
        return {"mode": "correctness",
                "error": "需要 KV_CAPACITY / KV_DTYPE（先跑 scripts/75-kv-gate.sh 拿实测值，禁止猜）"}
    prompts = {
        "P1_repeat": ("Repeat the following sentence exactly twelve times, one per line, "
                      "then say DONE: The quick brown fox jumps over the lazy dog. " * 12),
        "P2_normal": ("Explain in two sentences why mixture-of-experts models use fewer "
                      "active parameters than dense models of the same size."),
    }
    global BASE, PORT
    out = {"mode": "correctness", "arms": {}}
    arms = [("baseline", []),
            ("dflash2_k7", ["--spec", "dflash2", "--draft-tokens", "7"])]
    old_base, old_port = BASE, PORT
    try:
        for name, flags in arms:
            port = 8097 if name == "baseline" else 8098
            BASE, PORT = f"http://127.0.0.1:{port}", port
            log = os.path.join(LOGDIR, f"correctness-{name}.log")
            proc = start_server(flags, port, log)
            if not proc:
                out["arms"][name] = {"error": "服务未就绪"}
                continue
            try:
                res = {}
                for pname, ptext in prompts.items():
                    payload = {"model": MODEL_ID,
                               "messages": [{"role": "user", "content": ptext}],
                               "max_tokens": 420, "temperature": 0}
                    t0 = time.time()
                    r = post(payload)
                    dt = time.time() - t0
                    txt = ((r.get("choices") or [{}])[0].get("message") or {}).get("content", "")
                    ct = (r.get("usage") or {}).get("completion_tokens", 0)
                    res[pname] = {"md5": hashlib.md5(txt.encode("utf-8")).hexdigest(),
                                  "tokens": ct, "sec": round(dt, 2),
                                  "tok_s": round(ct / dt, 1) if dt else None,
                                  "head": txt[:120]}
                    print(f"  [{name}] {pname}: {res[pname]['tok_s']} tok/s "
                          f"md5={res[pname]['md5'][:12]}", flush=True)
                out["arms"][name] = res
            finally:
                stop_server(proc)
    finally:
        BASE, PORT = old_base, old_port
    if "baseline" in out["arms"] and "dflash2_k7" in out["arms"]:
        cmp_ = {}
        for pname in prompts:
            b = out["arms"]["baseline"].get(pname, {}).get("md5")
            s = out["arms"]["dflash2_k7"].get(pname, {}).get("md5")
            cmp_[pname] = {"identical": b == s, "baseline": b, "spec": s}
        out["comparison"] = cmp_
        out["lossless"] = all(v["identical"] for v in cmp_.values())
        print(f"\n=== 投机无损判定: {'PASS' if out['lossless'] else 'FAIL'} ===")
    _finish(out, save)
    return out


def _vram():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=index,uuid,memory.used",
                              "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=15).stdout
        return [l.strip() for l in out.strip().splitlines()]
    except Exception:
        return []


def _finish(rec, save):
    if not save:
        return
    os.makedirs(OUTDIR, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    p = os.path.join(OUTDIR, f"agent-{rec.get('mode','run')}-{ts}.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False, indent=2)
    print(f"-> {p}")


def main():
    os.makedirs(LOGDIR, exist_ok=True)
    mode = (sys.argv[1] if len(sys.argv) > 1 else "loop").lower()
    if mode in ("loop", "context", "stability") and not health():
        print(f"[fail] 服务未就绪: {BASE}/v1/models", file=sys.stderr)
        return 2
    if mode == "loop":
        mode_loop(True)
    elif mode == "context":
        mode_context(True)
    elif mode == "stability":
        mode_stability(True)
    elif mode == "correctness":
        mode_correctness(True)
    elif mode == "all":
        mode_loop(True); mode_context(True); mode_stability(True)
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
