#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/lib.sh —— 共用的日志 / 下载 / 校验助手（被其它脚本 source）
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_0=
fi

log()  { printf '%s[info]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ok]%s   %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1${2:+（$2）}"
}

sha256_of() {
  [ -f "$1" ] || return 1
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# 带断点续传的下载：download URL 输出文件
download() {
  local url="$1" out="$2"
  need_cmd curl
  mkdir -p "$(dirname "$out")"
  log "下载 $url"
  if curl -fL --retry 3 --retry-delay 2 -C - -o "$out" \
        --progress-bar "$url"; then
    return 0
  fi
  # 有些镜像不支持 Range，退回整体重下
  warn "断点续传失败，改为重新下载"
  rm -f "$out"
  curl -fL --retry 3 --retry-delay 2 -o "$out" --progress-bar "$url"
}

# 校验文件大小与 sha256；不符返回 1
verify_file() {
  local path="$1" want_sha="$2" want_bytes="$3"
  [ -f "$path" ] || return 1
  if [ -n "$want_bytes" ]; then
    local sz; sz="$(stat -c %s "$path" 2>/dev/null || echo 0)"
    [ "$sz" = "$want_bytes" ] || { warn "体积不符：$sz ≠ $want_bytes"; return 1; }
  fi
  if [ -n "$want_sha" ]; then
    local got; got="$(sha256_of "$path")"
    [ "$got" = "$want_sha" ] || { warn "sha256 不符：$got ≠ $want_sha"; return 1; }
  fi
  return 0
}

human_size() {
  local b="${1:-0}"
  if   [ "$b" -ge 1073741824 ]; then awk -v b="$b" 'BEGIN{printf "%.2f GiB", b/1073741824}'
  elif [ "$b" -ge 1048576 ];    then awk -v b="$b" 'BEGIN{printf "%.1f MiB", b/1048576}'
  elif [ "$b" -ge 1024 ];       then awk -v b="$b" 'BEGIN{printf "%.1f KiB", b/1024}'
  else echo "${b} B"; fi
}
