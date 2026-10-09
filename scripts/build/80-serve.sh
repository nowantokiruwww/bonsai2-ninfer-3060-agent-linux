#!/usr/bin/env bash
# scripts/80-serve.sh — Phase 8：按 agent 形态起服务
#
# 与前几阶段的约定：
#   - 按 GPU UUID 锁卡（CUDA 设备序与 nvidia-smi 相反，用序号会误选 V100）；
#   - NINFER_DEVICE_PROFILES 指向项目内 28-SM 标定结果；
#   - --kv-capacity / --kv-dtype 由 §4.2 门禁实测决定，禁止预设；
#   - 桌面占用、PCIe 链路一并记账。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "80-serve"
EV="$PROJ/evidence/serve"; mkdir -p "$EV"

[ -x "$NINFER_SERVE" ] || { echo "[fail] 未找到 $NINFER_SERVE" >&2; exit 1; }
[ -s "$NINFER_MODEL_PATH" ] || { echo "[fail] 模型未就位: $NINFER_MODEL_PATH" >&2; exit 1; }
[ -s "$NINFER_DEVICE_PROFILES" ] || { echo "[warn] 尚无 28-SM profile（建议先跑 scripts/70-calibrate.sh）" >&2; }

# KV 参数：若未显式给定，从门禁结果里取"带桌面"那一档的最大稳定值
if [ -z "${KV_CAPACITY:-}" ] || [ -z "${KV_DTYPE:-}" ]; then
  pick=$(python3 - "$PROJ/results" <<'PY' || true
import glob, json, sys, os
best = None
for p in sorted(glob.glob(os.path.join(sys.argv[1], "kv-feasibility-*.json"))):
    d = json.load(open(p))
    for dt, v in (d.get("dtypes") or {}).items():
        cap = v.get("max_stable_capacity")
        if cap and (best is None or cap > best[0]):
            best = (cap, dt, os.path.basename(p))
print(f"{best[0]}\t{best[1]}\t{best[2]}" if best else "")
PY
)
  if [ -n "$pick" ]; then
    KV_CAPACITY=$(echo "$pick" | cut -f1); KV_DTYPE=$(echo "$pick" | cut -f2)
    note "KV 取自门禁结果（$(echo "$pick" | cut -f3)）: capacity=$KV_CAPACITY dtype=$KV_DTYPE"
  else
    echo "[fail] 未指定 KV_CAPACITY/KV_DTYPE，且没有可用的门禁结果。请先跑 scripts/75-kv-gate.sh。" >&2
    exit 1
  fi
fi

export CUDA_VISIBLE_DEVICES="$GPU_UUID_3060"
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export NINFER_DEVICE_PROFILES
export PATH="$NINFER_CUDA_DIR/bin:$PATH"
unset LD_LIBRARY_PATH 2>/dev/null || true

# 兜底值与 config/env.sh 的 NINFER_EXTRA_FLAGS 必须一致（思考预算 1024，见 L28）。
# 正常情况下这里不会生效——本脚本已 source config/env.sh。
EXTRA="${NINFER_EXTRA_FLAGS:---max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 --default-reasoning-effort medium --default-thinking-budget 1024}"

{
  echo "# serve 形态"
  echo "binary        = $NINFER_SERVE ($(stat -c %s "$NINFER_SERVE") B, sha256=$(sha256sum "$NINFER_SERVE" | cut -c1-16)…)"
  echo "model         = $NINFER_MODEL_PATH"
  echo "model_sha256  = $(sha256sum "$NINFER_MODEL_PATH" | awk '{print $1}')"
  echo "gpu_uuid      = $GPU_UUID_3060"
  echo "device_profiles = $NINFER_DEVICE_PROFILES"
  echo "kv_dtype      = $KV_DTYPE"
  echo "kv_capacity   = $KV_CAPACITY"
  echo "extra_flags   = $EXTRA"
  echo "endpoint      = http://$NINFER_HOST:$NINFER_PORT/v1"
  echo "# 环境记账"
  nvidia-smi --query-gpu=index,uuid,name,memory.used,memory.total --format=csv
  nvidia-smi --query-gpu=index,name,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv
} | tee "$EV/serve-config.txt"

CMD=("$NINFER_SERVE" "$NINFER_MODEL_PATH" --host "$NINFER_HOST" --port "$NINFER_PORT"
     --model-id "$NINFER_MODEL_ID" --max-context "$KV_CAPACITY" --kv-capacity "$KV_CAPACITY"
     --kv-dtype "$KV_DTYPE")
if [ -n "${NINFER_SPEC:-}" ] && [ "$NINFER_SPEC" != "none" ]; then
  CMD+=(--spec "$NINFER_SPEC" --draft-tokens "${NINFER_DRAFT:-7}")
fi
# shellcheck disable=SC2206
CMD+=($EXTRA)

echo "[serve] ${CMD[*]}" | tee -a "$EV/serve-config.txt"

LOG="$PROJ/logs/serve-$(date '+%Y%m%d-%H%M%S').log"
echo "[serve] 日志 -> $LOG"
"${CMD[@]}" > "$LOG" 2>&1 &
SRV=$!
echo "$SRV" > "$PROJ/logs/serve.pid"

# 就绪等待
for i in $(seq 1 300); do
  if ! kill -0 "$SRV" 2>/dev/null; then
    echo "[fail] 服务进程已退出。日志尾部：" >&2; tail -20 "$LOG" >&2; exit 1
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://$NINFER_HOST:$NINFER_PORT/v1/models" || true)
  if [ "$code" = "200" ]; then note "就绪（${i}s）"; break; fi
  sleep 1
done
[ "$code" = "200" ] || { echo "[fail] 就绪超时" >&2; tail -20 "$LOG" >&2; exit 1; }

curl -s "http://$NINFER_HOST:$NINFER_PORT/v1/models" | tee "$EV/models.json"
note "serve pid=$SRV port=$NINFER_PORT"
log_finish 0
echo "[done] 服务在 http://$NINFER_HOST:$NINFER_PORT/v1 （pid=$SRV，日志 $LOG）"
