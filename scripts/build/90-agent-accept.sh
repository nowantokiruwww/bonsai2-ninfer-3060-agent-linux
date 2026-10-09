#!/usr/bin/env bash
# scripts/90-agent-accept.sh — Phase 9：agent 体验验收（薄包装）
#
#   bash scripts/90-agent-accept.sh loop|context|stability|correctness|all
#
# correctness 模式会自己起两个服务（无投机 / dflash2 K=7），
# 因此需要 KV_DTYPE / KV_CAPACITY 已由 §4.2 门禁确定。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

MODE="${1:-loop}"
log_init "90-agent-$MODE"
EV="$PROJ/evidence/agent"; mkdir -p "$EV" "$PROJ/results"

[ -f "$PROJ/agent/agent_accept.py" ] || { echo "[fail] 缺 agent/agent_accept.py" >&2; exit 1; }

export CUDA_VISIBLE_DEVICES="$GPU_UUID_3060"
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export NINFER_DEVICE_PROFILES="$PROJ/profiles/device-profiles.json"
export PATH="$NINFER_CUDA_DIR/bin:$PATH"
unset LD_LIBRARY_PATH 2>/dev/null || true

export ACCEPT_OUTDIR="$PROJ/results"
export ACCEPT_LOGDIR="$EV/runs"
mkdir -p "$ACCEPT_LOGDIR"

# KV 设定：未给则从门禁结果取最大稳定值
if [ -z "${KV_CAPACITY:-}" ] || [ -z "${KV_DTYPE:-}" ]; then
  pick=$(python3 - "$PROJ/results" <<'PY' || true
import glob, json, os, sys
best=None
for p in sorted(glob.glob(os.path.join(sys.argv[1],"kv-feasibility*.json"))):
    d=json.load(open(p))
    for dt,v in (d.get("dtypes") or {}).items():
        c=v.get("max_stable_capacity")
        if c and (best is None or c>best[0]): best=(c,dt,os.path.basename(p))
print(f"{best[0]}\t{best[1]}\t{best[2]}" if best else "")
PY
)
  if [ -n "$pick" ]; then
    KV_CAPACITY=$(echo "$pick" | cut -f1); KV_DTYPE=$(echo "$pick" | cut -f2)
    export KV_CAPACITY KV_DTYPE
    note "KV 取自门禁（$(echo "$pick" | cut -f3)）: $KV_DTYPE / $KV_CAPACITY"
  else
    echo "[warn] 未指定 KV，且无门禁结果。loop/context/stability 需要已有服务在跑；" >&2
    echo "       correctness 需要 KV，请先跑 scripts/75-kv-gate.sh。" >&2
  fi
fi

# 若本机 8098 还没服务，且是非 correctness 模式，就顺手起一个
if [ "$MODE" != "correctness" ]; then
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$NINFER_HOST:$NINFER_PORT/v1/models" || true)" != "200" ]; then
    echo "[fail] $NINFER_HOST:$NINFER_PORT 上没有服务。请先跑 scripts/80-serve.sh" >&2
    exit 1
  fi
fi

# 环境记账（PCIe 链路在负载前后各测一次更有意义，这里先记一次）
{
  echo "# agent 验收环境记账 ($MODE)"
  echo "at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  nvidia-smi --query-gpu=index,uuid,name,memory.used,memory.total --format=csv
  nvidia-smi --query-gpu=index,name,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv
} | tee "$EV/env-$MODE.txt"

python3 "$PROJ/agent/agent_accept.py" "$MODE" 2>&1 | tee "$EV/agent-$MODE-console.log"

# 服务端日志里的地面真相（throughput / accepted 行）
SLOG=$(ls -t "$PROJ"/logs/serve-*.log 2>/dev/null | head -1 || true)
if [ -n "$SLOG" ]; then
  grep -E 'throughput \||accepted|req#[0-9]+ done' "$SLOG" | tail -40 > "$EV/serve-truth-$MODE.txt" || true
  note "服务端地面真相 -> $EV/serve-truth-$MODE.txt"
fi

log_finish 0
echo "[done] $MODE -> $PROJ/results/"
