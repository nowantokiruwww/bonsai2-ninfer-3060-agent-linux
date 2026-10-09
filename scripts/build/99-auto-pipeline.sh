#!/usr/bin/env bash
# scripts/99-auto-pipeline.sh — 构建结束后自动跑完整条验收链（无人值守，逐步记录状态）
#
# 为什么要有这个：编译的长尾有 1.5–2 小时，GPU 阶段又要 1–2 小时。
# 把"构建结束 → 产物门禁/体检 → 动态 flag 对账 → 28-SM 标定 → KV 门禁
#   → 起服务 → agent 验收 → 隔离证明 → MANIFEST"串成一条链，
# 每一步的成败都写进一个状态文件，失败不阻断后续（便于一次性拿到全部证据）。
#
# 用法：nohup bash scripts/99-auto-pipeline.sh > /tmp/auto-pipeline.log 2>&1 &
# 状态：logs/AUTO-PIPELINE-STATUS.txt（每行 `<步骤> <PASS|FAIL> <秒>`）

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/.." && pwd)"
cd "$PROJ"
ST="$PROJ/logs/AUTO-PIPELINE-STATUS.txt"
mkdir -p "$PROJ/logs"
: > "$ST"
step() { # step <name> <seconds> <rc>
  printf '%-22s %-4s %ss  %s\n' "$1" "$([ "$3" = 0 ] && echo PASS || echo FAIL)" "$2" "$(date '+%H:%M:%S')" >> "$ST"
}
say() { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$ST"; }

say "pipeline start; waiting for build to finish"
# 等编译结束（最多 3 小时）
for _ in $(seq 1 360); do
  pgrep -f '50-buil[d]' >/dev/null || break
  sleep 30
done
if pgrep -f '50-buil[d]' >/dev/null; then say "ABORT: build still running after 3h"; exit 1; fi
say "build finished"

run_step() { # run_step <name> <cmd...>
  local name="$1"; shift
  local t0=$SECONDS rc=0
  say "== $name =="
  "$@" >> "$PROJ/logs/pipeline-$name.log" 2>&1 || rc=$?
  step "$name" "$((SECONDS-t0))" "$rc"
}

# 1) 产物门禁 + 体检（50-build.sh 会重跑 configure/build；此时应为 no-op，然后做门禁与体检）
run_step "build-gate" env NINFER_JOBS=3 bash "$HERE/50-build.sh"
run_step "flag-diff" bash "$HERE/55-flag-diff.sh"

# 2) 28-SM 标定
run_step "calibrate" bash "$HERE/70-calibrate.sh"

# 3) KV 可行性门禁（带桌面态）
run_step "kv-gate-desktop" env NINFER_STATE=desktop bash "$HERE/75-kv-gate.sh"

# 4) 起服务（KV 由门禁结果自动选取）
say "== serve =="
if bash "$HERE/80-serve.sh" >> "$PROJ/logs/pipeline-serve.log" 2>&1; then
  step "serve" 0 0
  # 5) agent 验收三模式（服务已在跑）
  run_step "agent-loop"      bash "$HERE/90-agent-accept.sh" loop
  run_step "agent-context"   bash "$HERE/90-agent-accept.sh" context
  run_step "agent-stability" bash "$HERE/90-agent-accept.sh" stability
  # 6) 停服务，腾显存给 correctness（它自己起两个服务）
  say "stopping served instance before correctness"
  if [ -f "$PROJ/logs/serve.pid" ]; then
    kill -INT "$(cat "$PROJ/logs/serve.pid")" 2>/dev/null || true
    sleep 20
    kill -9 "$(cat "$PROJ/logs/serve.pid")" 2>/dev/null || true
    sleep 5
  fi
  run_step "agent-correctness" bash "$HERE/90-agent-accept.sh" correctness
else
  step "serve" 0 1
  say "serve failed; skipping agent acceptance"
fi

# 7) 隔离证明与清单（与 GPU 无关，最后跑以便纳入最新产物）
run_step "isolation-proof" bash "$HERE/85-isolation-proof.sh"
run_step "manifest"        bash "$HERE/95-manifest.sh"

say "pipeline done"
