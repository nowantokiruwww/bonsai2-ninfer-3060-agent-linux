#!/usr/bin/env bash
# ===========================================================================
#  容器启动器（宿主机侧）
# ===========================================================================
#
#  它替你做三件手工 docker run 很容易做错的事：
#
#    1. 找到该用哪张卡，并把 GPU UUID 传进容器
#       —— 绝不用序号：CUDA 的设备序和 nvidia-smi 相反，序号会锁到 V100。
#
#    2. 让容器看得见显卡
#       —— 装了 nvidia-container-toolkit 就用 --gpus；
#          没装就手工挂 /dev/nvidia* 和宿主机驱动库（libcuda / ptxjitcompiler /
#          nvvm / nvidia-ml）。后者是不装 toolkit 也能跑起来的完整方案，
#          官方 CUDA 镜像在没 toolkit 时也是这么办的。
#
#    3. 把宿主机的 models/ 挂进去，顺手把 logs/ 也挂出来
#       —— 模型 9.5 GB 不进镜像；日志留在宿主机上方便翻。
#
#  用法：
#      ./docker/run.sh                 # 前台跑（引擎 + 网页控制台），Ctrl-C 退出
#      ./docker/run.sh -d              # 后台跑
#      ./docker/run.sh --lan           # 允许局域网访问（⚠ 无鉴权，慎用）
#      ./docker/run.sh headless        # 只跑引擎，不跑控制台
#      ./docker/run.sh shell           # 进容器 bash
#      ./docker/run.sh logs            # 看容器日志
#      ./docker/run.sh stop            # 停容器
#      ./docker/run.sh status          # 容器状态 + 引擎 API 探活
#
#  环境变量：
#      IMAGE=...        镜像名（默认见下）
#      GPU_UUID=...     强制指定显卡
#      PORT=8098        API 端口（映射到宿主机同号）
#      WEBUI_PORT=8099  网页控制台端口
#      MODEL_DIR=...    模型目录（默认 <仓库>/models）
#      ADVERTISE_IP=... 对外报哪个 IP（默认走默认路由那张网卡）
#
# ===========================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)"
IMAGE="${IMAGE:-bonsai2-ninfer-3060:${VERSION}}"
NAME="${NAME:-bonsai2-ninfer-3060}"
PORT="${PORT:-8098}"
WEBUI_PORT="${WEBUI_PORT:-8099}"
MODEL_DIR="${MODEL_DIR:-$ROOT/models}"
LIBDIR=/usr/lib/x86_64-linux-gnu
LAN=0

log()  { printf '\033[36m[run]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[run]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[run]\033[0m %s\n' "$*" >&2; exit 1; }

# 走默认路由的那张网卡的地址 —— 别人的笔记本最可能连上的就是它
primary_lan_ip() {
  local p=""
  command -v ip >/dev/null 2>&1 && p="$(ip route get 1.1.1.1 2>/dev/null \
      | awk '{ for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit } }')"
  printf '%s' "$p"
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------
MODE_OVERRIDE=""
case "${1:-}" in
  stop)   exec docker stop "$NAME" ;;
  logs)   shift; exec docker logs -f --tail 200 "$NAME" "$@" ;;
  status)
    docker ps -a --filter "name=^${NAME}$" --format '  容器：{{.Status}}  ({{.Image}})'
    printf '  API  : http://127.0.0.1:%s/v1  → http=%s\n' "$PORT" \
      "$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null)"
    printf '  控制台: http://127.0.0.1:%s/    → http=%s\n' "$WEBUI_PORT" \
      "$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$WEBUI_PORT/" 2>/dev/null)"
    # 从端口绑定反推有没有开给局域网。
    # ⚠ 不能只看 "有没有 HostIp" —— 绑 127.0.0.1 时 HostIp 是 127.0.0.1（非空！），
    #   只有绑所有网卡时才是 0.0.0.0 / ::。所以要明确比对这两个值。
    BINDS="$(docker inspect -f \
      '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostIp}} {{end}}{{end}}' \
      "$NAME" 2>/dev/null || true)"
    case " $BINDS " in
      *" 0.0.0.0 "*|*" :: "*)
        ADV="$(primary_lan_ip)"
        if [ -n "$ADV" ]; then
          printf '  局域网: http://%s:%s/v1  （⚠ 无鉴权，同网段都能用）\n' "$ADV" "$PORT"
          printf '          http://%s:%s/    （网页控制台）\n' "$ADV" "$WEBUI_PORT"
        fi ;;
      *)
        printf '  局域网: 未开放（只有本机能连）—— 想开放用 ./docker/run.sh --lan\n' ;;
    esac
    exit 0 ;;
  shell)
    MODE_OVERRIDE=shell
    shift ;;
  -h|--help|help)
    sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

