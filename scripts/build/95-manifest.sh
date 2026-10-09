#!/usr/bin/env bash
# scripts/95-manifest.sh — 汇总 MANIFEST.md：所有输入与产物的 sha256 + 来源
#
# 去黑盒化的落点：任何一个产物都能回答"来自哪个 commit、哪套工具链、哪条命令行"。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "95-manifest"
M="$PROJ/MANIFEST.md"
EV="$PROJ/evidence"; mkdir -p "$EV"

h() { [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo "(缺失)"; }
sz() { [ -f "$1" ] && stat -c %s "$1" || echo "-"; }

{
  echo "# MANIFEST — 输入与产物的身份"
  echo
  echo "生成时间：$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "说明：本文件由 \`scripts/95-manifest.sh\` 生成。**任何数字离开这张表都无法追溯。**"
  echo
  echo "## 1. 输入"
  echo
  echo "| 输入 | 标识 | 值 |"
  echo "|---|---|---|"
  echo "| 引擎源码仓库 | repo | \`$NINFER_SRC_REPO\` |"
  echo "| 引擎源码 commit | sha | \`$NINFER_SRC_COMMIT\` |"
  echo "| 引擎源码版本 | VERSION | \`$NINFER_SRC_VERSION\` |"
  echo "| 引擎源码树 | tree | \`$(git -C "$NINFER_SRC_DIR" rev-parse 'HEAD^{tree}' 2>/dev/null || echo '(未取源码)')\` |"
  echo "| 方法学参照仓库 | repo | \`$BENCH_REPO\` |"
  echo "| 方法学参照 commit | sha | \`$BENCH_REPO_COMMIT\` |"
  echo "| 模型仓库 | repo | \`$NINFER_MODEL_HF_REPO\` |"
  echo "| 模型 revision | sha | \`$NINFER_MODEL_HF_REVISION\` |"
  echo "| 模型 sha256 | sha256 | \`$NINFER_MODEL_SHA256\` |"
  echo "| 模型字节数 | bytes | \`$NINFER_MODEL_BYTES\` |"
  echo "| CUDA redist 清单 | sha256 | \`$(h "$STORE_TOOLCHAIN/redistrib_$NINFER_CUDA_REDIST.json")\` |"
  echo
  echo "## 2. 工具链（精确版本见 \`config/toolchain.lock\`）"
  echo
  echo "| 项 | 值 |"
  echo "|---|---|"
  echo "| CUDA | $NINFER_CUDA_VERSION（redist $NINFER_CUDA_REDIST，地板 $NINFER_CUDA_FLOOR） |"
  echo "| nvcc | \`$NINFER_CUDA_DIR/bin/nvcc\` |"
  echo "| nvcc release | \`$([ -x "$NINFER_CUDA_DIR/bin/nvcc" ] && "$NINFER_CUDA_DIR/bin/nvcc" --version | grep -oE 'release [0-9.]+' | head -1 || echo '(未安装)')\` |"
  echo "| 目标架构 | sm_$NINFER_ARCH |"
  echo "| host CC | \`$CC_HOST\` / \`$CXX_HOST\` |"
  echo "| 构建并行度 | $NINFER_JOBS |"
  echo
  echo "## 3. 构建产物"
  echo
  echo "| 产物 | 字节 | sha256 |"
  echo "|---|---|---|"
  for b in ninfer ninfer-serve ninfer-calibrate ninfer-perplexity; do
    p="$BUILD_DIR/apps/$b"
    [ -f "$p" ] && echo "| \`$b\` | $(sz "$p") | \`$(h "$p")\` |"
  done
  echo
  echo "（Release 构建默认不保证 bit-reproducible，故这些 sha256 标识的是**本次构建**，不是唯一可能的结果。）"
  echo
  echo "## 4. device profile（每张卡不同）"
  echo
  echo "| 项 | 值 |"
  echo "|---|---|"
  echo "| 路径 | \`$NINFER_DEVICE_PROFILES\` |"
  echo "| 字节 | $(sz "$NINFER_DEVICE_PROFILES") |"
  echo "| sha256 | \`$(h "$NINFER_DEVICE_PROFILES")\` |"
  echo "| GPU | RTX 3060 / sm_86 / 28 SM / \`$GPU_UUID_3060\` |"
  echo
  echo "## 5. 结果"
  echo
  echo "| 文件 | sha256 |"
  echo "|---|---|"
  if [ -d "$PROJ/results" ]; then
    for f in "$PROJ/results/"*; do
      [ -f "$f" ] && echo "| \`$(basename "$f")\` | \`$(h "$f")\` |"
    done
  fi
  echo
  echo "## 6. 补丁"
  echo
  if [ -z "$(ls -A "$PROJ/patches" 2>/dev/null | grep -v README.md || true)" ]; then
    echo "**零补丁。** 源码未做任何修改 —— 见 \`patches/README.md\`（这本身是结论的一部分）。"
  else
    for p in "$PROJ/patches/"*.patch; do
      [ -f "$p" ] && echo "- \`$(basename "$p")\` sha256 \`$(h "$p")\`"
    done
  fi
  echo
  echo "## 7. 环境记账"
  echo
  echo "| 项 | 值 |"
  echo "|---|---|"
  echo "| 主机 | $(hostname) |"
  echo "| 内核 | $(uname -r) |"
  echo "| 驱动 | $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo '(未知)') |"
  echo "| 3060 PCIe | $(nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv,noheader 2>/dev/null | head -1 || echo '(未知)') |"
} > "$M"

cp "$M" "$EV/MANIFEST.md"
note "MANIFEST -> $M"
log_finish 0
echo "[done] $M"
