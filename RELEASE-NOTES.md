# v0.1.0 —— 在单张 RTX 3060 12 GB 上跑 Ternary-Bonsai-2-27B

首个可用版本。**已在真机上端到端跑通**（RTX 3060 12 GB / 驱动 580.178.04 / CUDA 13.1）。

## 这是什么

把 [Ternary-Bonsai-2-27B](https://huggingface.co/WaveCut/Ternary-Bonsai-2-27B-NInfer-v3)（三值量化 2-bit 权重）
跑在一张消费级 12 GB 显卡上的**完整、自包含**部署仓库：从零编译的推理引擎、按 UUID 锁卡、
KV 容量门禁、网页控制台、Docker 镜像、以及一份把踩过的坑全写下来的移植病历。

上游引擎是 [`iamwavecut/ninfer-all`](https://github.com/iamwavecut/ninfer-all)，**零源码改动**
（`sm_86` 本来就在它的架构白名单里）。真正难的地方不是编译，是**认出上次失败的原因**：
两个 fork 给同一个三值 2-bit 格式起了不同名字（`PQ2_0_G128` vs `t2_g128_fp16`），
跨 fork 配模型必然 `unknown tensor format`。详见 `docs/LINEAGE.md`。

## 你需要什么

- 一张 **RTX 3060 12 GB**（sm_86；3070 / 3080 / 3090 同为 sm_86，也能跑）
- Ubuntu 24.04 或同类，NVIDIA 驱动 ≥ 580，**驱动装好就行，不需要装 CUDA Toolkit**
- 约 15 GB 磁盘（载荷 2.6 GB + 权重 9.5 GB）

## 怎么开始

```bash
git clone https://github.com/nowantokiruwww/bonsai2-ninfer-3060-agent-linux.git
cd bonsai2-ninfer-3060-agent-linux

./install.sh     # ① 引擎载荷 ② 模型权重 ③ 自检
./start.sh       # 启动，第一次约 35 秒
./webui.sh       # 浏览器打开 http://127.0.0.1:8099
```

## 本 Release 的附件

引擎载荷压缩后是 **2.06 GiB**，而 GitHub Release 的**附件单文件上限是 2 GiB**，
所以切成两卷。**两个都要下**，`fetch-runtime.sh` 会自动拼回去并校验整包 sha256：

| 附件 | 说明 |
|---|---|
| `runtime-0.1.0-linux-x86_64.tar.zst.part1` | 第 1 卷，1.46 GiB |
| `runtime-0.1.0-linux-x86_64.tar.zst.part2` | 第 2 卷，582 MiB |
| `runtime-0.1.0-linux-x86_64.tar.zst.sha256` | **整包**的 sha256（拼回来之后校验这个） |
| `runtime-0.1.0-linux-x86_64.tar.zst.part1.sha256` | 第 1 卷单独校验 |
| `runtime-0.1.0-linux-x86_64.tar.zst.part2.sha256` | 第 2 卷单独校验 |

`./install.sh` 会自己处理这些，**手工下载的话记得两个 part 都要**。
单卷坏了不用重下整包：重跑 `./scripts/fetch-runtime.sh` 会跳过校验通过的那一卷。

载荷里是：`ninfer-serve`（服务端）、`ninfer`（裸 CLI）、`ninfer-calibrate`（标定工具）、
4 个 CUDA 运行库、这张卡实测出来的 `device-profiles.json`、以及 agent 验收脚本。
**不带**驱动（从宿主机来）、**不带**权重（另下）、**不带**编译器。

## 实测数字

| 项目 | 数字 |
|---|---|
| 权重加载 | 7.99 GiB / 25.5 秒 |
| 就绪 | 约 35 秒（冷启动） |
| 短对话解码 | **177 tok/s**（思考关闭时中位，n=67） |
| 长文思考解码 | 56 tok/s（思考 >1000 token 时中位） |
| 投机接受率 | 思考关闭 94.8% → 长思考 33.8% |
| 工具调用 | 50/50 轮全部合法，前缀缓存命中 99.7% |
| 显存 | 11,032 MiB，长时间跑零增长 |

**速度的真实旋钮是思考预算，不是别的。** 一张 DSH 形态的 agent 任务：
1024 预算 44 秒，4096 预算 68 秒。生产默认给 **1024**。

## 已知边界（都是实测，不是猜的）

- **投机并非普遍无损**：同一 prompt 连发 3 次，基线臂逐字节可复现、投机臂不可复现
  （两条路径输出不同）。要逐字节可复现就用基线臂，追吞吐用投机臂。
- **引擎不发 CORS 头**（OPTIONS 预检返回 404），浏览器页面**不能**直接调它，
  只适合桌面客户端 / 脚本。
- **`--greedy` + `--no-thinking` 会复读锁死**（L26）：去掉唯一随机逃逸和唯一自省通道后，
  argmax 恒等于那条工具调用，形成死循环。生产配置已改采样。
- KV 上限随桌面占用浮动：卡空闲时 76,768，保守取 **49,152**。

## 文档

| 想知道什么 | 看哪 |
|---|---|
| 这东西怎么来的、为什么是这条源码线 | `docs/LINEAGE.md` |
| 移植过程中踩的 30 条坑（含复现与修法） | `docs/PORTING-LEDGER.md` |
| 每个参数干什么、怎么调 | `docs/PARAMETERS.md` |
| 怎么用 Docker 跑 | `docs/DOCKER.md` |
| agent 实测体验（A1–A8） | `docs/AGENT-EXPERIENCE.md` |

## 许可

本项目 Apache-2.0（见 `LICENSE`）。引擎来自 `iamwavecut/ninfer-all`（Apache-2.0），
模型来自 `WaveCut/Ternary-Bonsai-2-27B-NInfer-v3`，CUDA 运行库受 NVIDIA EULA 约束 ——
三段归属与再分发注意事项都在 `NOTICE` 里。