DETACH=""
MODE="serve"
for a in "$@"; do
  case "$a" in
    -d|--detach) DETACH="-d" ;;
    serve|headless|webui) MODE="$a" ;;
    --lan)   LAN=1 ;;
    --local) LAN=0 ;;
  esac
done

docker image inspect "$IMAGE" >/dev/null 2>&1 || die "本地没有镜像 $IMAGE
      先构建： ./docker/build.sh"

# ---------------------------------------------------------------------------
# 1. 选卡
# ---------------------------------------------------------------------------
detect_uuid() {
  [ -n "${GPU_UUID:-}" ] && { printf '%s' "$GPU_UUID"; return; }
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  # 优先 compute_cap=8.6 且空闲最多的那张（本项目要的就是 sm_86）
  nvidia-smi --query-gpu=uuid,compute_cap,memory.free --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', *' '
        { gsub(/ /,"",$2); if ($2=="8.6") { if ($3+0 > best) { best=$3+0; u=$1 } } }
        END { if (u != "") print u }' \
    || true
}
UUID="$(detect_uuid || true)"
[ -n "$UUID" ] || UUID="$(detect_uuid || true)"
if [ -z "$UUID" ]; then
  warn "nvidia-smi 没给出 sm_86 的卡，让容器自己从 /proc/driver/nvidia 探测"
else
  case "$UUID" in GPU-*) ;; *) die "GPU_UUID 必须是 GPU- 开头（拿到 '$UUID'）" ;; esac
  log "锁卡 $UUID"
fi

# ---------------------------------------------------------------------------
# 2. 让容器看见显卡
# ---------------------------------------------------------------------------
GPU_ARGS=()
if docker info --format '{{range $k,$v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null | grep -qw nvidia; then
  log "检测到 nvidia-container-runtime，用 --gpus all"
  GPU_ARGS+=(--gpus all)
else
  warn "没装 nvidia-container-toolkit，改为手工挂载设备节点与驱动库"
  warn "（想要 --gpus 的话： https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html）"

  for dev in /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
    [ -e "$dev" ] && GPU_ARGS+=(--device "$dev")
  done
  for dev in /dev/nvidia[0-9]*; do
    [ -e "$dev" ] && GPU_ARGS+=(--device "$dev")
  done

  # 驱动用户态库：版本必须和宿主内核模块一致，所以按实际版本文件挂，
  # 挂到容器里约定俗成的名字上（libcuda.so.1 等）。
  mount_driver_lib() {
    local pattern="$1" target="$2" f
    f="$(ls -1 $LIBDIR/${pattern} 2>/dev/null | grep -E '\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
    if [ -n "$f" ]; then
      GPU_ARGS+=(-v "$f:$LIBDIR/$target:ro")
    else
      warn "找不到 $pattern（可能在别的目录）"
    fi
  }
  mount_driver_lib 'libcuda.so.*'                  'libcuda.so.1'
  mount_driver_lib 'libnvidia-ptxjitcompiler.so.*' 'libnvidia-ptxjitcompiler.so.1'
  mount_driver_lib 'libnvidia-nvvm.so.*'           'libnvidia-nvvm.so.4'
  mount_driver_lib 'libnvidia-ml.so.*'             'libnvidia-ml.so.1'
  # nvidia-smi 是给人和给 app/env.sh 看的，顺手挂进去
  [ -x /usr/bin/nvidia-smi ] && GPU_ARGS+=(-v /usr/bin/nvidia-smi:/usr/bin/nvidia-smi:ro)
fi

