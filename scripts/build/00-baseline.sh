#!/usr/bin/env bash
# scripts/00-baseline.sh — Phase 0：空白基线留证
#
# 目的：留下一份可对质的"起点快照"，证明后续所有结论不是建立在未知的既有状态上。
#       在真正干净的 Ubuntu 上，本脚本应当显示：无 nvidia 模块、nvidia-smi 失败、
#       无 nvcc、无 ~/.cache/ninfer。在当前机器上它会把既有状态如实记录下来。
#
# 不写系统、不装任何东西、不触碰任何既有服务。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "00-baseline"
EV="$PROJ/evidence/baseline"
mkdir -p "$EV"

# --- 系统 ---
run_ok uname -a
run_ok lscpu
run_ok free -h
run_ok df -h
run_ok lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
run_ok bash -c 'cat /etc/os-release'

# --- NVIDIA 硬件与驱动状态（空白系统上应看到：有 lspci、无 lsmod、nvidia-smi 失败）---
run_ok bash -c "lspci -nn | grep -i -E 'vga|3d|display' || echo '(no display controller found)'"
run_ok bash -c "lsmod | grep -i -E 'nvidia|nouveau' || echo '(no nvidia/nouveau module loaded)'"
run_ok bash -c "command -v nvidia-smi || echo '(nvidia-smi: MISSING)'"
run_ok nvidia-smi
run_ok bash -c "cat /proc/driver/nvidia/version 2>/dev/null || echo '(/proc/driver/nvidia/version: absent)'"
run_ok bash -c "command -v mokutil >/dev/null && mokutil --sb-state || echo '(mokutil: not installed; Secure Boot state unknown)'"
run_ok bash -c "dpkg -l | awk '/^ii/{print \$2\"\\t\"\$3}' | grep -iE '^nvidia' || echo '(no nvidia dpkg packages)'"
run_ok bash -c "ls -la /usr/lib/modules/\$(uname -r)/ 2>/dev/null | head -20 || true"
run_ok bash -c "dpkg -l 'linux-headers-*' 2>/dev/null | awk '/^ii/{print \$2}' || echo '(none)'"

# --- GPU 身份（用于 UUID 锁卡）---
run_ok bash -c "nvidia-smi --query-gpu=index,uuid,name,compute_cap,memory.total,driver_version --format=csv || echo '(unavailable)'"
run_ok bash -c "nvidia-smi --query-gpu=index,name,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv || echo '(unavailable)'"

# --- CUDA 工具链状态 ---
run_ok bash -c "command -v nvcc || echo '(nvcc: MISSING)'"
run_ok bash -c "ls -d /usr/local/cuda* 2>/dev/null || echo '(no /usr/local/cuda*)'"
run_ok bash -c "ls -d \$HOME/cuda* 2>/dev/null || echo '(no ~/cuda*)'"

# --- 构建工具 ---
run_ok bash -c "command -v gcc g++ cmake ninja git curl pkg-config || true"
run_ok bash -c "gcc --version | head -1; g++ --version | head -1"
run_ok bash -c "cmake --version | head -1; ninja --version"
run_ok bash -c "command -v gcc-13 g++-13 || echo '(gcc-13/g++-13: MISSING)'"
run_ok bash -c "python3 --version; python3 -c 'import ensurepip' 2>&1 | tail -1 || true; command -v pip3 || echo '(pip3: MISSING)'"

# --- 构建依赖（FFmpeg / libcurl 开发库）---
run_ok bash -c "for p in libavcodec libavformat libavutil libswscale libcurl zlib; do printf '%-14s %s\n' \"\$p\" \"\$(pkg-config --modversion \$p 2>/dev/null || echo MISSING)\"; done"

# --- 既有 NInfer 痕迹（污染审计：本项目不得使用这些）---
run_ok bash -c "ls -d \$HOME/.cache/ninfer 2>/dev/null && ls -la \$HOME/.cache/ninfer || echo '(no ~/.cache/ninfer)'"
run_ok bash -c "ls -d \$HOME/src/ninfer-all 2>/dev/null || echo '(no ~/src/ninfer-all)'"
run_ok bash -c "ls -d \$HOME/llm 2>/dev/null || echo '(no ~/llm)'"
run_ok bash -c "ls \$HOME/.config/systemd/user/ 2>/dev/null | grep -iE 'ninfer|llama' || echo '(no ninfer/llama user units)'"
run_ok bash -c "ss -ltnp 2>/dev/null | grep -E ':(8098|8901|8905|8906|8907|8908)\b' || echo '(no ninfer-ish ports listening)'"

# --- 网络可达性（决定下载路径）---
run_ok bash -c "timeout 20 curl -sS -o /dev/null -w 'hf-mirror.com=%{http_code} time=%{time_total}\n' '$HF_ENDPOINT/api/models/$NINFER_MODEL_HF_REPO' || echo '(hf-mirror unreachable)'"
run_ok bash -c "timeout 20 curl -sS -o /dev/null -w 'api.github.com=%{http_code}\n' https://api.github.com || echo '(github api unreachable)'"
run_ok bash -c "timeout 20 curl -sS -o /dev/null -w 'nvidia.cn=%{http_code}\n' '$NINFER_CUDA_MIRROR/12.9.0/local_installers/' || echo '(nvidia mirror unreachable)'"

# --- 结论摘要 ---
{
  echo "# Phase 0 摘要"
  echo
  echo "- 若上面 nvidia-smi 成功，说明这台机器**不是**空白 Ubuntu：驱动已存在。"
  echo "- 本项目在既有机器上的执行方式：所有构建输入仍走项目自带路径（见 config/env.sh），"
  echo "  并用 evidence/isolation/ 证明没有使用机器上既有的 CUDA / NInfer 产物。"
  echo "- 在真正重装的空白 Ubuntu 上，本脚本的 nvidia-smi / nvcc / ~/.cache/ninfer 三项应全部为缺失。"
} > "$EV/PHASE0-SUMMARY.md"

cp "$LOG_ROOT"/*.log "$EV/" 2>/dev/null || true
log_finish 0
echo "[done] baseline evidence -> $EV"
