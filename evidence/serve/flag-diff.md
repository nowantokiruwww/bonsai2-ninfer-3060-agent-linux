# CLI 口径对账（Linux 口径 vs bench 的 Windows 口径）

- 二进制：`/home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/.store/build/build-sm86/apps/ninfer-serve`
- sha256：`7ebf2ebf6c086f0f135f97090825c0a8a0a05fd02ffc9199c5faf9dc6cc6d574`
- 生成时间：2026-10-06T21:08:38+0800
- 完整 --help：`evidence/serve/serve-help.txt`
- 实际接受的 flag 集合：`evidence/serve/serve-flags-accepted.txt`（233 个）

## bench 的 Windows 3060 命令逐条对账

| flag | 本二进制是否接受 | 说明 |
|---|---|---|
| `--host` | ✅ | |
| `--port` | ✅ | |
| `--model-id` | ✅ | |
| `--max-context` | ✅ | |
| `--kv-capacity` | ✅ | |
| `--kv-dtype` | ✅ | |
| `--max-concurrency` | ✅ | |
| `--no-thinking` | ✅ | |
| `--greedy` | ✅ | |
| `--spec` | ✅ | |
| `--draft-tokens` | ✅ | |
| `--lm-head-draft` | ✅ | |

## 本项目关心 / bench 变体实验出现过的 flag

| flag | 是否接受 |
|---|---|
| `--device-profile` | ✅ |
| `--device-profile-path` | ✅ |
| `--gdn-state-fp16` | ✅ |
| `--kv-capacity` | ✅ |
| `--lookup-ngram` | ✅ |
| `--mlp-a8-decode` | ✅ |
| `--mtp-experts-q4` | ✅ |
| `--prefill-cublas` | ✅ |
| `--preserve-thinking` | ✅ |
| `--reasoning-effort` | ❌ |
| `--thinking-budget` | ❌ |
| `--vision` | ✅ |

## 结论

bench 的 Windows 3060 命令里的 flag **全部被本二进制接受**，命令可逐字沿用
（仅需把 `.exe`、Windows 续行符 `^`、以及显式容量以外的部分换掉）。
