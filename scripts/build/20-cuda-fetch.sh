#!/usr/bin/env bash
# scripts/20-cuda-fetch.sh — Phase 2：项目自带 CUDA 工具链（免 root，逐件 sha256 校验）
#
# 设计：
#   1. 取 NVIDIA 官方 redist 清单，记其 sha256（清单本身就是证据）。
#   2. 只下载构建所需组件（见 config/env.sh 的 NINFER_CUDA_COMPONENTS），
#      每个组件校验 sha256 与字节数，任一不符即失败。
#   3. 解包后把各组件的顶层目录内容合并进 $NINFER_CUDA_DIR，形成常规布局
#      （bin/ include/ lib/ lib64/ nvvm/ ...）。
#   4. 断言 nvcc 可用、--list-gpu-arch 含 compute_86、地板 ≥ 12.8。
#
# 不需要 sudo；不触碰 /usr/local/cuda*。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "20-cuda"
DL="$STORE_TOOLCHAIN/downloads"
MAN="$STORE_TOOLCHAIN/redistrib_$NINFER_CUDA_REDIST.json"
mkdir -p "$DL" "$NINFER_CUDA_DIR"

# --- 1. 清单 ---
run curl -sSL -o "$MAN" "$NINFER_CUDA_REDIST_BASE/redistrib_$NINFER_CUDA_REDIST.json"
run sha256sum "$MAN"
note "redist 清单: $MAN sha256=$(sha256sum "$MAN" | awk '{print $1}')"

LOCK="$PROJ/config/toolchain.lock"
{
  echo "# toolchain.lock — 由 scripts/20-cuda-fetch.sh 与 scripts/30-deps.sh 生成"
  echo "# generated_at: $(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo
  echo "[cuda]"
  echo "requested_version = $NINFER_CUDA_VERSION"
  echo "redist_manifest   = redistrib_$NINFER_CUDA_REDIST.json"
  echo "redist_sha256     = $(sha256sum "$MAN" | awk '{print $1}')"
  echo "floor             = $NINFER_CUDA_FLOOR   # CMakeLists.txt:201-204 强制"
  echo "install_dir       = $NINFER_CUDA_DIR"
  echo
  echo "[cuda.components]"
} > "$LOCK"

# --- 2+3. 逐组件下载 / 校验 / 解包 / 合并 ---
for comp in $NINFER_CUDA_COMPONENTS; do
  meta=$(python3 - "$MAN" "$comp" <<'PY'
import json,sys
man, comp = sys.argv[1], sys.argv[2]
d = json.load(open(man))
v = d.get(comp)
if not isinstance(v, dict):
    sys.exit(f"component {comp!r} not in manifest")
pl = v.get("linux-x86_64")
if not isinstance(pl, dict):
    sys.exit(f"component {comp!r} has no linux-x86_64")
print(v.get("version",""), pl["relative_path"], pl["sha256"], pl["size"], sep="\t")
PY
)
  ver=$(echo "$meta" | cut -f1)
  rel=$(echo "$meta" | cut -f2)
  want_sha=$(echo "$meta" | cut -f3)
  want_sz=$(echo "$meta" | cut -f4)
  file="$DL/$(basename "$rel")"

  if [ ! -s "$file" ] || [ "$(sha256sum "$file" | awk '{print $1}')" != "$want_sha" ]; then
    run curl -sSL --retry 3 -o "$file.part" "$NINFER_CUDA_REDIST_BASE/$rel"
    mv "$file.part" "$file"
  else
    note "复用已校验组件: $(basename "$rel")"
  fi

  got_sha=$(sha256sum "$file" | awk '{print $1}')
  got_sz=$(stat -c %s "$file")
  [ "$got_sha" = "$want_sha" ] || { echo "[fail] $comp sha256 不符: got=$got_sha want=$want_sha" >&2; exit 1; }
  [ "$got_sz" = "$want_sz" ]   || { echo "[fail] $comp 字节数 不符: got=$got_sz want=$want_sz" >&2; exit 1; }

  tmp="$DL/x-$comp"; rm -rf "$tmp"; mkdir -p "$tmp"
  tar -xf "$file" -C "$tmp"
  top=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$top" ] || { echo "[fail] $comp 解包后无顶层目录" >&2; exit 1; }
  # 合并进统一根（-a 保留权限与符号链接）
  cp -a "$top"/. "$NINFER_CUDA_DIR"/
  rm -rf "$tmp"

  printf '%-18s v%-12s %10s B  sha256=%s\n' "$comp" "$ver" "$got_sz" "$got_sha" >> "$LOCK"
  note "installed $comp v$ver ($got_sz B)"
done

# --- 4. 布局修正 + 断言 ---
# CUDA 13 的拆分组件把库放在 lib/，而 nvcc / CMake 按 <cuda>/lib64 搜索
# （libcuda.so 驱动桩在 lib/stubs/）。缺这一层会报：
#   /usr/bin/ld: 找不到 -lcudadevrt / -lcudart_static
# 故补一个 lib64 -> lib 的相对符号链接（幂等）。
[ -e "$NINFER_CUDA_DIR/lib64" ] || ln -sfn lib "$NINFER_CUDA_DIR/lib64"
note "lib64 -> lib 已就位（$(readlink "$NINFER_CUDA_DIR/lib64")）"
# nvcc 的 C 前端在 libnvvm 组件里，缺它 nvcc 任何一次调用都会失败
[ -x "$NINFER_CUDA_DIR/nvvm/bin/cicc" ] || { echo "[fail] 缺 nvvm/bin/cicc（组件清单里必须有 libnvvm）" >&2; exit 1; }

run "$NINFER_CUDA_DIR/bin/nvcc" --version
ARCHS=$("$NINFER_CUDA_DIR/bin/nvcc" --list-gpu-arch | tr '\n' ' ')
note "nvcc --list-gpu-arch = $ARCHS"
echo "$ARCHS" | grep -qw "compute_86" || { echo "[fail] nvcc 不支持 compute_86" >&2; exit 1; }
echo "$ARCHS" | grep -qw "compute_70" && note "注意: 该 nvcc 仍支持 compute_70" || note "注意: 该 nvcc 不含 compute_70（CUDA 13 已移除 Volta）"

VER=$("$NINFER_CUDA_DIR/bin/nvcc" --version | grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')
note "nvcc release = $VER (floor=$NINFER_CUDA_FLOOR)"
python3 -c "import sys; sys.exit(0 if [int(x) for x in '$VER'.split('.')] >= [int(x) for x in '$NINFER_CUDA_FLOOR'.split('.')] else 1)" \
  || { echo "[fail] CUDA $VER 低于地板 $NINFER_CUDA_FLOOR" >&2; exit 1; }

run bash -c "ls -1 '$NINFER_CUDA_DIR/bin' | head -20"
run bash -c "ls -1 '$NINFER_CUDA_DIR/lib64' | grep -E 'libcudart|libcublas|libnvjitlink' || true"

{ echo; echo "[cuda.resolved]"; echo "nvcc_release = $VER"; echo "gpu_archs = $ARCHS"; } >> "$LOCK"

EV="$PROJ/evidence/toolchain"; mkdir -p "$EV"
cp "$LOCK" "$EV/toolchain.lock"
"$NINFER_CUDA_DIR/bin/nvcc" --version > "$EV/nvcc-version.txt" 2>&1
"$NINFER_CUDA_DIR/bin/nvcc" --list-gpu-arch > "$EV/nvcc-list-gpu-arch.txt" 2>&1

log_finish 0
echo "[done] CUDA $NINFER_CUDA_VERSION -> $NINFER_CUDA_DIR ; lock=$LOCK"
