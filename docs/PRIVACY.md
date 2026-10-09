# 隐私与脱敏

`evidence/` 里 215 个文件是**原始命令输出**，不是整理过的报告。原始输出天然包含
"这台机器是谁"的信息：用户名、主机名、挂载点、GPU 序列号。发布前必须脱敏，
否则公开仓库里就有一份你的机器指纹。

## 脱敏规则

| 原始 | 替换为 | 例子 |
|---|---|---|
| `/home/<你的用户名>/` | `/home/<user>/` | `/home/<user>/llm/logs/ninfer-v3-3060.log` |
| 主机名（`uname -n`、`hostname`） | `<user>-<主板型号>` | `Linux <user>-MS-7B89 7.0.0-38-generic` |
| 挂载点里的用户名 | `<user>` | `/media/<user>/T9` |
| GPU UUID | `GPU-<redacted>` | `GPU-<redacted>` |
| 本地归档仓库名 | `<retired-local-archive>` | 见 `scripts/fetch-runtime.sh` 的 `--auto` 回退说明 |

**只替换身份，不替换数字。** 时间戳、字节数、吞吐、退出码、错误码全部保留原值 ——
否则证据失去意义。

## 已扫描的密钥形态

发布前扫描（`scripts/verify.sh` 的 `[5d/7]` 门禁覆盖 README；下面的命令覆盖全仓库）：

```bash
grep -rlE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|hf_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}' \
  . --exclude-dir=.git
```

结果：**0 命中**。`request.jsonl` 里出现的 `api_key` 字样是引擎 usage 字符串
`--api-key KEY`，不是真实密钥。

## `request.jsonl` 里到底有什么

这是引擎的请求元数据，字段只有：

```
effective_thinking_budget, enable_thinking, has_tool_history, media_item_count,
message_count, model, preserve_thinking, protocol, request_id,
requested_output_tokens, requested_reasoning_effort, sampling, stream,
thinking_budget, tool_choice, tool_count
```

**没有对话内容**，没有 prompt，没有回复。它用来算接受率和吞吐，不是用来存档会话。

## 自己重新生成证据时

跑 `scripts/build/` 流水线会生成带**你**的机器指纹的原始证据。如果你也要发布，
先跑一遍脱敏：

```bash
find evidence -type f \( -name '*.log' -o -name '*.txt' -o -name '*.json' -o -name '*.jsonl' -o -name '*.md' \) \
  -exec sed -i \
    -e "s#/home/$(whoami)/#/home/<user>/#g" \
    -e "s/$(hostname)/<user>-<board>/g" \
    -e 's/GPU-[0-9a-f]\{6,\}/GPU-<redacted>/g' {} +
```

然后 `./scripts/verify.sh` 会确认没有身份标识残留。

## 什么没脱敏（以及为什么）

- **主板型号**（`MS-7B89`）保留：它不是身份标识，而且对复现有用（说明这是一台桌面机）。
- **内核版本、驱动版本、包版本**保留：复现依赖它们。
- **内存/显存容量**保留：结论（如 `-j 6` 的由来）依赖这些数字。
