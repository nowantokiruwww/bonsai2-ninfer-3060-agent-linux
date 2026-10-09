#!/usr/bin/env bash
# 93-param-frontier.sh —— Phase 2 配置矩阵实测台。
#
# 目的：把「思考预算 / reasoning-effort / 草稿窗口 K」这三个维度在**同一固定任务**上
# 逐臂实测，产出「速度 ↔ 正确性」前沿表。背景见 PORTING-LEDGER L26/L27，
# 以及 92-thinking-throughput.py 的基线分析。
#
# 为什么不走 systemd：为了不改动交付物（config/runtime.env 与 unit 文件），
# 本脚本用**与 unit 完全相同的环境**直接前台拉起引擎，每臂用独立的
# --request-log-jsonl，便于逐臂精确对账、不受时间窗混淆。
#
# 用法:
#   scripts/93-param-frontier.sh --arms "medium:4096 medium:512 low:512 minimal:512" \
#                                --repeats 3 --k 7 [--skip-probe] [--dry-run]

set -u

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/bonsai-ninfer-3060}"  # verify:allow-outside-path（历史编译期流水线，部署根在仓库外）
EVID="$PROJ/evidence/params"
PORT="${PORT:-8098}"
BASE="http://127.0.0.1:$PORT"
TS="$(date +%Y%m%d-%H%M%S)"
RUNDIR="$EVID/frontier-$TS"
ARMS="medium:4096"
REPEATS=3
K=7
SKIP_PROBE=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --arms)      ARMS="$2"; shift 2 ;;
    --repeats)   REPEATS="$2"; shift 2 ;;
    --k)         K="$2"; shift 2 ;;
    --skip-probe) SKIP_PROBE=1; shift ;;
    --dry-run)   DRY=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$RUNDIR"

# ── 从部署态读取固定不改的部分（GPU 锁卡 / profile / 模型 / KV / 采样）────
ENVF="$PREFIX/config/runtime.env"
[ -f "$ENVF" ] || { echo "找不到 $ENVF" >&2; exit 1; }
set -a; . "$ENVF"; set +a

MODEL_PATH="${MODEL_PATH:?runtime.env 缺少 MODEL_PATH}"
MODEL_ID="${MODEL_ID:-bonsai2-27b}"
GPU_UUID="${GPU_UUID:?runtime.env 缺少 GPU_UUID}"
PROF="${NINFER_DEVICE_PROFILES:?runtime.env 缺少 NINFER_DEVICE_PROFILES}"
KV_DTYPE="${KV_DTYPE:-rk2v4-e8}"
KV_CAPACITY="${KV_CAPACITY:-49152}"
MAX_CTX="${MAX_CTX:-$KV_CAPACITY}"
# 采样固定为生产档（L27），在全部臂中保持一致 —— 本实验只变思考与草稿窗口。
SAMPLE_FLAGS="--temperature 1.0 --top-p 0.95 --top-k 20"
MAX_TOKENS=16384

echo "=== 前沿实测台 $TS ==="
echo "臂: $ARMS   每臂重复: $REPEATS   K=$K   KV=$KV_DTYPE@$KV_CAPACITY"
echo "输出目录: $RUNDIR"
[ "$DRY" = 1 ] && { echo "(dry-run，不实际起服务)"; }

