#!/usr/bin/env bash
# 96-tune-serve.sh — 3060 bonsai2 的**手动调参启动器**（前台，参数全部走命令行）
#
# 为什么有这个东西：
#   systemd + config/runtime.env 那条线是"固定生产档"，适合长期挂机、开机可用；
#   但它把参数钉死了 —— 想换上下文、想让模型闭嘴（no-thinking）、想换采样，
#   都得先改文件再重启服务，而且日志跑在另一个地方（gnome-terminal 弹窗，还可能被浏览器挡住）。
#   调参要的是：**每次都能换一组参数、日志直接打在当前终端、Ctrl-C 就干净退出。**
#   这个脚本把那种体验搬回来（等价于 Windows 时期"自己填参数、在 shell 里起"）。
#
#   它**不动 systemd 单元**，除非你显式给 --persist（那时才写回 runtime.env 并重启服务）。
#
# 用法速查：
#   ./tune.sh                       # 打印预设表与当前生效参数（不启动）
#   ./tune.sh fast                  # no-thinking + V100 采样（最快，见 --help 的取舍）
#   ./tune.sh balanced              # 思考预算 1024（= 当前生产档）
#   ./tune.sh --ctx 76k --dry-run   # 只看会执行什么命令
#   ./tune.sh --ctx 49152 --thinking off --sample v100 --k 7
#   ./tune.sh fast --no-thinking --probe
#   ./tune.sh --persist balanced    # 把该档写回 config/runtime.env 并重启 systemd 单元
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"; HERE="$(dirname "$SELF")"
# 部署根：环境变量 > 脚本所在目录（部署态）> 上一级（工程态 scripts/）> 默认部署根
PREFIX="${BONSAI_PREFIX:-}"
if [ -z "$PREFIX" ]; then
  if   [ -f "$HERE/config/runtime.env" ];    then PREFIX="$HERE"
  elif [ -f "$HERE/../config/runtime.env" ]; then PREFIX="$(cd "$HERE/.." && pwd)"
  else PREFIX="$HOME/bonsai-ninfer-3060"; fi  # verify:allow-outside-path（历史编译期流水线，部署根在仓库外）
fi
ENVF="$PREFIX/config/runtime.env"
UNIT=bonsai2-ninfer-3060.service

die() { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
inf() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
wrn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }

[ -f "$ENVF" ] || die "找不到 $ENVF（用 BONSAI_PREFIX=... 指定部署根）"
# runtime.env 是 systemd EnvironmentFile 风格，bash source 也成立（含空格的值已加引号）
# shellcheck disable=SC1090
. "$ENVF"

# ⚠⚠ **必须 export**，不能只是 source 进来当 shell 变量：
#   CUDA 运行时的设备序与 nvidia-smi 可能相反（本机就是反的），不锁卡时引擎会挑到
#   另一块卡上。/usr/bin 实测过一次：只 source 不 export → 引擎去标定 V100(sm_70) 并
#   死在 `cudaErrorNoKernelImageForDevice`。runtime-tools.sh 里也是这么 export 的，
#   这里必须保持一致（见 PORTING-LEDGER 的锁卡条目）。
[ -d "$PREFIX/lib" ] && export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-${GPU_UUID:-}}"
export CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"
export NINFER_DEVICE_PROFILES="${NINFER_DEVICE_PROFILES:-$PREFIX/profiles/device-profiles.json}"

# 锁卡自检：宁可拒绝启动，也不要跑到别的卡上去
case "$CUDA_VISIBLE_DEVICES" in
  GPU-*) : ;;
  "")    die "CUDA_VISIBLE_DEVICES 为空 —— 请在 $ENVF 里设 GPU_UUID=GPU-xxxx（禁止不锁卡启动）" ;;
  *)     die "CUDA_VISIBLE_DEVICES='$CUDA_VISIBLE_DEVICES' 不是 GPU- 开头的 UUID —— 设备序不保证，拒绝启动" ;;
esac