# ---------------------------------------------------------------------------
# 3. 模型与日志
# ---------------------------------------------------------------------------
VOLS=()
if [ -d "$MODEL_DIR" ] && ls "$MODEL_DIR"/*.ninfer >/dev/null 2>&1; then
  log "挂载模型目录 $MODEL_DIR → /app/models"
  VOLS+=(-v "$MODEL_DIR:/app/models:ro")
else
  warn "$MODEL_DIR 下没有 .ninfer 模型；容器会启动失败并给出下载指引"
fi
mkdir -p "$ROOT/logs"
VOLS+=(-v "$ROOT/logs:/app/logs")

# ---------------------------------------------------------------------------
# 4. 对外暴露与否
# ---------------------------------------------------------------------------
# 容器里引擎必须绑 0.0.0.0（否则 docker 的 -p 转发进不来），所以容器自己判断不出
# 「宿主机到底把端口开给谁」。这两个变量就是把真相告诉容器：
#   BONSAI_LAN_EXPOSED  0/1，覆盖 bind 地址启发式
#   BONSAI_ADVERTISE_IP 对外该报哪个 IP（容器只看得见 172.17.x.x 的桥接地址，
#                       报出来对笔记本毫无用处）
BIND_PREFIX="127.0.0.1:"
NET_ENV=(-e "BONSAI_LAN_EXPOSED=0")
if [ "$LAN" = "1" ]; then
  ADV="${ADVERTISE_IP:-$(primary_lan_ip)}"
  BIND_PREFIX=""
  warn "局域网模式：端口会开到所有网卡上"
  warn "⚠ 引擎没有鉴权 —— 同网段任何人都能白用这张显卡，也能读 logs/request.jsonl"
  if [ -n "$ADV" ]; then
    NET_ENV=(-e "BONSAI_LAN_EXPOSED=1" -e "BONSAI_ADVERTISE_IP=$ADV")
    log "对外地址 http://${ADV}:${PORT}/v1"
  else
    NET_ENV=(-e "BONSAI_LAN_EXPOSED=1")
    warn "拿不到默认路由的地址，容器会报自己的网卡地址；可显式指定 ADVERTISE_IP=..."
  fi
fi

# ---------------------------------------------------------------------------
# 跑
# ---------------------------------------------------------------------------
if [ "$MODE_OVERRIDE" = "shell" ]; then
  log "进容器 bash（显卡已挂好，直接 ./start.sh 就能试）"
  exec docker run --rm -it "${GPU_ARGS[@]}" "${VOLS[@]}" "${NET_ENV[@]}" "$IMAGE" shell "$@"
fi

CMD=(docker run --rm --init --name "$NAME"
     "${GPU_ARGS[@]}" "${VOLS[@]}"
     -p "${BIND_PREFIX}${PORT}:8098"
     -p "${BIND_PREFIX}${WEBUI_PORT}:8099"
     "${NET_ENV[@]}"
     -e "GPU_UUID=${UUID}"
     -e "HOST=0.0.0.0"
     -e "PORT=8098"
     "$IMAGE" "$MODE")

if [ -n "$DETACH" ]; then
  CMD=("${CMD[@]:0:2}" -d "${CMD[@]:2}")
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  if ! "${CMD[@]}" >/dev/null; then
    die "启动失败（上面是 docker 的报错）。常见原因：端口被裸机引擎占着
      先 ./stop.sh 停掉裸机的，再试一次。"
  fi
  log "已在后台启动"
  sleep 3
  printf '  API    http://127.0.0.1:%s/v1\n' "$PORT"
  printf '  控制台  http://127.0.0.1:%s/\n' "$WEBUI_PORT"
  if [ "$LAN" = "1" ]; then
    ADV="${ADVERTISE_IP:-$(primary_lan_ip)}"
    [ -n "$ADV" ] && printf '  局域网  http://%s:%s/v1  （笔记本 / 手机用这个）\n' "$ADV" "$PORT"
  fi
  printf '  日志    ./docker/run.sh logs\n'
else
  log "前台启动（Ctrl-C 停止）；控制台 http://127.0.0.1:${WEBUI_PORT}/"
  exec "${CMD[@]}"
fi
