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
echo " 仓库自检 —— $(basename "$ROOT")"
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

# --- 3. python 语法（compile() 不生成 __pycache__）-----------------------
log "[3/7] python 语法"
while IFS= read -r s; do
  chk "语法 ${s#"$ROOT"/}" python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); compile(p.read_bytes(), str(p), "exec")' "$s"
done < <(find "$ROOT" -name '*.py' -not -path '*/.git/*' -not -path '*/__pycache__/*' | sort)
echo

# --- 4. 可执行位 ---------------------------------------------------------
log "[4/7] 可执行位"
for f in install.sh start.sh stop.sh restart.sh status.sh logs.sh presets.sh check.sh webui.sh \
         app/launcher.sh scripts/fetch-runtime.sh scripts/fetch-model.sh \
         scripts/install-service.sh scripts/verify.sh scripts/make-release.sh \
         docker/deploy.sh docker/build.sh docker/run.sh docker/entrypoint.sh; do
  [ -e "$ROOT/$f" ] || continue          # docker/ 是可选的，缺了不算错
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
raw="$( (cd "$ROOT" && grep -rnE '(^|[^A-Za-z0-9_])/(home|Users)/[A-Za-z0-9._-]+|~/bonsai|[$]HOME/bonsai|bonsai2-ninfer-3060-agent-linux[.]retired' \
        . \
        --include='*.sh' --include='*.py' --include='*.md' --include='*.html' --include='*.js' --include='*.env' \
        --exclude-dir=.git --exclude-dir=.cache --exclude-dir=logs --exclude-dir=models \
        --exclude-dir=runtime --exclude-dir=__pycache__ \
        --exclude="$SELF" \
        --exclude='PORTING-LEDGER.md' --exclude='AGENT-EXPERIENCE.md' \
        --exclude='LINEAGE.md' --exclude='METHODOLOGY.md' \
        --exclude='REPORT-*.md' \
        --exclude='runtime.env' ) 2>/dev/null || true)"
# 只保留仓库相对文件和行号；原始匹配内容可能包含本机路径。
hits="$(printf '%s\n' "$raw" | grep -v 'verify:allow-outside-path' | grep -v '^$' | cut -d: -f1-2 || true)"
if [ -z "$hits" ]; then
  ok "没有引用仓库外的绝对路径"
  npass=$((npass+1))
else
  printf '%s[FAIL]%s 发现仓库外路径引用（仅显示位置，不显示路径内容）：\n' "$C_R" "$C_0"
  printf '%s\n' "$hits" | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

# 允许 .env 里的 $HOME 默认值（GPU 自动探测那几个 candidate），但必须只是 fallback
if grep -rn 'HOME' "$ROOT/app/env.sh" 2>/dev/null | grep -qE '^\s*[0-9]+:\s*(local )?.*HOME'; then
  log "  （app/env.sh 里对 \$HOME 的引用仅用于自动探测，且始终可被 --from 覆盖）"
fi
echo

# --- 5b. 生产档参数一致性 -----------------------------------------------
#
# 起因（L28/L30）：思考预算从 4096 改成 1024 后，docs/AGENT-EXPERIENCE.md 的
# §13.2（标题写着"最终配置"，是**现在时**）还留着 4096。verify 没发现，因为它把
# 这个文件整份当成"历史记录"豁免了 —— 豁免把"历史叙述"和"当前配置"混为一谈。
#
# 所以这里单独钉死"生产档"的定义：同一个值必须同时出现在
#   install.sh（生成 config/runtime.env 的模板）
#   docker/entrypoint.sh（容器里的同一份模板）
#   app/presets.env 的 balanced 档（网页控制台点"balanced"时用）
#   以及 docs/AGENT-EXPERIENCE.md §13.2 那段自称"最终配置"的代码块
# 四处取值不同就是在制造"文档说 A、脚本做 B"的静默漂移。
log "[5b/7] 生产档参数一致性"
budget_of() { grep -oE -- '--default-thinking-budget [0-9]+' "$1" 2>/dev/null | awk '{print $2}' | sort -u | head -1; }
b_install="$(budget_of "$ROOT/install.sh")"
b_docker="$(budget_of "$ROOT/docker/entrypoint.sh")"
b_presets="$(bash -c '. "$1/app/presets.env"; preset_apply balanced; printf "%s" "$P_BUDGET"' _ "$ROOT" 2>/dev/null || true)"
# 取 §13.2 标题之后出现的第一个 --default-thinking-budget 的数字
b_doc="$(awk '/^### 13\.2 /{f=1} f && /--default-thinking-budget/{
            match($0, /--default-thinking-budget [0-9]+/);
            print substr($0, RSTART+26, RLENGTH-26); exit }' \
        "$ROOT/docs/AGENT-EXPERIENCE.md" 2>/dev/null || true)"

