#!/usr/bin/env bash
# scripts/55-flag-diff.sh — Phase 5 步骤 3：CLI 口径对账（Linux 口径 vs Windows 口径）
#
# 为什么必须做：bench 的 Windows 命令里有一批 flag（`--max-concurrency 1`、
# `--lm-head-draft`、`--kv-dtype int8`…），而不同 fork 的 CLI 集合不同 ——
# 旧移植就栽在这上面（`--host-state-slots`/`--host-kv-mib`/`--log-level` 在某套 kit 里
# 根本不存在；`--spec dflash2` 只在部分线存在）。
#
# 本脚本把实际二进制的 --help 落盘，并逐条说明 bench 命令里的 flag 是否被接受、
# 不被接受时的等价替换。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "55-flag-diff"
EV="$PROJ/evidence/serve"; mkdir -p "$EV"

[ -x "$NINFER_SERVE" ] || { echo "[fail] 未找到 $NINFER_SERVE（先跑 scripts/50-build.sh）" >&2; exit 1; }

HELP="$EV/serve-help.txt"
run bash -c "'$NINFER_SERVE' --help > '$HELP' 2>&1 || true"
[ -s "$HELP" ] || { echo "[warn] --help 无输出，可能该版本不支持 --help；改用 strings 兜底" >&2
  run bash -c "strings '$NINFER_SERVE' | grep -oE '^--[a-z0-9-]+$' | sort -u > '$HELP'"; }

# 抽出二进制实际接受的 flag 集合（help 文本 + strings 兜底）
ACCEPTED="$EV/serve-flags-accepted.txt"
{
  grep -oE -- '--[a-z0-9][a-z0-9-]*' "$HELP" 2>/dev/null || true
  strings "$NINFER_SERVE" 2>/dev/null | grep -oE -- '^--[a-z0-9][a-z0-9-]*$' || true
} | sort -u > "$ACCEPTED"

# bench 的 Windows 3060 命令用到的 flag
BENCH_FLAGS="host port model-id max-context kv-capacity kv-dtype max-concurrency no-thinking greedy spec draft-tokens lm-head-draft"
# 本项目关心 / bench 变体实验里出现过的其它 flag
EXTRA_FLAGS="lookup-ngram device-profile device-profile-path prefill-cublas mlp-a8-decode mtp-experts-q4 gdn-state-fp16 vision reasoning-effort thinking-budget preserve-thinking kv-capacity"

OUT="$EV/flag-diff.md"
{
  echo "# CLI 口径对账（Linux 口径 vs bench 的 Windows 口径）"
  echo
  echo "- 二进制：\`$NINFER_SERVE\`"
  echo "- sha256：\`$(sha256sum "$NINFER_SERVE" | awk '{print $1}')\`"
  echo "- 生成时间：$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "- 完整 --help：\`evidence/serve/serve-help.txt\`"
  echo "- 实际接受的 flag 集合：\`evidence/serve/serve-flags-accepted.txt\`（$(wc -l < "$ACCEPTED") 个）"
  echo
  echo "## bench 的 Windows 3060 命令逐条对账"
  echo
  echo "| flag | 本二进制是否接受 | 说明 |"
  echo "|---|---|---|"
} > "$OUT"

check() {
  local f="$1"
  if grep -qx -- "--$f" "$ACCEPTED"; then
    printf '| `--%s` | ✅ | |\n' "$f" >> "$OUT"
    return 0
  else
    printf '| `--%s` | ❌ | |\n' "$f" >> "$OUT"
    return 1
  fi
}

MISSING=""
for f in $BENCH_FLAGS; do check "$f" || MISSING="$MISSING $f"; done

{
  echo
  echo "## 本项目关心 / bench 变体实验出现过的 flag"
  echo
  echo "| flag | 是否接受 |"
  echo "|---|---|"
} >> "$OUT"
for f in $(echo "$EXTRA_FLAGS" | tr ' ' '\n' | sort -u); do
  if grep -qx -- "--$f" "$ACCEPTED"; then printf '| `--%s` | ✅ |\n' "$f" >> "$OUT"
  else printf '| `--%s` | ❌ |\n' "$f" >> "$OUT"; fi
done

{
  echo
  echo "## 结论"
  echo
  if [ -z "$MISSING" ]; then
    echo "bench 的 Windows 3060 命令里的 flag **全部被本二进制接受**，命令可逐字沿用"
    echo "（仅需把 \`.exe\`、Windows 续行符 \`^\`、以及显式容量以外的部分换掉）。"
  else
    echo "以下 flag **不被本二进制接受**，必须换等价方式："
    echo
    for m in $MISSING; do echo "- \`--$m\`"; done
    echo
    echo "处置：在 \`METHODOLOGY.md\` 与 \`PORTING-LEDGER.md\` 中登记为"Linux 口径差异"，"
    echo "并用 \`--help\` 里的等价 flag 或环境变量替换。"
  fi
} >> "$OUT"

cat "$OUT"
note "flag 对账 -> $OUT（缺失:${MISSING:-无}）"
log_finish 0
