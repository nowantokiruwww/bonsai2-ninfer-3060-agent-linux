# 证据索引（evidence/）

`docs/PORTING-LEDGER.md` 里每一条病历都指向一个具体文件。这份索引把引用 → 文件对应起来，
所以任何一条结论都能点开验证，而不是只有一句"我们试过"。

**共 210 个文件，4.8 MB，全部纯文本/JSON。** 已脱敏：用户名、主机名、GPU UUID、本机绝对路径
（见 `docs/PRIVACY.md`）。

## 按阶段

| 目录 | 文件数 | 内容 | 对应病历 |
|---|---|---|---|
| `evidence/baseline/` | 35 | 环境基线快照（uname/lscpu/free/df/lsblk/lspci/lsmod/nvidia-smi/dpkg…） | L09, L11 |
| `evidence/toolchain/` | 4 | CUDA redist 版本、`--list-gpu-arch`、依赖闭包、toolchain.lock | L05, L06 |
| `evidence/sources/` | 2 | 上游 commit 锁定与引擎事实 | L01 |
| `evidence/build/` | 9 | cuobjdump ELF/PTX 体检、架构汇总、产物身份、内存压力诊断 | L10, L13, L16 |
| `evidence/isolation/` | 9 | RUNPATH/ldd 污染门禁、构建前后环境、隔离证明 | L02, L15, L22 |
| `evidence/calibrate/` | 5 | 3060 设备 profile 标定 | L09 |
| `evidence/kv-gate/` | 16 | 逐 kv-dtype × 逐容量实测（int8/rk2v4/rk4v4/rk8v4） | L08, L21 |
| `evidence/model/` | 2 | 工件身份（字节数 + sha256） | L01 |
| `evidence/serve/` | 6 | flag 静态面 vs 实际接受、serve help | L17, L19 |
| `evidence/agent/` | 20 | A1–A8 验收、correctness control、lm-head-draft 探针 | L17, L19, L26 |
| `evidence/params/` | 98 | 参数审计、前沿扫描、A/B 调参、request.jsonl | L27, L29 |
| `evidence/deploy/` | 3 | systemd 部署报告、harness 集成、端到端 | L24, L30 |

## 病历 → 证据（抽查）

| 病历 | 结论 | 证据文件 |
|---|---|---|
| L02/L22 | RUNPATH 硬钉在项目内，换机器仍可跑 | `evidence/isolation/runpath.txt`, `evidence/isolation/ldd.txt` |
| L05 | `cuda_nvcc` 不含 `cicc`，它在 `libnvvm` | `evidence/toolchain/toolchain.lock` |
| L08/L21 | KV 容量不是常数，24576 只是某时刻的值 | `evidence/kv-gate/runs/rk2v4-e8-76768.log` |
| L11 | V100 sm_70 不可达：`209 CUDA_ERROR_NO_BINARY_FOR_GPU` | `evidence/build/cuobjdump-elf.txt`, `evidence/build/cuobjdump-ptx.txt` |
| L15 | 非英文 locale 让 readelf 门禁误判 | `evidence/isolation/artefact-gate.txt` |
| L16 | 产物实际带 369 个 sm_86 cubin **且** PTX | `evidence/build/cuobjdump-ptx.txt` |
| L24 | 引擎忽略单个 SIGINT → systemd 每次停服务等 63 秒再 SIGKILL | `evidence/deploy/deploy-report.txt` |
| L26 | `--no-thinking` 导致复读锁定（字节相同的重复工具调用，永不逃逸） | `evidence/agent/control/baseline.log` |
| L29 | 中文散文 26 tok/s 是带宽地板；spec 在 6% 接受率下是纯 no-op | `evidence/params/tune-ab-20261007/request.jsonl` |
| L30 | 只读验证把生产服务杀掉了 | `evidence/deploy/dsh-e2e.txt` |

## 这些文件是什么形态

- `.log` / `.txt`：命令的原始 stdout，带时间戳，未编辑。
- `.json` / `.jsonl`：结构化指标。`request.jsonl` 是引擎的请求元数据（`message_count`、
  `sampling`、`thinking_budget`、`acceptance`），**不含对话内容**。
- `ISOLATION-PROOF.md` / `MANIFEST.md`：由脚本生成的身份表。

## 复现

跑 `scripts/build/` 里的流水线会重新生成同名证据（时间戳不同）。
配方见 [`docs/BUILD.md`](BUILD.md)。