usage() {
  cat <<'EOF'
tune.sh —— 手动调参启动器（前台运行，Ctrl-C 一次干净退出）

预设（也可以一个都不用，纯手拼参数）：
  fast        不思考 + V100 采样      代码/工具 65–88、中文散文 ~26；⚠ 见下方"fast 的取舍"
  balanced    思考预算 1024          当前生产档；固定 agent 任务中位墙钟 44.2s
  think       思考预算 4096          更肯想；同任务中位墙钟 67.8s
  deep        思考预算 8192 + high   最肯想，也最慢
  greedy      同 balanced 但 --greedy 强制 argmax（可复现，但**没有随机逃逸路径**）

⚠ 速度的天花板（先读这个，否则会白调）
  decode tok/s ≈ 显存带宽地板(≈26) × (1 + 草稿数 × 接受率)。
  接受率取决于**请求类型**，不取决于你的参数：
    代码/工具 37–52% → 65–88 tok/s；旧部署的 DSH 流量 95% → ~200 tok/s；
    **中文散文只有 6% → ~26 tok/s**（关掉投机同样是 26，逐位相同）。
  所以"中文散文到不了 120"是这张卡的硬件事实，不是配置问题（病历 L29）。

可调参数（覆盖预设）：
  --ctx N           上下文 = KV 容量，同时设 --max-context/--kv-capacity。
                    接受 49152 / 32k / 76k / 65536 这类写法。⚠ 上限随桌面占用浮动（L21）
  --kv-dtype X      KV 量型：rk2v4-e8(默认) rk4v4-e8 int8 bf16 fp8 k8v4 rk4v4 rk8v4 nvfp4
  --thinking on|off 思考开关。off = 追加 --no-thinking（且不传 effort/budget，二者互斥）
  --budget N        思考预算（收口机制：到点服务端补思考终止标记逼它作答）
  --effort E        none|minimal|low|medium|high|xhigh|max
  --sample v100|greedy|none
                    v100   = --temperature 1.0 --top-p 0.95 --top-k 20
                    greedy = --greedy（强制 argmax）
                    none   = 不传采样参数，用引擎默认
  --k N             草稿窗口（1..15，默认 7）
  --spec X          dflash2(默认) | dflash | mtp | none
  --ngram N         ngram 草稿窗口（不传 = 引擎默认 15）
  --max-concurrency N  默认 1（引擎允许 1..8）
  --port N / --host H  默认取 runtime.env
  --reqlog / --no-reqlog  是否写 logs/request.jsonl（默认写；四类事件，不含 prompt 正文）
  --dry-run         只打印将要执行的完整命令，不启动
  --no-stop         启动前不去停已经在跑的实例（默认会先停干净）
  --probe           就绪后自动跑复读锁死探针（若找得到）
  --persist         把这一组参数写回 config/runtime.env（带备份）并重启 systemd 单元，
                    不在前台跑。适合"调好了就固化"。
  -h, --help        本帮助

fast 的取舍（务必读）：
  不思考能让 decode 飙到 120–180 tok/s，但它同时砍掉了模型唯一的自省通道。
  在 --greedy（强制 argmax、无随机逃逸）下，实测会让模型把**同一条工具调用逐字节重复 43 次**、
  harness 注入 10 次提醒全部无效、永不自愈（PORTING-LEDGER L26 实战事故）。
  所以 fast 预设刻意配 --sample v100 而**不是** greedy：保留随机逃逸。
  拿不准就先加 --probe 跑一遍探针，再决定要不要长期用。
EOF
}

# 记忆用的预设表（每个预设就是一组默认值，命令行永远覆盖它）
preset_fast()     { P_THINKING=off; P_BUDGET="";   P_EFFORT="";     P_SAMPLE=v100;   }
preset_balanced() { P_THINKING=on;  P_BUDGET=1024; P_EFFORT=medium; P_SAMPLE=v100;   }
preset_think()    { P_THINKING=on;  P_BUDGET=4096; P_EFFORT=medium; P_SAMPLE=v100;   }
preset_deep()     { P_THINKING=on;  P_BUDGET=8192; P_EFFORT=high;   P_SAMPLE=v100;   }
preset_greedy()   { P_THINKING=on;  P_BUDGET=1024; P_EFFORT=medium; P_SAMPLE=greedy; }

NO_ARGS=$#
ARGS=("$@")

# ---- 第一趟：只认预设，把它铺成默认值 ----
ARG_PRESET=""
for a in "$@"; do
  case "$a" in fast|balanced|think|deep|greedy) ARG_PRESET="$a" ;; esac
done

