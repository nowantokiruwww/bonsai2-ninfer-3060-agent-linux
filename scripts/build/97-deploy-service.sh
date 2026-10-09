#!/usr/bin/env bash
# scripts/97-deploy-service.sh — 把已验收的构建部署成常驻 user systemd 服务
#
# 设计要点：
#   * 部署物来自 dist/<ver>/runtime（让"部署的"和"要发布的"是同一个对象）。
#   * 部署根用纯 ASCII（$HOME/bonsai-ninfer-3060）——避免把非 ASCII 路径写进 systemd unit。  # verify:allow-outside-path（历史编译期流水线，部署根在仓库外）
#   * 参数**只有一个入口**：$PREFIX/config/runtime.env（你要调上下文/速度就改这里）。
#   * 服务单元由本脚本**生成**（不手写），生成时读 config/env.sh，保证可复现。
#   * 只做 user 单元；不需要 sudo。
#
# 用法：bash scripts/97-deploy-service.sh [--profile-name NAME] [--dry-run]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/env.sh"
source "$HERE/lib/log.sh"

log_init "97-deploy"

DRY=0
ENABLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --enable) ENABLE=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

DIST="$PROJ/dist/${NINFER_VERSION}"
SRC_RT="$DIST/runtime"
PREFIX="$HOME/bonsai-ninfer-3060"  # verify:allow-outside-path（历史编译期流水线，部署根在仓库外）
UNIT="bonsai2-ninfer-3060.service"
UNIT_PATH="$HOME/.config/systemd/user/$UNIT"
EV="$PROJ/evidence/deploy"; mkdir -p "$EV"

[ -x "$SRC_RT/bin/ninfer-serve" ] || { echo "[fail] 找不到发布物 $SRC_RT/bin/ninfer-serve，先跑 bash scripts/make-release.sh（上一代叫 package/make-package.sh）" >&2; exit 1; }

echo "=== 0) 若本单元已在跑，先停掉（幂等重部署）==="
# 不停掉的话，前置检查会看到"8098 被占用 + 显存只剩 1GB"，从而误判失败。
# 实测踩过：第二次部署直接报 [fail] 端口 8098 已被占用 / 空闲显存只有 1131 MiB。
# ⚠ --dry-run 必须**只读**：本脚本早期版本在 dry-run 下也会走到这里把服务停掉，
#   实测踩过——只是想验证生成器，结果把正在跑的 3060 服务停了。（见 L30）
if [ "$DRY" = "1" ]; then
  echo "  (dry-run) 只读模式：不碰正在运行的服务，也不写任何文件"
elif systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
  run systemctl --user stop "$UNIT"
  for _ in $(seq 1 30); do
    f=$(nvidia-smi --query-gpu=uuid,memory.free --format=csv,noheader,nounits 2>/dev/null \
        | awk -F', ' -v u="$GPU_UUID_3060" '$1==u{print $2}')
    [ "${f:-0}" -ge "${DEPLOY_MIN_FREE_MIB:-10600}" ] && break
    sleep 2
  done
  echo "  旧实例已停；空闲显存 $(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1) MiB"
else
  echo "  (本单元未在运行)"
fi

echo "=== 1) 前置检查 ==="
fail=0

# 1a. 端口
# dry-run 且端口是被**本单元自己**占着时不算冲突（否则"服务在跑时验证生成器"永远失败）
if ss -ltn 2>/dev/null | grep -qE ":$NINFER_PORT\b"; then
  if [ "$DRY" = "1" ] && systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
    echo "  端口 $NINFER_PORT 被本单元自己占着（dry-run 视为正常）✓"
  else
    echo "[fail] 端口 $NINFER_PORT 已被占用：" >&2
    ss -ltnp 2>/dev/null | grep -E ":$NINFER_PORT\b" >&2 || true
    fail=1
  fi
else
  echo "  端口 $NINFER_PORT 空闲 ✓"
fi

# 1b. GPU UUID 必须在（不能靠序号：CUDA 设备序与 nvidia-smi 可能相反）
if nvidia-smi -L 2>/dev/null | grep -q "$GPU_UUID_3060"; then
  echo "  GPU UUID 存在 ✓  $GPU_UUID_3060"
