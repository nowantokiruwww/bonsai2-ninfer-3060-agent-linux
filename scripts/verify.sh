#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/verify.sh —— 仓库自检（不需要引擎在跑）
#
# 这个脚本存在的唯一目的：**证明这个仓库是自包含的**。
# 也就是说，别人 git clone 下来之后，README 里写的每一条命令、
# 每一个被引用的路径，都能在仓库内部找到 —— 不存在"只有作者本机才有"的东西。
#
#   ./scripts/verify.sh
#
# 退出码：0 = 全过；1 = 有问题
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

FAIL=0
npass=0
chk() { # chk 描述 命令...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; npass=$((npass+1))
  else printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$desc"; FAIL=$((FAIL+1)); fi
}

echo "================================================================"
echo " 仓库自检 —— $ROOT"
echo "================================================================"
echo

# --- 1. 关键文件存在 -----------------------------------------------------
log "[1/7] 关键文件"
for f in README.md LICENSE NOTICE VERSION \
         app/env.sh app/presets.env app/launcher.sh \
         webui/server.py webui/static/index.html webui/static/app.js webui/static/style.css \
         scripts/lib.sh scripts/fetch-runtime.sh scripts/fetch-model.sh \
         scripts/install-service.sh scripts/verify.sh scripts/make-release.sh \
         config/release.env install.sh \
         start.sh stop.sh restart.sh status.sh logs.sh presets.sh check.sh webui.sh; do
  chk "存在 $f" test -e "$ROOT/$f"
done
echo

# --- 2. shell 语法 -------------------------------------------------------
log "[2/7] shell 语法"
while IFS= read -r s; do
  chk "语法 ${s#"$ROOT"/}" bash -n "$s"
done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' -not -path '*/.cache/*' | sort)
echo

# --- 3. python 语法 ------------------------------------------------------
log "[3/7] python 语法"
while IFS= read -r s; do
  chk "语法 ${s#"$ROOT"/}" python3 -m py_compile "$s"
done < <(find "$ROOT" -name '*.py' -not -path '*/.git/*' -not -path '*/__pycache__/*' | sort)
find "$ROOT" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
echo

# --- 4. 可执行位 ---------------------------------------------------------
log "[4/7] 可执行位"
for f in install.sh start.sh stop.sh restart.sh status.sh logs.sh presets.sh check.sh webui.sh \
         app/launcher.sh scripts/fetch-runtime.sh scripts/fetch-model.sh \
         scripts/install-service.sh scripts/verify.sh scripts/make-release.sh; do
  chk "可执行 $f" test -x "$ROOT/$f"
done
echo

# --- 5. 不允许引用仓库外路径 --------------------------------------------
#
# 这是本项目最重要的一条纪律：clone 的人只拿得到仓库里的东西。
# 所以「可执行面 + 对外入口」里不允许出现作者本机的绝对路径。
#
# 例外：docs/PORTING-LEDGER.md、docs/AGENT-EXPERIENCE.md、docs/LINEAGE.md、
# docs/METHODOLOGY.md、docs/params/*.md 是**历史记录**，它们诚实地写下了当时在
# 哪台机器的哪个路径上测到的什么数字。删掉这些路径等于篡改证据，所以显式豁免。
# 纪律只约束「别人会照着敲」的东西：README、install.sh、app/、scripts/、webui/、
# config/、tests/。
log "[5/7] 仓库外路径引用（核心纪律）"
SELF="$(basename "${BASH_SOURCE[0]}")"
raw="$(grep -rnE '(^|[^A-Za-z0-9_])/(home|Users)/[A-Za-z0-9._-]+|~/bonsai|[$]HOME/bonsai|bonsai2-ninfer-3060-agent-linux[.]retired' \
        "$ROOT" \
        --include='*.sh' --include='*.py' --include='*.md' --include='*.html' --include='*.js' --include='*.env' \
        --exclude-dir=.git --exclude-dir=.cache --exclude-dir=logs --exclude-dir=models \
        --exclude-dir=runtime --exclude-dir=__pycache__ \
        --exclude="$SELF" \
        --exclude='PORTING-LEDGER.md' --exclude='AGENT-EXPERIENCE.md' \
        --exclude='LINEAGE.md' --exclude='METHODOLOGY.md' \
        --exclude='REPORT-*.md' \
        --exclude='runtime.env' 2>/dev/null || true)"
# 允许的例外：显式标注了 verify:allow-outside-path 的行。
# 只用于「自动探测本机已有部署」这类**可选**候选路径 —— 找不到照样能跑，绝不能被当成必需路径。
# 标注意味着知情豁免，不是漏网。
hits="$(printf '%s\n' "$raw" | grep -v 'verify:allow-outside-path' | grep -v '^$' || true)"
if [ -z "$hits" ]; then
  ok "没有引用仓库外的绝对路径"
  npass=$((npass+1))
else
  printf '%s[FAIL]%s 发现仓库外路径引用：\n' "$C_R" "$C_0"
  printf '%s\n' "$hits" | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

# 允许 .env 里的 $HOME 默认值（GPU 自动探测那几个 candidate），但必须只是 fallback
if grep -rn 'HOME' "$ROOT/app/env.sh" 2>/dev/null | grep -qE '^\s*[0-9]+:\s*(local )?.*HOME'; then
  log "  （app/env.sh 里对 \$HOME 的引用仅用于自动探测，且始终可被 --from 覆盖）"
fi
echo

# --- 6. README 里出现的命令，脚本都存在 --------------------------------
log "[6/7] README 命令可解析"
cmds="$(grep -oE '\./(scripts/)?[A-Za-z0-9_.-]+\.sh' "$ROOT/README.md" 2>/dev/null | sort -u || true)"
if [ -z "$cmds" ]; then
  warn "  README 里没有解析到 ./*.sh 形式的命令"
else
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    chk "README 引用 $c" test -e "$ROOT/${c#./}"
  done <<< "$cmds"
fi
echo

# --- 7. 运行载荷是否就位（可选，缺失只警告不算失败）---------------------
log "[7/7] 运行载荷（缺失不算错误，只是还不能启动）"
if [ -x "$ROOT/runtime/bin/ninfer-serve" ]; then
  ok "runtime/bin/ninfer-serve 存在"
  s="$(sha256_of "$ROOT/runtime/bin/ninfer-serve")"
  if [ "$s" = "7ebf2ebf6c086f0f135f97090825c0a8a0a05fd02ffc9199c5faf9dc6cc6d574" ]; then
    ok "  指纹匹配（验证过的构建）"
  else
    warn "  指纹 $s（不是验证过的那份构建）"
  fi
else
  warn "  runtime/ 未就位 → 跑 ./install.sh 或 ./scripts/fetch-runtime.sh"
fi
if [ -f "$ROOT/models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer" ]; then
  ok "模型文件存在（$(human_size "$(stat -c %s "$ROOT/models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer")")）"
else
  warn "  models/ 未就位 → 跑 ./scripts/fetch-model.sh"
fi
echo

echo "================================================================"
if [ "$FAIL" = "0" ]; then
  printf '%s结论：PASS —— 通过 %d 项，仓库自包含%s\n' "$C_G" "$npass" "$C_0"
  exit 0
else
  printf '%s结论：FAIL —— %d 项失败 / %d 项通过%s\n' "$C_R" "$FAIL" "$npass" "$C_0"
  exit 1
fi