# ---- 基线默认值（来自 runtime.env，预设随后覆盖，命令行最后覆盖）----
P_KV_DTYPE="${KV_DTYPE:-rk2v4-e8}"; P_CTX="${KV_CAPACITY:-49152}"
P_PORT="${PORT:-8098}"; P_HOST="${HOST:-127.0.0.1}"; P_MC=1; P_REQLOG=1
P_THINKING=on; P_BUDGET=1024; P_EFFORT=medium; P_SAMPLE=v100
P_SPEC_BACKEND=dflash2; P_K=7; P_NGRAM=""
case "${SPEC_FLAGS:-}" in
  *--spec\ mtp*)     P_SPEC_BACKEND=mtp ;;
  *--spec\ dflash2*) P_SPEC_BACKEND=dflash2 ;;
  *--spec\ dflash*)  P_SPEC_BACKEND=dflash ;;
  *--spec\ none*)    P_SPEC_BACKEND=none ;;
esac
_k="$(printf '%s\n' "${SPEC_FLAGS:-}" | grep -oE '\-\-draft-tokens[= ]+[0-9]+' | grep -oE '[0-9]+$' || true)"
[ -n "$_k" ] && P_K="$_k"

case "$ARG_PRESET" in
  fast) preset_fast ;; balanced) preset_balanced ;; think) preset_think ;;
  deep) preset_deep ;; greedy) preset_greedy ;;
esac

DRY_RUN=0; DO_STOP=1; DO_PROBE=0; DO_PERSIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    fast|balanced|think|deep|greedy) shift ;;   # 预设已在上面生效
    --ctx)      P_CTX="${2:?--ctx 需要值}"; shift 2 ;;
    --kv-dtype) P_KV_DTYPE="${2:?}"; shift 2 ;;
    --thinking) P_THINKING="${2:?}"; shift 2 ;;
    --budget)   P_BUDGET="${2:?}"; shift 2 ;;
    --effort)   P_EFFORT="${2:?}"; shift 2 ;;
    --sample)   P_SAMPLE="${2:?}"; shift 2 ;;
    --k)        P_K="${2:?}"; shift 2 ;;
    --spec)     P_SPEC_BACKEND="${2:?}"; shift 2 ;;
    --ngram)    P_NGRAM="${2:?}"; shift 2 ;;
    --max-concurrency) P_MC="${2:?}"; shift 2 ;;
    --port)     P_PORT="${2:?}"; shift 2 ;;
    --host)     P_HOST="${2:?}"; shift 2 ;;
    --reqlog)   P_REQLOG=1; shift ;;
    --no-reqlog) P_REQLOG=0; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --no-stop)  DO_STOP=0; shift ;;
    --probe)    DO_PROBE=1; shift ;;
    --persist)  DO_PERSIST=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    "")         shift ;;
    *)          usage >&2; die "未知参数：$1" ;;
  esac
done

case "$P_THINKING" in on|off) ;; *) die "--thinking 只能是 on|off" ;; esac
case "$P_SAMPLE"   in v100|greedy|none) ;; *) die "--sample 只能是 v100|greedy|none" ;; esac
case "$P_SPEC_BACKEND" in dflash2|dflash|mtp|none) ;; *) die "--spec 只能是 dflash2|dflash|mtp|none" ;; esac
case "$P_CTX" in *[kK]) P_CTX=$(( ${P_CTX%[kK]} * 1000 )) ;; esac
case "$P_CTX" in ''|*[!0-9]*) die "--ctx 必须是数字（可带 k 后缀）" ;; esac

# ---------- 无参数：打印预设表 ----------
if [ "$NO_ARGS" -eq 0 ]; then
  printf '\n\033[1m3060 bonsai2 调参台\033[0m   部署根 %s\n' "$PREFIX"
  printf '%s\n' '------------------------------------------------------------------'
  cat <<'EOF'
 预设            思考        预算    采样     速度（本机实测，随输入波动）
 fast            关          —       v100     代码/工具 65–88；中文散文只有 ~26
 balanced        开          1024    v100     代码 73；中文散文 39–58；固定 agent 任务中位墙钟 44.2s
 think           开          4096    v100     同任务中位墙钟 67.8s（≈1.5× balanced）
 deep            开          8192    v100     最慢，留给真的难题
 greedy          开          1024    greedy   可复现，但无随机逃逸（L26 放大器）

 ⚠ decode 快慢主要取决于"投机接受率"，而接受率取决于请求类型：
   代码/工具/英文 ~37–52%，旧部署 95% → ~200 tok/s；
   **中文散文只有 6% → ~26 tok/s，这就是这张卡的带宽地板**（关掉投机也是 26）。
   中文散文到不了 120，换任何服务端参数都没用（病历 L29）。
