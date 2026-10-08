#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/fetch-runtime.sh —— 把引擎载荷放进 <repo>/runtime/
#
# 仓库里**不含** 2.6 GB 的载荷（3 个二进制 + 4 个 CUDA 运行库），因为 GitHub
# 单个文件上限 100 MB。载荷放在 Release 附件里，由本脚本取回。
#
# 用法：
#   ./scripts/fetch-runtime.sh                    # 从 Release 下载（默认）
#   ./scripts/fetch-runtime.sh --from DIR         # 从本地已有的 runtime 目录拷
#   ./scripts/fetch-runtime.sh --tarball FILE     # 从本地 tar.zst 解
#   ./scripts/fetch-runtime.sh --url URL          # 从任意 URL 下载
#   ./scripts/fetch-runtime.sh --auto             # 自动在常见位置找（开发机用）
#   ./scripts/fetch-runtime.sh --check            # 只校验，不下载
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=../config/release.env
. "$ROOT/config/release.env"

RUNTIME="$ROOT/runtime"

# 已知指纹（防"下载到旧版本"）
KNOW_NINFER_SERVE_SHA="7ebf2ebf6c086f0f135f97090825c0a8a0a05fd02ffc9199c5faf9dc6cc6d574"
KNOW_PROFILE_SHA="737c5f29c549f75a229ad8c56f3f710155856d2c598f737bd1843586cffdb924"

MODE=""
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from)    MODE=from;    ARG="$2"; shift 2 ;;
    --tarball) MODE=tarball; ARG="$2"; shift 2 ;;
    --url)     MODE=url;     ARG="$2"; shift 2 ;;
    --auto)    MODE=auto;    shift ;;
    --check)   MODE=check;   shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

runtime_ok() {
  [ -x "$RUNTIME/bin/ninfer-serve" ] && [ -f "$RUNTIME/profiles/device-profiles.json" ]
}

# 重新生成载荷清单。
#
# 为什么必须重建而不是沿用源目录那份：源目录（比如别人机器上已经部署好的那一份）
# 里还有 config/、docs/、install-runtime.sh、tune.sh 等本仓库不需要的文件，
# 它的 MANIFEST.sha256 是按**它自己**的全量内容生成的。我们只拷 bin/lib/agent/profiles，
# 拿那份清单去校验必然报一堆「打开或读取失败」。清单要描述的是**拷进来的这份**。
regen_manifest() {
  [ -d "$RUNTIME" ] || return 0
  ( cd "$RUNTIME" && \
    find . -type f ! -name MANIFEST.sha256 ! -name '*.pyc' -print0 \
      | sort -z | xargs -0 sha256sum ) > "$RUNTIME/MANIFEST.sha256" 2>/dev/null || true
  local n; n="$(wc -l < "$RUNTIME/MANIFEST.sha256" 2>/dev/null || echo 0)"
  [ "$n" -gt 0 ] && log "已重建载荷清单 MANIFEST.sha256（$n 个文件）"
}

# 校验载荷完整性（有清单就按清单，没清单就比已知指纹）
verify_runtime() {
  local rc=0
  if [ -f "$RUNTIME/MANIFEST.sha256" ]; then
    if ( cd "$RUNTIME" && sha256sum -c MANIFEST.sha256 --quiet ) 2>/dev/null; then
      ok "MANIFEST.sha256 校验通过"
    else
      warn "MANIFEST.sha256 校验未通过"
      rc=1
    fi
  fi
  if [ -f "$RUNTIME/bin/ninfer-serve" ]; then
    local s; s="$(sha256_of "$RUNTIME/bin/ninfer-serve")"
    if [ "$s" = "$KNOW_NINFER_SERVE_SHA" ]; then
      ok "ninfer-serve 指纹匹配（已验证过的构建）"
    else
      warn "ninfer-serve sha256 = $s"
      warn "  期望              = $KNOW_NINFER_SERVE_SHA"
      warn "  如果不是你自己重新编译的，这个载荷可能不是验证过的版本"
    fi
  else
    warn "缺少 runtime/bin/ninfer-serve"; rc=1
  fi
  if [ -f "$RUNTIME/profiles/device-profiles.json" ]; then
    local p; p="$(sha256_of "$RUNTIME/profiles/device-profiles.json")"
    [ "$p" = "$KNOW_PROFILE_SHA" ] && ok "device-profiles.json 指纹匹配" \
      || warn "device-profiles.json sha256 = $p（期望 $KNOW_PROFILE_SHA）"
  else
    warn "缺少 runtime/profiles/device-profiles.json"; rc=1
  fi
  return $rc
}

