#!/usr/bin/env bash
# scripts/50-build.sh — Phase 5：sm_86 的 Linux 编译 + 污染门禁 + 产物体检
#
# 步骤：
#   1. 构建期污染门禁：断言环境里没有任何指向项目外的 CUDA。
#   2. configure（Ninja / Release / gcc-13 / 项目自带 nvcc / arch=86）。
#   3. build --parallel 6（硬上限：本机 23Gi 内存，bench 侧 -j 24 曾触发内核 BugCheck）。
#   4. 产物期污染门禁：readelf -d 的 RUNPATH + ldd 的真实解析必须落在项目内。
#   5. 产物体检：cuobjdump -lelf（必须 sm_86）/ -lptx（如实记录有无）/ file / sha256。
#
# 不做任何需要 sudo 的动作。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "50-build"
EV="$PROJ/evidence/build"; mkdir -p "$EV"
ISO="$PROJ/evidence/isolation"; mkdir -p "$ISO"

fail=0

# ---------------------------------------------------------------- 1. 构建期门禁
{
  echo "# 构建期污染门禁"
  echo "checked_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  for v in CUDA_HOME CUDA_PATH CUDA_ROOT CUDACXX CUDAToolkit_ROOT CMAKE_PREFIX_PATH PKG_CONFIG_PATH; do
    printf '%-18s = %s\n' "$v" "${!v:-<unset>}"
  done
  echo "PATH             = $PATH"
  echo "LD_LIBRARY_PATH  = ${LD_LIBRARY_PATH:-<unset>}"
} | tee "$ISO/build-env-before.txt"

# PATH / LD_LIBRARY_PATH 里出现任何项目外 CUDA 都是违规
for var in PATH LD_LIBRARY_PATH; do
  val="${!var:-}"
  bad=$(echo "$val" | tr ':' '\n' | grep -E '/usr/local/cuda|'"$HOME"'/cuda' || true)
  if [ -n "$bad" ]; then
    echo "[fail] $var 指向项目外 CUDA:" >&2; echo "$bad" >&2; fail=1
  fi
done
# 显式设置的 CUDA* 变量必须落在项目内
for var in CUDA_HOME CUDA_PATH CUDA_ROOT CUDACXX CUDAToolkit_ROOT; do
  val="${!var:-}"
  if [ -n "$val" ] && [[ "$val" != "$NINFER_CUDA_DIR"* ]]; then
    echo "[fail] $var=$val 不在项目内 ($NINFER_CUDA_DIR)" >&2; fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo "[fail] 构建期污染门禁未通过，终止。" >&2; exit 1; }
note "构建期污染门禁通过"

# 清空后再显式指向项目自带工具链
export CUDA_HOME="$NINFER_CUDA_DIR"
export CUDA_PATH="$NINFER_CUDA_DIR"
export CUDACXX="$NINFER_CUDA_DIR/bin/nvcc"
export PATH="$NINFER_CUDA_DIR/bin:$(echo "$PATH" | tr ':' '\n' | grep -vE '/usr/local/cuda|'"$HOME"'/cuda' | paste -sd:)"
unset LD_LIBRARY_PATH 2>/dev/null || true

{
  echo; echo "# 构建期门禁通过后的环境"
  echo "CUDA_HOME=$CUDA_HOME"; echo "CUDACXX=$CUDACXX"; echo "PATH=$PATH"
} | tee -a "$ISO/build-env-after.txt"

# ---------------------------------------------------------------- 2. configure
[ -x "$CUDACXX" ] || { echo "[fail] 项目自带 nvcc 不存在: $CUDACXX（先跑 scripts/20-cuda-fetch.sh）" >&2; exit 1; }
[ -d "$NINFER_SRC_DIR/.git" ] || { echo "[fail] 源码未就位: $NINFER_SRC_DIR（先跑 scripts/40-fetch-sources.sh）" >&2; exit 1; }

run "$CUDACXX" --version
run "$CUDACXX" --list-gpu-arch

run cmake -S "$NINFER_SRC_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC_HOST" \
  -DCMAKE_CXX_COMPILER="$CXX_HOST" \
  -DCMAKE_CUDA_COMPILER="$CUDACXX" \
  -DCMAKE_CUDA_HOST_COMPILER="$CXX_HOST" \
  -DCUDAToolkit_ROOT="$NINFER_CUDA_DIR" \
  -DCMAKE_CUDA_ARCHITECTURES="$NINFER_ARCH" \
  -DNINFER_BUILD_APPS=ON \
  -DBUILD_TESTING=OFF \
  -DNINFER_BUILD_BENCHMARKS=OFF

grep -E 'CMAKE_CUDA_ARCHITECTURES|CUDAToolkit_ROOT|CMAKE_CUDA_COMPILER:|CMAKE_CXX_COMPILER:|CMAKE_BUILD_TYPE' \
  "$BUILD_DIR/CMakeCache.txt" > "$EV/cmake-cache-key-lines.txt" 2>/dev/null || true

