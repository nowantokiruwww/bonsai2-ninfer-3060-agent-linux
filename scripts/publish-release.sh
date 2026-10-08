#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/publish-release.sh —— 把 dist/ 里的 Release 附件传到 GitHub
#
#   export GITHUB_TOKEN=ghp_xxxxxxxx        # 见下面"怎么拿 token"
#   ./scripts/publish-release.sh            # 建 Release（若不存在）+ 传附件
#   ./scripts/publish-release.sh --dry-run  # 只看会传什么，不联网
#   ./scripts/publish-release.sh --notes-file RELEASE-NOTES.md
#
# 为什么不用浏览器拖：载荷是 2.06 GiB、分成两卷，浏览器上传说断就断、断了要重来。
# 这个脚本按卷上传，已经传上去的卷会跳过 —— 重跑一次就接着传。
#
# 怎么拿 token（GitHub 从 2021 年起不接受账号密码）：
#   1. 打开 https://github.com/settings/tokens  →  Generate new token (classic)
#   2. Note 随便写，Expiration 选 30 days
#   3. 勾上 **repo** 这一个 scope（整块打勾）就够了
#   4. Generate token → 复制那串 ghp_... （**只显示这一次**，关掉页面就再也看不到）
#   5. export GITHUB_TOKEN=ghp_...
#
# token 只在本进程用，脚本不会把它写到任何文件里。
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=../config/release.env
. "$ROOT/config/release.env"

DRY=0
NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY=1; shift ;;
    --notes-file) NOTES="$2"; shift 2 ;;
    -h|--help)    sed -n '2,24p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
UPLOAD="https://uploads.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
TAG="v${REPO_VERSION}"
OUTDIR="$ROOT/dist"
ASSET="$OUTDIR/${RUNTIME_ASSET}"

# ---- 收集要传的文件 --------------------------------------------------------
FILES=("$ASSET.sha256")
PARTS="${RUNTIME_ASSET_PARTS:-1}"
if [ "$PARTS" -gt 1 ]; then
  for i in $(seq 1 "$PARTS"); do
    FILES+=("$ASSET.part$i" "$ASSET.part$i.sha256")
  done
else
  FILES=("$ASSET" "$ASSET.sha256")
fi

echo "版本     : $TAG"
echo "仓库     : ${REPO_OWNER}/${REPO_NAME}"
echo "要传的附件："
MISSING=0
for f in "${FILES[@]}"; do
  if [ -f "$f" ]; then
    echo "    $(human_size "$(stat -c %s "$f")")  $(basename "$f")"
  else
    echo "    **缺失**  $f"
    MISSING=1
  fi
done
[ "$MISSING" -eq 0 ] || die "有附件还没生成，先跑 ./scripts/make-release.sh"
# 硬拦：单文件必须小于 2 GiB，否则 GitHub 会拒
for f in "${FILES[@]}"; do
  sz="$(stat -c %s "$f")"
  [ "$sz" -lt 2147483648 ] || die "$(basename "$f") 是 $(human_size "$sz")，超过 Release 附件 2 GiB 上限 —— 调大 config/release.env 的 RUNTIME_ASSET_PARTS 后重跑 make-release.sh"
done

if [ "$DRY" -eq 1 ]; then
  echo
  echo "（--dry-run，没有联网）"
  exit 0
fi

# ---- 前置检查 --------------------------------------------------------------
need_cmd curl
command -v python3 >/dev/null 2>&1 || die "需要 python3（用来解析 GitHub 返回的 JSON）"
[ -n "${GITHUB_TOKEN:-}" ] || die "没有 GITHUB_TOKEN。先 export GITHUB_TOKEN=ghp_...（见 ./scripts/publish-release.sh -h）"

case "$GITHUB_TOKEN" in
  ghp_*|github_pat_*) : ;;
  *) warn "GITHUB_TOKEN 不像 classic PAT（通常以 ghp_ 开头），继续尝试" ;;
