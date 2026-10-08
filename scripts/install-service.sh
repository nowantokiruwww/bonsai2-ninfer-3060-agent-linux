#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/install-service.sh —— 注册成 systemd **用户**服务（可选，为了开机自启）
#
#   ./scripts/install-service.sh            # 安装 + 立马启动
#   ./scripts/install-service.sh --no-start # 只安装，不启动
#   ./scripts/install-service.sh --remove   # 卸载
#
# 生成的 unit 里所有路径都是**本仓库的绝对路径**（安装时烘焙进去），
# 所以仓库挪走之后要重新跑一次本脚本。
#
# ⚠ 停止必须用 SIGTERM。引擎的 SIGINT 处理要求"5 秒内按两次 Ctrl+C"，
#   用 SIGINT 的话每次 stop 都要干等 60 秒超时再被 SIGKILL（实测）。
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

UNIT_NAME="ninfer-3060-bonsai.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"

DO_START=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-start) DO_START=0; shift ;;
    --remove)
      systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
      rm -f "$UNIT_PATH"
      systemctl --user daemon-reload 2>/dev/null || true
      ok "已卸载 $UNIT_NAME"
      exit 0 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

command -v systemctl >/dev/null 2>&1 || die "没有 systemctl —— 这台机器不是 systemd，请直接用 ./start.sh"
[ -x "$ROOT/app/launcher.sh" ] || die "找不到 $ROOT/app/launcher.sh"
[ -f "$ROOT/config/runtime.env" ] || die "找不到 config/runtime.env —— 先跑 ./install.sh"

mkdir -p "$UNIT_DIR"

# 用 'EOF' 引号避免展开 —— 但我们需要 $ROOT 展开，所以用普通 heredoc 且只留 $ROOT。
# 注意：注释里不要用反引号，普通 heredoc 会对它做命令替换（踩过这个坑，病历 L25）。
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=ninfer-3060-bonsai (Ternary-Bonsai-2-27B on RTX 3060, sm_86)
Documentation=file://$ROOT/README.md
After=network.target

[Service]
Type=simple
WorkingDirectory=$ROOT

# 运行配置（唯一调参入口）
EnvironmentFile=$ROOT/config/runtime.env

# 锁卡与运行库：CUDA 的设备序和 nvidia-smi 相反，所以按 UUID 锁；
# 不用 --gpus 之类的外部机制，纯环境变量。
Environment=LD_LIBRARY_PATH=$ROOT/runtime/lib
Environment=CUDA_DEVICE_ORDER=PCI_BUS_ID
Environment=NINFER_DEVICE_PROFILES=$ROOT/runtime/profiles/device-profiles.json

ExecStart=$ROOT/app/launcher.sh serve --foreground

# 必须 SIGTERM：引擎对单次 SIGINT 不退出（要求 5 秒内两次），
# 用 SIGINT 会导致每次停止都等 60 秒超时再被 SIGKILL。
KillSignal=SIGTERM
KillMode=mixed
TimeoutStopSec=60

Restart=on-failure
RestartSec=10

StandardOutput=append:$ROOT/logs/service.log
StandardError=append:$ROOT/logs/service.log

[Install]
WantedBy=default.target
EOF

chmod 644 "$UNIT_PATH"
systemctl --user daemon-reload || die "systemctl --user daemon-reload 失败"
ok "已写入 $UNIT_PATH"

if [ "$DO_START" = "1" ]; then
  # 先把手工起的实例停掉，免得抢端口
  if [ -f "$ROOT/logs/serve.pid" ]; then
    log "先停掉手工启动的实例"
    bash "$ROOT/app/launcher.sh" stop >/dev/null 2>&1 || true
  fi
  systemctl --user start "$UNIT_NAME" || die "启动失败：systemctl --user status $UNIT_NAME"
  log "等待就绪（最多 300 秒）…"
  for i in $(seq 1 150); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:8098/v1/models || echo 000)"
    [ "$code" = "200" ] && { ok "就绪（$((i*2))s）"; break; }
    sleep 2
  done
  systemctl --user --no-pager status "$UNIT_NAME" | head -12
fi

cat <<EOF

 服务名：$UNIT_NAME
 常用命令：
   systemctl --user status  $UNIT_NAME
   systemctl --user restart $UNIT_NAME
   systemctl --user stop    $UNIT_NAME
   journalctl --user -u $UNIT_NAME -f

 开机自启（默认没开）：
   systemctl --user enable $UNIT_NAME
   sudo loginctl enable-linger $USER     # 没登录也保持运行

 注意：unit 里的路径是安装时烘焙的 $ROOT。
       仓库挪位置之后重新跑一次本脚本。
EOF
