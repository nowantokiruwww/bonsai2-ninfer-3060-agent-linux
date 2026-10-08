# 参数调优

配置文件：**`config/runtime.env`**（唯一入口）。也可以用网页控制台或 `--persist` 改。

先看结论，再看推导。

---

## 0. 三句话结论

1. **真正有用的旋钮只有两个**：KV 容量（换上下文，代价是显存）和思考预算（换墙钟时间，不换 decode 速度）。
2. **`decode tok/s` 的地板约 26**，那是显存带宽。120+ 的数字全部来自投机解码被接受，接受率又取决于**流量类型**。
3. **有两个组合会造成静默失败或死循环**：`--greedy` + `--no-thinking`，以及思考预算 ≥ `max_tokens`。

---

## 1. 生产配置长什么样

```bash
KV_DTYPE=rk2v4-e8
KV_CAPACITY=49152
SPEC_FLAGS="--spec dflash2 --draft-tokens 7"
EXTRA_FLAGS="--max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 \
             --default-reasoning-effort medium --default-thinking-budget 1024 \
             --request-log-jsonl $PWD/logs/request.jsonl"
```

对应引擎命令行：

```
ninfer-serve models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer \
  --host 127.0.0.1 --port 8098 --model-id bonsai2-27b \
  --max-context 49152 --kv-capacity 49152 --kv-dtype rk2v4-e8 \
  --spec dflash2 --draft-tokens 7 \
  --max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 \
  --default-reasoning-effort medium --default-thinking-budget 1024 \
  --request-log-jsonl logs/request.jsonl
```

一条命令看到拼好的结果：

```bash
./app/launcher.sh cmd --preset balanced
```

---

## 2. 维度一：KV 容量 ↔ 显存余量

**KV 容量必须实测，不能猜。** 同一张卡上能开多大，完全取决于当时桌面占了多少显存。

实测（RTX 3060 12 GB，空闲 11,278 MiB）：

| KV 量化 | 提交 32,768 | 提交 49,152 | 提交 65,536 | 实测上限 |
|---|---|---|---|---|
| `int8` | ✅ | ❌ | ❌ | 32,768 |
| `rk8v4` | ✅ | ❌ | ❌ | 32,768 |
| `rk4v4-e8` | ✅ | ✅ | ❌ | 49,152 |
| **`rk2v4-e8`** | ✅ | ✅ | ✅ | **76,768（过了阶梯顶端，真实上限未探）** |

结构原因：工件的 `config.layer_types` 是**混合注意力** —— 一部分层是 `full_attention`（有经典 KV cache），
其余是 `linear_attention`（没有）。所以容量不是简单线性关系。

**默认取 49,152 而不是 76,768**：76,768 只在空卡成立。
桌面上开个浏览器、开个 IDE，显存一掉，同样的配置就起不来（病历 L21）。

想自己试：

```bash
# 先停掉引擎，再试
./stop.sh
./start.sh --ctx 76768
# 失败了就退回
./start.sh --ctx 49152
```

也可以用穷举的方式找出当前显存条件下的真实上限 —— 见 `docs/METHODOLOGY.md` 里的 KV 门禁做法。

修改默认值：

```bash
# 网页控制台里改 KV 容量 → 「保存到 config」
# 或者直接编辑 config/runtime.env 的 KV_CAPACITY
```

---

## 3. 维度二：思考预算 ↔ 墙钟时间

模型有两种输出模式：**思考**（推理过程）和**正文**。思考 token 也算进 `max_tokens`。

`--default-thinking-budget N` 的真实身份是**收口机制** —— 到第 N 个 token，服务端主动补上结束标记
强制关掉思考，让模型开始写正文。它**不是**"最多想 N 个 token"的软限制，
而是"想满 N 个就一定被打断"。

### 实测矩阵（固定任务：写一个内联 SVG 的单文件 HTML + 4 个 tool 定义）

