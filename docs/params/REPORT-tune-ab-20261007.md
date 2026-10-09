# 调参对照实测：中文散文为什么"速度没变"（2026-10-07）

**一句话**：这张卡上**单流 decode 的地板是 ~26 tok/s**（显存带宽），
120–200 tok/s 那些数字**全部来自投机被接受**。
中文散文上 dflash2 的接受率只有 **6%**，所以它回到地板值 —— 与思考开关、思考预算、投机开关**都无关**。

原始数据：`evidence/params/tune-ab-20261007/request.jsonl`（三臂，同机同卡同权重）。
命令行的三个臂由 `scripts/build/96-tune-serve.sh（`tune.sh` 的源码；载荷包里的 `./tune.sh` 是同一脚本的运行时副本）` 拉起（它把日志直接打在终端）。

## 1. 三臂矩阵

固定条件：`rk2v4-e8 @ 49152`、`--spec dflash2 --draft-tokens 7`（除第三臂）、
采样 `--temperature 1.0 --top-p 0.95 --top-k 20`、`batch 1.00`、每臂独立重启引擎。

| 请求类型 | `fast`（`--no-thinking`） | `balanced`（思考 1024） | 关投机 + `--no-thinking` |
|---|---|---|---|
| 中文散文 ~400 字 | **26.3** tok/s · 接受率 6.1% | 39.1 / 57.9 / 50.6 · 14.6 / 27.4 / 22.9% | **26.3** tok/s · 0% |
| 英文散文 ~400 词 | 39.5 · 17.5% | 42.7 · 17.7% | — |
| 代码：写 Python 函数 | 64.7 · 37.4% | 72.7 · 40.0% | — |
| agent + tools：英文写 `bike.html` | **88.3** · 52.4% | 80.8 · 45.2% | — |

（单位 tok/s；接受率 = `accepted_tokens / drafted_tokens`；中文散文各 3 个样本取中位。）

## 2. 关键读法

### 2.1 关掉投机，中文散文一模一样

`--spec none` 得到 **26.4 / 26.3 / 26.0**，开着 dflash2 K=7 得到 **26.2 / 26.3 / 27.2**。
**逐位相同**：每轮多算的 7 个草稿，与那 6% 被接受、省下来的一步，正好抵消。
→ 在中文散文上，投机既不是加速器也不是减速器，就是个**空转**。

### 2.2 那个 26 是显存带宽，不是调度

权重常驻 **7.99 GiB**（`--spec` 打开时；关掉时 6.70 GiB）。
单流每产 1 个 token 必须把权重读一遍：`8 GiB ÷ ~300 GB/s ≈ 26–37 tok/s`。
实测地板 26 → 与带宽推算吻合。

每轮投机产出 ≈ `1 + K × 接受率` 个 token，所以：

- 接受率 **95%**（旧部署的 DSH 代码/工具流量）→ ≈7.7× → **~200 tok/s**（A3 自报中位 202.1）；
- 接受率 **52%**（agent + tools）→ 实测 **88.3**；
- 接受率 **6%**（中文散文）→ 被自身开销吃光 → **26**。

**用户记忆中的"很容易突破 120"是代码/英文/工具流量上的数字**。
中文散文在这张卡上**从来到不了 120**，而且**任何服务端开关都改不了** —— 瓶颈是带宽。

### 2.3 `--no-thinking` 在中文上反而更慢

中文散文：`fast`（不思考）**26.3**，`balanced`（思考 1024）**39.1–57.9**。
因为思考文本（英文推理）的接受率（14.6–27.4%）**比中文散文本身（6.1%）高**。
"让模型闭嘴就能提速"这个直觉**在中文散文上是错的**。

## 3. 顺带钉住的静默失败：`max_tokens` 小于思考预算 → 空正文

`balanced`（预算 1024）第一次用 `max_tokens=900` 发中文散文，**三条全部**
`finish_reason=length`、`content` **0 字符**、`model_thinking_tokens≈900`。
思考把配额烧光，正文一个字都没有，**而且不报错**。

→ **硬约束：思考预算必须显著小于 `max_tokens`**（L27）。
DSH 发 `max_tokens=16384` 所以碰不到；任何"小 `max_tokens` + 思考开"的组合都会中招。

## 4. 调参器自己的坑（已修）

`scripts/build/96-tune-serve.sh` 第一版只 `source` 了 `config/runtime.env` 而没有 `export`，
于是子进程环境里**没有** `CUDA_VISIBLE_DEVICES`，引擎按 CUDA 自己的设备序**挑中了 V100**：

```
engine | calibrating routes for nvidia-tesla-v100-sxm2-16gb-sm70 (80 SMs)
CUDA_CHECK(cudaGetLastError()) failed: cudaErrorNoKernelImageForDevice
```

（本产物只有 sm_86 的 cubin，当场死掉，没造成损害；
`profiles/device-profiles.json` 事后校验与冻结基线 sha256 一致，未被写脏。）

修法：显式 `export CUDA_VISIBLE_DEVICES / CUDA_DEVICE_ORDER=PCI_BUS_ID / NINFER_DEVICE_PROFILES / LD_LIBRARY_PATH`，
并在 `CUDA_VISIBLE_DEVICES` 不以 `GPU-` 开头时**拒绝启动**。
上一代工程的 `package/runtime-tools.sh` 一直是 export 的 —— **复制启动逻辑时要把 export 一起复制。**

## 5. 复跑方法

```bash
scripts/build/96-tune-serve.sh（`tune.sh` 的源码；载荷包里的 `./tune.sh` 是同一脚本的运行时副本）                 # 预设表 + 当前生产档
scripts/build/96-tune-serve.sh（`tune.sh` 的源码；载荷包里的 `./tune.sh` 是同一脚本的运行时副本） fast            # 不思考（日志打在终端；Ctrl-C 一次干净退出）
scripts/build/96-tune-serve.sh（`tune.sh` 的源码；载荷包里的 `./tune.sh` 是同一脚本的运行时副本） balanced        # 思考 1024
scripts/build/96-tune-serve.sh（`tune.sh` 的源码；载荷包里的 `./tune.sh` 是同一脚本的运行时副本） --spec none --thinking off   # 关投机对照
```

解析新产生的日志（`offset` 用 `stat -c%s` 在启动前取）：

```bash
python3 scripts/build/92-thinking-throughput.py --jsonl evidence/params/tune-ab-20261007/request.jsonl
```
