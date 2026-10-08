#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/make-release.sh —— 打出 Release 附件（引擎载荷）
#
#   ./scripts/make-release.sh                     # 自动找载荷
#   ./scripts/make-release.sh --from DIR          # 指定载荷目录
#   ./scripts/make-release.sh --out DIR           # 指定输出目录（默认 dist/）
#
# 产出：
#   dist/runtime-<version>-linux-x86_64.tar.zst.part1
#   dist/runtime-<version>-linux-x86_64.tar.zst.part2
#   （每卷一个 .sha256；整包也有一个 .sha256，下载端拼回去后校验整包）
#
# 为什么要单独发：载荷 2.6 GB（3 个二进制 + 4 个 CUDA 运行库），
# 进不了 git（**git 仓库**单文件上限 100 MB）；权重 9.5 GB 同理。
# 仓库里只放源码和文档，运行时由 fetch-runtime.sh / fetch-model.sh 取回。
#
# 为什么要分卷：**GitHub Release 附件单文件上限 2 GiB**（官方文档原话
# "must be under 2 GiB"），而整包压缩后是 2.06 GiB —— 正好超。zstd -19 只降到
# 2.03 GiB，仍然超（CUDA 二进制压缩比只有 1.25x）。所以按 config/release.env 的
# RUNTIME_ASSET_PARTS 切成若干卷，每卷远小于 2 GiB。
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
  # 注意这里在**函数外**，不能用 local。
  cands=(
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
log "压缩 → $ASSET（zstd -19，2.6 GB 实测 219 秒）"
tar --use-compress-program='zstd -T0 -19' -C "$STAGE" -cf "$ASSET" runtime
( cd "$OUTDIR" && sha256sum "$(basename "$ASSET")" > "$(basename "$ASSET").sha256" )

# ---- 分卷 ----------------------------------------------------------------
# 整个 tar.zst 是 2.06 GiB，超过 Release 附件 2 GiB 上限，必须切开。
PARTS="${RUNTIME_ASSET_PARTS:-1}"
PART_MIB="${RUNTIME_PART_MIB:-1500}"
UPLOADS=()
if [ "$PARTS" -gt 1 ]; then
  log "切分为 $PARTS 卷（每卷 ≤ ${PART_MIB} MiB）"
  rm -f "$ASSET".part*
  ( cd "$OUTDIR" && split -b "${PART_MIB}M" -d -a 1 --numeric-suffixes=1 \
      "$(basename "$ASSET")" "$(basename "$ASSET").part" )
  for i in $(seq 1 "$PARTS"); do
    p="$ASSET.part$i"
    [ -f "$p" ] || die "切分后缺少第 $i 卷：$p"
    ( cd "$OUTDIR" && sha256sum "$(basename "$p")" > "$(basename "$p").sha256" )
    UPLOADS+=("$p" "$p.sha256")
  done
fi
UPLOADS+=("$ASSET.sha256")

ok "产出："
echo "    整包  $ASSET   $(human_size "$(stat -c %s "$ASSET")")"
if [ "$PARTS" -gt 1 ]; then
  for i in $(seq 1 "$PARTS"); do
    p="$ASSET.part$i"
    echo "    分卷  $p   $(human_size "$(stat -c %s "$p")")"
  done
fi
echo "    校验  $ASSET.sha256$([ "$PARTS" -gt 1 ] && echo '  + 每卷一 .sha256')"
echo
echo "上传（有 gh CLI 的话）："
echo "    gh release create v${REPO_VERSION} \\"
printf '      %s \\\n' "${UPLOADS[@]}"
echo "      --title \"v${REPO_VERSION}\" --notes-file RELEASE-NOTES.md"
echo
if [ "$PARTS" -gt 1 ]; then
  cat <<EOF
没有 gh 的话：GitHub → Releases → Draft a new release → 手动拖文件上去。
⚠ 分卷必须**全部**传上去，缺一卷装不上：
EOF
  printf '      %s\n' "$(basename "$ASSET")".part* "$ASSET.sha256"
  echo "   下载端会拼回整包并校验整包 sha256，所以每卷的 .sha256 也建议一并上传。"
else
  echo "没有 gh 的话：GitHub → Releases → Draft a new release → 手动拖这两个文件上去。"
fi