| 思考预算 | 三次墙钟 | 中位 | 产出质量 |
|---|---|---|---|
| 512 | 40.9 / 47.4 / 37.6 s | **40.9 s** | 好 |
| **1024** | **44.2 / 57.2 / 42.4 s** | **44.2 s** | 3/3 真正 `write`（4,750–7,333 字符） |
| 2048 | 36.5 / 36.6 / 63.2 s | 36.6 s | 1/3（两次只发了 33 / 922 字符的 `bash`） |
| 4096 | 56.5 / 67.8 / 124.4 s | 67.8 s | 差（三次里两次只发 48 字符的 `bash`） |

每臂 15 个样本的 decode 中位 / 投机接受率中位：

| 预算 | effort | decode 中位 | 接受率中位 |
|---|---|---|---|
| 4096 | medium | 63.9 | 39.3 % |
| 512 | medium | 66.5 | 40.0 % |
| 4096 | low | 82.4 | 42.6 % |
| 512 | low | 70.4 | 35.3 % |
| 4096 | minimal | 74.6 | 38.6 % |
| 512 | minimal | 76.7 | 41.0 % |

**读法：`decode tok/s` 几乎不随预算变化（58–83 全域）。** 变的是有多少 token 被烧在思考里。
4096 档每个请求都会烧满 4096 个思考 token，512 档只烧 512 个 —— 这就是同任务墙钟差 1.5–2.7 倍的全部原因。

**所以降预算不是"提速"，是"削尾巴"。** 它砍掉的是那批烧了 1000+ 思考 token 的慢请求。

### 为什么选 1024

复读锁死探针（每档 5 次重复 × 3 个草稿窗口 = 15 个判据）：

| 预算 | 单轮 LOCKED | 锁死率 | 真锁死（4 轮里 ≥3 次） |
|---|---|---|---|
| 512 | 6/15 | **40.0 %** | 0 |
| **1024** | **2/15** | **13.3 %** | **0** |
| 2048 | 4/15 | 26.7 % | 0 |
| 4096 | 2/15 | 13.3 % | 0 |

三个结论：

1. **单次探针不足以裁决档位** —— 四档都出现过单轮 FAIL。
2. **降预算安全** —— 真锁死 0/4 臂，不会退回 L26 那种吸引子。
3. **反直觉：最低的 512 单轮重复率最高（40 %）。**

所以 **1024 是唯一在"速度 / 产出 / 复读稳健性"三项都不吃亏的档**。

---

## 4. 维度三（别抱期望）：投机解码

`--spec dflash2 --draft-tokens 7` 已经是实测最好的一档。这是速度的主要来源，但**它治不了中文散文**。

草稿窗口 K 越大，单轮产出越多，但接受率下降。实测 dflash2 在高熵推理文本上的位置衰减：

```
accepted_per_position = [1736, 1240, 897, 670, 528, 401, 311, 13, 12, 11, 8, 8, 7, 6, 5]
                           75%   54%  39%  29%  23%  17%  13%  0.6% ...
```

第 1 位 75 %、第 7 位 13 %、**第 8 位之后接近 0**。总体接受率 35 %。
**没有任何 flag 能治这个根因** —— 它是草稿模型预测能力和文本熵的关系。

`--ngram-draft-tokens` 也**不是速度旋钮**：在长思考请求里，ngram 只贡献了 5.0 % 的接受 token。
它在复读事故里的角色是**放大器**（强化重复），不是提速器。

---

## 5. 完整可用 flag 面

### 思考相关

| Flag | 说明 |
|---|---|
| `--no-thinking` | **默认**关闭思考（客户端仍可覆盖）。⚠ 与 `--default-reasoning-effort` **互斥**，同时给会 throw |
| `--preserve-thinking` | 保留思考内容到响应里 |
| `--default-thinking-budget N` | 思考到 N 个 token 强制收口 |
| `--thinking-budget-message TEXT` | 收口时插入的消息 |
| `--default-reasoning-effort E` | `none` / `minimal` / `low` / `medium` / `high` / `xhigh` / `max` |

> **互斥的坑**：`--no-thinking` 和 `--default-reasoning-effort` 不能同时给。
> 本仓库的 `app/presets.env` 里 `thinking_flags()` 已经处理了这件事：
> 思考关闭时**两个参数都不传**。

### 投机相关

