#!/usr/bin/env bash
# scripts/86-verify-live-match.sh — 断言「**本仓库 ≡ 3060 上正在运行的服务**」
#
# 为什么需要这个脚本：
#   2026-10-07 这个项目经历了一次大改（L26 复读锁死 → L27 档位 → L28 预算定档 → L29 带宽地板）。
#   参数分散在 config/env.sh、scripts/80-serve.sh、package/{runtime-tools,install-runtime,entrypoint}.sh
#   以及 scripts/97-deploy-service.sh 的**生成模板**里。改的时候漏掉任何一处，
#   "从仓库起服务"就会和"3060 上跑着的服务"参数不一致 —— 实测已经漏过三处（兜底值还写着 4096）。
#
#   本脚本把这件事变成可执行断言：读**运行进程的真实 cmdline**（不是读配置猜），
#   再逐项与仓库的声明对账。只要它 PASS，就能说"仓库和 3060 跑的一模一样"。
#
# 用法：bash scripts/86-verify-live-match.sh [--prefix DIR]
# 退出码：0 = 全部一致；1 = 有漂移（逐条打印）；2 = 服务没在跑（无法对账）

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/.." && pwd)"
PREFIX="${BONSAI_PREFIX:-$HOME/bonsai-ninfer-3060}"  # verify:allow-outside-path（历史编译期流水线，部署根在仓库外）
UNIT="bonsai2-ninfer-3060.service"
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

pass=0; fail=0
ok()  { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*" >&2; fail=$((fail+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1: 期望 '$2'，实际 '$3'"; fi; }

# 把 "--a 1 --b --c 2" 解析成 map（布尔 flag 值为 1）
parse_flags() { # $1=命令串  $2=数组名
  local -n out="$2"; local -a w; read -r -a w <<< "$1"
  local i k
  for ((i=0; i<${#w[@]}; i++)); do
    case "${w[i]}" in
      --*) k="${w[i]#--}"
           if [[ "${w[i+1]:-}" == --* || -z "${w[i+1]:-}" ]]; then out[$k]=1
           else out[$k]="${w[i+1]}"; i=$((i+1)); fi ;;
    esac
  done
}

printf '\033[1m仓库 ≡ 运行态 对账\033[0m  (repo=%s  prefix=%s)\n\n' "$PROJ" "$PREFIX"

# ---------------------------------------------------------------- 0) 进程
echo "=== 0) 找到 3060 上正在跑的进程 ==="
if ! systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
  bad "服务 $UNIT 不在运行 —— 无法对账。先 systemctl --user start $UNIT"
  echo; echo "结论：SKIP（服务没在跑）"; exit 2
fi
ok "服务 $UNIT = active"
MAIN="$(systemctl --user show -p MainPID --value "$UNIT" 2>/dev/null)"
if [ -z "$MAIN" ] || [ "$MAIN" = "0" ] || [ ! -r "/proc/$MAIN/cmdline" ]; then
  bad "拿不到可读的 MainPID（got='${MAIN}'）"; echo; echo "结论：SKIP"; exit 2
fi
ok "MainPID=$MAIN"
LIVE_CMD="$(tr '\0' ' ' < "/proc/$MAIN/cmdline")"
declare -A LIVE=(); parse_flags "$LIVE_CMD" LIVE
ok "已读取真实 cmdline（${#LIVE[@]} 个 --flag）"

# ------------------------------------------------- 1) 部署根 runtime.env
echo
echo "=== 1) 部署根 runtime.env（运行态唯一调参入口）==="
RENVF="$PREFIX/config/runtime.env"
if [ ! -r "$RENVF" ]; then bad "读不到 $RENVF"; echo; echo "结论：FAIL"; exit 1; fi
ok "读到 $RENVF（sha256=$(sha256sum "$RENVF" | cut -c1-16)…）"
# runtime.env 是纯赋值文件（无命令），直接 source。
# ⚠ 它自己也会赋值 PREFIX —— 先存下来、source 完再还原（否则 --prefix 被覆盖，且 set -u 下报未绑定）
_MY_PREFIX="$PREFIX"
set +u
# shellcheck disable=SC1090
. "$RENVF" || bad "source $RENVF 失败"
DEP_HOST="${HOST:-}"; DEP_PORT="${PORT:-}"; DEP_MID="${MODEL_ID:-}"
DEP_KVDT="${KV_DTYPE:-}"; DEP_KVCAP="${KV_CAPACITY:-}"
DEP_SPEC="${SPEC_FLAGS:-}"; DEP_EXTRA="${EXTRA_FLAGS:-}"
set -u
for v in HOST PORT MODEL_ID KV_DTYPE KV_CAPACITY SPEC_FLAGS EXTRA_FLAGS \
         MODEL_PATH GPU_UUID CUDA_VISIBLE_DEVICES CUDA_DEVICE_ORDER NINFER_DEVICE_PROFILES PREFIX; do
  unset "$v" 2>/dev/null || true
done
PREFIX="$_MY_PREFIX"

# ----------------------------------------- 2) 运行 cmdline ≡ runtime.env
echo
echo "=== 2) 运行中的 cmdline ≡ runtime.env 声明 ==="
declare -A EXP=()
EXP[host]="$DEP_HOST"; EXP[port]="$DEP_PORT"; EXP[model-id]="$DEP_MID"
EXP[max-context]="$DEP_KVCAP"; EXP[kv-capacity]="$DEP_KVCAP"; EXP[kv-dtype]="$DEP_KVDT"
declare -A _tmp=()
parse_flags "$DEP_SPEC"  _tmp; for k in "${!_tmp[@]}"; do EXP[$k]="${_tmp[$k]}"; done
_tmp=(); parse_flags "$DEP_EXTRA" _tmp; for k in "${!_tmp[@]}"; do EXP[$k]="${_tmp[$k]}"; done

for k in $(printf '%s\n' "${!EXP[@]}" | sort); do
  if [ -z "${LIVE[$k]+x}" ]; then bad "运行命令里缺 --$k（runtime.env 声明为 '${EXP[$k]}'）"
  else chk "--$k" "${EXP[$k]}" "${LIVE[$k]}"; fi
done
for k in $(printf '%s\n' "${!LIVE[@]}" | sort); do
  [ -n "${EXP[$k]+x}" ] || bad "运行命令里有 --$k=${LIVE[$k]}，但 runtime.env 没声明（参数漂移）"
done

# L26 安全门：这两个不能在运行态里
[ -z "${LIVE[greedy]+x}" ] && ok "运行态无 --greedy（L26 的复读放大器）" || bad "运行态出现了 --greedy —— 见 L26"
[ -z "${LIVE[no-thinking]+x}" ] && ok "运行态无 --no-thinking（L26 组合的一半）" || bad "运行态出现了 --no-thinking —— 见 L26"
[ -n "${LIVE[request-log-jsonl]+x}" ] && ok "取证日志开关在（行为中性、不含 prompt 正文）" || bad "缺 --request-log-jsonl，40 tok/s 那类归因将无从做起"

# ------------------------------------------- 3) 仓库默认值 ≡ 运行态
echo
echo "=== 3) 仓库 config/env.sh 的默认值 ≡ 运行态 ==="
_repo() { ( cd "$PROJ" && set +u; # shellcheck disable=SC1091
            . ./config/env.sh >/dev/null 2>&1
            case "$1" in
              extra) printf '%s' "${NINFER_EXTRA_FLAGS:-}" ;;
              spec)  printf -- '--spec %s --draft-tokens %s' "${NINFER_SPEC:-}" "${NINFER_DRAFT:-}" ;;
            esac ); }
