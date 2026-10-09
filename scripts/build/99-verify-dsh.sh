#!/usr/bin/env bash
# scripts/99-verify-dsh.sh — 端到端验证：让**真的 DSH agent** 走一遍本地服务
#
# 为什么不能只验 /v1/models：那只证明端口活着，不证明 agent 路径（工具调用、流式、多轮）
# 走得通。所以这里跑一次 `dsh headless`，并要求**服务端日志出现对应请求**——双向对账。
#
# 为什么用 headless + --patch 而不是直接改 web profile：web 正在服务当前会话，
# 重启它会打断对话。headless 是独立进程，且它自己的 patch 层是 `[]`，
# 用 --patch 注入一个临时 overlay 即可，**不碰用户 profile**。
#
# 用法：bash scripts/99-verify-dsh.sh ["自定义任务"]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "99-verify-dsh"

PREFIX="$HOME/bonsai-ninfer-3060"  # verify:allow-outside-path（历史编译期流水线，部署根在仓库外）
DEPLOY_ENV="$PREFIX/config/runtime.env"
OVERLAY="$PREFIX/dsh-verify-overlay.yml"
LOG="$PREFIX/logs/service.log"
EV="$PROJ/evidence/deploy"; mkdir -p "$EV"

TASK="${1:-Use the shell tool to run exactly: echo bonsai-ninfer-ok   — then reply with the command output and nothing else.}"

[ -f "$DEPLOY_ENV" ] || { echo "[fail] 缺 $DEPLOY_ENV（先跑 scripts/97-deploy-service.sh）" >&2; exit 1; }

PORT=$(awk -F= '/^PORT=/{print $2}' "$DEPLOY_ENV" | tr -d '[:space:]')
KV_CAP=$(awk -F= '/^KV_CAPACITY=/{print $2}' "$DEPLOY_ENV" | tr -d '[:space:]')
MODEL_ID=$(awk -F= '/^MODEL_ID=/{print $2}' "$DEPLOY_ENV" | tr -d '[:space:]')
SPEC=$(awk -F= '/^SPEC_FLAGS=/{print $2}' "$DEPLOY_ENV" | tr -d '"')
DRAFT=$(echo "$SPEC" | grep -oE 'draft-tokens [0-9]+' | awk '{print $2}')
DRAFT="${DRAFT:-7}"

echo "=== 服务健康检查 ==="
curl -s "http://127.0.0.1:$PORT/v1/models" >/dev/null \
  || { echo "[fail] 8098 不可达，先确认 systemctl --user status bonsai2-ninfer-3060" >&2; exit 1; }
echo "  http://127.0.0.1:$PORT/v1 活着 ✓"

echo
echo "=== 生成 headless 用的临时 overlay（不碰用户 profile）==="
cat > "$OVERLAY" <<EOF
# 由 scripts/99-verify-dsh.sh 生成 —— 只用于 dsh headless 的端到端验证。
# 它注入两件事：① 本地 provider；② 把默认模型临时指到它。
# 正式生效的那份在 ~/.dsh/profiles/web/cordis.patch.yml（由 scripts/98-dsh-integrate.sh 维护）。
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      bonsai2-3060:
        displayName: 3060 Bonsai 2 27B (dflash2-$DRAFT)
        baseURL: http://127.0.0.1:$PORT/v1
        api: openai-completions
        models:
          - id: $MODEL_ID
            name: Bonsai 2 27B 三值 (3060)
            contextWindow: $KV_CAP
            maxTokens: 8192
            input:
              - text
            reasoningEfforts: false
        defaultInput:
          - text
        defaultContextWindow: $KV_CAP
        defaultMaxTokens: 8192
        timeoutMs: 300000
        streamIdleTimeoutMs: 300000
        apiKeyEnv: BONSAI2_3060_API_KEY
- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: bonsai2-3060
    model: $MODEL_ID
EOF
echo "  $OVERLAY"
echo "  校验 overlay 能被 dsh 组合进去："
dsh --profile headless --patch "$OVERLAY" --dump-config 2>&1 | grep -cE "127.0.0.1:$PORT" | xargs -I{} echo "    组合配置里出现新 baseURL {} 次"

echo
echo "=== 跑一次真的 agent 任务（headless）==="
BEFORE=$(wc -l < "$LOG" 2>/dev/null || echo 0)
echo "  服务日志基线行数 = $BEFORE"
echo "  任务: $TASK"
set +e
OUT=$(timeout 420 dsh --profile headless --patch "$OVERLAY" "$TASK" 2>&1)
RC=$?
set -e
echo "  dsh 退出码 = $RC"
echo "$OUT" | tail -25 | sed 's/^/    /'

echo
echo "=== 双向对账：服务端是否真的收到了这次请求 ==="
AFTER=$(wc -l < "$LOG" 2>/dev/null || echo 0)
NEWLINES=$((AFTER - BEFORE))
echo "  服务日志新增 $NEWLINES 行"
REQ=$(tail -n +$((BEFORE + 1)) "$LOG" 2>/dev/null | grep -cE 'openai-chat|req#[0-9]+' || true)
TOOL=$(tail -n +$((BEFORE + 1)) "$LOG" 2>/dev/null | grep -cE 'tool calls|tools [0-9]+' || true)
echo "  其中请求行 $REQ 条，含工具调用痕迹 $TOOL 条"
echo "  —— 新增日志里与请求相关的行 ——"
tail -n +$((BEFORE + 1)) "$LOG" 2>/dev/null | grep -E 'openai-chat|req#[0-9]+|decode|accepted|tools' | tail -12 | sed 's/^/    /'

VERDICT=FAIL
if [ "$RC" = "0" ] && [ "$REQ" -gt 0 ]; then
  VERDICT=PASS
fi
echo
echo "  判定：$VERDICT （要求：dsh 退出码 0 且服务端出现对应请求）"

{
  echo "### DSH 端到端验证 $(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "task      = $TASK"
  echo "overlay   = $OVERLAY"
  echo "baseURL   = http://127.0.0.1:$PORT/v1"
  echo "model     = $MODEL_ID   (contextWindow $KV_CAP)"
  echo "dsh_rc    = $RC"
  echo "log_delta = $NEWLINES 行（请求行 $REQ，工具痕迹 $TOOL）"
  echo "verdict   = $VERDICT"
  echo
  echo "### dsh 输出"
  echo "$OUT" | tail -30
  echo
  echo "### 服务端新增日志"
  tail -n +$((BEFORE + 1)) "$LOG" 2>/dev/null | tail -30
} > "$EV/dsh-e2e.txt" 2>&1
cp "$EV/dsh-e2e.txt" "$LOG_ROOT/" 2>/dev/null || true

log_finish 0
[ "$VERDICT" = "PASS" ] || { echo "[fail] 端到端验证未通过" >&2; exit 1; }
echo "[done] 端到端 PASS —— 证据 $EV/dsh-e2e.txt"
