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
# 且空闲显存最多。没有 sm_86 时必须失败，不能退回不兼容架构。
gpu_autodetect_uuid() {
  local best_mem=-1 best_cc="" line uuid cc mem
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
  [ -n "$best_cc" ] || return 1
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

# ---------------------------------------------------------------------------
# 网络地址
#
# ⚠ 引擎**没有鉴权** —— 这是上游的设计，本项目没有在外面加壳。
#   所以默认只绑 127.0.0.1。要让笔记本连台式机的算力，必须显式开 --lan，
#   并且要明白这意味着什么：**同一局域网里任何人都能白用你的显卡**，
#   包括看你的请求内容（请求日志就落在 logs/request.jsonl）。
#   要开放就开放，但不许悄悄开放 —— 所以暴露时 everywhere 都会打警告。
#
# 这里不猜 IP：直接问内核要全局作用域的 IPv4，跳过虚拟网卡。
# ---------------------------------------------------------------------------
lan_ips() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global 2>/dev/null \
      | awk '{ split($4, a, "/"); if ($2 !~ /^(docker|br-|veth|virbr|tun|tap)/) print $2, a[1] }'
  elif command -v hostname >/dev/null 2>&1; then
    local a
    for a in $(hostname -I 2>/dev/null); do
      case "$a" in 127.*|172.1[0-9].*|172.2[0-9].*|172.3[01].*|169.254.*) continue ;; esac
      printf 'host %s\n' "$a"
    done
  fi
}

# 走默认路由的那张网卡的地址 —— 别的机器最可能连上的就是它
primary_lan_ip() {
  local p=""
  if command -v ip >/dev/null 2>&1; then
    p="$(ip route get 1.1.1.1 2>/dev/null \
         | awk '{ for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit } }')"
  fi
  [ -n "$p" ] || p="$(lan_ips | awk 'NR==1{print $2}')"
  printf '%s' "$p"
}

# 一个 bind 地址对外意味着哪些 URL
#   127.0.0.1 / localhost  → 只有本机
#   0.0.0.0                → 所有网卡，返回每条 LAN 地址
#   具体 IP                → 就那一个
#
# BONSAI_ADVERTISE_IP：手动指定「对外该报哪个 IP」。
#   在容器里必须要它 —— 容器只看得见自己那个网络命名空间的网卡（172.17.x.x），
#   报出来的桥接地址对笔记本毫无用处；docker/run.sh 会把宿主机的真实局域网
#   地址通过这个变量传进来。
urls_for_bind() {
  local host="$1" port="${2:-8098}"
  case "$host" in
    0.0.0.0|"::"|"*")
      printf 'http://127.0.0.1:%s\n' "$port"
      if [ -n "${BONSAI_ADVERTISE_IP:-}" ]; then
        printf 'http://%s:%s\n' "$BONSAI_ADVERTISE_IP" "$port"
        return 0
      fi
      local line
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf 'http://%s:%s\n' "$(printf '%s' "$line" | awk '{print $2}')" "$port"
      done < <(lan_ips)
      ;;
    *)
      printf 'http://%s:%s\n' "$host" "$port"
      ;;
  esac
}

# bind 在 0.0.0.0 上就是对外开放
#
# BONSAI_LAN_EXPOSED 可以推翻这个判断：容器里引擎必须绑 0.0.0.0（否则 docker 的
#   -p 转发不进来），但宿主机到底把端口映射到 127.0.0.1 还是所有网卡，容器自己
#   看不见 —— 这个变量就是宿主机把真相告诉容器的方式。docker/run.sh 会设它。
is_lan_exposed() {
  case "${BONSAI_LAN_EXPOSED:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  case "${1:-}" in 0.0.0.0|"::"|"*") return 0 ;; *) return 1 ;; esac
}
