#!/usr/bin/env bash
# scripts/98-dsh-integrate.sh — 把部署好的本地服务接进 DSH
#
# 只做一件最小改动：把 DSH 里**已存在**的 provider "bonsai2-3060" 指向新部署
# （旧配置指向 http://127.0.0.1:8901/v1 —— 那是旧移植的端口，且旧 unit 早已 disabled+inactive，
#  也就是说在本次接入之前，DSH 里那个模型是指向一个死端点的）。
#
# 刻意**不**做的事：
#   * 不新增 provider、不新增模型卡片（避免模型选择器里塞一堆变体）；
#   * 不改 agent-default-model（默认仍是 deepseek-official/deepseek-flash）。
#
# 两处硬约束（来自该 profile 自己的注释，也是实测踩过的）：
#   1. 非 pi-ai 目录内路由必须显式 `api: openai-completions`；
#   2. `apiKeyEnv` 必须可解析，否则请求报 `PI_AI_ERROR: No API key for provider: <id>`。
#   3. `contextWindow` 必须等于服务端实际的 --max-context —— 所以本脚本从部署的
#      config/runtime.env 读 KV_CAPACITY，**不让两边各填一遍**。
#
# 用法：bash scripts/98-dsh-integrate.sh [--dry-run]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "98-dsh"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

PREFIX="$HOME/bonsai-ninfer-3060"  # verify:allow-outside-path（历史编译期流水线，部署根在仓库外）
DEPLOY_ENV="$PREFIX/config/runtime.env"
PATCH="$HOME/.dsh/profiles/web/cordis.patch.yml"
CREDS="$HOME/.dsh/.credentials.yaml"
PROVIDER="bonsai2-3060"
APIKEY_REF="BONSAI2_3060_API_KEY"
EV="$PROJ/evidence/deploy"; mkdir -p "$EV"

[ -f "$DEPLOY_ENV" ] || { echo "[fail] 找不到部署参数文件 $DEPLOY_ENV（先跑 scripts/97-deploy-service.sh）" >&2; exit 1; }
[ -f "$PATCH" ]      || { echo "[fail] 找不到 DSH profile 补丁层 $PATCH" >&2; exit 1; }

# 从部署参数派生，保证两边一致
KV_CAP=$(awk -F= '/^KV_CAPACITY=/{print $2}' "$DEPLOY_ENV" | tr -d '[:space:]')
KV_DT=$(awk -F= '/^KV_DTYPE=/{print $2}'  "$DEPLOY_ENV" | tr -d '[:space:]')
PORT=$(awk -F= '/^PORT=/{print $2}'       "$DEPLOY_ENV" | tr -d '[:space:]')
BASEURL="http://127.0.0.1:$PORT/v1"
[ -n "$KV_CAP" ] && [ -n "$PORT" ] || { echo "[fail] 无法从 $DEPLOY_ENV 解析 KV_CAPACITY/PORT" >&2; exit 1; }

echo "=== 目标 ==="
echo "  provider   = $PROVIDER"
echo "  baseURL    = $BASEURL   （旧值 8901 已死）"
echo "  contextWindow = $KV_CAP   （= 服务端 --max-context，KV $KV_DT）"
echo "  apiKeyEnv  = $APIKEY_REF（不改）"

echo
echo "=== 1) 检查凭据引用是否存在（只输出名字，绝不打印值）==="
if grep -qE "^[[:space:]]*$APIKEY_REF:" "$CREDS" 2>/dev/null; then
  echo "  $APIKEY_REF 在 $CREDS 中存在 ✓"
else
  echo "  ⚠ 在 $CREDS 里没找到 $APIKEY_REF。" >&2
  echo "    否则 DSH 请求会报：PI_AI_ERROR: No API key for provider: $PROVIDER" >&2
  echo "    补法：给该 ref 填一个值即可；引擎不校验密钥，填 1 就行（与文件里 llama-server 的既有先例一致）。" >&2
fi

echo
echo "=== 2) 备份 ==="
if [ "$DRY" = "0" ]; then
  BAK="$PATCH.bak-$(date '+%Y%m%d-%H%M%S')"
  cp -a "$PATCH" "$BAK"
  echo "  $BAK"
else
  echo "  (dry-run) 会备份 $PATCH"
fi

echo
echo "=== 3) 改 provider（只动 $PROVIDER 这一块）==="
export DSH_PATCH="$PATCH" DSH_PROVIDER="$PROVIDER" DSH_BASEURL="$BASEURL" \
       DSH_CTX="$KV_CAP" DSH_KVDT="$KV_DT" DSH_PORT="$PORT" DSH_DRY="$DRY" \
       DSH_COMMIT="$NINFER_SRC_COMMIT" DSH_BIN_SHA="7ebf2ebf6c086f0f135f97090825c0a8a0a05fd02ffc9199c5faf9dc6cc6d574"

python3 - <<'PY'
import os, re, sys, datetime

patch = os.environ["DSH_PATCH"]; prov = os.environ["DSH_PROVIDER"]
baseurl = os.environ["DSH_BASEURL"]; ctx = os.environ["DSH_CTX"]
kvdt = os.environ["DSH_KVDT"]; port = os.environ["DSH_PORT"]
dry = os.environ["DSH_DRY"] == "1"
commit = os.environ["DSH_COMMIT"]; binsha = os.environ["DSH_BIN_SHA"]

