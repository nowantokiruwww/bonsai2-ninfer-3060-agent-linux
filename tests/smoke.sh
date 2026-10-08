#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tests/smoke.sh —— 端到端冒烟测试（会真的起引擎、真的发一个请求）
#
#   ./tests/smoke.sh                 # 起 → 请求 → 校验 → 停
#   ./tests/smoke.sh --keep-running  # 测完不关引擎
#
# 会占 12 GB 显存里的一大半，跑的时候别同时干别的重活。
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../scripts/lib.sh
. "$ROOT/scripts/lib.sh"

KEEP=0
[ "${1:-}" = "--keep-running" ] && KEEP=1

FAIL=0
step() { echo; printf '%s──── %s%s\n' "$C_B" "$*" "$C_0"; }
chk()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$d"; FAIL=$((FAIL+1)); fi; }

echo "================================================================"
echo " 冒烟测试 —— $ROOT"
echo "================================================================"

step "1. 载荷与模型"
chk "runtime/bin/ninfer-serve 存在" test -x "$ROOT/runtime/bin/ninfer-serve"
chk "标定 profile 存在"             test -f "$ROOT/runtime/profiles/device-profiles.json"
chk "模型文件存在"                   test -f "$ROOT/models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer"
if [ "$FAIL" != "0" ]; then
  die "先跑 ./install.sh 把载荷和模型装好"
fi

step "2. 确保引擎处于停止状态"
bash "$ROOT/app/launcher.sh" stop >/dev/null 2>&1 || true
sleep 2
chk "已停止" bash -c "! bash '$ROOT/app/launcher.sh' status --json | grep -q '\"running\":true'"

step "3. 启动（第一次要 30–40 秒加载 7.99 GiB 权重）"
if bash "$ROOT/app/launcher.sh" start --preset balanced; then
  ok "启动成功"
else
  printf '%s[FAIL]%s 启动失败 —— 看 logs/service.log\n' "$C_R" "$C_0"
  tail -30 "$ROOT/logs/service.log" 2>/dev/null | sed 's/^/    /'
  exit 1
fi

step "4. 端点"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:8098/v1/models || echo 000)"
chk "/v1/models 返回 200（拿到 $CODE）" test "$CODE" = "200"

step "4b. 地址信息（网页控制台靠这几个字段显示完整 API 地址）"
SJ="$(bash "$ROOT/app/launcher.sh" status --json 2>/dev/null || echo '{}')"
chk "status --json 含 api_base"    bash -c "printf '%s' '$SJ' | grep -q '\"api_base\"'"
chk "status --json 含 urls"        bash -c "printf '%s' '$SJ' | grep -q '\"urls\"'"
chk "status --json 含 lan_exposed" bash -c "printf '%s' '$SJ' | grep -q '\"lan_exposed\"'"
chk "默认只绑本机（lan_exposed=false）" \
    bash -c "printf '%s' '$SJ' | grep -q '\"lan_exposed\":false'"
chk "局域网地址能算出来（urls_for_bind 0.0.0.0）" \
    bash -c "test \"\$(bash '$ROOT/app/launcher.sh' urls 0.0.0.0 8098 | wc -l)\" -ge 1"
chk "只绑 127.0.0.1 时不该出现局域网地址" \
    bash -c "test \"\$(bash '$ROOT/app/launcher.sh' urls 127.0.0.1 8098 | wc -l)\" -eq 1"
chk "BONSAI_LAN_EXPOSED=1 能推翻 bind 地址判断" \
    bash -c "BONSAI_LAN_EXPOSED=1 bash -c '. \"$ROOT/app/env.sh\"; is_lan_exposed 127.0.0.1'"
chk "BONSAI_LAN_EXPOSED=0 能推翻 bind 地址判断" \
    bash -c "! BONSAI_LAN_EXPOSED=0 bash -c '. \"$ROOT/app/env.sh\"; is_lan_exposed 0.0.0.0'"

step "5. 发一个真实请求"
BODY='{"model":"bonsai2-27b","messages":[{"role":"user","content":"用一句话说明什么是三元量化。"}],"max_tokens":2048,"stream":false}'
RESP="$(curl -s -m 300 -H 'Content-Type: application/json' -d "$BODY" \
        http://127.0.0.1:8098/v1/chat/completions || echo '')"
if printf '%s' "$RESP" | grep -q '"choices"'; then
  ok "收到 chat/completions 响应"
  LEN="$(printf '%s' "$RESP" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); c=d["choices"][0]; m=c.get("message",{}); print(len((m.get("content") or "") + (m.get("reasoning_content") or "")), c.get("finish_reason"))' \
        2>/dev/null || echo "? ?")"
  ok "  正文长度 / finish_reason = $LEN"
else
  printf '%s[FAIL]%s 响应异常：\n' "$C_R" "$C_0"
  printf '%s\n' "$RESP" | head -20 | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

step "6. 遥测"
if [ -f "$ROOT/logs/request.jsonl" ]; then
  N="$(wc -l < "$ROOT/logs/request.jsonl")"
  ok "logs/request.jsonl 有 $N 条事件"
  chk "  含 request_done" grep -q '"request_done"' "$ROOT/logs/request.jsonl"
else
  printf '%s[FAIL]%s 没有 logs/request.jsonl\n' "$C_R" "$C_0"; FAIL=$((FAIL+1))
fi

step "7. 收尾"
if [ "$KEEP" = "1" ]; then
  warn "按要求保留引擎运行中"
else
  bash "$ROOT/app/launcher.sh" stop >/dev/null 2>&1 && ok "已停止" || warn "停止时有告警"
fi

echo
echo "================================================================"
if [ "$FAIL" = "0" ]; then
  printf '%s结论：PASS —— 端到端全通%s\n' "$C_G" "$C_0"; exit 0
else
  printf '%s结论：FAIL —— %d 项失败%s\n' "$C_R" "$FAIL" "$C_0"; exit 1
fi
