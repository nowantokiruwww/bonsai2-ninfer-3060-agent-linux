#!/usr/bin/env bash
# scripts/lib/log.sh — 统一日志层（append-only，可对质）
#
# 每个 Phase 脚本必须：
#   source .../lib/log.sh
#   log_init "<phase-name>"
#   run <cmd...>            # 普通命令：失败即终止
#   run_ok <cmd...>         # 允许失败：记录退出码但不终止
#
# 日志内容：完整 argv、cwd、过滤后的环境快照、起止时间、退出码、stdout/stderr 原文。
# 这是对旧移植"测的脚本与实际跑的不是一回事"的正面修正。

set -euo pipefail

: "${PROJ:?PROJ 未设置：请先 source config/env.sh}"

_log_seq=0
_log_dir=""

# 统一时间戳
_now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log_init() {
  local phase="$1"
  _log_dir="$PROJ/logs/$phase/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$_log_dir"
  export PHASE="$phase"
  export LOG_ROOT="$_log_dir"

  {
    echo "# phase: $phase"
    echo "# started_at: $(_now)"
    echo "# hostname: $(hostname)"
    echo "# kernel: $(uname -r)"
    echo "# cwd: $(pwd)"
    echo "# script: ${BASH_SOURCE[1]:-unknown}"
    echo "# argv: $0 $*"
  } > "$_log_dir/00-meta.txt"

  # 环境快照（过滤掉噪声与密钥）
  env | LC_ALL=C sort \
    | grep -vE '^(LS_COLORS|XDG_|DBUS_|SSH_|GPG_|BASH_|LESS|PAGER|TERM|SHELL|SHLVL|OLDPWD|_)=' \
    > "$_log_dir/01-env.txt"

  echo "[log] phase=$phase dir=$_log_dir"
}

_log_slug() { echo "$1" | tr -cs 'A-Za-z0-9._-' '-' | cut -c1-48; }

# run：失败即终止
run() {
  _run_inner 0 "$@"
}

# run_ok：允许失败
run_ok() {
  _run_inner 1 "$@"
}

_run_inner() {
  local allow_fail="$1"; shift
  _log_seq=$((_log_seq + 1))
  local n rc slug file
  n=$(printf '%03d' "$_log_seq")
  slug=$(_log_slug "$*")
  file="$_log_dir/${n}-${slug}.log"

  {
    echo "### argv: $*"
    echo "### cwd: $(pwd)"
    echo "### start: $(_now)"
  } > "$file"

  set +e
  "$@" >> "$file" 2>&1
  rc=$?
  set -e

  {
    echo "### end: $(_now)"
    echo "### exit: $rc"
  } >> "$file"

  echo "[log] ($rc) $* -> ${file##*/}"
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$allow_fail" -eq 1 ]]; then
      echo "[warn] 非零退出但被允许: $rc" >&2
    else
      echo "[fail] 命令失败 rc=$rc: $*" >&2
      echo "[fail] 详见 $file" >&2
      return "$rc"
    fi
  fi
  return 0
}

# 记录一条结论性事实（供 evidence/ 引用）
note() {
  local msg="$*"
  printf '%s  %s\n' "$(_now)" "$msg" | tee -a "$_log_dir/notes.txt"
}

log_finish() {
  local rc="${1:-0}"
  printf '# finished_at: %s\n# exit: %s\n' "$(_now)" "$rc" >> "$_log_dir/00-meta.txt"
  echo "[log] phase=$PHASE done rc=$rc (dir=$_log_dir)"
}
