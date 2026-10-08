#!/usr/bin/env bash
# 薄封装 —— 真正的实现在 app/launcher.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app/launcher.sh" restart "$@"