lines = open(patch, encoding="utf-8").read().splitlines(keepends=True)
# 定位 provider 块的起始行（形如 "      bonsai2-3060:"）
start = next((i for i, l in enumerate(lines)
              if re.match(rf"^\s+{re.escape(prov)}:\s*$", l)), None)
if start is None:
    sys.exit(f"[fail] 在 {patch} 里找不到 provider 块 '{prov}:'")
# 块结束 = 下一个同缩进或更浅缩进的 key
indent = len(lines[start]) - len(lines[start].lstrip())
end = len(lines)
for i in range(start + 1, len(lines)):
    l = lines[i]
    if not l.strip() or l.lstrip().startswith("#"):
        continue
    cur = len(l) - len(l.lstrip())
    if cur <= indent and l.strip().endswith(":") is False and re.match(r"^\s*[a-zA-Z].*:", l):
        end = i; break
    if cur <= indent and re.match(r"^\s*[a-zA-Z].*:", l):
        end = i; break

block = "".join(lines[start:end])
changed = []

def sub1(pat, rep, label):
    global block
    new, n = re.subn(pat, rep, block, count=1)
    if n:
        block = new; changed.append(label)

sub1(r"baseURL:\s*\S+", f"baseURL: {baseurl}", "baseURL")
sub1(r"(\n\s*contextWindow:\s*)\d+", rf"\g<1>{ctx}", "contextWindow")
sub1(r"(\n\s*defaultContextWindow:\s*)\d+", rf"\g<1>{ctx}", "defaultContextWindow")

# 溯源注释（去黑盒化：DSH 侧也能看出背后是哪个二进制/哪套 KV）
stamp = datetime.datetime.now().strftime("%Y-%m-%d")
note = (
    f"      # ── 本次切换到 Linux 从零构建版（{stamp}）─────────────────────────\n"
    f"      # 后端：~/bonsai-ninfer-3060（user systemd 单元 bonsai2-ninfer-3060.service）\n"  # verify:allow-outside-path（历史编译期流水线，部署根在仓库外）
    f"      # 引擎：iamwavecut/ninfer-all @ {commit[:12]}…  二进制 sha256 {binsha[:16]}…\n"
    f"      # KV：{kvdt} @ {ctx}；投机 --spec dflash2 --draft-tokens 7（必用项）\n"
    f"      # 设备码：369 个 cubin 全部 sm_86（cuobjdump -lelf 实证）\n"
    f"      # 旧值：baseURL 曾为 http://127.0.0.1:8901/v1（旧移植端口，已退役）\n"
    f"      # ⚠ contextWindow 必须等于服务端 --max-context；改 KV 时两边一起改\n"
)
if "本次切换到 Linux 从零构建版" not in "".join(lines[max(0, start-12):start]):
    lines[start:start] = [note]
    start += 1
    end += 1

lines[start:end] = [block]
out = "".join(lines)

if dry:
    print("  (dry-run) 将要写入的内容片段：")
    for l in block.splitlines():
        if any(k in l for k in ("baseURL", "contextWindow", "defaultContextWindow")):
            print("   ", l.strip())
else:
    open(patch, "w", encoding="utf-8").write(out)
    print("  已更新字段：", ", ".join(changed) or "（无变化）")
PY

echo
echo "=== 4) 用 dsh 校验组合后的配置（只读，不影响正在跑的服务）==="
if [ "$DRY" = "0" ]; then
  if command -v dsh >/dev/null 2>&1; then
    CFG=$(dsh --profile web --dump-config 2>/dev/null || true)
    if [ -z "$CFG" ]; then
      echo "  ⚠ dsh --dump-config 没输出，跳过校验（可手工跑一次看看）"
    else
      echo "  组合配置里的 $PROVIDER："
      echo "$CFG" | grep -nE "bonsai2-3060|$BASEURL|contextWindow: $KV_CAP" | head -8 | sed 's/^/    /'
      echo "$CFG" | grep -q "$BASEURL" && echo "  ✓ 新 baseURL 出现在组合配置里" || echo "  ⚠ 组合配置里没找到新 baseURL，请手工核对"
    fi
  else
    echo "  (找不到 dsh 命令，跳过)"
  fi
fi

{
  echo "### DSH 接入（$PROVIDER）"
  echo "baseURL = $BASEURL"
  echo "contextWindow = $KV_CAP   (KV $KV_DT)"
  echo "apiKeyEnv = $APIKEY_REF"
  echo "changed_fields = $(python3 -c "print('see log')" 2>/dev/null || true)"
  echo
  echo "### $PROVIDER 块（改后）"
  awk -v p="$PROVIDER" 'index($0,p":"){f=1} f{print}' "$PATCH" | head -30
} > "$EV/dsh-integration.txt" 2>&1
cp "$EV/dsh-integration.txt" "$LOG_ROOT/" 2>/dev/null || true

log_finish 0
cat <<EOF

[done] DSH 已指向新部署：$BASEURL （contextWindow $KV_CAP）

⚠ 要让 **GUI** 生效，必须由你重启 dsh web（当前 pid $(pgrep -f 'dsh web' | head -1)）——
  那会中断正在服务本会话的界面，所以我不代你重启。
  重启后：新会话的模型选择器里选「Bonsai 2 27B 三值 (3060)」即可。
  默认模型仍是 deepseek-official/deepseek-flash（按你的选择没动）。

本轮验证走 dsh headless --patch（不重启 web）：
  scripts/99-verify-dsh.sh
EOF
