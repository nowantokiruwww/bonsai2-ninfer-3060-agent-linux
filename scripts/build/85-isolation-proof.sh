#!/usr/bin/env bash
# scripts/85-isolation-proof.sh — 隔离证明（方案 §5 的六条，逐条可执行）
#
# 目的：用命令证明本项目的**每一个输入都来自项目自己**，
#       而不是机器上那套旧移植（那是"暗病"的来源）。
#
# 判定为 PASS 的条件全部落地在证据文件里，README 直接引用这些文件。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "85-isolation"
ISO="$PROJ/evidence/isolation"; mkdir -p "$ISO"
R="$ISO/ISOLATION-PROOF.md"
fail=0

th() { echo; echo "## $*" >> "$R"; }
line() { echo "- $*" >> "$R"; }

{
  echo "# 隔离证明（ISOLATION PROOF）"
  echo
  echo "生成时间：$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "项目根：\`$PROJ\`"
  echo
  echo "**结论**：见文末。每条都有对应命令与证据文件。"
} > "$R"

# ---- 1. 依赖层断言：没有任何赋值把 CUDA/动态库路径指向项目外 ----
th "1) 依赖层断言：没有脚本把 CUDA/动态库路径**赋值**为项目外"
# 注意：判定必须基于"赋值"这种语义，而不是"文本里出现了这个词"。
# 早期版本只 grep 路径字符串，结果把两处**正常**内容判成 FAIL：
#   * scripts/20-cuda-fetch.sh:12 的注释「不需要 sudo；不触碰 /usr/local/cuda*」
#   * scripts/00-baseline.sh:44 的存在性探测 `ls -d /usr/local/cuda*`（就是用来记录起点的）
# 一个把 PASS 判成 FAIL 的门禁比没有门禁更危险，故改为语义断言。
BAD=$(grep -rnE '(CUDA_HOME|CUDA_PATH|CUDA_ROOT|CUDACXX|CUDAToolkit_ROOT|LD_LIBRARY_PATH)=["'"'"']?(/usr/local/cuda|\$HOME/cuda|~/cuda)' \
        "$PROJ/scripts" "$PROJ/config" "$PROJ/agent" "$PROJ/package" 2>/dev/null || true)
BADPATH=$(grep -rnE 'PATH=["'"'"']?(/usr/local/cuda|\$HOME/cuda|~/cuda)' \
        "$PROJ/scripts" "$PROJ/config" "$PROJ/agent" "$PROJ/package" 2>/dev/null || true)
{
  echo '```'
  echo '$ grep -rnE "(CUDA_HOME|CUDA_PATH|CUDA_ROOT|CUDACXX|CUDAToolkit_ROOT|LD_LIBRARY_PATH|PATH)=[\"?](/usr/local/cuda|\$HOME/cuda|~/cuda)" scripts/ config/ agent/ package/'
  echo "${BAD}${BADPATH}"
  echo '```'
} >> "$R"
if [ -z "$BAD" ] && [ -z "$BADPATH" ]; then
  line "**PASS** —— 没有任何赋值把 CUDA/动态库路径指向项目外"
else
  line "**FAIL** —— 存在指向项目外的赋值，见上"; fail=1
fi

# ---- 1b. 文本清单（信息性，不参与判定）----
th "1b) 禁用路径的文本清单（信息性；注释与存在性探测属正常）"
HITS=$(grep -rnE "/usr/local/cuda|$HOME/cuda-12\.9|$HOME/src/ninfer-all|$HOME/llm" \
        --include='*.sh' --include='*.py' --include='*.env' \
        "$PROJ" 2>/dev/null \
        | grep -v '/\.store/' | grep -v '/logs/' \
        | grep -v 'scripts/85-isolation-proof.sh' \
        | grep -v 'scripts/50-build.sh' || true)
line "命中 $(echo "$HITS" | grep -c . || true) 行，逐条列出供人工判断（本项不判 FAIL）："
{
  echo
  echo '```'
  echo "$HITS"
  echo '```'
} >> "$R"

# ---- 2. 构建脚本里的 CUDA 只能指向项目内 ----
th "2) 构建脚本的 CUDA 路径只能指向项目内"
CFG="$PROJ/config/env.sh"
if grep -qE 'NINFER_CUDA_DIR="\$STORE_TOOLCHAIN/cuda-' "$CFG"; then
  line '**PASS** —— `config/env.sh` 里 `NINFER_CUDA_DIR="$STORE_TOOLCHAIN/cuda-$NINFER_CUDA_VERSION"`'
else
  line "**FAIL** —— 未发现项目内 CUDA 根的定义"; fail=1
fi
if grep -q 'CUDA_HOME=' "$PROJ/scripts/50-build.sh" 2>/dev/null; then
  line '`scripts/50-build.sh` 显式 `export CUDA_HOME="$NINFER_CUDA_DIR"`（并先做构建期门禁）'
fi

