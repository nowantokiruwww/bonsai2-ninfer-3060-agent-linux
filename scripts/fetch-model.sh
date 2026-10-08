#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/fetch-model.sh —— 把 9.5 GB 的模型放进 <repo>/models/
#
#   ./scripts/fetch-model.sh               # 从 config/release.env 里的镜像下载
#   ./scripts/fetch-model.sh --from PATH   # 从本地已有文件复制/硬链接（最快）
#   ./scripts/fetch-model.sh --check       # 只校验
#
# 模型不随仓库发布（太大），也不随 Release 附件（9.5 GB 超过多数人的耐心），
# 由本脚本在安装时拉取。下载完会校验 sha256，不符就删掉重下。
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=../config/release.env
. "$ROOT/config/release.env"

MODEL_DIR="$ROOT/models"
TARGET="$MODEL_DIR/$MODEL_FILENAME"

MODE="download"; ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from)  MODE=from;   ARG="$2"; shift 2 ;;
    --check) MODE=check;  shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

model_ok() { verify_file "$TARGET" "$MODEL_SHA256" "$MODEL_BYTES"; }

url() {
  printf '%s/%s/resolve/%s/%s' "$MODEL_ENDPOINT" "$MODEL_REPO" "$MODEL_REVISION" "$MODEL_FILENAME"
}

main() {
  mkdir -p "$MODEL_DIR"

  if [ "$MODE" = "check" ]; then
    if model_ok; then ok "模型校验通过：$TARGET"; exit 0
    else die "模型缺失或校验不过：$TARGET"; fi
  fi

  if model_ok; then
    ok "模型已就位且校验通过（$(human_size "$MODEL_BYTES")）"
    exit 0
  fi

  if [ "$MODE" = "from" ]; then
    [ -f "$ARG" ] || die "文件不存在：$ARG"
    # ⚠ 必须先解析符号链接。
    # 别人机器上的部署经常把模型做成软链（指向 .store/models/…）。
    # 直接 ln 会硬链接**那个软链本身**（146 字节），而不是 9.5 GB 的权重，
    # 结果是「链接成功」但文件是坏的，直到校验阶段才炸。
    local src; src="$(readlink -f "$ARG" 2>/dev/null || echo "$ARG")"
    [ -f "$src" ] || die "解析符号链接后文件不存在：$src"
    [ "$src" != "$ARG" ] && log "源是符号链接，已解析为 $src"
    log "从 $src 取模型"
    rm -f "$TARGET"
    # 同盘优先硬链接（秒级、零额外空间），否则复制
    if ln "$src" "$TARGET" 2>/dev/null; then
      ok "已硬链接（同一文件系统）"
    else
      log "跨文件系统，复制中…"
      cp -f "$src" "$TARGET"
    fi
  else
    local u; u="$(url)"
    log "模型地址：$u"
    log "大小 $(human_size "$MODEL_BYTES")，断点续传已开启（中断后重跑本脚本即可继续）"
    # 已有部分文件则接着下
    download "$u" "$TARGET"
  fi

  if model_ok; then
    ok "模型就位并校验通过：$TARGET"
  else
    local got; got="$(sha256_of "$TARGET")"
    local sz;  sz="$(stat -c %s "$TARGET" 2>/dev/null || echo 0)"
    warn "校验失败：体积 $sz / 期望 $MODEL_BYTES；sha256 $got"
    die "模型文件不完整或被改动。删掉 $TARGET 后重跑本脚本。"
  fi
}

main