EOF
  printf '%s\n' '------------------------------------------------------------------'
  printf '\n用法：%s <预设|参数> [更多参数...]\n' "$(basename "$SELF")"
  printf '看全部参数：%s --help\n' "$(basename "$SELF")"
  printf '\n当前 runtime.env 里的生产档：\n'
  printf '  KV_DTYPE      = %s\n  KV_CAPACITY   = %s\n  SPEC_FLAGS    = %s\n  EXTRA_FLAGS   = %s\n' \
     "${KV_DTYPE:-}" "${KV_CAPACITY:-}" "${SPEC_FLAGS:-}" "${EXTRA_FLAGS:-}"
  printf '\n运行状态：%s\n' "$(systemctl --user is-active "$UNIT" 2>/dev/null | head -1)"
  printf '参考：12G 空卡实测 KV 上限 76768（可写 --ctx 76768）；当前部署取 49152，因为上限随桌面占用浮动（L21）\n'
  exit 0
fi

# ---------- 组装命令行（--dry-run 打印用，--persist 复用同样的取值逻辑）----------
build_cmd() {
  CMD=("$PREFIX/bin/ninfer-serve" "$MODEL_PATH"
       --host "$P_HOST" --port "$P_PORT" --model-id "${MODEL_ID:-bonsai2-27b}"
       --max-context "$P_CTX" --kv-capacity "$P_CTX" --kv-dtype "$P_KV_DTYPE")
  [ "$P_SPEC_BACKEND" = none ] || CMD+=(--spec "$P_SPEC_BACKEND" --draft-tokens "$P_K")
  CMD+=(--max-concurrency "$P_MC")
  case "$P_SAMPLE" in
    v100)   CMD+=(--temperature 1.0 --top-p 0.95 --top-k 20) ;;
    greedy) CMD+=(--greedy) ;;
  esac
  # ⚠ --no-thinking 与 --default-reasoning-effort 互斥（serve_options.cpp 会 throw），
  #    所以 thinking off 时两个思考参数都不传。
  if [ "$P_THINKING" = off ]; then
    CMD+=(--no-thinking)
  else
    [ -n "$P_EFFORT" ] && CMD+=(--default-reasoning-effort "$P_EFFORT")
    [ -n "$P_BUDGET" ] && CMD+=(--default-thinking-budget "$P_BUDGET")
  fi
  [ -n "$P_NGRAM" ] && CMD+=(--ngram-draft-tokens "$P_NGRAM")
  [ "$P_REQLOG" = 1 ] && CMD+=(--request-log-jsonl "$PREFIX/logs/request.jsonl")
  return 0
}
build_cmd

# ---------- --persist：写回 runtime.env 并重启单元 ----------
if [ "$DO_PERSIST" -eq 1 ]; then
  BAK="$ENVF.bak-$(date '+%Y%m%d-%H%M%S')-tune"
  cp "$ENVF" "$BAK" || die "备份 runtime.env 失败"
  spec_line=""; [ "$P_SPEC_BACKEND" = none ] || spec_line="--spec $P_SPEC_BACKEND --draft-tokens $P_K"
  extra="--max-concurrency $P_MC"
  case "$P_SAMPLE" in
    v100)   extra+=" --temperature 1.0 --top-p 0.95 --top-k 20" ;;
    greedy) extra+=" --greedy" ;;
  esac
  if [ "$P_THINKING" = off ]; then
    extra+=" --no-thinking"
  else
    [ -n "$P_EFFORT" ] && extra+=" --default-reasoning-effort $P_EFFORT"
    [ -n "$P_BUDGET" ] && extra+=" --default-thinking-budget $P_BUDGET"
  fi
  [ -n "$P_NGRAM" ] && extra+=" --ngram-draft-tokens $P_NGRAM"
  [ "$P_REQLOG" = 1 ] && extra+=" --request-log-jsonl $PREFIX/logs/request.jsonl"
  sed -i "s|^KV_DTYPE=.*|KV_DTYPE=$P_KV_DTYPE|"         "$ENVF"
  sed -i "s|^KV_CAPACITY=.*|KV_CAPACITY=$P_CTX|"       "$ENVF"
  sed -i "s|^SPEC_FLAGS=.*|SPEC_FLAGS=\"$spec_line\"|" "$ENVF"
  sed -i "s|^EXTRA_FLAGS=.*|EXTRA_FLAGS=\"$extra\"|"   "$ENVF"
  ok "已写回 $ENVF（备份 $BAK）"
  printf '  KV_DTYPE=%s  KV_CAPACITY=%s\n  SPEC_FLAGS="%s"\n  EXTRA_FLAGS="%s"\n' \
     "$P_KV_DTYPE" "$P_CTX" "$spec_line" "$extra"
  systemctl --user restart "$UNIT" || die "重启 $UNIT 失败"
  inf "等待就绪…"
  for i in $(seq 1 300); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$P_HOST:$P_PORT/v1/models" 2>/dev/null || true)" = 200 ] \
      && { ok "就绪（${i}s）-> http://$P_HOST:$P_PORT/v1"; exit 0; }
    sleep 1
  done
  die "就绪超时，看 $PREFIX/logs/service.log"