extract_tarball() {
  local tb="$1" dest="$2"
  need_cmd tar
  log "解包 $(basename "$tb") → $dest"
  rm -rf "$dest.new"; mkdir -p "$dest.new"
  case "$tb" in
    *.zst) need_cmd zstd "apt install zstd"; tar --use-compress-program=unzstd -xf "$tb" -C "$dest.new" ;;
    *.gz)  tar -xzf "$tb" -C "$dest.new" ;;
    *)     tar -xf  "$tb" -C "$dest.new" ;;
  esac
  # 容忍 tarball 里多一层目录
  local inner
  inner="$(find "$dest.new" -maxdepth 2 -type d -name bin | head -1)"
  if [ -n "$inner" ]; then
    inner="$(dirname "$inner")"
  else
    inner="$dest.new"
  fi
  rm -rf "$dest"
  mv "$inner" "$dest"
  rm -rf "$dest.new"
}

copy_from_dir() {
  local src="$1"
  [ -d "$src" ] || die "目录不存在：$src"
  [ -x "$src/bin/ninfer-serve" ] || die "$src 看起来不是 runtime 目录（缺 bin/ninfer-serve）"
  log "从 $src 复制载荷"
  rm -rf "$RUNTIME"; mkdir -p "$RUNTIME"
  # 只拷载荷必需的部分，避免把日志/模型链接带进来
  for d in bin lib agent profiles; do
    [ -e "$src/$d" ] && cp -a "$src/$d" "$RUNTIME/"
  done
  for f in LICENSE NOTICE; do
    [ -f "$src/$f" ] && cp -a "$src/$f" "$RUNTIME/"
  done
  chmod 755 "$RUNTIME/bin"/* 2>/dev/null || true
  regen_manifest
}

do_auto() {
  local cands=(
    # 以下是**可选**的自动探测候选：找不到也能跑，用户用 --from 指定即可。
    "$HOME/bonsai-ninfer-3060"                                     # verify:allow-outside-path
    "$ROOT/../bonsai2-ninfer-3060-agent-linux.retired/dist/0.1.0/runtime"  # verify:allow-outside-path
    "$HOME/.cache/bonsai2-ninfer-3060-agent-linux/runtime"
  )
  for c in "${cands[@]}"; do
    if [ -x "$c/bin/ninfer-serve" ]; then
      log "在 $c 找到可用载荷"
      copy_from_dir "$c"; return 0
    fi
  done
  return 1
}

do_download() {
  local url="$1"
  local tb="$ROOT/.cache/$RUNTIME_ASSET"
  mkdir -p "$ROOT/.cache"
  if [ -f "$tb" ] && [ -f "$ROOT/.cache/$RUNTIME_ASSET.sha256" ]; then
    local want got; want="$(cat "$ROOT/.cache/$RUNTIME_ASSET.sha256")"
    got="$(sha256_of "$tb")"
    if [ "$got" = "$want" ]; then ok "复用已下载的 $(basename "$tb")"; else rm -f "$tb"; fi
  fi
  [ -f "$tb" ] || download "$url" "$tb"
  local sidecar="$url.sha256"
  if curl -fsL -o "$tb.sha256" "$sidecar" 2>/dev/null; then
    local want; want="$(awk '{print $1}' "$tb.sha256")"
    local got;  got="$(sha256_of "$tb")"
    [ "$want" = "$got" ] || die "载荷 sha256 不符：$got ≠ $want"
    ok "载荷 sha256 校验通过"
    cp -f "$tb.sha256" "$ROOT/.cache/$RUNTIME_ASSET.sha256"
  else
    warn "没有找到 $sidecar，跳过下载校验（解包后会用已知指纹校验）"
  fi
  extract_tarball "$tb" "$RUNTIME"
}

main() {
  if runtime_ok && [ "$MODE" != "check" ]; then
    log "runtime/ 已经就位，校验一下"
    verify_runtime; exit $?
  fi

  case "$MODE" in
    check)   verify_runtime; exit $? ;;
    from)    copy_from_dir "$ARG" ;;
    tarball) extract_tarball "$ARG" "$RUNTIME" ;;
    url)     do_download "$ARG" ;;
    auto)    do_auto || die "没找到本地载荷，请用 --from / --url / 直接不带参数从 Release 下载" ;;
    "")
      if [ "$REPO_OWNER" = "OWNER" ]; then
        warn "config/release.env 里的 REPO_OWNER 还是占位符 OWNER"
        if do_auto; then
          log "已改用本机已有的载荷"
        else
          die "请先把 config/release.env 的 REPO_OWNER 改成你的 GitHub 用户名，或用 --from / --url 指定载荷"
        fi
      else
        do_download "$RELEASE_BASE/$RUNTIME_ASSET"
      fi
      ;;
  esac

  runtime_ok || die "载荷不完整（缺 bin/ninfer-serve 或 profiles/device-profiles.json）"
  verify_runtime || warn "载荷校验有告警（见上），但必要文件都在，仍可继续"
  ok "引擎载荷就位：$RUNTIME"
}

main
