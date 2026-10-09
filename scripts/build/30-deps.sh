#!/usr/bin/env bash
# scripts/30-deps.sh — Phase 3：构建依赖核对与锁定
#
# 本机已有全部所需开发库（FFmpeg / libcurl / gcc-13 / cmake / ninja）。
# 在真正的空白 Ubuntu 上，本脚本的 --install 分支会经 apt 安装它们
# （需要 sudo 密码，故默认只做核对；缺件时明确报出要装什么）。
#
# 产出：把全部版本写进 config/toolchain.lock 与 evidence/toolchain/。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

MODE="${1:-verify}"
log_init "30-deps"

LOCK="$PROJ/config/toolchain.lock"
EV="$PROJ/evidence/toolchain"; mkdir -p "$EV"

APT_PKGS="build-essential gcc-13 g++-13 cmake ninja-build pkg-config \
libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libcurl4-openssl-dev git curl"

if [ "$MODE" = "--install" ]; then
  if sudo -n true 2>/dev/null; then
    run sudo apt-get update
    run sudo apt-get install -y $APT_PKGS
  else
    echo "[warn] 需要 sudo 密码（本会话无法自动输入）。请手动执行：" >&2
    echo "  sudo apt-get update && sudo apt-get install -y $APT_PKGS" >&2
  fi
fi

# --- 核对 ---
missing=0
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[fail] 缺少命令: $1" >&2; missing=1; }; }
for c in gcc-13 g++-13 cmake ninja pkg-config git curl; do need_cmd "$c"; done

need_pc() {
  local v; v=$(pkg-config --modversion "$1" 2>/dev/null || true)
  [ -n "$v" ] || { echo "[fail] 缺少 pkg-config 库: $1" >&2; missing=1; }
  printf '%s\n' "${v:-MISSING}"
}

GCCV=$("$CC_HOST" --version | head -1)
GXXV=$("$CXX_HOST" --version | head -1)
CMKV=$(cmake --version | head -1)
NINV=$(ninja --version)
PKGV=$(pkg-config --version)
AVC=$(need_pc libavcodec); AVF=$(need_pc libavformat); AVU=$(need_pc libavutil); SWC=$(need_pc libswscale); CRL=$(need_pc libcurl); ZLB=$(need_pc zlib)

CM_NUM=$(echo "$CMKV" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
python3 -c "import sys; sys.exit(0 if [int(x) for x in '$CM_NUM'.split('.')] >= [3,28,0] else 1)" \
  || { echo "[fail] CMake $CM_NUM < 3.28（NInfer 要求 cmake_minimum_required(VERSION 3.28)）" >&2; missing=1; }

[ "$missing" -eq 0 ] || { echo "[fail] 依赖不齐，见上。" >&2; exit 1; }

{
  echo
  echo "[host-build-deps]"
  echo "gcc-13        = $GCCV"
  echo "g++-13        = $GXXV"
  echo "cmake         = $CMKV"
  echo "ninja         = $NINV"
  echo "pkg-config    = $PKGV"
  echo "libavcodec    = $AVC"
  echo "libavformat   = $AVF"
  echo "libavutil     = $AVU"
  echo "libswscale    = $SWC"
  echo "libcurl       = $CRL"
  echo "zlib          = $ZLB"
  echo "apt_packages  = $APT_PKGS"
  echo "source        = 已存在于本机；空白机请跑 scripts/30-deps.sh --install"
} >> "$LOCK"

{
  echo "# host build deps"
  echo "gcc-13 $GCCV"
  echo "cmake $CMKV"
  echo "ninja $NINV"
  echo "libavcodec $AVC / libavformat $AVF / libavutil $AVU / libswscale $SWC"
  echo "libcurl $CRL / zlib $ZLB"
} > "$EV/deps.txt"

note "deps OK: cmake $CM_NUM, gcc-13, ffmpeg $AVC/$AVF/$AVU/$SWC, curl $CRL"
cp "$LOCK" "$EV/toolchain.lock" 2>/dev/null || true
log_finish 0
echo "[done] 依赖核对通过；lock=$LOCK"