fi

# ---------- 打印将要做的事 ----------
printf '\n\033[1m参数\033[0m（部署根 %s）\n' "$PREFIX"
printf '  上下文/KV     %s token  (%s)\n' "$P_CTX" "$P_KV_DTYPE"
if [ "$P_SPEC_BACKEND" = none ]; then printf '  投机          关\n'
else printf '  投机          %s K=%s%s\n' "$P_SPEC_BACKEND" "$P_K" "${P_NGRAM:+ ngram=$P_NGRAM}"; fi
if [ "$P_THINKING" = off ]; then
  printf '  思考          关（--no-thinking；不传 effort/budget，二者互斥）\n'
else
  printf '  思考          开  effort=%s budget=%s\n' "${P_EFFORT:-默认}" "${P_BUDGET:-无帽}"
fi
printf '  采样          %s\n' "$P_SAMPLE"
printf '  并发/端口     %s / %s:%s\n' "$P_MC" "$P_HOST" "$P_PORT"
printf '  锁卡          CUDA_VISIBLE_DEVICES=%s（按 UUID，不信设备序）\n' "$CUDA_VISIBLE_DEVICES"
gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader -i "$CUDA_VISIBLE_DEVICES" 2>/dev/null | head -1)"
[ -n "$gpu_name" ] && printf '  实卡          %s\n' "$gpu_name"
printf '  取证日志      %s\n' "$([ "$P_REQLOG" = 1 ] && echo "$PREFIX/logs/request.jsonl" || echo 关)"
printf '\n\033[1m将执行的命令\033[0m\n  %s\n\n' "${CMD[*]}"

if [ "$DRY_RUN" -eq 1 ]; then ok "--dry-run：到此为止，没有启动任何东西"; exit 0; fi

# ---------- 停掉已有实例 ----------
if [ "$DO_STOP" -eq 1 ]; then
  if systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
    inf "停止 systemd 单元 $UNIT"; systemctl --user stop "$UNIT" || true
  fi
  if [ -f "$PREFIX/logs/serve.pid" ]; then
    p="$(cat "$PREFIX/logs/serve.pid" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then inf "停止裸跑进程 pid=$p"; kill -TERM "$p" 2>/dev/null || true; fi
  fi
  stray="$(pgrep -x ninfer-serve 2>/dev/null || true)"
  if [ -n "$stray" ]; then wrn "仍有残留 ninfer-serve：$stray —— 发 SIGTERM"; kill -TERM $stray 2>/dev/null || true; fi
  i=0; while ss -ltn 2>/dev/null | grep -q ":$P_PORT " && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
  ss -ltn 2>/dev/null | grep -q ":$P_PORT " && die "端口 $P_PORT 30 秒后仍被占用"
fi

# ---------- 前台跑，输出同时进终端与日志文件 ----------
mkdir -p "$PREFIX/logs"
TLOG="$PREFIX/logs/tune-$(date '+%Y%m%d-%H%M%S').log"
inf "前台启动（日志同时写终端与 $TLOG）"
printf '%s  命令: %s\n' "$(date '+%F %T')" "${CMD[*]}" >> "$TLOG"
"${CMD[@]}" > >(tee -a "$TLOG") 2>&1 &
child=$!
# 引擎对**单次 SIGINT 不退出**（要 5 秒内按两次 Ctrl-C），所以这里把 Ctrl-C 转成 SIGTERM
trap 'printf "\n[info] 收到中断，转发 SIGTERM…\n"; kill -TERM "$child" 2>/dev/null' INT TERM
wait "$child" 2>/dev/null || true
i=0; while kill -0 "$child" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
trap - INT TERM
if kill -0 "$child" 2>/dev/null; then wrn "引擎 30 秒未退，请手动：kill -TERM $child"; exit 1; fi
ok "引擎已退出；本轮日志 $TLOG"
