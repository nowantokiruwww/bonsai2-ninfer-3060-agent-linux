#!/usr/bin/env python3
# agent/kvgate.py — KV (dtype, capacity) 可行性门禁（纯标准库）
#
# 为什么：bench 的 Windows 记录里 3060 必须显式给 --kv-capacity（--kv-capacity auto 会因
# dflash2 草稿权重 9.10 GiB 多留 1 GiB 而拒绝启动），而本机旧服务却在同一张 12G 卡上用
# --kv-capacity 76768 --kv-dtype rk2v4-e8 跑通过 —— 说明容量强依赖 dtype，24576 不是常量。
#
# 做法：对每个候选 --kv-dtype，在容量阶梯上二分，找出"能启动 + 连续 N 次请求无错"的最大容量。
# 判据：started(ready) AND smoke_ok。失败原因（引擎原文）必须留存。
#
# 输出：results/kv-feasibility.json

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

SERVE = os.environ["NINFER_SERVE"]
MODEL = os.environ["NINFER_MODEL_PATH"]
OUT = os.environ["KV_GATE_OUT"]
LOGDIR = os.environ["KV_GATE_LOGDIR"]
PORT = int(os.environ.get("KV_GATE_PORT", "8099"))
BASE = f"http://127.0.0.1:{PORT}"
MODEL_ID = os.environ.get("NINFER_MODEL_ID", "bonsai2-27b")

DTYPES = os.environ.get("KV_GATE_DTYPES", "int8 rk8v4 rk4v4-e8 rk2v4-e8").split()
LADDER = [int(x) for x in os.environ.get(
    "KV_GATE_LADDER", "8192 16384 24576 32768 49152 65536 76768").split()]
SPEC = os.environ.get("KV_GATE_SPEC", "dflash2")
DRAFT = os.environ.get("KV_GATE_DRAFT", "7")
EXTRA = os.environ.get("KV_GATE_EXTRA_FLAGS",
                       "--max-concurrency 1 --no-thinking --greedy").split()

SMOKE_N = int(os.environ.get("KV_GATE_SMOKE_N", "3"))
SMOKE_TOK = int(os.environ.get("KV_GATE_SMOKE_TOK", "256"))
READY_TIMEOUT = int(os.environ.get("KV_GATE_READY_TIMEOUT", "600"))

PROMPT = ("Explain in two sentences why mixture-of-experts models use fewer active "
          "parameters than dense models of the same size.")


def vram_used_mib():
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,memory.used", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=15).stdout
        return {int(l.split(",")[0]): int(l.split(",")[1]) for l in out.strip().splitlines()}
    except Exception:
        return {}


def desktop_present():
    for name in ("gnome-shell", "Xorg", "kwin_x11", "plasmashell"):
        if subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 0:
            return True
    return False


def wait_ready(proc, deadline):
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        try:
            with urllib.request.urlopen(BASE + "/v1/models", timeout=3) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(2)
    return False


def smoke():
    """连续 N 次请求；任一失败或输出为空即判失败。返回 (ok, detail)。"""
    texts = []
    for i in range(SMOKE_N):
        payload = json.dumps({
            "model": MODEL_ID,
            "messages": [{"role": "user", "content": PROMPT}],
            "max_tokens": SMOKE_TOK, "temperature": 0,
        }).encode()
        req = urllib.request.Request(BASE + "/v1/chat/completions", data=payload,
                                     headers={"Content-Type": "application/json"})
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                resp = json.loads(r.read().decode("utf-8", "replace"))
        except Exception as e:
            return False, f"req#{i} 失败: {type(e).__name__}: {e}"
        dt = time.time() - t0
        ct = (resp.get("usage") or {}).get("completion_tokens", 0)
        txt = ((resp.get("choices") or [{}])[0].get("message") or {}).get("content", "")
        if not txt or not ct:
            return False, f"req#{i} 输出为空 (completion_tokens={ct})"
        texts.append({"tok_s": round(ct / dt, 1) if dt else None, "tokens": ct})
    return True, texts


