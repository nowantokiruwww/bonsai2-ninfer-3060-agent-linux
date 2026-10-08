#!/usr/bin/env bash
# ===========================================================================
#  docker/deploy.sh —— Docker 一键部署入口
# ===========================================================================
#
#  把「仓库 → 能用的容器」这几步串成一条命令：
#
#    1. 安装/校验引擎载荷与模型（复用 ./install.sh，断点续传 + sha256）
#    2. 构建运行镜像（复用 ./docker/build.sh）
#    3. 启动容器（复用 ./docker/run.sh）
#
#  用法：
#      ./docker/deploy.sh                 # 本机访问，前台运行（Ctrl-C 停）
#      ./docker/deploy.sh -d              # 后台运行
#      ./docker/deploy.sh --lan -d        # 允许局域网访问（⚠ 无鉴权）
#      ./docker/deploy.sh logs            # 只看日志（不重新安装/构建）
#      ./docker/deploy.sh status          # 容器状态 + 端口探活
#      ./docker/deploy.sh stop            # 停容器
#      ./docker/deploy.sh shell           # 进容器 bash
#
#  环境变量：
#      BASE=...        基座镜像（默认 ubuntu:24.04；国内可换镜像站）
#      IMAGE=...       镜像标签（默认 bonsai2-ninfer-3060:<VERSION>）
#      其余变量（PORT / WEBUI_PORT / MODEL_DIR / GPU_UUID / ADVERTISE_IP…）
#      原样传给 ./docker/run.sh，含义见该脚本头部注释。
#
#  这个脚本**不做**的事：
#      * 不自己实现下载、校验、选卡、容器参数 —— 那些都是上面三个脚本的职责，
#        这里只做编排，避免出现第二份真相。
#      * 不隐式开放局域网：默认只绑回环，要开必须显式 --lan。
#      * 不碰宿主机的 models/、logs/、config/runtime.env（它们是本机资产）。
#
# ===========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[36m[deploy]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[deploy]\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
# BASE 默认与 docker/build.sh 一致；要换镜像站就在外面 export BASE=...
BASE="${BASE:-ubuntu:24.04}"
# build.sh 认 TAG、run.sh 认 IMAGE —— 这里把两者钉成同一个名字，
# 否则会出现「构建了一个标签、又去找另一个标签」的静默不一致。
IMAGE="${IMAGE:-${TAG:-bonsai2-ninfer-3060:${VERSION}}}"
TAG="${TAG:-$IMAGE}"
[ "$IMAGE" = "$TAG" ] || die "IMAGE 与 TAG 不一致（$IMAGE ≠ $TAG）；只设置其中一个。"
export BASE IMAGE TAG

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

# run.sh 的这几个子命令只操作已有容器，不该触发安装和构建。
case "${1:-}" in
  logs|status|stop|shell) exec "$ROOT/docker/run.sh" "$@" ;;
esac

command -v docker >/dev/null 2>&1 || die "没有 docker —— 先装 Docker Engine，见 docs/DOCKER.md"
docker info >/dev/null 2>&1 || die "docker 命令在，但连不上 daemon。
      常见原因：没启动 docker 服务，或当前用户不在 docker 组（sudo usermod -aG docker \$USER 后重新登录）。"

log "第 1/3 步：安装引擎载荷与模型（已存在则只校验）"
bash "$ROOT/install.sh"

log "第 2/3 步：构建镜像 $IMAGE（基座 $BASE）"
if ! bash "$ROOT/docker/build.sh"; then
  die "镜像构建失败。最常见的原因是基座镜像「$BASE」拉不动（Docker Hub 在国内经常超时）。
      换成镜像站，整条命令重跑一遍即可 —— 第 1 步已经装好的东西会自动跳过：

        BASE=docker.m.daocloud.io/library/ubuntu:24.04 ./docker/deploy.sh $*

      其它情况（依赖闭包、磁盘空间）见 docs/DOCKER.md。"
fi

log "第 3/3 步：启动容器"
exec bash "$ROOT/docker/run.sh" "$@"