else
  echo "[fail] nvidia-smi 里找不到 UUID $GPU_UUID_3060（换槽/换卡了？）" >&2
  nvidia-smi -L >&2 || true
  fail=1
fi

# 1c. 空闲显存
# 阈值怎么来的（不是拍脑袋）：当前部署档 rk2v4-e8 @ 49152 + 投机，
# 在**空闲 10,810 MiB** 时实测启动通过；而 rk2v4-e8 @ 76768 在同一空闲量下失败。
# 故取 10,600 作为"我们这个档位已验证过的下限附近"，低于它就明确拦下并给降级指引。
# 反对照：早先误用过 11,000，把"总占用"当成"需要的空闲量"，会误拦本来能起的配置。
# 参考数字：投机开着权重 7.99 GiB；rk2v4-e8 @ 76768 需要 > 10,814 MiB。
MIN_FREE="${DEPLOY_MIN_FREE_MIB:-10600}"
VERIFIED_FREE_MIB="${VERIFIED_FREE_MIB:-10810}"
FREE=$(nvidia-smi --query-gpu=uuid,memory.free --format=csv,noheader,nounits 2>/dev/null \
       | awk -F', ' -v u="$GPU_UUID_3060" '$1==u{print $2}')
DESKTOP_USED=$(nvidia-smi --query-gpu=uuid,memory.used --format=csv,noheader,nounits 2>/dev/null \
       | awk -F', ' -v u="$GPU_UUID_3060" '$1==u{print $2}')
echo "  3060 显存：空闲 ${FREE:-?} MiB，已被占 ${DESKTOP_USED:-?} MiB（桌面等）"
echo "  本档（rk2v4-e8 @ 49152 + dflash2 K=7）实测验证条件：空闲 ${VERIFIED_FREE_MIB} MiB 时启动通过；门限 ${MIN_FREE} MiB"
if [ -n "${FREE:-}" ]; then
  if [ "$DRY" = "1" ] && systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
    echo "  空闲显存 ${FREE} MiB 是本单元自己占掉后的余量（dry-run 不做门限判定）✓"
  elif [ "$FREE" -ge "$MIN_FREE" ]; then
    echo "  空闲显存 ${FREE} MiB ≥ ${MIN_FREE} MiB ✓"
  else
    echo "[fail] 空闲显存只有 ${FREE} MiB，低于门限 ${MIN_FREE} MiB。" >&2
    echo "       最常见的原因是桌面/浏览器占多了。两条路：" >&2
    echo "        ① 关掉占显存的程序后重跑本脚本；" >&2
    echo "        ② 把 $PREFIX/config/runtime.env 的 KV 降到更省的档（实测通过值）：" >&2
    echo "           rk4v4-e8 @ 49152（余量约 3GB） / int8 @ 32768 / int8 @ 24576" >&2
    echo "       ⚠ 改 KV 后**必须同步改** ~/.dsh/profiles/web/cordis.patch.yml 里 bonsai2-3060 的 contextWindow" >&2
    fail=1
  fi
else
  echo "  (拿不到空闲显存，跳过该项)" >&2
fi

# 1d. 模型哈希
if [ -s "$NINFER_MODEL_PATH" ]; then
  got=$(sha256sum "$NINFER_MODEL_PATH" | awk '{print $1}')
  if [ "$got" = "$NINFER_MODEL_SHA256" ]; then
    echo "  模型 sha256 一致 ✓"
  else
    echo "[fail] 模型 sha256 不符：$got" >&2; fail=1
  fi
else
  echo "[fail] 找不到模型 $NINFER_MODEL_PATH" >&2; fail=1
fi

[ "$fail" -eq 0 ] || { echo "[fail] 前置检查未通过，终止。" >&2; exit 1; }
note "前置检查通过（端口 $NINFER_PORT / UUID / 显存 $FREE MiB / 模型哈希）"

echo
echo "=== 2) 安装发布物到 $PREFIX ==="
# install-runtime.sh 的契约是"在包目录里就地运行"（MANIFEST 是 runtime/ 内部那份，
# 路径相对 runtime/）。所以先整目录拷过去，再在部署根里就地跑，不传 --prefix。
if [ "$DRY" = "1" ]; then
  echo "  (dry-run) cp -a $SRC_RT/. $PREFIX/ && bash $PREFIX/install-runtime.sh"
