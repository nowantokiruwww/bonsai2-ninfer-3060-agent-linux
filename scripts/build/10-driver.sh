#!/usr/bin/env bash
# scripts/10-driver.sh — Phase 1：NVIDIA 驱动（从零；空白 Ubuntu 也能跑）
#
# 空白系统上必踩的两个坑，本脚本都会先判后做：
#   1. Secure Boot 开着 → DKMS 模块不加载 → nvidia-smi 报
#      "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver"
#   2. 内核头缺失 → DKMS 编不出模块
#
# 默认只做**核对**（需要 sudo 的安装动作必须由人执行，本会话无法输入密码）：
#   bash scripts/10-driver.sh            # 核对 + 出诊断
#   bash scripts/10-driver.sh --install  # 尝试自动装（有 sudo 免密时才真的装）

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

MODE="${1:-verify}"
log_init "10-driver"
EV="$PROJ/evidence/driver"; mkdir -p "$EV"
LOCK="$PROJ/config/toolchain.lock"

# ---------------------------------------------------------------- 诊断
{
  echo "# NVIDIA 驱动诊断"
  echo "checked_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo
  echo "## 硬件"
  lspci -nn | grep -i -E 'vga|3d|display' || echo "(no display controller)"
  echo
  echo "## 内核与头文件"
  uname -r
  dpkg -l 'linux-headers-*' 2>/dev/null | awk '/^ii/{print $2}' || echo "(none)"
  echo
  echo "## Secure Boot"
  command -v mokutil >/dev/null && mokutil --sb-state || echo "(mokutil 未安装；无法判定，见文末说明)"
  echo
  echo "## nouveau 是否被屏蔽"
  lsmod | grep -i nouveau || echo "(nouveau 未加载 ✓)"
  echo
  echo "## nvidia 模块"
  lsmod | grep -i '^nvidia' || echo "(nvidia 模块未加载 ✗)"
  echo
  echo "## /proc/driver/nvidia/version"
  cat /proc/driver/nvidia/version 2>/dev/null || echo "(缺失 → 驱动未生效)"
  echo
  echo "## nvidia-smi"
  nvidia-smi 2>&1 | head -12 || true
} > "$EV/diagnosis.txt"
cat "$EV/diagnosis.txt"

SB=$(mokutil --sb-state 2>/dev/null | tr -d '\n' || echo "unknown")
if echo "$SB" | grep -qi enabled; then
  echo
  echo "!! Secure Boot 处于 enabled。DKMS 编出的模块不会被加载，除非注册 MOK。" >&2
  echo "   两种处置：① BIOS 里关掉 Secure Boot；② sudo mokutil --import <公钥> 后重启注册。" >&2
fi

if [ "$MODE" = "--install" ]; then
  echo
  echo "=== 安装动作（按 fork 的 Linux 指南：驱动 580+ 走 CUDA 13 分支）==="
  APT_CMD="apt-get update && apt-get install -y linux-headers-\$(uname -r) nvidia-driver-580-open"
  if sudo -n true 2>/dev/null; then
    run bash -c "sudo $APT_CMD"
  else
    echo "需要 sudo 密码（本会话无法自动输入）。请在终端执行：" >&2
    echo "  sudo $APT_CMD" >&2
    echo "  然后重启，再跑本脚本核对。" >&2
  fi
fi

# ---------------------------------------------------------------- 核对
fail=0
command -v nvidia-smi >/dev/null || { echo "[fail] 无 nvidia-smi" >&2; fail=1; }
if [ "$fail" = "0" ]; then
  if ! nvidia-smi >/dev/null 2>&1; then
    echo "[fail] nvidia-smi 执行失败 —— 驱动/模块问题（先看上面的诊断）" >&2; fail=1
  fi
fi
lsmod | grep -q '^nvidia' || { echo "[fail] nvidia 模块未加载" >&2; fail=1; }

if [ "$fail" = "0" ]; then
  nvidia-smi --query-gpu=index,uuid,name,compute_cap,memory.total,driver_version --format=csv \
    > "$EV/gpu-identity.txt"
  nvidia-smi --query-gpu=index,name,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv \
    > "$EV/pcie-link.txt"
  cat "$EV/gpu-identity.txt" "$EV/pcie-link.txt"
  DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
  {
    echo
    echo "[driver]"
    echo "version   = $DRV"
    echo "floor     = 580（fork 的 Linux 指南：CUDA 13 分支需要 580+；bench 侧要求 >=570）"
    echo "secureboot= $SB"
    echo "kernel    = $(uname -r)"
  } >> "$LOCK"
  note "驱动核对通过: $DRV"
else
  echo "[fail] 驱动核对未通过（详见 $EV/diagnosis.txt）" >&2
fi

log_finish "$fail"
[ "$fail" = "0" ] || exit 1
