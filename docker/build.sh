#!/usr/bin/env bash
# ===========================================================================
#  构建镜像
# ===========================================================================
#
#  用法：
#      ./docker/build.sh                          # 用 ubuntu:24.04 构建
#      ./docker/build.sh --base docker.m.daocloud.io/library/ubuntu:24.04
#      ./docker/build.sh --with-model             # 把 9.5 GB 模型也烧进去（约 12 GB）
#      ./docker/build.sh --tag my/bonsai:test
#
#  两条前置条件，脚本会先检查：
#      1. runtime/ 里要有引擎（没有就先跑 ./scripts/fetch-runtime.sh）
#      2. docker 能拉到基座镜像（国内拉不动就 --base 换镜像站，见 docs/DOCKER.md）
#
# ===========================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BASE="${BASE:-ubuntu:24.04}"
TAG="bonsai2-ninfer-3060:${VERSION}"
WITH_MODEL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base)       BASE="$2"; shift 2 ;;
    --tag|-t)     TAG="$2"; shift 2 ;;
    --with-model) WITH_MODEL=1; shift ;;
    --no-cache)   NOCACHE="--no-cache"; shift ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
NOCACHE="${NOCACHE:-}"

log()  { printf '\033[36m[build]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "没有 docker"

# --- 前置检查 ---------------------------------------------------------------
[ -x runtime/bin/ninfer-serve ] || die "runtime/ 里没有引擎。
      先跑： ./scripts/fetch-runtime.sh --auto
      （镜像不编译引擎，它只装已经验证过的那个二进制）"
[ -f runtime/profiles/device-profiles.json ] || die "runtime/profiles/device-profiles.json 缺失。
      标定文件必须随载荷一起进来，否则容器里引擎起不来。"

log "引擎： $(stat -c %s runtime/bin/ninfer-serve) 字节"
log "载荷： $(du -sh runtime | cut -f1)"
if [ "$WITH_MODEL" = "1" ]; then
  [ -f models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer ] || die "--with-model 但 models/ 里没有权重。
      先跑： ./scripts/fetch-model.sh"
  log "模型： $(du -sh models | cut -f1)（会烧进镜像）"
else
  log "模型：不烧进镜像，运行时用 ./docker/run.sh 挂载"
fi

# --- 构建 -------------------------------------------------------------------
log "基座 $BASE → 镜像 $TAG"

# --with-model 要放行 models/，但 .dockerignore 默认挡着它 —— 默认构建的上下文
# 只该有 2.6 GB，不能因为偶发的胖镜像需求就让每次都拖 9.5 GB。
#
# 这里临时改写 .dockerignore 来条件放行，构建结束（无论成败）还原。
# 不用 docker/Dockerfile.dockerignore 那种"按 Dockerfile 生效"的写法，是因为
# 它属于 BuildKit 特性，而本机没装 buildx 插件、走的是经典构建器，不会生效 ——
# 那种写法的失败方式是静默的：镜像建出来了，模型没进去。
if [ "$WITH_MODEL" = "1" ]; then
  BAK=".dockerignore.bak-build"
  [ -e "$BAK" ] && die "$BAK 已存在（可能是上次中断留下的），先处理掉它"
  cp .dockerignore "$BAK"
  trap 'mv -f "$BAK" .dockerignore 2>/dev/null || true' EXIT
  grep -vE '^(models/|\*\.ninfer)$' "$BAK" > .dockerignore
  log "已临时放行 models/（上下文会涨到约 12 GB；构建结束自动还原 .dockerignore）"
fi

docker build $NOCACHE \
  --build-arg "BASE=$BASE" \
  --build-arg "WITH_MODEL=$WITH_MODEL" \
  -f docker/Dockerfile \
  -t "$TAG" \
  . || die "构建失败"

echo
log "构建完成"
docker images "$TAG" --format '  {{.Repository}}:{{.Tag}}  {{.Size}}'
cat <<EOF

下一步：

  ./docker/run.sh          # 前台跑起来（引擎 + 网页控制台）
  ./docker/run.sh -d       # 后台跑
  ./docker/run.sh shell    # 进容器看看到底装了什么

  打开 http://127.0.0.1:8099/ 就是网页控制台。

EOF
