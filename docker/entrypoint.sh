#!/usr/bin/env bash
# ===========================================================================
#  容器入口
# ===========================================================================
#
#  职责只有四件：
#    1. 找出要用哪张卡（必须是 UUID，不能用序号）
#    2. 在容器内生成 config/runtime.env（宿主那份含宿主机绝对路径，不能用）
#    3. 检查载荷与模型在不在（不在就给一句人话，而不是让引擎报段错误）
#    4. 按模式起进程，并保证 Ctrl-C / docker stop 能干净收尾
#
#  模式（docker run <image> <模式>）：
#    serve     默认。引擎 + 网页控制台一起跑；控制台里能启停引擎，容器不退出
#    headless  只跑引擎，前台，适合当纯 API 服务
#    webui     只跑网页控制台（引擎自己另起）
#    shell     进 bash
#    其它      透传给 app/launcher.sh（比如 `status`、`presets`、`stop`）
#
# ===========================================================================
set -uo pipefail

ROOT=/app
ENVF="$ROOT/config/runtime.env"
WEBUI_LOG="$ROOT/logs/webui.log"
MODE="${1:-serve}"

log() { printf '[容器] %s\n' "$*"; }
die() { printf '[容器] 错误：%s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. 找卡
# ---------------------------------------------------------------------------
#
# 优先级：
#   a) 外面传进来的 GPU_UUID（docker/run.sh 会自动探测并传）
#   b) /proc/driver/nvidia/gpus/*/information —— 只要挂进了 /dev/nvidia*，
#      这个 procfs 目录在容器里就看得见，里面有型号和 UUID，不需要 nvidia-smi
#
# 为什么非要 UUID：CUDA 运行时的设备枚举顺序与 nvidia-smi **相反**。
# 用序号 0 锁卡，在这台双卡机器上会锁到 V100，然后报
# "no kernel image is available for execution on the device"。
detect_gpu_uuid() {
  if [ -n "${GPU_UUID:-}" ]; then
    printf '%s' "$GPU_UUID"; return 0
  fi
  local info uuid model fallback=""
  for info in /proc/driver/nvidia/gpus/*/information; do
    [ -f "$info" ] || continue
    uuid="$(awk -F':' '/^GPU UUID:/{gsub(/^[ \t]+/,"",$2); print $2; exit}' "$info")"
    model="$(awk -F':' '/^Model:/{gsub(/^[ \t]+/,"",$2); print $2; exit}' "$info")"
    [ -n "$uuid" ] || continue
    case "$model" in
      *RTX*|*GeForce*|*GeForce*RTX*) printf '%s' "$uuid"; return 0 ;;
    esac
    [ -n "$fallback" ] || fallback="$uuid"
  done
  if [ -n "$fallback" ]; then printf '%s' "$fallback"; return 0; fi
  return 1
}

GPU_UUID_DETECTED="$(detect_gpu_uuid || true)"
if [ -z "$GPU_UUID_DETECTED" ]; then
  cat >&2 <<'EOF'
[容器] 错误：看不见任何 NVIDIA 显卡。

  这个容器不会自带驱动 —— 它需要宿主机把设备节点放进来。三种办法：

  1) 装了 nvidia-container-toolkit（推荐）
         docker run --gpus all ...

  2) 用本仓库的启动器，它会自动探测并挂载宿主机的驱动库
         ./docker/run.sh

  3) 手工
         docker run --device /dev/nvidiactl --device /dev/nvidia0 \
                    --device /dev/nvidia-uvm --device /dev/nvidia-modeset ...

  当前 /proc/driver/nvidia/gpus/ 下的内容：
EOF
  ls -la /proc/driver/nvidia/gpus/ 2>&1 | sed 's/^/    /' >&2 || echo "    （目录不存在）" >&2
  exit 1
fi
export GPU_UUID="$GPU_UUID_DETECTED"
export CUDA_VISIBLE_DEVICES="$GPU_UUID"
# 不打印 UUID 本身：容器日志经常被贴到 issue / 聊天里，那是本机的硬件唯一标识。
# 需要核对到底选了哪张卡时，在容器里看 /proc/driver/nvidia/gpus/*/information。
log "已锁定兼容 GPU（UUID 已隐藏）"

# ---------------------------------------------------------------------------
# 2. 生成容器内的 runtime.env
# ---------------------------------------------------------------------------
#
# 宿主机的 config/runtime.env 里有宿主机的绝对路径和宿主机看到的卡序，
# 拿到容器里可能整个都是错的。所以容器内一律自己生成一份。
# 想覆盖就挂载自己的文件到 /app/config/runtime.env —— 存在就不覆盖。
# 容器里必须监听 0.0.0.0，否则 -p 映射不进来
HOST=${HOST:-0.0.0.0}
PORT=${PORT:-8098}
MODEL_ID=${MODEL_ID:-bonsai2-27b}

# 锁卡一律用 UUID（上面已探测）
GPU_UUID=$GPU_UUID

# KV 量化与容量
#   rk2v4-e8 是 12G 卡上能开最大上下文的量化；容量必须实测，不要猜。
#   空卡实测能到 76768，但桌面上开个浏览器就会掉，默认取 49152。
: "${KV_DTYPE:=rk2v4-e8}"
: "${KV_CAPACITY:=49152}"

# 投机解码：dflash2 + 7 个草稿 token 是实测吞吐最好的一档
: "${SPEC_FLAGS:=--spec dflash2 --draft-tokens 7}"

# 采样与思考
#   思考预算是"收口"不是"提速"：4096 会让每个请求烧满 4096 个思考 token，
#   同一任务墙钟 68 秒；1024 只要 44 秒。
#   ⚠ 不要加 --greedy，也不要加 --no-thinking：两者合用会让模型逐字节重复
#     同一个工具调用陷入死循环（病历 L26）。
: "${EXTRA_FLAGS:=--max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 --default-reasoning-effort medium --default-thinking-budget 1024 --request-log-jsonl $ROOT/logs/request.jsonl}"

# 借 app/env.sh 的 urls_for_bind / is_lan_exposed（地址口径的单一事实源）。
# 必须放在上面 HOST 定值之后 —— env.sh 里是 `: "${HOST:=127.0.0.1}"`，
# 先 source 会把容器该绑的 0.0.0.0 顶成 127.0.0.1，-p 就转发不进来了。
# shellcheck source=../app/env.sh
. "$ROOT/app/env.sh"

# 自检：如果 env.sh 没真的被 source 到，宁可在这里响亮地死掉，
# 也不要等到 start_webui 里蹦一句 `urls_for_bind: command not found`
# （那正是上面那个 heredoc 写错时的症状 —— 见 L31）。
command -v urls_for_bind >/dev/null 2>&1 \
  || die "app/env.sh 没有被 source 到（urls_for_bind 未定义）。
      检查 docker/entrypoint.sh 里的 heredoc 是不是把 source 语句吞进文本了。"

# ---------------------------------------------------------------------------
# 2b. 写容器内的 config/runtime.env
# ---------------------------------------------------------------------------
#
# ⚠ 下面这个 heredoc 只允许**写数据**，任何要执行的语句都必须放在 EOF 之后。
#   这里踩过一次：一度把 `HOST=` / `. env.sh` 等语句写在 heredoc 里面，
#   结果是它们被当成文本写进了 runtime.env（靠 heredoc 会展开 ${VAR:-默认}
#   侥幸没出错），而 entrypoint 自己从头到尾没 source 到 env.sh，
#   于是容器日志里蹦出 `urls_for_bind: command not found`。
if [ ! -f "$ENVF" ]; then
  log "生成 config/runtime.env（容器内）"
  cat > "$ENVF" <<EOF
# ---------------------------------------------------------------------------
# 由容器 entrypoint 生成（$(date '+%Y-%m-%d %H:%M:%S')）
# 宿主机的同名文件不要直接挂进来：里面有宿主机的绝对路径。
# 想用自定义配置就挂载自己的文件覆盖本文件，存在即不覆盖。
# ---------------------------------------------------------------------------

# 容器里必须监听 0.0.0.0，否则 -p 映射不进来
HOST=${HOST}
PORT=${PORT}
MODEL_ID=${MODEL_ID}

# 锁卡一律用 UUID（entrypoint 已探测，见脚本顶部注释）
GPU_UUID=${GPU_UUID}

# KV 量化与容量
KV_DTYPE=${KV_DTYPE}
KV_CAPACITY=${KV_CAPACITY}

# 投机解码
SPEC_FLAGS="${SPEC_FLAGS}"

# 采样与思考
EXTRA_FLAGS="${EXTRA_FLAGS}"
EOF
else
  log "沿用已存在的 config/runtime.env"
fi

mkdir -p "$ROOT/logs"

# ---------------------------------------------------------------------------
# 3. 载荷与模型
# ---------------------------------------------------------------------------
[ -x "$ROOT/runtime/bin/ninfer-serve" ] || die "缺少引擎：$ROOT/runtime/bin/ninfer-serve
      镜像构建时 runtime/ 是空的。
      先跑 ./scripts/fetch-runtime.sh（或 --auto 从本机已有部署里取），再重新构建。"
[ -f "$ROOT/runtime/profiles/device-profiles.json" ] || die "缺少标定文件：$ROOT/runtime/profiles/device-profiles.json"

MODEL_FILE="$ROOT/models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer"
if [ ! -f "$MODEL_FILE" ]; then
  cat >&2 <<EOF
[容器] 错误：没有模型。

  要的是：$MODEL_FILE

  模型 9.5 GB，不烧在镜像里（会让镜像变成 12 GB 且无法更新）。两种办法：

  1) 挂载宿主机的模型目录（推荐，零拷贝）
         docker run ... -v /宿主机路径/models:/app/models ...

     本仓库的启动器就是这么干的：
         ./docker/run.sh

  2) 进容器自己下（约 9.5 GB，走 hf-mirror）
         docker run ... -it <镜像> shell
         # 容器内：
         ./scripts/fetch-model.sh