# ---------------------------------------------------------------- 3. build
note "开始构建（-j $NINFER_JOBS）… 本机同配置历史耗时约 96.6 分钟"
run cmake --build "$BUILD_DIR" --parallel "$NINFER_JOBS"

# ---------------------------------------------------------------- 4. 产物期门禁
BIN="$NINFER_SERVE"
[ -x "$BIN" ] || { echo "[fail] 未产出 $BIN" >&2; exit 1; }

readelf -d "$BIN" > "$ISO/readelf-dyn.txt" 2>&1 || true
ldd "$BIN" > "$ISO/ldd.txt" 2>&1 || true
LC_ALL=C readelf -d "$BIN" | grep -E 'RUNPATH|RPATH' > "$ISO/runpath.txt" 2>&1 || true

# ⚠ 必须 LC_ALL=C：非英文 locale 下 readelf 会把 "Library runpath" 本地化，
# 早期版本用 `grep -oE '/[^]]*'` 抓路径会抓到本地化文本里的斜杠，
# 实测得到 `runpath = /值` 而真实 RUNPATH 明明是项目内路径 → 误判 FAIL。
RUNPATH=$(LC_ALL=C readelf -d "$BIN" \
  | sed -n 's/.*(RUNPATH)[^[]*\[\(.*\)\].*/\1/p;s/.*(RPATH)[^[]*\[\(.*\)\].*/\1/p' \
  | tr ':' '\n' | grep -v '^$' | head -1 || true)
if [ -n "$RUNPATH" ] && [[ "$RUNPATH" != "$NINFER_CUDA_DIR"* ]]; then
  echo "[fail] RUNPATH 不在项目内: $RUNPATH" >&2; fail=1
fi

# 项目外 CUDA 库的解析（libcuda.so.1 来自驱动，属白名单例外）
FOREIGN=$(grep -E 'libcudart|libcublas|libnvjitlink' "$ISO/ldd.txt" \
  | grep -vE "$NINFER_CUDA_DIR" || true)
if [ -n "$FOREIGN" ]; then
  echo "[fail] 以下 CUDA 库解析到项目外：" >&2; echo "$FOREIGN" >&2; fail=1
fi
{
  echo "# 产物期污染门禁"
  echo "binary = $BIN"
  echo "runpath = ${RUNPATH:-<none>}"
  echo "project_cuda = $NINFER_CUDA_DIR"
  echo "verdict = $([ "$fail" -eq 0 ] && echo PASS || echo FAIL)"
  echo
  echo "# 项目外解析的 CUDA 库（应为空；libcuda.so.1 属驱动白名单，单独列出）"
  echo "$FOREIGN"
  echo
  echo "# libcuda.so.1（驱动加载器，允许来自系统）"
  grep -E 'libcuda\.so\.1' "$ISO/ldd.txt" || echo "(none)"
} | tee "$ISO/artefact-gate.txt"

[ "$fail" -eq 0 ] || { echo "[fail] 产物期污染门禁未通过。" >&2; exit 1; }

# ---------------------------------------------------------------- 5. 体检
for b in ninfer ninfer-serve ninfer-calibrate ninfer-perplexity; do
  p="$BUILD_DIR/apps/$b"
  [ -f "$p" ] || continue
  echo "=== $b ($(stat -c %s "$p") B, sha256=$(sha256sum "$p" | cut -c1-16)…) ==="
done | tee "$EV/apps-inventory.txt"

{
  echo "# cuobjdump -lelf (设备码 / cubin)"
  "$NINFER_CUDA_DIR/bin/cuobjdump" -lelf "$BIN" 2>&1 || echo "(cuobjdump failed)"
  echo
  echo "# cuobjdump -lptx (PTX / 中间码)"
  "$NINFER_CUDA_DIR/bin/cuobjdump" -lptx "$BIN" 2>&1 || echo "(no PTX)"
} > "$EV/cuobjdump.txt"

echo "--- cubin 架构清单 ---"
grep -oE 'sm_[0-9]+[a-z]?' "$EV/cuobjdump.txt" | sort | uniq -c | tee "$EV/arch-summary.txt"
echo "--- PTX 有无 ---"
if grep -q 'No PTX file found\|no PTX' "$EV/cuobjdump.txt"; then
  echo "PTX = 无（CMAKE_CUDA_ARCHITECTURES=$NINFER_ARCH 只出 cubin；40/50 系无法靠 JIT 复用）" | tee "$EV/ptx-status.txt"
else
  echo "PTX = 有（见 cuobjdump.txt）" | tee "$EV/ptx-status.txt"
fi
{
  echo "# 入口文件"
  file "$BIN"
  echo "# sha256"
  sha256sum "$BUILD_DIR/apps/"ninfer* 2>/dev/null
} > "$EV/binary-identity.txt"
cat "$EV/binary-identity.txt"

note "构建完成；门禁 PASS；产物 $BIN"
log_finish 0
echo "[done] build -> $BUILD_DIR  (evidence=$EV, isolation=$ISO)"
