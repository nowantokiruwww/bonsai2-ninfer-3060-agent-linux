#!/usr/bin/env python3
# agent/correctness_control.py — 控制实验：先判断"引擎本身是否可复现"，再谈投机是否无损
#
# 背景：agent/agent_accept.py correctness 跑出
#   P1_repeat（复读密集）两臂逐字节相同；P2_normal（普通问答）两臂不同。
# 在把结论写成"投机解码有损"之前，必须先排除另一种可能：**引擎在同配置下本身就不可复现**。
# 本脚本对每个臂把同一个 prompt 连发 N 次：
#   * 臂内 N 次结果不一致 → 引擎/服务本身非确定 → 与投机无关；
#   * 臂内一致但两臂不一致 → 投机路径确实改变了输出；
#   * 两臂一致              → 之前的差异来自别的因素（温度/flags/上下文残留）。
#
# 用法：python3 agent/correctness_control.py

import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request

SERVE = os.environ.get("NINFER_SERVE", "")
MODEL = os.environ.get("NINFER_MODEL_PATH", "")
KV_CAP = os.environ.get("KV_CAPACITY", "")
KV_DT = os.environ.get("KV_DTYPE", "")
REPEATS = int(os.environ.get("CTRL_REPEATS", "3"))
MAXTOK = int(os.environ.get("CTRL_MAX_TOK", "420"))
LOGDIR = os.environ.get("CTRL_LOGDIR", "evidence/agent/control")

P1 = ("Repeat the following sentence exactly twelve times, one per line, then say DONE: "
      "The quick brown fox jumps over the lazy dog. " * 12)
P2 = ("Explain in two sentences why mixture-of-experts models use fewer active "
      "parameters than dense models of the same size.")
PROMPTS = {"P1_repeat": P1, "P2_normal": P2}

ARMS = [("baseline", []),
        ("dflash2_k7", ["--spec", "dflash2", "--draft-tokens", "7"])]

EXTRA = os.environ.get("CTRL_SERVE_EXTRA",
                       "--max-concurrency 1 --no-thinking --greedy").split()


def start(flags, port, log):
    cmd = [SERVE, MODEL, "--host", "127.0.0.1", "--port", str(port),
           "--max-context", KV_CAP, "--kv-capacity", KV_CAP, "--kv-dtype", KV_DT] + EXTRA + flags
    lf = open(log, "w", encoding="utf-8", errors="replace")
    lf.write("### " + " ".join(cmd) + "\n"); lf.flush()
    p = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, env=os.environ.copy())
    t0 = time.time()
    while time.time() - t0 < 600:
        if p.poll() is not None:
            return None
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/models", timeout=3) as r:
                if r.status == 200:
                    return p
        except Exception:
            time.sleep(2)
    p.kill(); return None


def stop(p):
    if not p:
        return
    p.send_signal(subprocess.signal.SIGINT)
    try:
        p.wait(timeout=90)
    except subprocess.TimeoutExpired:
        p.kill(); p.wait(timeout=30)
    time.sleep(5)


def ask(port, ptext):
    body = json.dumps({"model": os.environ.get("NINFER_MODEL_ID", "bonsai2-27b"),
                       "messages": [{"role": "user", "content": ptext}],
                       "max_tokens": MAXTOK, "temperature": 0}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=body, headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=900) as r:
        d = json.loads(r.read().decode("utf-8", "replace"))
    dt = time.time() - t0
    txt = ((d.get("choices") or [{}])[0].get("message") or {}).get("content", "")
    ct = (d.get("usage") or {}).get("completion_tokens", 0)
    return {"md5": hashlib.md5(txt.encode()).hexdigest(), "chars": len(txt),
            "tokens": ct, "sec": round(dt, 2), "text": txt}


def main():
    if not (SERVE and MODEL and KV_CAP and KV_DT):
        print("需要 NINFER_SERVE / NINFER_MODEL_PATH / KV_CAPACITY / KV_DTYPE", file=sys.stderr)
        return 2
    os.makedirs(LOGDIR, exist_ok=True)
    out = {"repeats": REPEATS, "max_tokens": MAXTOK, "serve_extra": EXTRA, "arms": {}}
    for name, flags in ARMS:
        port = 8097 if name == "baseline" else 8098
        p = start(flags, port, os.path.join(LOGDIR, f"{name}.log"))
        if not p:
            out["arms"][name] = {"error": "服务未就绪"}
            print(f"[{name}] 服务未就绪")
            continue
        try:
            res = {}
            for pn, pt in PROMPTS.items():
                runs = [ask(port, pt) for _ in range(REPEATS)]
                md5s = [r["md5"] for r in runs]
                res[pn] = {"md5s": md5s, "stable": len(set(md5s)) == 1,
                           "chars_head": runs[0]["chars"],
                           "tok_s": round(runs[0]["tokens"] / runs[0]["sec"], 1) if runs[0]["sec"] else None,
                           "text_head": runs[0]["text"][:100]}
                print(f"[{name}] {pn}: stable={res[pn]['stable']} md5s={[m[:8] for m in md5s]}")
            out["arms"][name] = res
        finally:
            stop(p)
    # 判定
    if "baseline" in out["arms"] and "dflash2_k7" in out["arms"]:
        v = {}
        for pn in PROMPTS:
            b = out["arms"]["baseline"].get(pn, {})
            s = out["arms"]["dflash2_k7"].get(pn, {})
            v[pn] = {"baseline_stable": b.get("stable"), "spec_stable": s.get("stable"),
                     "across_equal": (b.get("md5s") or [None])[0] == (s.get("md5s") or [None])[0]}
        out["verdict"] = v
        for pn, d in v.items():
            if d["baseline_stable"] and d["spec_stable"] and not d["across_equal"]:
                out.setdefault("conclusion", []).append(
                    f"{pn}: 两臂各自可复现，但彼此不同 → 投机路径改变了输出")
            elif not d["baseline_stable"]:
                out.setdefault("conclusion", []).append(
                    f"{pn}: 基线臂自身就不可复现 → 引擎/服务非确定，与投机无关")
            elif d["across_equal"]:
                out.setdefault("conclusion", []).append(f"{pn}: 两臂一致")
    p = os.path.join(LOGDIR, "correctness-control.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("\n=== 结论 ===")
    for c in out.get("conclusion", []):
        print(" -", c)
    print("->", p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