else
  mkdir -p "$PREFIX"
  run cp -a "$SRC_RT/." "$PREFIX/"
  run bash "$PREFIX/install-runtime.sh"
fi

echo
echo "=== 3) 模型用符号链接（不复制 8.9G）==="
if [ "$DRY" = "0" ]; then
  mkdir -p "$PREFIX/models"
  if [ ! -L "$PREFIX/models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer" ]; then
    ln -sfn "$NINFER_MODEL_PATH" "$PREFIX/models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer"
  fi
  cp -f "$NINFER_DEVICE_PROFILES" "$PREFIX/profiles/device-profiles.json" 2>/dev/null || true
  echo "  模型符号链接 -> $NINFER_MODEL_PATH"
  echo "  profile 已拷贝（28-SM 标定结果）"
fi

echo
echo "=== 4) 写参数文件（唯一调参入口）==="
ENVF="$PREFIX/config/runtime.env"
if [ "$DRY" = "0" ]; then
  cat > "$ENVF" <<EOF
# bonsai2-ninfer-3060 运行时参数 —— **唯一调参入口**（由 scripts/97-deploy-service.sh 生成）
#
# ★ 唯一值得调的维度：上下文 ↔ 显存余量。只改下面 KV_CAPACITY 一行。
#   ⚠ 改它之后**必须同步改** ~/.dsh/profiles/web/cordis.patch.yml 里
#     provider "bonsai2-3060" 的 contextWindow / defaultContextWindow，否则两者不一致。
#
# ⚠⚠ 最重要的一条实测教训：**KV 上限不是这张卡的常数，它随"桌面当前占多少显存"变化。**
#   同一个 rk2v4-e8 @ 76768：
#     * 空闲 11,278 MiB 时（2026-10-06 21:35）→ 起来过
#     * 空闲 10,810 MiB 时（2026-10-07 03:38）→ 启动失败，日志只有
#       「ERROR startup failed | finalizing target | 31.8 ms」
#   所以"以前能起"不等于"现在能起"。
#
# 2026-10-07 03:5x 在空闲 10,810 MiB 下实测的阶梯（投机恒开 dflash2 K=7）：
#   rk2v4-e8 @ 76768  ✗       rk2v4-e8 @ 65536  ✓
#   rk2v4-e8 @ 57344  ✓       rk2v4-e8 @ 49152  ✓  ← 当前值（两种桌面状态下都通过）
#   rk4v4-e8 @ 49152  ✓       int8 @ 8192 ✓
# 取 49152 而不是 65536：它在"空闲 11,278"与"空闲 10,810"两种桌面状态下都验证通过，
# 有真实余量；65536 只在当前状态下验证过，桌面再长一点就会重演上面的启动失败。
#
# 想回到更大的上下文：先关掉占显存的程序，用 scripts/75-kv-gate.sh 重测上限，
# 再改这里 + 同步 DSH 的 contextWindow。
#
# --spec dflash2 --draft-tokens 7 是必用项，不作为可调开关。
# 参考：投机开着权重 7.99 GiB，关掉 6.70 GiB（草稿模型多占约 1.3 GiB）。
PREFIX=$PREFIX
HOST=127.0.0.1
PORT=$NINFER_PORT
MODEL_ID=$NINFER_MODEL_ID
MODEL_PATH=$PREFIX/models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer
GPU_UUID=$GPU_UUID_3060
CUDA_VISIBLE_DEVICES=$GPU_UUID_3060
CUDA_DEVICE_ORDER=PCI_BUS_ID
NINFER_DEVICE_PROFILES=$PREFIX/profiles/device-profiles.json
KV_DTYPE=rk2v4-e8
KV_CAPACITY=49152
# ⚠ 含空格的值必须加引号：本文件既被 serve.sh 用 source 读（bash），又是 systemd 的
#   EnvironmentFile。不加引号会被 bash 拆成"赋值 + 执行命令"，实测报
#   「<prefix>/config/runtime.env: 行 26: dflash2: 未找到命令」 且服务起不来。
SPEC_FLAGS="--spec dflash2 --draft-tokens 7"
#
# ── 思考与采样（2026-10-07 L26/L27/L28 实测定档；改前先读 PORTING-LEDGER）──
# 采样档对齐 V100/llama.cpp-prism：--temperature/--top-p/--top-k 对应 V100 的
#   --temp 1.0 --top-p 0.95 --top-k 20。刻意**不用 --greedy**：它是强制 argmax、
#   无任何随机逃逸路径，是 L26 复读锁死的放大器。
# ⚠ --no-thinking 也**不要加回来**：--no-thinking 与 --greedy 的组合实测会让模型把同一条
#   工具调用逐字节重复 43 次、harness 注入 10 次提醒全部无效、永不自愈（L26 实战事故）。
# --default-thinking-budget 不是"质量帽"而是**收口机制**：到点服务端主动补思考终止标记
#   逼模型作答。硬约束是「思考预算 + 工具调用载荷(约 6,100 tok) <= DSH 侧 maxTokens」。
# 为什么是 1024 而不是 4096（L28 实测，固定 agent 任务每档 3 次）：
#   4096 -> 中位墙钟 67.8s、真正写出文件 1/3；1024 -> 44.2s、3/3；
#   512  -> 40.9s、2/3，但单轮重复率高（6/15 = 40%，四档里最差，不建议当默认）。
#   decode tok/s 几乎不随预算变（58-83 全域），差的是"被烧掉多少思考 token"。
# ⚠ ngram 别当速度旋钮：--ngram-draft-tokens 在开 --spec 时默认就是 15（开），
#   它在长思考档里只占全部接受 token 的 5.0%，与速度无关（L28）。
#   早期版本这里写过"显式关掉 ngram（0 = 关闭）"，那是 13:0x 中间态的残留、且与事实不符。
# --request-log-jsonl 是行为中性的取证开关（server_start/request_start/request_done/
#   throughput 四类事件落盘，**不含 prompt 正文**），本轮把 40 tok/s 归因清楚全靠它，保留常开。
EXTRA_FLAGS="--max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 --default-reasoning-effort medium --default-thinking-budget 1024 --request-log-jsonl $PREFIX/logs/request.jsonl"
EOF
  echo "  已写 $ENVF"