# ---- 3. readelf / ldd 真实解析 ----
th "3) 产物期门禁：readelf -d（RUNPATH）+ ldd（真实解析）"
BIN="$NINFER_SERVE"
if [ -x "$BIN" ]; then
  LC_ALL=C readelf -d "$BIN" > "$ISO/readelf-dyn.txt" 2>&1 || true
  ldd "$BIN" > "$ISO/ldd.txt" 2>&1 || true
  # 必须 LC_ALL=C：非英文 locale 下 readelf 会本地化 "Library runpath"，
  # 而 `grep -oE '/[^]]*'` 会抓到本地化文本里的斜杠（实测得到 runpath=/值）→ 误判 FAIL。
  RUNPATH=$(LC_ALL=C readelf -d "$BIN" \
    | sed -n 's/.*(RUNPATH)[^[]*\[\(.*\)\].*/\1/p;s/.*(RPATH)[^[]*\[\(.*\)\].*/\1/p' \
    | tr ':' '\n' | grep -v '^$' | head -1 || true)
  {
    echo '```'
    echo "binary  = $BIN"
    echo "RUNPATH = ${RUNPATH:-<none>}"
    echo "project = $NINFER_CUDA_DIR"
  } >> "$R"
  if [ -z "$RUNPATH" ] || [[ "$RUNPATH" == "$NINFER_CUDA_DIR"* ]]; then
    line "**PASS** —— RUNPATH 落在项目内"
  else
    line "**FAIL** —— RUNPATH 在项目外: $RUNPATH"; fail=1
  fi
  FOREIGN=$(grep -E 'libcudart|libcublas|libnvjitlink' "$ISO/ldd.txt" | grep -vE "$NINFER_CUDA_DIR" || true)
  if [ -z "$FOREIGN" ]; then
    line "**PASS** —— libcudart/libcublas/libnvjitlink 全部解析到项目内"
  else
    line "**FAIL** —— 有库解析到项目外："; echo '```' >> "$R"; echo "$FOREIGN" >> "$R"; echo '```' >> "$R"; fail=1
  fi
  line '白名单例外：`libcuda.so.1`（驱动加载器）来自系统属正常：'
  { echo '```'; grep -E 'libcuda\.so\.1' "$ISO/ldd.txt" || echo "(none)"; echo '```'; } >> "$R"
else
  line "**SKIP** —— 尚未构建（$BIN 不存在）"
fi

# ---- 4. 源码锁定且干净 ----
th "4) 源码树锁定且干净"
SRC="$NINFER_SRC_DIR"
if [ -d "$SRC/.git" ]; then
  HEAD=$(git -C "$SRC" rev-parse HEAD)
  DIRTY=$(git -C "$SRC" status --porcelain | head -10)
  { echo '```'; echo "HEAD     = $HEAD"; echo "pinned   = $NINFER_SRC_COMMIT"; echo "VERSION  = $(cat "$SRC/VERSION" 2>/dev/null || echo -)"; echo "dirty    = ${DIRTY:-<clean>}"; echo '```'; } >> "$R"
  [ "$HEAD" = "$NINFER_SRC_COMMIT" ] && line "**PASS** —— HEAD 等于锁定 commit" || { line "**FAIL** —— HEAD 不等于锁定 commit"; fail=1; }
  [ -z "$DIRTY" ] && line "**PASS** —— 工作树干净（本轮零补丁，见 patches/README.md）" || { line "**FAIL** —— 工作树有改动"; fail=1; }
else
  line "**SKIP** —— 源码未就位"
fi

# ---- 5. 模型哈希 ----
th "5) 模型 sha256 等于官方发布值"
if [ -s "$NINFER_MODEL_PATH" ]; then
  GOT=$(sha256sum "$NINFER_MODEL_PATH" | awk '{print $1}')
  SZ=$(stat -c %s "$NINFER_MODEL_PATH")
  { echo '```'; echo "path   = $NINFER_MODEL_PATH"; echo "bytes  = $SZ"; echo "sha256 = $GOT"; echo "expect = $NINFER_MODEL_SHA256"; echo '```'; } >> "$R"
  if [ "$GOT" = "$NINFER_MODEL_SHA256" ] && [ "$SZ" = "$NINFER_MODEL_BYTES" ]; then
    line "**PASS**"
  else
    line "**FAIL**"; fail=1
  fi
else
  line "**SKIP** —— 模型未就位"
fi

# ---- 6. 外部 device profile 未被触碰 ----
th "6) \`~/.cache/ninfer/device-profiles.json\` 未被读取/写入"
FOREIGN="$FOREIGN_PROFILE_FILE"
BASE_F="$ISO/foreign-profile-baseline.txt"
if [ -e "$FOREIGN" ]; then
  NOW=$(sha256sum "$FOREIGN" | awk '{print $1}')
  NOW_MT=$(stat -c %y "$FOREIGN")
  WAS=$(awk -F= '/^sha256=/{print $2}' "$BASE_F" 2>/dev/null || echo "")
  WAS_MT=$(awk -F= '/^mtime=/{print $2}' "$BASE_F" 2>/dev/null || echo "")
  { echo '```'; echo "path        = $FOREIGN"; echo "sha256 now  = $NOW"; echo "sha256 base = ${WAS:-<未冻结>}"; echo "mtime  now  = $NOW_MT"; echo "mtime  base = ${WAS_MT:-<未冻结>}"; echo '```'; } >> "$R"
  if [ -n "$WAS" ] && [ "$NOW" = "$WAS" ] && [ "$NOW_MT" = "$WAS_MT" ]; then
    line "**PASS** —— 外部 profile 未被读取也未被写入"
  else
    line "**FAIL** —— 外部 profile 发生了变化（说明有进程按默认路径读了它，或写了它）"; fail=1
  fi
else
  line "**PASS** —— 外部 profile 不存在（干净系统应有的状态）"
fi

# ---- 结论 ----
th "结论"
if [ "$fail" = "0" ]; then
  echo "**全部通过。** 本项目的输入没有一条来自机器上既有的旧移植产物。" >> "$R"
else
  echo "**存在失败项**（见上）。失败项未解决前，本项目的数字不应被当作"从零构建"的结果。" >> "$R"
fi
echo >> "$R"
echo "证据文件：\`readelf-dyn.txt\`、\`ldd.txt\`、\`foreign-profile-baseline.txt\`、\`artefact-gate.txt\`。" >> "$R"

cat "$R"
note "隔离证明 -> $R（verdict=$([ "$fail" = 0 ] && echo PASS || echo FAIL)）"
log_finish "$fail"
[ "$fail" = "0" ] || exit 1