chk "install.sh 有生产档思考预算" test -n "$b_install"
chk "docker/entrypoint.sh 有生产档思考预算" test -n "$b_docker"
chk "presets.env balanced 有思考预算" test -n "$b_presets"
if [ "$b_install" = "$b_docker" ] && [ "$b_install" = "$b_presets" ]; then
  chk "三处脚本的生产档思考预算一致（=$b_install）" test 1 = 1
else
  warn "  生产档思考预算不一致：install.sh=$b_install docker=$b_docker presets.balanced=$b_presets"
  chk "三处脚本的生产档思考预算一致" test 1 = 0
fi
# 这不是"不许出现 4096"（4096 是 think 档，且矩阵里到处是它），
# 而是"不许把 4096 当成生产默认"。
if [ -z "$b_doc" ]; then
  warn "  §13.2 里没解析到思考预算（文档结构变了？下面那条会失败）"
fi
chk "docs/AGENT-EXPERIENCE.md §13.2 引用的是生产档（$b_install）" test "$b_doc" = "$b_install"
echo

# --- 5c. 本机自己的 IP 不许出现在文档里 --------------------------------
# 文档示例使用 RFC 5737 TEST-NET 地址；真实地址不应进入仓库或可分享输出。
log "[5c/7] 本机 IP 没有写进公开文档"
# shellcheck source=../app/env.sh
if ( . "$ROOT/app/env.sh" 2>/dev/null && declare -F lan_ips >/dev/null ); then
  ips="$( (. "$ROOT/app/env.sh"; lan_ips) 2>/dev/null | awk '{print $NF}' | grep -vE '^$' || true )"
else
  ips="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' \
         | grep -vE '^(127\.|172\.1[0-9]\.|172\.2[0-9]\.|172\.3[01]\.|169\.254\.)' || true)"
fi
if [ -z "$ips" ]; then
  warn "  没探到本机局域网地址（没有网卡？），这一组检查跳过"
else
  ipfail=0
  nips="$(printf '%s\n' "$ips" | awk 'NF {n++} END {print n+0}')"
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    h="$(cd "$ROOT" && grep -rl -- "$ip" README.md docs --include='*.md' 2>/dev/null || true)"
    if [ -n "$h" ]; then
      printf '%s[FAIL]%s 检测到本机地址出现在公开文档中（地址已隐藏）：\n' "$C_R" "$C_0"
      printf '%s\n' "$h" | sed 's#^#    #'
      ipfail=1
    fi
  done <<< "$ips"
  chk "本机地址未写入公开文档（检查 $nips 个地址）" test "$ipfail" = 0
fi
# --- 5e. 证据与文档的交叉引用 -------------------------------------------
# 起因：病历里写 "见 evidence/xxx"，但那个文件没进仓库 —— 读者点开是 404。
# 这比缺功能更糟：它让"有证据"的声明变成装饰。
log "[5e/7] 文档引用的证据文件真实存在"
refs="$(cd "$ROOT" && grep -rhoE '(evidence|results)/[A-Za-z0-9._-]+/[A-Za-z0-9._*-]+|(evidence|results)/[A-Za-z0-9._-]+' \
        docs README.md RELEASE-NOTES.md 2>/dev/null | sort -u || true)"