def attempt(dtype, cap, logdir, spec=None, draft=None):
    log = os.path.join(logdir, f"{dtype}-{cap}.log")
    sp = SPEC if spec is None else spec
    dr = DRAFT if draft is None else draft
    cmd = [SERVE, MODEL, "--host", "127.0.0.1", "--port", str(PORT),
           "--max-context", str(cap), "--kv-capacity", str(cap), "--kv-dtype", dtype]
    if sp and sp != "none":
        cmd += ["--spec", sp, "--draft-tokens", dr]
    cmd += EXTRA
    rec = {"dtype": dtype, "capacity": cap, "spec": sp, "cmd": " ".join(cmd)}
    before = vram_used_mib()
    with open(log, "w", encoding="utf-8", errors="replace") as lf:
        lf.write("### cmd: " + " ".join(cmd) + "\n")
        lf.flush()
        proc = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT,
                                env={**os.environ})
        try:
            t0 = time.time()
            ready = wait_ready(proc, time.time() + READY_TIMEOUT)
            rec["ready_sec"] = round(time.time() - t0, 1)
            rec["started"] = bool(ready)
            peak = dict(before)
            if ready:
                for _ in range(SMOKE_N):
                    cu = vram_used_mib()
                    for k, v in cu.items():
                        peak[k] = max(peak.get(k, 0), v)
                    time.sleep(0.2)
                ok, detail = smoke()
                rec["smoke_ok"] = bool(ok)
                rec["detail"] = detail
            else:
                rec["smoke_ok"] = False
                rec["detail"] = "未就绪（启动失败或超时）"
            rec["vram_peak_mib"] = peak
        finally:
            proc.send_signal(subprocess.signal.SIGINT)
            try:
                proc.wait(timeout=90)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=30)
            time.sleep(5)  # 让显存回收
    # 失败时截取日志尾部作为"引擎原文"
    try:
        with open(log, encoding="utf-8", errors="replace") as f:
            lines = [l.rstrip() for l in f if l.strip()]
        rec["log_tail"] = lines[-6:]
    except Exception:
        rec["log_tail"] = []
    rec["pass"] = bool(rec.get("started") and rec.get("smoke_ok"))
    return rec


def binsearch(dtype, logdir):
    """在 LADDER 上二分，返回 (best_cap, attempts)。"""
    lo, hi = 0, len(LADDER) - 1
    best = None
    attempts = []
    # 先探中位（更快命中"能跑"的量级），再二分
    while lo <= hi:
        mid = (lo + hi) // 2
        cap = LADDER[mid]
        rec = attempt(dtype, cap, logdir)
        attempts.append(rec)
        print(f"[{dtype}] cap={cap} pass={rec['pass']} "
              f"ready={rec.get('ready_sec')}s detail={str(rec.get('detail'))[:80]}", flush=True)
        if rec["pass"]:
            best = cap
            lo = mid + 1
        else:
            hi = mid - 1
    return best, attempts


def main():
    os.makedirs(LOGDIR, exist_ok=True)
    result = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "serve": SERVE, "model": MODEL,
        "spec": SPEC, "draft_tokens": DRAFT, "extra_flags": EXTRA,
        "smoke": {"requests": SMOKE_N, "max_tokens": SMOKE_TOK, "temperature": 0},
        "desktop_present": desktop_present(),
        "vram_used_before_mib": vram_used_mib(),
        "cuda_visible_devices": os.environ.get("CUDA_VISIBLE_DEVICES"),
        "ladder": LADDER,
        "dtypes": {},
    }
    for dtype in DTYPES:
        best, attempts = binsearch(dtype, LOGDIR)
        entry = {"max_stable_capacity": best, "attempts": attempts}
        if best is None and SPEC and SPEC != "none":
            # 全都起不来时，必须区分是"容量/显存问题"还是"草稿权重（dflash2 9.10GiB）问题"
            probe = attempt(dtype, LADDER[0], LOGDIR, spec="none")
            probe["purpose"] = ("spec 关掉后在最小容量能否启动："
                                "能启动 => 失败主因是草稿权重；不能启动 => 失败主因是容量/dtype")
            entry["spec_off_probe"] = probe
            print(f"[{dtype}] 全部档位失败；spec=off@cap{LADDER[0]} pass={probe['pass']}", flush=True)
        result["dtypes"][dtype] = entry

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print("\n=== KV 可行性汇总 ===")
    for dtype, v in result["dtypes"].items():
        print(f"  {dtype:12s} max_stable={v['max_stable_capacity']}")
    print(f"\n-> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
