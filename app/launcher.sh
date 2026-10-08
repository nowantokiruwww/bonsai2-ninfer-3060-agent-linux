#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# launcher.sh —— 引擎生命周期（仓库自包含，不依赖任何仓库外路径）
#
#   ./start.sh    [--preset 名] [选项]     后台起 + 等就绪
#   ./stop.sh                              SIGTERM 干净停
#   ./restart.sh                          改完参数用这个
#   ./status.sh   [--json]                 状态（webUI 也调它）
#   ./logs.sh     [-f] [-n 200]            看日志
#   ./webui.sh    [--port 8099]            打开网页控制台
#
# 停止语义（实测，见 docs/PORTING-LEDGER.md L24）：
#   引擎对**单次 SIGINT 不退出**（要求 5 秒内按两次），所以必须用 SIGTERM。
#   用 SIGINT 的话每次 stop 要干等 60 秒超时再被 SIGKILL。
# ---------------------------------------------------------------------------

set -uo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$APP_DIR/env.sh"
# shellcheck source=presets.env
. "$APP_DIR/presets.env"

die() { echo "[fail] $*" >&2; exit 1; }
info() { echo "[info] $*"; }
ok()   { echo "[ok]   $*"; }

mkdir -p "$LOG_DIR" "$CONF_DIR" "$TUNE_LOG_DIR"

# --------------------------------------------------------------------------
# 进程发现
# --------------------------------------------------------------------------
pid_from_file() {
  [ -f "$PIDF" ] || return 1
  local p; p="$(cat "$PIDF" 2>/dev/null || true)"
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  printf '%s' "$p"
}

pid_from_proc() {
  # 按二进制路径精确匹配，避免误伤别的 ninfer
  pgrep -f "^$BIN " 2>/dev/null | head -1
}

engine_pid() {
  pid_from_file || pid_from_proc || return 1
}

