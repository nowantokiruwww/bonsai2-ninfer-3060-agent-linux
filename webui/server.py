#!/usr/bin/env python3
"""
webui/server.py —— ninfer-3060-bonsai 的网页控制台后端

纯 Python 标准库，无第三方依赖。启动：

    ./webui.sh                 # 默认 127.0.0.1:8099
    ./webui.sh --port 9000

它做的事情：
  * 调用 app/launcher.sh 启停引擎（不自己拼引擎参数，单一事实源）
  * 把 logs/service.log 实时推到浏览器（SSE）
  * 读 logs/request.jsonl 算出「每个请求的 decode 速度 / 投机接受率 / 思考 token」
  * 读写 config/runtime.env

设计要点：
  * 只监听 127.0.0.1（引擎和它都是本机服务，不对外暴露）
  * 动作是异步的：start 要等 30 秒左右权重加载完，不能阻塞 HTTP
  * 状态查询带 1.5 秒缓存，避免前端轮询把 nvidia-smi 打爆
  * 引擎「端口通」≠「就绪」：权重加载期间 /v1/models 回 503，判就绪必须看 200
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# ---------------------------------------------------------------------------
# 路径（一切相对仓库根解析 —— 本仓库自包含，不允许引用仓库外路径）
# ---------------------------------------------------------------------------
WEBUI_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(WEBUI_DIR)
STATIC_DIR = os.path.join(WEBUI_DIR, "static")
APP_DIR = os.path.join(ROOT, "app")
LAUNCHER = os.path.join(APP_DIR, "launcher.sh")
ENVF = os.path.join(ROOT, "config", "runtime.env")
LOG_DIR = os.path.join(ROOT, "logs")
SERVICE_LOG = os.path.join(LOG_DIR, "service.log")
REQ_LOG = os.path.join(LOG_DIR, "request.jsonl")

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8099


# ---------------------------------------------------------------------------
# runtime.env 读写
# ---------------------------------------------------------------------------
CONFIG_KEYS = ("HOST", "PORT", "MODEL_ID", "KV_DTYPE", "KV_CAPACITY",
               "SPEC_FLAGS", "EXTRA_FLAGS")


def read_env_file():
    """读 config/runtime.env → dict（只认 KEY=VALUE，忽略注释）。"""
    out = {}
    try:
        with open(ENVF, "r", encoding="utf-8") as fh:
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k, _, v = s.partition("=")
                k = k.strip()
                if k.startswith("export "):
                    k = k[7:].strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                out[k] = v
    except FileNotFoundError:
        pass
    return out


def write_env_values(updates):
    """就地更新 config/runtime.env 里已存在的 KEY=… 行，保留注释与顺序。"""
    if not os.path.isfile(ENVF):
        os.makedirs(os.path.dirname(ENVF), exist_ok=True)
        with open(ENVF, "w", encoding="utf-8") as fh:
            fh.write("# ninfer-3060-bonsai runtime config\n")
    with open(ENVF, "r", encoding="utf-8") as fh:
        lines = fh.readlines()

    seen = set()
    for i, line in enumerate(lines):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k = s.split("=", 1)[0].strip()
        if k.startswith("export "):
            k = k[7:].strip()
        if k in updates:
            val = str(updates[k])
            if re.search(r"\s", val) or val == "":
                val = '"%s"' % val.replace('"', '\\"')
            lines[i] = "%s=%s\n" % (k, val)
            seen.add(k)

    for k, v in updates.items():
        if k in seen:
            continue
        val = str(v)
        if re.search(r"\s", val) or val == "":
            val = '"%s"' % val.replace('"', '\\"')
        lines.append("%s=%s\n" % (k, val))

    tmp = ENVF + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    os.replace(tmp, ENVF)
    return sorted(updates.keys())


# ---------------------------------------------------------------------------
# 调用 launcher.sh
# ---------------------------------------------------------------------------
def run_launcher(args, timeout=25):
    """同步跑 app/launcher.sh，返回 (rc, stdout, stderr)。"""
    try:
        p = subprocess.run(
            ["bash", LAUNCHER] + list(args),
            cwd=ROOT, capture_output=True, text=True, timeout=timeout,
        )
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "launcher 超时（%ss）" % timeout
    except FileNotFoundError as e:
        return 127, "", "找不到 launcher：%s" % e


# ---------------------------------------------------------------------------
# 状态（带缓存）
# ---------------------------------------------------------------------------
_status_lock = threading.Lock()
_status_cache = {"t": 0.0, "data": None}


def get_status(force=False):
    with _status_lock:
        now = time.time()
        if not force and _status_cache["data"] and (now - _status_cache["t"]) < 1.5:
            return _status_cache["data"]
        rc, out, err = run_launcher(["status", "--json"], timeout=20)
        data = None
        if rc == 0 and out.strip():
            try:
                data = json.loads(out.strip().splitlines()[-1])
            except Exception:
                data = None
        if data is None:
            data = {"running": False, "error": (err or out or "status 失败").strip()}
        _status_cache.update(t=now, data=data)
        return data


def get_gpus():
    try:
        p = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=index,uuid,name,memory.total,memory.used,memory.free,compute_cap,utilization.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10,
        )
        if p.returncode != 0:
            return []
        gpus = []
        for line in p.stdout.strip().splitlines():
            parts = [x.strip() for x in line.split(",")]
            if len(parts) < 8:
                continue
            gpus.append({
                "index": parts[0], "uuid": parts[1], "name": parts[2],
                "mem_total_mib": int(float(parts[3] or 0)),
                "mem_used_mib": int(float(parts[4] or 0)),
                "mem_free_mib": int(float(parts[5] or 0)),
                "compute_cap": parts[6], "util_pct": parts[7],
            })
        return gpus
    except Exception:
        return []


def get_presets():
    """从 app/presets.env 取预设（单一事实源，不在 Python 里重复写一遍）。"""
    script = (
        '. "%s/presets.env"; for n in $PRESET_NAMES; do '
        'preset_apply "$n" >/dev/null 2>&1 || continue; '
        "printf '%%s|%%s|%%s|%%s|%%s|%%s\\n' \"$n\" \"$P_THINKING\" \"$P_EFFORT\" "
        '"$P_BUDGET" "$P_SAMPLE" "$P_DESC"; done' % APP_DIR
    )
    try:
        p = subprocess.run(["bash", "-c", script], capture_output=True,
                           text=True, timeout=10)
        out = []
        for line in p.stdout.strip().splitlines():
            f = line.split("|")
            if len(f) < 5:
                continue
            out.append({
                "name": f[0], "thinking": f[1], "effort": f[2],
                "budget": f[3], "sample": f[4],
                "desc": f[5] if len(f) > 5 else "",
            })
        return out
    except Exception:
        return []


# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
def tail_file(path, n=300):
    if not os.path.isfile(path):
        return []
    n = max(1, min(int(n), 5000))
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            block = min(size, max(64 * 1024, n * 400))
            fh.seek(size - block)
            raw = fh.read().decode("utf-8", "replace")
        lines = raw.splitlines()
        return lines[-n:]
    except Exception as e:
        return ["<读取日志失败：%s>" % e]


def file_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


# ---------------------------------------------------------------------------
# request.jsonl → 每个请求的指标
# ---------------------------------------------------------------------------
def recent_requests(n=25):
    if not os.path.isfile(REQ_LOG):
        return []
    n = max(1, min(int(n), 200))
    try:
        with open(REQ_LOG, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            block = min(size, 2 * 1024 * 1024)
            fh.seek(size - block)
            raw = fh.read().decode("utf-8", "replace")
    except Exception:
        return []

    lines = raw.splitlines()
    if size > block and lines:
        lines = lines[1:]  # 首行可能被截断

    starts = {}
    done = []
    for line in lines:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        kind = ev.get("event")
        sid = ev.get("server_instance_id") or ""
        if kind == "request_start":
            r = ev.get("request") or {}
            starts[(sid, r.get("request_id"))] = (ev, r)
        elif kind == "request_done":
            rr = ev.get("request") or {}
            done.append((ev, rr))

    out = []
    for ev, rr in done[-n:]:
        sid = ev.get("server_instance_id") or ""
        rid = rr.get("request_id")
        _sev, sr = starts.get((sid, rid), (None, {}))
        res = ev.get("result") or {}
        tm = ev.get("timings_seconds") or {}
        sp = ev.get("speculative") or {}
        ct = res.get("completion_tokens")
        dec = tm.get("decode")
        tps = None
        if isinstance(ct, (int, float)) and isinstance(dec, (int, float)) and dec > 0:
            tps = round(ct / dec, 1)
        acc = None
        da, ac = sp.get("drafted_tokens"), sp.get("accepted_tokens")
        if isinstance(da, (int, float)) and da > 0 and isinstance(ac, (int, float)):
            acc = round(100.0 * ac / da, 1)
        ts = ev.get("timestamp_unix_ms")
        out.append({
            "time": (time.strftime("%H:%M:%S", time.localtime(ts / 1000.0))
                     if isinstance(ts, (int, float)) else ""),
            "request_id": rid,
            "thinking": sr.get("enable_thinking", rr.get("enable_thinking")),
            "budget": sr.get("effective_thinking_budget", rr.get("effective_thinking_budget")),
            "messages": sr.get("message_count"),
            "tools": sr.get("tool_count"),
            "completion_tokens": ct,
            "thinking_tokens": res.get("model_thinking_tokens"),
            "finish_reason": res.get("finish_reason"),
            "decode_tps": tps,
            "accept_pct": acc,
            "ttft_s": (round(tm["ttft"], 2) if isinstance(tm.get("ttft"), (int, float)) else None),
            "total_s": (round(tm["total"], 2) if isinstance(tm.get("total"), (int, float)) else None),
            "spec_backend": sp.get("backend"),
    })
    out.reverse()
    return out


# ---------------------------------------------------------------------------
# 异步动作
# ---------------------------------------------------------------------------
JOB = {
    "id": 0, "action": None, "started": 0.0, "finished": 0.0,
    "rc": None, "running": False, "cmd": [], "output": deque(maxlen=400),
}
JOB_LOCK = threading.Lock()


def _job_worker(job_id, action, cmd):
    try:
        proc = subprocess.Popen(
            cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        for line in proc.stdout:
            with JOB_LOCK:
                JOB["output"].append(line.rstrip("\n"))
        rc = proc.wait()
    except Exception as e:
        with JOB_LOCK:
            JOB["output"].append("[fail] 无法执行：%s" % e)
        rc = 1
    with JOB_LOCK:
        if JOB["id"] == job_id:
            JOB.update(running=False, rc=rc, finished=time.time())


def start_job(action, launcher_args):
    with JOB_LOCK:
        if JOB["running"]:
            return None, "已有操作在进行中（%s）" % JOB["action"]
        JOB["id"] += 1
        job_id = JOB["id"]
        JOB.update(action=action, started=time.time(), finished=0.0, rc=None,
                   running=True, output=deque(maxlen=400),
                   cmd=["bash", LAUNCHER] + list(launcher_args))
    t = threading.Thread(
        target=_job_worker, args=(job_id, action, ["bash", LAUNCHER] + list(launcher_args)),
        daemon=True,
    )
    t.start()
    return job_id, None


def job_view():
    with JOB_LOCK:
        return {
            "id": JOB["id"], "action": JOB["action"], "running": JOB["running"],
            "rc": JOB["rc"], "started": JOB["started"], "finished": JOB["finished"],
            "elapsed": round((JOB["finished"] or time.time()) - JOB["started"], 1)
            if JOB["started"] else 0,
            "cmd": " ".join(shlex.quote(c) for c in JOB["cmd"]),
            "output": list(JOB["output"]),
        }


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".json": "application/json; charset=utf-8",
}


class Handler(BaseHTTPRequestHandler):
    server_version = "ninfer-webui/0.1"
    protocol_version = "HTTP/1.1"

    # ---- helpers ---------------------------------------------------------
    def log_message(self, fmt, *args):
        if os.environ.get("WEBUI_VERBOSE"):
            sys.stderr.write("[webui] " + (fmt % args) + "\n")

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False))

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    # ---- routing ---------------------------------------------------------
    def do_GET(self):
        u = urlparse(self.path)
        path, q = u.path, parse_qs(u.query)
        try:
            if path in ("/", "/index.html"):
                return self._static("index.html")
            if path.startswith("/static/"):
                return self._static(path[len("/static/"):])

            if path == "/api/health":
                return self._json({"ok": True, "root": ROOT, "time": time.time()})
            if path == "/api/status":
                return self._json(get_status(force=("force" in q)))
            if path == "/api/gpus":
                return self._json({"gpus": get_gpus()})
            if path == "/api/presets":
                return self._json({"presets": get_presets()})
            if path == "/api/config":
                return self._json({
                    "values": read_env_file(),
                    "keys": list(CONFIG_KEYS),
                    "path": os.path.relpath(ENVF, ROOT),
                })
            if path == "/api/action":
                return self._json(job_view())
            if path == "/api/logs":
                n = int((q.get("n") or ["300"])[0])
                return self._json({
                    "lines": tail_file(SERVICE_LOG, n),
                    "bytes": file_size(SERVICE_LOG),
                    "path": os.path.relpath(SERVICE_LOG, ROOT),
                })
            if path == "/api/requests":
                n = int((q.get("n") or ["25"])[0])
                return self._json({"requests": recent_requests(n),
                                   "bytes": file_size(REQ_LOG)})
            if path == "/api/logs/stream":
                return self._stream()
            return self._json({"error": "not found", "path": path}, 404)
        except BrokenPipeError:
            pass
        except Exception as e:
            try:
                return self._json({"error": "%s: %s" % (type(e).__name__, e)}, 500)
            except Exception:
                pass

    def do_POST(self):
        u = urlparse(self.path)
        try:
            body = self._read_json()
            if u.path == "/api/config":
                updates = {}
                for k in CONFIG_KEYS:
                    if k in body and body[k] is not None:
                        updates[k] = str(body[k]).strip()
                if not updates:
                    return self._json({"ok": False, "error": "没有可更新的键"}, 400)
                changed = write_env_values(updates)
                return self._json({"ok": True, "changed": changed,
                                   "values": read_env_file()})
            if u.path == "/api/action":
                return self._action(body)
            return self._json({"ok": False, "error": "not found"}, 404)
        except Exception as e:
            return self._json({"ok": False, "error": "%s: %s" % (type(e).__name__, e)}, 500)

    # ---- actions ---------------------------------------------------------
    def _action(self, body):
        action = (body.get("action") or "").strip()
        args = []
        preset = (body.get("preset") or "").strip()
        if preset:
            args += ["--preset", preset]
        for key, flag in (("ctx", "--ctx"), ("kv_dtype", "--kv-dtype"),
                          ("spec", "--spec"), ("extra", "--extra"),
                          ("host", "--host"), ("port", "--port")):
            v = body.get(key)
            if v not in (None, ""):
                args += [flag, str(v)]

        if action == "start":
            job_id, err = start_job("start", ["start"] + args)
        elif action == "restart":
            job_id, err = start_job("restart", ["restart"] + args)
        elif action == "stop":
            job_id, err = start_job("stop", ["stop"])
        elif action == "save":
            # 只写 runtime.env，不重启
            updates = {}
            for k in CONFIG_KEYS:
                if k in body and body[k] is not None:
                    updates[k] = str(body[k]).strip()
            changed = write_env_values(updates)
            return self._json({"ok": True, "saved": changed, "values": read_env_file()})
        else:
            return self._json({"ok": False, "error": "未知动作 %r" % action}, 400)

        if err:
            return self._json({"ok": False, "error": err}, 409)
        return self._json({"ok": True, "job": job_id, "action": action})

    # ---- static ----------------------------------------------------------
    def _static(self, rel):
        rel = rel.lstrip("/")
        full = os.path.normpath(os.path.join(STATIC_DIR, rel))
        if not full.startswith(STATIC_DIR) or not os.path.isfile(full):
            return self._json({"error": "not found"}, 404)
        ext = os.path.splitext(full)[1].lower()
        with open(full, "rb") as fh:
            data = fh.read()
        return self._send(200, data, MIME.get(ext, "application/octet-stream"))

    # ---- SSE -------------------------------------------------------------
    def _stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        lines = tail_file(SERVICE_LOG, 200)
        try:
            for ln in lines:
                self._sse(json.dumps({"line": ln}, ensure_ascii=False))
            pos = file_size(SERVICE_LOG)
            last_ping = time.time()
            while True:
                time.sleep(0.6)
                size = file_size(SERVICE_LOG)
                if size < pos:           # 日志被轮转/截断
                    pos = 0
                    self._sse(json.dumps({"reset": True}))
                if size > pos:
                    with open(SERVICE_LOG, "r", encoding="utf-8", errors="replace") as fh:
                        fh.seek(pos)
                        chunk = fh.read()
                        pos = fh.tell()
                    for ln in chunk.splitlines():
                        self._sse(json.dumps({"line": ln}, ensure_ascii=False))
                if time.time() - last_ping > 15:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    last_ping = time.time()
        except (BrokenPipeError, ConnectionResetError):
            return

    def _sse(self, payload):
        self.wfile.write(("data: %s\n\n" % payload).encode("utf-8"))
        self.wfile.flush()


def main():
    ap = argparse.ArgumentParser(description="ninfer-3060-bonsai 网页控制台")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = ap.parse_args()

    if not os.path.isfile(LAUNCHER):
        sys.exit("找不到 %s" % LAUNCHER)

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    url = "http://%s:%d/" % (args.host, args.port)
    print("ninfer-3060-bonsai 网页控制台")
    print("  仓库根 : %s" % ROOT)
    print("  地址   : %s" % url)
    print("  Ctrl+C 退出")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已退出")


if __name__ == "__main__":
    main()
