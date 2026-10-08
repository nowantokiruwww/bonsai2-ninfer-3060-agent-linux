#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/make-release.sh —— 打出 Release 附件（引擎载荷）
#
#   ./scripts/make-release.sh                     # 自动找载荷
#   ./scripts/make-release.sh --from DIR          # 指定载荷目录
#   ./scripts/make-release.sh --out DIR           # 指定输出目录（默认 dist/）
#
# 产出：
#   dist/runtime-<version>-linux-x86_64.tar.zst
#   dist/runtime-<version>-linux-x86_64.tar.zst.sha256
#
# 为什么要单独发：载荷 2.6 GB（3 个二进制 + 4 个 CUDA 运行库），
# GitHub 单文件上限 100 MB，进不了 git；权重 9.5 GB 同理。
# 仓库里只放源码和文档，运行时由 fetch-runtime.sh / fetch-model.sh 取回。
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=../config/release.env
. "$ROOT/config/release.env"

SRC=""
OUTDIR="$ROOT/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --from) SRC="$2"; shift 2 ;;
    --out)  OUTDIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

need_cmd tar
command -v zstd >/dev/null 2>&1 || die "需要 zstd：sudo apt install zstd"

if [ -z "$SRC" ]; then
  # 可选探测候选：找不到就 die，让用户用 --from 指定。
  local cands=(
    "$ROOT/runtime"
    "$HOME/bonsai-ninfer-3060"                                     # verify:allow-outside-path
    "$ROOT/../bonsai2-ninfer-3060-agent-linux.retired/dist/0.1.0/runtime"  # verify:allow-outside-path
  )
  for c in "${cands[@]}"; do
    if [ -x "$c/bin/ninfer-serve" ]; then SRC="$c"; break; fi
  done
fi
[ -n "$SRC" ] || die "没找到载荷，请用 --from DIR 指定"
[ -x "$SRC/bin/ninfer-serve" ] || die "$SRC 不是 runtime 目录"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/runtime"

log "整理载荷（只带运行必需的文件）"
for d in bin lib agent profiles; do
  [ -e "$SRC/$d" ] && cp -a "$SRC/$d" "$STAGE/runtime/"
done
for f in MANIFEST.sha256 LICENSE NOTICE; do
  [ -f "$SRC/$f" ] && cp -a "$SRC/$f" "$STAGE/runtime/"
done
[ -f "$SRC/../LICENSE" ] && cp -a "$SRC/../LICENSE" "$STAGE/runtime/LICENSE" 2>/dev/null || true

# 清掉不该进发布物的东西
find "$STAGE" -name '*.bak*' -delete 2>/dev/null || true
find "$STAGE" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGE" -name '*.log' -delete 2>/dev/null || true
chmod 755 "$STAGE/runtime/bin"/* 2>/dev/null || true

# 重算清单（发布物自带校验）
( cd "$STAGE/runtime" && find . -type f ! -name MANIFEST.sha256 -print0 \
    | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )
ok "载荷清单：$(wc -l < "$STAGE/runtime/MANIFEST.sha256") 个文件"

mkdir -p "$OUTDIR"
ASSET="$OUTDIR/runtime-${REPO_VERSION}-linux-x86_64.tar.zst"
log "压缩 → $ASSET（zstd -19，2.6 GB 大概要几分钟）"
tar --use-compress-program='zstd -T0 -19' -C "$STAGE" -cf "$ASSET" runtime
( cd "$OUTDIR" && sha256sum "$(basename "$ASSET")" > "$(basename "$ASSET").sha256" )

ok "产出："
echo "    $ASSET   $(human_size "$(stat -c %s "$ASSET")")"
echo "    $ASSET.sha256"
echo
echo "上传（有 gh CLI 的话）："
echo "    gh release create v${REPO_VERSION} \\"
echo "      \"$ASSET\" \"$ASSET.sha256\" \\"
echo "      --title \"v${REPO_VERSION}\" --notes-file RELEASE-NOTES.md"
echo
echo "没有 gh 的话：GitHub → Releases → Draft a new release → 手动拖这两个文件上去。"
