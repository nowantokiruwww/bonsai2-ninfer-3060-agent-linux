#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# env.sh —— 路径与运行环境解析
#
# 核心约定：**仓库根就是部署根**。
#   <repo>/runtime/   引擎二进制 + CUDA 运行库 + agent 脚本 + 标定 profile
#   <repo>/models/    模型权重（不进 git，由 install.sh 下载）
#   <repo>/config/    运行时配置（runtime.env 由 install.sh 生成）
#   <repo>/logs/      服务日志与 request.jsonl
#
# 这里**不允许出现任何仓库外的绝对路径** —— 这是上一版 README 最大的毛病：
# 它引用作者本机的部署目录，而 clone 仓库的人根本没有那个目录。
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"

RUNTIME="$ROOT/runtime"
BIN_DIR="$RUNTIME/bin"
BIN="$BIN_DIR/ninfer-serve"
CALIBRATE_BIN="$BIN_DIR/ninfer-calibrate"
LIB_DIR="$RUNTIME/lib"
AGENT_DIR="$RUNTIME/agent"
PROFILE="$RUNTIME/profiles/device-profiles.json"

MODEL_DIR="$ROOT/models"
MODEL_FILE="$MODEL_DIR/Ternary-Bonsai-2-27B-ninfer-v3.ninfer"
MODEL_SHA256="cdc4810b0ff17c40d0f62cf214b6e0bcd08346e9eb05ca53371507037793c14a"
MODEL_BYTES="9520051456"
MODEL_ID_DEFAULT="bonsai2-27b"

CONF_DIR="$ROOT/config"
ENVF="$CONF_DIR/runtime.env"
LOG_DIR="$ROOT/logs"
PIDF="$LOG_DIR/serve.pid"
SERVICE_LOG="$LOG_DIR/service.log"
REQ_LOG="$LOG_DIR/request.jsonl"
TUNE_LOG_DIR="$LOG_DIR/tune"

# 引擎默认值（config/runtime.env 缺失时用这套 —— 与 3060 上实测跑通的一致）
: "${HOST:=127.0.0.1}"
: "${PORT:=8098}"
: "${MODEL_ID:=$MODEL_ID_DEFAULT}"
: "${KV_DTYPE:=rk2v4-e8}"
: "${KV_CAPACITY:=49152}"
: "${MAX_CONTEXT:=}"
: "${SPEC_FLAGS:=--spec dflash2 --draft-tokens 7}"
: "${EXTRA_FLAGS:=}"

export LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export NINFER_DEVICE_PROFILES="$PROFILE"
export CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"

# ---------------------------------------------------------------------------
# GPU 选择
#
# ⚠ CUDA 运行时的设备枚举顺序与 nvidia-smi **相反**。用序号锁卡会锁错卡 ——
#   本项目就踩过：调参器把引擎指到了另一块卡上，因为那块卡没有 sm_86 的
#   cubin，直接 cudaErrorNoKernelImageForDevice。
#   所以这里只认 **UUID**，并且在锁卡变量不是 GPU- 开头时直接拒绝启动。
# ---------------------------------------------------------------------------
gpu_list() {
  nvidia-smi --query-gpu=index,uuid,name,memory.total,memory.free,compute_cap \
             --format=csv,noheader,nounits 2>/dev/null
}

# 自动挑一张卡：优先 compute_cap 8.6（本项目就是给 3060 编的），
# 且空闲显存最多。找不到 8.6 就退回空闲最多的一张。
gpu_autodetect_uuid() {
  local best_cc="" best_mem=-1 line uuid cc mem
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    uuid="$(echo "$line" | awk -F', ' '{print $2}')"
    cc="$(echo "$line"   | awk -F', ' '{print $6}')"
    mem="$(echo "$line"  | awk -F', ' '{print $5}')"
    [ -n "$uuid" ] || continue
    if [ "$cc" = "8.6" ] && [ "${mem:-0}" -gt "$best_mem" ] 2>/dev/null; then
      best_mem="$mem"; best_cc="$uuid"
    fi
  done < <(gpu_list)
  if [ -n "$best_cc" ]; then printf '%s' "$best_cc"; return 0; fi
  # 退回：空闲显存最多
  best_mem=-1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    uuid="$(echo "$line" | awk -F', ' '{print $2}')"
    mem="$(echo "$line"  | awk -F', ' '{print $5}')"
    [ -n "$uuid" ] || continue
    if [ "${mem:-0}" -gt "$best_mem" ] 2>/dev/null; then best_mem="$mem"; best_cc="$uuid"; fi
  done < <(gpu_list)
  printf '%s' "$best_cc"
}

gpu_name_of_uuid() {
  gpu_list | awk -F', ' -v u="$1" '$2==u {print $3}'
}
gpu_free_of_uuid() {
  gpu_list | awk -F', ' -v u="$1" '$2==u {print $5}'
}

# 解析最终要用的 UUID：环境变量 > runtime.env > 自动探测
resolve_gpu_uuid() {
  local u="${GPU_UUID:-}"
  if [ -z "$u" ] && [ -f "$ENVF" ]; then
    u="$(bash -c 'set -a; . "$1" >/dev/null 2>&1; printf "%s" "${GPU_UUID:-}"' _ "$ENVF" 2>/dev/null)"
  fi
  [ -n "$u" ] || u="$(gpu_autodetect_uuid)"
  printf '%s' "$u"
}

# 锁卡必须是 UUID。序号（0/1）在 CUDA 与 nvidia-smi 之间含义相反，一律拒绝。
apply_gpu_lock() {
  local uuid="$1"
  if [ -z "$uuid" ]; then
    echo "[fail] 找不到可用 GPU（nvidia-smi 无输出？）" >&2
    return 1
  fi
  case "$uuid" in
    GPU-*) ;;
    *) echo "[fail] GPU 锁必须是 UUID（GPU- 开头），拿到的是 '$uuid'。
       CUDA 的设备序与 nvidia-smi 相反，用序号会锁错卡。" >&2
       return 1 ;;
  esac
  export CUDA_VISIBLE_DEVICES="$uuid"
  return 0
}

load_runtime_env() {
  [ -f "$ENVF" ] || return 0
  local _saved_root="$ROOT"
  set -a
  # shellcheck disable=SC1090
  . "$ENVF"
  set +a
  ROOT="$_saved_root"
  # runtime.env 里的相对路径按仓库根解释
  [ -n "${MODEL_PATH:-}" ] || MODEL_PATH="$MODEL_FILE"
  return 0
}
