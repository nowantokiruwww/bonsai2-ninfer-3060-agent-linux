#!/usr/bin/env bash
# scripts/70-calibrate.sh — Phase 7：在 RTX 3060（28 SM）上标定 device profile
#
# 为什么必须做：docs/device-profiles.md:21 的内置表只覆盖 RTX 3090/4090/5090/PRO 6000，
# RTX 3060（28 SM）没有内置 profile；:38 明确说 SM 数不同必须自行标定。
# 不标定就会落到编译期表，且可能被 ~/.cache/ninfer 里的旧 profile 静默顶替。
#
# 产出：<project>/profiles/device-profiles.json + evidence/calibrate/

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "70-calibrate"
EV="$PROJ/evidence/calibrate"; mkdir -p "$EV" "$PROJ/profiles"
ISO="$PROJ/evidence/isolation"; mkdir -p "$ISO"

[ -x "$NINFER_CALIBRATE" ] || { echo "[fail] 未找到 $NINFER_CALIBRATE（先跑 scripts/50-build.sh）" >&2; exit 1; }

# --- profile 污染门禁：实验前冻结外部 profile ---
FOREIGN="$FOREIGN_PROFILE_FILE"
if [ -e "$FOREIGN" ]; then
  printf 'path=%s\nbytes=%s\nmtime=%s\nsha256=%s\nfrozen_at=%s\n' \
    "$FOREIGN" "$(stat -c %s "$FOREIGN")" "$(stat -c %y "$FOREIGN")" \
    "$(sha256sum "$FOREIGN" | awk '{print $1}')" "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    > "$ISO/foreign-profile-before-calibrate.txt"
  note "外部 profile 冻结: $(sha256sum "$FOREIGN" | awk '{print $1}')"
else
  note "外部 profile 不存在（干净系统应有的状态）"
fi

export NINFER_DEVICE_PROFILES="$PROJ/profiles/device-profiles.json"
export CUDA_VISIBLE_DEVICES="$GPU_UUID_3060"
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export PATH="$NINFER_CUDA_DIR/bin:$PATH"
# 明确不带 LD_LIBRARY_PATH，靠二进制 RUNPATH 找到项目自带 CUDA（见 50-build.sh 的门禁）
unset LD_LIBRARY_PATH 2>/dev/null || true

note "NINFER_DEVICE_PROFILES=$NINFER_DEVICE_PROFILES"
note "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"

# --help 不保证退出码为 0，用 run_ok 免得不必要的终止
run_ok "$NINFER_CALIBRATE" --help

# 该 GPU 的身份（写进 evidence，供与 profile 条目里的 multiprocessors 对照）
nvidia-smi --query-gpu=index,uuid,name,compute_cap --format=csv > "$EV/gpu-identity.txt" 2>&1 || true

# --- 标定 ---
# --out 落盘到项目内；--print 把条目打印出来留证；--repeat 提高稳定性
run "$NINFER_CALIBRATE" --device 0 --out "$NINFER_DEVICE_PROFILES" --repeat 2
run_ok bash -c "'$NINFER_CALIBRATE' --device 0 --print > '$EV/profile-printed.json'"

[ -s "$NINFER_DEVICE_PROFILES" ] || { echo "[fail] 标定未产出 profile: $NINFER_DEVICE_PROFILES" >&2; exit 1; }

cp "$NINFER_DEVICE_PROFILES" "$EV/device-profiles.json"
sha256sum "$NINFER_DEVICE_PROFILES" > "$EV/device-profiles.sha256"
note "profile -> $NINFER_DEVICE_PROFILES ($(stat -c %s "$NINFER_DEVICE_PROFILES") B)"

# 把 profile 里的硬件身份解析出来（应含 multiprocessors=28）
python3 - "$NINFER_DEVICE_PROFILES" > "$EV/profile-summary.txt" 2>&1 <<'PY' || true
import json, sys
d = json.load(open(sys.argv[1]))
print("# schema =", d.get("schema"), "schema_version =", d.get("schema_version"))
devs = d.get("devices")
if isinstance(devs, dict):
    items = devs.items()
elif isinstance(devs, list):
    items = enumerate(devs)
else:
    items = [("<unknown>", devs)]
for k, v in items:
    if isinstance(v, dict):
        print(f"- key={k} hardware_class={v.get('hardware_class')!r} "
              f"multiprocessors={v.get('multiprocessors')!r} origin={v.get('origin')!r}")
    else:
        print(f"- key={k} value={type(v).__name__}")
PY
cat "$EV/profile-summary.txt"

# --- 门禁复核：外部 profile 必须未被触碰 ---
if [ -e "$FOREIGN" ]; then
  now=$(sha256sum "$FOREIGN" | awk '{print $1}')
  was=$(awk -F= '/^sha256=/{print $2}' "$ISO/foreign-profile-before-calibrate.txt")
  if [ "$now" != "$was" ]; then
    echo "[fail] 外部 profile 被改动了！was=$was now=$now" >&2; exit 1
  fi
  note "profile 门禁 PASS：外部 profile 未被读取/写入"
fi

log_finish 0
echo "[done] calibration -> $NINFER_DEVICE_PROFILES"