is_running() { engine_pid >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# 就绪判定
#
# ⚠ 引擎在权重加载完成前就已经监听端口，此时 /v1/models 回 503。
#   所以"端口通了" ≠ "就绪"，必须判 **HTTP 200**。本项目踩过这个坑：
#   探针把 503 当就绪，结果 20 次请求全部连接失败。
# --------------------------------------------------------------------------
http_code() {
  curl -s -o /dev/null -w '%{http_code}' -m 3 "$1" 2>/dev/null || echo 000
}

wait_ready() {
  local host="$1" port="$2" timeout="${3:-300}" waited=0 code
  while [ "$waited" -lt "$timeout" ]; do
    if ! is_running; then
      echo "[fail] 引擎进程已退出（未就绪）—— 看日志：$SERVICE_LOG" >&2
      return 1
    fi
    code="$(http_code "http://$host:$port/v1/models")"
    if [ "$code" = "200" ]; then
      ok "就绪（${waited}s）：http://$host:$port/v1"
      return 0
    fi
    sleep 2; waited=$((waited + 2))
    if [ $((waited % 20)) -eq 0 ]; then
      info "等待就绪… ${waited}s（当前 http=$code；503 表示权重仍在加载）"
    fi
  done
  echo "[fail] 等待就绪超时（${timeout}s）—— 看日志：$SERVICE_LOG" >&2
  return 1
}

# --------------------------------------------------------------------------
# 命令行拼装
# --------------------------------------------------------------------------
: "${MAX_TOKENS_DEFAULT:=16384}"

build_cmd() {
  local host="$1" port="$2" kv_dtype="$3" kv_cap="$4" spec="$5" extra="$6"
  local tflags sflags
  tflags="$(thinking_flags)" || return 1
  sflags="$(sampling_flags)" || return 1
  CMD=( "$BIN" "$MODEL_FILE"
        --host "$host" --port "$port" --model-id "$MODEL_ID"
        --max-context "$kv_cap" --kv-capacity "$kv_cap" --kv-dtype "$kv_dtype" )
  # shellcheck disable=SC2206
  [ -n "$spec" ]  && CMD+=( $spec )
  # shellcheck disable=SC2206
  [ -n "$tflags" ] && CMD+=( $tflags )
  # shellcheck disable=SC2206
  [ -n "$sflags" ] && CMD+=( $sflags )
  # shellcheck disable=SC2206
  [ -n "$extra" ] && CMD+=( $extra )
  CMD+=( --request-log-jsonl "$REQ_LOG" )
}

show_cmd() {
  local i
  printf '  '
  for i in "${CMD[@]}"; do
    case "$i" in
      "$ROOT"/*) printf '%s ' "${i#"$ROOT"/}" ;;
      *)         printf '%s ' "$i" ;;
    esac
  done
  printf '\n'
}

# --------------------------------------------------------------------------
# 前置检查
# --------------------------------------------------------------------------
preflight() {
  local fail=0

  [ -x "$BIN" ] || { echo "[fail] 缺少引擎：$BIN（先跑 ./install.sh）"; fail=1; }
  [ -f "$MODEL_FILE" ] || { echo "[fail] 缺少模型：$MODEL_FILE（先跑 ./install.sh）"; fail=1; }
  [ -f "$PROFILE" ] || { echo "[fail] 缺少标定 profile：$PROFILE"; fail=1; }

  if [ -f "$MODEL_FILE" ]; then
    local sz; sz="$(stat -c %s "$MODEL_FILE" 2>/dev/null || echo 0)"
    if [ "$sz" != "$MODEL_BYTES" ]; then
      echo "[warn] 模型体积 $sz ≠ 期望 $MODEL_BYTES（可能不完整）"
    fi
  fi

  local uuid; uuid="$(resolve_gpu_uuid)"
  if ! apply_gpu_lock "$uuid"; then fail=1; fi
  if [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
    ok "锁卡 CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
    ok "实卡 $(gpu_name_of_uuid "$uuid")  空闲 $(gpu_free_of_uuid "$uuid") MiB"
    if ! "$BIN" --help >/dev/null 2>&1 && [ ! -x "$BIN" ]; then :; fi
  fi

  return $fail
}

# --------------------------------------------------------------------------
# start / stop
# --------------------------------------------------------------------------
do_stop() {
  local pid
  if ! is_running; then
    ok "本来就没在跑"
    rm -f "$PIDF"
    return 0
  fi
  pid="$(engine_pid)"
  info "停止 pid=$pid（SIGTERM）"
  kill -TERM "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
    sleep 0.5; waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "[warn] 20s 未退出，SIGKILL" >&2
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PIDF"
  # 兜底：按二进制路径清残留
  local rest; rest="$(pid_from_proc || true)"
  [ -n "${rest:-}" ] && kill -TERM "$rest" 2>/dev/null || true
  ok "已停止"
}

start_engine() {
  local foreground="$1"; shift
  local host="$1" port="$2" kv_dtype="$3" kv_cap="$4" spec="$5" extra="$6"

  preflight || die "前置检查未通过（见上）"
  is_running && die "已经在跑（pid=$(engine_pid)）—— 先 ./stop.sh"

  build_cmd "$host" "$port" "$kv_dtype" "$kv_cap" "$spec" "$extra" || die "参数拼装失败"

  echo
  echo "  预设     : ${PRESET:-custom}  ${P_DESC:-}"
  echo "  思考     : ${P_THINKING:-on} ${P_EFFORT:+effort=$P_EFFORT }${P_BUDGET:+budget=$P_BUDGET}"
  echo "  采样     : ${P_SAMPLE:-v100}"
  echo "  投机     : $spec"
  echo "  KV       : $kv_dtype @ $kv_cap"
  echo "  锁卡     : ${CUDA_VISIBLE_DEVICES:-<未锁>}  $(gpu_name_of_uuid "${CUDA_VISIBLE_DEVICES:-}")"
  echo "  日志     : ${SERVICE_LOG#"$ROOT"/}"
  echo "  命令     :"
  show_cmd
  echo

  if [ "$foreground" = "1" ]; then
    info "前台启动（Ctrl+C 退出；引擎需要 SIGTERM，用 ./stop.sh 最省事）"
    echo $$ > "$PIDF"
    exec "${CMD[@]}"
  fi

  info "后台启动…"
  nohup "${CMD[@]}" >> "$SERVICE_LOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$PIDF"
  wait_ready "$host" "$port" "${READY_SECS:-300}"
}

# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------
read_running_flags() {
  local pid="$1"
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
}

cmdline_flag() {
  local flags="$1" name="$2"
  # shellcheck disable=SC2086
  set -- $flags
  while [ $# -gt 0 ]; do
    case "$1" in
      "$name") shift; printf '%s' "${1:-}"; return 0 ;;
      *) shift ;;
    esac
  done
  return 1
}

cmdline_has() {
  local flags="$1" name="$2"
  # shellcheck disable=SC2086
  set -- $flags
  for a in "$@"; do [ "$a" = "$name" ] && return 0; done
  return 1
}

do_status() {
  local json="$1"
  local pid="" flags="" running=false endpoint="000" uptime_s=""
  local kv_dtype="" kv_cap="" think="unknown" budget="" effort="" sampling="unknown"
  local host="$HOST" port="$PORT" spec=""

  if is_running; then
    running=true
    pid="$(engine_pid)"
    flags="$(read_running_flags "$pid")"
    local et; et="$(stat -c %Y "/proc/$pid" 2>/dev/null || echo 0)"
    [ "$et" != "0" ] && uptime_s=$(( $(date +%s) - et ))
    host="$(cmdline_flag "$flags" --host || echo "$HOST")"
    port="$(cmdline_flag "$flags" --port || echo "$PORT")"
    kv_dtype="$(cmdline_flag "$flags" --kv-dtype || true)"
    kv_cap="$(cmdline_flag "$flags" --kv-capacity || true)"
    budget="$(cmdline_flag "$flags" --default-thinking-budget || true)"
    effort="$(cmdline_flag "$flags" --default-reasoning-effort || true)"
    if cmdline_has "$flags" --no-thinking; then think="off"; else think="on"; fi
    if cmdline_has "$flags" --greedy; then sampling="greedy"; else sampling="sampled"; fi
    spec="$(cmdline_flag "$flags" --spec || true)"
    endpoint="$(http_code "http://$host:$port/v1/models")"
  fi

  if [ "$json" = "1" ]; then
    local uuid; uuid="$(resolve_gpu_uuid)"
    printf '{'
    printf '"running":%s,' "$running"
    printf '"pid":%s,' "${pid:-null}"
    printf '"uptime_s":%s,' "${uptime_s:-null}"
    printf '"host":"%s","port":%s,' "$host" "${port:-null}"
    printf '"endpoint_http":"%s",' "$endpoint"
    printf '"kv_dtype":"%s","kv_capacity":"%s",' "$kv_dtype" "$kv_cap"
    printf '"thinking":"%s","budget":"%s","effort":"%s",' "$think" "$budget" "$effort"
    printf '"sampling":"%s","spec":"%s",' "$sampling" "$spec"
    printf '"gpu_uuid":"%s","gpu_name":"%s","gpu_free_mib":"%s",' \
           "$uuid" "$(gpu_name_of_uuid "$uuid")" "$(gpu_free_of_uuid "$uuid")"
    printf '"model":"%s",' "$MODEL_ID"
    printf '"log_bytes":%s,' "$(stat -c %s "$SERVICE_LOG" 2>/dev/null || echo 0)"
    printf '"req_log_bytes":%s,' "$(stat -c %s "$REQ_LOG" 2>/dev/null || echo 0)"
    printf '"root":"%s"' "$ROOT"
    printf '}\n'
    return 0
  fi

  if [ "$running" = "true" ]; then
    ok "运行中  pid=$pid  已运行 ${uptime_s}s"
    echo "  端点      http://$host:$port/v1  →  http=$endpoint"
    echo "  模型      $MODEL_ID"
    echo "  KV        ${kv_dtype:-?} @ ${kv_cap:-?}"
    echo "  思考      $think ${effort:+effort=$effort }${budget:+budget=$budget}"
    echo "  采样      $sampling    投机 ${spec:-none}"
    echo "  日志      ${SERVICE_LOG#"$ROOT"/}  ($(stat -c %s "$SERVICE_LOG" 2>/dev/null || echo 0) B)"
  else
    echo "[ -- ] 未运行"
  fi
  echo "  仓库根    $ROOT"
  local uuid; uuid="$(resolve_gpu_uuid)"
  echo "  可用卡    $uuid  $(gpu_name_of_uuid "$uuid")  空闲 $(gpu_free_of_uuid "$uuid") MiB"
  if [ -z "$pid" ] && [ -n "$uuid" ]; then
    echo "  提示      启动：./start.sh    网页控制台：./webui.sh"
  fi
}

# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
usage() {
  cat <<EOF
ninfer-3060-bonsai —— 引擎启停与日志

  ./start.sh   [选项]        后台启动并等待就绪
  ./stop.sh                  停止（SIGTERM，约 5 秒）
  ./restart.sh [选项]        重启
  ./status.sh  [--json]      查看状态
  ./logs.sh    [-f] [-n N]   查看/跟踪日志
  ./webui.sh   [--port N]    网页控制台（推荐）
  ./presets.sh               列出预设档位

选项（默认读 config/runtime.env，可直接覆盖）：
  --preset NAME    $PRESET_NAMES
  --ctx N          上下文=KV 容量（默认 $KV_CAPACITY；支持 76k 写法）
  --kv-dtype NAME  KV 量化（默认 $KV_DTYPE）
  --port N         端口（默认 $PORT）
  --host ADDR      监听地址（默认 $HOST）
  --spec "..."     投机参数（默认 "$SPEC_FLAGS"）
  --extra "..."    追加任意引擎参数
  --foreground     前台运行（systemd 用）
EOF
}

parse_args() {
  PRESET="${PRESET:-balanced}"
  preset_apply "$PRESET" || exit 1
  FOREGROUND=0
  NO_WAIT=0
  HOST_OV=""; PORT_OV=""; KV_DTYPE_OV=""; KV_CAP_OV=""; SPEC_OV=""; EXTRA_OV=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --preset)     PRESET="$2"; preset_apply "$PRESET" || exit 1; shift 2 ;;
      --ctx)        KV_CAP_OV="$2"; shift 2 ;;
      --kv-dtype)   KV_DTYPE_OV="$2"; shift 2 ;;
      --port)       PORT_OV="$2"; shift 2 ;;
      --host)       HOST_OV="$2"; shift 2 ;;
      --spec)       SPEC_OV="$2"; shift 2 ;;
      --extra)      EXTRA_OV="$2"; shift 2 ;;
      --foreground|-f) FOREGROUND=1; shift ;;
      --no-wait)    NO_WAIT=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "[fail] 未知参数 '$1'" >&2; usage >&2; exit 1 ;;
    esac
  done

  # 归一化 76k 这类写法
  case "${KV_CAP_OV:-}" in
    *k|*K) KV_CAP_OV=$(( ${KV_CAP_OV%[kK]} * 1024 )) ;;
  esac
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    start|serve)
      parse_args "$@"
      if [ "${KV_CAP_OV:-}" = "76k" ]; then KV_CAP_OV=76768; fi
      start_engine "$FOREGROUND" \
        "${HOST_OV:-$HOST}" "${PORT_OV:-$PORT}" \
        "${KV_DTYPE_OV:-$KV_DTYPE}" "${KV_CAP_OV:-$KV_CAPACITY}" \
        "${SPEC_OV:-$SPEC_FLAGS}" "${EXTRA_OV:-$EXTRA_FLAGS}"
      ;;
    stop)    do_stop ;;
    restart)
      parse_args "$@"
      do_stop
      if [ "${KV_CAP_OV:-}" = "76k" ]; then KV_CAP_OV=76768; fi
      start_engine "$FOREGROUND" \
        "${HOST_OV:-$HOST}" "${PORT_OV:-$PORT}" \
        "${KV_DTYPE_OV:-$KV_DTYPE}" "${KV_CAP_OV:-$KV_CAPACITY}" \
        "${SPEC_OV:-$SPEC_FLAGS}" "${EXTRA_OV:-$EXTRA_FLAGS}"
      ;;
    status)
      local json=0
      [ "${1:-}" = "--json" ] && json=1
      load_runtime_env
      do_status "$json"
      ;;
    presets)
      echo "预设档位："; preset_table
      echo; echo "  当前 config/runtime.env：" ; load_runtime_env
      echo "    KV        $KV_DTYPE @ $KV_CAPACITY"
      echo "    投机      $SPEC_FLAGS"
      echo "    追加      $EXTRA_FLAGS"
      ;;
    logs)
      local f=0 n=200
      while [ $# -gt 0 ]; do
        case "$1" in -f|--follow) f=1; shift ;; -n) n="$2"; shift 2 ;; *) shift ;; esac
      done
      [ -f "$SERVICE_LOG" ] || { echo "（还没有日志：$SERVICE_LOG）"; exit 0; }
      if [ "$f" = "1" ]; then tail -n "$n" -F "$SERVICE_LOG"; else tail -n "$n" "$SERVICE_LOG"; fi
      ;;
    check)   load_runtime_env; preflight && ok "前置检查通过" ;;
    cmd)     parse_args "$@"; load_runtime_env
             build_cmd "${HOST_OV:-$HOST}" "${PORT_OV:-$PORT}" "${KV_DTYPE_OV:-$KV_DTYPE}" \
                       "${KV_CAP_OV:-$KV_CAPACITY}" "${SPEC_OV:-$SPEC_FLAGS}" "${EXTRA_OV:-$EXTRA_FLAGS}"
             show_cmd ;;
    "")      load_runtime_env; do_status 0; echo; usage ;;
    *)       echo "[fail] 未知子命令 '$sub'" >&2; usage >&2; exit 1 ;;
  esac
}

main "$@"