fi

echo
echo "=== 5) 生成 systemd user 单元 ==="
if [ "$DRY" = "0" ]; then
  mkdir -p "$HOME/.config/systemd/user" "$PREFIX/logs"
  cat > "$UNIT_PATH" <<EOF
# 由 scripts/97-deploy-service.sh 生成（不要手改；改 config/runtime.env）
# 引擎: iamwavecut/ninfer-all @ $NINFER_SRC_COMMIT
[Unit]
Description=bonsai2-ninfer-3060 — NInfer + Ternary-Bonsai-2-27B on RTX 3060 (port $NINFER_PORT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$PREFIX
EnvironmentFile=$PREFIX/config/runtime.env
Environment=CUDA_VISIBLE_DEVICES=$GPU_UUID_3060
Environment=CUDA_DEVICE_ORDER=PCI_BUS_ID
Environment=NINFER_DEVICE_PROFILES=$PREFIX/profiles/device-profiles.json
# 随包发的 CUDA 运行库优先（二进制 RUNPATH 指向构建时的绝对路径，换机器就没了）
Environment=LD_LIBRARY_PATH=$PREFIX/lib
# 日志交给 systemd 收集（--foreground 不自己重定向）
# 用显式子命令形式（runtime-tools.sh serve）而不是 serve.sh 软链接：
# 两种都支持（软链接按 \$0 basename 推断子命令），但单元里显式最稳。
# ⚠ 上面这行的 \$0 必须转义：本 heredoc 未加引号，裸写 $0 会被展开成脚本自身路径，
#   生成出来的单元注释就变成「按 scripts/97-deploy-service.sh basename 推断」——错的。
ExecStart=$PREFIX/runtime-tools.sh serve --foreground
# 注意：不能用 SIGINT。引擎对单次 SIGINT 不退出（它打印 "Press Ctrl+C again within
# 5 s to close"，要求按两次），于是每次 stop 都要干等 TimeoutStopSec 超时再被 SIGKILL
# ——实测 63 秒、单元落成 failed。SIGTERM 实测 5 秒干净退出、显存立即释放。见 L24。
KillSignal=SIGTERM
KillMode=mixed
TimeoutStopSec=60
Restart=on-failure
RestartSec=10
StandardOutput=append:$PREFIX/logs/service.log
StandardError=append:$PREFIX/logs/service.log

[Install]
WantedBy=default.target
EOF
  echo "  已写 $UNIT_PATH"
fi

echo
echo "=== 6) 启动服务 ==="
if [ "$DRY" = "1" ]; then
  echo "  (dry-run) systemctl --user daemon-reload && systemctl --user start${ENABLE:+ + enable} $UNIT"
else
  run systemctl --user daemon-reload
  # 轮转服务日志：否则上一次失败尝试的旧报错会混进本次证据，导致误判
  if [ -s "$PREFIX/logs/service.log" ]; then
    mv "$PREFIX/logs/service.log" "$PREFIX/logs/service.log.$(date '+%Y%m%d-%H%M%S')"
  fi
  # 默认【不设开机自启】：只 start。要用自启必须显式 --enable。
  # （用户要手动开关，所以 enable 绝不能是默认行为；踩过：enable 会在下次登录时自己起来）
  run systemctl --user start "$UNIT"
  if [ "$ENABLE" = "1" ]; then
    run systemctl --user enable "$UNIT"
    echo "  ⚠ 已启用开机自启（--enable）：下次登录会自动启动；用 systemctl --user disable $UNIT 撤销"
  fi
  echo -n "  等待就绪"
  ok=0
  for i in $(seq 1 120); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$NINFER_HOST:$NINFER_PORT/v1/models" || true)" = "200" ]; then
      echo " → 就绪（${i}s）"; ok=1; break
    fi
    echo -n "."
    sleep 1
  done
  [ "$ok" = "1" ] || {
    echo; echo "[fail] 就绪超时。service.log 尾部：" >&2
    tail -25 "$PREFIX/logs/service.log" >&2 || true
    exit 1
  }
