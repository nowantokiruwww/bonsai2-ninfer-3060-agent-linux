#!/usr/bin/env bash
# scripts/75-kv-gate.sh — §4.2 KV (dtype, capacity) 可行性门禁
#
# 薄包装：把环境准备好，交给 agent/kvgate.py（纯标准库）做二分扫描。
# 必须分别在"带桌面"与"TTY 无桌面"两种状态下各跑一次（桌面在 GPU0 占约 922MiB）。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "75-kv-gate"
EV="$PROJ/evidence/kv-gate"; mkdir -p "$EV" "$PROJ/results"

[ -x "$NINFER_SERVE" ] || { echo "[fail] 未找到 $NINFER_SERVE（先跑 scripts/50-build.sh）" >&2; exit 1; }
[ -s "$NINFER_MODEL_PATH" ] || { echo "[fail] 模型未就位（先跑 scripts/60-fetch-model.sh）" >&2; exit 1; }

# 确认 --kv-dtype 的候选确实是这个二进制接受的
run_ok bash -c "'$NINFER_SERVE' --help > '$EV/serve-help.txt' 2>&1"
note "serve --help 已存 $EV/serve-help.txt"

export CUDA_VISIBLE_DEVICES="$GPU_UUID_3060"
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export NINFER_DEVICE_PROFILES="$PROJ/profiles/device-profiles.json"
export PATH="$NINFER_CUDA_DIR/bin:$PATH"
unset LD_LIBRARY_PATH 2>/dev/null || true

export KV_GATE_OUT="$PROJ/results/kv-feasibility.json"
export KV_GATE_LOGDIR="$EV/runs"
export NINFER_STATE="${NINFER_STATE:-desktop}"   # desktop | tty
export KV_GATE_OUT="${KV_GATE_OUT%.json}-$NINFER_STATE.json"
# 单次启动的就绪上限：模型 9.5GB，加载通常 1–2 分钟；
# 压到 300s 是为了让"起不来"的档位及时判负并留证据，而不是每档干等 10 分钟。
export KV_GATE_READY_TIMEOUT="${KV_GATE_READY_TIMEOUT:-300}"
# 候选 dtype：均已在源码里确认被接受（见 evidence/serve/flag-surface-static.md）
export KV_GATE_DTYPES="${KV_GATE_DTYPES:-int8 rk8v4 rk4v4-e8 rk2v4-e8}"
# 容量阶梯：底部留 4096，避免"模型要求最小上下文"被误判成"全都起不来"
export KV_GATE_LADDER="${KV_GATE_LADDER:-4096 8192 16384 24576 32768 49152 65536 76768}"

nvidia-smi --query-gpu=index,uuid,name,memory.used,memory.total --format=csv \
  > "$EV/gpu-before-$NINFER_STATE.txt" 2>&1 || true
note "GPU 状态已存（状态=$NINFER_STATE，桌面占用会影响容量上限）"

python3 "$PROJ/agent/kvgate.py"

cp "$PROJ/results/kv-feasibility-$NINFER_STATE.json" "$EV/" 2>/dev/null || true
log_finish 0
echo "[done] KV 门禁（$NINFER_STATE）-> $KV_GATE_OUT"
