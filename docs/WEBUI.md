# 网页控制台（`./webui.sh`）的接口

`webui.sh` 起的是 `webui/server.py` —— **纯标准库**的 HTTP 服务，默认 `127.0.0.1:8099`。
它不是引擎本身：引擎在 `PORT`（默认 8098），控制台只是启停/调参/看日志的壳。

写这份文档的原因：README 里只写了"六个 API 端点"，而实际是 **10 个 GET + 2 个 POST**。
数字对不上，读者就没法验证 —— 所以这里把每个端点列出来，并且 `verify.sh` 会检查这份列表和代码一致。

```bash
./webui.sh                 # 默认 127.0.0.1:8099
./webui.sh --port 9000
./webui.sh --lan           # 绑 0.0.0.0：局域网里别的机器也能打开（无鉴权，慎用）
./webui.sh --local         # 收回上面的开放
```

## GET

| 端点 | 返回 | 说明 |
|---|---|---|
| `/api/health` | `{"ok":true,"root":…,"time":…}` | 控制台活着吗（不依赖引擎） |
| `/api/status` | `{"running":bool,"pid":…,"uptime_s":…,"host":…,"port":…,"endpoint_http":…,"kv_dtype":…,"kv_capacity":…,"thinking":…}` | 引擎状态；`?force=1` 绕过 5 秒缓存 |
| `/api/gpus` | `{"gpus":[{"uuid":…,"name":…,"compute_cap":…}]}` | `nvidia-smi` 的机器可读版；没驱动时是 `[]` |
| `/api/access` | `{"model":…,"engine":{"local_base":…,"lan_base":…,"urls":[…],"exposed":bool},"snippet":…}` | "别人怎么连这台机器"：完整 API 地址 + 可粘贴的代码片段 |
| `/api/presets` | `{"presets":[{"name":…,"thinking":…,"effort":…,"budget":…,"sample":…,"desc":…}]}` | 五个档位（balanced/fast/think/deep/greedy），来自 `app/presets.env` |
| `/api/config` | `{"values":{…},"keys":[…],"path":"config/runtime.env"}` | 当前 `config/runtime.env` 的内容 |
| `/api/action` | `{"id":…,"action":…,"running":bool,"rc":…,"elapsed":…,"cmd":…,"output":[…]}` | 最后一次启停动作的结果 |
| `/api/logs` | `{"lines":[…],"bytes":…,"path":"logs/service.log"}` | 服务日志尾部；`?n=300` 控制行数 |
| `/api/requests` | `{"requests":[…],"bytes":…}` | 每个请求的 token/耗时（读 `logs/request.jsonl`）；`?n=25` |
| `/api/logs/stream` | SSE | 日志实时流：先推最后 200 行，然后每 0.6 秒增量；每 15 秒一条 `: ping` 保活 |

## POST

两个都接受 JSON。

| 端点 | 请求体 | 返回 |
|---|---|---|
| `/api/config` | 任意 `CONFIG_KEYS` 的键：`HOST` `PORT` `MODEL_ID` `KV_DTYPE` `KV_CAPACITY` `SPEC_FLAGS` `EXTRA_FLAGS` | `{"ok":true,"changed":[…],"values":{…}}`；没有可更新的键 → 400 `没有可更新的键` |
| `/api/action` | `{"action":"start"|"stop"|"restart", "preset":"balanced", "ctx":…, "kv_dtype":…, "spec":…, "extra":…}` | 启停结果 |

未知路径：GET 返回 404 `{"error":"not found","path":…}`，POST 返回 404 `{"ok":false,"error":"not found"}`。

## 为什么控制台和引擎是两个端口

引擎（`/v1/chat/completions`）在 `PORT=8098`，控制台在 8099。
分开的理由写在病历里：把两者合并成一个进程意味着控制台要依赖引擎的库，
而控制台必须**在引擎起不起来都能打开** —— 起不起来正是你要排查的第一件事。
`/api/status` 用 `endpoint_http` 字段（`200`/`000`）区分"进程存在"和"服务真的能应答"，
这两个不一样：进程存在但 CUDA 挑错卡，一样会 000（病历 L11 的设备顺序陷阱）。

## 没有鉴权

控制台没有任何登录。`--lan` 绑 `0.0.0.0` 意味着局域网里任何人都能停你的服务、改你的参数。
默认只绑 `127.0.0.1`。要对外暴露，请自己在前面放一层反向代理或防火墙。