# ── 固定任务：一个会诱发长思考的真实 agent 形态请求 ──────────────────────
TASK="$RUNDIR/task.json"
python3 - "$TASK" <<'PY'
import json, sys
tools = [
 {"type":"function","function":{"name":"read","description":"Read a UTF-8 text file.","parameters":{"type":"object","properties":{"file_path":{"type":"string"}},"required":["file_path"]}}},
 {"type":"function","function":{"name":"write","description":"Create or fully replace a UTF-8 text file.","parameters":{"type":"object","properties":{"file_path":{"type":"string"},"content":{"type":"string"}},"required":["file_path","content"]}}},
 {"type":"function","function":{"name":"bash","description":"Execute a bash command.","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}},
 {"type":"function","function":{"name":"glob","description":"Find files by glob pattern.","parameters":{"type":"object","properties":{"pattern":{"type":"string"}},"required":["pattern"]}}},
]
body = {
 "model": "bonsai2-27b",
 "messages": [
   {"role":"system","content":"You are a coding agent. Complete the user's request using the provided tools. Write files with the write tool."},
   {"role":"user","content":"写一个单文件 HTML 页面 bike.html，用内联 SVG 画一辆自行车：两个车轮、车架三角、车把、坐垫、脚踏曲柄。所有坐标必须严格对齐（轮心距、链条、对称性都要对），页面要能在浏览器直接打开。写完后用 write 工具保存。"},
 ],
 "tools": tools,
 "temperature": 1.0, "top_p": 0.95, "top_k": 20,
 "max_tokens": 16384,
 "stream": False,
}
open(sys.argv[1],"w").write(json.dumps(body, ensure_ascii=False, indent=1))
PY
echo "任务已写: $TASK"

# ── 工具函数 ────────────────────────────────────────────────────────────
engine_pid=""

stop_engine() {
  # 先停 systemd 单元（若在跑），再兜底清掉占用端口的进程
  systemctl --user stop bonsai2-ninfer-3060.service 2>/dev/null || true
  if [ -n "$engine_pid" ] && kill -0 "$engine_pid" 2>/dev/null; then
    kill -TERM "$engine_pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$engine_pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$engine_pid" 2>/dev/null && kill -KILL "$engine_pid" 2>/dev/null || true
  fi
  engine_pid=""
  # 等端口真正释放
  for _ in $(seq 1 30); do
    ss -ltn 2>/dev/null | grep -q ":$PORT " || break
    sleep 1
  done
}

wait_ready() {
  local log="$1" deadline=$((SECONDS + 120))
  while [ $SECONDS -lt $deadline ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/models" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && return 0
    if [ -n "$engine_pid" ] && ! kill -0 "$engine_pid" 2>/dev/null; then
      echo "  ✗ 引擎进程已退出，日志尾部："; tail -5 "$log" | sed 's/^/    /'
      return 1
    fi
    sleep 2
  done
  echo "  ✗ 就绪超时（120s），日志尾部："; tail -5 "$log" | sed 's/^/    /'
  return 1
}

# ── 逐臂执行 ────────────────────────────────────────────────────────────
SUMMARY="$RUNDIR/summary.tsv"
printf 'arm\teffort\tbudget\tk\tstarted_ok\tready_s\tprobe\n' > "$SUMMARY"

for arm in $ARMS; do
  effort="${arm%%:*}"; budget="${arm##*:}"
  name="e${effort}-b${budget}-k${K}"
  log="$RUNDIR/$name.engine.log"
  reqlog="$RUNDIR/$name.request.jsonl"
  reslog="$RUNDIR/$name.responses.jsonl"
  echo
  echo "───────────────────────────────────────────────"
  echo "臂 $name"

  stop_engine
  : > "$reslog"

  if [ "$DRY" = 1 ]; then
    echo "  (dry-run) 跳过"
    printf '%s\t%s\t%s\t%s\tdry\t-\t-\n' "$name" "$effort" "$budget" "$K" >> "$SUMMARY"
    continue
  fi

  t0=$SECONDS
  env -i \
    HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" LANG=C LC_ALL=C \
    CUDA_VISIBLE_DEVICES="$GPU_UUID" CUDA_DEVICE_ORDER=PCI_BUS_ID \
    NINFER_DEVICE_PROFILES="$PROF" \
    LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}" \
    nohup "$PREFIX/bin/ninfer-serve" "$MODEL_PATH" \
      --host 127.0.0.1 --port "$PORT" --model-id "$MODEL_ID" \
      --max-context "$MAX_CTX" --kv-capacity "$KV_CAPACITY" --kv-dtype "$KV_DTYPE" \
      --spec dflash2 --draft-tokens "$K" \
      $SAMPLE_FLAGS \
      --default-reasoning-effort "$effort" \
      --default-thinking-budget "$budget" \
      --max-concurrency 1 \
      --request-log-jsonl "$reqlog" \
      > "$log" 2>&1 &
  engine_pid=$!
  echo "  pid=$engine_pid"

  if ! wait_ready "$log"; then
    printf '%s\t%s\t%s\t%s\tFAIL\t-\t-\n' "$name" "$effort" "$budget" "$K" >> "$SUMMARY"
    stop_engine
    continue
  fi
  ready_s=$((SECONDS - t0))
  echo "  就绪 ${ready_s}s"

  # 1) 固定任务 × REPEATS
  for i in $(seq 1 "$REPEATS"); do
    st=$(date +%s.%N)
    code=$(curl -s -o "$RUNDIR/$name.run$i.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' -H 'Authorization: Bearer none' \
      --max-time 600 --data-binary "@$TASK" "$BASE/v1/chat/completions" 2>/dev/null || echo 000)
    en=$(date +%s.%N)
    python3 - "$RUNDIR/$name.run$i.json" "$name" "$i" "$code" "$st" "$en" >> "$reslog" <<'PY'
import json,sys
path,name,i,code,st,en = sys.argv[1:7]
wall=float(en)-float(st)
try:
    d=json.load(open(path,errors='replace'))
except Exception as e:
    print(json.dumps({"arm":name,"run":int(i),"http":code,"wall_s":round(wall,2),
                      "parse_error":str(e)[:120]},ensure_ascii=False)); sys.exit()
ch=(d.get("choices") or [{}])[0]
msg=ch.get("message") or {}
tc=msg.get("tool_calls") or []
content=msg.get("content") or ""
reasoning=msg.get("reasoning_content") or ""
args="".join((t.get("function") or {}).get("arguments","") for t in tc)
print(json.dumps({"arm":name,"run":int(i),"http":code,"wall_s":round(wall,2),
                  "finish_reason":ch.get("finish_reason"),
                  "completion_tokens":(d.get("usage") or {}).get("completion_tokens"),
                  "tool_calls":len(tc),
                  "tool_name":(tc[0].get("function") or {}).get("name") if tc else None,
                  "args_chars":len(args),
                  "content_chars":len(content),
                  "reasoning_chars":len(reasoning),
                  "args_tail_ok": args.rstrip().endswith("}") if args else None},
                 ensure_ascii=False))
PY
    echo "  run$i http=$code $(tail -1 "$reslog" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"finish={d.get(\"finish_reason\")} calls={d.get(\"tool_calls\")} args={d.get(\"args_chars\")} wall={d.get(\"wall_s\")}s")' 2>/dev/null)"
    sleep 2
  done

  # 2) 复读锁门禁
  probe="-"
  if [ "$SKIP_PROBE" = 0 ] && [ -f "$PROJ/scripts/91-repeat-lock-probe.py" ]; then
    probe_rc=0
    python3 "$PROJ/scripts/91-repeat-lock-probe.py" --ks 4,6,10 --rounds 4 \
      --max-tokens "$MAX_TOKENS" --base "$BASE" > "$RUNDIR/$name.probe.txt" 2>&1 || probe_rc=$?
    case "$probe_rc" in
      0) probe=PASS ;;
      1) probe=FAIL ;;
      *) probe="ERROR(rc=$probe_rc)" ;;
    esac
    echo "  probe=$probe  ($(grep -cE '\[PASS\]' "$RUNDIR/$name.probe.txt" 2>/dev/null || echo 0) 个 PASS)"
  fi

  printf '%s\t%s\t%s\t%s\tOK\t%s\t%s\n' "$name" "$effort" "$budget" "$K" "$ready_s" "$probe" >> "$SUMMARY"
  stop_engine
  # 等显存回落，避免下一臂起不来
  sleep 5
done

stop_engine
echo
echo "=== 实测台结束 ==="
echo "汇总: $SUMMARY"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo
echo "逐臂速度统计（用 92-thinking-throughput.py）:"
for f in "$RUNDIR"/*.request.jsonl; do
  [ -f "$f" ] || continue
  echo
  echo "--- $(basename "$f") ---"
  python3 "$PROJ/scripts/92-thinking-throughput.py" --jsonl "$f" 2>&1 | sed -n '1,14p'
done