esac

AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}"
      -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28")

# 代理解释：浏览器读 GNOME 的代理设置，git/curl 不读 —— 所以能开 GitHub 不代表 curl 能通。
if [ -z "${https_proxy:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${all_proxy:-}" ]; then
  warn "没有设 https_proxy。如果你的机器要靠代理才能访问 github.com，先："
  warn "    export https_proxy=http://127.0.0.1:7890     # 换成你自己的代理端口"
fi

# ---- 取当前用户（顺便验证 token 有效）-------------------------------------
who="$(curl -fsSL "${AUTH[@]}" https://api.github.com/user 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("login",""))' 2>/dev/null)"
[ -n "$who" ] || die "token 无效，或者网络不通（能开网页 ≠ curl 能通，见上面的代理提示）"
ok "token 有效，登录身份：$who"

# ---- 找 Release，没有就建 --------------------------------------------------
get_release_id() {
  curl -fsSL "${AUTH[@]}" "$API/releases/tags/$TAG" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null
}
REL_ID="$(get_release_id)"
if [ -z "$REL_ID" ]; then
  BODY=""
  [ -n "$NOTES" ] && [ -f "$NOTES" ] && BODY="$NOTES"
  log "Release $TAG 不存在，创建它"
  if [ -n "$BODY" ]; then
    payload="$(python3 -c '
import json,sys
notes=open(sys.argv[1],encoding="utf-8").read() if sys.argv[1] else ""
print(json.dumps({"tag_name":sys.argv[2],"name":sys.argv[2],"body":notes,"draft":False,"prerelease":False}))' "$BODY" "$TAG")"
  else
    payload="$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[1],"draft":False,"prerelease":False}))' "$TAG")"
  fi
  REL_ID="$(curl -fsSL -X POST "${AUTH[@]}" -H 'Content-Type: application/json' \
              -d "$payload" "$API/releases" 2>/dev/null \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null)"
  [ -n "$REL_ID" ] || die "创建 Release 失败。手动建一个 tag 为 $TAG 的 Release 再重跑本脚本也行。"
  ok "Release 已创建（id=$REL_ID，tag=$TAG）"
else
  ok "Release 已存在（id=$REL_ID，tag=$TAG）"
fi

# ---- 已经传上去的附件 ------------------------------------------------------
list_assets() {
  curl -fsSL "${AUTH[@]}" "$API/releases/$REL_ID/assets?per_page=100" 2>/dev/null \
    | python3 -c 'import json,sys; [print(a["name"]) for a in json.load(sys.stdin)]' 2>/dev/null
}
HAVE="$(list_assets)"

# ---- 逐个上传 --------------------------------------------------------------
DONE=0; SKIP=0; FAIL=0
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  if printf '%s\n' "$HAVE" | grep -qxF "$name"; then
    ok "已在 Release 里，跳过：$name"
    SKIP=$((SKIP+1)); continue
  fi
  log "上传 $name（$(human_size "$(stat -c %s "$f")")）…"
  if curl -fL --progress-bar -X POST "${AUTH[@]}" \
        -H 'Content-Type: application/octet-stream' \
        --data-binary @"$f" \
        "$UPLOAD/releases/$REL_ID/assets?name=$name"; then
    echo
    ok "上传完成：$name"
    DONE=$((DONE+1))
  else
    echo
    warn "上传失败：$name（重跑本脚本会跳过已成功的，接着传这个）"
    FAIL=$((FAIL+1))
  fi
done

echo
echo "================================================================"
echo "新传 $DONE 个，跳过 $SKIP 个，失败 $FAIL 个"
[ "$FAIL" -eq 0 ] || die "有附件没传上去，重跑一次即可续传"
echo "Release 页面： https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/${TAG}"
echo
echo "自检（任何人都能跑，验证 Release 真能用）："
echo "    curl -sI https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${TAG}/${RUNTIME_ASSET}.part1 | head -1"