EOF
  exit 1
fi

MODEL_SZ="$(stat -c %s "$MODEL_FILE" 2>/dev/null || echo 0)"
if [ "$MODEL_SZ" != "9520051456" ]; then
  log "警告：模型体积 $MODEL_SZ ≠ 期望 9520051456，可能不完整"
fi
log "模型就位（$(( MODEL_SZ / 1024 / 1024 / 1024 )) GiB）"

# ---------------------------------------------------------------------------
# 4. 收尾与模式分发
# ---------------------------------------------------------------------------
cleanup() {
  log "收到停止信号，收尾…"
  bash "$ROOT/app/launcher.sh" stop >/dev/null 2>&1 || true
  [ -n "${WEBUI_PID:-}" ] && kill -TERM "$WEBUI_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  log "已停止"
}
trap cleanup TERM INT

start_webui() {
  log "网页控制台 → http://0.0.0.0:${WEBUI_PORT:-8099}"
  # 「别人该连哪个地址」由宿主机通过 BONSAI_ADVERTISE_IP 告诉我们，别报桥接地址
  local u
  while IFS= read -r u; do
    [ -n "$u" ] && log "              $u/"
  done < <(urls_for_bind 0.0.0.0 "${WEBUI_PORT:-8099}")
  if is_lan_exposed 0.0.0.0; then
    log "⚠ 局域网可访问：控制台与引擎都没有鉴权，同网段的人都能用这张显卡"
    log "  要收回：宿主机上改成 ./docker/run.sh --local"
  fi
  python3 "$ROOT/webui/server.py" --host 0.0.0.0 --port "${WEBUI_PORT:-8099}" \
    >> "$WEBUI_LOG" 2>&1 &
  WEBUI_PID=$!
}

case "$MODE" in
  serve)
    # 引擎后台起，控制台在前台守着。
    # 这样控制台里的「停止/启动」按钮才真的能控制引擎 ——
    # 如果引擎是 PID 1，一停容器就没了。
    start_webui
    log "启动引擎（首次要 30–40 秒加载 7.99 GiB 权重）"
    if bash "$ROOT/app/launcher.sh" start; then
      log "引擎就绪"
    else
      log "引擎启动失败，但控制台还在跑 —— 打开网页看日志"
    fi
    while kill -0 "$WEBUI_PID" 2>/dev/null; do sleep 2; done
    ;;

  headless)
    log "无界面模式：引擎前台运行"
    exec bash "$ROOT/app/launcher.sh" serve --foreground
    ;;

  webui)
    exec python3 "$ROOT/webui/server.py" --host 0.0.0.0 --port "${WEBUI_PORT:-8099}"
    ;;

  shell|bash)
    # 不带参数 = 交互 shell；`docker run … shell -c '…'` 也能用（方便排查）
    shift || true
    exec bash "$@"
    ;;

  *)
    exec bash "$ROOT/app/launcher.sh" "$@"
    ;;
esac