| Flag | 说明 |
|---|---|
| `--spec mtp\|dflash\|dflash2` | 投机后端；`dflash2` 实测最好 |
| `--draft-tokens N` | 草稿窗口 1–15 |
| `--ngram-draft-tokens N` | ngram 草稿 1–63，**引擎默认 15（开）** |
| `--ngram-min-match N` | ngram 最小匹配长度 |
| `--ngram-archive-mib` / `--ngram-session-mib` | ngram 缓存大小（session 默认 128 MiB） |
| `--ngram-native-sessions` / `--ngram-table PATH` / `--ngram-ram` | ngram 存储位置 |

### KV 相关

`--kv-dtype` 可选九种：`bf16` `fp8` `int8` `k8v4` `nvfp4` `rk2v4-e8` `rk4v4` `rk4v4-e8` `rk8v4`。

服务端硬约束：

- `--kv-capacity` 必须 ≥ `--max-context`
- `--max-concurrency` 必须在 `[1, 8]`
- 不给 `--kv-capacity` 时，非 Hybrid 模式默认等于 `max_context`

### 采样

生产用 V100 档：`--temperature 1.0 --top-p 0.95 --top-k 20`。

引擎在非思考模式下的服务端默认是 `presence_penalty 1.5 / temperature 0.7 / top_k 20` ——
**和 V100 档不一样**，所以生产配置里显式给了。

### ⚠ `--greedy`

**不要在生产里用。** 它是 argmax（temperature 0），没有任何随机逃逸。
配合 `--no-thinking` 就会复读死循环（病历 L26）。

`presets.env` 里保留了 `greedy` 档，是为了复现那个事故，界面上会给出红色警告。

---

## 6. 两个静默失败陷阱

### 6.1 预算 ≥ `max_tokens` → 正文为空，HTTP 200

```
思考预算 1024 + max_tokens 900
  → 三条全部 finish_reason=length
  → content 是空字符串
  → HTTP 200，一声不吭
```

**硬约束：思考预算 + 工具调用载荷（约 6,100 token） < `max_tokens`。**

agent 场景建议 `max_tokens ≥ 16384`。

### 6.2 端口通了 ≠ 就绪

引擎在**权重加载完成之前就已经监听端口**，这期间 `/v1/models` 回 **503**。

本项目踩过这个坑：一个探针用 `curl -s -m 2 "$BASE/v1/models" >/dev/null` 判就绪，
把 503 当成了成功，结果 20 次请求全部连接失败，引擎日志还停在 `loading weights | 7.99 GiB`。

**判就绪必须断言 HTTP 200。** 本仓库的 `app/launcher.sh` 的 `wait_ready()` 已经是这么做的。

---

## 7. 速度的本质（复述一遍，最重要）

```
decode ≈ 地板(≈26 tok/s) × (1 + 草稿数 × 接受率)
```

| 流量 | 接受率 | 实测 decode |
|---|---|---|
| agent + 工具 | 52 % | 88.3 |
| 代码 | 37–40 % | 65–73 |
| 英文散文 | 17 % | 39–43 |
| **中文散文** | **6 %** | **26** |

关掉投机（`--spec none`）后中文散文是 26.4 / 26.3 / 26.0 —— 和开着 `dflash2 K=7` 的
26.2 / 26.3 / 27.2 **逐位相同**。

**120–200 从来不是这张卡的 decode 速度，而是"投机接受率 × 带宽地板"。**

想真正提升只有两条路：换带宽更大的卡，或换一个能预测中文的草稿表。
服务端参数改不了。

---

## 8. 复现这些结论

```bash
# 完整审计矩阵（六臂 + 补点，会跑很久）
./docs/params/REPORT-param-audit-20261007.md      # 结论与原始数据

# 自己动手：改参数 → 重启 → 看指标
./restart.sh --preset think
./status.sh
# 请求指标在网页控制台的「请求指标」区，或者直接读 logs/request.jsonl
```

每个请求的指标都记在 `logs/request.jsonl` 里（JSON Lines，schema_version 28），
包含 `completion_tokens`、`timings_seconds.decode`、`speculative.accepted_tokens/drafted_tokens`、
`result.model_thinking_tokens`、`finish_reason`。想自己算：

```
decode tok/s = completion_tokens / timings_seconds.decode
接受率       = speculative.accepted_tokens / speculative.drafted_tokens
```
