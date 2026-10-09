#!/usr/bin/env bash
# scripts/40-fetch-sources.sh — Phase 4：锁 commit 取源码（去黑盒化）
#
# 1. 引擎源码：iamwavecut/ninfer-all，锁定 config/env.sh 里的 commit。
#    断言 HEAD == 该 commit、工作树干净，并记录 VERSION 与全树清单哈希。
# 2. 方法学参照：suanrongqieqiezi/ninfer-rtx30-bench，只读（license = null，不抄代码）。
#
# 不使用本机任何既有克隆（~/src/ninfer-all 等）。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "40-sources"
mkdir -p "$STORE_SRC" "$STORE_REFS"
EV="$PROJ/evidence/sources"; mkdir -p "$EV"

# git 加固：本环境从 GitHub 拉大 pack 会被中途掐断
#   error: RPC 失败。curl 92 HTTP/2 stream 5 was not closed cleanly: CANCEL (err 8)
# 对策：强制 HTTP/1.1 + 加大 postBuffer + 关压缩，并优先"按 SHA 浅取"把体量降到最小。
GITC=(git -c http.version=HTTP/1.1 -c http.postBuffer=1073741824 -c core.compression=0)

fetch_locked() {
  local repo="$1" want="$2" dir="$3" name="$4"

  if [ ! -d "$dir/.git" ]; then
    rm -rf "$dir"; mkdir -p "$dir"
    run "${GITC[@]}" -C "$dir" init -q
    run "${GITC[@]}" -C "$dir" remote add origin "$repo"
  else
    note "复用已有克隆: $dir"
  fi

  if ! git -C "$dir" cat-file -e "$want^{commit}" 2>/dev/null; then
    # 首选按 SHA 浅取（体量最小、最不易被掐断）；失败再回退完整 fetch
    if ! run "${GITC[@]}" -C "$dir" fetch --depth 1 origin "$want"; then
      note "$name: 按 SHA 浅取失败，回退完整 fetch"
      run "${GITC[@]}" -C "$dir" fetch --tags origin
    fi
  fi

  run "${GITC[@]}" -C "$dir" checkout --force "$want"
  run_ok "${GITC[@]}" -C "$dir" submodule update --init --recursive

  local head
  head=$(git -C "$dir" rev-parse HEAD)
  [ "$head" = "$want" ] || { echo "[fail] $name HEAD=$head != pinned $want" >&2; exit 1; }

  local dirty
  dirty=$(git -C "$dir" status --porcelain | head -20)
  [ -z "$dirty" ] || { echo "[fail] $name 工作树不干净:" >&2; echo "$dirty" >&2; exit 1; }

  note "$name OK: HEAD=$head clean"
  {
    echo "[$name]"
    echo "repo    = $repo"
    echo "commit  = $head"
    echo "dir     = $dir"
    echo "describe= $(git -C "$dir" describe --tags --always 2>/dev/null || echo '-')"
    echo "date    = $(git -C "$dir" show -s --format=%cI HEAD)"
    echo "subject = $(git -C "$dir" show -s --format=%s HEAD)"
    [ -f "$dir/VERSION" ] && echo "VERSION = $(cat "$dir/VERSION")"
    echo "tree    = $(git -C "$dir" rev-parse HEAD^{tree})"
    echo "shallow = $(git -C "$dir" rev-parse --is-shallow-repository)"
    echo
  } >> "$EV/sources.lock"
}

: > "$EV/sources.lock"
fetch_locked "$NINFER_SRC_REPO" "$NINFER_SRC_COMMIT" "$NINFER_SRC_DIR" "ninfer-all"
fetch_locked "$BENCH_REPO"     "$BENCH_REPO_COMMIT"  "$BENCH_REPO_DIR" "ninfer-rtx30-bench"

# 方法学参照仓库：确认它确实不含引擎（把这份"缺失"固化为证据）
{
  echo "[bench-repo-inventory]"
  echo "blob_count = $(git -C "$BENCH_REPO_DIR" ls-tree -r --name-only HEAD | wc -l)"
  echo "has_source_code = $(git -C "$BENCH_REPO_DIR" ls-tree -r --name-only HEAD | grep -cE '\.(c|cc|cpp|cu|cuh|h|hpp)$' || true)"
  echo "has_build_files = $(git -C "$BENCH_REPO_DIR" ls-tree -r --name-only HEAD | grep -cE '(CMakeLists\.txt|Makefile|\.cmake|vcpkg\.json|Dockerfile)' || true)"
  echo "has_patches     = $(git -C "$BENCH_REPO_DIR" ls-tree -r --name-only HEAD | grep -cE '\.(patch|diff)$' || true)"
  echo "has_dep_manifest= $(git -C "$BENCH_REPO_DIR" ls-tree -r --name-only HEAD | grep -ciE '(requirements.*\.txt|.*\.lock|environment\.ya?ml)$' || true)"
  echo "files:"
  git -C "$BENCH_REPO_DIR" ls-tree -r --name-only HEAD | sed 's/^/  /'
} >> "$EV/sources.lock"

# 引擎源码关键事实留证
SRC="$NINFER_SRC_DIR"
{
  echo "[engine-arch-gate]"
  grep -nE 'CMAKE_CUDA_ARCHITECTURES|FATAL_ERROR|CUDA 12\.8' "$SRC/CMakeLists.txt" | head -20
  echo
  echo "[engine-cuda-floor]"
  sed -n '199,206p' "$SRC/CMakeLists.txt"
  echo
  echo "[engine-artifact-v3]"
  grep -nE 'NInfer v2 artifact is not supported|expected NInfer v3 entry magic' "$SRC/src/artifact/reader.cpp" || true
  echo
  echo "[engine-sm86-fp8-stub]"
  ls -la "$SRC/src/ops/fp8_sm86_stubs.cpp" 2>/dev/null || echo "(MISSING: src/ops/fp8_sm86_stubs.cpp)"
  echo
  echo "[engine-t2_g128_fp16]"
  echo "files_hit = $(grep -rIl 't2_g128_fp16' "$SRC/src" "$SRC/include" 2>/dev/null | wc -l)"
  grep -rIl 't2_g128_fp16' "$SRC/src" "$SRC/include" 2>/dev/null | sed 's/^/  /'
  echo
  echo "[engine-hadamard_signs]"
  echo "files_hit = $(grep -rIl 'hadamard_signs' "$SRC/src" "$SRC/include" 2>/dev/null | wc -l)"
  echo
  echo "[engine-device-profile-resolution-order]"
  sed -n '14,22p' "$SRC/docs/device-profiles.md"
} > "$EV/engine-facts.txt"

cp "$EV/sources.lock" "$EV/engine-facts.txt" "$LOG_ROOT/" 2>/dev/null || true
log_finish 0
echo "[done] sources locked. engine=$NINFER_SRC_DIR ref=$BENCH_REPO_DIR"
