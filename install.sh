#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install.sh —— 一条命令把本仓库变成可运行的引擎
#
#   ./install.sh                     # 拉载荷 + 拉模型 + 自检
#   ./install.sh --runtime-from DIR  # 载荷从本地目录取
#   ./install.sh --model-from PATH   # 模型从本地文件取
#   ./install.sh --skip-model        # 只装引擎（稍后再拉模型）
#
# 装完之后：
#   ./start.sh        启动
#   ./webui.sh        打开网页控制台（推荐）
#
# 重要：本仓库自包含 —— 所有路径都相对仓库根解析，不会引用仓库外的任何东西。
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
# shellcheck source=scripts/lib.sh
. "$HERE/scripts/lib.sh"

RT_ARGS=(); MD_ARGS=(); SKIP_MODEL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime-from) RT_ARGS=(--from "$2"); shift 2 ;;
    --runtime-url)  RT_ARGS=(--url  "$2"); shift 2 ;;
    --runtime-tarball) RT_ARGS=(--tarball "$2"); shift 2 ;;
    --model-from)   MD_ARGS=(--from "$2"); shift 2 ;;
    --skip-model)   SKIP_MODEL=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

echo "================================================================"
echo " bonsai2-ninfer-3060-agent-linux 安装"
echo " 仓库根：$ROOT"
echo "================================================================"
echo

# --- 1. 环境自检 ---------------------------------------------------------
log "[1/5] 环境自检"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  die "找不到 nvidia-smi —— 需要先装 NVIDIA 驱动（>= 570）。参考 docs/REQUIREMENTS.md"
fi
DRV="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
log "  驱动版本：${DRV:-未知}"

GPU_LINE="$(nvidia-smi --query-gpu=index,uuid,name,memory.total,compute_cap \
            --format=csv,noheader,nounits 2>/dev/null | grep '8\.6' | head -1)"
if [ -z "$GPU_LINE" ]; then
  warn "没找到 compute capability 8.6（RTX 3060/3070/3080/3090）的卡。"
  warn "本项目的引擎只编译了 sm_86 内核，别的架构会报："
  warn "  cudaErrorNoKernelImageForDevice: no kernel image is available"
  echo
  nvidia-smi --query-gpu=index,uuid,name,memory.total,compute_cap \
             --format=csv,noheader 2>/dev/null | sed 's/^/    /'
  die "需要一张 sm_86 的卡"
fi
ok "找到可用卡：$GPU_LINE"

if command -v zstd >/dev/null 2>&1; then :; else
  warn "没有 zstd（解 Release 载荷要用）：sudo apt install zstd"
fi
command -v curl >/dev/null 2>&1 || die "缺少 curl：sudo apt install curl"
echo

# --- 2. 引擎载荷 ---------------------------------------------------------
log "[2/5] 引擎载荷 → runtime/"
bash "$ROOT/scripts/fetch-runtime.sh" ${RT_ARGS[@]+"${RT_ARGS[@]}"} || die "载荷安装失败"
echo

# --- 3. 模型 -------------------------------------------------------------
if [ "$SKIP_MODEL" = "1" ]; then
  warn "[3/5] 按要求跳过模型下载"
  warn "  稍后补：./scripts/fetch-model.sh"
else
  log "[3/5] 模型 → models/（9.5 GB，可中断后重跑续传）"
  bash "$ROOT/scripts/fetch-model.sh" ${MD_ARGS[@]+"${MD_ARGS[@]}"} || die "模型安装失败"
fi
echo

# --- 4. 生成 config/runtime.env -----------------------------------------
log "[4/5] 生成 config/runtime.env"
if [ -f "$ROOT/config/runtime.env" ]; then
  ok "  已存在，保留不覆盖（要重置就删掉它再跑一次）"
else
  UUID="$(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | head -1)"
  # 优先挑 sm_86 那张
  SM86_UUID="$(nvidia-smi --query-gpu=uuid,compute_cap --format=csv,noheader,nounits 2>/dev/null \
               | awk -F, '$2+0==8.6 {gsub(/ /,"",$1); print $1; exit}')"
  [ -n "$SM86_UUID" ] && UUID="$SM86_UUID"

  cat > "$ROOT/config/runtime.env" <<EOF
# ---------------------------------------------------------------------------
# bonsai2-ninfer-3060-agent-linux 运行配置 —— 这是唯一需要改的文件
# 由 install.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# ---------------------------------------------------------------------------

HOST=127.0.0.1
PORT=8098
MODEL_ID=bonsai2-27b

# 锁卡：CUDA 的运行时设备序和 nvidia-smi 相反，必须按 UUID 锁，
# 否则可能挑到你机器上另一张卡（本项目实测过挑中 V100 → sm_70 没有内核）。
GPU_UUID=$UUID

# KV 量化与容量
#   rk2v4-e8 是 12G 卡上能开最大上下文的量化；容量必须实测，不要猜。
#   空卡实测能到 76768，但桌面上开个浏览器就会掉，所以默认取 49152 这个稳妥值。
#   改大之前先看 docs/PARAMETERS.md。
KV_DTYPE=rk2v4-e8
KV_CAPACITY=49152

# 投机解码：dflash2 + 7 个草稿 token 是实测吞吐最好的一档
SPEC_FLAGS="--spec dflash2 --draft-tokens 7"

# 采样与思考
#   思考预算是"收口"不是"提速"：4096 会让每个请求烧满 4096 个思考 token。
#   1024 在同一任务上墙钟 44 秒，4096 要 68 秒。
#   ⚠ 不要加 --greedy，也不要加 --no-thinking：两者合用会让模型逐字节
#     重复同一个工具调用，陷入死循环（病历 L26）。
EXTRA_FLAGS="--max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 --default-reasoning-effort medium --default-thinking-budget 1024 --request-log-jsonl $ROOT/logs/request.jsonl"
EOF
  ok "  已写入 config/runtime.env（锁卡 $UUID）"
fi
echo

# --- 5. 自检 -------------------------------------------------------------
log "[5/5] 前置自检"
bash "$ROOT/app/launcher.sh" check && ok "自检通过" || warn "自检有告警（见上）"
echo

cat <<EOF
================================================================"
 安装完成
================================================================"

下一步：

  1) 启动引擎（第一次要 30–40 秒加载 7.99 GiB 权重）
       ./start.sh

  2) 打开网页控制台（启停 / 实时日志 / 参数 / 每个请求的速度）
       ./webui.sh

  3) 或者直接用命令行
       ./status.sh              看状态
       ./logs.sh -f             跟日志
       ./stop.sh                停止

  想接入自己的 agent / 客户端：把 base_url 指向
       http://127.0.0.1:8098/v1
  模型名（model id）：bonsai2-27b

  开机自启（可选）：
       ./scripts/install-service.sh
EOF