WANT_EXTRA="$(printf '%s' "$DEP_EXTRA" | sed -E 's/ --request-log-jsonl [^ ]+//')"
chk "config/env.sh NINFER_EXTRA_FLAGS" "$WANT_EXTRA" "$(_repo extra)"
chk "config/env.sh NINFER_SPEC/DRAFT"  "$DEP_SPEC"   "$(_repo spec)"
GOT_KVDT="$(_repo kvdt 2>/dev/null || true)"
# KV 在 env.sh 里刻意留空（必须实测填），所以只断言"没被写死成别的值"
if grep -qE '^export KV_DTYPE="\$\{KV_DTYPE:-\}"' "$PROJ/config/env.sh" \
   && grep -qE '^export KV_CAPACITY="\$\{KV_CAPACITY:-\}"' "$PROJ/config/env.sh"; then
  ok "config/env.sh 的 KV 保持空值（强制走门禁实测，未写死）"
else bad "config/env.sh 的 KV 被写死了 —— 见 L08/L21"; fi

# ------------------------------------- 4) 生成模板 ≡ 运行态（防再次漏改）
echo
echo "=== 4) scripts/97-deploy-service.sh 生成模板 ≡ 运行态 ==="
_gen="$PROJ/scripts/97-deploy-service.sh"
grep -qF -- "--default-thinking-budget ${LIVE[default-thinking-budget]:-?}" "$_gen" \
  && ok "生成模板的思考预算与运行态一致（${LIVE[default-thinking-budget]:-?}）" \
  || bad "生成模板的 --default-thinking-budget 与运行态不一致（运行态=${LIVE[default-thinking-budget]:-?}）"
grep -qF -- "--temperature ${LIVE[temperature]:-?} --top-p ${LIVE[top-p]:-?} --top-k ${LIVE[top-k]:-?}" "$_gen" \
  && ok "生成模板的采样档与运行态一致（t=${LIVE[temperature]:-?}/p=${LIVE[top-p]:-?}/k=${LIVE[top-k]:-?}）" \
  || bad "生成模板的采样档与运行态不一致"
grep -qF -- "--spec ${LIVE[spec]:-?} --draft-tokens ${LIVE[draft-tokens]:-?}" "$_gen" \
  && ok "生成模板的投机档与运行态一致" || bad "生成模板的投机档与运行态不一致"
