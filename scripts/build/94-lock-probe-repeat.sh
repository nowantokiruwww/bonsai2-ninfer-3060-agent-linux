#!/usr/bin/env bash
# 94-lock-probe-repeat.sh —— 复读锁死探针「重复测量」台
#
# 为什么需要它：scripts/93-param-frontier.sh 只跑 1 次探针（每 K 4 轮，共 12 个判据），
# 在**采样态**下偶发单轮重复属正常抖动（见 PORTING-LEDGER L27.7）。用 1 次探针的 PASS/FAIL
# 去裁决预算档位，会把抖动误判成"这个预算不安全"。
#
# 本脚本对每个候选预算**重复跑 N 次探针**，统计：
#   * 总判据数 / LOCKED 判据数 / 锁死率
#   * 每次探针的 rc（0=PASS,1=FAIL,2=连接错误）
#   * 是否出现"跨轮持续不恢复"的真锁死（L26 签名：同一 K 内连续 >=3 轮逐字节相同）
# 真锁死与抖动的区别就在这里：抖动 = 单个 LOCKED 之后立刻恢复；真锁死 = 连续多轮不变。
#
# 用法: bash scripts/94-lock-probe-repeat.sh [--budgets 512,1024,2048,4096] [--reps 5] [--k 7]
set -uo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${BONSAI2_PREFIX:-$HOME/bonsai-ninfer-3060}"  # verify:allow-outside-path（历史编译期流水线，部署根在仓库外）
ENVF="$PREFIX/config/runtime.env"
BASE="http://127.0.0.1:8098"
BUDGETS="512,1024,2048,4096"
REPS=5
K=7
MAX_TOKENS=16384

while [ $# -gt 0 ]; do
  case "$1" in
    --budgets) BUDGETS="$2"; shift 2 ;;
    --reps)    REPS="$2"; shift 2 ;;
    --k)       K="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    --base)    BASE="$2"; shift 2 ;;
    --prefix)  PREFIX="$2"; ENVF="$PREFIX/config/runtime.env"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -f "$ENVF" ] || { echo "找不到 $ENVF" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "$ENVF"; set +a

OUT="$PROJ/evidence/params/probe-repeat-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "=== 复读锁死探针重复测量 $(date) ===" | tee "$OUT/log.txt"
echo "预算: $BUDGETS   每档重复: $REPS   探针 K=$K   max_tokens=$MAX_TOKENS" | tee -a "$OUT/log.txt"
echo "输出目录: $OUT" | tee -a "$OUT/log.txt"

engine_pid=""
stop_engine() {
  [ -n "$engine_pid" ] || return 0
  kill -TERM "$engine_pid" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$engine_pid" 2>/dev/null || break; sleep 1; done
  kill -KILL "$engine_pid" 2>/dev/null || true
  wait "$engine_pid" 2>/dev/null || true
  engine_pid=""
}
trap 'stop_engine' EXIT INT TERM

for budget in ${BUDGETS//,/ }; do
  name="b$budget"
  echo "" | tee -a "$OUT/log.txt"
  echo "── 预算 $budget ─────────────────────────" | tee -a "$OUT/log.txt"

  env -i \
    HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" LANG=C LC_ALL=C \
    CUDA_VISIBLE_DEVICES="$GPU_UUID" CUDA_DEVICE_ORDER=PCI_BUS_ID \
    NINFER_DEVICE_PROFILES="$NINFER_DEVICE_PROFILES" \
    LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}" \
    nohup "$PREFIX/bin/ninfer-serve" "$MODEL_PATH" \
      --host 127.0.0.1 --port 8098 --model-id "$MODEL_ID" \
      --max-context "$KV_CAPACITY" --kv-capacity "$KV_CAPACITY" --kv-dtype "$KV_DTYPE" \
      --spec dflash2 --draft-tokens "$K" \
      --temperature 1.0 --top-p 0.95 --top-k 20 \
      --default-reasoning-effort medium \
      --default-thinking-budget "$budget" \
      --max-concurrency 1 \
      --request-log-jsonl "$OUT/$name.request.jsonl" \
      > "$OUT/$name.engine.log" 2>&1 &
  engine_pid=$!

  # ⚠ 必须判 HTTP 状态码，不能只判"curl 有没有回话"：
  #   引擎在权重加载完成之前就已经在监听端口，此时 /v1/models 回 **503**，
  #   只判退避与否会以为"已就绪"，于是所有请求打在加载窗口里、全部 503
  #   （实测：探针 20 次全 rc=2，引擎日志停在 `loading weights | 7.99 GiB`）。
  ready=0
  for _ in $(seq 1 60); do
    code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE/v1/models" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && { ready=1; break; }
    kill -0 "$engine_pid" 2>/dev/null || break
    sleep 2
  done
  if [ "$ready" != "1" ]; then
    echo "  起不来（见 $name.engine.log）" | tee -a "$OUT/log.txt"
    stop_engine
    continue
  fi
  echo "  就绪" | tee -a "$OUT/log.txt"

  for r in $(seq 1 "$REPS"); do
    rc=0
    python3 "$PROJ/scripts/91-repeat-lock-probe.py" --ks 4,6,10 --rounds 4 \
      --max-tokens "$MAX_TOKENS" --base "$BASE" >> "$OUT/$name.probe.txt" 2>&1 || rc=$?
    echo "  rep$r rc=$rc" | tee -a "$OUT/log.txt"
  done
  stop_engine
done

echo "" | tee -a "$OUT/log.txt"
echo "=== 统计 ===" | tee -a "$OUT/log.txt"
python3 - "$OUT" <<'PY' 2>&1 | tee -a "$OUT/log.txt"
import sys, os, re, collections
out = sys.argv[1]
unlock = 0
for fn in sorted(os.listdir(out)):
    if not fn.endswith('.probe.txt'):
        continue
    b = fn[:-len('.probe.txt')]
    txt = open(os.path.join(out, fn), errors='replace').read()
    total = len(re.findall(r'^\s+\d+\s+\d+\s+\d+\s+[\d.]+\s+\[', txt, re.M))
    locked = len(re.findall(r'\bLOCKED', txt))
    fail = len(re.findall(r'^\[FAIL\]', txt, re.M))
    ok = len(re.findall(r'^\[PASS\]', txt, re.M))
    # 真锁死签名：某个 K 的 4 轮里出现 >=3 个 LOCKED（连续不恢复）
    real = 0
    for line in txt.splitlines():
        m = re.match(r"\s+\d+\s+\d+\s+\d+\s+[\d.]+\s+\[(.*)\]\s*(<== LOCKED)?\s*$", line)
        if m and m.group(1).count('LOCKED') >= 3:
            real += 1
    unlock += 1
    print(f"{b:<8} 判据 {total:>4} | LOCKED {locked:>3} ({100*locked/total if total else 0:>5.1f}%) | "
          f"探针 PASS {ok:>2} / FAIL {fail:>2} | 真锁死(>=3轮连续) {real}")
PY
echo "结果目录: $OUT"
