#!/usr/bin/env bash
# 网页控制台：启停 / 日志 / 参数 / 请求指标
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/webui/server.py" "$@"