grep -qF -- "KV_CAPACITY=${LIVE[kv-capacity]:-?}" "$_gen" \
  && ok "生成模板的 KV 容量与运行态一致（${LIVE[kv-capacity]:-?}）" || bad "生成模板的 KV 容量与运行态不一致"

# ------------------------------------------- 5) 部署文件 ≡ 仓库文件
echo
echo "=== 5) 部署根每个文件 ≡ 仓库对应文件 ==="
cmp_pair() { # $1=部署根相对路径  $2=仓库相对路径
  if [ ! -e "$PREFIX/$1" ]; then bad "部署根缺 $1"; return; fi
  if [ ! -e "$PROJ/$2" ]; then bad "仓库缺 $2"; return; fi
  if cmp -s "$PREFIX/$1" "$PROJ/$2"; then ok "$1 ≡ $2"
  else bad "$1 ≠ $2（部署的是另一个版本！）"; fi
}
cmp_pair agent/agent_accept.py        agent/agent_accept.py
cmp_pair agent/correctness_control.py agent/correctness_control.py
cmp_pair agent/kvgate.py              agent/kvgate.py
cmp_pair agent/91-repeat-lock-probe.py scripts/91-repeat-lock-probe.py
cmp_pair config/env.sh                config/env.sh
cmp_pair docs/LINEAGE.md              LINEAGE.md
cmp_pair docs/METHODOLOGY.md          METHODOLOGY.md
cmp_pair docs/PORTING-LEDGER.md       PORTING-LEDGER.md
cmp_pair docs/AGENT-EXPERIENCE.md     AGENT-EXPERIENCE.md
cmp_pair docs/params/REPORT-param-audit-20261007.md evidence/params/REPORT-param-audit-20261007.md
cmp_pair docs/params/REPORT-tune-ab-20261007.md     evidence/params/REPORT-tune-ab-20261007.md
cmp_pair install-runtime.sh           package/install-runtime.sh
cmp_pair runtime-tools.sh             package/runtime-tools.sh
cmp_pair tune.sh                      scripts/96-tune-serve.sh
cmp_pair README.md                    package/README-modelscope.md

# ------------------------------------------ 6) 不可变产物哈希
echo
echo "=== 6) 二进制 / profile 未漂移 ==="
BUILD="$PROJ/.store/build/build-sm86/apps"
for b in ninfer ninfer-serve ninfer-calibrate; do
  if [ -e "$PREFIX/bin/$b" ] && [ -e "$BUILD/$b" ]; then
    cmp -s "$PREFIX/bin/$b" "$BUILD/$b" && ok "bin/$b ≡ 构建产物（$(sha256sum "$PREFIX/bin/$b" | cut -c1-16)…）" \
      || bad "bin/$b ≠ 构建产物（版本漂移）"
  else ok "跳过 bin/$b（构建目录或部署根缺该文件）"; fi
done
if [ -e "$PREFIX/profiles/device-profiles.json" ] && [ -e "$PROJ/evidence/calibrate/device-profiles.json" ]; then
  cmp -s "$PREFIX/profiles/device-profiles.json" "$PROJ/evidence/calibrate/device-profiles.json" \
    && ok "profiles/device-profiles.json ≡ 冻结基线" || bad "profile 被改过（28-SM 标定被污染）"
fi

# ------------------------------------------ 7) 全仓残留扫描
echo
echo "=== 7) 全仓扫描：有效参数位是否还有旧值 ==="
_hits="$(grep -rn --include='*.sh' --include='*.py' --include='*.env' --include='*.yml' \
           --exclude="$(basename "${BASH_SOURCE[0]}")" \
           -e 'default-thinking-budget 4096' "$PROJ" 2>/dev/null \
         | grep -v '/dist/\|/backups/\|/evidence/\|/logs/\|93-param-frontier\|94-lock-probe' || true)"
[ -z "$_hits" ] && ok "没有把旧的 4096 当默认值的地方（测量台的参数空间除外）" \
               || { bad "仍有旧值 4096："; printf '%s\n' "$_hits" | sed 's/^/         /'; }
_cmp="$PROJ/scripts/86-verify-live-match.sh"
if [ -f "$_cmp" ]; then
  for f in config/env.sh scripts/80-serve.sh package/runtime-tools.sh package/install-runtime.sh package/entrypoint.sh; do
    grep -q 'default-thinking-budget' "$PROJ/$f" && \
      { grep -q 'default-thinking-budget 1024' "$PROJ/$f" \
        && ok "$f 的兜底值为 1024" || bad "$f 的兜底值不是 1024"; }
  done
fi

# ---------------------------------------------------------- 结论
echo
echo "─────────────────────────────────────────────"
if [ "$fail" = "0" ]; then
  printf '\033[32m结论：PASS —— 本仓库与 3060 上正在运行的服务一致（%d 项全过）\033[0m\n' "$pass"
  exit 0
else
  printf '\033[31m结论：FAIL —— %d 项漂移，%d 项通过\033[0m\n' "$fail" "$pass"
  exit 1
fi