fi

echo
echo "=== 7) 证据 ==="
if [ "$DRY" = "0" ]; then
  {
    echo "### $UNIT_PATH"; cat "$UNIT_PATH"
    echo; echo "### config/runtime.env"; cat "$ENVF"
    echo; echo "### systemctl status"; systemctl --user status "$UNIT" --no-pager 2>&1 | head -20
    echo; echo "### /v1/models"; curl -s "http://$NINFER_HOST:$NINFER_PORT/v1/models" 2>&1 | head -5
    echo; echo "### ldd（CUDA 库解析）"; ldd "$PREFIX/bin/ninfer-serve" 2>&1 | grep -iE 'cudart|cublas|nvjitlink' | sed "s#$PREFIX#<prefix>#"
    echo; echo "### 显存"; nvidia-smi --query-gpu=index,uuid,memory.used,memory.total --format=csv
    echo; echo "### PCIe"; nvidia-smi --query-gpu=index,name,pcie.link.gen.current,pcie.link.width.current --format=csv
    echo; echo "### 服务启动命令行（service.log 里 runtime-tools 打印的那行）"
    grep -m1 '命令: ' "$PREFIX/logs/service.log" 2>/dev/null || echo "(未找到；见 service.log)"
  } > "$EV/deploy-report.txt" 2>&1
  cp "$EV/deploy-report.txt" "$LOG_ROOT/" 2>/dev/null || true
fi

log_finish 0
echo "[done] 服务已部署：http://$NINFER_HOST:$NINFER_PORT/v1   （前缀 $PREFIX）"
echo "       调参（固定服务档）：编辑 $PREFIX/config/runtime.env 后 systemctl --user restart $UNIT"
echo "       调参（临时试档，不碰 systemd、日志打在终端）："
echo "         $PREFIX/tune.sh              # 预设表 + 当前生产档"
echo "         $PREFIX/tune.sh fast         # 不思考 + V100 采样（最快；先看 --help 的取舍）"
echo "         $PREFIX/tune.sh --dry-run    # 只看会跑什么"
echo "         $PREFIX/tune.sh --persist balanced   # 调好后写回 runtime.env 并重启服务"
echo
echo "       手动开关（默认不开机自启）："
echo "         起   systemctl --user start   $UNIT"
echo "         停   systemctl --user stop    $UNIT     # SIGTERM，约 5 秒"
echo "         重启 systemctl --user restart $UNIT"
echo "         看   systemctl --user status  $UNIT"
echo "         自启 systemctl --user enable|disable $UNIT   # 只有这里才碰自启"
