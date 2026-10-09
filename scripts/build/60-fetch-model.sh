#!/usr/bin/env bash
# scripts/60-fetch-model.sh — Phase 6：模型工件下载 + 强校验
#
# 关键顺序（旧移植就是在这里栽的）：
#   **先校验工件 sha256 == 公布值，再去怀疑构建/引擎。**
# 上次把"引擎 fork 拿错"误读成"模型格式不兼容"，根因是没做这一步。
#
# 直连 huggingface.co 在本环境 DNS 污染/超时，走 hf-mirror.com。
# 下载完整文件后再校验，不用 Range 断点（避免半文件被当成完整文件）。

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "60-model"
mkdir -p "$STORE_MODELS"
EV="$PROJ/evidence/model"; mkdir -p "$EV"

URL_BASE="$HF_ENDPOINT/$NINFER_MODEL_HF_REPO/resolve/$NINFER_MODEL_HF_REVISION"

echo "$NINFER_MODEL_SHA256  $NINFER_MODEL_NAME" > "$STORE_MODELS/$NINFER_MODEL_NAME.sha256"

verify_one() {
  local name="$1" sha="$2" size="$3"
  local path="$STORE_MODELS/$name"
  if [ -s "$path" ] && [ "$(sha256sum "$path" | awk '{print $1}')" = "$sha" ]; then
    note "已缓存且校验通过: $name"
    return 0
  fi
  run curl -sSL --retry 3 --retry-delay 5 -o "$path.part" "$URL_BASE/$name"
  mv "$path.part" "$path"
  local got; got=$(sha256sum "$path" | awk '{print $1}')
  local sz;  sz=$(stat -c %s "$path")
  [ "$got" = "$sha" ] || { echo "[fail] $name sha256 不符: got=$got want=$sha" >&2; exit 1; }
  [ "$sz" = "$size" ] || { echo "[fail] $name 字节数 不符: got=$sz want=$size" >&2; exit 1; }
  note "$name OK: $sz B sha256=$got"
}

# 主工件（9,520,051,456 B）
verify_one "$NINFER_MODEL_NAME" "$NINFER_MODEL_SHA256" "$NINFER_MODEL_BYTES"

# 随附小文件（有则取，无则记录；不作为通过条件）
for extra in "Ternary-Bonsai-2-27B-ninfer-v3.ninfer.conversion.json" "NOTICE" "README.md"; do
  run_ok curl -sSL --retry 2 -o "$STORE_MODELS/$extra" "$URL_BASE/$extra"
  [ -s "$STORE_MODELS/$extra" ] && note "附加文件: $extra ($(stat -c %s "$STORE_MODELS/$extra") B)" || true
done

{
  echo "[model]"
  echo "hf_repo   = $NINFER_MODEL_HF_REPO"
  echo "revision  = $NINFER_MODEL_HF_REVISION"
  echo "endpoint  = $HF_ENDPOINT"
  echo "path      = $NINFER_MODEL_PATH"
  echo "bytes     = $(stat -c %s "$NINFER_MODEL_PATH")"
  echo "expected  = $NINFER_MODEL_BYTES"
  echo "sha256    = $(sha256sum "$NINFER_MODEL_PATH" | awk '{print $1}')"
  echo "expected  = $NINFER_MODEL_SHA256"
  echo "verdict   = PASS"
} | tee "$EV/model-identity.txt"
cp "$EV/model-identity.txt" "$PROJ/config/toolchain.lock.d/model.lock" 2>/dev/null || true

log_finish 0
echo "[done] model verified -> $NINFER_MODEL_PATH"
