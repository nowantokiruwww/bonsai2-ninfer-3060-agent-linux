# CLI 口径对账（静态，基于源码；二进制版见 `flag-diff.md`）

- 源码：`iamwavecut/ninfer-all` @ `796f985007775f4bc7cfde53804fa22e7d60dbf8`（工作树干净，零补丁）
- CLI 解析源文件：`apps/cli/options.cpp`、`src/serve/serve_options.cpp`、`src/serve/operational_log.cpp`
- 生成时间：2026-10-06（Phase 5 期间静态核对；二进制产出后由 `scripts/55-flag-diff.sh` 复核）

## bench 的 Windows 3060 命令用到的 flag —— 源码里全部存在

bench 命令（Windows 口径）：
```
ninfer-serve.exe Ternary-Bonsai-2-27B-ninfer-v3.ninfer --host 127.0.0.1 --port 8098 ^
  --max-context 24576 --kv-capacity 24576 --kv-dtype int8 ^
  --max-concurrency 1 --no-thinking --greedy ^
  --spec dflash2 --draft-tokens 7 --lm-head-draft
```

| flag | 源码命中 | 结论 |
|---|---|---|
| `--host` | 26 | ✅ |
| `--port` | 5 | ✅ |
| `--model-id` | 4 | ✅ |
| `--max-context` | 21 | ✅ |
| `--kv-capacity` | 13 | ✅ |
| `--kv-dtype` | 10 | ✅ |
| `--max-concurrency` | 6 | ✅ |
| `--no-thinking` | 7 | ✅ |
| `--greedy` | 6 | ✅ |
| `--spec` | 20 | ✅ |
| `--draft-tokens` | 11 | ✅ |
| `--lm-head-draft` | 5 | ✅ |

**也就是说：bench 那条命令在本项目源码线上可以逐字沿用**（只需去掉 `.exe`、Windows 续行符 `^`，
并把 `--kv-capacity 24576` 换成我们自己门禁实测的值）。这是与旧移植最明显的差别——上次
`--host-state-slots`/`--host-kv-mib`/`--log-level` 在某套 kit 里根本不存在。

## 本项目关心的扩展 flag —— 也都存在

`--lookup-ngram`(7)、`--device-profile`(11)、`--prefill-cublas`(9)、`--mlp-a8-decode`(9)、
`--mtp-experts-q4`(11)、`--gdn-state-fp16`(6)。

## `--kv-dtype` 的实际接受集合（源码里出现的字面量）

```
bf16  fp8  int8  k8v4  nvfp4  rk2v4-e8  rk4v4  rk4v4-e8  rk8v4
```

共 9 种。注意：

1. **`--kv-dtype int8` 被接受** → bench 命令里的 `int8` 不用换。
2. 本机旧移植用的是 `rk2v4-e8`，也在列。
3. 交叉参考：`yangkang5303/ninfer-3090` 报告过某些 fork 会在 **engine 构造期**拒绝 `rk8v4`
   （解析能过，构造失败）。所以 KV 门禁必须**对每个 dtype 真起一次服务**，
   不能只看 `--help` 是否列出——`agent/kvgate.py` 正是这么做的：失败样本会连同
   引擎日志尾部一起留存。

## 对门禁的影响

`scripts/75-kv-gate.sh` 的候选 dtype 定为：
`int8`（bench 口径，必须对齐）、`rk8v4`、`rk4v4-e8`、`rk2v4-e8`（本机旧移植用过的激进档）。