nref=0; nmiss=0
while IFS= read -r r; do
  [ -n "$r" ] || continue
  nref=$((nref+1))
  if [ -e "$ROOT/$r" ]; then continue; fi
  # 带 * 或以 - 结尾的是"前缀引用"（如 evidence/params/frontier-*），命中任意一个即可
  case "$r" in
    *'*'*) hit="$(find "$ROOT/${r%/*}" -maxdepth 4 -name "${r##*/}" 2>/dev/null | head -1)"
           if [ -n "$hit" ]; then continue; fi ;;
    *- )   hit="$(find "$ROOT/${r%/*}" -maxdepth 4 -name "${r##*/}*" 2>/dev/null | head -1)"
           if [ -n "$hit" ]; then continue; fi ;;
  esac
  nmiss=$((nmiss+1))
  printf '%s[FAIL]%s 文档引用 %s，但仓库里没有这个文件\n' "$C_R" "$C_0" "$r"
done <<< "$refs"
if [ "$nmiss" = 0 ]; then
  ok "文档引用的 $nref 个证据文件全部存在"
  npass=$((npass+1))
else
  FAIL=$((FAIL+1))
fi
echo

# --- 5f. 文档引用的脚本真实存在 -----------------------------------------
log "[5f/7] 文档引用的脚本真实存在"
srefs="$(cd "$ROOT" && grep -rhoE '(scripts|agent)/[A-Za-z0-9._-]+\.(sh|py)' \
        docs README.md RELEASE-NOTES.md 2>/dev/null | sort -u || true)"
ns=0; nmiss=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  ns=$((ns+1))
  if [ -e "$ROOT/$s" ]; then continue; fi
  nmiss=$((nmiss+1))
  printf '%s[FAIL]%s 文档引用 %s，但仓库里没有这个文件\n' "$C_R" "$C_0" "$s"
done <<< "$srefs"
if [ "$nmiss" = 0 ]; then
  ok "文档引用的 $ns 个脚本全部存在"
  npass=$((npass+1))
else
  FAIL=$((FAIL+1))
fi
echo

# --- 5g. 文档内部链接可达 ---------------------------------------------------
# 起因：AGENT-EXPERIENCE.md 里有一条指向 evidence/params/REPORT-… 的链接，
# 那份报告实际在 docs/params/ —— 读者点开是 404。链接坏掉不会报错，只会静默失效。
log "[5g/7] 文档里的相对链接全部可达"
nlink=0; nbad=0
for src in README.md RELEASE-NOTES.md docs/*.md docs/params/*.md; do
  [ -e "$ROOT/$src" ] || continue
  dir="$(dirname "$src")"
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    case "$link" in http*|/*) continue ;; esac
    nlink=$((nlink+1))
    if [ -e "$ROOT/$dir/$link" ] || [ -e "$ROOT/$link" ]; then continue; fi
    nbad=$((nbad+1))
    printf '%s[FAIL]%s %s 里的链接 %s 不存在\n' "$C_R" "$C_0" "$src" "$link"
  done < <(grep -oE '\]\([^) ]+\.(md|sh|py|json|txt|yml|env)\)' "$ROOT/$src" 2>/dev/null \
           | sed -E 's/^\]\(([^[:space:]]+)\)/\1/')
done
if [ "$nbad" = 0 ]; then
  ok "文档里的 $nlink 条相对链接全部可达"
  npass=$((npass+1))
else
  FAIL=$((FAIL+1))
fi
echo

# --- 5d. README 隐私回归门禁 --------------------------------------------
log "[5d/7] README 隐私标识"
if grep -qE '(/(home|Users)/[A-Za-z0-9._-]+|GPU-[[:xdigit:]]{6,}-|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|hf_[A-Za-z0-9]{20,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|(^|[^0-9.])(10(\.[0-9]{1,3}){3}|192\.168(\.[0-9]{1,3}){2}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2})([^0-9.]|$))' "$ROOT/README.md"; then
  printf '%s[FAIL]%s README 包含疑似隐私标识（内容已隐藏）\n' "$C_R" "$C_0"
  FAIL=$((FAIL+1))
else
  ok "README 未发现密钥形态、邮箱、个人路径、GPU UUID 或私有 IPv4"
  npass=$((npass+1))
fi
echo

# --- 6. README 里出现的命令，脚本都存在 --------------------------------
log "[6/7] README 命令可解析"
cmds="$(grep -oE '\./[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?\.sh' "$ROOT/README.md" 2>/dev/null | sort -u || true)"
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
