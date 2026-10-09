# scripts/build/ —— 编译期流水线（历史，不是部署路径）

这个目录**不是**部署所需的东西。部署只需要仓库根的三个命令：

```bash
./install.sh && ./start.sh && ./webui.sh
```

这里保存的是 2026-10-06 → 2026-10-07 那两天里，把 `Ternary-Bonsai-2-27B` 从零编译到能在
RTX 3060 上跑的那条流水线。它存在的意义只有一个：**让 `docs/PORTING-LEDGER.md` 里每一条病历
都能追溯到某个脚本和某个证据文件**，而不是只有一句"我们试过，失败了"。

## 阶段顺序

| 脚本 | 阶段 | 产出证据 |
|---|---|---|
| `00-baseline.sh` | 环境基线：这台机器到底有什么 | `evidence/baseline/001…034-*.log` |
| `10-driver.sh` | 驱动与设备节点检查 | `evidence/baseline/` |
| `20-cuda-fetch.sh` | 项目自带 CUDA 13.1 工具链（免 root，逐件 sha256） | `config/toolchain.lock`、`evidence/toolchain/` |
| `30-deps.sh` | 系统依赖闭包 | `evidence/toolchain/deps.txt` |
| `40-fetch-sources.sh` | 拉引擎源码并锁定 commit | `evidence/sources/sources.lock` |
| `50-build.sh` | sm_86 编译 + 污染门禁 + 产物体检 | `evidence/build/`、`evidence/isolation/` |
| `55-flag-diff.sh` | 静态 flag 面 vs 实际接受 flag | `evidence/serve/flag-diff.md` |
| `60-fetch-model.sh` | 模型工件 + sha256 | `evidence/model/model-identity.txt` |
| `70-calibrate.sh` | 设备标定（3060 没有内置 profile） | `evidence/calibrate/` |
| `75-kv-gate.sh` | KV 量化容量门禁 | `evidence/kv-gate/runs/*.log` |
| `80-serve.sh` | 起服务 | `evidence/serve/serve-help.txt` |
| `85-isolation-proof.sh` | 证明产物不依赖外部 CUDA | `evidence/isolation/ISOLATION-PROOF.md` |
| `86-verify-live-match.sh` | 静态 flag 面与运行时行为对账 | `evidence/serve/flag-surface-static.md` |
| `90-agent-accept.sh` | agent 场景验收 A1–A8 | `evidence/agent/` |
| `91-repeat-lock-probe.py` | 重复锁定探针（`--no-thinking` 死循环） | `evidence/params/probe-repeat-*` |
| `92-thinking-throughput.py` | 思考预算 vs 吞吐 | `evidence/params/` |
| `93-param-frontier.sh` | 参数前沿扫描 | `evidence/params/frontier-*` |
| `94-lock-probe-repeat.sh` | 锁定复现 | `evidence/params/probe-repeat-*` |
| `95-manifest.sh` | 输入/产物身份表 | `evidence/MANIFEST.md` |
| `96-tune-serve.sh` | A/B 调参（`tune.sh` 的源码） | `evidence/params/tune-ab-20261007/` |
| `97-deploy-service.sh` | systemd 用户服务部署 | `evidence/deploy/deploy-report.txt` |
| `98-dsh-integrate.sh` | 接入 harness | `evidence/deploy/dsh-integration.txt` |
| `99-auto-pipeline.sh` | 全链编排 | — |
| `99-verify-dsh.sh` | 端到端验证 | `evidence/deploy/dsh-e2e.txt` |

## 复现的前提

这些脚本假设你**从零开始**，且有一张 sm_86 卡。它们不需要 sudo，也不碰 `/usr/local/cuda`：
工具链全部下载进 `.store/toolchain/cuda-13.1/`（可用 `BSTORE` 环境变量换盘）。

`config/env.sh` 已经在仓库里，不用改就能跑（它只声明路径和上游 commit，不含本机身份）。
要换存放盘，导出 `BSTORE=/path/to/store`。

```bash
bash scripts/build/00-baseline.sh
bash scripts/build/20-cuda-fetch.sh
bash scripts/build/30-deps.sh
bash scripts/build/40-fetch-sources.sh
bash scripts/build/50-build.sh          # 本机同配置历史耗时约 96.6 分钟
bash scripts/build/60-fetch-model.sh
bash scripts/build/70-calibrate.sh
bash scripts/build/75-kv-gate.sh
```

完整配方与踩坑解释见 **`docs/BUILD.md`**。

## 为什么这些脚本里的路径带 `verify:allow-outside-path`

`scripts/verify.sh` 的第 5 项断言禁止仓库引用仓库外的绝对路径。编译期脚本里
`$HOME` 下的 `bonsai-ninfer-3060` 是**当时那台机器的部署根**，不是部署指令。它们被显式豁免，
是为了保留历史原貌：改写它们等于篡改证据。新部署路径全部在仓库根，见 `README.md`。
